package com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw

import com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

/** Protocol calls are disposable; business tasks and their cached results belong to TaskManager. */
class ToolCallRouter(
    private val tasks: TaskManager,
    private val scope: CoroutineScope,
    private val liveConversation: Boolean,
    private val presentArtifact: suspend (TaskRecord) -> Unit,
    private val onResponse: (JSONObject) -> Unit,
    private val onFinished: () -> Unit,
    private val onResultDelivered: (TaskRecord) -> Unit = {},
) {
    companion object {
        fun buildImmediateResponse(call: GeminiFunctionCall, result: ToolResult): JSONObject =
            JSONObject().put("toolResponse", JSONObject().put("functionResponses", JSONArray().put(
                JSONObject().put("id", call.id).put("name", call.name).put("response", result.toJSON())
            )))
    }
    private val jobs = mutableMapOf<String, Job>()
    private val responses = mutableMapOf<String, JSONObject>()
    private val submitted = mutableMapOf<String, String>()
    private val cancelled = mutableSetOf<String>()
    private var connected = true

    fun handleToolCall(call: GeminiFunctionCall) {
        if (call.id in cancelled || call.id in jobs) { onFinished(); return }
        responses[call.id]?.let { onResponse(it); onFinished(); return }
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val result = route(call)
                val payload = buildImmediateResponse(call, result)
                if (connected && call.id !in cancelled) {
                    responses[call.id] = payload
                    onResponse(payload)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (connected && call.id !in cancelled) {
                    val payload = buildImmediateResponse(call, ToolResult.Failure(e.message ?: "작업 처리 실패"))
                    responses[call.id] = payload
                    onResponse(payload)
                }
            } finally {
                jobs.remove(call.id)
                if (connected) onFinished()
            }
        }
        jobs[call.id] = job
        job.start()
    }

    private suspend fun route(call: GeminiFunctionCall): ToolResult {
        if (call.name == "list_tasks") {
            val query = call.args["query"]?.toString().orEmpty().trim()
            val matches = tasks.snapshot().filter { query.isBlank() || it.title.contains(query, true) || it.tool.contains(query, true) }
            return ToolResult.Success(JSONObject().put("tasks", JSONArray(matches.takeLast(30).map { it.toJson() })).toString())
        }
        if (call.name == "get_task_result") {
            val task = requireTask(call)
            tasks.focus(task.id)
            if (task.state == TaskState.COMPLETED && task.tool == "capture_current_view") presentArtifact(task)
            if (task.state in setOf(TaskState.COMPLETED, TaskState.FAILED)) onResultDelivered(task)
            return ToolResult.Success(task.toJson(true).put("task_context", tasks.contextJson()).toString())
        }
        if (call.name == "record_task_result") {
            val task = requireTask(call)
            val updated = tasks.recordInterpretation(task.id, task.revision, call.args["interpretation"]?.toString().orEmpty())
            tasks.persist()
            onResultDelivered(updated)
            return ToolResult.Success(updated.toJson(true).toString())
        }
        if (call.name == "update_task") {
            val task = requireTask(call)
            val changed = tasks.control(task.id, task.revision, call.args["action"]?.toString().orEmpty())
            tasks.persist()
            return ToolResult.Success(changed.toJson(true).put("task_context", tasks.contextJson()).toString())
        }
        val taskId = call.args["task_id"]?.toString()?.takeIf { it.isNotBlank() }
        val task = if (taskId != null) {
            val existing = requireTask(call)
            require(existing.sourceTaskId == call.args["source_task_id"]?.toString() && existing.sourceRevision == (call.args["source_revision"] as? Number)?.toInt()) { "선행 작업이 변경되었습니다. 새 작업으로 요청하세요." }
            require(existing.tool == call.name) { "다른 종류의 작업입니다. 새 작업으로 요청하세요." }
            require(existing.argsJson == businessArgs(call).toString()) { "작업 내용이 변경되었습니다. 기존 작업을 명시적으로 취소하고 새 작업을 요청하세요." }
            tasks.focus(existing.id)
            existing
        } else {
            if (liveConversation && call.name == "save_life_memory") {
                require(!call.args["source_task_id"]?.toString().isNullOrBlank()) { "확인한 사진의 source_task_id와 source_revision이 필요합니다." }
            }
            tasks.submit(call.name, businessArgs(call).toString(), call.args["task_title"]?.toString()
                ?: "${call.name}: ${call.args["query"] ?: call.args["reason"] ?: call.args["title"] ?: "요청"}",
                call.args["source_task_id"]?.toString()?.takeIf { it.isNotBlank() },
                (call.args["source_revision"] as? Number)?.toInt())
        }
        submitted[call.id] = task.id
        val background = liveConversation && TaskPolicies.forTool(task.tool).background
        if (!background && task.state in setOf(TaskState.QUEUED, TaskState.RUNNING)) {
            tasks.tasks.first { list -> list.firstOrNull { it.id == task.id }?.state !in setOf(TaskState.QUEUED, TaskState.RUNNING) }
        }
        val latest = tasks.get(task.id) ?: error("작업 기록이 만료되었습니다.")
        val response = latest.toJson(true).put("task_context", tasks.contextJson())
        if (latest.state in setOf(TaskState.QUEUED, TaskState.RUNNING)) {
            response.put("accepted", true).put("instruction", "접수만 완료. 완료했다고 말하지 마세요. 다른 요청과 병행하며 결과는 보관됩니다. 반복 조회하지 마세요.")
        }
        if (!liveConversation && latest.state == TaskState.COMPLETED && latest.tool == "capture_current_view") presentArtifact(latest)
        if (latest.state in setOf(TaskState.COMPLETED, TaskState.FAILED)) onResultDelivered(latest)
        return ToolResult.Success(response.toString())
    }

    private fun requireTask(call: GeminiFunctionCall): TaskRecord {
        val id = call.args["task_id"]?.toString().orEmpty()
        val task = tasks.get(id) ?: error("작업을 찾을 수 없습니다. list_tasks로 확인하세요.")
        val revision = (call.args["expected_revision"] as? Number)?.toInt()
        require(revision == task.revision) { "작업 버전이 다릅니다. list_tasks로 현재 revision을 확인하세요." }
        return task
    }
    private fun businessArgs(call: GeminiFunctionCall): JSONObject = JSONObject().apply {
        call.args.toSortedMap().forEach { (key, value) ->
            if (key !in setOf("task_id", "expected_revision", "task_title", "source_task_id", "source_revision")) put(key, value)
        }
    }

    fun cancelToolCalls(ids: List<String>) {
        ids.forEach { id ->
            cancelled.add(id)
            // Read/capture tasks survive conversation interruption. Unfinished writes do not advance silently.
            submitted[id]?.let(tasks::get)?.let { task ->
                if (!TaskPolicies.forTool(task.tool).background && task.state in setOf(TaskState.QUEUED, TaskState.RUNNING)) {
                    tasks.control(task.id, task.revision, "hold")
                }
            }
            jobs[id]?.cancel()
        }
    }

    fun disconnect() {
        connected = false
        jobs.values.toList().forEach { it.cancel() }
        jobs.clear()
        // TaskManager is retained across Live reconnects; this router and its call IDs are not.
    }
}

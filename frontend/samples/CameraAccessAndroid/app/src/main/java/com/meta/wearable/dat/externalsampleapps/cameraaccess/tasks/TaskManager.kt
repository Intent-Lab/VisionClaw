package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Model chooses intent; this registry owns execution and result lifetime. No Android dependencies. */
enum class TaskState { QUEUED, RUNNING, WAITING_USER, HELD, COMPLETED, FAILED, CANCELLED, OUTCOME_UNKNOWN }
data class TaskRecord(
    val id: String,
    val revision: Int = 1,
    val tool: String,
    val argsJson: String,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long,
    val state: TaskState = TaskState.QUEUED,
    val result: String? = null,
    val error: String? = null,
    val dispatched: Boolean = false,
    val sourceTaskId: String? = null,
    val sourceRevision: Int? = null,
    val interpretation: String? = null,
    val resultTruncated: Boolean = false,
)
data class TaskOutcome(val result: String? = null, val error: String? = null, val waitingForUser: Boolean = false)
data class TaskPolicy(val background: Boolean, val resource: String? = null, val write: Boolean = false, val timeoutMs: Long = 60_000)

object TaskPolicies {
    private val policies = mapOf(
        "capture_current_view" to TaskPolicy(true, "camera", timeoutMs = 20_000),
        "universal_search" to TaskPolicy(true), "search_memory" to TaskPolicy(true),
        "search_people" to TaskPolicy(true), "search_meetings" to TaskPolicy(true),
        "get_proposal_context" to TaskPolicy(true), "search_contacts" to TaskPolicy(true, timeoutMs = 10_000),
        "call_contact" to TaskPolicy(false), "text_contact" to TaskPolicy(false),
        "save_person" to TaskPolicy(false, "database-write", true),
        "save_meeting" to TaskPolicy(false, "database-write", true),
        "save_memory" to TaskPolicy(false, "database-write", true),
        "save_life_memory" to TaskPolicy(false, "database-write", true),
        "save_need" to TaskPolicy(false, "database-write", true),
        "create_contact" to TaskPolicy(false, "device-action", true),
        "create_calendar_event" to TaskPolicy(false, "device-action", true),
        "resolve_contact_action" to TaskPolicy(false, "device-action", true),
        "control_meeting_recording" to TaskPolicy(false, "microphone", true),
    )
    fun forTool(name: String): TaskPolicy = policies[name] ?: error("Unsupported task tool: $name")
}

interface TaskStore {
    suspend fun load(): List<TaskRecord>
    suspend fun save(tasks: List<TaskRecord>)
}

class TaskManager(
    private val scope: CoroutineScope,
    private val store: TaskStore,
    private val execute: suspend (TaskRecord, Execution) -> TaskOutcome,
    private val now: () -> Long = System::currentTimeMillis,
    private val retentionMs: Long = 24 * 60 * 60 * 1000L,
    private val maxRecords: Int = 80,
) {
    private val lock = Any()
    private val records = linkedMapOf<String, TaskRecord>()
    private val jobs = mutableMapOf<String, Job>()
    private val resources = mutableMapOf<String, Mutex>()
    private val persistence = Mutex()
    private val writes = Channel<Unit>(Channel.CONFLATED)
    private var initialized = false
    private val _tasks = MutableStateFlow<List<TaskRecord>>(emptyList())
    val tasks = _tasks.asStateFlow()
    @Volatile var focusTaskId: String? = null
        private set
    @Volatile var storageError: String? = null
        private set

    init {
        scope.launch {
            for (ignored in writes) {
                try { persist() } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    storageError = "작업 기록 저장 실패: ${e.message}"
                }
            }
        }
    }

    suspend fun initialize() = persistence.withLock {
        if (initialized) return@withLock
        val loaded = store.load()
        synchronized(lock) {
            loaded.filter { it.state !in setOf(TaskState.COMPLETED, TaskState.FAILED, TaskState.CANCELLED) || now() - it.updatedAt < retentionMs }.takeLast(maxRecords).forEach { old ->
                // A process restart cannot prove whether a dispatched write reached the server.
                val state = when (old.state) {
                    TaskState.RUNNING, TaskState.QUEUED -> if (old.dispatched) TaskState.OUTCOME_UNKNOWN else TaskState.HELD
                    else -> old.state
                }
                records[old.id] = old.copy(state = state)
            }
            initialized = true
            publish()
        }
    }

    suspend fun persist() = persistence.withLock {
        store.save(snapshot())
        storageError = null
    }

    fun snapshot(): List<TaskRecord> = synchronized(lock) { records.values.toList() }
    fun get(id: String): TaskRecord? = synchronized(lock) { records[id] }
    fun onNewUserInput() = synchronized(lock) {
        focusTaskId = null
        records.values.toList().filter {
            TaskPolicies.forTool(it.tool).write && !it.dispatched && it.state in setOf(TaskState.QUEUED, TaskState.RUNNING)
        }.forEach { control(it.id, it.revision, "hold") }
    }
    fun focus(id: String) { require(get(id) != null); focusTaskId = id }

    fun submit(tool: String, argsJson: String, title: String, sourceId: String? = null, sourceRevision: Int? = null): TaskRecord = synchronized(lock) {
        check(initialized) { "작업 기록을 불러오는 중입니다." }
        TaskPolicies.forTool(tool)
        require(argsJson.length <= 16_000) { "작업 입력이 너무 큽니다. 요청을 나누어 주세요." }
        if (sourceId != null) {
            val source = records[sourceId] ?: error("선행 작업이 없습니다.")
            require(source.revision == sourceRevision) { "선행 작업 버전이 변경되었습니다." }
            require(source.state == TaskState.COMPLETED) { "선행 작업 완료 후 다시 요청하세요: ${source.state}" }
        }
        prune()
        check(records.size < maxRecords) { "보관 가능한 작업 수를 초과했습니다. 이전 작업을 정리해주세요." }
        val timestamp = now()
        val task = TaskRecord(UUID.randomUUID().toString(), tool = tool, argsJson = argsJson,
            title = title.take(160), createdAt = timestamp, updatedAt = timestamp,
            sourceTaskId = sourceId, sourceRevision = sourceRevision)
        records[task.id] = task
        focusTaskId = task.id
        publish()
        launchTask(task)
        task
    }

    /** Only explicit model/user control changes a business task. Speech interruption does not. */
    fun control(id: String, expectedRevision: Int, action: String): TaskRecord = synchronized(lock) {
        val task = records[id] ?: error("작업을 찾을 수 없습니다.")
        require(task.revision == expectedRevision) { "작업 버전이 변경되었습니다. 상태를 다시 조회하세요." }
        when (action) {
            "cancel", "hold" -> {
                require(task.state != TaskState.OUTCOME_UNKNOWN &&
                    (task.state != TaskState.COMPLETED || (action == "cancel" && TaskPolicies.forTool(task.tool).background && !task.dispatched))) {
                    "이미 완료되었거나 실행 여부가 불명확합니다. 취소됐다고 보고하지 마세요."
                }
                val state = if (task.dispatched) TaskState.OUTCOME_UNKNOWN
                    else if (action == "hold") TaskState.HELD else TaskState.CANCELLED
                // Invalidate before cancellation so a late result cannot overwrite this state.
                records[id] = task.copy(revision = task.revision + 1, state = state, updatedAt = now(),
                    result = null, interpretation = null, error = if (task.dispatched) "외부 실행 결과 확인 필요. 자동 재시도 금지." else null)
                jobs[id]?.cancel()
                if (focusTaskId == id) focusTaskId = null
            }
            "resume" -> {
                require(task.state == TaskState.HELD || task.state == TaskState.FAILED) { "보류 또는 실패한 작업만 재개할 수 있습니다." }
                require(!task.dispatched) { "외부 변경이 전송된 작업은 반복 실행하지 않습니다. 실행 결과를 먼저 확인하세요." }
                require(jobs[id]?.isCompleted != false) { "이전 동작이 종료되는 중입니다. 잠시 후 재개하세요." }
                val resumed = task.copy(revision = task.revision + 1, state = TaskState.QUEUED,
                    result = null, error = null, updatedAt = now())
                records[id] = resumed
                focusTaskId = id
                launchTask(resumed)
            }
            "focus" -> focusTaskId = id
            else -> error("지원하지 않는 작업 제어입니다.")
        }
        publish()
        records.getValue(id)
    }

    fun recordInterpretation(id: String, revision: Int, text: String): TaskRecord = synchronized(lock) {
        val task = records[id] ?: error("작업을 찾을 수 없습니다.")
        require(task.revision == revision && task.state == TaskState.COMPLETED) { "완료된 현재 버전의 작업에만 해석을 보관할 수 있습니다." }
        require(text.isNotBlank() && text.length <= 12_000) { "해석은 1~12000자로 입력하세요." }
        records[id] = task.copy(interpretation = text, updatedAt = now())
        publish()
        records.getValue(id)
    }

    /** Session exit stops hardware/read work, but preserves records and uncertain write outcomes. */
    fun suspendActive() = synchronized(lock) {
        records.values.toList().filter { it.state in setOf(TaskState.QUEUED, TaskState.RUNNING) }.forEach {
            control(it.id, it.revision, "hold")
        }
        focusTaskId = null
    }

    suspend fun claimWaiting(id: String, revision: Int): TaskRecord {
        synchronized(lock) {
            val task = records[id] ?: error("확인할 작업이 없습니다.")
            require(task.revision == revision && task.state == TaskState.WAITING_USER && !task.dispatched) { "확인 요청이 변경되었거나 이미 처리되었습니다." }
            records[id] = task.copy(state = TaskState.RUNNING, dispatched = true, updatedAt = now())
            publish()
        }
        persist()
        return synchronized(lock) {
            val task = records.getValue(id)
            check(task.revision == revision && task.state == TaskState.RUNNING) { "확인 요청이 취소되었습니다." }
            task
        }
    }

    fun completeWaiting(id: String, revision: Int, outcome: TaskOutcome) = synchronized(lock) {
        val task = records[id] ?: error("확인할 작업이 없습니다.")
        require(task.revision == revision && task.state in setOf(TaskState.WAITING_USER, TaskState.RUNNING)) { "확인 요청이 변경되었거나 취소되었습니다." }
        records[id] = task.copy(state = if (outcome.error == null) TaskState.COMPLETED else if (task.dispatched) TaskState.OUTCOME_UNKNOWN else TaskState.FAILED,
            result = outcome.result, error = outcome.error, updatedAt = now())
        publish()
    }

    inner class Execution internal constructor(private val id: String, private val revision: Int) {
        fun checkCurrent() = synchronized(lock) {
            val task = records[id]
            if (task == null || task.revision != revision || task.state != TaskState.RUNNING) throw CancellationException("Task superseded")
            task.sourceTaskId?.let { sourceId ->
                val source = records[sourceId]
                check(source != null && source.revision == task.sourceRevision && source.state == TaskState.COMPLETED) { "선행 작업 결과가 더 이상 유효하지 않습니다." }
            }
        }
        /** Durably mark the uncertainty boundary BEFORE dispatching an external change. */
        suspend fun beforeExternalEffect() {
            currentCoroutineContext().ensureActive()
            synchronized(lock) {
                checkCurrent()
                records[id] = records.getValue(id).copy(dispatched = true, updatedAt = now())
                publish()
            }
            persist() // If local journaling fails, do not dispatch the write.
            currentCoroutineContext().ensureActive()
            checkCurrent()
        }
    }

    private fun launchTask(task: TaskRecord) {
        val policy = TaskPolicies.forTool(task.tool)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val execution = Execution(task.id, task.revision)
            try {
                val work: suspend () -> TaskOutcome = {
                    synchronized(lock) {
                        val current = records[task.id]
                        if (current?.revision != task.revision || current.state != TaskState.QUEUED) throw CancellationException()
                        records[task.id] = current.copy(state = TaskState.RUNNING, updatedAt = now())
                        publish()
                    }
                    execution.checkCurrent()
                    withTimeout(policy.timeoutMs) { execute(task, execution) }
                }
                val outcome = if (policy.resource == null) work() else {
                    val mutex = synchronized(lock) { resources.getOrPut(policy.resource) { Mutex() } }
                    mutex.withLock { work() }
                }
                finish(task, outcome)
            } catch (e: TimeoutCancellationException) {
                finish(task, TaskOutcome(error = "작업 제한 시간을 초과했습니다."))
            } catch (e: CancellationException) {
                synchronized(lock) {
                    val current = records[task.id]
                    if (current?.revision == task.revision && current.state in setOf(TaskState.RUNNING, TaskState.QUEUED)) {
                        records[task.id] = current.copy(state = if (current.dispatched) TaskState.OUTCOME_UNKNOWN else TaskState.HELD,
                            updatedAt = now(), error = "작업이 중단되었습니다.")
                        publish()
                    }
                }
                throw e
            } catch (e: Exception) {
                finish(task, TaskOutcome(error = e.message ?: "작업 실패"))
            } finally {
                synchronized(lock) {
                    if (jobs[task.id] === coroutineContext[Job]) jobs.remove(task.id)
                }
            }
        }
        jobs[task.id] = job
        job.start()
    }

    private fun finish(start: TaskRecord, outcome: TaskOutcome) = synchronized(lock) {
        val current = records[start.id] ?: return@synchronized
        if (current.revision != start.revision || current.state != TaskState.RUNNING) return@synchronized
        records[start.id] = current.copy(
            state = when {
                outcome.error != null && current.dispatched -> TaskState.OUTCOME_UNKNOWN
                outcome.error != null -> TaskState.FAILED
                outcome.waitingForUser -> TaskState.WAITING_USER
                else -> TaskState.COMPLETED
            }, result = outcome.result?.take(64_000), resultTruncated = (outcome.result?.length ?: 0) > 64_000, error = outcome.error?.take(2000), updatedAt = now())
        publish()
    }

    private fun prune() {
        val terminal = setOf(TaskState.COMPLETED, TaskState.FAILED, TaskState.CANCELLED)
        records.values.toList().filter { it.state in terminal && now() - it.updatedAt >= retentionMs }.forEach { records.remove(it.id) }
        while (records.size >= maxRecords) {
            val oldest = records.values.firstOrNull { it.state in terminal } ?: break
            records.remove(oldest.id)
        }
    }
    private fun publish() {
        _tasks.value = records.values.toList()
        writes.trySend(Unit)
    }
}

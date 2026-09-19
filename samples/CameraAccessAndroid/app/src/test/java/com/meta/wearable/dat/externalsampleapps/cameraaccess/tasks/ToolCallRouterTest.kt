package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ToolCallRouterTest {
    private class MemoryStore : TaskStore {
        override suspend fun load() = emptyList<TaskRecord>()
        override suspend fun save(tasks: List<TaskRecord>) = Unit
    }
    private fun test(block: suspend CoroutineScope.() -> Unit) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try { scope.block() } finally { scope.cancel() }
    }
    private fun JSONObject.payload(): JSONObject = getJSONObject("toolResponse").getJSONArray("functionResponses").getJSONObject(0).getJSONObject("response")

    @Test fun duplicateCallIdDoesNotStartTwoOperationsAndProtocolCancelDoesNotCancelBackgroundRead() = test {
        val gate = CompletableDeferred<Unit>()
        var starts = 0
        val tasks = TaskManager(this, MemoryStore(), { _, _ -> starts++; gate.await(); TaskOutcome(result = "cached") })
        tasks.initialize()
        val replies = mutableListOf<JSONObject>()
        var finished = 0
        val router = ToolCallRouter(tasks, this, true, {}, { replies.add(it) }, { finished++ })
        val call = GeminiFunctionCall("call-1", "universal_search", mapOf("query" to "김민수"))
        router.handleToolCall(call)
        router.handleToolCall(call)
        assertEquals(1, starts)
        assertEquals(2, replies.size)
        assertTrue(JSONObject(replies.first().payload().getString("result")).getBoolean("accepted"))
        router.cancelToolCalls(listOf("call-1"))
        router.disconnect()
        gate.complete(Unit)
        assertEquals(TaskState.COMPLETED, tasks.snapshot().single().state)
        assertEquals("cached", tasks.snapshot().single().result)
        assertEquals(2, replies.size) // No late reply using an invalid protocol call ID.
        assertEquals(2, finished)
    }

    @Test fun cachedPhotoIsOnlyPresentedByAnExplicitResultRequestAndWrongRevisionFails() = test {
        val tasks = TaskManager(this, MemoryStore(), { _, _ -> TaskOutcome(result = "photo cached") })
        tasks.initialize()
        val replies = mutableListOf<JSONObject>()
        var presented = 0
        val router = ToolCallRouter(tasks, this, true, { presented++ }, { replies.add(it) }, {})
        router.handleToolCall(GeminiFunctionCall("capture", "capture_current_view", emptyMap()))
        val photo = tasks.snapshot().single()
        assertEquals(0, presented)
        router.handleToolCall(GeminiFunctionCall("wrong", "get_task_result", mapOf("task_id" to photo.id, "expected_revision" to 99)))
        assertTrue(replies.last().payload().has("error"))
        assertEquals(0, presented)
        router.handleToolCall(GeminiFunctionCall("right", "get_task_result", mapOf("task_id" to photo.id, "expected_revision" to 1)))
        assertEquals(1, presented)
        assertEquals("photo cached", JSONObject(replies.last().payload().getString("result")).getString("result"))
    }

    @Test fun protocolCancellationHoldsUncommittedWriteAndSuppressesItsResponse() = test {
        val gate = CompletableDeferred<Unit>()
        var dispatched = false
        val tasks = TaskManager(this, MemoryStore(), { _, execution ->
            gate.await()
            execution.beforeExternalEffect()
            dispatched = true
            TaskOutcome(result = "saved")
        })
        tasks.initialize()
        val replies = mutableListOf<JSONObject>()
        val router = ToolCallRouter(tasks, this, true, {}, { replies.add(it) }, {})
        router.handleToolCall(GeminiFunctionCall("save", "save_memory", mapOf("text" to "test")))
        router.cancelToolCalls(listOf("save"))
        gate.complete(Unit)
        assertFalse(dispatched)
        assertEquals(TaskState.HELD, tasks.snapshot().single().state)
        assertTrue(replies.isEmpty())
    }

    @Test fun repeatWithTaskIdReusesResultButChangedArgumentsAreRejected() = test {
        var starts = 0
        val tasks = TaskManager(this, MemoryStore(), { _, _ -> starts++; TaskOutcome(result = "one") })
        tasks.initialize()
        val replies = mutableListOf<JSONObject>()
        val router = ToolCallRouter(tasks, this, true, {}, { replies.add(it) }, {})
        router.handleToolCall(GeminiFunctionCall("first", "universal_search", mapOf("query" to "민수")))
        val task = tasks.snapshot().single()
        router.handleToolCall(GeminiFunctionCall("retry", "universal_search", mapOf("query" to "민수", "task_id" to task.id, "expected_revision" to 1)))
        assertEquals(1, starts)
        router.handleToolCall(GeminiFunctionCall("changed", "universal_search", mapOf("query" to "민준", "task_id" to task.id, "expected_revision" to 1)))
        assertTrue(replies.last().payload().has("error"))
        assertEquals(1, starts)
    }

    @Test fun interpretationIsCachedSeparatelyFromPhysicalOperationResult() = test {
        val tasks = TaskManager(this, MemoryStore(), { _, _ -> TaskOutcome(result = "captured") })
        tasks.initialize()
        val photo = tasks.submit("capture_current_view", "{}", "명함")
        val replies = mutableListOf<JSONObject>()
        val router = ToolCallRouter(tasks, this, true, {}, { replies.add(it) }, {})
        router.handleToolCall(GeminiFunctionCall("interpret", "record_task_result", mapOf("task_id" to photo.id, "expected_revision" to 1, "interpretation" to "김민수의 명함")))
        assertEquals("captured", tasks.get(photo.id)!!.result)
        assertEquals("김민수의 명함", tasks.get(photo.id)!!.interpretation)
        assertEquals(TaskState.COMPLETED, tasks.get(photo.id)!!.state)
    }

    @Test fun toolSchemaExposesWorkControlsAndRequiresAnExactPhotoForSaving() {
        val declarations = ToolDeclarations.allDeclarationsJSON(true)
        val tools = (0 until declarations.length()).associate { declarations.getJSONObject(it).getString("name") to declarations.getJSONObject(it) }
        assertTrue(tools.keys.containsAll(listOf("list_tasks", "get_task_result", "update_task", "record_task_result")))
        val required = tools.getValue("save_life_memory").getJSONObject("parameters").getJSONArray("required")
        assertTrue((0 until required.length()).map { required.getString(it) }.containsAll(listOf("source_task_id", "source_revision")))
        assertEquals("BLOCKING", tools.getValue("universal_search").getString("behavior"))
    }
}

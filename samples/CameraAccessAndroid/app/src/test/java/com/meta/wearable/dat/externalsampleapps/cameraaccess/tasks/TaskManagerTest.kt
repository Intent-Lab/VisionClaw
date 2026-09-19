package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

class TaskManagerTest {
    private class MemoryStore(var data: List<TaskRecord> = emptyList()) : TaskStore {
        override suspend fun load() = data
        override suspend fun save(tasks: List<TaskRecord>) { data = tasks }
    }
    private suspend fun TaskManager.until(id: String, state: TaskState): TaskRecord = withTimeout(2000) {
        tasks.first { list -> list.any { it.id == id && it.state == state } }.first { it.id == id }
    }
    private fun test(block: suspend CoroutineScope.() -> Unit) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try { scope.block() } finally { scope.cancel() }
    }

    @Test fun independentSearchFinishesWhileCameraIsBusyAndResultsStaySeparate() = test {
        val camera = CompletableDeferred<Unit>()
        val manager = TaskManager(this, MemoryStore(), { task, _ ->
            if (task.tool == "capture_current_view") camera.await()
            TaskOutcome(result = task.title)
        })
        manager.initialize()
        val photo = manager.submit("capture_current_view", "{}", "명함 사진")
        val search = manager.submit("universal_search", "{}", "김민수 검색")
        assertEquals("김민수 검색", manager.until(search.id, TaskState.COMPLETED).result)
        assertEquals(TaskState.RUNNING, manager.get(photo.id)!!.state)
        manager.onNewUserInput()
        camera.complete(Unit)
        assertEquals("명함 사진", manager.until(photo.id, TaskState.COMPLETED).result)
        assertNull(manager.focusTaskId)
    }

    @Test fun cancelledHardwareKeepsResourceUntilItActuallyReturnsAndCannotPublishLateResult() = test {
        val shutter = CompletableDeferred<Unit>()
        var starts = 0
        val manager = TaskManager(this, MemoryStore(), { _, _ ->
            starts++
            if (starts == 1) withContext(NonCancellable) { shutter.await() }
            TaskOutcome(result = "photo")
        })
        manager.initialize()
        val first = manager.submit("capture_current_view", "{}", "A")
        manager.control(first.id, 1, "cancel")
        val second = manager.submit("capture_current_view", "{}", "B")
        assertEquals(1, starts)
        assertEquals(TaskState.QUEUED, manager.get(second.id)!!.state)
        shutter.complete(Unit)
        manager.until(second.id, TaskState.COMPLETED)
        assertEquals(TaskState.CANCELLED, manager.get(first.id)!!.state)
        assertNull(manager.get(first.id)!!.result)
        assertEquals(2, starts)
    }

    @Test fun staleRevisionCannotCancelResumedWork() = test {
        val gate = CompletableDeferred<Unit>()
        val manager = TaskManager(this, MemoryStore(), { _, _ -> gate.await(); TaskOutcome(result = "ok") })
        manager.initialize()
        val task = manager.submit("universal_search", "{}", "검색")
        manager.control(task.id, 1, "hold")
        val resumed = manager.control(task.id, 2, "resume")
        assertEquals(3, resumed.revision)
        assertThrows(IllegalArgumentException::class.java) { manager.control(task.id, 1, "cancel") }
        gate.complete(Unit)
        manager.until(task.id, TaskState.COMPLETED)
    }

    @Test fun sentWriteCancelledBecomesUnknownAndCannotBeRetried() = test {
        val gate = CompletableDeferred<Unit>()
        val store = MemoryStore()
        val manager = TaskManager(this, store, { _, execution ->
            execution.beforeExternalEffect()
            gate.await()
            TaskOutcome(result = "saved")
        })
        manager.initialize()
        val task = manager.submit("save_memory", "{}", "저장")
        assertTrue(store.data.single().dispatched)
        manager.control(task.id, 1, "cancel")
        assertEquals(TaskState.OUTCOME_UNKNOWN, manager.get(task.id)!!.state)
        assertThrows(IllegalArgumentException::class.java) { manager.control(task.id, 2, "resume") }
    }

    @Test fun aNewUtteranceHoldsQueuedWritesButKeepsIndependentReads() = test {
        val gate = CompletableDeferred<Unit>()
        val manager = TaskManager(this, MemoryStore(), { task, execution ->
            if (task.tool == "save_memory") execution.beforeExternalEffect()
            gate.await()
            TaskOutcome(result = "done")
        })
        manager.initialize()
        val first = manager.submit("save_memory", "{}", "저장 A")
        val queued = manager.submit("save_person", "{}", "저장 B")
        val search = manager.submit("universal_search", "{}", "검색")
        manager.onNewUserInput()
        assertEquals(TaskState.HELD, manager.get(queued.id)!!.state)
        assertEquals(TaskState.RUNNING, manager.get(search.id)!!.state)
        assertEquals(TaskState.RUNNING, manager.get(first.id)!!.state)
        gate.complete(Unit)
    }

    @Test fun restoreDoesNotReplayRunningTasksOrForgetUncertainWritesAfterTtl() = test {
        val store = MemoryStore(listOf(
            TaskRecord("read", tool = "universal_search", argsJson = "{}", title = "read", createdAt = 0, updatedAt = 0, state = TaskState.RUNNING),
            TaskRecord("write", tool = "save_memory", argsJson = "{}", title = "write", createdAt = 0, updatedAt = 0, state = TaskState.RUNNING, dispatched = true),
            TaskRecord("old", tool = "universal_search", argsJson = "{}", title = "old", createdAt = 0, updatedAt = 0, state = TaskState.COMPLETED)
        ))
        var executions = 0
        val manager = TaskManager(this, store, { _, _ -> executions++; TaskOutcome() }, now = { 1000 }, retentionMs = 100)
        manager.initialize()
        assertEquals(TaskState.HELD, manager.get("read")!!.state)
        assertEquals(TaskState.OUTCOME_UNKNOWN, manager.get("write")!!.state)
        assertNull(manager.get("old"))
        assertEquals(0, executions)
    }

    @Test fun aDependencyMustBeCompletedAndMatchTheReferencedVersion() = test {
        val gate = CompletableDeferred<Unit>()
        val manager = TaskManager(this, MemoryStore(), { _, _ -> gate.await(); TaskOutcome(result = "image") })
        manager.initialize()
        val photo = manager.submit("capture_current_view", "{}", "photo")
        assertThrows(IllegalArgumentException::class.java) { manager.submit("save_life_memory", "{}", "save", photo.id, 1) }
        gate.complete(Unit)
        manager.until(photo.id, TaskState.COMPLETED)
        assertThrows(IllegalArgumentException::class.java) { manager.submit("save_life_memory", "{}", "save", photo.id, 2) }
        assertEquals(photo.id, manager.submit("save_life_memory", "{}", "save", photo.id, 1).sourceTaskId)
    }

    @Test fun pendingApprovalCannotBeClaimedTwiceOrAfterCancel() = test {
        val manager = TaskManager(this, MemoryStore(), { _, _ -> TaskOutcome(result = "confirm?", waitingForUser = true) })
        manager.initialize()
        val task = manager.submit("text_contact", "{}", "문자")
        manager.until(task.id, TaskState.WAITING_USER)
        manager.claimWaiting(task.id, 1)
        try { manager.claimWaiting(task.id, 1); fail("duplicate claim") } catch (_: IllegalArgumentException) { }
        manager.completeWaiting(task.id, 1, TaskOutcome(result = "sent"))
        assertThrows(IllegalArgumentException::class.java) { manager.control(task.id, 1, "cancel") }
    }

    @Test fun storageFailurePreventsDispatch() = test {
        var sent = false
        val store = object : TaskStore {
            override suspend fun load() = emptyList<TaskRecord>()
            override suspend fun save(tasks: List<TaskRecord>) { error("disk full") }
        }
        val manager = TaskManager(this, store, { _, execution -> execution.beforeExternalEffect(); sent = true; TaskOutcome() })
        manager.initialize()
        val task = manager.submit("save_memory", "{}", "save")
        manager.until(task.id, TaskState.OUTCOME_UNKNOWN)
        assertFalse(sent)
    }

    @Test fun historyRoundTripsWithoutReplayingAnExternalWrite() = test {
        val directory = kotlin.io.path.createTempDirectory("task-store-test").toFile()
        try {
            val store = FileTaskStore(File(directory, "history.json"))
            val task = TaskRecord("task-1", tool = "save_memory", argsJson = "{\"text\":\"한국어\"}", title = "보관", createdAt = 1, updatedAt = 2,
                state = TaskState.COMPLETED, result = "저장 완료", dispatched = true)
            store.save(listOf(task))
            assertEquals(listOf(task), store.load())
        } finally { directory.deleteRecursively() }
    }
    @Test fun cancelledCompletedPhotoCannotBeUsedForANewSave() = test {
        val manager = TaskManager(this, MemoryStore(), { _, _ -> TaskOutcome(result = "photo") })
        manager.initialize()
        val photo = manager.submit("capture_current_view", "{}", "photo")
        manager.until(photo.id, TaskState.COMPLETED)
        manager.control(photo.id, 1, "cancel")
        assertThrows(IllegalArgumentException::class.java) { manager.submit("save_life_memory", "{}", "save", photo.id, 1) }
        assertNull(manager.get(photo.id)!!.result)
    }

    @Test fun anExplicitResumeCanRunAHeldWriteThatWasNeverDispatched() = test {
        val gate = CompletableDeferred<Unit>()
        var sent = 0
        val manager = TaskManager(this, MemoryStore(), { _, execution ->
            gate.await()
            execution.beforeExternalEffect()
            sent++
            TaskOutcome(result = "saved")
        })
        manager.initialize()
        val task = manager.submit("save_memory", "{}", "save")
        manager.onNewUserInput()
        assertEquals(TaskState.HELD, manager.get(task.id)!!.state)
        gate.complete(Unit)
        manager.control(task.id, 2, "resume")
        manager.until(task.id, TaskState.COMPLETED)
        assertEquals(1, sent)
    }

    @Test fun capacityEvictsOldCompletedResultsButKeepsPendingWork() = test {
        val gate = CompletableDeferred<Unit>()
        val manager = TaskManager(this, MemoryStore(), { task, _ ->
            if (task.tool == "capture_current_view") gate.await()
            TaskOutcome(result = "ok")
        }, maxRecords = 2)
        manager.initialize()
        val pending = manager.submit("capture_current_view", "{}", "pending")
        val old = manager.submit("universal_search", "{}", "old")
        manager.until(old.id, TaskState.COMPLETED)
        manager.submit("universal_search", "{}", "new")
        assertNull(manager.get(old.id))
        assertEquals(TaskState.RUNNING, manager.get(pending.id)!!.state)
        assertEquals(2, manager.snapshot().size)
        gate.complete(Unit)
    }

    @Test fun approvalCancelledBeforeClaimCannotExecute() = test {
        val manager = TaskManager(this, MemoryStore(), { _, _ -> TaskOutcome(result = "confirm?", waitingForUser = true) })
        manager.initialize()
        val task = manager.submit("call_contact", "{}", "call")
        manager.until(task.id, TaskState.WAITING_USER)
        manager.control(task.id, 1, "cancel")
        try { manager.claimWaiting(task.id, 1); fail("cancelled approval") } catch (_: IllegalArgumentException) { }
        assertFalse(manager.get(task.id)!!.dispatched)
    }

}

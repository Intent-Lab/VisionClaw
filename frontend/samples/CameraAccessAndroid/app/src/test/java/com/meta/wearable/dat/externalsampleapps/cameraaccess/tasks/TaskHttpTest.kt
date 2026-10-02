package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import java.io.IOException
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Timeout
import org.junit.Assert.*
import org.junit.Test

class TaskHttpTest {
    private class FakeCall : Call {
        lateinit var callback: Callback
        var cancelled = false
        override fun request() = Request.Builder().url("http://localhost/task-test").build()
        override fun enqueue(responseCallback: Callback) { callback = responseCallback }
        override fun execute(): Response = error("Unexpected blocking HTTP")
        override fun cancel() { cancelled = true }
        override fun isExecuted() = ::callback.isInitialized
        override fun isCanceled() = cancelled
        override fun clone(): Call = FakeCall()
        override fun timeout() = Timeout()
        fun respond(code: Int, body: String) {
            callback.onResponse(this, Response.Builder().request(request()).protocol(Protocol.HTTP_1_1)
                .code(code).message("test").body(body.toResponseBody()).build())
        }
    }

    @Test fun cancellationStopsHttpEvenIfItsCallbackArrivesLater() = runBlocking {
        val call = FakeCall()
        val result = async(start = CoroutineStart.UNDISPATCHED) { call.awaitTaskResponse() }
        result.cancelAndJoin()
        assertTrue(call.cancelled)
        call.respond(200, "late result")
        assertTrue(result.isCancelled)
    }

    @Test fun serverFailureIsNotConvertedToSuccess() = runBlocking {
        val call = FakeCall()
        val result = async(start = CoroutineStart.UNDISPATCHED) { call.awaitTaskResponse() }
        call.respond(503, "busy")
        assertEquals(TaskHttpResponse(503, "busy"), result.await())
        assertFalse(call.cancelled)
    }

    @Test fun transportFailureIsPropagatedToTheTask() = runBlocking {
        supervisorScope {
            val call = FakeCall()
            val result = async(start = CoroutineStart.UNDISPATCHED) { call.awaitTaskResponse() }
            call.callback.onFailure(call, IOException("connection lost"))
            try { result.await(); fail("failure lost") } catch (e: IOException) { assertEquals("connection lost", e.message) }
        }
    }
}

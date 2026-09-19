package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

internal data class TaskHttpResponse(val code: Int, val body: String)

/** Cancelling a coroutine also cancels its HTTP call; this does not undo a server-side write. */
internal suspend fun Call.awaitTaskResponse(): TaskHttpResponse = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (continuation.isActive) continuation.resumeWithException(e)
        }
        override fun onResponse(call: Call, response: Response) {
            try {
                val result = response.use { TaskHttpResponse(it.code, it.body?.string().orEmpty()) }
                if (continuation.isActive) continuation.resume(result)
            } catch (e: Exception) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }
        }
    })
}

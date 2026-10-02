package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import com.google.gson.Gson
import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.VisualMemoryFrameStore.VisualFrame
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class TaskArtifacts(private val directory: File) {
    private val gson = Gson()
    private fun file(id: String, revision: Int): File {
        require(id.matches(Regex("[a-zA-Z0-9-]+")) && revision > 0)
        return File(directory, "$id-$revision.json")
    }
    suspend fun put(id: String, revision: Int, frame: VisualFrame) = withContext(Dispatchers.IO) {
        directory.mkdirs()
        val files = directory.listFiles().orEmpty().filter { it.extension == "json" }.sortedBy { it.lastModified() }
        files.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000L }.forEach { it.delete() }
        var total = directory.listFiles().orEmpty().sumOf { it.length() }
        for (old in files) {
            if (total + frame.base64.length < 48_000_000) break
            val size = old.length()
            if (old.delete()) total -= size
        }
        require(frame.base64.length <= 12_000_000) { "사진 크기가 보관 한도를 초과했습니다." }
        val target = file(id, revision)
        val temp = File(target.path + ".tmp")
        temp.writeText(gson.toJson(frame))
        check(temp.renameTo(target))
    }
    suspend fun get(id: String, revision: Int): VisualFrame? = withContext(Dispatchers.IO) {
        val target = file(id, revision)
        if (!target.exists()) return@withContext null
        if (System.currentTimeMillis() - target.lastModified() > 86_400_000L) {
            target.delete()
            return@withContext null
        }
        gson.fromJson(target.readText(), VisualFrame::class.java)
    }
}

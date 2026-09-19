package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import com.google.gson.Gson
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** App-private, bounded task history. Atomic replacement leaves the prior file intact on failure. */
class FileTaskStore(private val file: File) : TaskStore {
    private val gson = Gson()
    override suspend fun load(): List<TaskRecord> = withContext(Dispatchers.IO) {
        if (!file.exists()) emptyList() else {
            require(file.length() <= 32_000_000) { "작업 기록 파일 크기가 올바르지 않습니다." }
            gson.fromJson(file.readText(), Array<TaskRecord>::class.java).toList()
        }
    }
    override suspend fun save(tasks: List<TaskRecord>) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.outputStream().use { stream ->
            stream.write(gson.toJson(tasks).toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        }
        check(temp.renameTo(file)) { "작업 기록 파일 교체 실패" }
    }
}

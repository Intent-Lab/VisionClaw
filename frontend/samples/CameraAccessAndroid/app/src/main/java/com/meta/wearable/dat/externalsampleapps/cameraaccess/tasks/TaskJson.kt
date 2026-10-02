package com.meta.wearable.dat.externalsampleapps.cameraaccess.tasks

import org.json.JSONArray
import org.json.JSONObject

fun TaskRecord.toJson(includeResult: Boolean = false): JSONObject = JSONObject().apply {
    put("task_id", id)
    put("revision", revision)
    put("tool", tool)
    put("title", title)
    put("state", state.name.lowercase())
    put("created_at_ms", createdAt)
    put("updated_at_ms", updatedAt)
    put("source_task_id", sourceTaskId)
    put("source_revision", sourceRevision)
    put("external_effect_dispatched", dispatched)
    put("error", error)
    put("result_truncated", resultTruncated)
    if (tool == "capture_current_view" && state in setOf(TaskState.CANCELLED, TaskState.HELD)) {
        put("cancellation_note", "사진 결과 사용과 후속 처리를 중단합니다. 이미 글라스에 전달된 셔터 동작의 중단은 보장되지 않습니다.")
    }
    if (includeResult) {
        put("result", result)
        put("interpretation", interpretation)
    }
}
fun TaskManager.contextJson(): JSONObject = JSONObject().apply {
    put("focus_task_id", focusTaskId)
    put("storage_error", storageError)
    put("tasks", JSONArray(snapshot().takeLast(12).map { it.toJson() }))
}
fun parseTaskArgs(json: String): Map<String, Any?> {
    val obj = JSONObject(json)
    return obj.keys().asSequence().associateWith { obj.opt(it) }
}

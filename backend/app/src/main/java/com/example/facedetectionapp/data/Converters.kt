package com.example.facedetectionapp.data

import android.util.Base64
import androidx.room.TypeConverter
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken

class Converters {
    private val gson = Gson()

    @TypeConverter
    fun fromEmbeddingList(value: List<FloatArray>?): String {
        return gson.toJson(value)
    }

    @TypeConverter
    fun toEmbeddingList(value: String): List<FloatArray> {
        // [수정된 핵심 로직]
        // JSON에서 숫자는 기본적으로 Double로 인식됩니다.
        // 그래서 바로 FloatArray로 바꾸려 하면 에러(ClassCastException)가 납니다.
        // 1. 먼저 Double 리스트로 받습니다.
        val listType = object : TypeToken<List<List<Double>>>() {}.type
        val doubleList: List<List<Double>>? = gson.fromJson(value, listType)

        // 2. 그걸 FloatArray로 하나씩 안전하게 변환합니다.
        return doubleList?.map { list ->
            list.map { it.toFloat() }.toFloatArray()
        } ?: emptyList()
    }

    @TypeConverter
    fun fromThumbnailList(value: List<ByteArray>?): String {
        if (value.isNullOrEmpty()) return "[]"
        val base64List = value.map { Base64.encodeToString(it, Base64.DEFAULT) }
        return gson.toJson(base64List)
    }

    @TypeConverter
    fun toThumbnailList(value: String): List<ByteArray> {
        if (value == "[]" || value.isBlank()) return emptyList()
        val listType = object : TypeToken<List<String>>() {}.type
        val base64List: List<String> = gson.fromJson(value, listType) ?: return emptyList()
        return base64List.map { Base64.decode(it, Base64.DEFAULT) }
    }
}
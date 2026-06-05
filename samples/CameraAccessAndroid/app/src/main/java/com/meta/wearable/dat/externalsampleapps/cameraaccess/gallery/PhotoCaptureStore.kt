package com.meta.wearable.dat.externalsampleapps.cameraaccess.gallery

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

object PhotoCaptureStore {
    private const val TAG = "PhotoCaptureStore"
    private const val MANIFEST_FILE = "manifest.json"

    private val _photos = MutableStateFlow<List<CapturedPhoto>>(emptyList())
    val photos: StateFlow<List<CapturedPhoto>> = _photos.asStateFlow()

    private fun capturesDir(context: Context): File {
        val dir = File(context.filesDir, "captures")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    fun loadPhotos(context: Context) {
        val manifestFile = File(capturesDir(context), MANIFEST_FILE)
        if (!manifestFile.exists()) {
            _photos.value = emptyList()
            return
        }
        try {
            val json = JSONArray(manifestFile.readText())
            val loaded = mutableListOf<CapturedPhoto>()
            for (i in 0 until json.length()) {
                val obj = json.getJSONObject(i)
                val photo = CapturedPhoto(
                    id = obj.getString("id"),
                    filename = obj.getString("filename"),
                    timestamp = obj.getLong("timestamp"),
                    description = obj.optString("description", null)
                )
                if (File(capturesDir(context), photo.filename).exists()) {
                    loaded.add(photo)
                }
            }
            _photos.value = loaded
            Log.d(TAG, "Loaded ${loaded.size} photos from manifest")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load manifest: ${e.message}")
            _photos.value = emptyList()
        }
    }

    fun saveFrame(context: Context, bitmap: Bitmap, description: String?): CapturedPhoto? {
        val formatter = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US)
        val filename = "capture_${formatter.format(Date())}.jpg"
        val file = File(capturesDir(context), filename)

        return try {
            FileOutputStream(file).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            }
            val photo = CapturedPhoto(
                id = UUID.randomUUID().toString(),
                filename = filename,
                timestamp = System.currentTimeMillis(),
                description = description
            )
            val current = _photos.value.toMutableList()
            current.add(0, photo)
            _photos.value = current
            saveManifest(context)
            Log.d(TAG, "Saved: $filename (${file.length()} bytes)")
            photo
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save photo: ${e.message}")
            null
        }
    }

    fun deletePhoto(context: Context, photo: CapturedPhoto) {
        File(capturesDir(context), photo.filename).delete()
        _photos.value = _photos.value.filter { it.id != photo.id }
        saveManifest(context)
        Log.d(TAG, "Deleted: ${photo.filename}")
    }

    fun getPhotoFile(context: Context, photo: CapturedPhoto): File {
        return File(capturesDir(context), photo.filename)
    }

    fun loadBitmap(context: Context, photo: CapturedPhoto): Bitmap? {
        val file = getPhotoFile(context, photo)
        return if (file.exists()) BitmapFactory.decodeFile(file.absolutePath) else null
    }

    private fun saveManifest(context: Context) {
        try {
            val json = JSONArray()
            for (photo in _photos.value) {
                json.put(JSONObject().apply {
                    put("id", photo.id)
                    put("filename", photo.filename)
                    put("timestamp", photo.timestamp)
                    if (photo.description != null) put("description", photo.description)
                })
            }
            File(capturesDir(context), MANIFEST_FILE).writeText(json.toString(2))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save manifest: ${e.message}")
        }
    }
}

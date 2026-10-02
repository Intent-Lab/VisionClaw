package com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting

import android.app.Application
import android.media.MediaRecorder
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class MeetingRecordingUiState(
    val isRecording: Boolean = false,
    val isProcessing: Boolean = false,
    val recordingStartedAtMs: Long? = null,
    val errorMessage: String? = null,
    val result: MeetingRecordingResult? = null,
)

class MeetingRecordingViewModel(application: Application) : AndroidViewModel(application) {
    companion object {
        private const val TAG = "MeetingRecordingVM"
    }

    private val _uiState = MutableStateFlow(MeetingRecordingUiState())
    val uiState: StateFlow<MeetingRecordingUiState> = _uiState.asStateFlow()

    private val repository = MeetingRecordingRepository()
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var startedAt: ZonedDateTime? = null

    fun startRecording() {
        if (_uiState.value.isRecording || _uiState.value.isProcessing) return
        val context = getApplication<Application>()
        val file = File(context.cacheDir, "meeting-${System.currentTimeMillis()}.m4a")
        try {
            val mediaRecorder = MediaRecorder(context).apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioChannels(1)
                setAudioSamplingRate(16_000)
                setAudioEncodingBitRate(32_000)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }
            recorder = mediaRecorder
            recordingFile = file
            startedAt = ZonedDateTime.now(ZoneId.of("Asia/Seoul"))
            _uiState.value = MeetingRecordingUiState(
                isRecording = true,
                recordingStartedAtMs = System.currentTimeMillis(),
            )
            Log.d(TAG, "Meeting recording started: ${file.absolutePath}")
        } catch (e: Exception) {
            file.delete()
            recorder?.release()
            recorder = null
            _uiState.value = MeetingRecordingUiState(
                errorMessage = "회의 녹음을 시작하지 못했습니다: ${e.message}"
            )
        }
    }

    fun stopAndProcess() {
        if (!_uiState.value.isRecording) return
        val file = recordingFile ?: return
        val start = startedAt ?: ZonedDateTime.now(ZoneId.of("Asia/Seoul"))
        try {
            recorder?.stop()
        } catch (e: Exception) {
            file.delete()
            _uiState.value = MeetingRecordingUiState(
                errorMessage = "녹음 파일을 만들지 못했습니다: ${e.message}"
            )
            releaseRecorder()
            return
        }
        releaseRecorder()
        val end = ZonedDateTime.now(ZoneId.of("Asia/Seoul"))
        _uiState.value = MeetingRecordingUiState(isProcessing = true)

        viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    repository.upload(
                        file = file,
                        title = "회의 ${start.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))}",
                        startedAt = start.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
                        endedAt = end.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME),
                    )
                }
                _uiState.value = MeetingRecordingUiState(result = result)
            } catch (e: Exception) {
                _uiState.value = MeetingRecordingUiState(
                    errorMessage = "회의 처리 실패: ${e.message}"
                )
            } finally {
                file.delete()
                recordingFile = null
                startedAt = null
            }
        }
    }

    fun cancelRecording() {
        if (_uiState.value.isRecording) {
            try {
                recorder?.stop()
            } catch (_: Exception) {
            }
        }
        releaseRecorder()
        recordingFile?.delete()
        recordingFile = null
        startedAt = null
        _uiState.value = MeetingRecordingUiState()
    }

    fun clearMessage() {
        _uiState.value = _uiState.value.copy(errorMessage = null, result = null)
    }

    private fun releaseRecorder() {
        recorder?.release()
        recorder = null
    }

    override fun onCleared() {
        cancelRecording()
        super.onCleared()
    }
}

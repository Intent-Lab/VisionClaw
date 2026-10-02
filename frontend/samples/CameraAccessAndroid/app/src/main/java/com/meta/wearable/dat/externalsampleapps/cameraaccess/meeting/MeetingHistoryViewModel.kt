package com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MeetingHistoryViewModel : ViewModel() {
    private val repository = MeetingHistoryRepository()

    private val _uiState = MutableStateFlow(MeetingHistoryUiState())
    val uiState: StateFlow<MeetingHistoryUiState> = _uiState.asStateFlow()

    fun loadRecent() {
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                val meetings = withContext(Dispatchers.IO) { repository.recent() }
                _uiState.update { it.copy(isLoading = false, meetings = meetings) }
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(
                        isLoading = false,
                        errorMessage = e.message ?: "Failed to load meetings",
                    )
                }
            }
        }
    }

    fun shareText(item: MeetingHistoryItem): String = repository.buildShareText(item)

    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    fun updateMeeting(
        meeting: MeetingHistoryItem,
        onSuccess: (MeetingHistoryItem) -> Unit,
    ) {
        _uiState.update { it.copy(isSaving = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                val updated = withContext(Dispatchers.IO) { repository.update(meeting) }
                onSuccess(updated)
                loadRecent()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to update meeting")
                }
            } finally {
                _uiState.update { it.copy(isSaving = false) }
            }
        }
    }

    fun deleteMeeting(
        meetingId: String,
        onSuccess: () -> Unit,
    ) {
        _uiState.update { it.copy(isSaving = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { repository.delete(meetingId) }
                onSuccess()
                loadRecent()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to delete meeting")
                }
            } finally {
                _uiState.update { it.copy(isSaving = false) }
            }
        }
    }
}

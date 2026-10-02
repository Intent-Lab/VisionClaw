package com.meta.wearable.dat.externalsampleapps.cameraaccess.memory

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MemoryViewModel : ViewModel() {
    private val repository = MemoryRepository()

    private val _uiState = MutableStateFlow(MemoryUiState())
    val uiState: StateFlow<MemoryUiState> = _uiState.asStateFlow()

    fun loadRecent() {
        runLoad { repository.recent() }
    }

    fun updateQuery(query: String) {
        _uiState.update { it.copy(query = query) }
    }

    fun search() {
        val query = _uiState.value.query.trim()
        if (query.isEmpty()) {
            loadRecent()
            return
        }
        runLoad { repository.search(query) }
    }

    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    fun refreshCurrent() {
        val query = _uiState.value.query.trim()
        if (query.isEmpty()) loadRecent() else search()
    }

    fun updateMemory(
        memory: MemoryItem,
        onSuccess: (MemoryItem) -> Unit,
    ) {
        _uiState.update { it.copy(isSaving = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                val updated = withContext(Dispatchers.IO) { repository.update(memory) }
                onSuccess(updated)
                refreshCurrent()
            } catch (e: Exception) {
                _uiState.update { it.copy(errorMessage = e.message ?: "Failed to update memory") }
            } finally {
                _uiState.update { it.copy(isSaving = false) }
            }
        }
    }

    fun deleteMemory(
        memoryId: String,
        onSuccess: () -> Unit,
    ) {
        _uiState.update { it.copy(isSaving = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { repository.delete(memoryId) }
                onSuccess()
                refreshCurrent()
            } catch (e: Exception) {
                _uiState.update { it.copy(errorMessage = e.message ?: "Failed to delete memory") }
            } finally {
                _uiState.update { it.copy(isSaving = false) }
            }
        }
    }

    private fun runLoad(block: () -> List<MemoryItem>) {
        _uiState.update { it.copy(isLoading = true, errorMessage = null) }
        viewModelScope.launch {
            try {
                val memories = withContext(Dispatchers.IO) { block() }
                _uiState.update { it.copy(isLoading = false, memories = memories) }
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(
                        isLoading = false,
                        errorMessage = e.message ?: "Failed to load memories",
                    )
                }
            }
        }
    }
}

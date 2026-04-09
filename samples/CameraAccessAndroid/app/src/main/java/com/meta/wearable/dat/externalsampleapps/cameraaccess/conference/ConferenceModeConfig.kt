package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager

data class ConferenceModeConfig(
    val enabled: Boolean,
    val acceptedConfidenceMin: Double = ACCEPTED_CONFIDENCE_THRESHOLD,
    val reviewConfidenceMin: Double = REVIEW_CONFIDENCE_THRESHOLD,
    val duplicateCooldownMs: Long = DUPLICATE_COOLDOWN_MS,
) {
    companion object {
        const val ACCEPTED_CONFIDENCE_THRESHOLD = 0.70
        const val REVIEW_CONFIDENCE_THRESHOLD = 0.50
        const val DUPLICATE_COOLDOWN_MS = 10_000L

        fun current(): ConferenceModeConfig {
            return ConferenceModeConfig(enabled = SettingsManager.conferenceModeEnabled)
        }
    }
}

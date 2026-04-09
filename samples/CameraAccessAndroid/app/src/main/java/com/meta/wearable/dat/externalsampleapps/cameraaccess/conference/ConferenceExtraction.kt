package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

enum class ConferenceSourceType(val wireValue: String) {
    BADGE("badge"),
    CARD("card"),
    BOOTH("booth"),
    SLIDE("slide");

    val displayName: String
        get() = wireValue.replaceFirstChar { it.uppercase() }

    companion object {
        fun fromValue(value: String?): ConferenceSourceType? {
            val normalized = value?.trim()?.lowercase() ?: return null
            return entries.firstOrNull { it.wireValue == normalized }
        }
    }
}

enum class ConferenceExtractionDisposition(val wireValue: String) {
    ACCEPTED("accepted"),
    REVIEW("review");

    val displayName: String
        get() = wireValue.replaceFirstChar { it.uppercase() }
}

data class ConferenceExtraction(
    val name: String,
    val company: String?,
    val role: String?,
    val sourceType: ConferenceSourceType,
    val confidence: Double,
    val observedText: String?,
    val disposition: ConferenceExtractionDisposition,
    val detectedAtMs: Long,
) {
    val confidenceText: String
        get() = "${(confidence * 100).toInt()}%"

    val summaryText: String
        get() = listOfNotNull(company?.takeIf { it.isNotBlank() }, role?.takeIf { it.isNotBlank() })
            .joinToString(separator = " / ")
}

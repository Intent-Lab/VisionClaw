package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

sealed class ConferenceExtractionHandlingResult {
    data class Accepted(val extraction: ConferenceExtraction) : ConferenceExtractionHandlingResult()
    data class Review(val extraction: ConferenceExtraction) : ConferenceExtractionHandlingResult()
    data class IgnoredLowConfidence(val confidence: Double) : ConferenceExtractionHandlingResult()
    data object IgnoredDuplicate : ConferenceExtractionHandlingResult()
    data class Invalid(val message: String) : ConferenceExtractionHandlingResult()
}

class ConferenceExtractionProcessor(
    private val config: ConferenceModeConfig = ConferenceModeConfig.current(),
) {
    private val recentDetections = mutableMapOf<String, Long>()

    fun handle(
        args: Map<String, Any?>,
        nowMs: Long = System.currentTimeMillis(),
    ): ConferenceExtractionHandlingResult {
        val name = cleanedString(args["name"])
            ?: return ConferenceExtractionHandlingResult.Invalid("Missing required field: name")
        val sourceType = ConferenceSourceType.fromValue(cleanedString(args["source_type"]))
            ?: return ConferenceExtractionHandlingResult.Invalid("Invalid required field: source_type")
        val confidence = parseConfidence(args["confidence"])
            ?: return ConferenceExtractionHandlingResult.Invalid("Invalid required field: confidence")

        if (confidence < config.reviewConfidenceMin) {
            return ConferenceExtractionHandlingResult.IgnoredLowConfidence(confidence)
        }

        val company = cleanedString(args["company"])
        val role = cleanedString(args["role"])
        val observedText = cleanedString(args["observed_text"])

        pruneDetections(nowMs - config.duplicateCooldownMs)
        val detectionKey = normalizedKey(name = name, company = company, sourceType = sourceType)
        val lastSeen = recentDetections[detectionKey]
        if (lastSeen != null && nowMs - lastSeen < config.duplicateCooldownMs) {
            return ConferenceExtractionHandlingResult.IgnoredDuplicate
        }

        recentDetections[detectionKey] = nowMs

        val extraction = ConferenceExtraction(
            name = name,
            company = company,
            role = role,
            sourceType = sourceType,
            confidence = confidence,
            observedText = observedText,
            disposition = if (confidence >= config.acceptedConfidenceMin) {
                ConferenceExtractionDisposition.ACCEPTED
            } else {
                ConferenceExtractionDisposition.REVIEW
            },
            detectedAtMs = nowMs,
        )

        return when (extraction.disposition) {
            ConferenceExtractionDisposition.ACCEPTED -> ConferenceExtractionHandlingResult.Accepted(extraction)
            ConferenceExtractionDisposition.REVIEW -> ConferenceExtractionHandlingResult.Review(extraction)
        }
    }

    companion object {
        fun normalizedKey(
            name: String,
            company: String?,
            sourceType: ConferenceSourceType,
        ): String {
            return buildString {
                append(name.trim().lowercase())
                append("|")
                append(company?.trim()?.lowercase().orEmpty())
                append("|")
                append(sourceType.wireValue)
            }
        }

        private fun cleanedString(value: Any?): String? {
            val trimmed = (value as? String)?.trim() ?: return null
            return trimmed.takeIf { it.isNotEmpty() }
        }

        private fun parseConfidence(value: Any?): Double? {
            return when (value) {
                is Number -> value.toDouble()
                is String -> value.trim().toDoubleOrNull()
                else -> null
            }
        }
    }

    private fun pruneDetections(cutoffMs: Long) {
        val iterator = recentDetections.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.value < cutoffMs) {
                iterator.remove()
            }
        }
    }
}

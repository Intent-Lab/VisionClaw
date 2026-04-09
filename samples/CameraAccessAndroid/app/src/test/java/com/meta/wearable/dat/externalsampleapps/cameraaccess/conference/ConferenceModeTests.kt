package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConferenceModeTests {

    @Test
    fun conferencePromptUsesFallbackWhenDisabled() {
        val fallback = "custom prompt"

        assertEquals(
            fallback,
            ConferencePrompts.activeSystemInstruction(
                conferenceModeEnabled = false,
                fallbackPrompt = fallback,
            ),
        )
    }

    @Test
    fun conferencePromptUsesRelationshipOpsWhenEnabled() {
        assertEquals(
            ConferencePrompts.relationshipOps,
            ConferencePrompts.activeSystemInstruction(
                conferenceModeEnabled = true,
                fallbackPrompt = "custom",
            ),
        )
    }

    @Test
    fun toolDeclarationsExcludeExtractEntityWhenConferenceModeDisabled() {
        val names = ToolDeclarations.allDeclarations(conferenceModeEnabled = false).map { it.name }

        assertEquals(listOf(ToolDeclarations.EXECUTE_NAME), names)
    }

    @Test
    fun toolDeclarationsIncludeExtractEntityWhenConferenceModeEnabled() {
        val names = ToolDeclarations.allDeclarations(conferenceModeEnabled = true).map { it.name }

        assertEquals(
            listOf(ToolDeclarations.EXECUTE_NAME, ToolDeclarations.EXTRACT_ENTITY_NAME),
            names,
        )
    }

    @Test
    fun processorAcceptsHighConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Sarah Chen",
                "company" to "Acme AI",
                "role" to "VP Engineering",
                "source_type" to "badge",
                "confidence" to 0.92,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.Accepted)
        val extraction = (result as ConferenceExtractionHandlingResult.Accepted).extraction
        assertEquals("Sarah Chen", extraction.name)
        assertEquals(ConferenceSourceType.BADGE, extraction.sourceType)
        assertEquals(ConferenceExtractionDisposition.ACCEPTED, extraction.disposition)
    }

    @Test
    fun processorReturnsReviewForMidConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Taylor Reed",
                "source_type" to "card",
                "confidence" to 0.61,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.Review)
        val extraction = (result as ConferenceExtractionHandlingResult.Review).extraction
        assertEquals(ConferenceExtractionDisposition.REVIEW, extraction.disposition)
        assertEquals(ConferenceSourceType.CARD, extraction.sourceType)
    }

    @Test
    fun processorIgnoresLowConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Jamie Park",
                "source_type" to "booth",
                "confidence" to 0.32,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.IgnoredLowConfidence)
        val confidence = (result as ConferenceExtractionHandlingResult.IgnoredLowConfidence).confidence
        assertEquals(0.32, confidence, 0.0001)
    }

    @Test
    fun processorSuppressesDuplicatesWithinCooldown() {
        val processor = makeProcessor()
        val args = mapOf(
            "name" to "Morgan Lee",
            "company" to "OpenClaw",
            "source_type" to "badge",
            "confidence" to 0.88,
        )

        val firstResult = processor.handle(args = args, nowMs = 0L)
        assertTrue(firstResult is ConferenceExtractionHandlingResult.Accepted)

        val secondResult = processor.handle(args = args, nowMs = 5_000L)
        assertEquals(ConferenceExtractionHandlingResult.IgnoredDuplicate, secondResult)
    }

    private fun makeProcessor(): ConferenceExtractionProcessor {
        return ConferenceExtractionProcessor(
            ConferenceModeConfig(
                enabled = true,
                acceptedConfidenceMin = 0.70,
                reviewConfidenceMin = 0.50,
                duplicateCooldownMs = 10_000L,
            ),
        )
    }
}

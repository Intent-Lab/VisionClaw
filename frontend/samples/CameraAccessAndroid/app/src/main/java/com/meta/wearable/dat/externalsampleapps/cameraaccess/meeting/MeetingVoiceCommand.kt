package com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting

enum class MeetingVoiceCommand {
    START,
    STOP,
}

object MeetingVoiceCommandParser {
    fun parse(text: String): MeetingVoiceCommand? {
        val normalized = text
            .lowercase()
            .replace(Regex("\\s+"), "")
            .replace(Regex("[^가-힣a-z0-9]"), "")

        val hasMeetingWord = normalized.contains("회의") || normalized.contains("미팅")
        val hasRecordingWord = normalized.contains("녹음") || normalized.contains("기록")
        val hasStopWord = listOf("종료", "끝", "중지", "정지", "그만", "멈춰", "마무리", "끝내")
            .any { normalized.contains(it) }

        return when {
            normalized.contains("회의시작") ||
                normalized.contains("녹음시작") ||
                normalized.contains("회의녹음시작") ||
                normalized.contains("회의기록") ||
                normalized.contains("회의를기록") ||
                normalized.contains("이회의를기록") ||
                normalized.contains("미팅시작") ||
                normalized.contains("미팅녹음") ||
                normalized.contains("미팅기록") -> MeetingVoiceCommand.START
            normalized.contains("회의녹음끝") ||
                normalized.contains("회의녹음종료") ||
                normalized.contains("미팅녹음끝") ||
                normalized.contains("미팅녹음종료") ||
                normalized.contains("녹음종료") ||
                normalized.contains("녹음끝") ||
                normalized.contains("녹음그만") ||
                normalized.contains("기록종료") ||
                normalized.contains("기록끝") ||
                (hasMeetingWord && hasStopWord) ||
                (hasRecordingWord && hasStopWord) -> MeetingVoiceCommand.STOP
            else -> null
        }
    }
}

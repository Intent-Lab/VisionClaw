package com.meta.wearable.dat.externalsampleapps.cameraaccess.chat

import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: ChatMessageRole,
    var text: String,
    val timestamp: Long = System.currentTimeMillis(),
    var status: ChatMessageStatus = ChatMessageStatus.Complete,
)

sealed class ChatMessageRole {
    data object User : ChatMessageRole()
    data object Assistant : ChatMessageRole()
    data class ToolCall(val name: String) : ChatMessageRole()
    data object SessionDivider : ChatMessageRole()
}

sealed class ChatMessageStatus {
    data object Streaming : ChatMessageStatus()
    data object Complete : ChatMessageStatus()
    data class Error(val message: String) : ChatMessageStatus()
}

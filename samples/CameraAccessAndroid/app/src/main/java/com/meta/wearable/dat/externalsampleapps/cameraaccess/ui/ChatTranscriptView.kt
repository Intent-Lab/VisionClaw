package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessage
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessageRole
import com.meta.wearable.dat.externalsampleapps.cameraaccess.chat.ChatMessageStatus
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

@Composable
fun ChatTranscriptView(
    messages: List<ChatMessage>,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size, messages.lastOrNull()?.text) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    if (messages.isEmpty()) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = "Start talking to see the conversation here",
                color = Color.Black.copy(alpha = 0.4f),
                fontSize = 14.sp,
            )
        }
    } else {
        SelectionContainer {
            LazyColumn(
                state = listState,
                modifier = modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                itemsIndexed(messages, key = { _, msg -> msg.id }) { index, message ->
                    val showTime = shouldShowTimestamp(index, messages)
                    MessageBubble(message = message, showTimestamp = showTime)
                }
            }
        }
    }
}

private fun shouldShowTimestamp(index: Int, messages: List<ChatMessage>): Boolean {
    val message = messages[index]
    if (message.role is ChatMessageRole.SessionDivider) return false
    if (index == 0) return true
    val prev = messages[index - 1]
    if (prev.role is ChatMessageRole.SessionDivider) return true
    return message.timestamp - prev.timestamp > 120_000 // 2+ minutes
}

private fun formatTime(timestamp: Long): String {
    return SimpleDateFormat("h:mm a", Locale.getDefault()).format(Date(timestamp))
}

private fun formatSessionDate(timestamp: Long): String {
    val cal = Calendar.getInstance()
    val today = Calendar.getInstance()
    cal.timeInMillis = timestamp
    return if (cal.get(Calendar.YEAR) == today.get(Calendar.YEAR)
        && cal.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR)) {
        "Today ${formatTime(timestamp)}"
    } else {
        SimpleDateFormat("MMM d, h:mm a", Locale.getDefault()).format(Date(timestamp))
    }
}

@Composable
fun MessageBubble(message: ChatMessage, showTimestamp: Boolean = false, modifier: Modifier = Modifier) {
    when (message.role) {
        is ChatMessageRole.User -> UserBubble(message, showTimestamp, modifier)
        is ChatMessageRole.Assistant -> AssistantBubble(message, showTimestamp, modifier)
        is ChatMessageRole.ToolCall -> ToolCallBubble(message.role.name, message, modifier)
        is ChatMessageRole.SessionDivider -> SessionDividerView(message, modifier)
    }
}

@Composable
private fun SessionDividerView(message: ChatMessage, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HorizontalDivider(modifier = Modifier.weight(1f), color = Color.Black.copy(alpha = 0.15f))
        Text(
            text = formatSessionDate(message.timestamp),
            color = Color.Black.copy(alpha = 0.35f),
            fontSize = 11.sp,
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        HorizontalDivider(modifier = Modifier.weight(1f), color = Color.Black.copy(alpha = 0.15f))
    }
}

@Composable
private fun UserBubble(message: ChatMessage, showTimestamp: Boolean, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalAlignment = Alignment.End,
    ) {
        Text(
            text = message.text,
            color = Color.White,
            fontSize = 15.sp,
            modifier = Modifier
                .background(Color(0xFF2979FF), RoundedCornerShape(18.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        )
        if (showTimestamp) {
            Text(
                text = formatTime(message.timestamp),
                color = Color.Black.copy(alpha = 0.3f),
                fontSize = 10.sp,
                modifier = Modifier.padding(top = 2.dp, end = 4.dp),
            )
        }
    }
}

@Composable
private fun AssistantBubble(message: ChatMessage, showTimestamp: Boolean, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            text = message.text,
            color = Color.Black.copy(alpha = 0.85f),
            fontSize = 15.sp,
        )
        if (showTimestamp) {
            Text(
                text = formatTime(message.timestamp),
                color = Color.Black.copy(alpha = 0.3f),
                fontSize = 10.sp,
                modifier = Modifier.padding(top = 2.dp, start = 4.dp),
            )
        }
    }
}

@Composable
private fun ToolCallBubble(name: String, message: ChatMessage, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.Center,
    ) {
        Row(
            modifier = Modifier
                .background(Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (message.status is ChatMessageStatus.Streaming) {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    color = Color.Black.copy(alpha = 0.6f),
                    strokeWidth = 1.5.dp,
                )
            } else {
                Text(
                    text = "[OK]",
                    color = Color(0xFF4CAF50),
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
            Text(
                text = name,
                color = Color.Black.copy(alpha = 0.6f),
                fontSize = 12.sp,
            )
        }
    }
}

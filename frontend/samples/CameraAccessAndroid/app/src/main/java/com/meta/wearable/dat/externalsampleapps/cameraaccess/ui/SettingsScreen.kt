package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var geminiAPIKey by remember { mutableStateOf(SettingsManager.geminiAPIKey) }
    var systemPrompt by remember { mutableStateOf(SettingsManager.geminiSystemPrompt) }
    var jarvisApiBase by remember { mutableStateOf(SettingsManager.jarvisApiBase) }
    var jarvisApiKey by remember { mutableStateOf(SettingsManager.jarvisApiKey) }
    var webrtcSignalingURL by remember { mutableStateOf(SettingsManager.webrtcSignalingURL) }
    var videoStreamingEnabled by remember { mutableStateOf(SettingsManager.videoStreamingEnabled) }
    var proactiveNotificationsEnabled by remember { mutableStateOf(SettingsManager.proactiveNotificationsEnabled) }
    var liveConversationEnabled by remember { mutableStateOf(SettingsManager.liveConversationEnabled) }
    var whisperSttEnabled by remember { mutableStateOf(SettingsManager.speechRecognizerProvider == "whisper") }
    var showResetDialog by remember { mutableStateOf(false) }

    fun save() {
        SettingsManager.geminiAPIKey = geminiAPIKey.trim()
        SettingsManager.geminiSystemPrompt = systemPrompt.trim()
        SettingsManager.jarvisApiBase = jarvisApiBase.trim()
        SettingsManager.jarvisApiKey = jarvisApiKey.trim()
        SettingsManager.webrtcSignalingURL = webrtcSignalingURL.trim()
        SettingsManager.videoStreamingEnabled = videoStreamingEnabled
        SettingsManager.proactiveNotificationsEnabled = proactiveNotificationsEnabled
        SettingsManager.liveConversationEnabled = liveConversationEnabled
        SettingsManager.speechRecognizerProvider = if (whisperSttEnabled) "whisper" else "android"
    }

    fun reload() {
        geminiAPIKey = SettingsManager.geminiAPIKey
        systemPrompt = SettingsManager.geminiSystemPrompt
        jarvisApiBase = SettingsManager.jarvisApiBase
        jarvisApiKey = SettingsManager.jarvisApiKey
        webrtcSignalingURL = SettingsManager.webrtcSignalingURL
        videoStreamingEnabled = SettingsManager.videoStreamingEnabled
        proactiveNotificationsEnabled = SettingsManager.proactiveNotificationsEnabled
        liveConversationEnabled = SettingsManager.liveConversationEnabled
        whisperSttEnabled = SettingsManager.speechRecognizerProvider == "whisper"
    }

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Jarvis 설정") },
            navigationIcon = {
                IconButton(onClick = {
                    save()
                    onBack()
                }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Gemini section
            SectionHeader("Gemini API")
            MonoTextField(
                value = geminiAPIKey,
                onValueChange = { geminiAPIKey = it },
                label = "API Key",
                placeholder = "Enter Gemini API key",
            )

            SectionHeader("System Prompt")
            OutlinedTextField(
                value = systemPrompt,
                onValueChange = { systemPrompt = it },
                label = { Text("System prompt") },
                modifier = Modifier.fillMaxWidth().height(200.dp),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            )

            SectionHeader("Jarvis Memory Server")
            MonoTextField(
                value = jarvisApiBase,
                onValueChange = { jarvisApiBase = it },
                label = "API URL",
                placeholder = "https://your-tunnel.trycloudflare.com",
                keyboardType = KeyboardType.Uri,
            )
            MonoTextField(
                value = jarvisApiKey,
                onValueChange = { jarvisApiKey = it },
                label = "API Key",
                placeholder = "Jarvis server API key",
            )

            // WebRTC section
            SectionHeader("Live Share")
            MonoTextField(
                value = webrtcSignalingURL,
                onValueChange = { webrtcSignalingURL = it },
                label = "Signaling URL",
                placeholder = "Auto: Jarvis API /live/ws",
                keyboardType = KeyboardType.Uri,
            )

            // Speech recognition
            SectionHeader("음성 대화")
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("실시간 대화", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "말하는 동안 Gemini가 듣고 답합니다. 답변 중에도 끼어들 수 있고, 종료 버튼을 누를 때까지 대화가 이어집니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = liveConversationEnabled,
                    onCheckedChange = { liveConversationEnabled = it },
                )
            }
            if (!liveConversationEnabled) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            if (whisperSttEnabled) "Whisper.cpp STT" else "Android Korean STT",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                        Text(
                            if (whisperSttEnabled) {
                                "Experimental offline mode. Slower, but useful for accuracy comparison."
                            } else {
                                "Default stable mode. Faster startup and better for daily testing."
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(
                        checked = whisperSttEnabled,
                        onCheckedChange = { whisperSttEnabled = it },
                    )
                }
            }

            // Video
            SectionHeader("Video")
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Column {
                    Text("연속 영상 전송", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "일상 테스트에서는 꺼두세요. Jarvis는 필요한 순간의 이미지만 캡처합니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = videoStreamingEnabled,
                    onCheckedChange = { videoStreamingEnabled = it },
                )
            }

            // Notifications
            SectionHeader("Jarvis 알림")
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            ) {
                Column {
                    Text("서버 알림 음성 안내", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Jarvis 서버에서 온 알림을 글라스 스피커로 안내합니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = proactiveNotificationsEnabled,
                    onCheckedChange = { proactiveNotificationsEnabled = it },
                )
            }

            // Reset
            TextButton(onClick = { showResetDialog = true }) {
                Text("기본값으로 초기화", color = Color.Red)
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }

    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("설정 초기화") },
            text = { Text("앱에 포함된 기본 설정으로 되돌립니다.") },
            confirmButton = {
                TextButton(onClick = {
                    SettingsManager.resetAll()
                    reload()
                    showResetDialog = false
                }) {
                    Text("초기화", color = Color.Red)
                }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) {
                    Text("취소")
                }
            },
        )
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
    )
}

@Composable
private fun MonoTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    placeholder: String,
    keyboardType: KeyboardType = KeyboardType.Text,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        modifier = Modifier.fillMaxWidth(),
        textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
    )
}

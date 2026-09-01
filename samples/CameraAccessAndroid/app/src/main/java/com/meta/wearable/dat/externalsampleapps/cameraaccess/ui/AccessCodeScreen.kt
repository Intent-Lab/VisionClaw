package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.GatewayApi
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.GatewayStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import kotlinx.coroutines.launch

/**
 * First-launch gate: the gateway token is per-person identity, so builds ship
 * without one and every install starts here. The code is verified against the
 * gateway before unlocking, because a typo saved silently would surface later
 * as a 401 that looks like a server outage.
 */
@Composable
fun AccessCodeScreen(
    onUnlocked: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var code by remember { mutableStateOf("") }
    var checking by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Self-hosters mint their own codes on their own gateway; without a way to
    // point the app there, the gate reads as a private beta and they email the
    // author for a code that only their gateway can issue.
    var ownGateway by remember { mutableStateOf(false) }
    var gatewayUrl by remember { mutableStateOf(SettingsManager.gatewayBaseUrl) }
    val scope = rememberCoroutineScope()

    fun submit() {
        if (checking) return
        error = null
        if (ownGateway) {
            val url = gatewayUrl.trim().trimEnd('/')
            if (!url.startsWith("http")) {
                error = "Gateway URL must start with https://"
                return
            }
            SettingsManager.gatewayBaseUrl = url
        }
        checking = true
        SettingsManager.gatewayToken = code.trim()
        scope.launch {
            when (val status = GatewayApi.checkStatus()) {
                is GatewayStatus.Ready -> onUnlocked()
                is GatewayStatus.Unauthorized -> {
                    error = "That code was not recognized. Check it and try again."
                }
                is GatewayStatus.Unreachable -> {
                    error = "Could not reach the server. Check your connection and try again."
                }
                else -> {
                    error = "Enter the access code you were given."
                }
            }
            checking = false
        }
    }

    Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("VisionClaw", style = MaterialTheme.typography.headlineMedium)
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                "Enter your access code to get started. Each code is a personal identity, so ask whoever shared the app for yours.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(32.dp))
            OutlinedTextField(
                value = code,
                onValueChange = { code = it },
                label = { Text("Access code") },
                singleLine = true,
                enabled = !checking,
                isError = error != null,
                supportingText = { error?.let { Text(it) } },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(4.dp))
            TextButton(onClick = { ownGateway = !ownGateway }, enabled = !checking) {
                Text(if (ownGateway) "Use the default gateway" else "Using your own gateway?")
            }
            if (ownGateway) {
                Text(
                    "A self-hosted gateway issues its own codes: any entry you set in its GATEWAY_TOKENS works here.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = gatewayUrl,
                    onValueChange = { gatewayUrl = it },
                    label = { Text("Gateway URL") },
                    singleLine = true,
                    enabled = !checking,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = ::submit,
                enabled = code.trim().isNotEmpty() && !checking,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (checking) {
                    CircularProgressIndicator(
                        modifier = Modifier.height(20.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text("Continue")
                }
            }
        }
    }
}

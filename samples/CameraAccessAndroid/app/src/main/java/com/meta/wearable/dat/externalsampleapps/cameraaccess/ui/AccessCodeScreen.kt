package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.GatewayApi
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.GatewayStatus
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import java.security.SecureRandom
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val EXCHANGE_POLL_MS = 2_000L
private const val EXCHANGE_TIMEOUT_MS = 10 * 60_000L
private const val PENDING_RECHECK_MS = 15_000L

private fun newNonce(): String {
    val bytes = ByteArray(16)
    SecureRandom().nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it) }
}

/**
 * First-launch gate. Google sign-in is the front door: consent happens in a
 * Custom Tab, the gateway parks the credential under a one-time nonce, and
 * the screen polls for it so the token never rides a deep link. Accounts the
 * researcher has not approved yet hold a token but wait here.
 *
 * Access codes and self-hosted gateways remain, demoted under a disclosure:
 * a code is a token from whichever gateway the app points at, and a typo is
 * caught by verifying against the gateway before unlocking.
 */
@Composable
fun AccessCodeScreen(
    onUnlocked: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    var error by remember { mutableStateOf<String?>(null) }
    var checking by remember { mutableStateOf(false) }

    // Google sign-in
    var nonce by remember { mutableStateOf<String?>(null) }
    var pendingEmail by remember {
        mutableStateOf(
            if (SettingsManager.accountStatus == "pending") SettingsManager.accountEmail else null,
        )
    }
    // Bumped on resume so a poll fires the instant the browser hands control back.
    var resumeTick by remember { mutableIntStateOf(0) }

    // Access code path
    var showManual by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var ownGateway by remember { mutableStateOf(false) }
    var gatewayUrl by remember { mutableStateOf(SettingsManager.gatewayBaseUrl) }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) resumeTick++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    suspend fun refreshAccount(): Boolean {
        val me = GatewayApi.fetchMe().getOrNull() ?: return false
        SettingsManager.accountUserId = me.userId
        if (me.email.isNotEmpty()) SettingsManager.accountEmail = me.email
        SettingsManager.accountStatus = me.status
        return when (me.status) {
            "approved" -> {
                pendingEmail = null
                onUnlocked()
                true
            }
            "pending" -> {
                pendingEmail = me.email.ifEmpty { SettingsManager.accountEmail }
                false
            }
            else -> {
                SettingsManager.signOut()
                pendingEmail = null
                error = "This account is no longer active."
                false
            }
        }
    }

    fun startGoogleSignIn() {
        error = null
        val n = newNonce()
        nonce = n
        CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(GatewayApi.signInUrl(n)))
    }

    // Poll the exchange while a sign-in is in flight; a resume re-enters the
    // loop immediately instead of waiting out the current interval.
    LaunchedEffect(nonce, resumeTick) {
        val n = nonce ?: return@LaunchedEffect
        val started = System.currentTimeMillis()
        while (System.currentTimeMillis() - started < EXCHANGE_TIMEOUT_MS) {
            when (val result = GatewayApi.exchangeNonce(n)) {
                is GatewayApi.AuthExchange.Ready -> {
                    nonce = null
                    SettingsManager.accountEmail = result.email
                    SettingsManager.accountUserId = result.userId
                    SettingsManager.accountStatus = result.status
                    SettingsManager.gatewayToken = result.token
                    if (result.status == "approved") {
                        onUnlocked()
                    } else {
                        pendingEmail = result.email
                        refreshAccount()
                    }
                    return@LaunchedEffect
                }
                is GatewayApi.AuthExchange.Expired -> {
                    nonce = null
                    error = "Sign-in expired. Try again."
                    return@LaunchedEffect
                }
                is GatewayApi.AuthExchange.Error -> {
                    // Transient (browser still open, network blip); keep polling.
                }
                GatewayApi.AuthExchange.NotReady -> Unit
            }
            delay(EXCHANGE_POLL_MS)
        }
        nonce = null
        error = "Sign-in timed out. Try again."
    }

    // While pending, re-ask the gateway on a slow cadence and on every resume.
    LaunchedEffect(pendingEmail, resumeTick) {
        if (pendingEmail == null) return@LaunchedEffect
        while (true) {
            if (refreshAccount()) return@LaunchedEffect
            delay(PENDING_RECHECK_MS)
        }
    }

    fun submitCode() {
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
            when (GatewayApi.checkStatus()) {
                is GatewayStatus.Ready -> onUnlocked()
                is GatewayStatus.Unauthorized -> error = "That code was not recognized. Check it and try again."
                is GatewayStatus.Unreachable -> error = "Could not reach the server. Check your connection and try again."
                else -> error = "Enter the access code you were given."
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

            val pending = pendingEmail
            if (pending != null) {
                Text(
                    "Awaiting approval",
                    style = MaterialTheme.typography.titleMedium,
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    pending,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    "We'll let you in as soon as the researcher approves your account.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(24.dp))
                Button(
                    onClick = { scope.launch { refreshAccount() } },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Check again") }
                TextButton(onClick = {
                    SettingsManager.signOut()
                    pendingEmail = null
                    error = null
                }) { Text("Use a different account") }
                error?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                        textAlign = TextAlign.Center)
                }
                return@Column
            }

            Text(
                "Sign in with your Google account to get started. Your calendar connects in the same step.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(32.dp))
            Button(
                onClick = ::startGoogleSignIn,
                enabled = nonce == null && !checking,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (nonce != null) {
                    CircularProgressIndicator(modifier = Modifier.height(20.dp), strokeWidth = 2.dp)
                } else {
                    Text("Sign in with Google")
                }
            }
            if (nonce != null) {
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    "Finish signing in with your browser, then come back here.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                TextButton(onClick = { nonce = null }) { Text("Cancel") }
            }
            error?.let {
                Spacer(modifier = Modifier.height(8.dp))
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center)
            }

            Spacer(modifier = Modifier.height(16.dp))
            TextButton(onClick = { showManual = !showManual }, enabled = nonce == null) {
                Text(if (showManual) "Hide" else "Have an access code or your own gateway?")
            }
            if (showManual) {
                OutlinedTextField(
                    value = code,
                    onValueChange = { code = it },
                    label = { Text("Access code") },
                    singleLine = true,
                    enabled = !checking,
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
                OutlinedButton(
                    onClick = ::submitCode,
                    enabled = code.trim().isNotEmpty() && !checking,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (checking) {
                        CircularProgressIndicator(modifier = Modifier.height(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text("Continue with code")
                    }
                }
            }
        }
    }
}

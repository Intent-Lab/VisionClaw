package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.GatewayApi
import kotlinx.coroutines.launch

/**
 * Connect third-party apps (calendar, etc.) to the cloud agent.
 *
 * Reduced from iOS's in-app auth sheet: Connect opens the gateway's /connect
 * route in the browser; the gateway runs the OAuth dance, stores the
 * credential, and shows a completion page. Returning to the app refreshes the
 * list (ON_RESUME), so the row flips to Connected.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectedAppsScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var apps by remember { mutableStateOf<List<GatewayApi.ConnectableApp>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    fun load() {
        scope.launch {
            GatewayApi.fetchApps()
                .onSuccess {
                    apps = it
                    errorMessage = null
                    isLoading = false
                }
                .onFailure {
                    errorMessage = it.message ?: "Could not reach the gateway"
                    isLoading = false
                }
        }
    }

    // ON_RESUME replays on subscription, so this doubles as the initial load
    // and the refresh after the user returns from the browser OAuth dance.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) load()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    BackHandler { onBack() }

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Connected Apps") },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
        )

        when {
            isLoading -> {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }
            errorMessage != null -> {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("Could not load apps", style = MaterialTheme.typography.titleMedium)
                    Text(
                        errorMessage.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    TextButton(onClick = {
                        isLoading = true
                        load()
                    }) {
                        Text("Try Again")
                    }
                }
            }
            apps.isEmpty() -> {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("No apps available", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(
                        "The gateway has no connectable apps configured.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
            else -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp)
                        .navigationBarsPadding(),
                ) {
                    apps.forEach { app ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column {
                                Text(app.displayName, style = MaterialTheme.typography.bodyLarge)
                                if (!app.available) {
                                    Text(
                                        "Not configured on the gateway",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.outline,
                                    )
                                }
                            }
                            if (app.connected) {
                                Icon(
                                    imageVector = Icons.Default.CheckCircle,
                                    contentDescription = "Connected",
                                    tint = AppColor.Green,
                                    modifier = Modifier.size(22.dp),
                                )
                            } else {
                                TextButton(
                                    enabled = app.available,
                                    onClick = {
                                        // In-app OAuth: a Custom Tab keeps the
                                        // dance inside the app; ON_RESUME
                                        // refreshes the list when it closes.
                                        CustomTabsIntent.Builder()
                                            .build()
                                            .launchUrl(context, Uri.parse(GatewayApi.connectUrl(app.id)))
                                    },
                                ) {
                                    Text("Connect")
                                }
                            }
                        }
                    }
                    FooterText(
                        "Connected apps let the assistant act on your behalf even when your " +
                            "phone is asleep, such as in scheduled updates.",
                    )
                    Spacer(modifier = Modifier.height(32.dp))
                }
            }
        }
    }
}

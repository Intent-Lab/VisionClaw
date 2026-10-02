package com.example.facedetectionapp

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.example.facedetectionapp.ui.PersonListScreen
import com.example.facedetectionapp.ui.theme.FaceDetectionAPPTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            FaceDetectionAPPTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AppNavigator()
                }
            }
        }
    }
}

enum class ScreenState {
    PERSON_LIST, PHONE_CAMERA, GLASSES, COACHING, STREAMING
}

@Composable
fun AppNavigator() {
    val activity = LocalContext.current as? Activity
    var currentScreen by remember { mutableStateOf(ScreenState.PERSON_LIST) }
    var showExitDialog by remember { mutableStateOf(false) }

    if (showExitDialog) {
        AlertDialog(
            onDismissRequest = { showExitDialog = false },
            title = { Text("앱 종료", fontWeight = FontWeight.Bold) },
            text = { Text("앱을 종료하시겠습니까?") },
            confirmButton = {
                Button(onClick = { activity?.finish() }) { Text("종료") }
            },
            dismissButton = {
                TextButton(onClick = { showExitDialog = false }) { Text("취소") }
            }
        )
    }

    when (currentScreen) {
        ScreenState.PERSON_LIST -> {
            BackHandler { showExitDialog = true }
            PersonListScreen(
                onPhoneModeClick = { currentScreen = ScreenState.PHONE_CAMERA },
                onGlassesModeClick = { currentScreen = ScreenState.GLASSES },
                onCoachingClick = { currentScreen = ScreenState.COACHING },
                onStreamingClick = { currentScreen = ScreenState.STREAMING }
            )
        }

        ScreenState.PHONE_CAMERA -> {
            BackHandler { currentScreen = ScreenState.PERSON_LIST }
            PhoneCameraWrapper(onNavigateBack = { currentScreen = ScreenState.PERSON_LIST })
        }

        ScreenState.GLASSES -> {
            BackHandler { currentScreen = ScreenState.PERSON_LIST }
            GlassesAssistantScreen()
        }

        ScreenState.COACHING -> {
            BackHandler { currentScreen = ScreenState.PERSON_LIST }
            CoachingScreen(onNavigateBack = { currentScreen = ScreenState.PERSON_LIST })
        }

        ScreenState.STREAMING -> {
            BackHandler { currentScreen = ScreenState.PERSON_LIST }
            StreamingScreen(onNavigateBack = { currentScreen = ScreenState.PERSON_LIST })
        }
    }
}

@Composable
fun PhoneCameraWrapper(onNavigateBack: () -> Unit = {}) {
    val context = LocalContext.current
    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.CAMERA
            ) == PackageManager.PERMISSION_GRANTED
        )
    }

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted -> hasPermission = isGranted }

    LaunchedEffect(Unit) {
        if (!hasPermission) launcher.launch(Manifest.permission.CAMERA)
    }

    if (hasPermission) {
        CameraScreen(onNavigateBack = onNavigateBack)
    } else {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.fillMaxSize().padding(24.dp)
        ) {
            Text(
                text = "카메라 권한이 필요합니다",
                style = MaterialTheme.typography.titleMedium
            )
            Spacer(Modifier.height(12.dp))
            Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) {
                Text("권한 허용하기")
            }
        }
    }
}

package com.example.facedetectionapp

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.MediaStore
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.facedetectionapp.data.OpenAIRepository
import com.example.facedetectionapp.data.Person
import com.example.facedetectionapp.data.PersonViewModel
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.roundToInt

data class FaceResult(val rect: Rect, val name: String, val info: String, val distance: Float)

@OptIn(ExperimentalGetImage::class, ExperimentalMaterial3Api::class)
@Composable
fun CameraScreen(
    onNavigateBack: () -> Unit = {},
    viewModel: PersonViewModel = viewModel()
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()

    // Room DB 명단
    val registeredPeople by viewModel.allPeople.collectAsState()


    // 팝업 상태
    var showInputDialog by remember { mutableStateOf(false) }
    var showDetailDialog by remember { mutableStateOf<Person?>(null) }
    var personToDeleteFromDetail by remember { mutableStateOf<Person?>(null) }
    var showSummaryConfirmDialog by remember { mutableStateOf(false) }

    // 데이터 상태
    var lensFacing by remember { mutableIntStateOf(CameraSelector.LENS_FACING_FRONT) }
    var faceResults by remember { mutableStateOf<List<FaceResult>>(emptyList()) }
    var currentFrameBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var selectedFaceBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var isRegistrationMode by remember { mutableStateOf(false) }
    var isEditingMode by remember { mutableStateOf(false) }
    var editingPersonId by remember { mutableIntStateOf(-1) }

    // 입력 필드
    var inputName by remember { mutableStateOf("") }
    var inputPhone by remember { mutableStateOf("") }
    var inputInfo by remember { mutableStateOf("") }

    var generatedSummary by remember { mutableStateOf("") }
    var isAILoading by remember { mutableStateOf(false) }

    var previewView by remember { mutableStateOf<PreviewView?>(null) }
    val classifier = remember { FaceClassifier(context) }
    val cameraExecutor = remember { Executors.newSingleThreadExecutor() }

    val detector = remember {
        val fastOptions = FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .build()
        FaceDetection.getClient(fastOptions)
    }

    // --- Helper Functions ---
    fun saveImageToStorage(bitmap: Bitmap, name: String) {
        try {
            val filename = "${name}.png"
            context.openFileOutput(filename, Context.MODE_PRIVATE).use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        } catch (e: Exception) { e.printStackTrace() }
    }

    fun loadImageFromStorage(name: String): Bitmap? {
        return try {
            val filename = "${name}.png"
            val file = File(context.filesDir, filename)
            if (file.exists()) BitmapFactory.decodeFile(file.absolutePath) else null
        } catch (e: Exception) { null }
    }

    // 1. 주소록 런처
    val contactPickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            result.data?.data?.let { uri ->
                val (name, phone) = getContactInfo(context, uri)
                inputName = name
                inputPhone = phone
            }
        }
    }
    fun openContactPicker() { contactPickerLauncher.launch(Intent(Intent.ACTION_PICK, ContactsContract.CommonDataKinds.Phone.CONTENT_URI)) }

    // 2. 갤러리 이미지 가져오기
    val galleryLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri != null) {
            try {
                val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, _, _ ->
                        decoder.isMutableRequired = true
                    }
                } else {
                    @Suppress("DEPRECATION")
                    MediaStore.Images.Media.getBitmap(context.contentResolver, uri)
                }

                val scaledBitmap = Bitmap.createScaledBitmap(bitmap, 600, 600, true)

                val inputImage = InputImage.fromBitmap(scaledBitmap, 0)
                detector.process(inputImage)
                    .addOnSuccessListener { faces ->
                        if (faces.isNotEmpty()) {
                            val face = faces[0]
                            val rect = face.boundingBox

                            val safeX = rect.left.coerceAtLeast(0)
                            val safeY = rect.top.coerceAtLeast(0)
                            val safeWidth = rect.width().coerceAtMost(scaledBitmap.width - safeX)
                            val safeHeight = rect.height().coerceAtMost(scaledBitmap.height - safeY)

                            if (safeWidth > 0 && safeHeight > 0) {
                                val croppedFace = Bitmap.createBitmap(scaledBitmap, safeX, safeY, safeWidth, safeHeight)
                                selectedFaceBitmap = croppedFace

                                isEditingMode = false
                                inputName = ""
                                inputPhone = ""
                                inputInfo = ""
                                showInputDialog = true
                            } else {
                                Toast.makeText(context, "얼굴 영역을 자를 수 없습니다.", Toast.LENGTH_SHORT).show()
                            }
                        } else {
                            Toast.makeText(context, "사진에서 얼굴을 찾을 수 없습니다.", Toast.LENGTH_SHORT).show()
                        }
                    }
                    .addOnFailureListener {
                        Toast.makeText(context, "얼굴 인식 실패: ${it.message}", Toast.LENGTH_SHORT).show()
                    }

            } catch (e: Exception) {
                e.printStackTrace()
                Toast.makeText(context, "이미 로드 중 오류 발생", Toast.LENGTH_SHORT).show()
            }
        }
    }

    // ======================================================
    // UI Layout
    // ======================================================

    LaunchedEffect(lensFacing, previewView, registeredPeople) {
            val pView = previewView ?: return@LaunchedEffect
            val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                cameraProvider.unbindAll()
                val preview = Preview.Builder().build()
                preview.setSurfaceProvider(pView.surfaceProvider)
                val imageAnalysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                imageAnalysis.setAnalyzer(cameraExecutor) { imageProxy ->
                    val mediaImage = imageProxy.image
                    if (mediaImage != null) {
                        val inputImage = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                        detector.process(inputImage).addOnSuccessListener { faces ->
                            val results = mutableListOf<FaceResult>()
                            val frameBitmap = imageProxy.toBitmap()
                            val rotation = imageProxy.imageInfo.rotationDegrees.toFloat()
                            val rotatedFrame = if (rotation != 0f) rotateBitmap(frameBitmap, rotation) else frameBitmap
                            currentFrameBitmap = rotatedFrame
                            for (face in faces) {
                                val rect = face.boundingBox
                                val safeX = rect.left.coerceAtLeast(0)
                                val safeY = rect.top.coerceAtLeast(0)
                                val safeWidth = rect.width().coerceAtMost(rotatedFrame.width - safeX)
                                val safeHeight = rect.height().coerceAtMost(rotatedFrame.height - safeY)
                                if (safeWidth > 0 && safeHeight > 0) {
                                    val croppedFace = Bitmap.createBitmap(rotatedFrame, safeX, safeY, safeWidth, safeHeight)
                                    val currentEmbedding = classifier.getFaceEmbedding(croppedFace)
                                    var bestPerson: Person? = null
                                    var globalMinDistance = Float.MAX_VALUE
                                    for (person in registeredPeople) {
                                        var localMinDistance = Float.MAX_VALUE
                                        for (vector in person.embeddings) {
                                            val distance = classifier.calculateDistance(currentEmbedding, vector)
                                            if (distance < localMinDistance) localMinDistance = distance
                                        }
                                        if (localMinDistance < globalMinDistance) {
                                            globalMinDistance = localMinDistance
                                            bestPerson = person
                                        }
                                    }
                                    val isRecognized = (globalMinDistance < 0.85f && bestPerson != null)
                                    results.add(FaceResult(rect, if(isRecognized) bestPerson!!.name else "Unknown", if(isRecognized) bestPerson!!.info else "", globalMinDistance))
                                }
                            }
                            faceResults = results
                        }.addOnCompleteListener { imageProxy.close() }
                    } else imageProxy.close()
                }
                val cameraSelector = CameraSelector.Builder().requireLensFacing(lensFacing).build()
                try { cameraProvider.bindToLifecycle(lifecycleOwner, cameraSelector, preview, imageAnalysis) } catch (e: Exception) { e.printStackTrace() }
            }, ContextCompat.getMainExecutor(context))
        }

        BoxWithConstraints(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            val maxWidthPx = with(density) { maxWidth.toPx() }
            val maxHeightPx = with(density) { maxHeight.toPx() }

            // 터치 등록
            Box(
                modifier = Modifier.fillMaxSize().pointerInput(Unit) {
                    detectTapGestures { tapOffset ->
                        if (isRegistrationMode && currentFrameBitmap != null) {
                            val scaleX = maxWidthPx / 480f
                            val scaleY = maxHeightPx / 640f
                            val isFront = (lensFacing == CameraSelector.LENS_FACING_FRONT)
                            for (result in faceResults) {
                                if (result.name == "Unknown" && !isRegistrationMode) continue
                                val rect = result.rect
                                val left = if (isFront) maxWidthPx - (rect.right * scaleX) else rect.left * scaleX
                                val right = if (isFront) maxWidthPx - (rect.left * scaleX) else rect.right * scaleX
                                val top = rect.top * scaleY
                                val bottom = rect.bottom * scaleY
                                if (tapOffset.x in left..right && tapOffset.y in top..bottom) {
                                    try {
                                        val safeX = rect.left.coerceAtLeast(0)
                                        val safeY = rect.top.coerceAtLeast(0)
                                        val safeW = rect.width().coerceAtMost(currentFrameBitmap!!.width - safeX)
                                        val safeH = rect.height().coerceAtMost(currentFrameBitmap!!.height - safeY)
                                        if (safeW > 0 && safeH > 0) {
                                            selectedFaceBitmap = Bitmap.createBitmap(currentFrameBitmap!!, safeX, safeY, safeW, safeH)
                                            val existing = registeredPeople.find { it.name == result.name && result.name != "Unknown" }
                                            if (existing != null) {
                                                isEditingMode = true; editingPersonId = existing.id; inputName = existing.name; inputPhone = existing.phoneNumber ?: ""; inputInfo = existing.info
                                            } else {
                                                isEditingMode = false; inputName = ""; inputPhone = ""; inputInfo = ""
                                            }
                                            showInputDialog = true
                                        }
                                    } catch (e: Exception) { e.printStackTrace() }
                                    break
                                }
                            }
                        }
                    }
                }
            ) {
                AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx -> PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }.also { previewView = it } })

                Canvas(modifier = Modifier.fillMaxSize()) {
                    val scaleX = size.width / 480f; val scaleY = size.height / 640f
                    val isFront = (lensFacing == CameraSelector.LENS_FACING_FRONT)
                    for (result in faceResults) {
                        if (!isRegistrationMode && result.name == "Unknown") continue
                        val rect = result.rect
                        val left = if (isFront) size.width - (rect.right * scaleX) else rect.left * scaleX
                        val right = if (isFront) size.width - (rect.left * scaleX) else rect.right * scaleX
                        val top = rect.top * scaleY
                        val bottom = rect.bottom * scaleY
                        drawRoundRect(
                            color = if (result.name == "Unknown") Color(0xFFFF5252) else Color(0xFF00E676),
                            topLeft = Offset(left, top), size = Size(right - left, bottom - top),
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(20f, 20f), style = Stroke(width = 8f)
                        )
                    }
                }

                // 등록 모드 안내 오버레이
                if (isRegistrationMode) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(Color(0xCC000000))
                            .padding(vertical = 10.dp)
                            .align(Alignment.TopCenter),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            "👆 화면에 나타난 얼굴을 탭하여 등록하세요",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 14.sp
                        )
                    }
                }

                // 정보 오버레이
                BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                    val scaleX = maxWidth.value / 480f; val scaleY = maxHeight.value / 640f
                    val isFront = (lensFacing == CameraSelector.LENS_FACING_FRONT)
                    for (result in faceResults) {
                        if (result.name != "Unknown") {
                            val rect = result.rect
                            val rightSideX = if (isFront) 480f - rect.left else rect.right.toFloat()
                            val topSideY = rect.top.toFloat()
                            val offsetX = (rightSideX * scaleX).dp; val offsetY = (topSideY * scaleY).dp
                            Column(modifier = Modifier.offset { IntOffset(offsetX.roundToPx() + 20, offsetY.roundToPx()) }.widthIn(max = 200.dp).heightIn(max = 200.dp).verticalScroll(rememberScrollState())) {
                                Text(result.name, color = Color.Green, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                Text(result.info, color = Color.White, fontSize = 14.sp)
                            }
                        }
                    }
                }

                // ======================================
                // UI 버튼들
                // ======================================

                // 1. 카메라 전환
                IconButton(
                    onClick = { lensFacing = if (lensFacing == CameraSelector.LENS_FACING_FRONT) CameraSelector.LENS_FACING_BACK else CameraSelector.LENS_FACING_FRONT },
                    modifier = Modifier.align(Alignment.TopEnd).padding(16.dp).size(50.dp).background(Color.Black.copy(alpha = 0.5f), CircleShape)
                ) { Icon(Icons.Filled.Refresh, "Switch", tint = Color.White) }

                // 2. 우측 하단: 등록 모드 (기본 56dp FAB)
                FloatingActionButton(
                    onClick = { isRegistrationMode = !isRegistrationMode },
                    containerColor = if (isRegistrationMode) Color.Red else Color(0xFF2196F3),
                    contentColor = Color.White,
                    modifier = Modifier.align(Alignment.BottomEnd).padding(30.dp)
                ) { if (isRegistrationMode) Icon(Icons.Filled.Close, "닫기") else Icon(Icons.Filled.Add, "등록") }

                // 3. 좌측 하단: 갤러리 등록 버튼
                FloatingActionButton(
                    onClick = { galleryLauncher.launch("image/*") },
                    containerColor = Color(0xFF673AB7),
                    contentColor = Color.White,
                    modifier = Modifier.align(Alignment.BottomStart).padding(30.dp)
                ) { Icon(Icons.Filled.Add, "갤러리 등록") }

                // 4. 중앙 하단: 설문조사 버튼
                Button(
                    onClick = {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://forms.gle/mKwcPaDwhtc7o3HG7"))
                        context.startActivity(intent)
                    },
                    modifier = Modifier
                        .align(Alignment.BottomCenter) // 하단 중앙 정렬
                        .padding(bottom = 30.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFFFFC107).copy(alpha = 0.9f), // 눈에 띄는 노란색
                        contentColor = Color.Black
                    ),
                    shape = RoundedCornerShape(24.dp)
                ) {
                    Text("📝 설문 참여", fontWeight = FontWeight.Bold)
                }
            }
        }

    // ================= [팝업 영역] =================

    // 0. 삭제 확인 다이얼로그
    personToDeleteFromDetail?.let { person ->
        AlertDialog(
            onDismissRequest = { personToDeleteFromDetail = null },
            icon = { Icon(Icons.Filled.Warning, null, tint = Color.Red) },
            title = { Text("삭제 확인") },
            text = { Text("${person.name}님의 모든 데이터를 삭제할까요?") },
            confirmButton = {
                Button(
                    onClick = {
                        File(context.filesDir, "${person.name}.png").delete()
                        viewModel.deletePerson(person)
                        personToDeleteFromDetail = null
                        showDetailDialog = null
                        Toast.makeText(context, "${person.name}님이 삭제되었습니다", Toast.LENGTH_SHORT).show()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Red)
                ) { Text("삭제") }
            },
            dismissButton = {
                TextButton(onClick = { personToDeleteFromDetail = null }) { Text("취소") }
            }
        )
    }

    // 1. 상세 정보 팝업
    if (showDetailDialog != null) {
        val person = showDetailDialog!!
        Dialog(onDismissRequest = { showDetailDialog = null }) {
            Surface(shape = RoundedCornerShape(24.dp), color = Color.White, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(24.dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
                    val savedImage = loadImageFromStorage(person.name)
                    if (savedImage != null) Image(bitmap = savedImage.asImageBitmap(), contentDescription = null, modifier = Modifier.size(150.dp).clip(RoundedCornerShape(16.dp)), contentScale = ContentScale.Crop)
                    else Box(modifier = Modifier.size(150.dp).background(Color.LightGray, RoundedCornerShape(16.dp)))
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(person.name, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    if (!person.phoneNumber.isNullOrBlank()) Text(person.phoneNumber, fontSize = 16.sp, color = Color.Gray)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(person.info, fontSize = 16.sp)
                    Spacer(modifier = Modifier.height(24.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { showDetailDialog = null }, modifier = Modifier.weight(1f), colors = ButtonDefaults.buttonColors(containerColor = Color.LightGray)) { Text("닫기", color = Color.Black) }
                        Button(onClick = {
                            personToDeleteFromDetail = person
                        }, modifier = Modifier.weight(1f), colors = ButtonDefaults.buttonColors(containerColor = Color.Red)) { Text("삭제") }
                    }
                }
            }
        }
    }

    // 2. 통합 입력 팝업
    if (showInputDialog) {
        Dialog(onDismissRequest = { showInputDialog = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(modifier = Modifier.fillMaxWidth(0.9f).wrapContentHeight().clip(RoundedCornerShape(24.dp)), color = Color.White) {
                Column(modifier = Modifier.padding(24.dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(if(isEditingMode) "정보 수정" else "신규 등록", fontSize = 20.sp, fontWeight = FontWeight.Bold)

                    if (selectedFaceBitmap != null) {
                        Image(bitmap = selectedFaceBitmap!!.asImageBitmap(), contentDescription = "Face", modifier = Modifier.size(120.dp).clip(RoundedCornerShape(12.dp)).border(1.dp, Color.Gray, RoundedCornerShape(12.dp)))
                    } else {
                        Box(modifier = Modifier.size(120.dp).background(Color.LightGray), contentAlignment = Alignment.Center) { Text("No Image") }
                    }

                    OutlinedButton(onClick = { openContactPicker() }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Filled.AccountCircle, null); Spacer(Modifier.width(8.dp)); Text("연락처 가져오기") }
                    OutlinedTextField(value = inputName, onValueChange = { inputName = it }, label = { Text("이름") }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = inputPhone, onValueChange = { inputPhone = it }, label = { Text("전화번호") }, modifier = Modifier.fillMaxWidth())

                    OutlinedTextField(
                        value = inputInfo,
                        onValueChange = { inputInfo = it },
                        label = { Text("메모 / 대화 내용") },
                        modifier = Modifier.fillMaxWidth().height(150.dp),
                        singleLine = false,
                        trailingIcon = {
                            IconButton(onClick = {
                                if (inputInfo.isBlank()) {
                                    Toast.makeText(context, "내용을 먼저 입력하세요!", Toast.LENGTH_SHORT).show()
                                } else {
                                    isAILoading = true
                                    scope.launch {
                                        try {
                                            val summary = withContext(Dispatchers.IO) { OpenAIRepository.summarizeText(inputInfo) }
                                            generatedSummary = summary
                                            isAILoading = false
                                            showSummaryConfirmDialog = true
                                        } catch (e: Exception) {
                                            isAILoading = false
                                            Toast.makeText(context, "AI 요약 실패: 네트워크를 확인해주세요", Toast.LENGTH_SHORT).show()
                                        }
                                    }
                                }
                            }) {
                                if (isAILoading) CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                                else Icon(Icons.Filled.AutoAwesome, "AI 요약 실행", tint = Color(0xFF673AB7))
                            }
                        }
                    )
                    Text("팁: 통화 내용이나 문자를 붙여넣고 ✨ 버튼을 누르세요.", fontSize = 12.sp, color = Color.Gray)

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                        OutlinedButton(onClick = { showInputDialog = false }) { Text("취소") }
                        Button(onClick = {
                            if (inputName.isBlank()) { Toast.makeText(context, "이름 입력 필수", Toast.LENGTH_SHORT).show(); return@Button }

                            if (selectedFaceBitmap != null) saveImageToStorage(selectedFaceBitmap!!, inputName)
                            val embeddings = if (selectedFaceBitmap != null) listOf(classifier.getFaceEmbedding(selectedFaceBitmap!!)) else emptyList()
                            val thumbnail = selectedFaceBitmap?.let { bmp ->
                                val scaled = android.graphics.Bitmap.createScaledBitmap(bmp, 96, 96, true)
                                val out = java.io.ByteArrayOutputStream()
                                scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, out)
                                out.toByteArray()
                            }

                            if (isEditingMode) {
                                registeredPeople.find { it.id == editingPersonId }?.let { original ->
                                    val newEmbeddings = if (embeddings.isNotEmpty()) original.embeddings.toMutableList().apply { add(embeddings[0]) } else original.embeddings
                                    val newThumbnails = if (thumbnail != null) original.photoThumbnails + thumbnail else original.photoThumbnails
                                    viewModel.updatePerson(original.copy(name = inputName, info = inputInfo, phoneNumber = inputPhone, embeddings = newEmbeddings, photoThumbnails = newThumbnails))
                                }
                                Toast.makeText(context, "✅ ${inputName} 정보가 수정되었습니다", Toast.LENGTH_SHORT).show()
                            } else {
                                if (embeddings.isEmpty()) { Toast.makeText(context, "사진이 필요합니다", Toast.LENGTH_SHORT).show(); return@Button }
                                viewModel.addPerson(name = inputName, info = inputInfo, phone = inputPhone, embeddings = embeddings, thumbnails = if (thumbnail != null) listOf(thumbnail) else emptyList())
                                Toast.makeText(context, "✅ ${inputName}님이 등록되었습니다", Toast.LENGTH_SHORT).show()
                            }
                            showInputDialog = false; isRegistrationMode = false
                        }) { Text("저장") }
                    }
                }
            }
        }
    }

    // 3. AI 요약 확인 팝업
    if (showSummaryConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showSummaryConfirmDialog = false },
            title = { Text("✨ AI 요약 완료") },
            text = {
                Column {
                    Text("AI가 내용을 다음과 같이 요약했습니다:", fontSize = 14.sp, color = Color.Gray)
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(generatedSummary, fontWeight = FontWeight.Bold)
                    Spacer(modifier = Modifier.height(16.dp))
                    Text("이 내용으로 덮어쓰시겠습니까?", fontSize = 14.sp, color = Color.Red)
                }
            },
            confirmButton = {
                Button(onClick = {
                    inputInfo = generatedSummary
                    showSummaryConfirmDialog = false
                }) { Text("덮어쓰기") }
            },
            dismissButton = {
                TextButton(onClick = { showSummaryConfirmDialog = false }) { Text("취소") }
            }
        )
    }
}

// ... 하단 Helper 함수는 기존과 동일 ...
@SuppressLint("Range")
fun getContactInfo(context: Context, contactUri: Uri): Pair<String, String> {
    var name = ""; var phone = ""
    try {
        val cursor = context.contentResolver.query(contactUri, null, null, null, null)
        if (cursor != null && cursor.moveToFirst()) {
            name = cursor.getString(cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)) ?: ""
            phone = cursor.getString(cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)) ?: ""
            cursor.close()
        }
    } catch (e: Exception) { e.printStackTrace() }
    return Pair(name, phone)
}

fun rotateBitmap(bitmap: Bitmap, degrees: Float): Bitmap {
    val matrix = Matrix(); matrix.postRotate(degrees)
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}
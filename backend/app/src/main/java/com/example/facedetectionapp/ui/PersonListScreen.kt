package com.example.facedetectionapp.ui

import android.graphics.BitmapFactory
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.facedetectionapp.data.Person
import com.example.facedetectionapp.data.PersonViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PersonListScreen(
    onPhoneModeClick: () -> Unit,
    onGlassesModeClick: () -> Unit,
    onCoachingClick: () -> Unit = {},
    onStreamingClick: () -> Unit = {},
    viewModel: PersonViewModel = viewModel()
) {
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    var searchQuery by remember { mutableStateOf("") }
    val allPeople by viewModel.allPeople.collectAsState()
    val filteredPeople = remember(allPeople, searchQuery) {
        if (searchQuery.isBlank()) allPeople
        else allPeople.filter {
            it.name.contains(searchQuery, ignoreCase = true) ||
            it.info.contains(searchQuery, ignoreCase = true) ||
            it.company?.contains(searchQuery, ignoreCase = true) == true ||
            it.jobTitle?.contains(searchQuery, ignoreCase = true) == true
        }
    }

    var selectedPerson by remember { mutableStateOf<Person?>(null) }
    var personToDelete by remember { mutableStateOf<Person?>(null) }

    // 삭제 확인 다이얼로그
    personToDelete?.let { person ->
        AlertDialog(
            onDismissRequest = { personToDelete = null },
            icon = { Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
            title = { Text("삭제 확인") },
            text = { Text("${person.name}님의 정보와 등록된 얼굴 데이터를 모두 삭제할까요?") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deletePerson(person)
                    personToDelete = null
                }) { Text("삭제", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold) }
            },
            dismissButton = {
                TextButton(onClick = { personToDelete = null }) { Text("취소") }
            }
        )
    }

    // 인물 상세 보기 다이얼로그
    selectedPerson?.let { person ->
        AlertDialog(
            onDismissRequest = { selectedPerson = null },
            title = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primaryContainer),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = person.name.take(1),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(person.name, fontWeight = FontWeight.Bold)
                }
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (!person.company.isNullOrBlank())
                        DetailRow(icon = Icons.Filled.Business, text = person.company!!)
                    if (!person.jobTitle.isNullOrBlank())
                        DetailRow(icon = Icons.Filled.Work, text = person.jobTitle!!)
                    if (!person.phoneNumber.isNullOrBlank())
                        DetailRow(icon = Icons.Filled.Phone, text = person.phoneNumber!!)
                    if (!person.email.isNullOrBlank())
                        DetailRow(icon = Icons.Filled.Email, text = person.email!!)
                    if (person.info.isNotBlank()) {
                        HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                        Text(person.info, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
                    Text(
                        "등록된 얼굴 데이터: ${person.embeddings.size}컷",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (person.photoThumbnails.isNotEmpty()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "등록 사진",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(Modifier.height(6.dp))
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(person.photoThumbnails) { bytes ->
                                val bitmap = remember(bytes) {
                                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                }
                                if (bitmap != null) {
                                    androidx.compose.foundation.Image(
                                        bitmap = bitmap.asImageBitmap(),
                                        contentDescription = "등록된 얼굴",
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier
                                            .size(72.dp)
                                            .clip(RoundedCornerShape(8.dp))
                                    )
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { selectedPerson = null }) { Text("닫기") }
            },
            dismissButton = {
                TextButton(onClick = {
                    personToDelete = person
                    selectedPerson = null
                }) { Text("삭제", color = MaterialTheme.colorScheme.error) }
            }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            Column {
                TopAppBar(
                    title = {
                        Column {
                            Text("인맥 관리 비서", fontWeight = FontWeight.Bold)
                            Text(
                                text = "등록된 인물 ${allPeople.size}명",
                                fontSize = 12.sp,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.surface
                    )
                )
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = { Text("이름, 회사, 메모 검색") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Filled.Clear, contentDescription = "지우기")
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp)
                )
            }
        },
        bottomBar = {
            Surface(shadowElevation = 8.dp) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = {
                            if (allPeople.isEmpty()) {
                                scope.launch { snackbarHostState.showSnackbar("등록된 인물이 없습니다. 먼저 얼굴을 등록해주세요.") }
                            }
                            onPhoneModeClick()
                        },
                        modifier = Modifier.weight(1f).height(52.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        Icon(Icons.Filled.CameraAlt, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("폰으로 인식", fontWeight = FontWeight.Bold)
                    }
                    Button(
                        onClick = {
                            if (allPeople.isEmpty()) {
                                scope.launch { snackbarHostState.showSnackbar("등록된 인물이 없습니다. 글라스 등록 모드에서 먼저 얼굴을 등록해주세요.") }
                            }
                            onGlassesModeClick()
                        },
                        modifier = Modifier.weight(1f).height(52.dp),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7B2FBE))
                    ) {
                        Icon(Icons.Filled.Visibility, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("글라스 모드", fontWeight = FontWeight.Bold)
                    }
                } // Row 끝
                // 두 번째 행: AI 코칭 + 라이브 스트리밍
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = onCoachingClick,
                        modifier = Modifier.weight(1f).height(48.dp),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1B5E20))
                    ) {
                        Icon(Icons.Filled.Psychology, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("AI 코칭", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }
                    Button(
                        onClick = onStreamingClick,
                        modifier = Modifier.weight(1f).height(48.dp),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFB71C1C))
                    ) {
                        Icon(Icons.Filled.FiberManualRecord, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("라이브", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }
                }
                } // Column 끝
            }
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onPhoneModeClick,
                icon = { Icon(Icons.Filled.PersonAdd, contentDescription = null) },
                text = { Text("얼굴 등록") },
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer
            )
        },
        floatingActionButtonPosition = FabPosition.End
    ) { innerPadding ->
        if (filteredPeople.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize().padding(innerPadding),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Icon(
                        Icons.Filled.PersonSearch,
                        contentDescription = null,
                        modifier = Modifier.size(72.dp),
                        tint = MaterialTheme.colorScheme.outlineVariant
                    )
                    Text(
                        text = if (searchQuery.isBlank())
                            "등록된 인물이 없습니다\n하단 버튼으로 얼굴을 등록해보세요"
                        else "\"$searchQuery\" 검색 결과가 없습니다",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 15.sp,
                        lineHeight = 22.sp
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(filteredPeople, key = { it.id }) { person ->
                    PersonItem(
                        person = person,
                        onClick = { selectedPerson = person },
                        onDelete = { personToDelete = person }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PersonItem(
    person: Person,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onDelete()
            }
            false
        }
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.errorContainer),
                contentAlignment = Alignment.CenterEnd
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(end = 20.dp)
                ) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription = "삭제",
                        tint = MaterialTheme.colorScheme.onErrorContainer
                    )
                    Spacer(Modifier.width(4.dp))
                    Text("삭제", color = MaterialTheme.colorScheme.onErrorContainer, fontWeight = FontWeight.Bold)
                }
            }
        }
    ) {
        Card(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth().animateContentSize(),
            shape = RoundedCornerShape(12.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
        ) {
            Row(
                modifier = Modifier.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = person.name.take(1),
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
                Spacer(modifier = Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = person.name,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    val subtitle = listOfNotNull(person.company, person.jobTitle).joinToString(" · ")
                    if (subtitle.isNotBlank()) {
                        Text(
                            text = subtitle,
                            fontSize = 13.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (person.info.isNotBlank()) {
                        Text(
                            text = person.info,
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.outline,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
                Spacer(Modifier.width(8.dp))
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.secondaryContainer
                ) {
                    Text(
                        text = "${person.embeddings.size}컷",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        color = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }
            }
        }
    }
}

@Composable
private fun DetailRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(8.dp))
        Text(text, fontSize = 14.sp)
    }
}

package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.content.Intent
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.CollectionsBookmark
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Groups2
import androidx.compose.material.icons.filled.ImageSearch
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting.MeetingHistoryItem
import com.meta.wearable.dat.externalsampleapps.cameraaccess.meeting.MeetingHistoryViewModel
import com.meta.wearable.dat.externalsampleapps.cameraaccess.memory.MemoryItem
import com.meta.wearable.dat.externalsampleapps.cameraaccess.memory.MemoryRepository
import com.meta.wearable.dat.externalsampleapps.cameraaccess.memory.MemoryViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private enum class RecordsTab(val title: String) {
    Memories("기억"),
    Meetings("회의"),
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun MemoryScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    memoryViewModel: MemoryViewModel = viewModel(),
    meetingViewModel: MeetingHistoryViewModel = viewModel(),
) {
    val memoryUiState by memoryViewModel.uiState.collectAsStateWithLifecycle()
    val meetingUiState by meetingViewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var selectedTab by rememberSaveable { mutableStateOf(RecordsTab.Memories) }
    var selectedMemory by remember { mutableStateOf<MemoryItem?>(null) }
    var selectedMeeting by remember { mutableStateOf<MeetingHistoryItem?>(null) }
    var editingMemory by remember { mutableStateOf<MemoryItem?>(null) }
    var editingMeeting by remember { mutableStateOf<MeetingHistoryItem?>(null) }
    var pendingDeleteMemory by remember { mutableStateOf<MemoryItem?>(null) }
    var pendingDeleteMeeting by remember { mutableStateOf<MeetingHistoryItem?>(null) }

    LaunchedEffect(Unit) {
        memoryViewModel.loadRecent()
        meetingViewModel.loadRecent()
    }

    val currentTitle = when {
        selectedMemory != null -> "기억 상세"
        selectedMeeting != null -> "회의 상세"
        else -> "Jarvis Records"
    }

    BackHandler(enabled = selectedMemory != null || selectedMeeting != null) {
        when {
            selectedMemory != null -> selectedMemory = null
            selectedMeeting != null -> selectedMeeting = null
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(currentTitle) },
                navigationIcon = {
                    IconButton(
                        onClick = {
                            when {
                                selectedMemory != null -> selectedMemory = null
                                selectedMeeting != null -> selectedMeeting = null
                                else -> onBack()
                            }
                        }
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    when {
                        selectedMemory != null -> {
                            IconButton(onClick = { editingMemory = selectedMemory }) {
                                Icon(Icons.Default.Edit, contentDescription = "Edit memory")
                            }
                            IconButton(onClick = { pendingDeleteMemory = selectedMemory }) {
                                Icon(Icons.Default.DeleteOutline, contentDescription = "Delete memory")
                            }
                        }
                        selectedMeeting != null -> {
                            IconButton(onClick = { editingMeeting = selectedMeeting }) {
                                Icon(Icons.Default.Edit, contentDescription = "Edit meeting")
                            }
                            IconButton(onClick = {
                                selectedMeeting?.let { meeting ->
                                    val shareText = meetingViewModel.shareText(meeting)
                                    val intent = Intent(Intent.ACTION_SEND).apply {
                                        type = "text/plain"
                                        putExtra(Intent.EXTRA_TEXT, shareText)
                                    }
                                    context.startActivity(Intent.createChooser(intent, "회의 공유"))
                                }
                            }) {
                                Icon(Icons.Default.Share, contentDescription = "Share meeting")
                            }
                            IconButton(onClick = { pendingDeleteMeeting = selectedMeeting }) {
                                Icon(Icons.Default.DeleteOutline, contentDescription = "Delete meeting")
                            }
                        }
                        else -> {
                            IconButton(
                                onClick = {
                                    when (selectedTab) {
                                        RecordsTab.Memories -> memoryViewModel.refreshCurrent()
                                        RecordsTab.Meetings -> meetingViewModel.loadRecent()
                                    }
                                }
                            ) {
                                Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                            }
                        }
                    }
                },
            )
        },
    ) { padding ->
        when {
            selectedMemory != null -> {
                MemoryDetail(
                    memory = selectedMemory!!,
                    modifier = Modifier.padding(padding),
                )
            }
            selectedMeeting != null -> {
                MeetingDetail(
                    meeting = selectedMeeting!!,
                    modifier = Modifier.padding(padding),
                )
            }
            else -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(horizontal = 16.dp),
                ) {
                    SummaryHeader(
                        memoryCount = memoryUiState.memories.size,
                        meetingCount = meetingUiState.meetings.size,
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    TabRow(selectedTabIndex = selectedTab.ordinal) {
                        RecordsTab.entries.forEach { tab ->
                            Tab(
                                selected = selectedTab == tab,
                                onClick = { selectedTab = tab },
                                text = {
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(
                                            imageVector = if (tab == RecordsTab.Memories) {
                                                Icons.Default.AutoStories
                                            } else {
                                                Icons.Default.Groups2
                                            },
                                            contentDescription = null,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Text(tab.title)
                                    }
                                },
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(12.dp))

                    if (selectedTab == RecordsTab.Memories) {
                        SearchBar(
                            value = memoryUiState.query,
                            onValueChange = memoryViewModel::updateQuery,
                            onSearch = memoryViewModel::search,
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                    }

                    when (selectedTab) {
                        RecordsTab.Memories -> {
                            RecordsState(
                                isLoading = memoryUiState.isLoading,
                                errorMessage = memoryUiState.errorMessage,
                                emptyText = "저장된 기억이 없습니다.",
                                isEmpty = memoryUiState.memories.isEmpty(),
                            ) {
                                LazyColumn(
                                    verticalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    items(memoryUiState.memories, key = { it.id }) { memory ->
                                        MemoryCard(
                                            memory = memory,
                                            onClick = { selectedMemory = memory },
                                        )
                                    }
                                }
                            }
                        }
                        RecordsTab.Meetings -> {
                            RecordsState(
                                isLoading = meetingUiState.isLoading,
                                errorMessage = meetingUiState.errorMessage,
                                emptyText = "저장된 회의가 없습니다.",
                                isEmpty = meetingUiState.meetings.isEmpty(),
                            ) {
                                LazyColumn(
                                    verticalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    items(meetingUiState.meetings, key = { it.id }) { meeting ->
                                        MeetingCard(
                                            meeting = meeting,
                                            onClick = { selectedMeeting = meeting },
                                            onShare = {
                                                val shareText = meetingViewModel.shareText(meeting)
                                                val intent = Intent(Intent.ACTION_SEND).apply {
                                                    type = "text/plain"
                                                    putExtra(Intent.EXTRA_TEXT, shareText)
                                                }
                                                context.startActivity(
                                                    Intent.createChooser(intent, "회의 공유")
                                                )
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    editingMemory?.let { current ->
        MemoryEditDialog(
            memory = current,
            isSaving = memoryUiState.isSaving,
            onDismiss = { editingMemory = null },
            onSave = { updated ->
                memoryViewModel.updateMemory(updated) {
                    selectedMemory = it
                    editingMemory = null
                }
            },
        )
    }

    editingMeeting?.let { current ->
        MeetingEditDialog(
            meeting = current,
            isSaving = meetingUiState.isSaving,
            onDismiss = { editingMeeting = null },
            onSave = { updated ->
                meetingViewModel.updateMeeting(updated) {
                    selectedMeeting = it
                    editingMeeting = null
                }
            },
        )
    }

    pendingDeleteMemory?.let { memory ->
        DeleteDialog(
            title = "기억 삭제",
            body = "이 기억을 삭제하면 되돌릴 수 없습니다.",
            isSaving = memoryUiState.isSaving,
            onDismiss = { pendingDeleteMemory = null },
            onConfirm = {
                memoryViewModel.deleteMemory(memory.id) {
                    if (selectedMemory?.id == memory.id) selectedMemory = null
                    pendingDeleteMemory = null
                }
            },
        )
    }

    pendingDeleteMeeting?.let { meeting ->
        DeleteDialog(
            title = "회의 삭제",
            body = "이 회의와 연결된 회의 메모도 함께 삭제됩니다.",
            isSaving = meetingUiState.isSaving,
            onDismiss = { pendingDeleteMeeting = null },
            onConfirm = {
                meetingViewModel.deleteMeeting(meeting.id) {
                    if (selectedMeeting?.id == meeting.id) selectedMeeting = null
                    pendingDeleteMeeting = null
                }
            },
        )
    }
}

@Composable
private fun SummaryHeader(
    memoryCount: Int,
    meetingCount: Int,
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.CollectionsBookmark,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = "기억과 회의 기록",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CountTile(label = "기억", value = memoryCount.toString(), modifier = Modifier.weight(1f))
                CountTile(label = "회의", value = meetingCount.toString(), modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun CountTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(10.dp),
        tonalElevation = 2.dp,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(text = label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(text = value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun SearchBar(
    value: String,
    onValueChange: (String) -> Unit,
    onSearch: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text("기억 검색") },
            placeholder = { Text("예: 투자자 명함, 회의실 문서") },
            singleLine = true,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onSearch) {
            Icon(Icons.Default.Search, contentDescription = "Search")
        }
    }
}

@Composable
private fun RecordsState(
    isLoading: Boolean,
    errorMessage: String?,
    isEmpty: Boolean,
    emptyText: String,
    content: @Composable () -> Unit,
) {
    when {
        isLoading -> {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
        errorMessage != null -> {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = errorMessage, color = MaterialTheme.colorScheme.error)
            }
        }
        isEmpty -> {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(text = emptyText, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        else -> content()
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MemoryCard(
    memory: MemoryItem,
    onClick: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            MemoryThumbnail(filename = memory.imageFilename)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = {}, label = { Text(memory.memoryTypeLabel()) })
                AssistChip(onClick = {}, label = { Text(memory.capturedAtDisplay) })
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = memory.userNote ?: memory.text.lineSequence().firstOrNull().orEmpty(),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            memory.aiInterpretation?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = "이 기억은 ${memory.recallHint()}로 다시 찾기 쉽습니다.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (memory.labels.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    memory.labels.take(4).forEach { label ->
                        AssistChip(onClick = {}, label = { Text(label) })
                    }
                }
            }
        }
    }
}

@Composable
private fun MemoryDetail(
    memory: MemoryItem,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            MemoryThumbnail(filename = memory.imageFilename, large = true)
        }
        item {
            MemoryRecallHeader(memory = memory)
        }
        item {
            DetailSection("사용자 메모", memory.userNote ?: memory.text)
        }
        memory.aiInterpretation?.let {
            item {
                IconDetailSection(
                    title = "AI 장면 해석",
                    body = it,
                    icon = {
                        Icon(
                            imageVector = Icons.Default.ImageSearch,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                )
            }
        }
        memory.peopleText?.let {
            item {
                IconDetailSection(
                    title = "관련 사람",
                    body = it,
                    icon = {
                        Icon(
                            imageVector = Icons.Default.PersonSearch,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                )
            }
        }
        item {
            RecallExamplesCard(memory = memory)
        }
        item {
            ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("기본 정보", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    MetadataRow("저장 시간", memory.capturedAtDisplay)
                    MetadataRow("출처", memory.source)
                    MetadataRow("유형", memory.memoryTypeLabel())
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MemoryRecallHeader(memory: MemoryItem) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.Lightbulb,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = "이 기억",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Text(
                text = memory.userNote ?: memory.aiInterpretation ?: memory.text,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = "${memory.capturedAtDisplay}에 저장된 ${memory.memoryTypeLabel()}입니다.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                memory.labels.take(6).forEach { label ->
                    AssistChip(onClick = {}, label = { Text(label) })
                }
            }
        }
    }
}

@Composable
private fun RecallExamplesCard(memory: MemoryItem) {
    val examples = memory.recallExamples()
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "이렇게 다시 물어보세요",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            examples.forEach { example ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                    shape = RoundedCornerShape(10.dp),
                ) {
                    Text(
                        text = example,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MeetingCard(
    meeting: MeetingHistoryItem,
    onClick: () -> Unit,
    onShare: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = meeting.title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = meeting.timeDisplay,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(onClick = onShare) {
                    Icon(Icons.Default.Share, contentDescription = "Share meeting")
                }
            }
            meeting.durationDisplay?.let {
                AssistChip(onClick = {}, label = { Text(it) })
            }
            meeting.summary?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (meeting.decisions.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    meeting.decisions.take(3).forEach { decision ->
                        AssistChip(onClick = {}, label = { Text(decision) })
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun MeetingDetail(
    meeting: MeetingHistoryItem,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(meeting.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    MetadataRow("회의 시간", meeting.timeDisplay)
                    meeting.durationDisplay?.let { MetadataRow("소요 시간", it) }
                }
            }
        }
        item {
            MarkdownDetailCard(
                title = "회의 요약",
                body = meeting.markdownSummary ?: meeting.summary.orEmpty(),
            )
        }
        if (meeting.actionItems.isNotEmpty()) {
            item {
                StructuredListCard(
                    title = "Action Item",
                    items = meeting.actionItems,
                    icon = {
                        Icon(
                            imageVector = Icons.Default.TaskAlt,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                )
            }
        }
        if (meeting.decisions.isNotEmpty()) {
            item {
                StructuredListCard(
                    title = "결정 사항",
                    items = meeting.decisions,
                    icon = {
                        Icon(
                            imageVector = Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                )
            }
        }
        if (meeting.keywords.isNotEmpty()) {
            item {
                ElevatedCard(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text("키워드", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            meeting.keywords.forEach { keyword ->
                                AssistChip(onClick = {}, label = { Text(keyword) })
                            }
                        }
                    }
                }
            }
        }
        if (meeting.transcript?.isNotBlank() == true) {
            item {
                DetailSection("회의록 원문", meeting.transcript)
            }
        }
    }
}

@Composable
private fun DetailSection(
    title: String,
    body: String,
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(body, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun IconDetailSection(
    title: String,
    body: String,
    icon: @Composable () -> Unit,
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                icon()
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            Text(body, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun StructuredListCard(
    title: String,
    items: List<String>,
    icon: @Composable () -> Unit,
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                icon()
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            items.forEach { item ->
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                    shape = RoundedCornerShape(10.dp),
                ) {
                    Text(
                        text = item,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun MetadataRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun MarkdownDetailCard(
    title: String,
    body: String,
) {
    ElevatedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            body.lineSequence().forEach { line ->
                val trimmed = line.trim()
                when {
                    trimmed.startsWith("# ") -> Text(
                        trimmed.removePrefix("# ").trim(),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    trimmed.startsWith("## ") -> Text(
                        trimmed.removePrefix("## ").trim(),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    trimmed.startsWith("- ") -> Text(
                        "• ${trimmed.removePrefix("- ").trim()}",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    trimmed.isBlank() -> Spacer(modifier = Modifier.height(2.dp))
                    else -> Text(trimmed, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun MemoryEditDialog(
    memory: MemoryItem,
    isSaving: Boolean,
    onDismiss: () -> Unit,
    onSave: (MemoryItem) -> Unit,
) {
    var userNote by remember(memory) { mutableStateOf(memory.userNote.orEmpty()) }
    var aiInterpretation by remember(memory) { mutableStateOf(memory.aiInterpretation.orEmpty()) }
    var peopleText by remember(memory) { mutableStateOf(memory.peopleText.orEmpty()) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("기억 수정") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(value = userNote, onValueChange = { userNote = it }, label = { Text("메모") })
                OutlinedTextField(
                    value = aiInterpretation,
                    onValueChange = { aiInterpretation = it },
                    label = { Text("AI 해석") },
                )
                OutlinedTextField(value = peopleText, onValueChange = { peopleText = it }, label = { Text("관련 사람") })
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isSaving,
                onClick = {
                    onSave(
                        memory.copy(
                            userNote = userNote.ifBlank { null },
                            aiInterpretation = aiInterpretation.ifBlank { null },
                            peopleText = peopleText.ifBlank { null },
                        )
                    )
                },
            ) { Text("저장") }
        },
        dismissButton = {
            TextButton(enabled = !isSaving, onClick = onDismiss) { Text("취소") }
        },
    )
}

@Composable
private fun MeetingEditDialog(
    meeting: MeetingHistoryItem,
    isSaving: Boolean,
    onDismiss: () -> Unit,
    onSave: (MeetingHistoryItem) -> Unit,
) {
    var title by remember(meeting) { mutableStateOf(meeting.title) }
    var summary by remember(meeting) { mutableStateOf(meeting.summary.orEmpty()) }
    var markdownSummary by remember(meeting) { mutableStateOf(meeting.markdownSummary.orEmpty()) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("회의 수정") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("제목") })
                OutlinedTextField(value = summary, onValueChange = { summary = it }, label = { Text("요약") })
                OutlinedTextField(
                    value = markdownSummary,
                    onValueChange = { markdownSummary = it },
                    label = { Text("회의록 마크다운") },
                    minLines = 5,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isSaving,
                onClick = {
                    onSave(
                        meeting.copy(
                            title = title,
                            summary = summary.ifBlank { null },
                            markdownSummary = markdownSummary.ifBlank { null },
                        )
                    )
                },
            ) { Text("저장") }
        },
        dismissButton = {
            TextButton(enabled = !isSaving, onClick = onDismiss) { Text("취소") }
        },
    )
}

@Composable
private fun DeleteDialog(
    title: String,
    body: String,
    isSaving: Boolean,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            TextButton(enabled = !isSaving, onClick = onConfirm) { Text("삭제") }
        },
        dismissButton = {
            TextButton(enabled = !isSaving, onClick = onDismiss) { Text("취소") }
        },
    )
}

@Composable
private fun MemoryThumbnail(
    filename: String?,
    large: Boolean = false,
) {
    if (filename == null) return
    val repository = remember { MemoryRepository() }
    val bitmap by produceState<Bitmap?>(initialValue = null, filename) {
        value = withContext(Dispatchers.IO) { repository.loadImage(filename) }
    }
    bitmap?.let {
        Image(
            bitmap = it.asImageBitmap(),
            contentDescription = "Memory image",
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(if (large) 4f / 3f else 16f / 9f)
                .background(Color.Black.copy(alpha = 0.04f)),
            contentScale = ContentScale.Crop,
        )
    }
}

private fun MemoryItem.memoryTypeLabel(): String {
    val normalized = labels.map { it.lowercase() }
    return when {
        normalized.any { it.contains("business_card") } -> "명함"
        normalized.any { it.contains("document") } -> "문서"
        normalized.any { it.contains("person") } -> "사람"
        normalized.any { it.contains("vehicle") } -> "차량"
        normalized.any { it.contains("food") } -> "음식"
        normalized.any { it.contains("place") } -> "장소"
        source == "voice" -> "음성 기억"
        source == "camera" -> "시야 기억"
        else -> "기억"
    }
}

private fun MemoryItem.recallHint(): String {
    val key = userNote
        ?: peopleText
        ?: labels.firstOrNull()
        ?: text.lineSequence().firstOrNull()
        ?: "저장한 내용"
    return key.take(24)
}

private fun MemoryItem.recallExamples(): List<String> {
    val type = memoryTypeLabel()
    val hint = recallHint()
    val label = labels.firstOrNull()?.replace("_", " ")
    return listOfNotNull(
        "\"$hint\" 찾아줘",
        if (type != "기억") "\"지난번 저장한 $type\" 보여줘" else null,
        if (!label.isNullOrBlank()) "\"$label 관련해서 저장한 거 뭐였지?\"" else null,
    ).distinct().take(3)
}

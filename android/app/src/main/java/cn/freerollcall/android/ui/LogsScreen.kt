package cn.freerollcall.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cn.freerollcall.android.app.*
import cn.freerollcall.android.core.displayTime
import cn.freerollcall.android.storage.AttendanceLog
import cn.freerollcall.android.storage.LogResult

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun LogsScreen(model: AppModel, state: UiState) {
    var selectedId by remember { mutableStateOf<String?>(null) }
    val logs = state.logs
    PageHeader("本地日志")
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 24.dp), contentPadding = PaddingValues(bottom = 20.dp)) {
        if (logs.isEmpty()) item(key = "logs-empty", contentType = "empty") { EmptyState("还没有签到记录", "签到操作的结果会保存在本机，离线也能查看") }
        items(logs, key = { it.id }, contentType = { "log" }) { log ->
            LogRow(log) { selectedId = log.id }
        }
    }
    selectedId?.let { id -> state.logs.firstOrNull { it.id == id }?.let { log ->
        ModalBottomSheet(onDismissRequest = { selectedId = null }, containerColor = Color.White) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp).navigationBarsPadding()) {
                Text("签到记录", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(16.dp))
                FieldLine("时间", displayTime(log.createdAt)); FieldLine("课程", log.courseName)
                FieldLine("签到形式", log.kind.title); FieldLine("结果", log.result.title)
                FieldLine("账号", log.username)
                if (log.accountNote.isNotEmpty()) FieldLine("备注", log.accountNote)
                FieldLine("签到码", log.codeText); Message(log.message)
                if (log.result == LogResult.UNCERTAIN) {
                    Button(onClick = { model.reconcile(id) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) {
                        Text(if (state.busy) "正在核对…" else "核对学校端结果")
                    }
                    Message("使用本条记录对应的账号查询，不会再次提交签到")
                }
                TextButton(onClick = { selectedId = null }, modifier = Modifier.align(Alignment.End)) { Text("完成") }
            }
        }
    } }
}
@Composable private fun LogRow(log: AttendanceLog, click: () -> Unit) {
    val timeText = remember(log.createdAt) { displayTime(log.createdAt) }
    val accountText = remember(log.accountNote, log.username) {
        if (log.accountNote.isEmpty()) log.username else "${log.accountNote} · ${log.username}"
    }
    Column(Modifier.fillMaxWidth().clickable(onClick = click).testTag("log-${log.id}").padding(vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Text(log.courseName, Modifier.weight(1f), fontWeight = FontWeight.Medium, fontSize = 16.sp)
            Spacer(Modifier.width(12.dp))
            Text(log.result.title, color = if (log.result == LogResult.FAILURE) Danger else Secondary, fontSize = 12.sp)
        }
        Text(timeText, color = Secondary, fontSize = 12.sp)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(log.kind.title, fontSize = 14.sp); Text(log.codeText, fontSize = 14.sp)
        }
        Text(accountText, color = Secondary, fontSize = 12.sp)
    }
    HorizontalDivider(color = Line)
}

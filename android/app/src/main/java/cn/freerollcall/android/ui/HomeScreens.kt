package cn.freerollcall.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cn.freerollcall.android.app.*
import cn.freerollcall.android.core.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun HomeScreens(model: AppModel, state: UiState) {
    var detailId by remember { mutableStateOf<String?>(null) }
    val pageStates = rememberSaveableStateHolder()
    val pageKey = "${state.currentAccountId}:${state.page}:${state.selectedCourse?.id}"
    PageHeader(when (state.page) { HomePage.HOME -> "功能"; HomePage.COURSES -> "本学期课程"; HomePage.HISTORY -> "课程签到" },
        back = if (state.page == HomePage.HOME) null else ({ model.back(); Unit }),
        action = if (state.page == HomePage.HOME) null else ({
            IconButton(onClick = { if (state.page == HomePage.COURSES) model.refreshCourses() else model.refreshHistory() }, enabled = !state.busy) {
                Icon(Icons.Outlined.Refresh, "刷新")
            }
        }))
    // Pull-to-refresh and explicit refresh share the same guarded read operation.
    androidx.compose.material3.pulltorefresh.PullToRefreshBox(
        isRefreshing = state.homeLoading != HomeLoading.NONE,
        onRefresh = { when (state.page) { HomePage.COURSES -> model.refreshCourses(); HomePage.HISTORY -> model.refreshHistory(); else -> Unit } },
        indicator = {},
        modifier = Modifier.fillMaxSize()) {
        // Each course has its own scroll position; returning restores the course list position.
        pageStates.SaveableStateProvider(pageKey) {
            LazyColumn(Modifier.fillMaxSize().testTag("home-list-${state.page.name.lowercase()}").padding(horizontal = 24.dp), contentPadding = PaddingValues(bottom = 20.dp)) {
                item {
                    Column(Modifier.padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (state.page == HomePage.HOME) Text("free_rollcall", color = Secondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                        state.selectedCourse?.takeIf { state.page == HomePage.HISTORY }?.let { Text(it.name, fontWeight = FontWeight.SemiBold, fontSize = 17.sp) }
                        Text(state.accountText, color = Secondary, fontSize = 13.sp)
                    }
                }
                state.error?.let { item { Message(it) } }
                state.message?.let { item { Message(it) } }
                if (state.homeLoading != HomeLoading.NONE && state.loginPrompt == null && state.page != HomePage.HOME)
                    item { Loading(if (state.homeLoading == HomeLoading.COURSES) "正在加载课程" else "正在加载签到记录") }
                when (state.page) {
                    HomePage.HOME -> item {
                        HorizontalDivider(color = Line)
                        Row(Modifier.fillMaxWidth().clickable(enabled = !state.busy, onClick = model::enterCourses)
                            .testTag("enter-courses").padding(vertical = 26.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.AutoMirrored.Outlined.MenuBook, null, Modifier.width(40.dp))
                            Spacer(Modifier.width(16.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                                Text("进入课程", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                                Text("查看本学期课程与签到记录", color = Secondary, fontSize = 13.sp)
                            }
                            if (state.homeLoading == HomeLoading.COURSES) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            else Icon(Icons.Outlined.ChevronRight, null, tint = Secondary)
                        }
                        HorizontalDivider(color = Line)
                    }
                    HomePage.COURSES -> {
                        items(state.courses, key = { it.id }) { course ->
                            Row(Modifier.fillMaxWidth().clickable(enabled = !state.busy) { model.openCourse(course) }
                                .testTag("course-${course.id}").padding(vertical = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Outlined.Book, null, Modifier.width(32.dp), tint = Secondary)
                                Spacer(Modifier.width(14.dp)); Text(course.name, Modifier.weight(1f), fontSize = 16.sp, lineHeight = 24.sp)
                                Spacer(Modifier.width(10.dp)); Icon(Icons.Outlined.ChevronRight, null, tint = Secondary)
                            }
                            HorizontalDivider(color = Line)
                        }
                        if (!state.busy && state.courses.isEmpty() && state.error == null) item { EmptyState("本学期暂无课程") }
                    }
                    HomePage.HISTORY -> {
                        items(state.records, key = { it.id }) { record ->
                            AttendanceRow(record, state.busy, state.homeLoading == HomeLoading.HISTORY, state.submitting == record.id) {
                                if (record.canSubmit) model.submit(record.id) else { detailId = record.id; model.refreshDetail(record.id) }
                            }
                        }
                        if (!state.busy && state.records.isEmpty() && state.error == null) item { EmptyState("暂无签到记录") }
                        if (state.history.hasMore && !state.busy) item {
                            TextButton(onClick = model::moreHistory, modifier = Modifier.fillMaxWidth()) { Text("加载更多记录") }
                        }
                        if (state.history.note.isNotEmpty()) item { Message(state.history.note) }
                    }
                }
            }
        }
    }
    detailId?.let { id ->
        val record = state.records.firstOrNull { it.id == id }
        if (record == null) detailId = null
        else ModalBottomSheet(onDismissRequest = { detailId = null }, containerColor = androidx.compose.ui.graphics.Color.White) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp).navigationBarsPadding()) {
                Text("签到详情", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(16.dp))
                FieldLine("课程", state.selectedCourse?.name.orEmpty())
                FieldLine("时间", record.date?.let(::displayTime) ?: record.rawDate ?: "未提供")
                FieldLine("形式", record.kind.title); FieldLine("状态", record.stateText)
                FieldLine("签到码", if (record.kind == AttendanceKind.RADAR) "雷达签到" else record.numberCode ?: "未获取")
                FieldLine("签到人数", record.attendanceCounts?.let { "${it.signedIn}/${it.total}" } ?: "—/—")
                if (record.canSubmit) Button(onClick = { model.submit(id) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth().padding(top = 20.dp)) { Text("立即签到") }
                state.message?.let { Message(it) }
                TextButton(onClick = { detailId = null }, modifier = Modifier.align(Alignment.End)) { Text("完成") }
            }
        }
    }
}
@Composable private fun AttendanceRow(record: Attendance, busy: Boolean, loadingCodes: Boolean, submitting: Boolean, click: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = !busy, onClick = click).testTag("attendance-${record.id}")
        .padding(vertical = 22.dp), verticalAlignment = Alignment.Top) {
        Icon(if (record.kind == AttendanceKind.RADAR) Icons.Outlined.Radar else Icons.Outlined.Tag, null, Modifier.width(32.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(record.kind.title, Modifier.weight(1f), fontWeight = FontWeight.Medium, fontSize = 16.sp)
                Spacer(Modifier.width(8.dp)); Text(record.stateText, color = if (record.isAbsent) Danger else Secondary, fontSize = 12.sp)
            }
            Text(record.date?.let(::displayTime) ?: record.rawDate ?: "时间未提供", color = Secondary, fontSize = 12.sp)
            if (record.kind == AttendanceKind.NUMBER) CodeText("签到码  ${record.numberCode?.takeIf { it.isNotEmpty() } ?: if (loadingCodes) "正在获取…" else "未获取"}")
            if (record.canSubmit) Text(if (submitting) "正在签到…" else "点击此条目签到", fontSize = 12.sp, fontWeight = FontWeight.Medium)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.widthIn(min = 72.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(record.attendanceCounts?.let { "${it.signedIn}/${it.total}" } ?: "—/—",
                fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            Text("已签到/总人数", color = Secondary, fontSize = 10.sp)
            if (submitting) CircularProgressIndicator(Modifier.padding(top = 3.dp).size(16.dp), strokeWidth = 2.dp)
        }
    }
    HorizontalDivider(color = Line)
}

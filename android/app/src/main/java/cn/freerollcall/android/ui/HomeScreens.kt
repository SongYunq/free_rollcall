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
    // Keep unrelated state changes out of the lazy-list content lambda.
    val page = state.page
    val courseName = state.selectedCourse?.name
    val accountText = state.accountText
    val courses = state.courses
    val records = state.records
    val history = state.history
    val busy = state.busy
    val homeLoading = state.homeLoading
    val loadingDetails = state.historyEnriching
    val submitting = state.submitting
    val error = state.error
    val message = state.message
    val hasContent = when (page) { HomePage.COURSES -> courses.isNotEmpty(); HomePage.HISTORY -> records.isNotEmpty(); else -> false }
    val showLoading = state.loginPrompt == null && page != HomePage.HOME && !hasContent &&
        (homeLoading != HomeLoading.NONE || page == HomePage.HISTORY && loadingDetails)
    PageHeader(when (state.page) { HomePage.HOME -> "功能"; HomePage.COURSES -> "本学期课程"; HomePage.HISTORY -> "课程签到" },
        back = if (state.page == HomePage.HOME) null else ({ model.back(); Unit }),
        action = if (state.page == HomePage.HOME) null else ({
            IconButton(onClick = { if (state.page == HomePage.COURSES) model.refreshCourses() else model.refreshHistory() }, enabled = !state.busy) {
                if (homeLoading != HomeLoading.NONE && hasContent) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else Icon(Icons.Outlined.Refresh, "刷新")
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
                item(key = "home-summary", contentType = "summary") {
                    HomeListHeader(page, courseName, accountText)
                }
                error?.let { item(key = "home-error", contentType = "message") { Message(it) } }
                message?.let { item(key = "home-message", contentType = "message") { Message(it) } }
                if (showLoading)
                    item(key = "home-loading", contentType = "loading") { Loading(if (homeLoading == HomeLoading.COURSES) "正在加载课程" else "正在加载签到记录") }
                when (page) {
                    HomePage.HOME -> item(key = "home-entry", contentType = "entry") {
                        HorizontalDivider(color = Line)
                        Row(Modifier.fillMaxWidth().clickable(enabled = !busy, onClick = model::enterCourses)
                            .testTag("enter-courses").padding(vertical = 26.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.AutoMirrored.Outlined.MenuBook, null, Modifier.width(40.dp))
                            Spacer(Modifier.width(16.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                                Text("进入课程", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                                Text("查看本学期课程与签到记录", color = Secondary, fontSize = 13.sp)
                            }
                            if (homeLoading == HomeLoading.COURSES) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            else Icon(Icons.Outlined.ChevronRight, null, tint = Secondary)
                        }
                        HorizontalDivider(color = Line)
                    }
                    HomePage.COURSES -> {
                        items(courses, key = { "course-${it.id}" }, contentType = { "course" }) { course ->
                            CourseRow(course, busy) { model.openCourse(course) }
                        }
                        if (!busy && courses.isEmpty() && error == null) item(key = "courses-empty", contentType = "empty") { EmptyState("本学期暂无课程") }
                    }
                    HomePage.HISTORY -> {
                        items(records, key = { "attendance-${it.id}" }, contentType = { "attendance" }) { record ->
                            val loadingCode = loadingDetails && record.kind == AttendanceKind.NUMBER && record.numberCode.isNullOrEmpty()
                            AttendanceRow(record, busy, loadingCode, submitting == record.id) {
                                if (record.canSubmit) model.submit(record.id) else { detailId = record.id; model.refreshDetail(record.id) }
                            }
                        }
                        if (!busy && !loadingDetails && records.isEmpty() && error == null) item(key = "history-empty", contentType = "empty") { EmptyState("暂无签到记录") }
                        if (history.hasMore && records.isNotEmpty()) item(key = "history-more", contentType = "more") {
                            TextButton(onClick = model::moreHistory, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("加载更多记录") }
                        }
                        if (history.note.isNotEmpty()) item(key = "history-note", contentType = "message") { Message(history.note) }
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
@Composable private fun HomeListHeader(page: HomePage, courseName: String?, accountText: String) {
    Column(Modifier.padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (page == HomePage.HOME) Text("free_rollcall", color = Secondary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
        if (page == HomePage.HISTORY && courseName != null) Text(courseName, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
        Text(accountText, color = Secondary, fontSize = 13.sp)
    }
}
@Composable private fun CourseRow(course: Course, busy: Boolean, click: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = !busy, onClick = click)
        .testTag("course-${course.id}").padding(vertical = 24.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.Book, null, Modifier.width(32.dp), tint = Secondary)
        Spacer(Modifier.width(14.dp)); Text(course.name, Modifier.weight(1f), fontSize = 16.sp, lineHeight = 24.sp)
        Spacer(Modifier.width(10.dp)); Icon(Icons.Outlined.ChevronRight, null, tint = Secondary)
    }
    HorizontalDivider(color = Line)
}
@Composable private fun AttendanceRow(record: Attendance, busy: Boolean, loadingCodes: Boolean, submitting: Boolean, click: () -> Unit) {
    val timeText = remember(record.date, record.rawDate) {
        record.date?.let(::displayTime) ?: record.rawDate ?: "时间未提供"
    }
    Row(Modifier.fillMaxWidth().clickable(enabled = !busy, onClick = click).testTag("attendance-${record.id}")
        .padding(vertical = 22.dp), verticalAlignment = Alignment.Top) {
        Icon(if (record.kind == AttendanceKind.RADAR) Icons.Outlined.Radar else Icons.Outlined.Tag, null, Modifier.width(32.dp))
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(record.kind.title, Modifier.weight(1f), fontWeight = FontWeight.Medium, fontSize = 16.sp)
                Spacer(Modifier.width(8.dp)); Text(record.stateText, color = if (record.isAbsent) Danger else Secondary, fontSize = 12.sp)
            }
            Text(timeText, color = Secondary, fontSize = 12.sp)
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

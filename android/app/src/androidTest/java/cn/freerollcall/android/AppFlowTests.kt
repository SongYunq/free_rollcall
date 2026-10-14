package cn.freerollcall.android

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import cn.freerollcall.android.app.*
import cn.freerollcall.android.auth.*
import cn.freerollcall.android.core.*
import cn.freerollcall.android.storage.*
import cn.freerollcall.android.ui.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.security.KeyStore
import android.os.Looper
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.CopyOnWriteArrayList
import androidx.compose.ui.semantics.SemanticsProperties

// Fixtures are only compiled into the test APK; the installed app always uses real services.
private class FixtureTransport : Transport {
    val requests = CopyOnWriteArrayList<ApiRequest>()
    var courseCount = 1
    @Volatile private var answered = false
    @Volatile private var pausedPath: String? = null
    @Volatile private var gate = CompletableDeferred<Unit>()
    fun pause(path: String) { gate = CompletableDeferred(); pausedPath = path }
    fun resume() { pausedPath = null; gate.complete(Unit) }
    override suspend fun send(request: ApiRequest): ApiResponse {
        requests += request
        if (request.path == pausedPath) gate.await()
        return ApiResponse(200, when {
            request.path == "/api/current-semester-info" -> """{"semester":{"id":1},"academic_year":{"id":1}}"""
            request.path == "/api/my-courses" -> (0 until courseCount).joinToString(
                prefix = """{"courses":[""", postfix = """],"pages":1}""") { index ->
                """{"id":${9 + index},"name":"本学期示例课程${if (index == 0) "" else index}"}"""
            }
            request.path.contains("/student/1/rollcalls") -> """{"rollcalls":[{"id":701,"is_number":true,"rollcall_status":"active","status":"absent","rollcall_time":"2026-10-05 08:00:00"},{"id":703,"is_number":true,"rollcall_status":"finished","status":"on_call_fine","rollcall_time":"2026-10-04 08:00:00"},{"id":704,"is_number":true,"rollcall_status":"finished","status":"absent","rollcall_time":"2026-10-03 08:00:00"}],"pages":1}"""
            request.path == "/api/radar/rollcalls" -> """{"rollcalls":[]}"""
            request.path.endsWith("/answer_number_rollcall") -> { answered = true; "{}" }
            request.path.startsWith("/api/timetable_rollcalls") -> {
                val date = request.path.substringAfter("rollcall_date=").substringBefore("&")
                val status = if (date == "2026-10-04" || answered) "on_call_fine" else "absent"
                val active = if (date == "2026-10-05") "active" else "finished"
                val id = if (date == "2026-10-05") 701 else 703
                """{"rollcalls":[{"id":$id,"is_number":true,"number_code":"0123","status":"$active","student_rollcalls":[{"student_id":1,"status":"$status"}]}]}"""
            }
            else -> error("Unexpected request ${request.path}")
        })
    }
}
private class BackgroundCheckedStore(private val delegate: Store) : Store by delegate {
    private fun checkThread() { check(Looper.myLooper() != Looper.getMainLooper()) { "本地存储不得在界面线程调用" } }
    override fun accounts(): List<SavedAccount> { checkThread(); return delegate.accounts() }
    override fun logs(): List<AttendanceLog> { checkThread(); return delegate.logs() }
    override fun password(id: String): String { checkThread(); return delegate.password(id) }
    override fun saveAccount(id: String?, username: String, password: String, note: String): SavedAccount {
        checkThread(); return delegate.saveAccount(id, username, password, note)
    }
    override fun makeDefault(id: String) { checkThread(); delegate.makeDefault(id) }
    override fun deleteAccount(id: String) { checkThread(); delegate.deleteAccount(id) }
    override fun verified(id: String, studentId: String) { checkThread(); delegate.verified(id, studentId) }
    override fun begin(account: SavedAccount, studentId: String, course: Course, record: Attendance): AttendanceLog {
        checkThread(); return delegate.begin(account, studentId, course, record)
    }
    override fun update(id: String, result: LogResult, message: String, code: String?, kind: AttendanceKind?, studentId: String?) {
        checkThread(); delegate.update(id, result, message, code, kind, studentId)
    }
}
@RunWith(AndroidJUnit4::class)
class AppFlowTests {
    @get:Rule val compose = createComposeRule()
    private lateinit var context: Context
    private lateinit var store: LocalStore
    private lateinit var model: AppModel
    private lateinit var transport: FixtureTransport
    private val name = "rollcall-ui-test.db"
    private val alias = "free_rollcall.ui-test"
    @Before fun before() {
        context = ApplicationProvider.getApplicationContext()
        context.deleteDatabase(name)
        store = LocalStore(context, name, CredentialVault(alias))
        store.saveAccount(null, "demo001", "test-password", "个人")
        store.saveAccount(null, "demo002", "test-password", "备用")
        transport = FixtureTransport()
        model = AppModel(BackgroundCheckedStore(store)) { c, _ -> AuthResult(Profile(if (c.username == "demo001") "1" else "2", c.username, "示例用户", null), TronclassClient(transport) {}) }
        compose.setContent { RollcallTheme { RollcallApp(model) } }
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.initializing }
    }
    @After fun after() {
        transport.resume()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy }
        store.close(); context.deleteDatabase(name)
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
    }
    @Test fun dockAndThreeDotMenuExposeFourActionsWithoutSwipe() {
        compose.onNodeWithContentDescription("账号管理").performClick()
        val account = store.accounts().first()
        compose.onNodeWithTag("account-${account.id}").performTouchInput { swipeLeft() }
        compose.onNodeWithText("登录", useUnmergedTree = true).assertDoesNotExist()
        compose.onNodeWithContentDescription("账号操作 ${account.username}").performClick()
        for (title in listOf("登录", "修改", "设为默认", "删除")) compose.onNodeWithText(title, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("登录", useUnmergedTree = true).performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.authenticated }
        compose.onNodeWithText("已登录", substring = true).assertIsDisplayed()
        compose.onNodeWithContentDescription("本地日志").performClick()
        compose.onNodeWithText("还没有签到记录").assertIsDisplayed()
    }
    private fun enterHistory() {
        compose.onNodeWithTag("enter-courses").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.courses.isNotEmpty() && !model.state.value.busy }
        compose.onNodeWithText("加载更多课程").assertDoesNotExist()
        compose.onNodeWithTag("course-9").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.records.size == 3 && !model.state.value.busy }
    }
    @Test fun historyCodesAreVisibleAndAnsweredRowsStayDistinct() {
        enterHistory()
        for (id in listOf("701", "703", "704")) compose.onNodeWithTag("attendance-$id", useUnmergedTree = true)
            .assert(hasAnyDescendant(hasText("签到码  0123")))
        compose.onNodeWithTag("attendance-701", useUnmergedTree = true).assert(hasAnyDescendant(hasText("正在签到")))
        compose.onNodeWithTag("attendance-703", useUnmergedTree = true).assert(hasAnyDescendant(hasText("已签到")))
        compose.onNodeWithTag("attendance-704", useUnmergedTree = true).assert(hasAnyDescendant(hasText("缺勤")))
        assertTrue(transport.requests.none { it.method == "PUT" })
    }
    @Test fun returningFromHistoryRestoresCourseListPosition() {
        transport.courseCount = 35
        compose.onNodeWithTag("enter-courses").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.courses.size == 35 }
        compose.onNodeWithTag("home-list-courses").performScrollToNode(hasTestTag("course-33"))
        compose.onNodeWithTag("course-33").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.records.size == 3 }
        compose.onNodeWithTag("attendance-701").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("course-33").assertIsDisplayed()
        compose.onNodeWithTag("course-9").assertIsNotDisplayed()
    }
    @Test fun directSubmissionCreatesSuccessfulLogAndDoesNotResubmit() {
        enterHistory()
        compose.onNodeWithTag("attendance-701").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.logs.isNotEmpty() }
        assertEquals(LogResult.SUCCESS, store.logs().single().result)
        assertEquals(1, transport.requests.count { it.method == "PUT" })
        compose.onNodeWithTag("attendance-701", useUnmergedTree = true).assert(hasAnyDescendant(hasText("已签到")))
        compose.onNodeWithContentDescription("本地日志").performClick()
        compose.onNodeWithText("成功").assertIsDisplayed()
        compose.onNodeWithText("0123").assertIsDisplayed()
        compose.onNodeWithText("个人 · demo001").assertIsDisplayed()
    }
    @Test fun addAccountEditorPersistsAndDefaultActionKeepsCurrentLogin() {
        compose.onNodeWithContentDescription("账号管理").performClick()
        compose.onNodeWithContentDescription("添加账号").performClick()
        compose.onNodeWithTag("username").performTextInput("demo003")
        compose.onNodeWithTag("password").performTextInput("visible-test")
        compose.onNodeWithTag("account-note").performTextInput("新账号")
        compose.onNodeWithText("保存").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.accounts.size == 3 && !model.state.value.busy }
        compose.onNodeWithText("新账号").assertIsDisplayed()
        assertEquals(3, store.accounts().size)
        val first = store.accounts().first()
        compose.onNodeWithContentDescription("账号操作 ${first.username}").performClick()
        compose.onNodeWithText("登录", useUnmergedTree = true).performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.authenticated }
        val third = store.accounts().first { it.username == "demo003" }
        compose.onNodeWithContentDescription("账号操作 ${third.username}").performClick()
        compose.onNodeWithText("设为默认", useUnmergedTree = true).performClick()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.accounts.first { it.id == third.id }.isDefault }
        assertEquals(first.id, model.state.value.currentAccountId)
        assertEquals(third.id, store.accounts().first { it.isDefault }.id)
    }
    private val progress = SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)
    @Test fun courseLoadingHasOneIndicatorAndDetailRefreshDoesNotShowPageLoading() {
        transport.pause("/api/current-semester-info")
        compose.onNodeWithTag("enter-courses").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.page == HomePage.COURSES && transport.requests.any { it.path == "/api/current-semester-info" } }
        compose.onAllNodes(progress).assertCountEquals(1)
        compose.onNodeWithTag("page-loading").assertIsDisplayed()
        transport.resume()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.courses.isNotEmpty() }
        compose.onNodeWithTag("course-9").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.records.size == 3 }
        transport.pause("/api/timetable_rollcalls?course_ids=9&rollcall_date=2026-10-04")
        compose.onNodeWithTag("attendance-703").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { model.state.value.busy }
        compose.onNodeWithTag("page-loading").assertDoesNotExist()
        compose.onAllNodes(progress).assertCountEquals(0)
        transport.resume()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy }
    }
    @Test fun submissionHasOnlyItsRowIndicator() {
        enterHistory()
        transport.pause("/api/rollcall/701/answer_number_rollcall")
        compose.onNodeWithTag("attendance-701").performClick()
        compose.waitUntil(timeoutMillis = 5_000) { transport.requests.any { it.path.endsWith("answer_number_rollcall") } }
        compose.onNodeWithTag("page-loading").assertDoesNotExist()
        compose.onAllNodes(progress).assertCountEquals(1)
        transport.resume()
        compose.waitUntil(timeoutMillis = 5_000) { !model.state.value.busy && model.state.value.logs.isNotEmpty() }
        assertEquals(LogResult.SUCCESS, model.state.value.logs.single().result)
    }
}

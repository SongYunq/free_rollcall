package cn.freerollcall.android

import cn.freerollcall.android.app.*
import cn.freerollcall.android.auth.*
import cn.freerollcall.android.core.*
import cn.freerollcall.android.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.*
import org.junit.Assert.*
import java.time.Instant

class MemoryStore : Store {
    val saved = mutableListOf(SavedAccount("a", "demo1", "", true, "1", 1), SavedAccount("b", "demo2", "", false, "2", 2))
    val entries = mutableListOf<AttendanceLog>()
    override fun accounts() = saved.toList()
    override fun logs() = entries.toList()
    override fun password(id: String) = "password"
    override fun saveAccount(id: String?, username: String, password: String, note: String): SavedAccount = error("Not used")
    override fun makeDefault(id: String) { saved.replaceAll { it.copy(isDefault = it.id == id) } }
    override fun deleteAccount(id: String) { saved.removeAll { it.id == id } }
    override fun verified(id: String, studentId: String) { saved.replaceAll { if (it.id == id) it.copy(verifiedStudentId = studentId) else it } }
    override fun begin(account: SavedAccount, studentId: String, course: Course, record: Attendance): AttendanceLog {
        return AttendanceLog("log${entries.size}", Instant.now(), account.id, account.username, account.note, studentId,
            course.id, course.name, record.id, record.kind, record.numberCode, LogResult.PROCESSING, "").also { entries += it }
    }
    override fun update(id: String, result: LogResult, message: String, code: String?, kind: AttendanceKind?, studentId: String?) {
        entries.replaceAll { if (it.id == id) it.copy(result = result, message = message, code = code ?: it.code,
            kind = kind ?: it.kind, studentId = studentId ?: it.studentId) else it }
    }
}
@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTests {
    private val dispatcher = StandardTestDispatcher()
    @Before fun before() { Dispatchers.setMain(dispatcher) }
    @After fun after() { Dispatchers.resetMain() }
    private fun auth(store: MemoryStore, client: TronclassClient, selected: MutableList<String>): suspend (AuthCredentials, Boolean) -> AuthResult = { c, _ ->
        selected += c.accountId
        val account = store.accounts().first { it.id == c.accountId }
        AuthResult(Profile(account.verifiedStudentId!!, account.username, account.username, null), client)
    }
    private fun transportForHistory(detailResponses: List<ApiResponse>): QueueTransport = QueueTransport(
        jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""),
        jsonResponse("""{"courses":[{"id":9,"name":"课程"}],"pages":1}"""),
        jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"status":"on_call_fine","rollcall_status":"finished","rollcall_time":"2026-10-08 08:00:00"},{"id":12,"is_number":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08 08:00:00"}],"pages":1}"""),
        jsonResponse("""{"rollcalls":[]}"""), *detailResponses.toTypedArray())
    @Test fun automaticallyUsesDefaultAndDefaultChangeDoesNotSwitchSession() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val client = TronclassClient(QueueTransport(jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""), jsonResponse("""{"courses":[],"pages":1}""")))
        val model = AppModel(store, dispatcher, auth(store, client, logins))
        model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("a"), logins); assertEquals("a", model.state.value.currentAccountId)
        model.makeDefault("b")
        assertEquals("a", model.state.value.currentAccountId); assertTrue(model.state.value.authenticated)
    }
    @Test fun manualAccountLoginIsUsedByFeatureInsteadOfDefault() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val transport = QueueTransport(jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""), jsonResponse("""{"courses":[],"pages":1}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(transport), logins))
        model.loginAccount("b"); advanceUntilIdle(); model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("b"), logins); assertEquals("b", model.state.value.currentAccountId)
    }
    @Test fun threeCredentialErrorsSwitchToManualButNetworkErrorsDoNotCount() = runTest(dispatcher) {
        val modes = mutableListOf<Boolean>(); var network = true
        val model = AppModel(MemoryStore(), dispatcher) { _, manual ->
            modes += manual
            if (network) throw RollcallException(RollcallException.Reason.NETWORK, "网络失败")
            throw RollcallException(RollcallException.Reason.INVALID_CREDENTIALS, "凭证错误")
        }
        repeat(3) { model.loginAccount("a"); advanceUntilIdle() }
        network = false
        repeat(3) { model.loginAccount("a"); advanceUntilIdle() }
        assertEquals(listOf(false, false, false, false, false, false, true), modes)
    }
    @Test fun autoCodesPreserveAnsweredAndOnlyExplicitAbsence() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = transportForHistory(listOf(
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"absent"}]}]}"""),
            jsonResponse("""{"rollcalls":[{"id":12,"is_number":true,"number_code":"0013","status":"active","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}""")))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), logins))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertEquals(listOf("已签到", "缺勤"), model.state.value.records.map { it.stateText })
        assertEquals(listOf("0012", "0013"), model.state.value.records.map { it.numberCode })
        assertTrue(store.logs().isEmpty()); assertTrue(t.requests.none { it.method == "PUT" })
    }
    @Test fun partialCodeFailureKeepsRowsAndAllowsRefresh() = runTest(dispatcher) {
        val store = MemoryStore(); val t = transportForHistory(listOf(jsonResponse("{}", 500), jsonResponse("""{"rollcalls":[{"id":12,"is_number":true,"number_code":"0007"}]}""")))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertEquals("已签到", model.state.value.records[0].stateText)
        assertEquals("0007", model.state.value.records[1].numberCode)
        assertTrue(model.state.value.error!!.contains("下拉刷新")); assertFalse(model.state.value.busy)
    }
    @Test fun accountChangeIsBlockedWhileLoading() = runTest(dispatcher) {
        val waiting = CompletableDeferred<AuthResult>()
        val model = AppModel(MemoryStore(), dispatcher) { _, _ -> waiting.await() }
        model.loginAccount("a"); runCurrent()
        try { model.makeDefault("b"); fail() } catch (error: RollcallException) { assertTrue(error.message!!.contains("等待")) }
        waiting.cancel(); advanceUntilIdle()
        assertFalse(model.state.value.busy)
    }
    @Test fun reconcileUnknownEndedStateStaysUncertainAndNeverWritesRemote() = runTest(dispatcher) {
        val store = MemoryStore()
        val log = store.begin(store.saved[0], "1", Course("9", "课程"), Attendance("11"))
        store.update(log.id, LogResult.UNCERTAIN, "待确认")
        val t = QueueTransport(jsonResponse("""{"rollcalls":[{"id":11,"status":"finished","student_rollcalls":[]}]}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle(); model.reconcile(log.id); advanceUntilIdle()
        assertEquals(LogResult.UNCERTAIN, store.logs().single().result)
        assertEquals(listOf("GET"), t.requests.map { it.method })
    }
    @Test fun logAccountMustMatchCurrentSession() = runTest(dispatcher) {
        val store = MemoryStore()
        val log = store.begin(store.saved[1], "2", Course("9", "课程"), Attendance("11"))
        store.update(log.id, LogResult.UNCERTAIN, "待确认")
        val t = QueueTransport()
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle(); model.reconcile(log.id); advanceUntilIdle()
        assertTrue(t.requests.isEmpty()); assertTrue(model.state.value.notice!!.contains("对应的账号"))
    }
    @Test fun reconciliationPreservesKnownKindWhenDetailOmitsIt() = runTest(dispatcher) {
        val store = MemoryStore()
        val log = store.begin(store.saved[0], "1", Course("9", "课程"), Attendance("11", kind = AttendanceKind.RADAR))
        store.update(log.id, LogResult.UNCERTAIN, "待确认")
        val t = QueueTransport(jsonResponse("""{"rollcalls":[{"id":11,"status":"finished","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle(); model.reconcile(log.id); advanceUntilIdle()
        assertEquals(LogResult.SUCCESS, store.logs().single().result)
        assertEquals(AttendanceKind.RADAR, store.logs().single().kind)
        assertEquals("雷达签到", store.logs().single().codeText)
        assertEquals(listOf("GET"), t.requests.map { it.method })
    }
    @Test fun readExpiryRenewsSameManualAccountRatherThanDefault() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = QueueTransport(jsonResponse("", 401),
            jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""),
            jsonResponse("""{"courses":[],"pages":1}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), logins))
        model.loginAccount("b"); advanceUntilIdle(); model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("b", "b"), logins)
        assertEquals("b", model.state.value.currentAccountId); assertTrue(model.state.value.authenticated)
    }
    @Test fun simultaneousSubmissionClicksCreateOneLogAndOnePut() = runTest(dispatcher) {
        val store = MemoryStore()
        val t = QueueTransport(
            jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""),
            jsonResponse("""{"courses":[{"id":9,"name":"课程"}],"pages":1}"""),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"absent","rollcall_status":"active","rollcall_time":"2026-10-08 08:00:00"}],"pages":1}"""),
            jsonResponse("""{"rollcalls":[]}"""),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"absent"}]}]}"""),
            jsonResponse("{}"),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t) {}, mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        model.submit("11"); model.submit("11"); advanceUntilIdle()
        assertEquals(1, store.logs().size); assertEquals(LogResult.SUCCESS, store.logs().single().result)
        assertEquals(1, t.requests.count { it.method == "PUT" })
        assertEquals("0012", store.logs().single().code); assertEquals("已签到", model.state.value.records.single().stateText)
    }
    @Test fun renewalThatAlsoExpiresClearsAuthenticatedState() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = QueueTransport(jsonResponse("", 401), jsonResponse("", 401))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t), logins))
        model.loginAccount("b"); advanceUntilIdle()
        model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("b", "b"), logins)
        assertEquals("b", model.state.value.currentAccountId)
        assertFalse(model.state.value.authenticated)
        assertFalse(model.state.value.busy)
        assertTrue(model.state.value.error!!.contains("过期"))
    }
    private fun submissionTransport(vararg tail: ApiResponse) = QueueTransport(
        jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""),
        jsonResponse("""{"courses":[{"id":9,"name":"课程"}],"pages":1}"""),
        jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"absent","rollcall_status":"active","rollcall_time":"2026-10-08 08:00:00"}],"pages":1}"""),
        jsonResponse("""{"rollcalls":[]}"""), *tail)
    @Test fun expiredSubmissionPreflightRenewsSelectedAccountAndWritesOnlyOnce() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = submissionTransport(
            jsonResponse("", 401),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":2,"status":"absent"}]}]}"""),
            jsonResponse("{}"),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":2,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(t) {}, logins))
        model.loginAccount("b"); advanceUntilIdle()
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        model.submit("11"); advanceUntilIdle()
        assertEquals(listOf("b", "b"), logins)
        assertEquals(1, t.requests.count { it.method == "PUT" })
        assertEquals(LogResult.SUCCESS, store.logs().single().result)
        assertEquals("b", store.logs().single().accountId)
        assertEquals("2", store.logs().single().studentId)
    }
    @Test fun localReadFailureAfterLogCreationFinalizesLogWithoutSubmitting() = runTest(dispatcher) {
        val store = MemoryStore(); var failRead = false
        val flakyStore = object : Store by store {
            override fun begin(account: SavedAccount, studentId: String, course: Course, record: Attendance): AttendanceLog =
                store.begin(account, studentId, course, record).also { failRead = true }
            override fun logs(): List<AttendanceLog> {
                if (failRead) { failRead = false; throw RollcallException.message("本地读取失败") }
                return store.logs()
            }
        }
        val t = submissionTransport()
        val model = AppModel(flakyStore, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        model.submit("11"); advanceUntilIdle()
        assertTrue(t.requests.none { it.method == "PUT" })
        assertEquals(LogResult.FAILURE, store.logs().single().result)
        assertEquals("本地读取失败", store.logs().single().message)
        assertEquals(LogResult.FAILURE, model.state.value.logs.single().result)
        assertFalse(model.state.value.busy)
    }
    @Test fun backCancelsHistoryAndIgnoresLateResults() = runTest(dispatcher) {
        val store = MemoryStore(); val gate = CompletableDeferred<Unit>()
        val base = submissionTransport()
        val transport = object : Transport {
            override suspend fun send(request: ApiRequest): ApiResponse {
                if (request.path.contains("/rollcalls?")) gate.await()
                return base.send(request)
            }
        }
        val model = AppModel(store, dispatcher, auth(store, TronclassClient(transport), mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); runCurrent()
        assertTrue(model.state.value.busy)
        assertTrue(model.back()); gate.complete(Unit); advanceUntilIdle()
        assertEquals(HomePage.COURSES, model.state.value.page)
        assertTrue(model.state.value.records.isEmpty())
        assertNull(model.state.value.selectedCourse)
        assertFalse(model.state.value.busy)
        assertNull(model.state.value.notice)
    }
}

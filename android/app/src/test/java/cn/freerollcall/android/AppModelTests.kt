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
        val model = AppModel(store, dispatcher, dispatcher, auth(store, client, logins))
        model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("a"), logins); assertEquals("a", model.state.value.currentAccountId)
        model.makeDefault("b")
        assertEquals("a", model.state.value.currentAccountId); assertTrue(model.state.value.authenticated)
    }
    @Test fun manualAccountLoginIsUsedByFeatureInsteadOfDefault() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val transport = QueueTransport(jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""), jsonResponse("""{"courses":[],"pages":1}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(transport), logins))
        model.loginAccount("b"); advanceUntilIdle(); model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("b"), logins); assertEquals("b", model.state.value.currentAccountId)
    }
    @Test fun threeCredentialErrorsSwitchToManualButNetworkErrorsDoNotCount() = runTest(dispatcher) {
        val modes = mutableListOf<Boolean>(); var network = true
        val model = AppModel(MemoryStore(), dispatcher, dispatcher) { _, manual ->
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
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"absent"}]},{"id":12,"is_number":true,"number_code":"0013","status":"active","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}""")))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), logins))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertEquals(listOf("已签到", "缺勤"), model.state.value.records.map { it.stateText })
        assertEquals(listOf("0012", "0013"), model.state.value.records.map { it.numberCode })
        assertEquals(listOf(AttendanceCounts(0, 1), AttendanceCounts(1, 1)), model.state.value.records.map { it.attendanceCounts })
        assertEquals(1, t.requests.count { it.path.startsWith("/api/timetable_rollcalls") })
        assertTrue(store.logs().isEmpty()); assertTrue(t.requests.none { it.method == "PUT" })
    }
    @Test fun partialCodeFailureKeepsRowsAndAllowsRefresh() = runTest(dispatcher) {
        val store = MemoryStore(); val t = transportForHistory(listOf(jsonResponse("""{"rollcalls":[{"id":12,"is_number":true,"number_code":"0007","student_rollcalls":[]}]}""")))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertEquals("已签到", model.state.value.records[0].stateText)
        assertEquals("0007", model.state.value.records[1].numberCode)
        assertNull(model.state.value.records[0].attendanceCounts)
        assertEquals(AttendanceCounts(0, 0), model.state.value.records[1].attendanceCounts)
        assertTrue(model.state.value.error!!.contains("下拉刷新")); assertFalse(model.state.value.busy)
    }
    @Test fun countsLoadForKnownCodesRadarAndOtherKindsInOneDailyRead() = runTest(dispatcher) {
        val store = MemoryStore()
        val t = QueueTransport(
            jsonResponse("""{"rollcalls":[
                {"id":11,"is_number":true,"number_code":"0012","status":"on_call_fine","rollcall_status":"finished","rollcall_time":"2026-10-08 08:00:00"},
                {"id":12,"is_radar":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08 09:00:00"},
                {"id":13,"is_radar":false,"is_number":false,"rollcall_status":"finished","rollcall_time":"2026-10-08 10:00:00"},
                {"id":14,"rollcall_status":"finished","rollcall_time":"2026-10-08 11:00:00"}
            ],"pages":1}"""),
            jsonResponse("""{"rollcalls":[]}"""),
            jsonResponse("""{"rollcalls":[
                {"id":11,"status":"active","student_rollcalls":[{"student_id":1,"status":"absent"},{"student_id":2,"status":"on_call_late"}]},
                {"id":12,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]},
                {"id":13,"student_rollcalls":[]},
                {"id":14,"is_radar":true,"student_rollcalls":[{"student_id":1,"status":"absent"}]}
            ]}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle()
        model.openCourse(Course("9", "课程")); advanceUntilIdle()
        val rows = model.state.value.records.associateBy { it.id }
        assertEquals(AttendanceCounts(1, 2), rows["11"]!!.attendanceCounts)
        assertEquals(AttendanceCounts(1, 1), rows["12"]!!.attendanceCounts)
        assertEquals(AttendanceCounts(0, 0), rows["13"]!!.attendanceCounts)
        assertEquals(AttendanceCounts(0, 1), rows["14"]!!.attendanceCounts)
        assertEquals("0012", rows["11"]!!.numberCode)
        assertEquals("已签到", rows["11"]!!.stateText)
        assertEquals("缺勤", rows["12"]!!.stateText)
        assertEquals(AttendanceKind.RADAR, rows["14"]!!.kind)
        assertEquals(1, t.requests.count { it.path.startsWith("/api/timetable_rollcalls") })
        assertNull(model.state.value.error)
        assertTrue(t.requests.all { it.method == "GET" })
    }
    @Test fun countFailureKeepsHistoryAndRefreshRetriesWithCurrentCounts() = runTest(dispatcher) {
        val store = MemoryStore()
        val history = jsonResponse("""{"rollcalls":[{"id":11,"is_radar":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08 07:00:00"}],"pages":1}""")
        val active = jsonResponse("""{"rollcalls":[]}""")
        val t = QueueTransport(history, active, jsonResponse("{}", 503), history, active,
            jsonResponse("""{"rollcalls":[{"id":11,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"},{"student_id":2,"status":"absent"}]}]}"""),
            history, active, jsonResponse("""{"rollcalls":[{"id":11,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"},{"student_id":2,"status":"on_call_late"}]}]}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle()
        model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertNull(model.state.value.records.single().attendanceCounts)
        assertEquals("缺勤", model.state.value.records.single().stateText)
        assertTrue(model.state.value.error!!.contains("人数未获取"))
        model.refreshHistory(); advanceUntilIdle()
        assertEquals(AttendanceCounts(1, 2), model.state.value.records.single().attendanceCounts)
        assertNull(model.state.value.error)
        model.refreshHistory(); advanceUntilIdle()
        assertEquals(AttendanceCounts(2, 2), model.state.value.records.single().attendanceCounts)
        assertNull(model.state.value.error)
        assertTrue(t.requests.filter { it.path.startsWith("/api/timetable_rollcalls") }
            .all { it.path == "/api/timetable_rollcalls?course_ids=9&rollcall_date=2026-10-07" })
        assertTrue(t.requests.all { it.method == "GET" })
    }
    @Test fun slowCountReadsDoNotLockVisibleHistoryAndBackCancelsThem() = runTest(dispatcher) {
        val store = MemoryStore(); val gate = CompletableDeferred<Unit>()
        val base = transportForHistory(listOf(jsonResponse("""{"rollcalls":[]}""")))
        val transport = Transport { request ->
            if (request.path.startsWith("/api/timetable_rollcalls")) gate.await()
            base.send(request)
        }
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(transport), mutableListOf()))
        model.enterCourses(); advanceUntilIdle()
        model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertEquals(2, model.state.value.records.size)
        assertFalse(model.state.value.busy)
        assertEquals(HomeLoading.NONE, model.state.value.homeLoading)
        assertTrue(model.state.value.historyEnriching)
        assertTrue(model.back())
        gate.complete(Unit); advanceUntilIdle()
        assertEquals(HomePage.COURSES, model.state.value.page)
        assertTrue(model.state.value.records.isEmpty())
        assertFalse(model.state.value.historyEnriching)
        assertFalse(model.state.value.busy)
    }
    @Test fun oneSlowDayDoesNotBlockCountsForLaterDays() = runTest(dispatcher) {
        val store = MemoryStore(); val gate = CompletableDeferred<Unit>()
        val transport = Transport { request ->
            when {
                request.path.contains("/student/1/rollcalls") -> jsonResponse((4..8).joinToString(
                    prefix = """{"rollcalls":[""", postfix = """],"pages":1}""") { day ->
                    """{"id":$day,"is_radar":true,"rollcall_status":"finished","rollcall_time":"2026-10-0$day 08:00:00"}"""
                })
                request.path == "/api/radar/rollcalls" -> jsonResponse("""{"rollcalls":[]}""")
                request.path.startsWith("/api/timetable_rollcalls") -> {
                    val day = request.path.substringAfter("rollcall_date=2026-10-0").toInt()
                    if (day == 8) gate.await()
                    jsonResponse("""{"rollcalls":[{"id":$day,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}""")
                }
                else -> error("Unexpected request ${request.path}")
            }
        }
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(transport), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle()
        model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertFalse(model.state.value.busy)
        assertTrue(model.state.value.historyEnriching)
        assertNull(model.state.value.records.first { it.id == "8" }.attendanceCounts)
        assertEquals(AttendanceCounts(1, 1), model.state.value.records.first { it.id == "4" }.attendanceCounts)
        gate.complete(Unit); advanceUntilIdle()
        assertFalse(model.state.value.historyEnriching)
        assertTrue(model.state.value.records.all { it.attendanceCounts == AttendanceCounts(1, 1) })
    }
    @Test fun openingDetailResumesUnfinishedClassCountsWithoutReplacingPersonalStatus() = runTest(dispatcher) {
        val store = MemoryStore(); val gate = CompletableDeferred<Unit>()
        var detailReads = 0
        val transport = Transport { request ->
            when {
                request.path.contains("/student/1/rollcalls") -> jsonResponse("""{"rollcalls":[
                    {"id":11,"is_radar":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08 08:00:00"},
                    {"id":12,"is_radar":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08 08:00:00"}
                ],"pages":1}""")
                request.path == "/api/radar/rollcalls" -> jsonResponse("""{"rollcalls":[]}""")
                request.path.startsWith("/api/timetable_rollcalls") -> {
                    detailReads++
                    if (detailReads == 1) gate.await()
                    val ownStatus = if (detailReads == 2) "on_call_fine" else "absent"
                    jsonResponse("""{"rollcalls":[
                        {"id":11,"student_rollcalls":[{"student_id":1,"status":"$ownStatus"}]},
                        {"id":12,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}
                    ]}""")
                }
                else -> error("Unexpected request ${request.path}")
            }
        }
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(transport), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle()
        model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertTrue(model.state.value.historyEnriching)
        model.refreshDetail("11"); advanceUntilIdle()
        assertEquals(3, detailReads)
        assertFalse(model.state.value.historyEnriching)
        assertFalse(model.state.value.busy)
        assertEquals("已签到", model.state.value.records.first { it.id == "11" }.stateText)
        assertEquals(AttendanceCounts(1, 1), model.state.value.records.first { it.id == "12" }.attendanceCounts)
        gate.complete(Unit)
    }
    @Test fun immediateEmptyHistoryDoesNotLeaveBackgroundLoadingSet() = runTest(dispatcher) {
        val immediate = UnconfinedTestDispatcher(testScheduler)
        Dispatchers.setMain(immediate)
        val store = MemoryStore()
        val client = TronclassClient(QueueTransport(jsonResponse("""{"rollcalls":[],"pages":1}"""),
            jsonResponse("""{"rollcalls":[]}""")))
        val model = AppModel(store, immediate, immediate, auth(store, client, mutableListOf()))
        model.loginAccount("a"); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        assertTrue(model.state.value.records.isEmpty())
        assertFalse(model.state.value.historyEnriching)
        assertFalse(model.state.value.busy)
    }
    @Test fun accountChangeIsBlockedWhileLoading() = runTest(dispatcher) {
        val waiting = CompletableDeferred<AuthResult>()
        val model = AppModel(MemoryStore(), dispatcher, dispatcher) { _, _ -> waiting.await() }
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
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle(); model.reconcile(log.id); advanceUntilIdle()
        assertEquals(LogResult.UNCERTAIN, store.logs().single().result)
        assertEquals(listOf("GET"), t.requests.map { it.method })
    }
    @Test fun logAccountMustMatchCurrentSession() = runTest(dispatcher) {
        val store = MemoryStore()
        val log = store.begin(store.saved[1], "2", Course("9", "课程"), Attendance("11"))
        store.update(log.id, LogResult.UNCERTAIN, "待确认")
        val t = QueueTransport()
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
        model.loginAccount("a"); advanceUntilIdle(); model.reconcile(log.id); advanceUntilIdle()
        assertTrue(t.requests.isEmpty()); assertTrue(model.state.value.notice!!.contains("对应的账号"))
    }
    @Test fun reconciliationPreservesKnownKindWhenDetailOmitsIt() = runTest(dispatcher) {
        val store = MemoryStore()
        val log = store.begin(store.saved[0], "1", Course("9", "课程"), Attendance("11", kind = AttendanceKind.RADAR))
        store.update(log.id, LogResult.UNCERTAIN, "待确认")
        val t = QueueTransport(jsonResponse("""{"rollcalls":[{"id":11,"status":"finished","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
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
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), logins))
        model.loginAccount("b"); advanceUntilIdle(); model.enterCourses(); advanceUntilIdle()
        assertEquals(listOf("b", "b"), logins)
        assertEquals("b", model.state.value.currentAccountId); assertTrue(model.state.value.authenticated)
    }
    @Test fun simultaneousSubmissionClicksCreateOneLogAndOnePut() = runTest(dispatcher) {
        val store = MemoryStore()
        val t = QueueTransport(
            jsonResponse("""{"semester":{"id":1},"academic_year":{"id":1}}"""),
            jsonResponse("""{"courses":[{"id":9,"name":"课程"}],"pages":1}"""),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"absent","rollcall_status":"active","rollcall_time":"2026-10-08 08:00:00","student_rollcalls":[]}],"pages":1}"""),
            jsonResponse("""{"rollcalls":[]}"""),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"absent"}]}]}"""),
            jsonResponse("{}"),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t) {}, mutableListOf()))
        model.enterCourses(); advanceUntilIdle(); model.openCourse(Course("9", "课程")); advanceUntilIdle()
        model.submit("11"); model.submit("11"); advanceUntilIdle()
        assertEquals(1, store.logs().size); assertEquals(LogResult.SUCCESS, store.logs().single().result)
        assertEquals(1, t.requests.count { it.method == "PUT" })
        assertEquals("0012", store.logs().single().code); assertEquals("已签到", model.state.value.records.single().stateText)
        assertEquals(AttendanceCounts(1, 1), model.state.value.records.single().attendanceCounts)
    }
    @Test fun radarSuccessRefreshesCountsWithoutDowngradingSuccessWhenCountReadFails() = runTest(dispatcher) {
        for (failCountRead in listOf(false, true)) {
            val store = MemoryStore()
            val t = QueueTransport(
                jsonResponse("""{"rollcalls":[{"id":11,"is_radar":true,"status":"absent","rollcall_status":"active","rollcall_time":"2026-10-08 08:00:00","student_rollcalls":[{"student_id":1,"status":"absent"}]}],"pages":1}"""),
                jsonResponse("""{"rollcalls":[]}"""),
                jsonResponse("""{"rollcalls":[{"id":11,"is_radar":true,"status":"active","student_rollcalls":[{"student_id":1,"status":"absent"}]}]}"""),
                jsonResponse("{}"),
                if (failCountRead) jsonResponse("{}", 503) else jsonResponse("""{"rollcalls":[{"id":11,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
            val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
            model.loginAccount("a"); advanceUntilIdle()
            model.openCourse(Course("9", "课程")); advanceUntilIdle()
            model.submit("11"); advanceUntilIdle()
            assertEquals(LogResult.SUCCESS, store.logs().single().result)
            assertEquals("已签到", model.state.value.records.single().stateText)
            assertEquals(if (failCountRead) null else AttendanceCounts(1, 1), model.state.value.records.single().attendanceCounts)
            assertEquals(1, t.requests.count { it.method == "PUT" })
            assertFalse(model.state.value.busy)
        }
    }
    @Test fun renewalThatAlsoExpiresClearsAuthenticatedState() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = QueueTransport(jsonResponse("", 401), jsonResponse("", 401))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t), logins))
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
        jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"absent","rollcall_status":"active","rollcall_time":"2026-10-08 08:00:00","student_rollcalls":[]}],"pages":1}"""),
        jsonResponse("""{"rollcalls":[]}"""), *tail)
    @Test fun expiredSubmissionPreflightRenewsSelectedAccountAndWritesOnlyOnce() = runTest(dispatcher) {
        val store = MemoryStore(); val logins = mutableListOf<String>()
        val t = submissionTransport(
            jsonResponse("", 401),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":2,"status":"absent"}]}]}"""),
            jsonResponse("{}"),
            jsonResponse("""{"rollcalls":[{"id":11,"is_number":true,"number_code":"0012","status":"active","student_rollcalls":[{"student_id":2,"status":"on_call_fine"}]}]}"""))
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(t) {}, logins))
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
        val model = AppModel(flakyStore, dispatcher, dispatcher, auth(store, TronclassClient(t), mutableListOf()))
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
        val model = AppModel(store, dispatcher, dispatcher, auth(store, TronclassClient(transport), mutableListOf()))
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

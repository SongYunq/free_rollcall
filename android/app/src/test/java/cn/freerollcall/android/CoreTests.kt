package cn.freerollcall.android

import cn.freerollcall.android.core.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import kotlin.math.*

class QueueTransport(vararg responses: ApiResponse) : Transport {
    val requests = mutableListOf<ApiRequest>()
    private val queue = ArrayDeque(responses.toList())
    override suspend fun send(request: ApiRequest): ApiResponse { requests += request; return queue.removeFirst() }
}
fun jsonResponse(body: String, status: Int = 200) = ApiResponse(status, body)

class ModelTests {
    @Test fun onlyExplicitEndedAbsenceIsRed() {
        val ended = Attendance("1", activityStatus = "finished", isExpired = true)
        for (status in listOf(null, "", "unknown")) {
            assertFalse(ended.copy(personalStatus = status).isAbsent)
            assertEquals("已结束", ended.copy(personalStatus = status).stateText)
        }
        assertEquals("缺勤", ended.copy(personalStatus = "absent").stateText)
        assertTrue(ended.copy(personalStatus = "absent").isAbsent)
        assertEquals("已签到", ended.copy(personalStatus = "on_call_fine").stateText)
        assertEquals("已签到 · 迟到", ended.copy(personalStatus = "on_call_late").stateText)
    }
    @Test fun activeAnsweredDoesNotBecomeOngoingOrAbsent() {
        val active = Attendance("1", kind = AttendanceKind.NUMBER, activityStatus = "active", isExpired = false)
        assertEquals("正在签到", active.copy(personalStatus = "absent").stateText)
        assertTrue(active.canSubmit)
        assertEquals("已签到", active.copy(personalStatus = "present").stateText)
        assertFalse(active.copy(personalStatus = "present").canSubmit)
        assertFalse(active.copy(endTime = Instant.EPOCH).isActive)
    }
    @Test fun historyCodeHydrationPreservesBothStates() {
        val history = Attendance("1", kind = AttendanceKind.NUMBER, activityStatus = "finished", personalStatus = "on_call_fine", isExpired = true)
        val hydrated = history.withCode(Attendance("1", numberCode = "0012", activityStatus = "active", personalStatus = "absent", isExpired = false))
        assertEquals("0012", hydrated.numberCode); assertEquals("已签到", hydrated.stateText)
        assertFalse(hydrated.isActive)
    }
    @Test fun parsesNumericIdsAndCodeWithoutLosingLeadingZeros() {
        val row = Attendance.parse(parseJson("""{"rollcall_id":3,"number_code":"0007","is_number":true,"status":"absent","rollcall_status":"finished"}"""))
        assertEquals("3", row.id); assertEquals("0007", row.numberCode); assertEquals("缺勤", row.stateText)
    }
    @Test fun undelaredShortPageStillContinuesUntilEmpty() {
        val p = parsePage(parseJson("""{"courses":[{"id":1,"name":"课程"}]}"""), "courses", 1, 30, Course::parse)
        assertTrue(p.hasMore); assertFalse(p.completenessKnown)
        val end = parsePage(parseJson("""{"courses":[]}"""), "courses", 2, 30, Course::parse)
        assertFalse(end.hasMore)
    }
    @Test fun duplicatePagesStopAndDeduplicate() {
        val course = Course("1", "课程")
        var pages = PageAccumulator<Course>().append(DataPage(listOf(course, course), 1, true, false), Course::id)
        assertEquals(1, pages.items.size)
        pages = pages.append(DataPage(listOf(course), 2, true, false), Course::id)
        assertFalse(pages.hasMore); assertTrue(pages.note.contains("重复"))
    }
    @Test fun wrappedPaginationMetadataIsHonored() {
        val p = parsePage(parseJson("""{"data":{"rollcalls":[{"id":"1"}],"total":1}}"""), "rollcalls", 1, 99, Attendance::parse)
        assertFalse(p.hasMore); assertTrue(p.completenessKnown)
    }
    @Test fun timestampsUseShanghaiForSchoolLocalTimes() {
        assertEquals(Instant.parse("2026-10-05T00:00:00Z"), parseTime("2026-10-05 08:00:00"))
        assertEquals("2026-10-05 08:00:00", displayTime(Instant.parse("2026-10-05T00:00:00Z")))
        assertNull(parseTime("bad date"))
    }
    @Test fun responseParsingRejectsEmptyAndNonJsonErrorBodies() {
        for (body in listOf("", "  ", "InternalError", "{success:true}")) {
            try { parseJson(body); fail("Expected malformed response: $body") }
            catch (error: RollcallException) { assertEquals(RollcallException.Reason.MALFORMED, error.reason) }
        }
        assertTrue(parseJson("null").isJsonNull)
        assertEquals("页面结果", parseJson("\"页面结果\"").text())
    }
}
class ClientTests {
    @Test fun currentSemesterConditionsAndEveryCoursePage() = runTest {
        val transport = QueueTransport(jsonResponse("""{"semester":{"id":8},"academic_year":{"id":"9"}}"""),
            jsonResponse("""{"courses":[{"id":1,"display_name":"本学期"}],"pages":2}"""),
            jsonResponse("""{"courses":[{"id":2,"name":"第二页"}],"pages":2}"""))
        val courses = TronclassClient(transport).currentSemesterCourses()
        assertEquals(listOf("1", "2"), courses.map { it.id })
        transport.requests.drop(1).forEachIndexed { index, request ->
            assertEquals("POST", request.method); assertEquals("/api/my-courses", request.path)
            val conditions = request.body!!.field("conditions")!!
            assertEquals("8", conditions.field("semester_id")!!.asJsonArray[0].asString)
            assertEquals("9", conditions.field("academic_year_id")!!.asJsonArray[0].asString)
            assertEquals("recently_started", conditions.field("classify_type").text())
            assertEquals(index + 1, request.body.field("page").intValue())
        }
    }
    @Test fun detailUsesOnlyCurrentStudentAndDoesNotBorrowClassmateStatus() = runTest {
        val body = """{"rollcalls":[{"id":11,"is_number":true,"number_code":"0123","status":"finished","student_rollcalls":[{"student_id":2,"status":"on_call_fine"},{"student_id":1,"status":"absent"}]}]}"""
        val client = TronclassClient(QueueTransport(jsonResponse(body), jsonResponse(body)))
        assertEquals("absent", client.detail("9", "11", "2026-10-08", "1").personalStatus)
        assertNull(client.detail("9", "11", "2026-10-08", "99").personalStatus)
    }
    @Test fun timetableRollcallsFiltersOtherCoursesAndMatchesTargetId() = runTest {
        val body = """{"rollcalls":[
            {"id":10,"course":{"id":999},"number_code":"9999","student_rollcalls":[]},
            {"id":11,"course":{"id":9},"number_code":"0012","status":"active","student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]},
            {"id":12,"course_id":9,"number_code":"0013","student_rollcalls":[]}
        ]}"""
        val transport = QueueTransport(jsonResponse(body))
        val client = TronclassClient(transport)
        val detail = client.detail("9", "11", "2026-10-08", "1")
        assertEquals("0012", detail.numberCode)
        assertEquals("on_call_fine", detail.personalStatus)
        assertEquals("/api/timetable_rollcalls?course_ids=9&rollcall_date=2026-10-08", transport.requests.single().path)
    }
    @Test fun acceptedNumberSubmissionPollsWithoutResubmitting() = runTest {
        val transport = QueueTransport(jsonResponse("{}"),
            jsonResponse("""{"rollcalls":[{"id":9,"student_rollcalls":[{"student_id":1,"status":"absent"}]}]}"""),
            jsonResponse("""{"rollcalls":[{"id":9,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        val waits = mutableListOf<Long>()
        val record = TronclassClient(transport) { waits += it }.submitNumber("9", "0012", "1", "1", "2026-10-08")
        assertTrue(record.isAnswered)
        assertEquals(1, transport.requests.count { it.method == "PUT" })
        assertEquals("0012", transport.requests[0].body!!.field("numberCode").text())
        assertEquals(listOf(800L), waits)
        assertEquals("/api/timetable_rollcalls?course_ids=1&rollcall_date=2026-10-08", transport.requests[1].path)
    }
    @Test fun failedReadBackNeverResubmitsOrClaimsFailure() = runTest {
        val transport = QueueTransport(jsonResponse("{}"), jsonResponse("{}", 500), jsonResponse("{}", 503), jsonResponse("{}", 401))
        try { TronclassClient(transport) {}.submitNumber("9", "0012", "1", "1", "2026-10-08"); fail("Expected uncertain") }
        catch (error: RollcallException) { assertEquals(RollcallException.Reason.UNCERTAIN, error.reason) }
        assertEquals(1, transport.requests.count { it.method == "PUT" })
        assertEquals(3, transport.requests.count { it.method == "GET" })
        assertTrue(transport.requests.drop(1).all { it.path.startsWith("/api/timetable_rollcalls") })
    }
    @Test fun rejectedNumberCodeDoesNotPoll() = runTest {
        val transport = QueueTransport(jsonResponse("{}", 400))
        try { TronclassClient(transport).submitNumber("9", "12", "1"); fail() }
        catch (error: RollcallException) { assertEquals(RollcallException.Reason.OTHER, error.reason) }
        assertEquals(1, transport.requests.size)
    }
    @Test fun expiredOrHtmlLoginResponsesAreDetected() = runTest {
        for (response in listOf(jsonResponse("", 302), jsonResponse("", 401), jsonResponse("<html>登录</html>"))) {
            try { TronclassClient(QueueTransport(response)).profile(); fail() }
            catch (error: RollcallException) { assertEquals(RollcallException.Reason.EXPIRED, error.reason) }
        }
    }
    @Test fun numberSubmissionChecksIdentityAndCodeBeforeWriting() = runTest {
        for ((studentId, code) in listOf("" to "0012", "not-an-id" to "0012", "1" to "")) {
            val transport = QueueTransport()
            try { TronclassClient(transport).submitNumber("9", code, studentId); fail() }
            catch (_: RollcallException) { }
            assertTrue(transport.requests.isEmpty())
        }
    }
    @Test fun numberSubmissionSeparatesExpiredSessionAndUncertainServerErrors() = runTest {
        for ((response, reason) in listOf(
            jsonResponse("<html>登录</html>") to RollcallException.Reason.EXPIRED,
            jsonResponse("<html>服务异常</html>", 503) to RollcallException.Reason.UNCERTAIN,
            jsonResponse("", 408) to RollcallException.Reason.UNCERTAIN)) {
            val transport = QueueTransport(response)
            try { TronclassClient(transport).submitNumber("9", "0012", "1"); fail() }
            catch (error: RollcallException) { assertEquals(reason, error.reason) }
            assertEquals(1, transport.requests.size)
        }
    }
    @Test fun malformedAcceptedNumberResponseStillConfirmsByReadBack() = runTest {
        val transport = QueueTransport(jsonResponse("InternalError"),
            jsonResponse("""{"rollcalls":[{"id":9,"student_rollcalls":[{"student_id":1,"status":"on_call_fine"}]}]}"""))
        assertTrue(TronclassClient(transport).submitNumber("9", "0012", "1", "1", "2026-10-08").isAnswered)
        assertEquals(1, transport.requests.count { it.method == "PUT" })
    }
}
class RadarTests {
    @Test fun payloadHasExactlyTheBotFieldsIncludingNulls() {
        val body = RadarSubmission.payload(RadarSubmission.first, "device")
        assertEquals(setOf("accuracy", "altitude", "altitudeAccuracy", "deviceId", "heading", "latitude", "longitude", "speed"), body.keySet())
        assertTrue(body["altitudeAccuracy"].isJsonNull); assertTrue(body["heading"].isJsonNull); assertTrue(body["speed"].isJsonNull)
        assertEquals(35, body["accuracy"].asInt); assertEquals("device", body["deviceId"].asString)
    }
    @Test fun intersectedCoordinatesMatchBotOrder() {
        val points = RadarSubmission.solve(25000.0, 25000.0)!!
        assertEquals(2, points.size)
        assertTrue(points[0].latitude > points[1].latitude)
        assertTrue(points[0].longitude < points[1].longitude)
        val lat0 = 24.45; val lon0 = 118.1; val radius = 6371000.0
        fun xy(p: Coordinate) = Math.toRadians(p.longitude - lon0) * radius * cos(Math.toRadians(lat0)) to Math.toRadians(p.latitude - lat0) * radius
        for (point in points) for (probe in listOf(RadarSubmission.first, RadarSubmission.second)) {
            val (x, y) = xy(point); val (px, py) = xy(probe)
            assertEquals(25000.0, hypot(x-px, y-py), .0001)
        }
        assertNull(RadarSubmission.solve(1.0, 1.0)); assertNull(RadarSubmission.solve(Double.NaN, 1.0))
    }
    @Test fun firstProbeSuccessStopsImmediately() = runTest {
        val transport = QueueTransport(jsonResponse("{}"))
        assertTrue(RadarSubmission.run(transport, "1")); assertEquals(1, transport.requests.size)
        assertTrue(transport.requests.single().radarHeaders)
    }
    @Test fun failedProbesUseBothIntersectionsInBotSequence() = runTest {
        val transport = QueueTransport(jsonResponse("""{"distance":25000}""", 400), jsonResponse("""{"distance":25000}""", 400),
            jsonResponse("{}", 400), jsonResponse("{}"))
        assertTrue(RadarSubmission.run(transport, "1"))
        val expected = listOf(RadarSubmission.first, RadarSubmission.second) + RadarSubmission.solve(25000.0, 25000.0)!!
        for ((index, request) in transport.requests.withIndex()) {
            assertEquals(expected[index].latitude, request.body!!.field("latitude").doubleValue()!!, .000001)
            assertEquals("PUT", request.method); assertEquals("/api/rollcall/1/answer", request.path)
        }
    }
    @Test fun damagedSuccessfulProbeResponseIsUncertainAndNeverRetried() = runTest {
        for (body in listOf("not json", "InternalError", "")) {
            val transport = QueueTransport(jsonResponse(body))
            try { RadarSubmission.run(transport, "1"); fail() }
            catch (error: RollcallException) { assertEquals(RollcallException.Reason.UNCERTAIN, error.reason) }
            assertEquals(1, transport.requests.size)
        }
    }
    @Test fun expiredRadarSessionStopsBeforeAnotherProbe() = runTest {
        for (response in listOf(jsonResponse("", 302), jsonResponse("{}", 401), jsonResponse("{}", 403),
            jsonResponse("<html>登录</html>"))) {
            val transport = QueueTransport(response)
            try { RadarSubmission.run(transport, "1"); fail() }
            catch (error: RollcallException) { assertEquals(RollcallException.Reason.EXPIRED, error.reason) }
            assertEquals(1, transport.requests.size)
        }
    }
    @Test fun uncertainRadarResponseStopsAtEveryStepOfBotSequence() = runTest {
        val distance = jsonResponse("""{"distance":25000}""", 400)
        for (step in 0..3) {
            val prior = listOf(distance, distance, jsonResponse("{}", 400)).take(step)
            val transport = QueueTransport(*(prior + jsonResponse("<html>服务异常</html>", 503)).toTypedArray())
            try { RadarSubmission.run(transport, "1"); fail() }
            catch (error: RollcallException) { assertEquals(RollcallException.Reason.UNCERTAIN, error.reason) }
            assertEquals(step + 1, transport.requests.size)
        }
    }
}

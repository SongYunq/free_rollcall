import XCTest
import UIKit
import RollcallCore
@testable import FreeRollcall

private let sampleRollcallTime = "2026-10-08T00:03:17Z"
private let sampleTimetablePath = "/api/timetable_rollcalls?course_ids=1&rollcall_date=2026-10-08"

private func timetableBody(id: String = "7", date: String = sampleRollcallTime, status: String? = "absent",
                           activity: String = "finished", code: String = "0012", courseID: String = "1") -> String {
    var students: [[String: String]] = [["student_id": "999", "status": "on_call"]]
    if let status { students.append(["student_id": "9", "status": status]) }
    let row: [String: Any] = [
        "id": id, "course": ["id": courseID, "name": "Test"], "is_number": true,
        "number_code": code, "status": activity, "rollcall_time": date, "student_rollcalls": students
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: ["rollcalls": [row]]), encoding: .utf8)!
}

actor StateTransport: HTTPTransport {
    var writes = 0
    var expired = false
    var answered = false
    var delay: UInt64 = 0
    private(set) var requests: [APIRequest] = []
    func configure(expired: Bool = false, delay: UInt64 = 0) { self.expired = expired; self.delay = delay }
    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if expired { return APIResponse(status: 401, data: Data()) }
        let json: String
        if request.method == "PUT", request.path == "/api/rollcall/7/answer_number_rollcall" {
            writes += 1; answered = true; json = "{}"
        } else if request.path == "/api/current-semester-info" { json = #"{"semester":{"id":7},"academic_year":{"id":2026}}"# }
        else if request.path == "/api/my-courses" { json = #"{"courses":[{"id":1,"name":"Test"}],"pages":1}"# }
        else if request.path == sampleTimetablePath {
            json = timetableBody(status: answered ? "on_call" : "absent", activity: "active")
        } else { throw RollcallError.message("Unexpected request: \(request.path)") }
        return APIResponse(status: 200, data: Data(json.utf8))
    }
}

actor SequenceTransport: HTTPTransport {
    private var replies: [APIResponse]
    private(set) var requests: [APIRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies.map { APIResponse(status: $0.0, data: Data($0.1.utf8)) } }
    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        guard !request.path.contains("/student_rollcalls") else { throw RollcallError.message("Legacy detail endpoint must not be used") }
        guard !replies.isEmpty else { throw RollcallError.message("Unexpected request") }
        return replies.removeFirst()
    }
}

@MainActor final class AppStateTests: XCTestCase {
    func makeSession(_ id: UUID, username: String, transport: any HTTPTransport) throws -> AuthenticatedSession {
        let profile = try UserProfile(json: .object(["id": .string("9"), "user_no": .string(username)]))
        return AuthenticatedSession(accountID: id, generation: UUID(), profile: profile, client: TronclassClient(transport: transport))
    }
    func testDefaultDoesNotReplaceManuallyLoggedAccount() async throws {
        let store = try LocalStore(inMemory: true), transport = StateTransport()
        let a = try store.saveAccount(id: nil, username: "a", password: " a ", note: "A")
        let b = try store.saveAccount(id: nil, username: "b", password: "b", note: "B")
        XCTAssertEqual(store.defaultAccount?.id, a.id); XCTAssertEqual(try store.password(a.id), " a ")
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(b.id)
        try store.makeDefault(a)
        await state.enterCourses()
        XCTAssertEqual(state.currentAccountID, b.id); XCTAssertEqual(state.courses.count, 1)
    }
    func testFirstOperationUsesDefaultAndStartupDoesNotLogin() async throws {
        let store = try LocalStore(inMemory: true), transport = StateTransport()
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let state = AppState(store: store)
        XCTAssertNil(state.session)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        await state.enterCourses()
        XCTAssertEqual(state.currentAccountID, a.id); XCTAssertEqual(state.homePath, [.courses])
    }
    func testFailedSwitchPreservesOldSession() async throws {
        let store = try LocalStore(inMemory: true), transport = StateTransport()
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let b = try store.saveAccount(id: nil, username: "b", password: "b", note: "")
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in
            if id == b.id { throw RollcallError.invalidCredentials }
            return try self.makeSession(id, username: username, transport: transport)
        }
        _ = try await state.login(a.id)
        let generation = state.session?.generation
        do { _ = try await state.login(b.id); XCTFail("expected rejection") } catch {}
        XCTAssertEqual(state.currentAccountID, a.id); XCTAssertEqual(state.session?.generation, generation)
    }
    func testExpiredManuallyChosenAccountReauthenticatesSameAccount() async throws {
        let store = try LocalStore(inMemory: true)
        _ = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let b = try store.saveAccount(id: nil, username: "b", password: "b", note: "")
        let state = AppState(store: store), expired = StateTransport(), renewed = StateTransport()
        await expired.configure(expired: true)
        var logins: [UUID] = []
        state.authentication = { id, username, _, _ in
            logins.append(id)
            return try self.makeSession(id, username: username, transport: logins.count == 1 ? expired : renewed)
        }
        _ = try await state.login(b.id); await state.loadCourses()
        XCTAssertEqual(logins, [b.id, b.id]); XCTAssertEqual(state.courses.count, 1)
    }
    func testLateOldAccountReadCannotOverwriteNewAccountPages() async throws {
        let store = try LocalStore(inMemory: true), slow = StateTransport(), fast = StateTransport()
        await slow.configure(delay: 150_000_000)
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let b = try store.saveAccount(id: nil, username: "b", password: "b", note: "")
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: id == a.id ? slow : fast) }
        _ = try await state.login(a.id)
        let oldRead = Task { await state.loadCourses() }
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await state.login(b.id)
        await oldRead.value
        XCTAssertTrue(state.courses.isEmpty); XCTAssertNil(state.coursesError)
    }
    func testDoubleTapProducesOneWriteAndOneLog() async throws {
        let store = try LocalStore(inMemory: true), transport = StateTransport()
        await transport.configure(delay: 30_000_000)
        _ = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000)
            return try self.makeSession(id, username: username, transport: transport)
        }
        let record = try Attendance(json: .object(["rollcall_id": .string("7"), "course_id": .string("1"), "rollcall_time": .string(sampleRollcallTime), "is_number": .bool(true), "status": .string("active")]))
        let course = Course(id: "1", name: "Test")
        async let first: Void = state.submit(record, course: course)
        async let second: Void = state.submit(record, course: course)
        _ = await (first, second)
        let writes = await transport.writes
        XCTAssertEqual(writes, 1); XCTAssertEqual(store.logs.count, 1); XCTAssertEqual(store.logs.first?.result, .success)
        XCTAssertEqual(store.logs.first?.code, "0012")
        XCTAssertEqual(store.logs.first?.rollcallDate, Attendance.parseDate(sampleRollcallTime))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), [sampleTimetablePath, "/api/rollcall/7/answer_number_rollcall", sampleTimetablePath])
        XCTAssertEqual(requests.map(\.method), ["GET", "PUT", "GET"])
    }
    func testDeletingDefaultDoesNotChooseReplacementOrDeleteLogs() async throws {
        let store = try LocalStore(inMemory: true)
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "Old label")
        _ = try store.saveAccount(id: nil, username: "b", password: "b", note: "")
        let record = try Attendance(json: .object(["rollcall_id": .string("7"), "course_id": .string("1"), "rollcall_time": .string(sampleRollcallTime), "is_radar": .bool(true)]))
        let log = try store.begin(account: a, studentID: "9", course: Course(id: "1", name: "Test"), record: record)
        try store.update(log, result: .success, message: "签到成功")
        try store.delete(a)
        XCTAssertNil(store.defaultAccount); XCTAssertEqual(store.logs.count, 1)
        XCTAssertEqual(store.logs[0].username, "a"); XCTAssertEqual(store.logs[0].accountNote, "Old label")
        XCTAssertEqual(store.logs[0].codeText, "雷达签到")
    }
    func testEditingPasswordInvalidatesOnlyCurrentSession() async throws {
        let store = try LocalStore(inMemory: true), transport = StateTransport()
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(a.id)
        try state.saveAccount(id: a.id, username: "a", password: "new", note: "")
        XCTAssertNil(state.session); XCTAssertEqual(state.currentAccountID, a.id)
        XCTAssertEqual(try store.password(a.id), "new")
    }
    func testFailedLoginDuringSubmissionStillCreatesFailureLog() async throws {
        let store = try LocalStore(inMemory: true)
        _ = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let state = AppState(store: store)
        state.authentication = { _, _, _, _ in throw RollcallError.invalidCredentials }
        let record = try Attendance(json: .object(["rollcall_id": .string("7"), "is_number": .bool(true)]))
        await state.submit(record, course: Course(id: "1", name: "Test"))
        XCTAssertEqual(store.logs.count, 1); XCTAssertEqual(store.logs.first?.result, .failure)
        XCTAssertFalse(state.busy)
    }
    func testCourseRefreshFailureKeepsPreviouslyLoadedCourses() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, #"{"semester":{"id":7},"academic_year":{"id":2026}}"#),
            (200, #"{"courses":[{"id":1,"name":"Saved course"}],"pages":1}"#),
            (200, #"{"semester":{"id":7},"academic_year":{"id":2026}}"#), (500, "{}")
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        await state.loadCourses(); await state.loadCourses()
        XCTAssertEqual(state.courses.map(\.name), ["Saved course"])
        XCTAssertNotNil(state.coursesError)
    }
    func testHistoryPaginationPreservesConfirmedStatusAndFetchedCode() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, #"{"rollcalls":[{"rollcall_id":7,"is_number":true,"is_expired":false,"status":"absent","rollcall_time":"2026-10-08T00:03:17Z"}]}"#),
            (200, #"{"rollcalls":[]}"#),
            (200, timetableBody(activity: "active")),
            (200, timetableBody(status: "on_call", activity: "active")),
            (200, #"{"rollcalls":[{"rollcall_id":8,"is_number":true,"rollcall_status":"finished","rollcall_time":"2026-10-07T00:03:17Z"}]}"#),
            (200, #"{"rollcalls":[]}"#),
            (200, timetableBody(id: "8", date: "2026-10-07T00:03:17Z", code: "0034"))
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let course = Course(id: "1", name: "Test")
        await state.loadHistory(course: course, reset: true)
        XCTAssertEqual(state.records.first?.numberCode, "0012")
        _ = try await state.detail(try XCTUnwrap(state.records.first))
        await state.loadHistory(course: course, reset: false)
        let record = try XCTUnwrap(state.records.first(where: { $0.id == "7" }))
        XCTAssertTrue(record.isAnswered); XCTAssertEqual(record.numberCode, "0012")
        XCTAssertEqual(state.records.count, 2)
        XCTAssertEqual(state.records.first(where: { $0.id == "8" })?.numberCode, "0034")
        XCTAssertNil(state.historyError)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/timetable_rollcalls?") }.map(\.path), [
            sampleTimetablePath, sampleTimetablePath,
            "/api/timetable_rollcalls?course_ids=1&rollcall_date=2026-10-07"
        ])
    }
    func testAutomaticCodesPreserveEveryExistingAttendanceState() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let history = #"{"rollcalls":[{"rollcall_id":7,"is_number":true,"rollcall_status":"finished","status":"on_call_fine","rollcall_time":"2026-09-20T08:00:00Z"},{"rollcall_id":8,"is_number":true,"rollcall_status":"finished","status":"on_call_late","rollcall_time":"2026-09-19T08:00:00Z"},{"rollcall_id":9,"is_number":true,"rollcall_status":"finished","rollcall_time":"2026-09-18T08:00:00Z"},{"rollcall_id":10,"is_number":true,"rollcall_status":"finished","status":"absent","rollcall_time":"2026-09-17T08:00:00Z"}]}"#
        // Automatic code enrichment must not replace personal/activity states from history.
        let details = zip(["7", "8", "9", "10"], ["20", "19", "18", "17"]).map { id, day in
            (200, timetableBody(id: id, date: "2026-09-\(day)T08:00:00Z", status: "absent", activity: "active"))
        }
        let transport = SequenceTransport([(200, history), (200, #"{"rollcalls":[]}"#)] + details)
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        await state.loadHistory(course: Course(id: "1", name: "Test"), reset: true)
        XCTAssertEqual(state.records.map(\.stateText), ["已签到", "已签到 · 迟到", "已结束", "缺勤"])
        XCTAssertEqual(state.records.map(\.isAbsent), [false, false, false, true])
        XCTAssertTrue(state.records.allSatisfy { $0.numberCode == "0012" && $0.hasEnded })
        XCTAssertNil(state.historyError); XCTAssertTrue(store.logs.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6); XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
    }
    func testCodeFailureAndRetryNeverTurnAnsweredHistoryIntoAbsence() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let history = #"{"rollcalls":[{"rollcall_id":7,"is_number":true,"status":"on_call_fine","rollcall_status":"finished","rollcall_time":"2026-09-20T08:00:00Z"},{"rollcall_id":8,"is_number":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-09-19T08:00:00Z"}]}"#
        let firstCode = timetableBody(date: "2026-09-20T08:00:00Z", status: nil, code: "0034")
        let secondCode = timetableBody(id: "8", date: "2026-09-19T08:00:00Z", status: nil, code: "0034")
        let transport = SequenceTransport([
            (200, history), (200, #"{"rollcalls":[]}"#), (500, "{}"), (200, secondCode),
            (200, history), (200, #"{"rollcalls":[]}"#), (200, firstCode), (200, secondCode)
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let course = Course(id: "1", name: "Test")
        await state.loadHistory(course: course, reset: true)
        XCTAssertEqual(state.records.map(\.stateText), ["已签到", "缺勤"])
        XCTAssertNil(state.records[0].numberCode); XCTAssertEqual(state.records[1].numberCode, "0034")
        XCTAssertEqual(state.historyError, "部分签到码未获取，可下拉刷新重试")
        await state.loadHistory(course: course, reset: true)
        XCTAssertEqual(state.records.map(\.stateText), ["已签到", "缺勤"])
        XCTAssertTrue(state.records.allSatisfy { $0.numberCode == "0034" }); XCTAssertNil(state.historyError)
    }
    func testHistoryRefreshFailureRetainsSameCourseButSwitchClearsOldCourse() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, #"{"rollcalls":[{"rollcall_id":7,"rollcall_status":"finished","rollcall_time":"2026-10-08T00:03:17Z"}]}"#),
            (200, #"{"rollcalls":[]}"#), (200, timetableBody()), (500, "{}"), (500, "{}")
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let first = Course(id: "1", name: "First")
        await state.loadHistory(course: first, reset: true)
        await state.loadHistory(course: first, reset: true)
        XCTAssertEqual(state.records.count, 1); XCTAssertNotNil(state.historyError)
        state.operationMessage = "旧课程的结果"
        await state.loadHistory(course: Course(id: "2", name: "Second"), reset: true)
        XCTAssertTrue(state.records.isEmpty); XCTAssertNil(state.operationMessage)
    }
    func testOpeningAnsweredDetailKeepsOnCallAndUnknownStatusesAnswered() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, timetableBody(status: "on_call")),
            (200, timetableBody(status: nil)),
            (200, timetableBody(status: "new_unknown_school_status"))
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let record = try Attendance(json: .object([
            "id": .string("7"), "status": .string("on_call_fine"), "rollcall_status": .string("finished"),
            "rollcall_time": .string(sampleRollcallTime), "is_number": .bool(true)
        ]))
        state.historyCourseID = "1"; state.records = [record]
        for _ in 0..<3 {
            let detail = try await state.detail(record, allowAuthentication: false)
            XCTAssertEqual(detail.stateText, "已签到")
            XCTAssertEqual(state.records.first?.stateText, "已签到")
            XCTAssertEqual(state.records.first?.numberCode, "0012")
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), Array(repeating: sampleTimetablePath, count: 3))
    }
    func testSameBeijingDayHydratesMultipleCodesWithOneRequest() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let history = #"{"rollcalls":[{"rollcall_id":7,"is_number":true,"status":"on_call_fine","rollcall_status":"finished","rollcall_time":"2026-10-07T16:30:00Z"},{"rollcall_id":8,"is_number":true,"status":"absent","rollcall_status":"finished","rollcall_time":"2026-10-08T00:03:17Z"}]}"#
        let timetable = #"{"rollcalls":[{"id":7,"course":{"id":1},"is_number":true,"number_code":"0007","status":"finished","rollcall_time":"2026-10-07T16:30:00Z","student_rollcalls":[{"student_id":9,"status":"absent"}]},{"id":8,"course":{"id":1},"is_number":true,"number_code":"0008","status":"finished","rollcall_time":"2026-10-08T00:03:17Z","student_rollcalls":[{"student_id":9,"status":"on_call"}]}]}"#
        let transport = SequenceTransport([(200, history), (200, #"{"rollcalls":[]}"#), (200, timetable)])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        await state.loadHistory(course: Course(id: "1", name: "Test"), reset: true)
        XCTAssertEqual(state.records.first(where: { $0.id == "7" })?.numberCode, "0007")
        XCTAssertEqual(state.records.first(where: { $0.id == "7" })?.stateText, "已签到")
        XCTAssertEqual(state.records.first(where: { $0.id == "8" })?.numberCode, "0008")
        XCTAssertEqual(state.records.first(where: { $0.id == "8" })?.stateText, "缺勤")
        XCTAssertNil(state.historyError)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.path, sampleTimetablePath)
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
    }
    func testUnconfirmedSubmissionAndReconcileUseOriginalCourseAndDateWithoutResubmitting() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, timetableBody(activity: "active")), (200, "{}"),
            (200, timetableBody(status: nil, activity: "active")),
            (200, timetableBody(status: "on_call"))
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let record = try Attendance(json: .object([
            "id": .string("7"), "is_number": .bool(true), "status": .string("active"),
            "rollcall_time": .string(sampleRollcallTime)
        ]))
        await state.submit(record, course: Course(id: "1", name: "Test"))
        let log = try XCTUnwrap(store.logs.first)
        XCTAssertEqual(log.result, .uncertain)
        XCTAssertEqual(log.rollcallDate, Attendance.parseDate(sampleRollcallTime))
        // The user may navigate elsewhere before reconciling this old log.
        state.historyCourseID = "777"
        try await state.reconcile(log)
        XCTAssertEqual(log.result, .success)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), [sampleTimetablePath, "/api/rollcall/7/answer_number_rollcall", sampleTimetablePath, sampleTimetablePath])
        XCTAssertEqual(requests.filter { $0.method == "PUT" }.count, 1)
    }
    func testLegacyLogRecoversDateFromHistoryPagesBeforeReconcile() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, #"{"rollcalls":[{"rollcall_id":99,"rollcall_time":"2026-10-10T00:03:17Z"}],"pages":2}"#),
            (200, #"{"rollcalls":[{"rollcall_id":7,"rollcall_time":"2026-10-08T00:03:17Z"}],"pages":2}"#),
            (200, timetableBody(status: "on_call"))
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let record = try Attendance(json: .object(["id": .string("7"), "is_number": .bool(true)]))
        let log = try store.begin(account: account, studentID: "9", course: Course(id: "1", name: "Test"), record: record)
        try store.update(log, result: .uncertain, message: "旧记录")
        XCTAssertNil(log.rollcallDate)
        try await state.reconcile(log)
        XCTAssertEqual(log.result, .success)
        XCTAssertEqual(log.rollcallDate, Attendance.parseDate(sampleRollcallTime))
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.path.contains("/student/") }.map(\.path), [
            "/api/course/1/student/9/rollcalls?page=1&page_size=99",
            "/api/course/1/student/9/rollcalls?page=2&page_size=99"
        ])
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/timetable_rollcalls?") }.map(\.path), [sampleTimetablePath])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
    }
    func testEndedReconcileWithoutOwnStatusStaysUncertain() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([(200, timetableBody(status: nil)), (200, timetableBody(status: "absent"))])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let record = try Attendance(json: .object([
            "id": .string("7"), "rollcall_time": .string(sampleRollcallTime), "is_number": .bool(true)
        ]))
        let log = try store.begin(account: account, studentID: "9", course: Course(id: "1", name: "Test"), record: record)
        try store.update(log, result: .uncertain, message: "待核对")
        try await state.reconcile(log)
        XCTAssertEqual(log.result, .uncertain, "其他同学已签到不代表本人已签到，缺少本人行也不代表缺勤")
        try await state.reconcile(log)
        XCTAssertEqual(log.result, .failure, "明确的本人缺勤状态才判为失败")
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.path == sampleTimetablePath })
    }
    func testKeychainRoundTripKeepsPasswordExactly() async throws {
        let id = UUID(); defer { try? CredentialVault.delete(id) }
        let password = "  test-'\\\"-中文  "
        try CredentialVault.write(password, id: id)
        XCTAssertEqual(try CredentialVault.read(id), password)
        try CredentialVault.write("replacement", id: id)
        XCTAssertEqual(try CredentialVault.read(id), "replacement")
        try CredentialVault.delete(id)
        XCTAssertThrowsError(try CredentialVault.read(id))
    }
    func testDiskReopenRestoresAccountsAndMarksInterruptedLogUncertain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RollcallTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.store")
        var accountID: UUID?
        defer { if let accountID { try? CredentialVault.delete(accountID) } }
        do {
            let store = try LocalStore(storageURL: url)
            let account = try store.saveAccount(id: nil, username: "disk-test", password: "example", note: "Snapshot")
            accountID = account.id
            let record = try Attendance(json: .object(["rollcall_id": .string("7"), "course_id": .string("1"), "rollcall_time": .string(sampleRollcallTime), "is_radar": .bool(true)]))
            _ = try store.begin(account: account, studentID: "9", course: Course(id: "1", name: "Test"), record: record)
        }
        let reopened = try LocalStore(storageURL: url)
        XCTAssertEqual(reopened.defaultAccount?.id, accountID)
        XCTAssertEqual(reopened.logs.count, 1); XCTAssertEqual(reopened.logs.first?.result, .uncertain)
        XCTAssertEqual(reopened.logs.first?.accountNote, "Snapshot")
        XCTAssertEqual(try reopened.password(try XCTUnwrap(accountID)), "example")
    }
    func testLiveLoginReadOnly() async throws {
        // Optional local integration check. Never runs unless explicitly opted in; never submits attendance.
        guard let path = ProcessInfo.processInfo.environment["ROLLCALL_TEST_CREDENTIALS_PATH"] else {
            throw XCTSkip("需要显式提供本机凭据文件路径才进行真实只读登录检查")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let username = values["username"], let password = values["password"] else {
            XCTFail("凭据文件缺少必要字段"); return
        }
        let auth = WebAuthenticator()
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        auth.webView.frame = window?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        window?.addSubview(auth.webView)
        defer { auth.cancel(); auth.webView.removeFromSuperview() }
        let session = try await auth.authenticate(accountID: UUID(), username: username, password: password, knownID: nil)
        XCTAssertTrue(session.profile.matches(username, knownID: nil), "学校返回身份应与输入一致")
        _ = try await session.client.currentSemesterCourses()
    }
}

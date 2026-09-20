import XCTest
import UIKit
import RollcallCore
@testable import FreeRollcall

actor StateTransport: HTTPTransport {
    var writes = 0
    var expired = false
    var answered = false
    var delay: UInt64 = 0
    func configure(expired: Bool = false, delay: UInt64 = 0) { self.expired = expired; self.delay = delay }
    func send(_ request: APIRequest) async throws -> APIResponse {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if expired { return APIResponse(status: 401, data: Data()) }
        let json: String
        if request.method == "PUT" { writes += 1; answered = true; json = "{}" }
        else if request.path == "/api/current-semester-info" { json = #"{"semester":{"id":7},"academic_year":{"id":2026}}"# }
        else if request.path == "/api/my-courses" { json = #"{"courses":[{"id":1,"name":"Test"}],"pages":1}"# }
        else { json = "{\"status\":\"active\",\"is_number\":true,\"number_code\":\"0012\",\"student_rollcalls\":[{\"student_id\":\"9\",\"status\":\"\(answered ? "on_call_fine" : "absent")\"}]}" }
        return APIResponse(status: 200, data: Data(json.utf8))
    }
}

actor SequenceTransport: HTTPTransport {
    private var replies: [APIResponse]
    init(_ replies: [(Int, String)]) { self.replies = replies.map { APIResponse(status: $0.0, data: Data($0.1.utf8)) } }
    func send(_ request: APIRequest) async throws -> APIResponse {
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
        let record = try Attendance(json: .object(["rollcall_id": .string("7"), "is_number": .bool(true), "status": .string("active")]))
        let course = Course(id: "1", name: "Test")
        async let first: Void = state.submit(record, course: course)
        async let second: Void = state.submit(record, course: course)
        _ = await (first, second)
        let writes = await transport.writes
        XCTAssertEqual(writes, 1); XCTAssertEqual(store.logs.count, 1); XCTAssertEqual(store.logs.first?.result, .success)
        XCTAssertEqual(store.logs.first?.code, "0012")
    }
    func testDeletingDefaultDoesNotChooseReplacementOrDeleteLogs() async throws {
        let store = try LocalStore(inMemory: true)
        let a = try store.saveAccount(id: nil, username: "a", password: "a", note: "Old label")
        _ = try store.saveAccount(id: nil, username: "b", password: "b", note: "")
        let record = try Attendance(json: .object(["rollcall_id": .string("7"), "is_radar": .bool(true)]))
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
            (200, #"{"rollcalls":[{"rollcall_id":7,"is_number":true,"is_expired":false,"status":"absent"}]}"#),
            (200, #"{"rollcalls":[]}"#),
            (200, #"{"status":"active","is_number":true,"number_code":"0012","student_rollcalls":[{"student_id":9,"status":"on_call_fine"}]}"#),
            (200, #"{"rollcalls":[{"rollcall_id":8,"is_number":true,"rollcall_status":"finished"}]}"#),
            (200, #"{"rollcalls":[]}"#)
        ])
        let state = AppState(store: store)
        state.authentication = { id, username, _, _ in try self.makeSession(id, username: username, transport: transport) }
        _ = try await state.login(account.id)
        let course = Course(id: "1", name: "Test")
        await state.loadHistory(course: course, reset: true)
        _ = try await state.detail(try XCTUnwrap(state.records.first))
        await state.loadHistory(course: course, reset: false)
        let record = try XCTUnwrap(state.records.first(where: { $0.id == "7" }))
        XCTAssertTrue(record.isAnswered); XCTAssertEqual(record.numberCode, "0012")
        XCTAssertEqual(state.records.count, 2)
    }
    func testHistoryRefreshFailureRetainsSameCourseButSwitchClearsOldCourse() async throws {
        let store = try LocalStore(inMemory: true)
        let account = try store.saveAccount(id: nil, username: "a", password: "a", note: "")
        let transport = SequenceTransport([
            (200, #"{"rollcalls":[{"rollcall_id":7,"rollcall_status":"finished"}]}"#),
            (200, #"{"rollcalls":[]}"#), (500, "{}"), (500, "{}")
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
            let record = try Attendance(json: .object(["rollcall_id": .string("7"), "is_radar": .bool(true)]))
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

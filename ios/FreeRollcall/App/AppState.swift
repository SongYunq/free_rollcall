import Foundation
import Observation
import RollcallCore

enum AppTab: Int, CaseIterable { case home, logs, accounts
    var title: String { switch self { case .home: return "功能"; case .logs: return "本地日志"; case .accounts: return "账号管理" } }
    var symbol: String { switch self { case .home: return "square.grid.2x2"; case .logs: return "clock.arrow.circlepath"; case .accounts: return "person.crop.circle" } }
}
enum HomeRoute: Hashable { case courses, history(Course) }
struct AppNotice: Identifiable { let id = UUID(); let text: String }
struct AccountEditorRoute: Identifiable { let id = UUID(); let accountID: UUID? }

@MainActor @Observable final class AppState {
    let store: LocalStore
    var tab: AppTab = .home
    var homePath: [HomeRoute] = []
    var notice: AppNotice?
    var editor: AccountEditorRoute?
    var authenticator: WebAuthenticator?
    var showingLogin = false
    var currentAccountID: UUID?
    var isLoggingIn = false
    var isSubmitting = false
    var preparingSubmission = false
    var enteringCourses = false
    var loadingCourses = false
    var loadingHistory = false
    var coursesError: String?
    var historyError: String?
    var operationMessage: String?
    var operationRecordID: String?
    var courses: [Course] = []
    var historyPage = PageAccumulator<Attendance>()
    var records: [Attendance] = []
    var historyCourseID: String?
    private(set) var session: AuthenticatedSession?
    @ObservationIgnored var authentication: ((UUID, String, String, String?) async throws -> AuthenticatedSession)?
    @ObservationIgnored private var loginTask: Task<AuthenticatedSession, Error>?
    @ObservationIgnored private var loginTarget: UUID?
    @ObservationIgnored private var failures: [UUID: Int] = [:]
    @ObservationIgnored private var courseRequest = UUID()
    @ObservationIgnored private var historyRequest = UUID()
    @ObservationIgnored private var detailEpoch = UUID()

    init(store: LocalStore) { self.store = store }
    var currentAccount: SavedAccount? { currentAccountID.flatMap(store.account) }
    var accountText: String {
        if let currentAccount { return "\(session == nil ? "待重新登录" : "当前账号") · \(currentAccount.username)" }
        if let account = store.defaultAccount { return "默认账号 · \(account.username)" }
        return "尚未设置账号"
    }
    var busy: Bool { isLoggingIn || isSubmitting || preparingSubmission }
    func report(_ error: Error) {
        if error as? RollcallError == .cancelled || error is CancellationError { return }
        notice = AppNotice(text: (error as? LocalizedError)?.errorDescription ?? "操作未完成，请重试")
    }
    private func resetPages() {
        courseRequest = UUID(); historyRequest = UUID(); detailEpoch = UUID()
        courses = []; historyPage = PageAccumulator()
        records = []; historyCourseID = nil; homePath = []
        coursesError = nil; historyError = nil; operationMessage = nil
        loadingCourses = false; loadingHistory = false
    }
    func logout() {
        guard !busy else { return }
        session = nil; currentAccountID = nil; authenticator = nil; resetPages()
    }
    func saveAccount(id: UUID?, username: String, password: String, note: String) throws {
        guard !busy else { throw RollcallError.message("请等待当前操作完成") }
        let old = id.flatMap(store.account)
        let usernameChanged = old.map { $0.username != username.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
        let changed = old.map { $0.username != username.trimmingCharacters(in: .whitespacesAndNewlines) || (try? store.password($0.id)) != password } ?? false
        let account = try store.saveAccount(id: id, username: username, password: password, note: note)
        if usernameChanged { failures[account.id] = nil }
        if changed && currentAccountID == account.id { session = nil; resetPages() }
    }
    func deleteAccount(_ account: SavedAccount) throws {
        guard !busy else { throw RollcallError.message("请等待当前操作完成") }
        let id = account.id
        try store.delete(account)
        if currentAccountID == id { session = nil; currentAccountID = nil; resetPages() }
        failures[id] = nil
    }
    func login(_ id: UUID) async throws -> AuthenticatedSession {
        if let loginTask {
            guard loginTarget == id else { throw RollcallError.message("正在登录另一个账号，请稍候") }
            return try await loginTask.value
        }
        guard !isSubmitting, let account = store.account(id) else { throw RollcallError.message("当前账号不可用，或签到尚未结束") }
        let username = account.username, password = try store.password(id), knownID = account.verifiedStudentID
        let auth = authentication == nil ? WebAuthenticator() : nil
        authenticator = auth; showingLogin = auth != nil; isLoggingIn = true; loginTarget = id
        let task = Task<AuthenticatedSession, Error> { [self] in
            let result: AuthenticatedSession
            do {
                if let authentication { result = try await authentication(id, username, password, knownID) }
                else { result = try await auth!.authenticate(accountID: id, username: username, password: password, knownID: knownID) }
            } catch RollcallError.invalidCredentials {
                failures[id, default: 0] += 1
                if failures[id, default: 0] >= 3, let auth {
                    result = try await auth.authenticate(accountID: id, username: username, password: password,
                                                       knownID: knownID, forceManual: true, reusePage: true)
                } else {
                    throw RollcallError.message("账号或密码错误，已连续失败 \(failures[id, default: 0]) 次，请修改账号后重试")
                }
            }
            try Task.checkCancellation()
            guard store.account(id) != nil else { throw RollcallError.cancelled }
            try store.verified(account, studentID: result.profile.id)
            let changedAccount = currentAccountID != id
            session = result; currentAccountID = id; failures[id] = 0
            if changedAccount { resetPages() }
            return result
        }
        loginTask = task
        defer { loginTask = nil; loginTarget = nil; isLoggingIn = false; showingLogin = false; authenticator = nil }
        return try await task.value
    }
    func cancelLogin() { authenticator?.cancel(); loginTask?.cancel() }
    private func ensureSession() async throws -> AuthenticatedSession {
        if let session { return session }
        guard let id = currentAccountID ?? store.defaultAccount?.id else { tab = .accounts; throw RollcallError.noDefaultAccount }
        return try await login(id)
    }
    private func read<T>(_ operation: (AuthenticatedSession) async throws -> T) async throws -> T {
        let initial = try await ensureSession()
        do {
            let result = try await operation(initial)
            guard session?.generation == initial.generation else { throw RollcallError.cancelled }
            return result
        } catch RollcallError.expiredSession {
            guard session?.generation == initial.generation else { throw RollcallError.cancelled }
            session = nil
            let renewed = try await login(initial.accountID)
            let result = try await operation(renewed)
            guard session?.generation == renewed.generation else { throw RollcallError.cancelled }
            return result
        }
    }
    func enterCourses() async {
        guard !enteringCourses, !busy else { return }
        enteringCourses = true; defer { enteringCourses = false }
        do {
            _ = try await ensureSession()
            if homePath.isEmpty { homePath.append(.courses) }
            await loadCourses()
        } catch { report(error) }
    }
    func loadCourses() async {
        guard !loadingCourses, !isSubmitting, !preparingSubmission else { return }
        let token = UUID(); courseRequest = token; loadingCourses = true; coursesError = nil
        defer { if courseRequest == token { loadingCourses = false } }
        do {
            let data = try await read { try await $0.client.currentSemesterCourses() }
            guard token == courseRequest else { return }
            courses = data
        } catch { if token == courseRequest { coursesError = error.localizedDescription } }
    }
    func loadHistory(course: Course, reset: Bool) async {
        guard !isSubmitting, !preparingSubmission, !(loadingHistory && historyCourseID == course.id) else { return }
        let token = UUID(); historyRequest = token; loadingHistory = true; historyError = nil
        defer { if historyRequest == token { loadingHistory = false } }
        let changedCourse = historyCourseID != course.id
        if changedCourse {
            historyPage = PageAccumulator(); records = []; detailEpoch = UUID()
        }
        if reset || changedCourse { operationMessage = nil }
        historyCourseID = course.id
        let page = reset ? 1 : historyPage.nextPage
        do {
            let data = try await read { try await $0.client.history(courseID: course.id, studentID: $0.profile.id, page: page) }
            guard token == historyRequest else { return }
            let visible = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            if reset { historyPage = PageAccumulator() }
            historyPage.append(data)
            // Loading older pages must retain already fetched codes and freshly confirmed results.
            records = historyPage.items.map { reset ? $0 : visible[$0.id] ?? $0 }
            // Active endpoint may include activities not yet visible in history. Only merge a proven course match.
            do {
                let active = try await read { try await $0.client.active() }
                guard token == historyRequest else { return }
                for item in active {
                    if let index = records.firstIndex(where: { $0.id == item.id }) { records[index].merge(item) }
                    else if item.courseID == course.id { records.append(item) }
                }
            } catch {
                guard token == historyRequest else { return }
                historyError = "历史记录已加载，当前活动刷新失败，可下拉重试"
            }
            records.sort { a, b in a.isActive != b.isActive ? a.isActive : (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            // History can omit numeric codes, including those of finished activities.
            // Fetch codes without replacing the history endpoint's personal/activity status.
            let missing = records.filter { ($0.kind == .number && $0.numberCode?.isEmpty != false) || $0.kind == .unknown }
            var incomplete = false
            for record in missing {
                guard token == historyRequest, !Task.isCancelled else { return }
                do {
                    let detail = try await read { try await $0.client.detail(id: record.id, studentID: $0.profile.id) }
                    guard token == historyRequest, !Task.isCancelled else { return }
                    if let index = records.firstIndex(where: { $0.id == record.id }) {
                        records[index].numberCode = detail.numberCode ?? records[index].numberCode
                        if records[index].kind == .unknown { records[index].kind = detail.kind }
                        if records[index].kind == .number && records[index].numberCode?.isEmpty != false { incomplete = true }
                    }
                } catch {
                    guard token == historyRequest, !Task.isCancelled, error as? RollcallError != .cancelled else { return }
                    incomplete = true
                }
            }
            if incomplete {
                let message = "部分签到码未获取，可下拉刷新重试"
                historyError = historyError.map { "\($0)；\(message)" } ?? message
            }
        } catch { if token == historyRequest { historyError = error.localizedDescription } }
    }
    func detail(_ record: Attendance, allowAuthentication: Bool = true) async throws -> Attendance {
        guard !isSubmitting, !preparingSubmission else { throw RollcallError.cancelled }
        let epoch = detailEpoch
        let detail: Attendance
        if allowAuthentication {
            detail = try await read { try await $0.client.detail(id: record.id, studentID: $0.profile.id) }
        } else {
            guard let current = session else { throw RollcallError.expiredSession }
            do {
                detail = try await current.client.detail(id: record.id, studentID: current.profile.id)
                guard session?.generation == current.generation else { throw RollcallError.cancelled }
            } catch {
                if error as? RollcallError == .expiredSession, session?.generation == current.generation { session = nil }
                throw error
            }
        }
        guard epoch == detailEpoch else { throw RollcallError.cancelled }
        var combined = record; combined.merge(detail)
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = combined }
        return combined
    }
    func submit(_ record: Attendance, course: Course) async {
        guard !busy else { return }
        preparingSubmission = true
        historyRequest = UUID(); courseRequest = UUID(); detailEpoch = UUID()
        loadingHistory = false; loadingCourses = false
        defer { preparingSubmission = false; detailEpoch = UUID() }
        guard let account = (currentAccountID ?? store.defaultAccount?.id).flatMap(store.account) else {
            report(RollcallError.noDefaultAccount); return
        }
        // Once created, every path finishes this one operation; account switching stays disabled.
        let log: AttendanceLog
        do { log = try store.begin(account: account, studentID: account.verifiedStudentID ?? "", course: course, record: record) }
        catch { report(error); return }
        operationRecordID = record.id; operationMessage = "正在准备签到"
        defer { isSubmitting = false; operationRecordID = nil }
        var accepted = false
        do {
            let current = try await ensureSession()
            isSubmitting = true
            log.studentID = current.profile.id
            var fresh = record
            fresh.merge(try await current.client.detail(id: record.id, studentID: current.profile.id))
            if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = fresh }
            if fresh.isAnswered {
                try store.update(log, result: .success, message: "该账号已签到，本次未重复提交", code: fresh.numberCode, kind: fresh.kind)
                operationMessage = "已签到，无需重复提交"; return
            }
            guard fresh.isActive else { throw RollcallError.message("签到已结束或状态未确认，请刷新后重试") }
            guard session?.generation == current.generation else { throw RollcallError.cancelled }
            try store.update(log, result: .processing, message: "正在提交签到", code: fresh.numberCode, kind: fresh.kind)
            operationMessage = "正在提交签到"
            switch fresh.kind {
            case .number:
                guard let code = fresh.numberCode, !code.isEmpty else { throw RollcallError.message("未能取得数字签到码") }
                let result = try await current.client.submitNumber(id: fresh.id, code: code, studentID: current.profile.id)
                fresh.merge(result)
            case .radar:
                guard try await current.client.submitRadar(id: fresh.id) else { throw RollcallError.message("雷达签到未完成，请稍后重试") }
                fresh.personalStatus = "on_call_fine"
            default: throw RollcallError.message("暂不支持此签到形式")
            }
            accepted = true
            if let i = records.firstIndex(where: { $0.id == fresh.id }) { records[i] = fresh }
            try store.update(log, result: .success, message: "签到成功", code: fresh.numberCode, kind: fresh.kind)
            operationMessage = "签到成功"
        } catch {
            let result: LogResult
            if accepted { result = .uncertain }
            else if case RollcallError.uncertain = error { result = .uncertain } else { result = .failure }
            if error as? RollcallError == .expiredSession { session = nil }
            do { try store.update(log, result: result, message: error.localizedDescription) } catch { report(error) }
            operationMessage = error.localizedDescription
        }
    }
    func reconcile(_ log: AttendanceLog) async throws {
        guard !busy else { throw RollcallError.message("请等待当前操作完成") }
        guard currentAccountID == log.accountID, let current = session else {
            throw RollcallError.message("请先在账号管理登录这条记录对应的账号")
        }
        do {
            guard current.profile.id == log.studentID else { throw RollcallError.identityMismatch }
            let detail = try await current.client.detail(id: log.rollcallID, studentID: log.studentID)
            guard session?.generation == current.generation else { throw RollcallError.cancelled }
            if detail.isAnswered { try store.update(log, result: .success, message: "已核对：学校记录显示已签到") }
            else if !detail.isActive && detail.activityStatus == "finished" {
                try store.update(log, result: .failure, message: "签到已结束，未查到本人签到成功记录")
            } else { try store.update(log, result: .uncertain, message: "暂未确认签到成功，可稍后再次核对") }
        } catch {
            if error as? RollcallError == .expiredSession, session?.generation == current.generation { session = nil }
            throw error
        }
    }
}

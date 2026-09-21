import Foundation
import SwiftData
import Security
import Observation
import RollcallCore

@Model final class SavedAccount {
    @Attribute(.unique) var id: UUID
    var username: String
    var note: String
    var isDefault: Bool
    var verifiedStudentID: String?
    var createdAt: Date
    init(id: UUID = UUID(), username: String, note: String, isDefault: Bool = false) {
        self.id = id; self.username = username; self.note = note; self.isDefault = isDefault
        self.createdAt = Date()
    }
    var label: String { note.isEmpty ? username : note }
}

enum LogResult: String { case processing, success, failure, uncertain
    var title: String {
        switch self { case .processing: return "处理中"; case .success: return "成功"
        case .failure: return "失败"; case .uncertain: return "待确认" }
    }
    var symbol: String {
        switch self { case .processing: return "arrow.triangle.2.circlepath"; case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle"; case .uncertain: return "questionmark.circle" }
    }
}

@Model final class AttendanceLog {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var accountID: UUID
    var username: String
    var accountNote: String
    var studentID: String
    var courseID: String
    var courseName: String
    var rollcallID: String
    var kindRaw: String
    var code: String?
    var resultRaw: String
    var message: String
    init(account: SavedAccount, studentID: String, course: Course, record: Attendance) {
        id = UUID(); createdAt = Date(); accountID = account.id
        username = account.username; accountNote = account.note; self.studentID = studentID
        courseID = course.id; courseName = course.name; rollcallID = record.id
        kindRaw = record.kind.rawValue; code = record.numberCode
        resultRaw = LogResult.processing.rawValue; message = "正在准备签到"
    }
    var result: LogResult { LogResult(rawValue: resultRaw) ?? .uncertain }
    var kind: AttendanceKind { AttendanceKind(rawValue: kindRaw) ?? .unknown }
    var codeText: String { kind == .radar ? "雷达签到" : (code ?? "未获取") }
}

enum CredentialVault {
    private static let service = "cn.free-rollcall.accounts"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }
    static func read(_ id: UUID) throws -> String {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw RollcallError.message("无法读取保存的密码，请重新编辑该账号")
        }
        return value
    }
    static func write(_ password: String, id: UUID) throws {
        let data = Data(password.utf8)
        let change = [kSecValueData as String: data]
        var status = SecItemUpdate(query(id) as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query(id); entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RollcallError.message("密码保存失败（\(status)），请检查设备解锁与应用签名") }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RollcallError.message("密码删除失败（\(status)），请重试") }
    }
}

@MainActor @Observable final class LocalStore {
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored private let inMemory: Bool
    @ObservationIgnored private var memoryPasswords: [UUID: String] = [:]
    private(set) var accounts: [SavedAccount] = []
    private(set) var logs: [AttendanceLog] = []
    init(inMemory: Bool = false, storageURL: URL? = nil) throws {
        self.inMemory = inMemory
        let config = storageURL.map { ModelConfiguration(url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        container = try ModelContainer(for: SavedAccount.self, AttendanceLog.self, configurations: config)
        context = ModelContext(container); context.autosaveEnabled = false
        try reload()
        for log in logs where log.result == .processing {
            log.resultRaw = LogResult.uncertain.rawValue
            log.message = "上次操作中断，请使用原账号核对签到状态"
        }
        try context.save()
    }
    func reload() throws {
        accounts = try context.fetch(FetchDescriptor<SavedAccount>()).sorted { $0.createdAt < $1.createdAt }
        logs = try context.fetch(FetchDescriptor<AttendanceLog>()).sorted { $0.createdAt > $1.createdAt }
    }
    func account(_ id: UUID) -> SavedAccount? { accounts.first { $0.id == id } }
    var defaultAccount: SavedAccount? { accounts.first(where: \.isDefault) }
    func password(_ id: UUID) throws -> String {
        if inMemory {
            guard let value = memoryPasswords[id] else { throw RollcallError.message("请重新填写密码") }
            return value
        }
        return try CredentialVault.read(id)
    }
    private func writePassword(_ password: String, id: UUID) throws {
        if inMemory { memoryPasswords[id] = password } else { try CredentialVault.write(password, id: id) }
    }
    private func deletePassword(_ id: UUID) throws {
        if inMemory { memoryPasswords[id] = nil } else { try CredentialVault.delete(id) }
    }
    func saveAccount(id: UUID?, username: String, password: String, note: String) throws -> SavedAccount {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { throw RollcallError.message("账号和密码不能为空") }
        guard !accounts.contains(where: { $0.username == username && $0.id != id }) else {
            throw RollcallError.message("这个账号已经存在，请修改已有账号")
        }
        let existing = id.flatMap(account)
        let record = existing ?? SavedAccount(username: username, note: note, isDefault: accounts.isEmpty)
        let oldPassword = existing == nil ? nil : try? self.password(record.id)
        try writePassword(password, id: record.id)
        if existing == nil { context.insert(record) }
        if record.username != username { record.verifiedStudentID = nil }
        record.username = username; record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try context.save(); try reload(); return record }
        catch {
            context.rollback()
            if let oldPassword { try? writePassword(oldPassword, id: record.id) }
            else { try? deletePassword(record.id) }
            throw RollcallError.message("账号保存失败，请重试")
        }
    }
    func makeDefault(_ account: SavedAccount) throws {
        for item in accounts { item.isDefault = item.id == account.id }
        do { try context.save(); try reload() }
        catch { context.rollback(); throw RollcallError.message("默认账号保存失败") }
    }
    func delete(_ account: SavedAccount) throws {
        let password = try? password(account.id)
        try deletePassword(account.id)
        context.delete(account)
        do { try context.save(); try reload() }
        catch {
            context.rollback()
            if let password { try? writePassword(password, id: account.id) }
            throw RollcallError.message("账号删除失败，请重试")
        }
    }
    func verified(_ account: SavedAccount, studentID: String) throws {
        account.verifiedStudentID = studentID
        do { try context.save() } catch { context.rollback(); throw RollcallError.message("账号验证信息保存失败") }
    }
    func begin(account: SavedAccount, studentID: String, course: Course, record: Attendance) throws -> AttendanceLog {
        let log = AttendanceLog(account: account, studentID: studentID, course: course, record: record)
        context.insert(log)
        do { try context.save(); try reload(); return log }
        catch { context.rollback(); throw RollcallError.message("无法保存签到记录，请检查本机存储后重试") }
    }
    func update(_ log: AttendanceLog, result: LogResult, message: String, code: String? = nil, kind: AttendanceKind? = nil) throws {
        log.resultRaw = result.rawValue; log.message = message
        if let code { log.code = code }; if let kind { log.kindRaw = kind.rawValue }
        if result != .processing { log.completedAt = Date() }
        do { try context.save(); try reload() }
        catch { context.rollback(); throw RollcallError.message("本地记录保存失败，请核对学校端结果后再操作") }
    }
}

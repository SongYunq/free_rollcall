import Foundation

public struct UserProfile: Equatable, Sendable {
    public let id: String
    public let account: String
    public let name: String
    public let email: String?
    public init(json: JSONValue) throws {
        guard let id = json["id"].string, let account = json["user_no"].string,
              !id.isEmpty, !account.isEmpty else { throw RollcallError.malformedResponse }
        self.id = id; self.account = account
        self.name = json["name"].string ?? account
        self.email = json["email"].string
    }
    public func matches(_ username: String, knownID: String?) -> Bool {
        if let knownID { return id == knownID }
        return account == username || email?.caseInsensitiveCompare(username) == .orderedSame
    }
}

public struct Course: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public init(json: JSONValue) throws {
        guard let id = json["id"].string, !id.isEmpty else { throw RollcallError.malformedResponse }
        self.id = id
        self.name = json["display_name"].string.flatMap { $0.isEmpty ? nil : $0 }
            ?? json["name"].string ?? "未命名课程"
    }
}

public enum AttendanceKind: String, Codable, Sendable {
    case number, radar, other, unknown
    public var title: String {
        switch self { case .number: return "数字签到"; case .radar: return "雷达签到"
        case .other: return "其他签到"; case .unknown: return "未知形式" }
    }
}

public struct Attendance: Identifiable, Hashable, Sendable {
    public let id: String
    public var courseID: String?
    public var courseName: String?
    public var date: Date?
    public var rawDate: String?
    public var kind: AttendanceKind
    public var activityStatus: String?
    public var personalStatus: String?
    public var isExpired: Bool?
    public var numberCode: String?
    public var endDate: Date?

    public init(json: JSONValue) throws {
        guard let id = json["rollcall_id"].string ?? json["id"].string else { throw RollcallError.malformedResponse }
        self.id = id
        self.courseID = json["course_id"].string ?? json["course"]["id"].string
        self.courseName = json["course_title"].string ?? json["course"]["name"].string
        self.rawDate = json["rollcall_time"].string ?? json["created_at"].string
        self.date = Self.parseDate(rawDate)
        self.kind = Self.kind(json)
        let status = json["status"].string
        self.activityStatus = json["rollcall_status"].string ?? (Self.activityStatuses.contains(status ?? "") ? status : nil)
        self.personalStatus = status.flatMap { Self.activityStatuses.contains($0) ? nil : $0 }
        self.isExpired = json["is_expired"].bool
        self.numberCode = json["number_code"].string
        self.endDate = Self.parseDate(json["end_time"].string)
    }
    public static let activityStatuses: Set<String> = ["active", "finished", "ended", "closed"]
    public var isAnswered: Bool { ["on_call_fine", "on_call_late", "present", "attended", "late"].contains(personalStatus ?? "") }
    public var hasEnded: Bool {
        isExpired == true || ["finished", "ended", "closed"].contains(activityStatus ?? "")
            || endDate.map { $0 <= Date() } == true
    }
    public var isActive: Bool {
        if hasEnded { return false }
        return activityStatus == "active" || isExpired == false
    }
    public var canSubmit: Bool { isActive && !isAnswered && (kind == .number || kind == .radar) }
    // An unknown/missing personal status is not evidence of absence.
    public var isAbsent: Bool { hasEnded && personalStatus == "absent" }
    public var stateText: String {
        if isAnswered { return personalStatus == "on_call_late" || personalStatus == "late" ? "已签到 · 迟到" : "已签到" }
        if isActive { return "正在签到" }
        if isAbsent { return "缺勤" }
        if hasEnded { return "已结束" }
        return "状态待确认"
    }
    public mutating func merge(_ other: Attendance) {
        guard id == other.id else { return }
        courseID = other.courseID ?? courseID; courseName = other.courseName ?? courseName
        date = other.date ?? date; rawDate = other.rawDate ?? rawDate
        if other.kind != .unknown { kind = other.kind }
        activityStatus = other.activityStatus ?? activityStatus
        personalStatus = other.personalStatus ?? personalStatus
        isExpired = other.isExpired ?? isExpired
        numberCode = other.numberCode ?? numberCode; endDate = other.endDate ?? endDate
    }
    public static func kind(_ json: JSONValue) -> AttendanceKind {
        if json["is_radar"].bool == true { return .radar }
        if json["is_number"].bool == true { return .number }
        if json["is_radar"].bool == false && json["is_number"].bool == false { return .other }
        if json["number_code"].string != nil { return .number }
        return .unknown
    }
    public static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: text) { return date }
        let plain = DateFormatter(); plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(identifier: "Asia/Shanghai"); plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return plain.date(from: text)
    }
}

public struct DataPage<Element: Sendable>: Sendable {
    public var items: [Element]
    public var page: Int
    public var pages: Int?
    public var total: Int?
    public var hasMore: Bool
    public var completenessKnown: Bool
}

public enum PageParser {
    public static func parse<T: Sendable>(_ json: JSONValue, key: String, page: Int, size: Int,
                                         transform: (JSONValue) throws -> T) throws -> DataPage<T> {
        let container: JSONValue = json["data"].object != nil ? json["data"] : json
        guard let raw = container.array ?? container[key].array ?? container["data"].array else {
            throw RollcallError.malformedResponse
        }
        let pages = container["pages"].int ?? json["pages"].int
        let total = container["total"].int ?? json["total"].int
        let flag = container["has_more"].bool ?? json["has_more"].bool
        let known = pages != nil || total != nil || flag != nil
        // A short page is not proof of the end when the server does not declare pagination.
        let more = flag ?? pages.map { page < $0 } ?? total.map { page * size < $0 } ?? !raw.isEmpty
        return DataPage(items: try raw.map(transform), page: page, pages: pages, total: total,
                        hasMore: more && !raw.isEmpty, completenessKnown: known)
    }
}

public struct PageAccumulator<Element: Identifiable & Sendable> where Element.ID: Hashable {
    public private(set) var items: [Element] = []
    public private(set) var nextPage = 1
    public private(set) var hasMore = true
    public private(set) var note = ""
    public init() {}
    public mutating func append(_ page: DataPage<Element>) {
        let ids = Set(items.map(\.id)); let added = page.items.filter { !ids.contains($0.id) }
        var seen = ids
        items.append(contentsOf: added.filter { seen.insert($0.id).inserted })
        if !page.items.isEmpty && added.isEmpty {
            hasMore = false; note = "学校返回重复记录，当前显示已取得的记录"
        } else {
            hasMore = page.hasMore
            note = hasMore ? "" : (page.completenessKnown ? "已全部加载" : "已加载当前可获取的记录")
        }
        nextPage = page.page + 1
    }
}

import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? {
        switch self {
        case .string(let v): return v
        case .number(let v) where v.isFinite:
            return v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: return nil
        }
    }
    public var double: Double? {
        if case .number(let v) = self { return v }
        if case .string(let v) = self { return Double(v) }
        return nil
    }
    public var int: Int? {
        guard let v = double, v.isFinite, v >= 0, v < Double(Int.max), v.rounded() == v else { return nil }
        return Int(v)
    }
    public var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public static func decode(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RollcallError.malformedResponse }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public enum RollcallError: Error, LocalizedError, Equatable, Sendable {
    case expiredSession, invalidCredentials, identityMismatch, malformedResponse, noDefaultAccount
    case message(String), uncertain(String), cancelled

    public var errorDescription: String? {
        switch self {
        case .expiredSession: return "登录已失效，请重新登录当前账号"
        case .invalidCredentials: return "账号或密码未通过认证，请修改后重试"
        case .identityMismatch: return "网页登录账号与所选账号不一致，请使用所选账号重新登录"
        case .malformedResponse: return "返回数据格式发生变化，请稍后重试"
        case .noDefaultAccount: return "请先添加账号并设为默认，或手动登录一个账号"
        case .message(let text), .uncertain(let text): return text
        case .cancelled: return "已取消"
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct APIRequest: Sendable {
    public let path: String
    public let method: String
    public let body: JSONValue?
    public let radarHeaders: Bool
    public init(_ path: String, method: String = "GET", body: JSONValue? = nil, radarHeaders: Bool = false) {
        self.path = path; self.method = method; self.body = body; self.radarHeaders = radarHeaders
    }
}
public struct APIResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
    public func json() throws -> JSONValue { try JSONValue.decode(data) }
}
public protocol HTTPTransport: Sendable {
    func send(_ request: APIRequest) async throws -> APIResponse
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class SchoolTransport: HTTPTransport, @unchecked Sendable {
    public static let host = "lnt.xmu.edu.cn"
    private let session: URLSession
    public init(cookies: [HTTPCookie]) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let url = URL(string: "https://\(Self.host)/")!
        for cookie in cookies {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if Self.host == domain || Self.host.hasSuffix("." + domain) {
                config.httpCookieStorage?.setCookies([cookie], for: url, mainDocumentURL: url)
            }
        }
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: APIRequest) async throws -> APIResponse {
        guard request.path.hasPrefix("/api/"), let url = URL(string: "https://\(Self.host)\(request.path)"),
              url.host == Self.host else { throw RollcallError.message("请求地址无效") }
        var native = URLRequest(url: url); native.httpMethod = request.method
        native.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        native.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        native.setValue(request.radarHeaders ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" : "application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        native.setValue(request.radarHeaders ? "https://ids.xmu.edu.cn/authserver/login" : "https://lnt.xmu.edu.cn/user/index", forHTTPHeaderField: "Referer")
        if let body = request.body {
            native.setValue("application/json", forHTTPHeaderField: "Content-Type")
            native.httpBody = try body.encoded()
        }
        do {
            let (data, response) = try await session.data(for: native)
            guard let response = response as? HTTPURLResponse else { throw RollcallError.malformedResponse }
            return APIResponse(status: response.statusCode, data: data)
        } catch {
            if request.method == "PUT" { throw RollcallError.uncertain("提交连接中断，结果待确认，请先核对签到状态") }
            if Task.isCancelled { throw RollcallError.cancelled }
            throw RollcallError.message("网络连接失败或超时，请重试")
        }
    }
}

public final class TronclassClient: Sendable {
    public let transport: any HTTPTransport
    public init(transport: any HTTPTransport) { self.transport = transport }
    private func read(_ request: APIRequest) async throws -> JSONValue {
        let response = try await transport.send(request)
        if response.status == 401 || response.status == 403 || (300..<400).contains(response.status) {
            throw RollcallError.expiredSession
        }
        guard response.status == 200 else { throw RollcallError.message("学校服务暂时不可用（\(response.status)）") }
        // Login redirects sometimes arrive as a 200 HTML page.
        if String(data: response.data.prefix(200), encoding: .utf8)?.lowercased().contains("<html") == true {
            throw RollcallError.expiredSession
        }
        return try response.json()
    }
    public func profile() async throws -> UserProfile { try UserProfile(json: await read(APIRequest("/api/profile"))) }
    public func currentSemesterCourses() async throws -> [Course] {
        let semester = try await read(APIRequest("/api/current-semester-info"))
        guard let semesterID = semester["semester"]["id"].string, !semesterID.isEmpty,
              let yearID = semester["academic_year"]["id"].string, !yearID.isEmpty else {
            throw RollcallError.message("未能获取当前学期，请稍后重试")
        }
        // Match rollcall_service.get_courses, using fresh semester IDs on each refresh.
        let conditions: JSONValue = .object([
            "semester_id": .array([.string(semesterID)]),
            "academic_year_id": .array([.string(yearID)]),
            "keyword": .string(""), "classify_type": .string("recently_started"),
            "display_studio_list": .bool(false)
        ])
        var courses = PageAccumulator<Course>()
        repeat {
            try Task.checkCancellation()
            let page = courses.nextPage
            let body: JSONValue = .object([
                "conditions": conditions, "fields": .string("id,name,display_name"),
                "page": .number(Double(page)), "page_size": .number(30), "showScorePassedStatus": .bool(false)
            ])
            let response = try await read(APIRequest("/api/my-courses", method: "POST", body: body))
            courses.append(try PageParser.parse(response, key: "courses", page: page, size: 30, transform: Course.init(json:)))
        } while courses.hasMore
        return courses.items
    }
    public func history(courseID: String, studentID: String, page: Int, size: Int = 99) async throws -> DataPage<Attendance> {
        try validateID(courseID); try validateID(studentID)
        let path = "/api/course/\(courseID)/student/\(studentID)/rollcalls?page=\(page)&page_size=\(size)"
        return try PageParser.parse(await read(APIRequest(path)), key: "rollcalls", page: page, size: size,
                                    transform: Attendance.init(json:))
    }
    public func active() async throws -> [Attendance] {
        let json = try await read(APIRequest("/api/radar/rollcalls"))
        guard let rows = json["rollcalls"].array ?? json.array else { throw RollcallError.malformedResponse }
        return try rows.map(Attendance.init(json:))
    }
    public func detail(id: String, studentID: String) async throws -> Attendance {
        try validateID(id)
        let json = try await read(APIRequest("/api/rollcall/\(id)/student_rollcalls"))
        guard var fields = json.object else { throw RollcallError.malformedResponse }
        fields["rollcall_id"] = .string(id)
        var record = try Attendance(json: .object(fields))
        // This endpoint includes the whole class: only inspect the current student's row.
        if let own = json["student_rollcalls"].array?.first(where: { $0["student_id"].string == studentID }) {
            record.personalStatus = own["status"].string
        }
        return record
    }
    public func submitNumber(id: String, code: String, studentID: String) async throws -> Attendance {
        try validateID(id)
        let response = try await transport.send(APIRequest("/api/rollcall/\(id)/answer_number_rollcall", method: "PUT", body: .object([
            "deviceId": .string(UUID().uuidString.lowercased()), "numberCode": .string(code)
        ])))
        if response.status == 401 || response.status == 403 { throw RollcallError.expiredSession }
        if response.status >= 500 { throw RollcallError.uncertain("学校服务响应异常，签到结果待确认") }
        guard response.status == 200 else { throw RollcallError.message("签到未通过（\(response.status)），请刷新后重试") }
        if let json = try? response.json(), json["success"].bool == false {
            throw RollcallError.message("学校未接受本次签到，请刷新后重试")
        }
        do {
            let record = try await detail(id: id, studentID: studentID)
            guard record.isAnswered else { throw RollcallError.uncertain("已提交，尚未确认本人签到状态，请稍后核对") }
            return record
        } catch { throw RollcallError.uncertain("已提交，结果待确认，请稍后核对签到状态") }
    }
    public func submitRadar(id: String) async throws -> Bool {
        try validateID(id)
        return try await RadarSubmission.run(transport: transport, id: id)
    }
    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw RollcallError.malformedResponse }
    }
}

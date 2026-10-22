#if DEBUG
import Foundation
import RollcallCore

// Explicit debug launch argument only. Every request stays in memory.
@MainActor extension AppState {
    func installFixture() throws {
        let first = try store.saveAccount(id: nil, username: "demo001", password: "example-only", note: "常用账号")
        _ = try store.saveAccount(id: nil, username: "demo002", password: "example-only", note: "备用账号")
        let course = Course(id: "101", name: "软件工程与实践")
        let record = try Attendance(json: JSONValue.decode(Data(#"{"rollcall_id":701,"course_id":101,"rollcall_time":"2026-10-08T00:03:17Z","is_number":true,"number_code":"0123"}"#.utf8)))
        let log = try store.begin(account: first, studentID: "90001", course: course, record: record)
        try store.update(log, result: .success, message: "签到成功")
        let radar = try Attendance(json: JSONValue.decode(Data(#"{"rollcall_id":702,"course_id":102,"rollcall_time":"2026-10-08T00:03:17Z","is_radar":true}"#.utf8)))
        let other = try store.begin(account: first, studentID: "90001", course: Course(id: "102", name: "大学英语综合教程"), record: radar)
        try store.update(other, result: .uncertain, message: "提交连接中断，结果待确认，请先核对签到状态")
        authentication = { id, username, _, _ in
            let studentID = username == "demo001" ? "90001" : "90002"
            let profile = try UserProfile(json: .object(["id": .string(studentID), "user_no": .string(username), "name": .string("演示用户")]))
            return AuthenticatedSession(accountID: id, generation: UUID(), profile: profile,
                                        client: TronclassClient(transport: FixtureTransport(studentID: studentID)))
        }
    }
}

private actor FixtureTransport: HTTPTransport {
    let studentID: String
    var answered: Set<String> = []
    init(studentID: String) { self.studentID = studentID }
    func send(_ request: APIRequest) async throws -> APIResponse {
        let body: JSONValue
        if request.method == "PUT" {
            let parts = request.path.split(separator: "/")
            if parts.count >= 3 { answered.insert(String(parts[2])) }
            body = .object([:])
        } else if request.path == "/api/current-semester-info" {
            body = .object(["semester": .object(["id": .number(7)]), "academic_year": .object(["id": .number(2026)])])
        } else if request.path == "/api/my-courses" {
            body = .object(["courses": .array([
                .object(["id": .string("101"), "name": .string("软件工程与实践")]),
                .object(["id": .string("102"), "name": .string("大学英语综合教程")]),
                .object(["id": .string("103"), "name": .string("人工智能基础与应用：跨学科研究方法")])
            ]), "pages": .number(1), "total": .number(3)])
        } else if request.path == "/api/radar/rollcalls" { body = .object(["rollcalls": .array([])]) }
        else if request.path.contains("/student/") {
            let courseID = String(request.path.split(separator: "/")[2])
            body = .object(["rollcalls": .array([
                record("701", courseID: courseID, radar: false, active: true, includeCode: false),
                record("702", courseID: courseID, radar: true, active: true),
                record("703", courseID: courseID, radar: false, active: false, includeCode: false),
                record("704", courseID: courseID, radar: false, active: false, includeCode: false)
            ]), "pages": .number(1)])
        } else if request.path.hasPrefix("/api/timetable_rollcalls?") {
            let query = URLComponents(string: request.path)?.queryItems ?? []
            guard let courseID = query.first(where: { $0.name == "course_ids" })?.value,
                  query.first(where: { $0.name == "rollcall_date" })?.value == "2026-10-08" else {
                throw RollcallError.message("演示查询缺少正确的课程或签到日期")
            }
            body = .object(["rollcalls": .array(["701", "702", "703", "704"].map { id in
                let active = id == "701" || id == "702"
                var fields = record(id, courseID: courseID, radar: id == "702", active: active).object!
                fields.removeValue(forKey: "rollcall_id")
                fields["id"] = .string(id)
                fields["course"] = .object(["id": .string(courseID), "name": .string("软件工程与实践")])
                fields["status"] = .string(active ? "active" : "finished")
                fields["student_rollcalls"] = .array(studentRollcalls(for: id))
                return .object(fields)
            })])
        } else { throw RollcallError.message("演示数据未提供此操作") }
        return APIResponse(status: 200, data: try body.encoded())
    }
    private func studentRollcalls(for id: String) -> [JSONValue] {
        let otherStatuses: [String]
        switch id {
        case "701": otherStatuses = ["on_call_fine", "on_call_late", "absent"]
        case "703": otherStatuses = ["on_call", "on_call_fine", "on_call_late"]
        default: otherStatuses = ["on_call", "absent", "absent"]
        }
        let own: JSONValue = .object([
            "student_id": .string(studentID),
            "status": .string(answered.contains(id) || id == "703" ? "on_call" : "absent")
        ])
        return [own] + otherStatuses.enumerated().map { index, status in
            .object(["student_id": .string("9100\(index + 1)"), "status": .string(status)])
        }
    }
    private func record(_ id: String, courseID: String, radar: Bool, active: Bool, includeCode: Bool = true) -> JSONValue {
        .object(["rollcall_id": .string(id), "course_id": .string(courseID), "is_number": .bool(!radar), "is_radar": .bool(radar),
                 "is_expired": .bool(!active), "rollcall_status": .string(active ? "active" : "finished"),
                 "status": .string(answered.contains(id) || id == "703" ? "on_call_fine" : "absent"),
                 "number_code": radar || !includeCode ? .null : .string("0123"), "rollcall_time": .string("2026-10-08T00:03:17Z")])
    }
}
#endif

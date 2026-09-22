import XCTest
@testable import RollcallCore

actor StubTransport: HTTPTransport {
    private var replies: [APIResponse]
    private(set) var requests: [APIRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies.map { APIResponse(status: $0.0, data: Data($0.1.utf8)) } }
    func send(_ request: APIRequest) async throws -> APIResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RollcallError.message("Unexpected request") }
        return replies.removeFirst()
    }
}

final class RollcallCoreTests: XCTestCase {
    private func json(_ value: String) throws -> JSONValue { try JSONValue.decode(Data(value.utf8)) }
    func testProfileIdentityIncludesKnownIDAndEmailAlias() throws {
        let p = try UserProfile(json: json(#"{"id":123,"user_no":"00123","email":"alias@example.test","name":"Test"}"#))
        XCTAssertEqual(p.id, "123"); XCTAssertEqual(p.account, "00123")
        XCTAssertTrue(p.matches("ALIAS@example.test", knownID: nil))
        XCTAssertFalse(p.matches("other", knownID: nil))
        XCTAssertTrue(p.matches("alias", knownID: "123"))
        XCTAssertFalse(p.matches("00123", knownID: "456"))
    }
    func testHistoryFinishedOverridesFalseExpiredAndPreservesOwnStatus() throws {
        let record = try Attendance(json: json(#"{"rollcall_id":1,"is_expired":false,"rollcall_status":"finished","is_number":true,"is_radar":false,"status":"on_call_fine","rollcall_time":"2026-09-01T08:00:00Z"}"#))
        XCTAssertFalse(record.isActive); XCTAssertFalse(record.canSubmit); XCTAssertTrue(record.isAnswered)
        XCTAssertEqual(record.kind, .number); XCTAssertNotNil(record.date)
    }
    func testRadarWinsWhenBothFlagsAreTrueAndUnknownIsNotSubmittable() throws {
        let radar = try Attendance(json: json(#"{"rollcall_id":1,"is_expired":false,"is_number":true,"is_radar":true,"status":"absent"}"#))
        XCTAssertEqual(radar.kind, .radar); XCTAssertTrue(radar.canSubmit)
        let unknown = try Attendance(json: json(#"{"rollcall_id":2}"#))
        XCTAssertFalse(unknown.canSubmit); XCTAssertEqual(unknown.stateText, "状态待确认")
    }
    func testPastEndTimeIsDisplayedAsEndedEvenIfActivityFlagIsStale() throws {
        let record = try Attendance(json: json(#"{"rollcall_id":1,"status":"active","is_expired":false,"is_number":true,"end_time":"2000-01-01T00:00:00Z"}"#))
        XCTAssertTrue(record.hasEnded); XCTAssertFalse(record.canSubmit)
        XCTAssertEqual(record.stateText, "已结束")
    }
    func testOnlyExplicitAbsenceAfterEndingGetsAbsentLabel() throws {
        var record = try Attendance(json: json(#"{"rollcall_id":1,"is_number":true,"rollcall_status":"finished"}"#))
        for status: String? in [nil, "", "unrecognized", "on_call_fine", "on_call_late", "present", "attended", "late"] {
            record.personalStatus = status
            XCTAssertFalse(record.isAbsent, "\(status ?? "missing") must not be treated as absent")
            if ["on_call_late", "late"].contains(status ?? "") { XCTAssertEqual(record.stateText, "已签到 · 迟到") }
            else if ["on_call_fine", "present", "attended"].contains(status ?? "") { XCTAssertEqual(record.stateText, "已签到") }
            else { XCTAssertEqual(record.stateText, "已结束") }
        }
        record.personalStatus = "absent"
        XCTAssertTrue(record.isAbsent); XCTAssertEqual(record.stateText, "缺勤")
        record.activityStatus = "active"
        XCTAssertFalse(record.isAbsent); XCTAssertEqual(record.stateText, "正在签到")
        record.personalStatus = "on_call_fine"
        XCTAssertFalse(record.isAbsent); XCTAssertEqual(record.stateText, "已签到")
        record.personalStatus = "on_call_late"
        XCTAssertFalse(record.isAbsent); XCTAssertEqual(record.stateText, "已签到 · 迟到")
    }
    func testCoursePaginationAndRepeatedPageStop() throws {
        let value = try json(#"{"courses":[{"id":1,"display_name":"A"},{"id":2,"name":"B"},{"id":2,"name":"B"}],"pages":2,"total":4}"#)
        let first = try PageParser.parse(value, key: "courses", page: 1, size: 2, transform: Course.init(json:))
        var pages = PageAccumulator<Course>(); pages.append(first)
        XCTAssertEqual(pages.items.count, 2); XCTAssertTrue(pages.hasMore); XCTAssertEqual(pages.nextPage, 2)
        let second = try PageParser.parse(value, key: "courses", page: 2, size: 2, transform: Course.init(json:))
        pages.append(second)
        XCTAssertFalse(pages.hasMore); XCTAssertEqual(pages.items.count, 2); XCTAssertTrue(pages.note.contains("重复"))
    }
    func testCoursesUseCurrentSemesterFiltersOnEveryPage() async throws {
        let transport = StubTransport([
            (200, #"{"semester":{"id":7},"academic_year":{"id":2026}}"#),
            (200, #"{"courses":[{"id":1,"name":"A"},{"id":2,"name":"B"}],"pages":2}"#),
            (200, #"{"courses":[{"id":2,"name":"B"},{"id":3,"name":"C"}],"pages":2}"#)
        ])
        let courses = try await TronclassClient(transport: transport).currentSemesterCourses()
        XCTAssertEqual(courses.map(\.id), ["1", "2", "3"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), ["/api/current-semester-info", "/api/my-courses", "/api/my-courses"])
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST"])
        let expected: JSONValue = .object([
            "semester_id": .array([.string("7")]), "academic_year_id": .array([.string("2026")]),
            "keyword": .string(""), "classify_type": .string("recently_started"), "display_studio_list": .bool(false)
        ])
        for (index, request) in requests.dropFirst().enumerated() {
            XCTAssertEqual(request.body?["conditions"], expected)
            XCTAssertEqual(request.body?["page"], .number(Double(index + 1)))
            XCTAssertEqual(request.body?["page_size"], .number(30))
        }
    }
    func testSemesterFailureNeverFallsBackToUnfilteredCourses() async throws {
        for reply in [(500, "{}"), (200, #"{"semester":null,"academic_year":{"id":2026}}"#)] {
            let transport = StubTransport([reply])
            do { _ = try await TronclassClient(transport: transport).currentSemesterCourses(); XCTFail("must stop without semester") }
            catch { /* No fixed semester or unfiltered course fallback. */ }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].path, "/api/current-semester-info")
        }
    }
    func testRefreshingCoursesFetchesTheNewSemesterAgain() async throws {
        let transport = StubTransport([
            (200, #"{"semester":{"id":"7"},"academic_year":{"id":"2026"}}"#),
            (200, #"{"courses":[],"pages":1}"#),
            (200, #"{"semester":{"id":"8"},"academic_year":{"id":"2027"}}"#),
            (200, #"{"courses":[],"pages":1}"#)
        ])
        let client = TronclassClient(transport: transport)
        _ = try await client.currentSemesterCourses()
        _ = try await client.currentSemesterCourses()
        let requests = await transport.requests
        XCTAssertEqual(requests[1].body?["conditions"]["semester_id"], .array([.string("7")]))
        XCTAssertEqual(requests[3].body?["conditions"]["semester_id"], .array([.string("8")]))
        XCTAssertEqual(requests[3].body?["conditions"]["academic_year_id"], .array([.string("2027")]))
    }
    func testHistoryDoesNotClaimAllWhenPaginationUnknown() throws {
        let value = try json(#"{"rollcalls":[{"rollcall_id":7}]}"#)
        var pages = PageAccumulator<Attendance>()
        pages.append(try PageParser.parse(value, key: "rollcalls", page: 1, size: 99, transform: Attendance.init(json:)))
        XCTAssertTrue(pages.hasMore)
        pages.append(try PageParser.parse(value, key: "rollcalls", page: 2, size: 99, transform: Attendance.init(json:)))
        XCTAssertFalse(pages.hasMore); XCTAssertNotEqual(pages.note, "已全部加载")
    }
    func testMoreThanNinetyNineHistoryRowsWithServerPageSizeCap() throws {
        var pages = PageAccumulator<Attendance>()
        for page in 1...4 {
            let lower = (page - 1) * 30
            let rows: [JSONValue] = (lower..<min(lower + 30, 105)).map { .object(["rollcall_id": .number(Double($0))]) }
            pages.append(try PageParser.parse(.object(["rollcalls": .array(rows)]), key: "rollcalls", page: page, size: 99, transform: Attendance.init(json:)))
            XCTAssertTrue(pages.hasMore)
        }
        XCTAssertEqual(pages.items.count, 105)
        pages.append(try PageParser.parse(.object(["rollcalls": .array([])]), key: "rollcalls", page: 5, size: 99, transform: Attendance.init(json:)))
        XCTAssertFalse(pages.hasMore); XCTAssertEqual(pages.items.count, 105)
        XCTAssertNotEqual(pages.note, "已全部加载")
    }
    func testDetailReadsOnlySelectedStudentAndKeepsLeadingZeroCode() async throws {
        let transport = StubTransport([(200, #"{"status":"active","is_number":true,"number_code":"0012","student_rollcalls":[{"student_id":8,"status":"on_call_fine"},{"student_id":9,"status":"absent"}]}"#)])
        let record = try await TronclassClient(transport: transport).detail(id: "7", studentID: "9")
        XCTAssertEqual(record.numberCode, "0012"); XCTAssertFalse(record.isAnswered); XCTAssertTrue(record.canSubmit)
    }
    func testNumericSubmissionRequiresOwnVerifiedSuccess() async throws {
        let transport = StubTransport([(200, "{}"), (200, #"{"status":"active","student_rollcalls":[{"student_id":9,"status":"on_call_fine"}]}"#)])
        let result = try await TronclassClient(transport: transport).submitNumber(id: "7", code: "0012", studentID: "9")
        XCTAssertTrue(result.isAnswered)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "GET"])
        XCTAssertEqual(requests[0].body?["numberCode"].string, "0012")
        XCTAssertNotNil(UUID(uuidString: requests[0].body?["deviceId"].string ?? ""))
    }
    func testUnconfirmedNumericWriteIsNotRetried() async throws {
        let transport = StubTransport([(200, "{}"), (200, #"{"student_rollcalls":[{"student_id":8,"status":"on_call_fine"},{"student_id":9,"status":"absent"}]}"#)])
        do {
            _ = try await TronclassClient(transport: transport).submitNumber(id: "7", code: "0000", studentID: "9")
            XCTFail("must remain uncertain")
        } catch RollcallError.uncertain {} catch { XCTFail("unexpected \(error)") }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.method == "PUT" }.count, 1)
    }
    func testExpiredSessionAndHTMLLoginAreRecognized() async throws {
        for reply in [(302, ""), (401, "{}"), (200, "<!DOCTYPE html><html>Login</html>")] {
            let client = TronclassClient(transport: StubTransport([reply]))
            do { _ = try await client.profile(); XCTFail("must reject") }
            catch { XCTAssertEqual(error as? RollcallError, .expiredSession) }
        }
    }
    func testRadarMathMatchesUnmodifiedPythonReference() throws {
        // Generated by executing only the four pure math functions from verify.py at c7de02b.
        let cases: [(Double, Double, [Coordinate])] = [
            (25000, 22000, [Coordinate(24.524828396473676, 117.99895695280263), Coordinate(24.402952407177416, 118.21956358296477)]),
            (35000, 25000, [Coordinate(24.61188675779247, 117.95336665988438), Coordinate(24.406329427956848, 118.32544413061515)]),
            (20000, 20000, [Coordinate(24.470519762573105, 118.06285736264282), Coordinate(24.429480237426898, 118.13714263735719)])
        ]
        for (d1, d2, expected) in cases {
            let actual = try XCTUnwrap(RadarSubmission.solve(distance1: d1, distance2: d2))
            for i in 0..<2 {
                XCTAssertEqual(actual[i].latitude, expected[i].latitude, accuracy: 1e-11)
                XCTAssertEqual(actual[i].longitude, expected[i].longitude, accuracy: 1e-11)
            }
        }
        XCTAssertNil(RadarSubmission.solve(distance1: 1, distance2: 1))
        XCTAssertNil(RadarSubmission.solve(distance1: .nan, distance2: 1))
    }
    func testRadarTriesBothProbesThenCandidatesInReferenceOrder() async throws {
        let transport = StubTransport([(400, #"{"distance":25000}"#), (400, #"{"distance":22000}"#), (400, "{}"), (200, "")])
        let success = try await RadarSubmission.run(transport: transport, id: "7")
        XCTAssertTrue(success)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        let expected = [RadarSubmission.first, RadarSubmission.second] + (RadarSubmission.solve(distance1: 25000, distance2: 22000) ?? [])
        var identifiers: Set<String> = []
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.path, "/api/rollcall/7/answer"); XCTAssertEqual(request.method, "PUT"); XCTAssertTrue(request.radarHeaders)
            let body = try XCTUnwrap(request.body)
            XCTAssertEqual(Set(body.object?.keys.map { $0 } ?? []), Set(["accuracy", "altitude", "altitudeAccuracy", "deviceId", "heading", "latitude", "longitude", "speed"]))
            XCTAssertEqual(body["accuracy"], .number(35)); XCTAssertEqual(body["altitude"], .number(0))
            for key in ["altitudeAccuracy", "heading", "speed"] { XCTAssertEqual(body[key], .null) }
            XCTAssertEqual(body["latitude"].double, expected[index].latitude)
            XCTAssertEqual(body["longitude"].double, expected[index].longitude)
            let id = try XCTUnwrap(body["deviceId"].string); XCTAssertNotNil(UUID(uuidString: id)); identifiers.insert(id)
        }
        XCTAssertEqual(identifiers.count, 4)
    }
    func testRadarStopsAfterFirstOrSecondOrThirdSuccess() async throws {
        let replies: [[(Int, String)]] = [[(200, "{}")], [(400, "{}"), (200, "{}")],
            [(400, #"{"distance":25000}"#), (400, #"{"distance":22000}"#), (200, "")]]
        for items in replies {
            let transport = StubTransport(items)
            let success = try await RadarSubmission.run(transport: transport, id: "7")
            XCTAssertTrue(success)
            let requests = await transport.requests; XCTAssertEqual(requests.count, items.count)
        }
    }
    func testRadarReturnsFailureAfterFourFailuresAndKeepsJSONBranchOrder() async throws {
        let transport = StubTransport([(400, #"{"distance":25000}"#), (400, #"{"distance":22000}"#), (400, "{}"), (400, "")])
        let success = try await RadarSubmission.run(transport: transport, id: "7"); XCTAssertFalse(success)
        let broken = StubTransport([(200, "")])
        do { _ = try await RadarSubmission.run(transport: broken, id: "7"); XCTFail("reference decodes before first success check") }
        catch { XCTAssertEqual(error as? RollcallError, .malformedResponse) }
        let requests = await broken.requests; XCTAssertEqual(requests.count, 1)
    }
}

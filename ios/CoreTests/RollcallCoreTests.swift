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
    private func counts(_ students: String) throws -> AttendanceCounts? {
        AttendanceCounts(json: try json("{\"student_rollcalls\":\(students)}"))
    }
    func testAttendanceCountsIncludeOnlyKnownSignedStatusesAndLateAttendance() throws {
        let statuses = ["on_call", "on_call_fine", "on_call_late", "present", "attended", "late",
                        "absent", "leave", "unrecognized", "not_on_call", "on_call_failed"]
        let students: [JSONValue] = statuses.enumerated().map {
            .object(["student_id": .number(Double($0.offset)), "status": .string($0.element)])
        }
        let result = try XCTUnwrap(AttendanceCounts(json: .object(["student_rollcalls": .array(students)])))
        XCTAssertEqual(result.signedIn, 6); XCTAssertEqual(result.total, 11)
    }
    func testAttendanceCountsDeduplicateStudentsAndDoNotGuessConflictingStatuses() throws {
        let students = [
            #"{"student_id":123,"id":1,"status":"on_call"}"#,
            #"{"student_id":"123","id":2,"status":"on_call"}"#,
            #"{"student_id":2,"status":"on_call"}"#, #"{"student_id":2,"status":"absent"}"#,
            #"{"student_id":3,"status":"present"}"#, #"{"student_id":3,"status":"late"}"#
        ]
        for rows in [students, Array(students.reversed())] {
            let result = try XCTUnwrap(counts("[\(rows.joined(separator: ","))]"))
            XCTAssertEqual(result.signedIn, 1); XCTAssertEqual(result.total, 3)
        }
    }
    func testAttendanceCountsFallBackToRecordIDsThenIndividualRows() throws {
        let result = try XCTUnwrap(counts(#"""
        [
            {"id":12,"status":"absent"},{"id":"12","status":"absent"},
            {"status":"on_call"},{"status":"on_call"},{"student_id":12,"status":"late"},
            {"student_id":true,"id":77,"status":"present"},{"student_id":" ","id":"77","status":"present"}
        ]
        """#))
        XCTAssertEqual(result.signedIn, 4); XCTAssertEqual(result.total, 5)
    }
    func testAttendanceCountsNormalizeStatusAndOnlyFallBackWhenPrimaryStatusIsMissingOrNull() throws {
        let result = try XCTUnwrap(counts(#"""
        [
            {"student_id":1,"status":" ON_CALL "},{"student_id":2,"rollcall_status":"LaTe"},
            {"student_id":3,"status":null,"rollcall_status":"present"},
            {"student_id":4,"status":"","rollcall_status":"on_call"},
            {"student_id":5,"status":123,"rollcall_status":"on_call"},
            {"student_id":6,"status":true},{"student_id":7}
        ]
        """#))
        XCTAssertEqual(result.signedIn, 3); XCTAssertEqual(result.total, 7)
        let duplicate = try XCTUnwrap(counts(#"[{"student_id":1,"status":" ON_CALL "},{"student_id":"1","status":"on_call"}]"#))
        XCTAssertEqual(duplicate.signedIn, 1); XCTAssertEqual(duplicate.total, 1)
    }
    func testAttendanceCountsDistinguishMissingOrMalformedRostersFromAnEmptyClass() throws {
        for response in ["null", "[]", "{}", #"{"student_rollcalls":null}"#,
                         #"{"student_rollcalls":{}}"#, #"{"student_rollcalls":"[]"}"#,
                         #"{"student_rollcalls":[null]}"#, #"{"student_rollcalls":[1]}"#,
                         #"{"student_rollcalls":[{},false]}"#] {
            XCTAssertNil(AttendanceCounts(json: try json(response)), response)
        }
        let empty = try XCTUnwrap(counts("[]"))
        XCTAssertEqual(empty.signedIn, 0); XCTAssertEqual(empty.total, 0)
        let unknown = try XCTUnwrap(counts(#"[{"student_id":1},{"student_id":2,"status":"unknown"}]"#))
        XCTAssertEqual(unknown.signedIn, 0); XCTAssertEqual(unknown.total, 2)
    }
    func testAttendanceMergeRetainsCountsWhenMissingAndAcceptsAnExplicitEmptyClass() throws {
        var record = try Attendance(json: json(#"{"rollcall_id":1,"status":"on_call_late","student_rollcalls":[{"student_id":1,"status":"late"},{"student_id":2,"status":"absent"}]}"#))
        let original = try XCTUnwrap(record.attendanceCounts)
        XCTAssertEqual(original.signedIn, 1); XCTAssertEqual(original.total, 2)
        record.merge(try Attendance(json: json(#"{"rollcall_id":1}"#)))
        XCTAssertEqual(record.attendanceCounts, original)
        record.merge(try Attendance(json: json(#"{"rollcall_id":2,"student_rollcalls":[]}"#)))
        XCTAssertEqual(record.attendanceCounts, original)
        record.merge(try Attendance(json: json(#"{"rollcall_id":1,"student_rollcalls":[]}"#)))
        let empty = try XCTUnwrap(record.attendanceCounts)
        XCTAssertEqual(empty.signedIn, 0); XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(record.personalStatus, "on_call_late")
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
    private var attendanceDate: Date { Attendance.parseDate("2026-10-08T00:03:17Z")! }
    private func timetableReply(_ rows: String) -> String { "{\"rollcalls\":\(rows)}" }
    func testTimetableUsesShanghaiDateAcrossUTCMidnightAndKeepsLeadingZeroCode() async throws {
        let transport = StubTransport([(200, timetableReply(#"[{"id":7,"course":{"id":11},"status":"active","is_number":true,"number_code":"0012","student_rollcalls":[{"student_id":8,"status":"on_call"},{"student_id":9,"status":"absent"}]}]"#))])
        let date = try XCTUnwrap(Attendance.parseDate("2026-10-07T16:03:17Z"))
        let record = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: date, studentID: "9")
        XCTAssertEqual(record.numberCode, "0012"); XCTAssertFalse(record.isAnswered); XCTAssertTrue(record.canSubmit)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.path), ["/api/timetable_rollcalls?course_ids=11&rollcall_date=2026-10-08"])
        XCTAssertEqual(requests.map(\.method), ["GET"])
    }
    func testDetailMatchesBothCourseAndRollcallInsteadOfFirstRow() async throws {
        let transport = StubTransport([(200, timetableReply(#"[{"id":7,"course":{"id":12},"number_code":"9999"},{"id":8,"course":{"id":11},"number_code":"2222"},{"id":7,"course":{"id":11},"number_code":"0012","status":"finished","student_rollcalls":[{"student_id":9,"status":"on_call"}]}]"#))])
        let record = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: "9")
        XCTAssertEqual(record.id, "7"); XCTAssertEqual(record.courseID, "11"); XCTAssertEqual(record.numberCode, "0012")
        XCTAssertTrue(record.isAnswered); XCTAssertEqual(record.stateText, "已签到")
    }
    func testTimetableUsesRequestedCourseWhenResponseOmitsCourse() async throws {
        let transport = StubTransport([(200, timetableReply(#"[{"id":7,"number_code":"0012","status":"finished"},{"id":8,"course_id":11,"number_code":"2345"}]"#))])
        let rows = try await TronclassClient(transport: transport).timetable(courseID: "11", date: attendanceDate, studentID: "9")
        XCTAssertEqual(rows.map(\.id), ["7", "8"]); XCTAssertEqual(rows.map(\.courseID), ["11", "11"])
        XCTAssertNil(rows[0].personalStatus); XCTAssertFalse(rows[0].isAbsent)
    }
    func testMissingTargetNeverFallsBackToAnotherRollcallOrOldEndpoint() async throws {
        let replies = [#"[]"#, #"[{"id":8,"course":{"id":11},"number_code":"2222"}]"#,
                       #"[{"id":7,"course":{"id":12},"number_code":"9999"}]"#,
                       #"[{"id":7,"course":{"id":11},"course_id":12,"number_code":"9999"}]"#]
        for rows in replies {
            let transport = StubTransport([(200, timetableReply(rows))])
            do {
                _ = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: "9")
                XCTFail("A missing target must be reported")
            } catch RollcallError.message(let message) { XCTAssertTrue(message.contains("未找到")) }
            catch { XCTFail("Unexpected error: \(error)") }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1); XCTAssertTrue(requests[0].path.hasPrefix("/api/timetable_rollcalls?"))
        }
    }
    func testTimetableRejectsMalformedContainersAndConflictingIdentifiers() async throws {
        let responses = ["{}", "[]", #"{"data":{"rollcalls":[]}}"#, #"{"rollcalls":null}"#,
                         timetableReply(#"[{"id":"7/8"}]"#), timetableReply(#"[{"id":7,"rollcall_id":8}]"#),
                         timetableReply(#"[{"id":false,"rollcall_id":7}]"#), timetableReply(#"[{"id":7,"course":{"id":false}}]"#),
                         timetableReply(#"[{"id":7},{"id":7}]"#), timetableReply(#"[{"id":7,"student_rollcalls":{}}]"#)]
        for response in responses {
            let transport = StubTransport([(200, response)])
            do {
                _ = try await TronclassClient(transport: transport).timetable(courseID: "11", date: attendanceDate, studentID: "9")
                XCTFail("Malformed timetable accepted: \(response)")
            } catch { XCTAssertEqual(error as? RollcallError, .malformedResponse) }
        }
    }
    func testTimetableOnlyOwnKnownStatusCanConfirmAttendance() async throws {
        let cases: [(String, String?)] = [
            (#"[{"student_id":8,"status":"on_call"}]"#, nil),
            (#"[{"student_id":9,"status":"on_call"}]"#, "on_call"),
            (#"[{"student_id":9,"status":"active"}]"#, nil),
            (#"[{"student_id":9,"status":"finished"}]"#, nil),
            (#"[{"student_id":9,"status":"new_server_value"}]"#, nil),
            (#"[{"student_id":9,"rollcall_status":"on_call_fine"}]"#, "on_call_fine"),
            (#"[{"student_id":9,"status":"absent","rollcall_status":"on_call_fine"}]"#, "absent"),
            (#"[{"student_id":9,"status":"","rollcall_status":"on_call"}]"#, "on_call"),
            (#"[{"student_id":9,"status":"on_call"},{"student_id":9,"status":"on_call"}]"#, "on_call"),
            (#"[{"student_id":9,"status":"on_call"},{"student_id":9,"status":"absent"}]"#, nil),
            (#"[{"student_id":9,"status":"on_call"},{"student_id":9}]"#, nil)
        ]
        for (students, expected) in cases {
            let response = "{\"rollcalls\":[{\"id\":7,\"status\":\"finished\",\"student_rollcalls\":\(students)}]}"
            let transport = StubTransport([(200, response)])
            let record = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: "9")
            XCTAssertEqual(record.personalStatus, expected, students)
            XCTAssertEqual(record.isAnswered, expected == "on_call" || expected == "on_call_fine", students)
        }
    }
    func testTimetableClassCountsRemainIndependentOfTheCurrentStudentsStatus() async throws {
        let response = timetableReply(#"[{"id":7,"status":"active","is_number":true,"student_rollcalls":[{"student_id":8,"status":"on_call"},{"student_id":9,"status":"absent"},{"student_id":10,"status":"on_call_late"}]}]"#)
        for studentID in ["9", "99"] {
            let transport = StubTransport([(200, response)])
            let record = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: studentID)
            let counts = try XCTUnwrap(record.attendanceCounts)
            XCTAssertEqual(counts.signedIn, 2); XCTAssertEqual(counts.total, 3)
            XCTAssertEqual(record.personalStatus, studentID == "9" ? "absent" : nil)
            XCTAssertFalse(record.isAnswered); XCTAssertTrue(record.canSubmit)
        }
    }
    func testTimetableAggregateParsingPreservesExistingPersonalStatusFallback() async throws {
        let transport = StubTransport([(200, timetableReply(#"[{"id":7,"status":"active","student_rollcalls":[{"student_id":9,"status":"","rollcall_status":"on_call"}]}]"#))])
        let record = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: "9")
        XCTAssertEqual(record.personalStatus, "on_call"); XCTAssertTrue(record.isAnswered)
        let counts = try XCTUnwrap(record.attendanceCounts)
        XCTAssertEqual(counts.signedIn, 0); XCTAssertEqual(counts.total, 1)
    }
    func testDetailWithoutOwnStatusPreservesSignedHistoryWhenMerged() async throws {
        for status in ["on_call", "on_call_fine", "on_call_late"] {
            var history = try Attendance(json: json("{\"rollcall_id\":7,\"status\":\"\(status)\",\"rollcall_status\":\"finished\"}"))
            let transport = StubTransport([(200, timetableReply(#"[{"id":7,"status":"finished","number_code":"0012","student_rollcalls":[{"student_id":8,"status":"absent"}]}]"#))])
            let detail = try await TronclassClient(transport: transport).detail(id: "7", courseID: "11", date: attendanceDate, studentID: "9")
            history.merge(detail)
            XCTAssertTrue(history.isAnswered); XCTAssertEqual(history.personalStatus, status)
            XCTAssertEqual(history.numberCode, "0012")
            XCTAssertEqual(history.stateText, status == "on_call_late" ? "已签到 · 迟到" : "已签到")
        }
    }
    func testMergeIgnoresUnrecognizedPersonalStateButAllowsExplicitCorrection() throws {
        for status: String? in [nil, "", "active", "finished", "new_server_value"] {
            var history = try Attendance(json: json(#"{"rollcall_id":7,"status":"on_call_fine","rollcall_status":"finished"}"#))
            var detail = try Attendance(json: json(#"{"id":7,"status":"finished"}"#))
            detail.personalStatus = status
            history.merge(detail)
            XCTAssertEqual(history.stateText, "已签到")
        }
        var history = try Attendance(json: json(#"{"rollcall_id":7,"status":"on_call_fine","rollcall_status":"finished"}"#))
        history.merge(try Attendance(json: json(#"{"id":7,"status":"absent","rollcall_status":"finished"}"#)))
        XCTAssertEqual(history.stateText, "缺勤")
    }
    func testGenericAttendanceDoesNotEraseKnownLateness() throws {
        for status in ["on_call", "present", "attended"] {
            var history = try Attendance(json: json(#"{"rollcall_id":7,"status":"on_call_late","rollcall_status":"finished"}"#))
            history.merge(try Attendance(json: json("{\"id\":7,\"status\":\"\(status)\"}")))
            XCTAssertEqual(history.stateText, "已签到 · 迟到")
            history.merge(try Attendance(json: json(#"{"id":7,"status":"on_call_fine"}"#)))
            XCTAssertEqual(history.stateText, "已签到")
        }
    }
    func testNumericSubmissionRequiresOwnVerifiedSuccessUsingNewEndpoint() async throws {
        let transport = StubTransport([(200, "{}"), (200, timetableReply(#"[{"id":7,"course":{"id":11},"status":"active","student_rollcalls":[{"student_id":9,"status":"on_call"}]}]"#))])
        let result = try await TronclassClient(transport: transport).submitNumber(id: "7", code: "0012", courseID: "11", date: attendanceDate, studentID: "9")
        XCTAssertTrue(result.isAnswered)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/api/rollcall/7/answer_number_rollcall", "/api/timetable_rollcalls?course_ids=11&rollcall_date=2026-10-08"])
        XCTAssertEqual(requests[0].body?["numberCode"].string, "0012")
        XCTAssertNotNil(UUID(uuidString: requests[0].body?["deviceId"].string ?? ""))
    }
    func testUnconfirmedNumericWriteIsNotRetried() async throws {
        for rows in [#"[{"id":7,"student_rollcalls":[{"student_id":8,"status":"on_call"},{"student_id":9,"status":"absent"}]}]"#,
                     #"[{"id":7,"student_rollcalls":[{"student_id":8,"status":"on_call"}]}]"#, #"[]"#] {
            let transport = StubTransport([(200, "{}"), (200, timetableReply(rows))])
            do {
                _ = try await TronclassClient(transport: transport).submitNumber(id: "7", code: "0000", courseID: "11", date: attendanceDate, studentID: "9")
                XCTFail("must remain uncertain")
            } catch RollcallError.uncertain {} catch { XCTFail("unexpected \(error)") }
            let requests = await transport.requests
            XCTAssertEqual(requests.filter { $0.method == "PUT" }.count, 1)
            XCTAssertEqual(requests.filter { $0.method == "GET" }.map(\.path), ["/api/timetable_rollcalls?course_ids=11&rollcall_date=2026-10-08"])
        }
    }
    func testInvalidSubmissionContextNeverWrites() async throws {
        let cases: [(String, String, String, String, Date)] = [
            ("7/8", "0012", "11", "9", attendanceDate), ("7", "0012", "11&extra=1", "9", attendanceDate),
            ("7", "0012", "11", "", attendanceDate), ("7", "", "11", "9", attendanceDate),
            ("7", "0012", "11", "9", Date(timeIntervalSinceReferenceDate: .nan))
        ]
        for (id, code, course, student, date) in cases {
            let transport = StubTransport([])
            do {
                _ = try await TronclassClient(transport: transport).submitNumber(id: id, code: code, courseID: course, date: date, studentID: student)
                XCTFail("Invalid context must be rejected before PUT")
            } catch {}
            let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
        }
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

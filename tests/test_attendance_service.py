"""课程分页与签到人数统计的离线测试，不使用真实账号或学校请求。"""

import unittest
from unittest.mock import Mock, patch

import requests

import rollcall_service as service


def response(data, status=200):
    result = Mock(status_code=status)
    result.json.return_value = data
    return result


def student(student_id, status, **extra):
    return {"student_id": student_id, "status": status, **extra}


class AttendanceSummaryTests(unittest.TestCase):
    def summarize(self, *students):
        return service.summarize_attendance({"student_rollcalls": list(students)})

    def test_counts_exact_signed_states_without_counting_other_states_as_absent(self):
        statuses = ["on_call", "on_call_fine", "on_call_late", "present", "attended", "late", "absent", "leave", "unrecognized"]
        summary = self.summarize(*(student(index, status) for index, status in enumerate(statuses)))
        self.assertEqual(summary, {
            "total": 9, "signed": 6, "unsigned": 1, "unknown": 2,
            "status_counts": dict.fromkeys(statuses, 1),
        })

    def test_does_not_match_status_substrings(self):
        summary = self.summarize(student(1, "not_on_call"), student(2, "on_call_failed"), student(3, "called"))
        self.assertEqual(summary["signed"], 0)
        self.assertEqual(summary["unknown"], 3)

    def test_deduplicates_student_id_over_different_record_ids(self):
        summary = self.summarize(student(123, "on_call", id=1), student("123", "on_call", id=2))
        self.assertEqual(summary["total"], 1)
        self.assertEqual(summary["signed"], 1)
        self.assertEqual(summary["status_counts"], {"on_call": 1})

    def test_conflicting_states_are_unknown_regardless_of_order(self):
        rows = [student(1, "on_call"), student(1, "absent"), student(2, "present"), student(2, "late")]
        summary = self.summarize(*rows)
        self.assertEqual(summary, self.summarize(*reversed(rows)))
        self.assertEqual(summary, {"total": 2, "signed": 0, "unsigned": 0, "unknown": 2, "status_counts": {"conflict": 2}})

    def test_missing_identity_falls_back_to_record_id_then_individual_rows(self):
        summary = self.summarize(
            {"id": 12, "status": "absent"}, {"id": "12", "status": "absent"},
            {"status": "on_call"}, {"status": "on_call"}, student(12, "late"),
        )
        self.assertEqual(summary["total"], 4)
        self.assertEqual(summary["signed"], 3)
        self.assertEqual(summary["unsigned"], 1)

    def test_missing_status_is_unknown_with_legacy_status_fallback(self):
        summary = self.summarize(
            {"student_id": 1}, {"student_id": 2, "status": 123},
            {"student_id": 3, "rollcall_status": "on_call"}, student(4, " ON_CALL "),
        )
        self.assertEqual(summary["signed"], 2)
        self.assertEqual(summary["unknown"], 2)

    def test_empty_list_is_zero_but_missing_or_malformed_roster_is_an_error(self):
        self.assertEqual(self.summarize(), {"total": 0, "signed": 0, "unsigned": 0, "unknown": 0, "status_counts": {}})
        for malformed in (None, [], {}, {"student_rollcalls": None}, {"student_rollcalls": {}}, {"student_rollcalls": [None]}):
            with self.subTest(data=malformed), self.assertRaises(service.RollcallQueryError):
                service.summarize_attendance(malformed)

    def test_summary_has_no_student_information_or_mutation(self):
        row = student(123456, "present", name="匿名测试姓名", account="anonymous-account")
        summary = self.summarize(row)
        self.assertEqual(set(summary), {"total", "signed", "unsigned", "unknown", "status_counts"})
        self.assertNotIn("123456", str(summary))
        self.assertNotIn("匿名测试姓名", str(summary))
        self.assertNotIn("anonymous-account", str(summary))
        self.assertEqual(row["name"], "匿名测试姓名")


class CourseQueryTests(unittest.TestCase):
    @patch.object(service.requests, "post")
    def test_fetches_next_page_and_deduplicates_course_ids(self, post):
        first = [{"id": value, "name": f"课程{value}"} for value in range(1, 31)]
        post.side_effect = [response({"courses": first}), response({"courses": [{"id": "30"}, {"id": 31}]})]
        courses = service.get_courses("offline", "semester", "year")
        self.assertEqual([item["id"] for item in courses], list(range(1, 32)))
        self.assertEqual(post.call_count, 2)
        for page, request in enumerate(post.call_args_list, 1):
            args, options = request
            self.assertEqual(args, (service.BASE_URL + "/api/my-courses",))
            self.assertEqual(options["json"]["page"], page)
            self.assertEqual(options["json"]["conditions"]["semester_id"], ["semester"])
            self.assertEqual(options["json"]["conditions"]["academic_year_id"], ["year"])
            self.assertEqual(options["timeout"], 15)
            self.assertFalse(options["allow_redirects"])

    @patch.object(service.requests, "post")
    def test_explicit_pagination_overrides_short_page(self, post):
        for key, first_value, last_value in (("has_more", True, False), ("pages", 2, 2), ("total", 31, 31)):
            with self.subTest(key=key):
                post.reset_mock()
                post.side_effect = [response({"data": {"courses": [{"id": 1}], key: first_value}}), response({"data": {"courses": [{"id": 2}], key: last_value}})]
                self.assertEqual(len(service.get_courses("offline", "s", "y")), 2)
                self.assertEqual(post.call_count, 2)

    @patch.object(service.requests, "post")
    def test_full_final_page_with_explicit_total_does_not_request_more(self, post):
        post.return_value = response({"courses": [{"id": index} for index in range(30)], "total": 30})
        self.assertEqual(len(service.get_courses("offline", "s", "y")), 30)
        post.assert_called_once()

    @patch.object(service.requests, "post")
    def test_plain_lists_and_legacy_data_are_supported(self, post):
        for payload in ([{"id": 1}], {"data": [{"id": 1}]}):
            with self.subTest(payload=payload):
                post.return_value = response(payload)
                self.assertEqual(service.get_courses("offline", "s", "y"), [{"id": 1}])

    @patch.object(service.requests, "post")
    def test_named_course_list_takes_precedence_over_unrelated_data(self, post):
        post.return_value = response({"courses": [{"id": 1}], "data": {"message": "metadata"}})
        self.assertEqual(service.get_courses("offline", "s", "y"), [{"id": 1}])

    @patch.object(service.requests, "post")
    def test_invalid_pagination_is_reported_as_query_error(self, post):
        for value in (True, -1, "unavailable", "²"):
            post.return_value = response({"courses": [{"id": 1}], "total": value})
            with self.subTest(value=value), self.assertRaises(service.RollcallQueryError):
                service.get_courses("offline", "s", "y")

    @patch.object(service.requests, "post")
    def test_repeated_pages_are_reported_without_infinite_requests(self, post):
        post.return_value = response({"courses": [{"id": 1}], "has_more": True})
        with self.assertRaisesRegex(service.RollcallQueryError, "重复"):
            service.get_courses("offline", "s", "y")
        self.assertEqual(post.call_count, 2)

    @patch.object(service.requests, "post")
    def test_malformed_data_and_incomplete_pages_do_not_look_like_no_courses(self, post):
        for payload in (None, {}, {"courses": [None]}, {"courses": [{}]}, {"courses": [], "has_more": True}):
            with self.subTest(payload=payload):
                post.return_value = response(payload)
                with self.assertRaises(service.RollcallQueryError):
                    service.get_courses("offline", "s", "y")

    @patch.object(service.requests, "post")
    def test_course_network_errors_do_not_leak_raw_error(self, post):
        for error in (requests.Timeout("secret-cookie"), requests.ConnectionError("secret-cookie")):
            with self.subTest(error=type(error).__name__):
                post.side_effect = error
                with self.assertRaises(service.RollcallQueryError) as raised:
                    service.get_courses("offline", "s", "y")
                self.assertNotIn("secret-cookie", str(raised.exception))

    @patch.object(service.requests, "post")
    def test_login_errors_and_invalid_json_are_query_errors(self, post):
        for status in (302, 401, 403, 500):
            post.return_value = response({}, status)
            with self.subTest(status=status), self.assertRaises(service.RollcallQueryError):
                service.get_courses("offline", "s", "y")
        post.return_value = response(None)
        post.return_value.json.side_effect = ValueError("secret-response")
        with self.assertRaises(service.RollcallQueryError) as raised:
            service.get_courses("offline", "s", "y")
        self.assertNotIn("secret-response", str(raised.exception))


class AttendanceQueryTests(unittest.TestCase):
    @patch.object(service.requests, "get")
    def test_latest_preserves_last_item_selection_and_empty_result(self, get):
        get.return_value = response({"rollcalls": [{"id": 1, "rollcall_time": "first"}, {"rollcall_id": 2, "created_at": "last"}]})
        self.assertEqual(service.get_latest_rollcall_id(10, "offline", 20), (2, "last"))
        self.assertIn("/api/course/10/student/20/rollcalls?page=1&page_size=99", get.call_args.args[0])
        self.assertEqual(get.call_args.kwargs["timeout"], 15)
        self.assertFalse(get.call_args.kwargs["allow_redirects"])
        get.return_value = response({"rollcalls": []})
        self.assertEqual(service.get_latest_rollcall_id(10, "offline", 20), (None, None))

    @patch.object(service.requests, "get")
    def test_latest_network_status_and_format_failures_raise_query_error(self, get):
        for error in (requests.Timeout("private"), requests.ConnectionError("private")):
            get.side_effect = error
            with self.assertRaises(service.RollcallQueryError):
                service.get_latest_rollcall_id(10, "offline", 20)
        get.side_effect = None
        for result in (response({}, 302), response(None), response({"rollcalls": [None]}), response({"rollcalls": [{}]})):
            get.return_value = result
            with self.assertRaises(service.RollcallQueryError):
                service.get_latest_rollcall_id(10, "offline", 20)
        get.return_value = response(None)
        get.return_value.json.side_effect = ValueError("private")
        with self.assertRaises(service.RollcallQueryError):
            service.get_latest_rollcall_id(10, "offline", 20)

    @patch.object(service.requests, "get")
    def test_date_query_filters_other_courses_and_keeps_student_list_internal(self, get):
        roster = [student(1, "on_call"), student(2, "absent")]
        target = {"id": 5, "course": {"id": "10"}, "student_rollcalls": roster}
        get.return_value = response({"rollcalls": [{"id": 1, "course": {"id": 99}}, {"id": 2, "course_id": 99}, target]})
        self.assertEqual(service.get_timetable_rollcalls(10, "2026-10-08", "offline"), [target])
        self.assertEqual(service.summarize_attendance(target)["signed"], 1)
        self.assertEqual(get.call_args.kwargs["params"], {"course_ids": 10, "rollcall_date": "2026-10-08"})

    @patch.object(service.requests, "get")
    def test_invalid_calendar_dates_never_send_requests(self, get):
        for value in (None, "20261008", "2026-1-1", "2026-02-30", "2026-10-08T00:00:00Z"):
            with self.subTest(date=value), self.assertRaises(service.RollcallQueryError):
                service.get_timetable_rollcalls(10, value, "offline")
        get.assert_not_called()

    @patch.object(service.requests, "get")
    def test_invalid_target_id_cannot_match_record_with_missing_id(self, get):
        get.return_value = response({"rollcalls": [{"number_code": "0009"}]})
        for value in (None, "", " ", False, {}):
            with self.subTest(value=value), self.assertRaises(service.RollcallQueryError):
                service.get_timetable_rollcall(10, value, "2026-10-07T18:00:00Z", "offline")
        get.assert_not_called()

    @patch.object(service.requests, "get")
    def test_single_query_matches_id_and_converts_timezone(self, get):
        target = {"id": "7", "number_code": "0009"}
        get.return_value = response({"rollcalls": [{"id": 8}, target]})
        self.assertEqual(service.get_timetable_rollcall(10, 7, "2026-10-07T18:00:00Z", "offline"), target)
        self.assertEqual(get.call_args.kwargs["params"]["rollcall_date"], "2026-10-08")
        self.assertEqual(get.call_args.args[0], service.BASE_URL + "/api/timetable_rollcalls")


if __name__ == "__main__":
    unittest.main()

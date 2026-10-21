"""离线验证按课程和签到日期查询签到码，不登录、不发送真实请求。"""

import asyncio
import io
import unittest
from contextlib import redirect_stdout
from unittest.mock import AsyncMock, Mock, patch

import requests

import free_rollcall_cli as cli
import rollcall_service as service


def attendance(**changes):
    record = {
        "id": 441597,
        "course": {"id": 110405, "name": "测试课程"},
        "type": "another",
        "is_number": True,
        "number_code": "0539",
        "status": "finished",
        "rollcall_time": "2026-10-08T00:03:17Z",
        "end_time": "2026-10-08T00:33:17Z",
        "student_rollcalls": [
            {"id": 24275223, "student_id": 41156, "status": "absent"}
        ],
    }
    record.update(changes)
    return record


class TimetableNumberCodeTests(unittest.TestCase):
    def setUp(self):
        self.get_patch = patch.object(service.requests, "get")
        self.get = self.get_patch.start()
        self.addCleanup(self.get_patch.stop)
        self.response = Mock(status_code=200)
        self.response.json.return_value = {"rollcalls": [attendance()]}
        self.get.return_value = self.response

    def query(self, **changes):
        arguments = {
            "course_id": 110405,
            "rollcall_id": 441597,
            "rollcall_time": "2026-10-08T00:03:17Z",
            "cookie": "offline-test-cookie",
        }
        arguments.update(changes)
        return service.get_timetable_number_code(**arguments)

    def assert_new_endpoint_only(self, date="2026-10-08", course_id=110405):
        self.get.assert_called_once()
        arguments, options = self.get.call_args
        self.assertEqual(arguments, (service.BASE_URL + "/api/timetable_rollcalls",))
        self.assertEqual(options["params"], {"course_ids": course_id, "rollcall_date": date})
        self.assertEqual(options["headers"]["cookie"], "offline-test-cookie")
        self.assertEqual(options["timeout"], 15)
        self.assertIs(options["allow_redirects"], False)

    def test_exact_sample_uses_top_level_code_status_and_end_time(self):
        self.assertEqual(self.query(), ("0539", "finished", "2026-10-08T00:33:17Z"))
        self.assert_new_endpoint_only()

    def test_utc_time_crossing_beijing_midnight_keeps_utc_date(self):
        self.query(rollcall_time="2026-10-07T17:03:17Z")
        self.assert_new_endpoint_only(date="2026-10-07")

    def test_offset_time_is_converted_to_utc_date(self):
        self.query(rollcall_time="2026-10-07T12:03:17-05:00")
        self.assert_new_endpoint_only(date="2026-10-07")

    def test_positive_offset_crossing_utc_midnight_uses_previous_date(self):
        self.query(rollcall_time="2026-10-08T01:03:17+08:00")
        self.assert_new_endpoint_only(date="2026-10-07")

    def test_historical_rollcall_uses_its_date_instead_of_today(self):
        self.query(rollcall_time="2021-03-04T04:05:06Z")
        self.assert_new_endpoint_only(date="2021-03-04")

    def test_naive_time_is_already_in_beijing_timezone(self):
        self.query(rollcall_time="2026-10-08T23:03:17")
        self.assert_new_endpoint_only(date="2026-10-08")

    def test_naive_morning_time_uses_previous_utc_date(self):
        self.query(rollcall_time="2026-10-08T07:56:23")
        self.assert_new_endpoint_only(date="2026-10-07")

    def test_beijing_eight_am_and_year_boundary(self):
        for started, expected in (
            ("2026-10-15T07:59:59+08:00", "2026-10-14"),
            ("2026-10-15T08:00:00+08:00", "2026-10-15"),
            ("2026-01-01T00:00:00+08:00", "2025-12-31"),
        ):
            with self.subTest(started=started):
                self.get.reset_mock()
                self.query(rollcall_time=started)
                self.assert_new_endpoint_only(date=expected)

    def test_morning_record_found_only_on_previous_utc_day(self):
        target = attendance(rollcall_time="2026-10-14T23:56:23Z")

        def reply(_url, **options):
            rows = [target] if options["params"]["rollcall_date"] == "2026-10-14" else []
            response = Mock(status_code=200)
            response.json.return_value = {"rollcalls": rows}
            return response

        self.get.side_effect = reply
        self.assertEqual(self.query(rollcall_time=target["rollcall_time"])[0], "0539")
        self.assert_new_endpoint_only(date="2026-10-14")

    def test_matches_target_id_and_course_among_multiple_rollcalls(self):
        self.response.json.return_value = {
            "rollcalls": [
                attendance(id=111111, number_code="1111"),
                attendance(course={"id": 999999}, number_code="2222"),
                attendance(id="441597", course={"id": "110405"}, number_code="0007"),
                attendance(id=333333, number_code="3333"),
            ]
        }
        self.assertEqual(self.query(), ("0007", "finished", "2026-10-08T00:33:17Z"))
        self.assert_new_endpoint_only()

    def test_compatible_rollcall_id_and_string_request_ids(self):
        record = attendance(rollcall_id=441597)
        del record["id"]
        del record["course"]
        self.response.json.return_value = {"rollcalls": [record]}
        self.assertEqual(self.query(course_id="110405", rollcall_id="441597")[0], "0539")
        self.assert_new_endpoint_only(course_id="110405")

    def test_non_numeric_rollcall_can_return_no_code(self):
        self.response.json.return_value = {
            "rollcalls": [attendance(is_number=False, number_code=None)]
        }
        self.assertEqual(self.query(), (None, "finished", "2026-10-08T00:33:17Z"))
        self.assert_new_endpoint_only()

    def test_invalid_or_missing_date_does_not_send_request(self):
        for date in (None, "", "not-a-date", "2026-02-30T12:00:00Z"):
            with self.subTest(date=date):
                with self.assertRaises(service.RollcallQueryError):
                    self.query(rollcall_time=date)
                self.get.assert_not_called()

    def test_timeout_and_transport_errors_do_not_retry_old_endpoint(self):
        for error in (requests.Timeout("offline timeout"), requests.ConnectionError("offline failure")):
            with self.subTest(error=type(error).__name__):
                self.get.reset_mock()
                self.get.side_effect = error
                with self.assertRaises(service.RollcallQueryError):
                    self.query()
                self.assert_new_endpoint_only()

    def test_non_200_response_including_login_redirect_does_not_retry(self):
        for status in (204, 302, 401, 403, 404, 500):
            with self.subTest(status=status):
                self.get.reset_mock()
                self.response.status_code = status
                with self.assertRaises(service.RollcallQueryError):
                    self.query()
                self.assert_new_endpoint_only()

    def test_invalid_json_does_not_retry_old_endpoint(self):
        self.response.json.side_effect = ValueError("offline malformed response")
        with self.assertRaises(service.RollcallQueryError):
            self.query()
        self.assert_new_endpoint_only()

    def test_response_requires_rollcalls_list(self):
        for data in (None, [], {}, {"data": []}, {"rollcalls": None}, {"rollcalls": {}}):
            with self.subTest(data=data):
                self.get.reset_mock()
                self.response.json.return_value = data
                with self.assertRaises(service.RollcallQueryError):
                    self.query()
                self.assert_new_endpoint_only()

    def test_empty_list_or_unmatched_record_reports_query_error(self):
        for records in ([], [attendance(id=999999)], [attendance(course={"id": 999999})]):
            with self.subTest(records=records):
                self.get.reset_mock()
                self.response.json.return_value = {"rollcalls": records}
                with self.assertRaises(service.RollcallQueryError):
                    self.query()
                self.assert_new_endpoint_only()


class DailyRollcallTests(unittest.TestCase):
    @patch.object(service.requests, "get")
    def test_beijing_day_includes_both_utc_dates_and_excludes_adjacent_days(self, get):
        before = attendance(id=1, rollcall_time="2026-10-14T15:59:59Z")
        midnight = attendance(id=2, rollcall_time="2026-10-14T16:00:00Z")
        morning = attendance(id=3, rollcall_time="2026-10-14T23:59:59Z")
        eight_am = attendance(id=4, rollcall_time="2026-10-15T00:00:00Z")
        evening = attendance(id=5, rollcall_time="2026-10-15T15:59:59Z")
        tomorrow = attendance(id=6, rollcall_time="2026-10-15T16:00:00Z")
        other_course = attendance(id=7, course={"id": 999}, rollcall_time="2026-10-15T00:00:00Z")
        replies = {
            "2026-10-14": [before, midnight, morning],
            "2026-10-15": [{**morning, "id": "3"}, eight_am, evening, tomorrow, other_course],
        }

        def reply(url, **options):
            self.assertEqual(url, service.BASE_URL + "/api/timetable_rollcalls")
            self.assertEqual(options["params"]["course_ids"], 110405)
            response = Mock(status_code=200)
            response.json.return_value = {"rollcalls": replies[options["params"]["rollcall_date"]]}
            return response

        get.side_effect = reply
        result = service.get_daily_rollcalls(110405, "2026-10-15", "offline")
        self.assertEqual(result, [midnight, morning, eight_am, evening])
        self.assertEqual([call.kwargs["params"]["rollcall_date"] for call in get.call_args_list],
                         ["2026-10-14", "2026-10-15"])

    @patch.object(service.requests, "get")
    def test_beijing_day_handles_new_year_and_created_at_fallback(self, get):
        record = attendance(rollcall_time=None, created_at="2026-01-01T00:00:00+08:00")
        response = Mock(status_code=200)
        response.json.return_value = {"rollcalls": [record]}
        get.return_value = response
        self.assertEqual(service.get_daily_rollcalls(110405, "2026-01-01", "offline"), [record])
        self.assertEqual([call.kwargs["params"]["rollcall_date"] for call in get.call_args_list],
                         ["2025-12-31", "2026-01-01"])

    @patch.object(service.requests, "get")
    def test_invalid_date_never_queries_server(self, get):
        for day in (None, "2026-02-30", "2026-1-1", "20261015", "0001-01-01"):
            with self.subTest(day=day), self.assertRaises(service.RollcallQueryError):
                service.get_daily_rollcalls(110405, day, "offline")
        get.assert_not_called()

    @patch.object(service.requests, "get")
    def test_missing_record_time_does_not_guess_its_day(self, get):
        response = Mock(status_code=200)
        get.return_value = response
        for started in (None, "invalid"):
            response.json.return_value = {"rollcalls": [attendance(rollcall_time=started, created_at=None)]}
            with self.subTest(started=started), self.assertRaises(service.RollcallQueryError):
                service.get_daily_rollcalls(110405, "2026-10-15", "offline")

    @patch.object(service.requests, "get")
    def test_second_day_failure_does_not_return_partial_day(self, get):
        response = Mock(status_code=200)
        response.json.return_value = {"rollcalls": [attendance(rollcall_time="2026-10-14T23:56:23Z")]}
        get.side_effect = [response, requests.Timeout("private-cookie")]
        with self.assertRaises(service.RollcallQueryError) as caught:
            service.get_daily_rollcalls(110405, "2026-10-15", "offline")
        self.assertIn("超时", str(caught.exception))
        self.assertNotIn("private-cookie", str(caught.exception))


class TimetableCliTests(unittest.TestCase):
    def run_cli(self, query_result=None, query_error=None, rollcall_time="2026-10-08T00:03:17Z"):
        output = io.StringIO()
        with (
            patch.object(cli, "_login", new=AsyncMock(return_value=("offline-test-cookie", 41156))),
            patch.object(cli, "get_current_semester_info", return_value=("test-semester", "test-year")),
            patch.object(cli, "get_courses", return_value=[{"id": 110405, "name": "测试课程"}]),
            patch.object(cli, "get_latest_rollcall_id", return_value=(441597, rollcall_time)),
            patch.object(cli, "get_timetable_rollcall", return_value=query_result or attendance(number_code="0007"), side_effect=query_error) as query,
            patch.object(service.requests, "get", side_effect=AssertionError("禁止真实请求")),
            patch("builtins.input", side_effect=["1", ""]) as prompt,
            redirect_stdout(output),
        ):
            asyncio.run(cli.main([]))
        query.assert_called_once_with(110405, 441597, rollcall_time, "offline-test-cookie")
        self.assertEqual(prompt.call_count, 2)
        return output.getvalue()

    def test_selected_course_displays_new_query_code_and_activity_status(self):
        output = self.run_cli()
        self.assertIn("0007", output)
        self.assertIn("已结束", output)
        self.assertIn("2026-10-08 08:03", output)
        self.assertIn("退出程序", output)

    def test_query_error_returns_to_course_prompt_without_false_no_code_result(self):
        output = self.run_cli(query_error=service.RollcallQueryError("离线查询失败"))
        self.assertIn("离线查询失败", output)
        self.assertNotIn("本次签到无数字签到码", output)
        self.assertIn("退出程序", output)

    def test_missing_time_is_passed_through_instead_of_replaced_by_today(self):
        output = self.run_cli(rollcall_time=None, query_error=service.RollcallQueryError("签到时间缺失"))
        self.assertIn("签到时间缺失", output)
        self.assertIn("退出程序", output)


if __name__ == "__main__":
    unittest.main()

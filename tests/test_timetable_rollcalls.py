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

    def test_utc_time_crossing_midnight_uses_beijing_date(self):
        self.query(rollcall_time="2026-10-07T17:03:17Z")
        self.assert_new_endpoint_only(date="2026-10-08")

    def test_offset_time_crossing_midnight_uses_beijing_date(self):
        self.query(rollcall_time="2026-10-07T12:03:17-05:00")
        self.assert_new_endpoint_only(date="2026-10-08")

    def test_historical_rollcall_uses_its_date_instead_of_today(self):
        self.query(rollcall_time="2021-03-04T04:05:06Z")
        self.assert_new_endpoint_only(date="2021-03-04")

    def test_naive_time_is_already_in_beijing_timezone(self):
        self.query(rollcall_time="2026-10-08T23:03:17")
        self.assert_new_endpoint_only(date="2026-10-08")

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

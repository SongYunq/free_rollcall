"""离线验证命令入口、交互会话和查询选择，不读取账号、不访问学校。"""

import asyncio
import io
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, Mock, patch

import free_rollcall_cli as cli
import rollcall_service as service


COOKIE = "offline-cli-cookie"
STUDENT_ID = 710001
COURSES = [
    {"id": 110405, "name": "测试课程一"},
    {"id": 110406, "name": "Test course two", "display_name": "测试课程二"},
]


def rollcall(**changes):
    record = {
        "id": 441597,
        "course": {"id": 110405, "name": "测试课程一"},
        "is_number": True,
        "number_code": "0007",
        "status": "finished",
        "rollcall_time": "2026-10-08T00:03:17Z",
        "created_at": "2026-10-08T00:03:17Z",
        "end_time": "2026-10-08T00:33:17Z",
        "student_rollcalls": [
            {"student_id": 710001, "name": "不可输出的学生甲", "status": "on_call"},
            {"student_id": 710002, "name": "不可输出的学生乙", "status": "on_call_late"},
            {"student_id": 710003, "name": "不可输出的学生丙", "status": "absent"},
        ],
    }
    record.update(changes)
    return record


class CliCommandTests(unittest.TestCase):
    def run_cli(self, argv, *, inputs=None, replacements=None):
        """所有学校/账号入口均隔离；未配置的真实请求或输入会立即失败。"""
        output = io.StringIO()
        replacements = replacements or {}
        mocks = {}
        with ExitStack() as stack:
            login = AsyncMock(return_value=(COOKIE, STUDENT_ID))
            if "_login" in replacements:
                login.side_effect = replacements["_login"]
            mocks["_login"] = stack.enter_context(patch.object(cli, "_login", new=login))
            mocks["_load_account"] = stack.enter_context(patch.object(
                cli, "_load_account", side_effect=AssertionError("禁止读取账号")
            ))
            defaults = {
                "get_current_semester_info": ("test-semester", "test-year"),
                "get_courses": COURSES,
                "get_latest_rollcall_id": (441597, "2026-10-08T00:03:17Z"),
                "get_timetable_rollcall": rollcall(),
                "get_daily_rollcalls": [rollcall()],
            }
            for name, value in defaults.items():
                value = replacements.get(name, value)
                options = {"side_effect": value} if isinstance(value, BaseException) else {"return_value": value}
                mocks[name] = stack.enter_context(patch.object(cli, name, **options))
            stack.enter_context(patch.object(service.requests, "get", side_effect=AssertionError("禁止真实请求")))
            mocks["input"] = stack.enter_context(patch(
                "builtins.input", side_effect=inputs if inputs is not None else AssertionError("单次命令不应输入")
            ))
            stack.enter_context(redirect_stdout(output))
            stack.enter_context(redirect_stderr(output))
            result = asyncio.run(cli.main(argv))
        return result, output.getvalue(), mocks

    def assert_no_authentication(self, mocks):
        mocks["_login"].assert_not_awaited()
        mocks["_load_account"].assert_not_called()
        for name in ("get_current_semester_info", "get_courses", "get_latest_rollcall_id", "get_timetable_rollcall", "get_daily_rollcalls"):
            mocks[name].assert_not_called()

    def test_global_help_lists_commands_without_authentication(self):
        for argv in (["help"], ["--help"], ["-h"]):
            with self.subTest(argv=argv):
                result, output, mocks = self.run_cli(argv)
                self.assertEqual(result, 0)
                for command in ("courses", "rollcalls", "code", "attendance", "help"):
                    self.assertIn(command, output)
                self.assert_no_authentication(mocks)

    def test_command_help_explains_selector_without_authentication(self):
        for argv in (["help", "attendance"], ["attendance", "--help"]):
            with self.subTest(argv=argv):
                result, output, mocks = self.run_cli(argv)
                self.assertEqual(result, 0)
                for option in ("--course-id", "--date", "--rollcall-id"):
                    self.assertIn(option, output)
                self.assert_no_authentication(mocks)

    def test_invalid_arguments_exit_two_before_login(self):
        cases = [
            ["unknown"], ["help", "unknown"], ["courses", "1"], ["code"],
            ["attendance", "0"], ["code", "-1"], ["code", "NaN"],
            ["code", "1", "--course-id", "110405"], ["rollcalls", "--course-id", "0"],
            ["code", "1", "--rollcall-id", "441597"],
            ["attendance", "1", "--date", "2026-10-08", "--rollcall-id", "-1"],
            ["rollcalls", "1", "--date", "2026-02-30"],
            ["rollcalls", "1", "--date", "2026-1-8"],
            ["rollcalls", "1", "--date", "20261008"],
            ["rollcalls", "1", "--date", "2026-10-08T00:00:00Z"],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                result, _, mocks = self.run_cli(argv)
                self.assertEqual(result, 2)
                self.assert_no_authentication(mocks)

    def test_courses_prints_current_semester_names_ids_and_uses_unattended_login(self):
        result, output, mocks = self.run_cli(["courses"])
        self.assertEqual(result, 0)
        for text in ("测试课程一", "测试课程二", "110405", "110406"):
            self.assertIn(text, output)
        mocks["_login"].assert_awaited_once_with(unattended=True, manual=False)
        mocks["get_current_semester_info"].assert_called_once()
        self.assertEqual(mocks["get_courses"].call_args.args[:3], (COOKIE, "test-semester", "test-year"))
        mocks["get_daily_rollcalls"].assert_not_called()
        mocks["get_latest_rollcall_id"].assert_not_called()

    def test_manual_login_flag_passes_explicit_interactive_mode(self):
        result, _, mocks = self.run_cli(["--manual-login", "courses"])
        self.assertEqual(result, 0)
        mocks["_login"].assert_awaited_once_with(unattended=False, manual=True)

    def test_course_index_selects_exact_course_for_latest_code(self):
        result, output, mocks = self.run_cli(["code", "2"])
        self.assertEqual(result, 0)
        mocks["get_latest_rollcall_id"].assert_called_once_with(110406, COOKIE, STUDENT_ID)
        mocks["get_timetable_rollcall"].assert_called_once_with(110406, 441597, "2026-10-08T00:03:17Z", COOKIE)
        mocks["get_daily_rollcalls"].assert_not_called()
        self.assertIn("0007", output)
        self.assertIn("已结束", output)
        self.assertIn("2026-10-08 08:03", output)

    def test_explicit_course_id_does_not_depend_on_course_list(self):
        result, output, mocks = self.run_cli(["code", "--course-id", "110900"])
        self.assertEqual(result, 0)
        mocks["get_courses"].assert_not_called()
        mocks["get_current_semester_info"].assert_not_called()
        mocks["get_latest_rollcall_id"].assert_called_once_with(110900, COOKIE, STUDENT_ID)
        self.assertIn("0007", output)

    def test_course_index_out_of_range_does_not_query_rollcalls(self):
        result, _, mocks = self.run_cli(["code", "3"])
        self.assertEqual(result, 2)
        mocks["get_latest_rollcall_id"].assert_not_called()
        mocks["get_timetable_rollcall"].assert_not_called()

    def test_day_rollcalls_prints_all_codes_and_uses_new_endpoint_only(self):
        records = [rollcall(), rollcall(id=441598, number_code="0025", status="active", rollcall_time="2026-10-08T02:03:17Z")]
        result, output, mocks = self.run_cli(
            ["rollcalls", "1", "--date", "2026-10-08"], replacements={"get_daily_rollcalls": records}
        )
        self.assertEqual(result, 0)
        for text in ("0007", "0025", "441597", "441598", "已结束", "进行中"):
            self.assertIn(text, output)
        mocks["get_daily_rollcalls"].assert_called_once_with(110405, "2026-10-08", COOKIE)
        mocks["get_latest_rollcall_id"].assert_not_called()
        mocks["get_timetable_rollcall"].assert_not_called()

    def test_day_default_is_current_beijing_date(self):
        before = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
        result, _, mocks = self.run_cli(["rollcalls", "--course-id", "110405"])
        after = datetime.now(timezone(timedelta(hours=8))).date().isoformat()
        self.assertEqual(result, 0)
        self.assertIn(mocks["get_daily_rollcalls"].call_args.args[1], {before, after})

    def test_historical_id_matches_exact_record_instead_of_latest(self):
        records = [rollcall(id=441598, number_code="1255", rollcall_time="2026-10-08T02:03:17Z"), rollcall()]
        result, output, mocks = self.run_cli(
            ["code", "--course-id", "110405", "--date", "2026-10-08", "--rollcall-id", "441597"],
            replacements={"get_daily_rollcalls": records},
        )
        self.assertEqual(result, 0)
        self.assertIn("0007", output)
        self.assertNotIn("1255", output)
        mocks["get_latest_rollcall_id"].assert_not_called()

    def test_historical_unknown_id_fails_without_latest_fallback(self):
        result, _, mocks = self.run_cli(["code", "1", "--date", "2026-10-08", "--rollcall-id", "999999"])
        self.assertEqual(result, 1)
        mocks["get_latest_rollcall_id"].assert_not_called()
        mocks["get_timetable_rollcall"].assert_not_called()

    def test_day_latest_uses_time_instead_of_list_order_or_id(self):
        records = [
            rollcall(id=441596, number_code="0139", rollcall_time="2026-10-08T02:03:17Z"),
            rollcall(id=441598, number_code="7755", rollcall_time="2026-10-08T01:03:17Z"),
        ]
        result, output, _ = self.run_cli(["code", "1", "--date", "2026-10-08"], replacements={"get_daily_rollcalls": records})
        self.assertEqual(result, 0)
        self.assertIn("0139", output)
        self.assertNotIn("7755", output)

    def test_missing_times_cannot_silently_choose_a_day_record(self):
        records = [rollcall(rollcall_time=None, created_at=None), rollcall(id=441598, rollcall_time=None, created_at=None)]
        result, output, _ = self.run_cli(["code", "1", "--date", "2026-10-08"], replacements={"get_daily_rollcalls": records})
        self.assertEqual(result, 1)
        self.assertNotIn("0007", output)

    def test_attendance_aggregates_counts_without_student_details(self):
        result, output, mocks = self.run_cli(["attendance", "1"])
        self.assertEqual(result, 0)
        for text in ("统计人数", "已签到", "缺勤"):
            self.assertIn(text, output)
        self.assertRegex(output, r"(?m)^\s*统计人数\s+3\s*$")
        self.assertRegex(output, r"(?m)^\s*已签到\s+2\s*$")
        self.assertRegex(output, r"(?m)^\s*缺勤\s+1\s*$")
        for text in ("710001", "710002", "710003", "不可输出的学生"):
            self.assertNotIn(text, output)
        mocks["get_timetable_rollcall"].assert_called_once()

    def test_active_absentees_are_not_labelled_final_absence(self):
        result, output, _ = self.run_cli(["attendance", "1"], replacements={"get_timetable_rollcall": rollcall(status="active")})
        self.assertEqual(result, 0)
        self.assertIn("未签到", output)
        self.assertNotIn("缺勤", output)

    def test_historical_attendance_uses_selected_record(self):
        records = [rollcall(), rollcall(id=441598, student_rollcalls=[])]
        result, output, _ = self.run_cli(
            ["attendance", "1", "--date", "2026-10-08", "--rollcall-id", "441598"],
            replacements={"get_daily_rollcalls": records},
        )
        self.assertEqual(result, 0)
        self.assertRegex(output, r"(?m)^\s*统计人数\s+0\s*$")

    def test_empty_results_are_success_and_not_query_errors(self):
        cases = [
            (["courses"], {"get_courses": []}),
            (["code", "--course-id", "110405"], {"get_latest_rollcall_id": (None, None)}),
            (["rollcalls", "1", "--date", "2026-10-08"], {"get_daily_rollcalls": []}),
        ]
        for argv, replacement in cases:
            with self.subTest(argv=argv):
                result, _, _ = self.run_cli(argv, replacements=replacement)
                self.assertEqual(result, 0)

    def test_query_failure_is_error_and_does_not_fall_back_to_old_endpoint(self):
        result, output, mocks = self.run_cli(["code", "1"], replacements={"get_timetable_rollcall": service.RollcallQueryError("离线查询错误")})
        self.assertEqual(result, 1)
        self.assertIn("离线查询错误", output)
        mocks["get_daily_rollcalls"].assert_not_called()

    def test_authentication_failure_stops_all_queries(self):
        result, output, mocks = self.run_cli(["courses"], replacements={"_login": service.LoginError("离线登录失败")})
        self.assertEqual(result, 1)
        self.assertIn("离线登录失败", output)
        mocks["get_current_semester_info"].assert_not_called()
        mocks["get_courses"].assert_not_called()

    def test_interactive_session_accepts_multiple_commands_and_number_shorthand(self):
        result, output, mocks = self.run_cli([], inputs=["help", "attendance 1", "2", "courses", "exit"])
        self.assertEqual(result, 0)
        mocks["_login"].assert_awaited_once_with()
        self.assertEqual(mocks["get_courses"].call_count, 2)
        self.assertEqual(mocks["get_timetable_rollcall"].call_count, 2)
        self.assertEqual([call.args[0] for call in mocks["get_latest_rollcall_id"].call_args_list], [110405, 110406])
        self.assertIn("已签到", output)
        self.assertIn("0007", output)
        self.assertIn("退出程序", output)

    def test_interactive_parameter_and_query_errors_allow_next_command(self):
        result, output, mocks = self.run_cli(
            [], inputs=["unknown", "code 1 --date invalid", "code 1 --date \"2026-10-08", "code 1", "courses", ""],
            replacements={"get_timetable_rollcall": service.RollcallQueryError("离线查询错误")},
        )
        self.assertEqual(result, 0)
        self.assertIn("日期格式", output)
        self.assertIn("引号未闭合", output)
        self.assertIn("离线查询错误", output)
        self.assertIn("退出程序", output)
        mocks["_login"].assert_awaited_once_with()
        self.assertEqual(mocks["get_courses"].call_count, 2)
        mocks["get_timetable_rollcall"].assert_called_once()

    def test_help_does_not_open_or_create_account_file(self):
        account_path = Mock()
        account_path.open.side_effect = AssertionError("帮助命令不得读取或创建账号文件")
        with (
            patch.object(cli, "ACCOUNT_PATH", account_path),
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(side_effect=AssertionError("帮助不应登录"))) as login,
            patch.object(cli, "login_in_browser", new=AsyncMock(side_effect=AssertionError("帮助不应网页登录"))) as browser,
            redirect_stdout(io.StringIO()),
        ):
            result = asyncio.run(cli.main(["help"]))
        self.assertEqual(result, 0)
        account_path.open.assert_not_called()
        login.assert_not_awaited()
        browser.assert_not_awaited()

    def test_interactive_queries_integrate_service_and_new_endpoint(self):
        """只隔离登录和网络，验证入口、业务查询、汇总和展示串联。"""
        def response(data):
            value = Mock(status_code=200)
            value.json.return_value = data
            return value

        def get(url, **options):
            self.assertEqual(options["headers"]["cookie"], COOKIE)
            if url == service.BASE_URL + "/api/current-semester-info":
                return response({"semester": {"id": 31}, "academic_year": {"id": 13}})
            if url == service.BASE_URL + f"/api/course/110405/student/{STUDENT_ID}/rollcalls?page=1&page_size=99":
                return response({"rollcalls": [{"id": 441597, "rollcall_time": "2026-10-08T00:03:17Z"}]})
            if url == service.BASE_URL + "/api/timetable_rollcalls":
                self.assertEqual(options["params"]["course_ids"], 110405)
                self.assertIn(options["params"]["rollcall_date"], ("2026-10-07", "2026-10-08"))
                self.assertIs(options["allow_redirects"], False)
                return response({"rollcalls": [rollcall()] if options["params"]["rollcall_date"] == "2026-10-08" else []})
            raise AssertionError(f"禁止访问未约定接口: {url}")

        def post(url, **options):
            self.assertEqual(url, service.BASE_URL + "/api/my-courses")
            self.assertEqual(options["headers"]["cookie"], COOKIE)
            self.assertEqual(options["json"]["conditions"]["semester_id"], ["31"])
            self.assertEqual(options["json"]["conditions"]["academic_year_id"], ["13"])
            self.assertEqual(options["json"]["page"], 1)
            return response({"courses": COURSES, "has_more": False})

        output = io.StringIO()
        with (
            patch.object(cli, "_login", new=AsyncMock(return_value=(COOKIE, STUDENT_ID))) as login,
            patch.object(service.requests, "get", side_effect=get) as http_get,
            patch.object(service.requests, "post", side_effect=post) as http_post,
            patch("builtins.input", side_effect=["attendance 1", "code 1", "rollcalls 1 --date 2026-10-08", "exit"]),
            redirect_stdout(output),
        ):
            result = asyncio.run(cli.main([]))
        self.assertEqual(result, 0)
        login.assert_awaited_once_with()
        http_post.assert_called_once()
        urls = [call.args[0] for call in http_get.call_args_list]
        self.assertEqual(len(urls), 7)
        self.assertEqual(urls.count(service.BASE_URL + "/api/timetable_rollcalls"), 4)
        self.assertFalse(any("/student_rollcalls" in url for url in urls))
        text = output.getvalue()
        self.assertRegex(text, r"(?m)^\s*统计人数\s+3\s*$")
        self.assertRegex(text, r"(?m)^\s*已签到\s+2\s*$")
        self.assertRegex(text, r"(?m)^\s*缺勤\s+1\s*$")
        self.assertIn("0007", text)
        self.assertIn("2026-10-08 08:03", text)
        self.assertIn("退出程序", text)
        for student_detail in ("710001", "710002", "710003", "不可输出的学生"):
            self.assertNotIn(student_detail, text)


    def test_morning_commands_query_utc_dates_but_display_beijing_time(self):
        target = rollcall(rollcall_time="2026-10-14T23:56:23Z")
        cases = [
            (["code", "--course-id", "110405"], ["2026-10-14"]),
            (["attendance", "--course-id", "110405"], ["2026-10-14"]),
            (["rollcalls", "--course-id", "110405", "--date", "2026-10-15"], ["2026-10-14", "2026-10-15"]),
            (["code", "--course-id", "110405", "--date", "2026-10-15", "--rollcall-id", "441597"], ["2026-10-14", "2026-10-15"]),
            (["attendance", "--course-id", "110405", "--date", "2026-10-15"], ["2026-10-14", "2026-10-15"]),
        ]
        for argv, expected_dates in cases:
            with self.subTest(argv=argv):
                dates = []

                def get(url, **options):
                    response = Mock(status_code=200)
                    if url == service.BASE_URL + f"/api/course/110405/student/{STUDENT_ID}/rollcalls?page=1&page_size=99":
                        response.json.return_value = {"rollcalls": [{"rollcall_id": 441597, "rollcall_time": target["rollcall_time"]}]}
                    elif url == service.BASE_URL + "/api/timetable_rollcalls":
                        query_date = options["params"]["rollcall_date"]
                        dates.append(query_date)
                        response.json.return_value = {"rollcalls": [target] if query_date == "2026-10-14" else []}
                    else:
                        raise AssertionError(f"禁止访问未约定接口: {url}")
                    return response

                output = io.StringIO()
                with (
                    patch.object(cli, "_login", new=AsyncMock(return_value=(COOKIE, STUDENT_ID))),
                    patch.object(service.requests, "get", side_effect=get),
                    redirect_stdout(output),
                ):
                    result = asyncio.run(cli.main(argv))
                self.assertEqual(result, 0, output.getvalue())
                self.assertEqual(dates, expected_dates)
                self.assertIn("2026-10-15 07:56", output.getvalue())
                self.assertIn("统计人数" if argv[0] == "attendance" else "0007", output.getvalue())


class CliLoginTests(unittest.TestCase):
    def test_unattended_login_has_no_countdown_input_or_browser_fallback(self):
        with (
            patch.object(cli.sys.stdin, "isatty", return_value=True),
            patch.object(cli, "_load_account", return_value=("offline-user", "offline-password")),
            patch.object(cli, "_choose_manual_login", side_effect=AssertionError("单次命令不应倒计时")),
            patch.object(cli, "_input_credentials", side_effect=AssertionError("单次命令不应输入账号")),
            patch("builtins.input", side_effect=AssertionError("单次命令不应等待输入")),
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(return_value=(COOKIE, STUDENT_ID))) as login,
            patch.object(cli, "login_in_browser", new=AsyncMock(side_effect=AssertionError("单次命令不应网页登录"))) as browser,
        ):
            result = asyncio.run(cli._login(unattended=True))
        self.assertEqual(result, (COOKIE, STUDENT_ID))
        login.assert_awaited_once_with("offline-user", "offline-password", log=cli.log_to_terminal, allow_browser_fallback=False)
        browser.assert_not_awaited()

    def test_unattended_bad_credentials_fail_once_without_prompt_or_browser(self):
        with (
            patch.object(cli.sys.stdin, "isatty", return_value=True),
            patch.object(cli, "_load_account", return_value=("offline-user", "offline-password")),
            patch.object(cli, "_choose_manual_login", side_effect=AssertionError("单次命令不应倒计时")),
            patch.object(cli, "_input_credentials", side_effect=AssertionError("单次命令不应重试输入")),
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(side_effect=service.InvalidCredentialsError("离线账号错误"))) as login,
            patch.object(cli, "login_in_browser", new=AsyncMock(side_effect=AssertionError("单次命令不应网页登录"))) as browser,
            redirect_stdout(io.StringIO()),
        ):
            with self.assertRaises(service.LoginError):
                asyncio.run(cli._login(unattended=True))
        login.assert_awaited_once()
        browser.assert_not_awaited()

    def test_unattended_missing_account_fails_before_authentication(self):
        with (
            patch.object(cli.sys.stdin, "isatty", return_value=True),
            patch.object(cli, "_load_account", return_value=None),
            patch.object(cli, "_input_credentials", side_effect=AssertionError("单次命令不应输入")),
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(side_effect=AssertionError("无账号不得登录"))) as login,
        ):
            with self.assertRaises(service.LoginError):
                asyncio.run(cli._login(unattended=True))
        login.assert_not_awaited()

    def test_manual_login_skips_account_file_and_countdown(self):
        with (
            patch.object(cli.sys.stdin, "isatty", return_value=True),
            patch.object(cli, "_load_account", side_effect=AssertionError("手动登录不得读取默认账号")) as account,
            patch.object(cli, "_choose_manual_login", side_effect=AssertionError("手动登录不应倒计时")),
            patch.object(cli, "_input_credentials", return_value=("manual-user", "manual-password")) as credentials,
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(return_value=(COOKIE, STUDENT_ID))) as login,
            patch.object(cli, "login_in_browser", new=AsyncMock(side_effect=AssertionError("成功登录不应转网页登录"))) as browser,
        ):
            result = asyncio.run(cli._login(manual=True))
        self.assertEqual(result, (COOKIE, STUDENT_ID))
        account.assert_not_called()
        credentials.assert_called_once_with()
        login.assert_awaited_once_with("manual-user", "manual-password", log=cli.log_to_terminal, allow_browser_fallback=True)
        browser.assert_not_awaited()

    def test_manual_login_requires_terminal_before_reading_credentials(self):
        with (
            patch.object(cli.sys.stdin, "isatty", return_value=False),
            patch.object(cli, "_load_account", side_effect=AssertionError("不得读取账号")),
            patch.object(cli, "_input_credentials", side_effect=AssertionError("非终端不得交互输入")),
            patch.object(cli, "login_and_get_cookie", new=AsyncMock(side_effect=AssertionError("不得登录"))) as login,
        ):
            with self.assertRaises(service.LoginError):
                asyncio.run(cli._login(manual=True))
        login.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()

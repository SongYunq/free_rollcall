"""统一命令行入口；命令解析与展示在此，登录和查询由业务层提供。"""

import argparse
import asyncio
import json
import os
import shlex
import sys
import time
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime, timezone, timedelta
from pathlib import Path

from terminal_log import log_to_terminal
from rollcall_service import (
    InvalidCredentialsError,
    LoginError,
    RollcallQueryError,
    get_courses,
    get_current_semester_info,
    get_latest_rollcall_id,
    get_timetable_rollcall,
    get_timetable_rollcalls,
    login_and_get_cookie,
    login_in_browser,
    summarize_attendance,
)


ACCOUNT_PATH = Path(__file__).resolve().with_name("account.json")


def _load_account():
    """只读取本机配置；缺失时创建空白文件，不覆盖已有内容。"""
    try:
        with ACCOUNT_PATH.open(encoding="utf-8") as file:
            account = json.load(file)
    except FileNotFoundError:
        try:
            with ACCOUNT_PATH.open("x", encoding="utf-8") as file:
                json.dump({"username": "", "password": ""}, file, indent=2)
                file.write("\n")
        except FileExistsError:
            return _load_account()
        except OSError:
            log_to_terminal("[WARN] 无法创建账号文件，可在终端手动输入")
        log_to_terminal(f"[INFO] 请在此文件填写默认账号和密码: {ACCOUNT_PATH}")
        return None
    except (ValueError, UnicodeError):
        log_to_terminal(f"[WARN] 账号文件格式有误，请检查: {ACCOUNT_PATH}")
        return None
    except OSError:
        log_to_terminal(f"[WARN] 无法读取账号文件: {ACCOUNT_PATH}")
        return None

    if isinstance(account, dict):
        username, password = account.get("username"), account.get("password")
        if isinstance(username, str) and isinstance(password, str):
            if username.strip() and password:
                return username.strip(), password
    log_to_terminal(f"[WARN] 请在账号文件填写 username 和 password: {ACCOUNT_PATH}")
    return None


def _wait_for_enter(timeout=2.0):
    """等待 Enter，不留下读取输入的后台线程或残留按键。"""
    deadline = time.monotonic() + timeout
    if os.name == "nt":
        import msvcrt

        try:
            while time.monotonic() < deadline:
                if msvcrt.kbhit():
                    char = msvcrt.getwch()
                    if char in ("\x00", "\xe0"):
                        msvcrt.getwch()
                        continue
                    if char in ("\r", "\n"):
                        return True
                    if char == "\x03":
                        raise KeyboardInterrupt
                time.sleep(0.01)
            return False
        finally:
            while msvcrt.kbhit():
                msvcrt.getwch()

    import select
    import termios

    fd = sys.stdin.fileno()
    try:
        original = termios.tcgetattr(fd)
        settings = termios.tcgetattr(fd)
        settings[3] &= ~(termios.ICANON | termios.ECHO)
        settings[6][termios.VMIN] = 1
        settings[6][termios.VTIME] = 0
        try:
            termios.tcsetattr(fd, termios.TCSANOW, settings)
            while (remaining := deadline - time.monotonic()) > 0:
                ready, _, _ = select.select([fd], [], [], remaining)
                if ready:
                    chars = os.read(fd, 64)
                    if not chars:
                        raise EOFError
                    if b"\r" in chars or b"\n" in chars:
                        return True
            return False
        finally:
            termios.tcsetattr(fd, termios.TCSAFLUSH, original)
    except termios.error as error:
        raise OSError("当前终端不支持限时按键") from error


def _choose_manual_login():
    print("2 秒后使用默认账号登录，按 Enter 手动输入", end="", flush=True)
    try:
        return _wait_for_enter()
    except (OSError, ValueError):
        print()
        return input("当前终端不支持限时按键，按 Enter 手动输入，输入其他内容使用默认账号：") == ""
    finally:
        print()


def _input_credentials():
    """密码可见，不校验账号形式，不改写本机配置。"""
    while True:
        username = input("请输入账号：").strip()
        password = input("请输入密码：")
        if username and password:
            return username, password
        log_to_terminal("[WARN] 账号和密码不能为空，请重新输入")


async def _login(*, unattended=False, manual=False):
    interactive = sys.stdin.isatty() and not unattended
    if manual and not interactive:
        raise LoginError("手动登录需要交互终端，请在系统终端重新运行")
    if manual:
        credentials = _input_credentials()
    else:
        credentials = _load_account()
    if credentials is None:
        if not interactive:
            raise LoginError("没有可用的默认账号，请填写 account.json 后重新运行")
        credentials = _input_credentials()
    elif interactive and not manual and _choose_manual_login():
        credentials = _input_credentials()

    for attempt in range(1, 4):
        try:
            return await login_and_get_cookie(
                *credentials, log=log_to_terminal, allow_browser_fallback=interactive
            )
        except InvalidCredentialsError:
            log_to_terminal(f"[WARN] 账号或密码错误，已连续失败 {attempt} 次")
            if not interactive:
                raise LoginError("默认账号登录失败，请修改 account.json 或在终端重新运行") from None
            if attempt == 3:
                log_to_terminal("[WARN] 连续登录失败 3 次，正在打开网页登录页面")
                return await login_in_browser(log=log_to_terminal)
            credentials = _input_credentials()


def _display_width(text):
    """计算常见中英文字符的终端显示宽度，用于课程列表对齐。"""
    return sum(
        0 if unicodedata.combining(char)
        else 2 if unicodedata.east_asian_width(char) in ("W", "F")
        else 1
        for char in text
    )


SCHOOL_TIMEZONE = timezone(timedelta(hours=8))


class CommandUsageError(Exception):
    """命令参数错误，不中断交互会话。"""


class CommandParser(argparse.ArgumentParser):
    def error(self, message):
        raise CommandUsageError(message)


def _positive_int(value):
    try:
        number = int(value)
        if number > 0:
            return number
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("请输入大于 0 的整数")


def _date_arg(value):
    try:
        if date.fromisoformat(value).isoformat() == value:
            return value
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("日期格式应为 YYYY-MM-DD，例如 2026-10-08")


def create_parser():
    parser = CommandParser(
        prog="free_rollcall_cli.py",
        description="查询本学期课程、签到记录、签到码和签到人数",
        epilog="不带参数进入交互模式；输入 help 查看命令，输入 exit 退出",
    )
    parser.add_argument("--manual-login", action="store_true", help="手动输入账号和密码，需在交互终端运行")
    commands = parser.add_subparsers(dest="command", title="可用命令")
    descriptions = {
        "courses": "查看本学期课程列表",
        "rollcalls": "查看课程指定日期的签到记录，默认今天",
        "code": "查看签到码，默认课程最新一次签到",
        "attendance": "查看签到人数，默认课程最新一次签到",
    }
    command_parsers = {}
    for name, description in descriptions.items():
        sub = commands.add_parser(name, help=description, description=description)
        command_parsers[name] = sub
        if name == "courses":
            continue
        sub.add_argument("course", nargs="?", type=_positive_int, metavar="课程序号", help="courses 列表中从 1 开始的序号")
        sub.add_argument("--course-id", type=_positive_int, metavar="ID", help="直接使用真实课程 ID，与课程序号二选一")
        sub.add_argument("--date", type=_date_arg, metavar="YYYY-MM-DD", help="按北京时间查询指定日期")
        if name in ("code", "attendance"):
            sub.add_argument("--rollcall-id", type=_positive_int, metavar="ID", help="选择该日指定签到，必须同时提供 --date")
            sub.epilog = (
                f"示例：{name} 1；{name} --course-id 110405 --date 2026-10-08 "
                "--rollcall-id 441597；只提供日期时查询该日最新一次签到"
            )
        else:
            sub.epilog = f"示例：{name} 1；{name} --course-id 110405 --date 2026-10-08"
    help_parser = commands.add_parser("help", help="查看全部命令或某个命令的说明")
    help_parser.add_argument("topic", nargs="?", choices=[*descriptions, "help"])
    command_parsers["help"] = help_parser
    parser.command_parsers = command_parsers
    return parser


def _parse_command(parser, arguments):
    args = parser.parse_args(arguments)
    if args.command in ("rollcalls", "code", "attendance"):
        if (args.course is None) == (args.course_id is None):
            raise CommandUsageError("请提供课程序号或 --course-id，且只能选择一种")
        if getattr(args, "rollcall_id", None) is not None and args.date is None:
            raise CommandUsageError("--rollcall-id 必须与 --date 一起使用")
    return args


def _print_help(parser, args):
    topic = getattr(args, "topic", None)
    (parser.command_parsers[topic] if topic else parser).print_help()


def _print_table(headers, rows):
    rows = [[str(value) for value in row] for row in rows]
    widths = [max(_display_width(row[i]) for row in [headers, *rows]) for i in range(len(headers))]
    for row in [headers, *rows]:
        print("  " + "  ".join(value + " " * (widths[i] - _display_width(value)) for i, value in enumerate(row)).rstrip())


def _course_name(course):
    return course.get("display_name") or course.get("name") or "未知课程"


def _rollcall_id(record):
    return record.get("id") or record.get("rollcall_id")


def _started_at(record):
    value = record.get("rollcall_time") or record.get("created_at")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            result = result.replace(tzinfo=SCHOOL_TIMEZONE)
        return result.astimezone(SCHOOL_TIMEZONE)
    except (AttributeError, TypeError, ValueError, OverflowError):
        raise RollcallQueryError("签到时间缺失或格式有误，无法确定最新签到，请使用 --rollcall-id 指定") from None


def _time_text(record):
    try:
        return _started_at(record).strftime("%Y-%m-%d %H:%M")
    except RollcallQueryError:
        return "未知时间"


def _status_text(record):
    status = record.get("status")
    return {"active": "进行中", "finished": "已结束"}.get(status, status or "未知")


@dataclass
class QuerySession:
    cookie: str
    student_id: str
    courses: list | None = None

    def load_courses(self, *, refresh=False):
        if self.courses is None or refresh:
            semester_id, year_id = get_current_semester_info(self.cookie, log=log_to_terminal)
            self.courses = get_courses(self.cookie, semester_id, year_id, log=log_to_terminal)
        return self.courses


def _show_courses(session):
    courses = session.load_courses(refresh=True)
    if not courses:
        log_to_terminal("[INFO] 本学期暂无课程")
        return
    print("\n本学期课程：")
    _print_table(["序号", "课程名称", "课程 ID"], [
        [i, _course_name(course), course.get("id", "未知")]
        for i, course in enumerate(courses, start=1)
    ])


def _select_course(args, session):
    if args.course_id is not None:
        return {"id": args.course_id}
    courses = session.load_courses()
    if not 1 <= args.course <= len(courses):
        raise CommandUsageError("课程序号超出范围，请输入 courses 查看课程列表")
    return courses[args.course - 1]


def _query_rollcall(args, course_id, session):
    if args.date is None:
        log_to_terminal("[INFO] 正在获取最新签到记录...")
        rollcall_id, rollcall_time = get_latest_rollcall_id(course_id, session.cookie, session.student_id)
        if rollcall_id is None:
            return None
        return get_timetable_rollcall(course_id, rollcall_id, rollcall_time, session.cookie)
    records = get_timetable_rollcalls(course_id, args.date, session.cookie)
    if args.rollcall_id is not None:
        for record in records:
            if str(_rollcall_id(record)) == str(args.rollcall_id):
                return record
        raise RollcallQueryError("该课程在指定日期没有找到此签到，请先使用 rollcalls 查看签到编号")
    if not records:
        return None
    # 日期查询不依赖接口排序；任何缺失时间都无法可靠判断最新一条。
    return max(records, key=_started_at)


def _show_record_header(course, record):
    detail_course = record.get("course")
    if not isinstance(detail_course, dict):
        detail_course = course
    else:
        detail_course = {**course, **detail_course}
    print(f"\n课程: {_course_name(detail_course)} (ID: {course['id']})")
    print(f"签到 ID: {_rollcall_id(record)}")
    print(f"时间: {_time_text(record)}")
    print(f"状态: {_status_text(record)}")


def _show_attendance(record):
    result = summarize_attendance(record)
    unsigned_label = "缺勤" if record.get("status") == "finished" else "未签到"
    _print_table(["统计项", "人数"], [
        ["统计人数", result["total"]],
        ["已签到", result["signed"]],
        [unsigned_label, result["unsigned"]],
        ["其他或未知", result["unknown"]],
    ])
    print("统计范围：本次接口返回的出勤记录，按学生去重")
    if result["status_counts"]:
        print("\n状态分布：")
        _print_table(["原始状态", "人数"], sorted(result["status_counts"].items()))


def _execute_query(args, session):
    if args.command == "courses":
        _show_courses(session)
        return
    course = _select_course(args, session)
    course_id = course.get("id")
    if course_id is None:
        raise RollcallQueryError("课程缺少 ID，无法查询")
    if args.command == "rollcalls":
        query_date = args.date or datetime.now(SCHOOL_TIMEZONE).date().isoformat()
        records = get_timetable_rollcalls(course_id, query_date, session.cookie)
        if not records:
            log_to_terminal(f"[INFO] 该课程在 {query_date} 暂无签到记录")
            return
        print(f"\n{query_date} 的签到记录 (课程 ID: {course_id})：")
        _print_table(["签到 ID", "时间", "状态", "签到码"], [
            [_rollcall_id(record), _time_text(record), _status_text(record),
             record.get("number_code") if record.get("number_code") is not None else "—"]
            for record in records
        ])
        return
    record = _query_rollcall(args, course_id, session)
    if record is None:
        log_to_terminal("[INFO] 该课程暂无符合条件的签到记录")
        return
    _show_record_header(course, record)
    if args.command == "code":
        code = record.get("number_code")
        print(f"签到码: 【 {code} 】" if code is not None and code != "" else "本次签到无数字签到码")
    elif args.command == "attendance":
        _show_attendance(record)


def _interactive_loop(parser, session):
    try:
        _show_courses(session)
    except RollcallQueryError as error:
        log_to_terminal(f"[ERROR] {error}")
    print("\n输入 help 查看命令；直接输入课程序号查看签到码；输入 exit 或按 Enter 退出")
    while True:
        try:
            line = input("\nfree_rollcall> ").strip()
        except EOFError:
            print("\n退出程序")
            return 0
        if not line or line in ("exit", "quit"):
            print("退出程序")
            return 0
        try:
            try:
                arguments = shlex.split(line)
            except ValueError:
                raise CommandUsageError("命令中的引号未闭合，请重新输入") from None
            if len(arguments) == 1 and arguments[0].isdigit():
                arguments.insert(0, "code")
            args = _parse_command(parser, arguments)
            if args.manual_login:
                raise CommandUsageError("已在登录会话中，切换账号请退出后使用 --manual-login 重新运行")
            if args.command in (None, "help"):
                _print_help(parser, args)
            else:
                _execute_query(args, session)
        except SystemExit:
            # argparse 的 -h/--help 已输出帮助，继续当前会话。
            continue
        except (CommandUsageError, RollcallQueryError) as error:
            log_to_terminal(f"[ERROR] {error}")


async def main(argv=None):
    parser = create_parser()
    try:
        args = _parse_command(parser, sys.argv[1:] if argv is None else argv)
    except SystemExit as result:
        return result.code
    except CommandUsageError as error:
        log_to_terminal(f"[ERROR] {error}")
        print("使用 help 或 --help 查看命令说明")
        return 2
    if args.command == "help":
        _print_help(parser, args)
        return 0

    interactive = args.command is None
    if interactive:
        print("=" * 50)
        print("   free_rollcall(CLI) - XMU")
        print("=" * 50)
    try:
        if interactive and not args.manual_login:
            cookie, student_id = await _login()
        else:
            cookie, student_id = await _login(unattended=not args.manual_login, manual=args.manual_login)
        if not cookie or not student_id:
            raise LoginError("获取登录凭证或学生ID失败")
    except LoginError as error:
        log_to_terminal(f"[ERROR] {error}")
        return 1
    session = QuerySession(cookie, student_id)
    if interactive:
        return _interactive_loop(parser, session)
    try:
        _execute_query(args, session)
    except CommandUsageError as error:
        log_to_terminal(f"[ERROR] {error}")
        return 2
    except RollcallQueryError as error:
        log_to_terminal(f"[ERROR] {error}")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\n操作已取消")
        sys.exit(130)
    except EOFError:
        print("\n输入已结束")
        sys.exit(1)

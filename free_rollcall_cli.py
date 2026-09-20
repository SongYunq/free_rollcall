"""交互式命令行入口；登录与查询由 rollcall_service 提供。"""

import asyncio
import json
import os
import sys
import time
import unicodedata
from datetime import datetime, timezone, timedelta
from pathlib import Path

from terminal_log import log_to_terminal
from rollcall_service import (
    InvalidCredentialsError,
    LoginError,
    get_courses,
    get_current_semester_info,
    get_latest_rollcall_id,
    get_number_code,
    login_and_get_cookie,
    login_in_browser,
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


async def _login():
    interactive = sys.stdin.isatty()
    credentials = _load_account()
    if credentials is None:
        if not interactive:
            raise LoginError("没有可用的默认账号，请填写 account.json 后重新运行")
        credentials = _input_credentials()
    elif interactive and _choose_manual_login():
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


async def main():
    print("=" * 50)
    print("   free_rollcall(CLI) - XMU")
    print("=" * 50)

    try:
        cookie, student_id = await _login()
    except LoginError as error:
        log_to_terminal(f"[ERROR] {error}")
        return 1
    if not cookie or not student_id:
        log_to_terminal("[ERROR] 获取登录凭证或学生ID失败")
        return 1

    s_id, y_id = get_current_semester_info(cookie, log=log_to_terminal)
    courses = get_courses(cookie, s_id, y_id, log=log_to_terminal)
    if not courses:
        log_to_terminal("[ERROR] 课程列表获取失败")
        return

    print("\n课程列表：")
    course_rows = [
        (course.get("display_name") or course.get("name") or "未知课程", course.get("id"))
        for course in courses
    ]
    number_width = len(str(len(course_rows)))
    name_width = max(_display_width(name) for name, _ in course_rows)
    for i, (name, cid) in enumerate(course_rows, start=1):
        padding = " " * (name_width - _display_width(name))
        print(f"  {i:>{number_width}}. {name}{padding}  (ID: {cid})")

    while True:
        print("\n" + "-" * 40)
        user_input = input("请输入课程编号 (按Enter键退出)：")

        if user_input.strip() == "":
            print("退出程序")
            break

        try:
            choice = int(user_input) - 1
            if choice < 0 or choice >= len(courses):
                log_to_terminal("[ERROR] 编号输入有误,请重新输入")
                continue
        except ValueError:
            log_to_terminal("[ERROR] 请输入有效数字编号")
            continue

        selected = courses[choice]
        course_id = selected.get("id")
        course_name = selected.get("display_name") or selected.get("name")
        print(f"\n已选择课程: {course_name}")

        log_to_terminal("[INFO] 正在获取最新签到记录...")
        rollcall_id, rollcall_time = get_latest_rollcall_id(course_id, cookie, student_id)
        if not rollcall_id:
            log_to_terminal("[WARN] 该课程暂无签到记录")
            continue

        if rollcall_time:
            try:
                dt = datetime.fromisoformat(rollcall_time.replace("Z", "+00:00"))
                dt_local = dt.astimezone(timezone(timedelta(hours=8)))
                time_str = dt_local.strftime("%Y-%m-%d %H:%M")
            except Exception:
                time_str = str(rollcall_time)
        else:
            time_str = "未知时间"

        log_to_terminal(f"[INFO] 找到最新签到: {time_str} (ID: {rollcall_id})")

        number_code, status, end_time = get_number_code(rollcall_id, cookie)

        print()
        print("=" * 40)
        if number_code:
            print(f"  签到码: 【 {number_code} 】")
            status_map = {"active": "进行中", "finished": "已结束"}
            print(f"  状态:   {status_map.get(status, status)}")
            print(f"  时间:   {time_str}")
        else:
            print("  本次签到无数字签到码（可能为扫码签到或 GPS 定位签到）")
        print("=" * 40)

if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except (KeyboardInterrupt, EOFError):
        print("\n退出程序")

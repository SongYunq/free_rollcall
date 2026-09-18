"""交互式命令行入口；登录与查询由 rollcall_service 提供。"""

import asyncio
import unicodedata
from datetime import datetime, timezone, timedelta

from terminal_log import log_to_terminal
from rollcall_service import (
    get_courses,
    get_current_semester_info,
    get_latest_rollcall_id,
    get_number_code,
    login_and_get_cookie,
)


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

    cookie, student_id = await login_and_get_cookie(log=log_to_terminal)
    if not cookie or not student_id:
        log_to_terminal("[ERROR] 获取登录凭证或学生ID失败")
        return

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
    asyncio.run(main())

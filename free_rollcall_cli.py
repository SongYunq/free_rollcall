"""交互式命令行入口；登录与查询由 rollcall_service 提供。"""

import asyncio
from datetime import datetime, timezone, timedelta

from terminal_log import log_to_terminal
from rollcall_service import (
    get_courses,
    get_current_semester_info,
    get_latest_rollcall_id,
    get_number_code,
    login_and_get_cookie,
)


async def main():
    print("=" * 50)
    print("   free_rollcall - 厦大畅课签到码查询助手 (CLI) ")
    print("=" * 50)

    cookie, student_id = await login_and_get_cookie(log=log_to_terminal)
    if not cookie or not student_id:
        log_to_terminal("[ERROR] 流程终止：未能获取到登录凭证或学生 ID。")
        return

    s_id, y_id = get_current_semester_info(cookie, log=log_to_terminal)
    courses = get_courses(cookie, s_id, y_id, log=log_to_terminal)
    if not courses:
        log_to_terminal("[ERROR] 获取课程列表失败。")
        return

    print(f"\n课程列表：")
    for i, course in enumerate(courses):
        name = course.get("display_name") or course.get("name") or "未知课程"
        cid = course.get("id")
        print(f"  {i+1}. {name}  (ID: {cid})")

    while True:
        print("\n" + "-" * 40)
        user_input = input("请输入课程编号 (直接按 Enter 回车键退出)：")
        
        if user_input.strip() == "":
            print("退出程序。")
            break

        try:
            choice = int(user_input) - 1
            if choice < 0 or choice >= len(courses):
                log_to_terminal("[ERROR] 编号超出范围，请重新输入。")
                continue
        except ValueError:
            log_to_terminal("[ERROR] 请输入有效的数字编号。")
            continue

        selected = courses[choice]
        course_id = selected.get("id")
        course_name = selected.get("display_name") or selected.get("name")
        print(f"\n已选择课程: {course_name}")

        log_to_terminal("[INFO] 正在获取最新签到记录...")
        rollcall_id, rollcall_time = get_latest_rollcall_id(course_id, cookie, student_id)
        if not rollcall_id:
            log_to_terminal("[WARN] 该课程暂无签到记录。")
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
            print("  本次签到无数字签到码（可能为扫码签到或 GPS 定位签到）。")
        print("=" * 40)

if __name__ == "__main__":
    asyncio.run(main())

"""畅课查询业务层，供 CLI、桌面端及后续脚本直接调用。

保留原接口参数、数据解析和返回值；此模块不依赖 UI、不读取终端输入。
登录使用 Playwright 异步 API，查询使用 requests 同步 API。
调用端负责事件循环、后台线程、用户提示与结果展示。
"""

import asyncio
import re

import requests
from playwright.async_api import async_playwright


def _ignore_log(_message):
    """默认不输出，由调用端按需传入日志回调。"""
    pass


BASE_URL = "https://lnt.xmu.edu.cn"
HEADERS_BASE = {
    "accept": "application/json, text/plain, */*",
    "accept-language": "zh-CN,zh;q=0.9",
    "user-agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/147.0.0.0 Safari/537.36"
    ),
}

# ==============================================================================
# 后端业务逻辑
# ==============================================================================

def get_current_semester_info(cookie, log=_ignore_log):
    """读取当前学期和学年，返回字符串 ID；失败沿用原默认值。"""
    headers = {**HEADERS_BASE, "cookie": cookie}
    try:
        resp = requests.get(
            f"{BASE_URL}/api/current-semester-info", headers=headers, timeout=5
        )
        if resp.status_code == 200:
            data = resp.json()
            return str(data["semester"]["id"]), str(data["academic_year"]["id"])
    except Exception:
        pass
    log("[WARN] 动态获取学期失败，使用内置默认参数...")
    return "29", "12"


async def login_and_get_cookie(log=_ignore_log, *, browser_channels=()):
    """浏览器登录，返回 (cookie, student_id)。

    默认直接启动 Playwright Chromium，启动失败时抛出异常（CLI 原行为）。
    传入本机浏览器渠道时依次尝试，最后回退 Chromium；全失败返回
    (None, None)（GUI 原行为）。本轮不保存或复用登录会话。
    log 可传入单参数回调，默认静默。"""
    log("[INFO] 正在启动浏览器，连接厦大统一身份认证系统...")
    async with async_playwright() as p:
        if not browser_channels:
            browser = await p.chromium.launch(headless=False)
        else:
            browser = None

            for channel in browser_channels:
                try:
                    log(f"[INFO] 正在尝试调用本地 [{channel}] 浏览器...")
                    browser = await p.chromium.launch(headless=False, channel=channel)
                    log(f"[SUCCESS] 成功唤起本地 [{channel}] 浏览器。")
                    break
                except Exception:
                    pass

            if browser is None:
                log("[INFO] 尝试启用 Playwright 内置 Chromium 内核...")
                try:
                    browser = await p.chromium.launch(headless=False)
                except Exception as e:
                    log(f"[ERROR] 浏览器启动失败: {e}")
                    return None, None

        context = await browser.new_context()
        page    = await context.new_page()
        student_id = None

        def handle_request(request):
            nonlocal student_id
            if student_id is None:
                m = re.search(r"/student/(\d+)/rollcalls", request.url)
                if m:
                    student_id = int(m.group(1))
                    log(f"[SUCCESS] 已提取到学生 ID: {student_id}")

        page.on("request", handle_request)
        await page.goto(BASE_URL)

        if "ids.xmu.edu.cn" in page.url:
            log("[INFO] 请在浏览器中输入账号密码登录...")
            await page.wait_for_function(
                "() => !window.location.href.includes('ids.xmu.edu.cn')",
                timeout=120000,
            )
            log("[SUCCESS] 登录成功，等待页面跳转...")

        try:
            await page.wait_for_url(
                "**/lnt.xmu.edu.cn/**", timeout=15000, wait_until="commit"
            )
            await asyncio.sleep(1)
        except Exception:
            pass

        if student_id is None:
            log("[INFO] 正在拉取课程页面触发数据包拦截...")
            try:
                cookies_tmp = await context.cookies()
                cookie_str_tmp = "; ".join(
                    f"{c['name']}={c['value']}"
                    for c in cookies_tmp
                    if "xmu.edu.cn" in c.get("domain", "")
                )
                s_id, y_id = get_current_semester_info(cookie_str_tmp, log)
                payload_tmp = {
                    "conditions": {
                        "semester_id": [s_id],
                        "academic_year_id": [y_id],
                        "keyword": "",
                        "classify_type": "recently_started",
                        "display_studio_list": False,
                    },
                    "fields": "id,name",
                    "page": 1,
                    "page_size": 1,
                    "showScorePassedStatus": False,
                }
                resp_tmp  = await context.request.post(
                    f"{BASE_URL}/api/my-courses", data=payload_tmp
                )
                data_tmp  = await resp_tmp.json()
                courses_tmp = data_tmp.get("courses", data_tmp.get("data", []))
                if courses_tmp:
                    first_id = courses_tmp[0]["id"]
                    await page.goto(f"{BASE_URL}/course/{first_id}/rollcall")
                    for _ in range(15):
                        if student_id is not None:
                            break
                        await asyncio.sleep(1)
            except Exception as e:
                log(f"[WARN] 自动触发跳转失败: {e}")

        cookies = await context.cookies()
        lnt_cookies = [c for c in cookies if "lnt.xmu.edu.cn" in c.get("domain", "")]
        cookie_str  = "; ".join(f"{c['name']}={c['value']}" for c in lnt_cookies)
        await browser.close()

        if not student_id:
            log("[ERROR] 未能提取到学生 ID。")
        return cookie_str, student_id


def get_courses(cookie, s_id, y_id, log=_ignore_log):
    """读取本学期课程，按课程 ID 去重并保留接口返回顺序。"""
    log("[INFO] 正在获取本学期课程列表...")
    headers = {
        **HEADERS_BASE,
        "cookie": cookie,
        "content-type": "application/json",
        "referer": "https://lnt.xmu.edu.cn/user/index",
    }
    payload = {
        "conditions": {
            "semester_id": [s_id],
            "academic_year_id": [y_id],
            "keyword": "",
            "classify_type": "recently_started",
            "display_studio_list": False,
        },
        "fields": "id,name,display_name",
        "page": 1,
        "page_size": 30,
        "showScorePassedStatus": False,
    }
    resp = requests.post(f"{BASE_URL}/api/my-courses", headers=headers, json=payload)
    try:
        data = resp.json()
    except Exception:
        log(f"[WARN] 返回数据解析失败: {resp.text}")
        return []

    if isinstance(data, list):
        courses = data
    elif "courses" in data:
        courses = data["courses"]
    elif "data" in data:
        courses = data["data"]
    else:
        log("[WARN] 无法解析课程列表数据")
        return []

    seen, unique = set(), []
    for c in courses:
        cid = c.get("id")
        if cid not in seen:
            seen.add(cid)
            unique.append(c)
    return unique


def get_latest_rollcall_id(course_id, cookie, student_id):
    """沿用取列表最后一项的规则，返回 (签到 ID, 发起时间)。"""
    headers = {**HEADERS_BASE, "cookie": cookie}
    url  = (
        f"{BASE_URL}/api/course/{course_id}"
        f"/student/{student_id}/rollcalls?page=1&page_size=99"
    )
    resp = requests.get(url, headers=headers)
    data = resp.json()

    if isinstance(data, list):
        rollcalls = data
    elif "rollcalls" in data:
        rollcalls = data["rollcalls"]
    elif "data" in data:
        rollcalls = data["data"]
    else:
        rollcalls = []

    if not rollcalls:
        return None, None
    latest = rollcalls[-1]
    return (
        latest.get("id") or latest.get("rollcall_id"),
        latest.get("rollcall_time") or latest.get("created_at"),
    )


def get_number_code(rollcall_id, cookie):
    """返回接口原始的 (number_code, status, end_time)，不格式化。"""
    headers = {**HEADERS_BASE, "cookie": cookie}
    url  = f"{BASE_URL}/api/rollcall/{rollcall_id}/student_rollcalls"
    resp = requests.get(url, headers=headers)
    data = resp.json()
    return data.get("number_code"), data.get("status"), data.get("end_time")

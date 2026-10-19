"""畅课登录与查询业务层，供命令行及后续脚本直接调用。

此模块不依赖 UI、不读取终端输入；命令行通过课程日期接口读取签到码。
登录使用 Playwright 异步 API，查询使用 requests 同步 API。
调用端负责事件循环、后台线程、用户提示与结果展示。
"""

import asyncio
import re
from datetime import date, datetime, timedelta, timezone

import requests
from playwright.async_api import Error as PlaywrightError
from playwright.async_api import TimeoutError as PlaywrightTimeoutError
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


class LoginError(Exception):
    """可直接向用户展示的登录错误，不包含凭证或底层调用参数。"""


class InvalidCredentialsError(LoginError):
    """网站拒绝账号或密码，调用端可以重新收集凭证。"""


class BrowserLoginRequired(LoginError):
    """网站需要验证码或其他人工认证。"""


class RollcallQueryError(Exception):
    """课程或签到查询失败；错误信息不包含凭证或其他学生的信息。"""


# 只观察已核实的表单状态，不修改或替代网站的认证逻辑。
_LOGIN_STATE = """() => {
    if (location.hostname === 'lnt.xmu.edu.cn' &&
        !/^\\/login(?:\\/|$)/.test(location.pathname)) return 'success';
    const visible = (e) => e && e.getClientRects().length &&
        getComputedStyle(e).visibility !== 'hidden';
    const error = document.querySelector('#pwdFromId #showErrorTip');
    const text = visible(error) ? error.textContent.trim() : '';
    if (text) {
        if (/网络|超时|服务异常|系统异常|network|timeout|unavailable/i.test(text))
            return 'error';
        if (/验证码|滑块|短信|动态码|验证身份|重置|禁用|锁定|captcha|locked/i.test(text))
            return 'manual';
        if (/账号|帐号|用户|密码|认证失败|登录失败|不允许|非法|username|password|credential/i.test(text))
            return 'invalid';
        return 'manual';
    }
    if (visible(document.querySelector('#pwdFromId #captcha')) ||
        document.querySelector('#sliderCaptchaDiv')?.children.length ||
        visible(document.querySelector('#dynamicCode'))) return 'manual';
    const warning = document.querySelector('#pwdFromId #showWarnTip');
    if (visible(warning) && warning.textContent.trim()) return 'manual';
    return false;
}"""


async def _submit_credentials(page, username, password, log=_ignore_log):
    """使用网站自己的提交按钮，包括页面原有的加密和验证。"""
    account_link = page.locator('a[href*="type=userNameLogin"]')
    form = page.locator("#pwdFromId")
    username_input = form.locator("#username")
    password_input = form.locator("#password")
    # 扫码模式由页面脚本异步显示；不能用一次 is_visible 判断就跳过切换。
    try:
        await page.locator(
            '#pwdFromId #username:visible, a[href*="type=userNameLogin"]:visible'
        ).first.wait_for(state="visible", timeout=20000)
        if not await username_input.is_visible():
            log("[INFO] 切换到账号密码登录")
            await account_link.click()
        await username_input.wait_for(state="visible", timeout=20000)
        await password_input.wait_for(state="visible", timeout=20000)
    except PlaywrightTimeoutError:
        raise LoginError("账号密码登录页面加载超时，请稍后重试") from None

    await username_input.fill(username)
    await password_input.fill(password)
    # 页面若自行截断了内容，不提交被悄悄改写过的凭证。
    if (await username_input.input_value() != username or
            await password_input.input_value() != password):
        raise InvalidCredentialsError("登录页面未接受完整账号或密码")
    if await page.evaluate(_LOGIN_STATE) == "manual":
        raise BrowserLoginRequired("需要验证码或额外认证，请在网页中完成登录")
    log("[INFO] 提交账号密码，等待认证结果")
    try:
        await form.locator("#login_submit").click()
        result = await page.wait_for_function(_LOGIN_STATE, timeout=30000)
    except PlaywrightTimeoutError:
        raise LoginError("已提交登录，但等待认证结果超时，请稍后重试") from None
    state = await result.json_value()
    await result.dispose()
    if state == "invalid":
        raise InvalidCredentialsError("账号或密码未通过认证")
    if state == "manual":
        raise BrowserLoginRequired("需要验证码或额外认证，请在网页中完成登录")
    if state == "error":
        raise LoginError("统一身份认证暂时不可用，请稍后重试")


async def login_and_get_cookie(
    username, password, log=_ignore_log, *, allow_browser_fallback=True
):
    """后台认证一次并返回 (cookie, student_id)，不读取终端或账号文件。

    凭证错误抛出 InvalidCredentialsError，由调用端决定重试次数。
    额外认证默认打开网页登录；脚本可关闭此回退并处理 BrowserLoginRequired。
    不保存或复用登录会话，不再兼容旧桌面端的 browser_channels 参数。
    """
    try:
        return await _login_with_browser(username, password, log, manual=False)
    except BrowserLoginRequired:
        if not allow_browser_fallback:
            raise
        log("[WARN] 需要人工认证，正在打开网页登录页面，请在网页中重新登录")
        return await login_in_browser(log=log)


async def login_in_browser(log=_ignore_log):
    """打开网页登录并等待人工认证，随后沿用同一查询凭证提取流程。"""
    return await _login_with_browser(None, None, log, manual=True)


async def _login_with_browser(username, password, log, *, manual):
    log("[INFO] 加载统一身份认证登录页面")
    try:
        async with async_playwright() as p:
            try:
                browser = await p.chromium.launch(headless=not manual)
            except PlaywrightError:
                raise LoginError(
                    "浏览器启动失败，请确认已执行 python -m playwright install chromium"
                ) from None
            try:
                context = await browser.new_context(locale="zh-CN")
                page = await context.new_page()
                return await _login_and_extract(page, context, username, password, log, manual)
            finally:
                await browser.close()
    except PlaywrightTimeoutError:
        raise LoginError("登录超时，请检查网络或稍后重试") from None
    except PlaywrightError:
        raise LoginError("登录未完成，请检查网络及浏览器是否已关闭") from None


async def _login_and_extract(page, context, username, password, log, manual):
    student_id = None

    def handle_request(request):
        nonlocal student_id
        if student_id is None:
            m = re.search(r"/student/(\d+)/rollcalls", request.url)
            if m:
                student_id = int(m.group(1))
                log(f"[SUCCESS] 已提取到学生 ID: {student_id}")

    page.on("request", handle_request)
    try:
        await page.goto(BASE_URL, wait_until="domcontentloaded")
    except PlaywrightTimeoutError:
        raise LoginError("统一身份认证页面打开超时，请检查网络或稍后重试") from None

    if manual:
        log("[INFO] 请进行统一身份认证登录")
        await page.wait_for_url(
            re.compile(r"https://lnt\.xmu\.edu\.cn/(?!login(?:[/?#]|$))"),
            timeout=120000, wait_until="domcontentloaded",
        )
    else:
        log("[INFO] 正在使用账号密码登录")
        await _submit_credentials(page, username, password, log)
    log("[SUCCESS] 登录成功，等待页面跳转...")

    try:
        await page.wait_for_url(
            "**/lnt.xmu.edu.cn/**", timeout=15000, wait_until="commit"
        )
        await asyncio.sleep(1)
    except Exception:
        pass

    if student_id is None:
        log("[INFO] 正在通过课程签到页面获取学生 ID...")
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
        except Exception:
            log("[WARN] 自动触发跳转失败，请稍后重试")

    cookies = await context.cookies()
    lnt_cookies = [c for c in cookies if "lnt.xmu.edu.cn" in c.get("domain", "")]
    cookie_str  = "; ".join(f"{c['name']}={c['value']}" for c in lnt_cookies)
    if not student_id:
        log("[ERROR] 未能提取到学生 ID")
    return cookie_str, student_id


def _query_data(response, subject):
    """统一读取查询结果，不把原始响应或登录凭证带入错误信息。"""
    if response.status_code in (401, 403) or 300 <= response.status_code < 400:
        raise RollcallQueryError(f"登录已失效或无权查询{subject}，请重新登录后重试")
    if response.status_code != 200:
        raise RollcallQueryError(f"{subject}查询失败，服务返回状态码 {response.status_code}")
    try:
        return response.json()
    except ValueError:
        raise RollcallQueryError(f"{subject}查询返回的数据无法解析，请稍后重试") from None


def _query_rows(data, key, subject):
    """兼容原接口的列表、具名列表及 data 包装。"""
    container = data
    if isinstance(data, dict) and key not in data and isinstance(data.get("data"), dict):
        container = data["data"]
    if isinstance(container, list):
        rows = container
    elif isinstance(container, dict):
        rows = container.get(key, container.get("data"))
    else:
        rows = None
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise RollcallQueryError(f"{subject}查询返回的数据格式有误")
    return rows, container


def _courses_have_more(data, container, page, page_size, row_count):
    # 优先使用服务明确给出的分页信息；旧格式则按每页容量判断。
    for key in ("has_more", "pages", "total"):
        value = container.get(key) if isinstance(container, dict) else None
        if value is None and isinstance(data, dict):
            value = data.get(key)
        if value is None:
            continue
        if key == "has_more":
            if not isinstance(value, bool):
                raise RollcallQueryError("课程列表查询返回的分页信息有误")
            return value
        if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
            raise RollcallQueryError("课程列表查询返回的分页信息有误")
        return page < int(value) if key == "pages" else page * page_size < int(value)
    return row_count >= page_size


def get_courses(cookie, s_id, y_id, log=_ignore_log):
    """分页读取本学期课程，按课程 ID 去重并保留接口返回顺序。"""
    log("[INFO] 正在获取本学期课程列表...")
    headers = {
        **HEADERS_BASE,
        "cookie": cookie,
        "content-type": "application/json",
        "referer": f"{BASE_URL}/user/index",
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
        "page_size": 30,
        "showScorePassedStatus": False,
    }
    seen, unique = set(), []
    # 正常课程列表远少于此上限，避免服务错误导致无限分页。
    for page in range(1, 101):
        try:
            resp = requests.post(
                f"{BASE_URL}/api/my-courses", headers=headers,
                json={**payload, "page": page}, timeout=15, allow_redirects=False,
            )
        except requests.Timeout:
            raise RollcallQueryError("课程列表查询超时，请稍后重试") from None
        except requests.RequestException:
            raise RollcallQueryError("课程列表查询失败，请检查网络后重试") from None
        data = _query_data(resp, "课程列表")
        courses, container = _query_rows(data, "courses", "课程列表")
        added = 0
        for course in courses:
            cid = course.get("id")
            if not isinstance(cid, (int, str)) or isinstance(cid, bool) or not str(cid).strip():
                raise RollcallQueryError("课程列表查询返回的课程编号有误")
            key = str(cid)
            if key not in seen:
                seen.add(key)
                unique.append(course)
                added += 1
        more = _courses_have_more(data, container, page, payload["page_size"], len(courses))
        if courses and not added:
            raise RollcallQueryError("课程列表分页返回了重复数据，无法确认完整课程列表，请稍后重试")
        if not more:
            return unique
        if not courses:
            raise RollcallQueryError("课程列表分页数据不完整，请稍后重试")
    raise RollcallQueryError("课程列表分页数量异常，请稍后重试")


def get_latest_rollcall_id(course_id, cookie, student_id):
    """沿用取列表最后一项的规则，返回 (签到 ID, 发起时间)。"""
    headers = {**HEADERS_BASE, "cookie": cookie}
    url = (
        f"{BASE_URL}/api/course/{course_id}"
        f"/student/{student_id}/rollcalls?page=1&page_size=99"
    )
    try:
        resp = requests.get(url, headers=headers, timeout=15, allow_redirects=False)
    except requests.Timeout:
        raise RollcallQueryError("签到列表查询超时，请稍后重试") from None
    except requests.RequestException:
        raise RollcallQueryError("签到列表查询失败，请检查网络后重试") from None
    rollcalls, _ = _query_rows(_query_data(resp, "签到列表"), "rollcalls", "签到列表")
    if not rollcalls:
        return None, None
    latest = rollcalls[-1]
    rollcall_id = latest.get("id") or latest.get("rollcall_id")
    if not isinstance(rollcall_id, (str, int)) or isinstance(rollcall_id, bool) or not str(rollcall_id).strip():
        raise RollcallQueryError("签到列表查询返回的签到编号有误")
    return rollcall_id, latest.get("rollcall_time") or latest.get("created_at")


def get_number_code(rollcall_id, cookie):
    """保留给历史桌面端的旧查询接口，命令行不再调用。"""
    headers = {**HEADERS_BASE, "cookie": cookie}
    url  = f"{BASE_URL}/api/rollcall/{rollcall_id}/student_rollcalls"
    resp = requests.get(url, headers=headers)
    data = resp.json()
    return data.get("number_code"), data.get("status"), data.get("end_time")


def _parse_rollcall_time(rollcall_time):
    """解析发起时间；沿用无时区时间按北京时间处理的约定。"""
    try:
        started_at = datetime.fromisoformat(rollcall_time.replace("Z", "+00:00"))
        if started_at.tzinfo is None:
            started_at = started_at.replace(tzinfo=timezone(timedelta(hours=8)))
        return started_at
    except (AttributeError, TypeError, ValueError, OverflowError):
        raise RollcallQueryError("签到时间缺失或格式有误，无法确定签到查询日期") from None


def get_rollcall_date(rollcall_time):
    """返回新接口要求的 UTC 日期，与界面显示的北京时间分开。"""
    try:
        return _parse_rollcall_time(rollcall_time).astimezone(timezone.utc).date().isoformat()
    except (ValueError, OverflowError):
        raise RollcallQueryError("签到时间超出支持范围，无法确定签到查询日期") from None


def _parse_query_date(rollcall_date):
    try:
        if not isinstance(rollcall_date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", rollcall_date):
            raise ValueError
        return date.fromisoformat(rollcall_date)
    except (TypeError, ValueError):
        raise RollcallQueryError("查询日期有误，请使用 YYYY-MM-DD 格式的有效日期") from None


def get_timetable_rollcalls(course_id, rollcall_date, cookie):
    """读取指定课程、UTC 日期的签到条目，仅排除明确属于其他课程的数据。"""
    _parse_query_date(rollcall_date)
    try:
        resp = requests.get(
            f"{BASE_URL}/api/timetable_rollcalls",
            headers={**HEADERS_BASE, "cookie": cookie},
            params={"course_ids": course_id, "rollcall_date": rollcall_date},
            timeout=15,
            allow_redirects=False,
        )
    except requests.Timeout:
        raise RollcallQueryError("签到查询超时，请稍后重试") from None
    except requests.RequestException:
        raise RollcallQueryError("签到查询失败，请检查网络后重试") from None
    data = _query_data(resp, "签到")
    if not isinstance(data, dict) or not isinstance(data.get("rollcalls"), list):
        raise RollcallQueryError("签到查询返回的数据格式有误")
    records = []
    for rollcall in data["rollcalls"]:
        if not isinstance(rollcall, dict):
            raise RollcallQueryError("签到查询返回的数据格式有误")
        course = rollcall.get("course")
        returned_course_id = course.get("id") if isinstance(course, dict) else None
        if returned_course_id is None:
            returned_course_id = rollcall.get("course_id")
        if returned_course_id is not None and str(returned_course_id) != str(course_id):
            continue
        records.append(rollcall)
    return records


def get_daily_rollcalls(course_id, rollcall_date, cookie):
    """按北京时间查询完整一天，合并两个 UTC 日期并剔除相邻日记录。"""
    local_day = _parse_query_date(rollcall_date)
    try:
        utc_days = (local_day - timedelta(days=1), local_day)
    except OverflowError:
        raise RollcallQueryError("查询日期超出支持范围") from None
    school_timezone = timezone(timedelta(hours=8))
    records, seen = [], set()
    for utc_day in utc_days:
        for record in get_timetable_rollcalls(course_id, utc_day.isoformat(), cookie):
            try:
                started_at = _parse_rollcall_time(record.get("rollcall_time") or record.get("created_at"))
                record_day = started_at.astimezone(school_timezone).date()
            except (ValueError, OverflowError):
                raise RollcallQueryError("签到时间超出支持范围，无法确定所属日期") from None
            if record_day != local_day:
                continue
            record_id = record.get("id") or record.get("rollcall_id")
            if not isinstance(record_id, (str, int)) or isinstance(record_id, bool) or not str(record_id).strip():
                raise RollcallQueryError("签到查询返回的签到编号有误")
            key = str(record_id)
            if key not in seen:
                seen.add(key)
                records.append(record)
    return records


def get_timetable_rollcall(course_id, rollcall_id, rollcall_time, cookie):
    """按发起时间的 UTC 日期、课程和签到 ID 匹配，不回退到旧详情接口。"""
    if not isinstance(rollcall_id, (str, int)) or isinstance(rollcall_id, bool) or not str(rollcall_id).strip():
        raise RollcallQueryError("签到编号缺失或格式有误，无法查询本次签到")
    rollcall_date = get_rollcall_date(rollcall_time)
    for rollcall in get_timetable_rollcalls(course_id, rollcall_date, cookie):
        if str(rollcall.get("id") or rollcall.get("rollcall_id")) == str(rollcall_id):
            return rollcall
    raise RollcallQueryError("该日期的查询结果中未找到本次签到，请重新选择课程重试")


def get_timetable_number_code(course_id, rollcall_id, rollcall_time, cookie):
    """按签到发起日和 ID 查询，返回 (number_code, status, end_time)。"""
    rollcall = get_timetable_rollcall(course_id, rollcall_id, rollcall_time, cookie)
    # 仅使用签到条目本身的状态，不读取 student_rollcalls 中的个人状态。
    return rollcall.get("number_code"), rollcall.get("status"), rollcall.get("end_time")


def summarize_attendance(rollcall):
    """返回去重人数及状态分布，不返回学生身份或名单。

    明确出勤归为 signed，只有 absent 归为 unsigned，其他归为 unknown。
    同一学生存在不同状态时归为 conflict，计入 unknown，不猜测最终状态。
    缺失学生 ID 时按记录 ID 去重；两种 ID 都缺失时按独立条目计数。
    """
    students = rollcall.get("student_rollcalls") if isinstance(rollcall, dict) else None
    if not isinstance(students, list) or any(not isinstance(row, dict) for row in students):
        raise RollcallQueryError("签到查询未返回有效学生名单，无法统计人数")
    states = {}
    for index, student in enumerate(students):
        identity = None
        for field in ("student_id", "id"):
            value = student.get(field)
            if isinstance(value, (str, int)) and not isinstance(value, bool) and str(value).strip():
                identity = (field, str(value))
                break
        if identity is None:
            identity = ("row", index)
        status = student.get("status")
        if status is None:
            status = student.get("rollcall_status")
        status = status.strip().lower() if isinstance(status, str) and status.strip() else "unknown"
        states.setdefault(identity, set()).add(status)

    signed_statuses = {"on_call", "on_call_fine", "on_call_late", "present", "attended", "late"}
    summary = {"total": len(states), "signed": 0, "unsigned": 0, "unknown": 0, "status_counts": {}}
    for statuses in states.values():
        status = next(iter(statuses)) if len(statuses) == 1 else "conflict"
        if status in signed_statuses:
            summary["signed"] += 1
        elif status == "absent":
            summary["unsigned"] += 1
        else:
            summary["unknown"] += 1
        summary["status_counts"][status] = summary["status_counts"].get(status, 0) + 1
    summary["status_counts"] = dict(sorted(summary["status_counts"].items()))
    return summary

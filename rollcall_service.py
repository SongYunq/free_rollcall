"""畅课登录与查询业务层，供命令行及后续脚本直接调用。

查询沿用原接口参数、数据解析和返回值；此模块不依赖 UI、不读取终端输入。
登录使用 Playwright 异步 API，查询使用 requests 同步 API。
调用端负责事件循环、后台线程、用户提示与结果展示。
"""

import asyncio
import re

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

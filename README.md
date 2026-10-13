# free_rollcall

面向作者个人使用的畅课（Tronclass）课程与签到查询工具，适配作者所在高校的教学平台。
可查询本学期课程、指定日期的签到记录、数字签到码和签到人数。目前以 Python 源码工程维护，
以命令行和独立业务层为维护重点，当前不维护打包配置。

本项目仅供技术交流与个人学习使用，请遵守学校相关管理规定与教学秩序。

## 代码结构

```text
rollcall_service.py       业务层：登录、学期、课程、签到查询和人数统计
free_rollcall_cli.py      命令行入口：命令解析、账号配置、登录选择和结果展示
free_rollcall_app.py      历史桌面源码：保留，停止维护，尚未适配新登录接口
terminal_log.py           共用终端日志配色
account.example.json     空白账号模板，随仓库提交
account.json             本机默认账号，首次运行生成，不随仓库提交
requirements.txt         运行依赖
tests/                   命令行与业务查询的离线测试
project_docs/            使用说明、环境说明、工作流和历史记录
```

命令行调用 `rollcall_service` 完成业务，通过 `terminal_log` 输出终端日志。
业务层不读取账号文件或终端输入，不依赖命令行入口和日志配色模块。
原独立脚本 `check.py` 已由统一的 `attendance` 命令替代，不再保留。
历史桌面源码、iOS、安卓和其他历史子目录不参与本次命令行改造，没有统一启动脚本。

完整命令与示例见 **[CLI_USAGE.md](project_docs/CLI_USAGE.md)**，环境说明见
[ENVIRONMENT.md](project_docs/ENVIRONMENT.md)，版本管理约定见
[GIT_WORKFLOW.md](project_docs/GIT_WORKFLOW.md)。项目说明和过程文档统一放在
`project_docs/`，根目录仅保留作为项目入口的 README。
首次拆分的历史记录见 [REFACTOR_PLAN.md](project_docs/REFACTOR_PLAN.md)。

## 快速开始

使用 Python 3.11+，在项目根目录创建环境并安装依赖：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m playwright install chromium
```

以上路径适用于 macOS / Linux；Windows 将 `.venv/bin/python` 替换为
`.venv/Scripts/python.exe`。已有项目环境时，不必重复安装。
仅运行命令行或业务层可只安装 `requests`、`playwright`、`PySocks`，无需桌面界面依赖。

将根目录的 `account.example.json` 复制为同目录的 `account.json`，填写：

```json
{
  "username": "你的账号",
  "password": "你的密码"
}
```

账号文件不随仓库提交，登录会话不保存到磁盘。新电脑需填写自己的账号，正常更新代码不会改写它。
文件始终位于 `free_rollcall_cli.py` 旁边，从其他目录启动也使用相同位置。

```bash
# 查看帮助，不登录、不读取账号文件
.venv/bin/python -B free_rollcall_cli.py help

# 交互使用：登录后显示本学期课程，进入命令提示符
.venv/bin/python -B free_rollcall_cli.py

# 执行一条命令后退出，适合脚本调用
.venv/bin/python -B free_rollcall_cli.py courses
.venv/bin/python -B free_rollcall_cli.py code --course-id 110405
.venv/bin/python -B free_rollcall_cli.py attendance --course-id 110405
```

无参数启动时，有效默认账号存在则等待 2 秒，按 Enter 改为手动输入，否则使用默认账号。
登录后可以输入 `help`、`courses`、`rollcalls 1`、`code 1`、`attendance 1` 等命令；
直接输入课程列表序号等同于 `code 序号`，保留原先选课查码的用法。
输入 `exit`、`quit` 或直接按 Enter 退出。

带子命令启动时，默认直接使用账号文件登录，不倒计时，也不等待人工输入。
需要人工登录时可显式使用 `--manual-login`，放在子命令前，例如：

```bash
.venv/bin/python -B free_rollcall_cli.py --manual-login attendance --course-id 110405
```

手动输入的密码可见，不校验账号格式；连续 3 次凭证错误后打开网页登录。
其他登录规则、命令参数与退出码见 [使用说明](project_docs/CLI_USAGE.md)。

## 查询命令

| 命令 | 作用 | 未指定日期时 |
| --- | --- | --- |
| `help [命令]` | 查看全部或某个命令的帮助 | 不需要登录 |
| `courses` | 查询或刷新本学期课程列表 | 不接收日期 |
| `rollcalls` | 列出某课程一天内的签到记录 | 今天，北京时间 |
| `code` | 查看某次数字签到码及状态 | 课程最新一次签到 |
| `attendance` | 查看某次签到的人数汇总 | 课程最新一次签到 |

课程可通过列表序号或 `--course-id` 指定；二者不能混用，真实课程 ID 不能当作序号。
`code`、`attendance` 支持 `--date YYYY-MM-DD`，当天有多次签到时默认取最新一项，
也可同时指定 `--rollcall-id` 精确选择。

人数汇总展示统计人数、已签到、未签到或缺勤、其他或未知及具体状态计数，不显示或保存学生明细。
统计范围仅为本次接口返回的名册，不保证等于课程选课人数。
进行中的 `absent` 显示为“未签到”，结束后显示为“缺勤”；未知或冲突状态不会计入缺勤。
这些命令仅查询，不提交签到。

## 接口调用关系

| 场景 | 调用接口 |
| --- | --- |
| 查询本学期课程 | 原 `/api/current-semester-info` 和 `/api/my-courses`，课程按页取全并去重 |
| 未指定日期，确定课程最新一次签到 | 原 `/api/course/{course_id}/student/{student_id}/rollcalls?page=1&page_size=99` |
| 查询一天的签到列表、读取签到码、获取人数统计的名单 | 新 `/api/timetable_rollcalls?course_ids=<course_id>&rollcall_date=<yyyy-mm-dd>` |

未指定日期时，先从学生签到列表取得最新签到编号与时间，再用该时间的北京时间日期和签到编号
匹配新接口；指定日期则直接请求新接口。签到码保留前导零。
命令行不调用旧 `/api/rollcall/{rollcall_id}/student_rollcalls`，查询失败也不回退到它。
旧接口只保留给历史桌面源码；iOS 和安卓有各自独立的查询实现，本次不调整。

## 业务层接口

| 函数 | 用途 |
| --- | --- |
| `await login_and_get_cookie(username, password, ...)` | 后台认证，返回 `(cookie, student_id)` |
| `await login_in_browser(...)` | 等待人工网页登录，返回 `(cookie, student_id)` |
| `get_current_semester_info(cookie, ...)` | 查询学期，返回 `(semester_id, academic_year_id)` |
| `get_courses(cookie, semester_id, academic_year_id, ...)` | 分页查询本学期课程，按课程 ID 去重 |
| `get_latest_rollcall_id(course_id, cookie, student_id)` | 获取最新签到编号与发起时间，无记录时返回 `(None, None)` |
| `get_timetable_rollcalls(course_id, rollcall_date, cookie)` | 通过课程日期接口查询签到列表 |
| `get_timetable_rollcall(course_id, rollcall_id, rollcall_time, cookie)` | 从课程日期接口匹配指定签到记录 |
| `get_timetable_number_code(course_id, rollcall_id, rollcall_time, cookie)` | 保留现有调用方式，返回 `(number_code, status, end_time)` |
| `summarize_attendance(rollcall)` | 汇总人数与状态，不发起网络请求 |
| `get_number_code(rollcall_id, cookie)` | 历史桌面端保留的旧接口，命令行不使用 |

登录为异步函数，其余查询为同步函数。业务层默认静默；登录、学期和课程函数支持 `log` 回调。
`login_and_get_cookie` 只尝试一次认证，重试和三次失败限制由命令行负责。
凭证被拒绝抛出 `InvalidCredentialsError`；额外认证默认打开网页，传入
`allow_browser_fallback=False` 则抛出 `BrowserLoginRequired`；其他登录异常抛出
`LoginError`。前两者均继承 `LoginError`。调用者应检查返回的登录凭证与学生 ID 是否完整。
查询失败使用 `RollcallQueryError`，交互模式提示后允许继续输入命令，单次模式返回非零退出码。

## 当前边界

学期获取失败仍沿用 `29` / `12`；课程列表现已分页读取，不再只显示前 30 条。
未指定日期查询最新签到时，学生签到列表仍查询第一页、最多 99 条并取列表最后一项。
按日期查询只覆盖指定日期，新命令不自动遍历全部历史日期。
这些规则仍需结合实际在线使用确认。

尚不提供会话持久化、结构化输出或自动签到；旧桌面端需要使用时需重新适配业务层。
`dist/`、`backups/`、虚拟环境和缓存已由 `.gitignore` 排除，不随源码提交。

## 本地检查

```bash
# 导入检查：不启动浏览器或桌面窗口
.venv/bin/python -B -c "import rollcall_service, free_rollcall_cli, terminal_log"

# 查看命令帮助：不读取账号文件，不访问学校服务
.venv/bin/python -B free_rollcall_cli.py --help
.venv/bin/python -B free_rollcall_cli.py help attendance

# 使用模拟响应测试，不读取账号文件或访问学校服务
.venv/bin/python -B -m unittest discover -s tests -p 'test_*.py'
```

`-B` 避免写入字节码缓存。离线测试不能替代真实账号的登录与查询验证。
历史文档中的测试结果只对应当时版本；登录改造记录见
[CLI_ACCOUNT_LOGIN_PLAN.md](project_docs/CLI_ACCOUNT_LOGIN_PLAN.md)。

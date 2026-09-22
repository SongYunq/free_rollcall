# free_rollcall

面向作者个人使用的畅课（Tronclass）数字签到码查询工具，适配作者所在高校的教学平台。
目前以 Python 源码工程维护，
以命令行和独立业务层为维护重点，当前不维护打包配置。

本项目仅供技术交流与个人学习使用，请遵守学校相关管理规定与教学秩序。

## 代码结构

```text
rollcall_service.py       业务层：自动登录、网页登录、学期、课程与签到查询
free_rollcall_cli.py      命令行入口：账号配置、登录选择、重试、菜单和结果展示
free_rollcall_app.py      历史桌面源码：保留，停止维护，尚未适配新登录接口
terminal_log.py           共用终端日志配色
account.example.json     空白账号模板，随仓库提交
account.json             本机默认账号，首次运行生成，不随仓库提交
requirements.txt         运行依赖
project_docs/            项目文档：环境说明、工作流和历史拆分记录
```

命令行调用 `rollcall_service` 完成业务，通过 `terminal_log` 输出终端日志。
业务层不读取账号文件或终端输入，不依赖命令行入口和日志配色模块。
桌面文件保留，但不再保证与新业务层兼容，需要时从桌面端重新适配；没有统一启动脚本。

环境说明见 [ENVIRONMENT.md](project_docs/ENVIRONMENT.md)，版本管理约定见
[GIT_WORKFLOW.md](project_docs/GIT_WORKFLOW.md)，首次拆分的历史记录见
[REFACTOR_PLAN.md](project_docs/REFACTOR_PLAN.md)。项目说明和过程文档统一放在
`project_docs/`，根目录仅保留作为项目入口的 README。

本地保留的旧应用、历史备份及其他平台子目录不属于上述运行链路，本次文档整理不改动它们。
`dist/`、`backups/`、虚拟环境和缓存已由 `.gitignore` 排除，不随源码提交。

## 从源码启动

使用 Python 3.11+，建议在虚拟环境中安装依赖：

```bash
python -m pip install -r requirements.txt
python -m playwright install chromium
```

命令行版：

```bash
python free_rollcall_cli.py
```

登录统一使用 Playwright Chromium，正常情况下在后台完成认证，登录后选择课程查询。
命令行无需启动桌面 UI；单独调用命令行或业务层时可仅安装
`requests`、`playwright`、`PySocks`。

## 默认账号与手动登录

将根目录的 `account.example.json` 复制为同目录的 `account.json`，填写：

```json
{
  "username": "你的账号",
  "password": "你的密码"
}
```

也可以直接首次运行：程序会创建空白 `account.json`、显示完整路径，并在终端提示手动输入。
文件始终位于 `free_rollcall_cli.py` 旁边，从其他目录启动也使用相同位置。
文件格式错误或未填写完整时，会提示问题并改用手动输入，不覆盖原文件。

- 有效默认配置存在时，启动等待 2 秒：按 Enter 手动输入，否则自动使用文件中的账号密码。
- 手动输入的密码可见，不校验学号、邮箱等账号格式，不限制字符种类；账号去除首尾空白，密码保留原样。非空文本交给网站判断，网站自身的限制仍然生效。
- 手动输入仅作用于本次运行，不写回账号文件；空输入重新提示，不计入失败次数。
- 账号密码认证失败后重新输入，连续失败 3 次就打开网页登录页。默认账号的失败也计入这 3 次，网络异常不计为密码错误。
- 网站若要求验证码、账号解锁或额外认证，会提前打开网页，由用户重新登录；后台认证状态不迁移到新窗口。
- 网页登录等待最多 2 分钟，成功后自动回到课程查询流程。
- 真实账号文件已被 `.gitignore` 忽略，模板和说明随仓库提交；新电脑需要填写自己的 `account.json`，正常更新代码不会改写本地配置。

建议在系统终端运行。不支持限时按键的交互终端会退回普通输入选择。
输入被重定向时跳过倒计时，只尝试默认账号一次；缺少配置、凭证错误或需要人工认证时明确报错，
不会自动打开窗口或等待重新输入。课程菜单仍是交互式，本版本不等于完整的无人值守脚本。

## 终端日志

终端日志配色：SUCCESS 绿色、ERROR 红色、WARN 黄色，INFO 保持终端默认颜色。
输出重定向到文件或管道时自动使用普通文本。
设置非空的 `NO_COLOR` 环境变量或使用 `TERM=dumb` 时也会关闭颜色。

## 业务层接口

| 函数 | 返回值 |
| --- | --- |
| `await login_and_get_cookie(username, password, ...)` | 后台认证，返回 `(cookie, student_id)` |
| `await login_in_browser(...)` | 等待人工网页登录，返回 `(cookie, student_id)` |
| `get_current_semester_info(cookie, ...)` | `(semester_id, academic_year_id)`，均为字符串 |
| `get_courses(cookie, semester_id, academic_year_id, ...)` | 去重后的课程字典列表 |
| `get_latest_rollcall_id(course_id, cookie, student_id)` | `(rollcall_id, rollcall_time)`；无记录时为 `(None, None)` |
| `get_number_code(rollcall_id, cookie)` | `(number_code, status, end_time)` |

登录为异步函数，其余查询为同步函数。service 不读取终端输入、不依赖 UI，
默认静默；登录、学期和课程函数支持 `log` 回调，如 `log=print`。
默认后台自动填写并提交，只有人工网页登录需要用户操作。

脚本可以直接调用共用业务接口：

```python
import asyncio
import json
from pathlib import Path
import rollcall_service as service

account_path = Path(service.__file__).resolve().with_name("account.json")
account = json.loads(account_path.read_text(encoding="utf-8"))
cookie, student_id = asyncio.run(service.login_and_get_cookie(
    account["username"], account["password"], log=print,
    allow_browser_fallback=False,
))
if cookie and student_id:
    semester_id, year_id = service.get_current_semester_info(cookie)
    courses = service.get_courses(cookie, semester_id, year_id)
    for course in courses:
        print(course["id"], course.get("display_name") or course.get("name"))
```

`login_and_get_cookie` 只尝试一次账号密码认证，重试和三次失败限制由命令行负责。
凭证被拒绝抛出 `InvalidCredentialsError`；额外认证默认打开网页，传入
`allow_browser_fallback=False` 则抛出 `BrowserLoginRequired`；浏览器或网络异常抛出
`LoginError`。前两者均继承 `LoginError`，调用者可统一捕获或分别处理。
正常结束但未捕获到学生 ID 时仍可能返回空 ID，调用者应检查返回值。
旧 `browser_channels` 参数已移除，登录会话不会保存到磁盘。

## 当前行为与后续工作

目前沿用原有接口和解析规则：学期获取失败使用 `29` / `12`；课程查询第一页、
最多 30 条；签到记录查询第一页、最多 99 条并取列表最后一项。
这些规则仍需结合实际在线使用确认。

当前 CLI 采用交互式菜单。会话持久化、无交互参数、JSON 输出及打包配置等
后续再按需要增加。

## 本地检查

当前没有保留自动化测试脚本。在已安装依赖的环境中，可在项目根目录执行导入检查：

```bash
# 业务层、命令行入口和终端日志
python -B -c "import rollcall_service, free_rollcall_cli, terminal_log"
```

这些命令不启动浏览器或桌面窗口，也不请求校园服务；`-B` 避免写入字节码缓存。
导入成功只说明模块和依赖可加载，不能替代真实账户的登录、选课和签到码查询验证。
历史拆分记录中的测试结果对应当时版本，不代表当前仍保留或运行了那套测试。
本次登录改造的范围与验证记录见 [CLI_ACCOUNT_LOGIN_PLAN.md](project_docs/CLI_ACCOUNT_LOGIN_PLAN.md)。

# free_rollcall

厦门大学畅课（Tronclass）数字签到码查询工具。目前以 Python 源码工程维护，
CLI 和桌面端共用独立业务层，当前不维护打包配置。

本项目仅供技术交流与个人学习使用，请遵守学校相关管理规定与教学秩序。

## 代码结构

```text
rollcall_service.py       共用业务层：登录、学期、课程、签到记录与签到码查询
free_rollcall_cli.py      交互式命令行入口：菜单、结果展示
free_rollcall_app.py      桌面入口：CustomTkinter UI、交互、后台线程
terminal_log.py           共用终端日志配色
requirements.txt         运行依赖
project_docs/            项目文档：环境说明、工作流和历史拆分记录
```

当前维护以上 4 个 Python 源码文件。CLI 和桌面端调用 `rollcall_service` 完成业务，
并通过 `terminal_log` 输出终端日志；业务层不依赖这两个入口或日志配色模块。
CLI 和桌面端分别启动，没有统一启动脚本。

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

桌面版：

```bash
python free_rollcall_app.py
```

命令行版：

```bash
python free_rollcall_cli.py
```

两版均通过浏览器完成统一身份认证，登录后选择课程查询，当前仍需交互登录。
桌面版依次尝试系统 Edge、Chrome、Playwright Chromium；CLI 保持直接使用
Playwright Chromium。CLI 无需启动桌面 UI；单独调用 CLI/service 时可仅安装
`requests`、`playwright`、`PySocks`。

终端日志配色：SUCCESS 绿色、ERROR 红色、WARN 黄色，INFO 保持终端默认颜色。
CLI 和桌面端的终端输出共用此规则；输出重定向到文件或管道时自动使用普通文本。
设置非空的 `NO_COLOR` 环境变量或使用 `TERM=dumb` 时也会关闭颜色。

## 业务层接口

| 函数 | 返回值 |
| --- | --- |
| `await login_and_get_cookie(...)` | `(cookie, student_id)` |
| `get_current_semester_info(cookie, ...)` | `(semester_id, academic_year_id)`，均为字符串 |
| `get_courses(cookie, semester_id, academic_year_id, ...)` | 去重后的课程字典列表 |
| `get_latest_rollcall_id(course_id, cookie, student_id)` | `(rollcall_id, rollcall_time)`；无记录时为 `(None, None)` |
| `get_number_code(rollcall_id, cookie)` | `(number_code, status, end_time)` |

登录为异步函数，其余查询为同步函数。service 不读取终端输入、不依赖 UI，
默认静默；登录、学期和课程函数支持 `log` 回调，如 `log=print`。
浏览器登录本身仍需要用户操作。

脚本可以直接调用共用业务接口：

```python
import asyncio
import rollcall_service as service

cookie, student_id = asyncio.run(service.login_and_get_cookie(log=print))
if cookie and student_id:
    semester_id, year_id = service.get_current_semester_info(cookie)
    courses = service.get_courses(cookie, semester_id, year_id)
    for course in courses:
        print(course["id"], course.get("display_name") or course.get("name"))
```

`login_and_get_cookie` 默认直接启动 Chromium，启动失败时抛出异常；传入
`browser_channels=("msedge", "chrome")` 时采用桌面版的回退流程，全部启动失败
返回 `(None, None)`。正常结束但未捕获到学生 ID 时也可能返回空 ID，调用者应检查凭证。

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

# 桌面模块，需要 CustomTkinter 和 Tcl/Tk
python -B -c "import free_rollcall_app"
```

这些命令不启动浏览器或桌面窗口，也不请求校园服务；`-B` 避免写入字节码缓存。
导入成功只说明模块和依赖可加载，不能替代真实账户的登录、选课和签到码查询验证。
历史拆分记录中的测试结果对应当时版本，不代表当前仍保留或运行了那套测试。

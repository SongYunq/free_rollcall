# free_rollcall

厦门大学畅课（Tronclass）数字签到码查询工具。目前以 Python 源码工程维护，
CLI 和桌面端共用独立业务层；本轮不构建或更新已封装的应用。

本项目仅供技术交流与个人学习使用，请遵守学校相关管理规定与教学秩序。

## 代码结构

```text
rollcall_service.py       共用业务层：登录、学期、课程、签到记录与签到码查询
free_rollcall_cli.py      交互式命令行入口：菜单、结果展示
free_rollcall_app.py      桌面入口：CustomTkinter UI、交互、后台线程
terminal_log.py           共用终端日志配色
test_rollcall_service.py  离线回归测试：模拟接口、浏览器与 CLI 操作
requirements.txt         运行依赖
project_docs/            项目文档：环境说明、拆分计划与验证记录
backups/                 重构前的顶层源码、配置和文档备份
rollcall_capturer.py      暂留的独立旧脚本，不属于当前调用链
```

调用关系：`CLI / 桌面 UI → rollcall_service → Playwright / requests`。
统一入口 `free_rollcall.py` 和旧打包配置 `free_rollcall.spec` 已移除。
原有子目录（包括旧应用、其他平台内容和资源）保持原样，本轮未纳入迁移或验证。

环境说明见 [ENVIRONMENT.md](project_docs/ENVIRONMENT.md)，拆分计划和验证记录见
[REFACTOR_PLAN.md](project_docs/REFACTOR_PLAN.md)。后续项目说明和过程文档统一放在
`project_docs/`，根目录仅保留作为项目入口的 README。

重构前的备份已保存在 [backups/2026-09-16-before-service/](backups/2026-09-16-before-service/)，
包含当时备份的顶层源码、配置、文档，以及对照记录 `baseline.json` 和 `refactor.diff`；
它不是整个项目的完整副本，不包含虚拟环境或已打包 App。

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

## 本轮保留的行为与后续工作

本轮只拆分业务层，没有调整接口、请求参数、等待时间和解析策略。例如：
学期获取失败仍使用 `29` / `12`；课程仍查询第一页、最多 30 条；签到记录仍查询
第一页、最多 99 条并取列表最后一项；现有异常处理方式保持不变。
这些是沿用行为，不代表已经验证线上接口仍满足这些假设。

CLI 的业务日志措辞统一到共用实现，菜单和结果格式保留。会话持久化、无交互参数、
JSON 输出及打包配置等后续再按需要增加。

## 离线验证

在项目根目录执行：

```bash
python -B -m unittest -v test_rollcall_service
```

测试模拟接口返回、浏览器流程和 CLI 输入，不启动真实浏览器、不请求校园服务。
`-B` 避免写入字节码缓存。离线测试不能替代真实账户的登录与查询验证。

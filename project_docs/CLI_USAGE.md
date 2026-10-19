# 命令行使用说明

`free_rollcall_cli.py` 提供交互模式和单次命令模式，共用 `rollcall_service.py` 的登录与查询能力。
原 `check.py` 的签到人数查询已合并为 `attendance` 命令，不再维护独立脚本。
命令行查询课程、签到记录、签到码和人数，不提交签到。

以下命令在项目根目录执行，使用 macOS / Linux 的项目解释器路径。
Windows 将 `.venv/bin/python` 替换为 `.venv/Scripts/python.exe`。
首次安装依赖和浏览器的方法见 [ENVIRONMENT.md](ENVIRONMENT.md)。

## 1. 准备账号

将根目录的 `account.example.json` 复制为 `account.json`，填写自己的账号密码：

```json
{
  "username": "你的账号",
  "password": "你的密码"
}
```

账号文件始终位于入口脚本旁边，从其他工作目录启动也使用同一份文件。
文件不随仓库提交，模板随仓库提供。首次普通运行缺少文件时，程序创建空白文件并显示其完整路径。
已有文件无论有效与否都不会被覆盖。显式 `--manual-login` 不读取或创建账号文件。

手动输入的账号去除首尾空白，密码保留原样且可见；不校验学号、邮箱等账号形式。
空账号或空密码会重新提示，不计为一次登录失败；非空内容交给学校认证系统判断。
手动输入只用于本次运行，不写回账号文件。登录会话不保存到磁盘。

## 2. 先看帮助

以下操作不登录、不读取或创建账号文件：

```bash
.venv/bin/python -B free_rollcall_cli.py help
.venv/bin/python -B free_rollcall_cli.py --help
.venv/bin/python -B free_rollcall_cli.py help attendance
.venv/bin/python -B free_rollcall_cli.py attendance --help
```

`-h` 与 `--help` 等效。命令拼写或参数格式错误会给出用法，不会先进行登录。
课程序号是否超出列表范围则需要登录并获取课程后才能检查。

## 3. 交互模式

```bash
.venv/bin/python -B free_rollcall_cli.py
```

如果配置中已有有效账号，启动后等待 2 秒：按 Enter 手动输入，不操作就使用默认账号。
没有配置或配置有误时，程序提示手动输入。登录成功后显示本学期课程列表，进入 `free_rollcall>` 提示符。

例如课程列表第一项是目标课程，可依次输入：

```text
free_rollcall> help
free_rollcall> courses
free_rollcall> code 1
free_rollcall> attendance 1
free_rollcall> rollcalls 1 --date 2026-10-08
free_rollcall> attendance 1 --date 2026-10-08 --rollcall-id 441597
free_rollcall> exit
```

- `courses` 重新获取并显示本学期课程，随后输入的序号以这次列表为准
- 直接输入 `1` 等同于 `code 1`，保留原先输入课程编号查码的用法
- `help attendance` 显示该命令的具体用法
- 输入 `exit`、`quit` 或直接按 Enter 退出
- 参数有误或一次查询失败时提示错误，仍可继续输入其他命令

本次交互过程共用同一次登录；登录失效或需要切换账号时退出后重新运行。
人数每次执行 `attendance` 时重新查询，不会自动定时刷新。

## 4. 单次命令模式

在启动命令后直接写子命令，完成后自动退出：

```bash
# 本学期课程列表
.venv/bin/python -B free_rollcall_cli.py courses

# 第一门课程最新一次签到码
.venv/bin/python -B free_rollcall_cli.py code 1

# 按真实课程 ID 查询最新一次签到人数
.venv/bin/python -B free_rollcall_cli.py attendance --course-id 110405

# 指定日期的签到记录列表
.venv/bin/python -B free_rollcall_cli.py rollcalls --course-id 110405 --date 2026-10-08

# 精确查看当天某条签到的签到码或人数
.venv/bin/python -B free_rollcall_cli.py code --course-id 110405 --date 2026-10-08 --rollcall-id 441597
.venv/bin/python -B free_rollcall_cli.py attendance --course-id 110405 --date 2026-10-08 --rollcall-id 441597
```

每次启动独立登录，默认只尝试文件中的账号，不进行 2 秒倒计时，也不等待终端输入或人工网页登录。
缺少有效配置、账号密码错误或学校要求额外认证时，提示原因并以非零退出码结束，适合后续脚本调用。
需要人工处理时，在交互终端中显式添加全局参数 `--manual-login`，必须放在子命令前：

```bash
.venv/bin/python -B free_rollcall_cli.py --manual-login attendance --course-id 110405
```

这会直接提示输入账号和密码，允许凭证错误后的重试与人工网页登录。
不支持将账号密码作为命令参数传入。当前输出为供人阅读的文本，不提供结构化输出选项。

## 5. 命令与参数

| 命令 | 参数 | 含义 |
| --- | --- | --- |
| `help` | `[命令]` | 查看总帮助或指定命令帮助 |
| `courses` | 无 | 查询或刷新本学期课程列表 |
| `rollcalls` | `课程序号` 或 `--course-id ID`，可加 `--date YYYY-MM-DD` | 列出指定课程当天的签到记录，默认今天 |
| `code` | 课程选择，可加 `--date`、`--rollcall-id` | 查看选定签到的数字码及状态 |
| `attendance` | 课程选择，可加 `--date`、`--rollcall-id` | 查看选定签到的人数与状态汇总 |
| `exit` / `quit` | 无，仅交互模式 | 退出程序 |

### 课程选择

`code 1` 的 `1` 是课程列表中从 1 开始的序号；`code --course-id 110405` 的 `110405` 是平台的真实课程 ID。
二者只选一种，不能同时提供。使用真实 ID 可避免课程排序变化导致选错课程，适合脚本使用。
单次模式使用序号时也会先查询本学期课程列表，再按序号选择。

### 日期和签到选择

命令中输入的日期与显示时间按北京时间（UTC+8）理解，与电脑本地时区无关。
接口本身按 UTC 日期筛选，程序会自动转换，无需手动把 `--date` 改成前一天。
例如北京时间 `2026-10-15 07:56` 的签到，接口查询日期实际是 `2026-10-14`，
在命令中仍使用 `--date 2026-10-15`。

- `rollcalls` 无 `--date` 时查询今天；它只列出这一天，不自动遍历全部历史日期
- `code`、`attendance` 无 `--date` 时查询课程最新一次签到；如果最新签到是几天前，仍会查询那一天
- `code`、`attendance` 有 `--date` 时，默认选择当天发起时间最新的一次签到，不依赖接口排序
- 需要查询同一天的其他签到，先运行 `rollcalls` 查看签到 ID，再同时传入 `--date` 与 `--rollcall-id`
- `--rollcall-id` 不能脱离 `--date` 单独使用，签到需在所选课程和日期的响应中匹配
- 日期必须使用 `YYYY-MM-DD` 格式，例如 `2026-10-08`

按日查询会读取北京时间当天覆盖的两个 UTC 日期，再按发起时间保留当天记录并按签到编号去重。
任一日期请求失败都会提示错误，避免把只读取到一部分的记录当作完整结果。

示例 ID 仅说明参数形式，实际使用时替换为有权限查看的课程和签到 ID。
某天没有签到或课程尚无签到时会说明无记录；指定签到不在查询结果中时会提示查询失败。
非数字签到可能没有数字签到码，界面会明确说明，不把空值显示成一个可用签到码。

## 6. 签到人数的含义

`attendance` 使用新课程日期接口中的 `student_rollcalls` 汇总，不使用旧详情接口。
输出课程、签到编号、时间、状态，以及人数汇总和具体状态分布，不显示或保存学生明细。

| 项目 | 计算方式 |
| --- | --- |
| 统计人数 | 本次接口返回名单按学生去重后的人数 |
| 已签到 | 状态为 `on_call`、`on_call_fine`、`on_call_late`、`present`、`attended` 或 `late` |
| 未签到 / 缺勤 | 状态为 `absent`；签到结束后称“缺勤”，其他情况下称“未签到” |
| 其他或未知 | 其他状态、缺少状态或同一学生多条记录相互冲突 |

优先按 `student_id` 去重；缺失时按记录 `id` 去重，两种 ID 都缺失则将该条作为独立记录计数。
同一学生重复且状态相同只计一次；状态冲突记为 `conflict`，归入“其他或未知”，不当作缺勤。
状态分布中的 `unknown` 表示缺失或无效状态，其他原始状态分别列出。

统计人数仅代表接口返回名册内人数，不保证等于课程选课人数。
缺少有效出勤名单时会提示无法统计；明确返回空名单时统计人数为 0。
查询结果不是自动签到的成功回执。

## 7. 登录与错误处理

交互启动或显式 `--manual-login` 时：

- 账号密码认证失败后重新输入，连续失败 3 次打开网页登录，默认账号的失败也计入这 3 次
- 网络问题不计为密码错误
- 验证码、账号解锁或其他额外认证可能提前转入网页，需在新窗口中重新登录
- 网页登录等待最多 2 分钟，成功后继续执行原命令或进入交互模式
- 不支持限时按键的终端会退回普通输入选择

后台自动登录使用 Playwright Chromium，正常情况下不会显示浏览器窗口。
输入被重定向时不等待人工登录；自动化使用应明确选择单次子命令。

单次命令的退出码如下：

| 退出码 | 含义 |
| --- | --- |
| `0` | 命令成功、帮助已显示，或查询结果正常但没有签到记录 |
| `1` | 登录失败、缺少账号配置或查询失败 |
| `2` | 命令或参数有误，包括课程序号超出范围 |
| `130` | 用户按 Ctrl+C 中断运行 |

交互模式内的查询错误会显示提示并返回命令提示符，不立即结束整个程序。
终端日志中 SUCCESS 为绿色、ERROR 为红色、WARN 为黄色，INFO 保持默认颜色。
重定向输出、设置非空 `NO_COLOR` 环境变量或使用 `TERM=dumb` 时关闭颜色。

## 8. 接口与查询边界

| 操作 | 接口与规则 |
| --- | --- |
| 本学期课程 | 原学期接口和 `/api/my-courses`，课程分页获取并去重 |
| 无日期的最新签到定位 | 原 `/api/course/{course_id}/student/{student_id}/rollcalls?page=1&page_size=99`，仍取第一页列表末项 |
| 按日列表、签到码和人数 | 新 `/api/timetable_rollcalls?course_ids=<course_id>&rollcall_date=<yyyy-mm-dd>` |

接口参数 `rollcall_date` 使用 UTC 日期。查询已知签到时只请求其发起时间对应的一天；
命令行按北京时间查询一整天时，请求前一个 UTC 日期和同名 UTC 日期，并过滤相邻日记录。

学期获取失败时沿用 `29` / `12`，无日期的最新签到定位仍受最多 99 条记录与接口排序影响。
可以使用明确的 `--date` 和 `--rollcall-id` 选择历史签到。
命令行不使用旧 `/api/rollcall/{rollcall_id}/student_rollcalls`，失败也不会回退到它。
2026-10-15 的只读实测中，新接口返回了数字签到，但未返回部分普通点名和雷达签到记录。
这类记录仍可能提示未找到；本次日期修复不改变接口覆盖范围，也不会改查另一条签到来代替。

离线测试可执行：

```bash
.venv/bin/python -B -m unittest discover -s tests -p 'test_*.py'
```

测试使用模拟响应，不读取真实账号、不登录学校平台。
真实账号的访问权限、在线响应完整性与实际人数需结合使用核对。

本轮验证记录（2026-10-15）：80 项离线测试通过，覆盖 UTC 日期、北京时间凌晨与早上 8 点边界、
跨年、按日筛选与去重，以及命令行和业务层串联验证。
此前日期不匹配的两门课程已完成 5 次真实只读命令验证，签到码、人数与按日列表查询均成功，
显示时间仍为北京时间；未执行签到。脱敏诊断记录保存在同目录
`CLI_QUERY_DIAGNOSTIC_2026-10-15.log`，日志不提交到版本库。

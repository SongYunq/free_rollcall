# Go 命令行使用说明

Go 版源码位于 `go-cli/`，独立于原来的 `free_rollcall_cli.py` 和 `rollcall_service.py`。
Python 命令行、账号文件、依赖和测试继续保留，两套工具可分别运行。
Go 版只查询课程和签到信息，不提交签到，不输出或保存学生明细。

## 构建与运行

源码构建需要 Go 1.24 或更新版本；运行已经构建好的程序无需安装 Go 或 Python。
登录需要本机 Chrome 或 Chromium，程序默认自动寻找常见安装位置。

在仓库根目录进入 Go 工程：

```bash
cd go-cli
go build -o rollcall ./cmd/rollcall
./rollcall --help
```

Windows 使用 `go build -o rollcall.exe ./cmd/rollcall`，随后运行 `.\rollcall.exe`。
运行 `go run` 时临时可执行文件位于工具链临时目录，因此应显式指定账号目录：

```bash
go run ./cmd/rollcall --config-dir ./accounts courses
```

## 账号文件

默认账号路径为**实际可执行文件旁的 `accounts/account.json`**，不取决于当前工作目录。
例如，程序为 `go-cli/rollcall`，默认读取 `go-cli/accounts/account.json`。
通过符号链接运行时以真实程序位置为准。

```text
go-cli/
  rollcall
  accounts/
    account.example.json   仓库中的空白示例
    account.json           自己填写的账号，不随 Git 提交
```

文件内容：

```json
{
  "username": "你的账号",
  "password": "你的密码"
}
```

缺少账号文件时，程序创建目录和空白 `account.json`，显示完整位置并以退出码 1 结束。
填写后重新运行即可。已有文件不会被覆盖，密码内容不会被去除前后空格。
新建账号目录在支持权限位的系统上使用 0700，文件使用 0600。

也可以指定一个文件夹，程序始终读取其中的 `account.json`：

```bash
./rollcall --config-dir /你的账号目录 courses

# 在 go-cli 目录直接复用 Python 版已有账号
./rollcall --config-dir .. courses
```

两种方式均没有倒计时、按 Enter 切换账号、终端输入密码或 `--manual-login`。
账号文件有误时修改文件再运行，不会自动反复尝试错误密码。
`help`、`--help` 和参数校验失败不会读取账号文件、生成模板或启动浏览器。

## 登录方式

1. 在独立、临时的浏览器环境中打开学校统一认证页面。
2. 仅向学校身份认证来源填入文件中的凭证，使用网页自己的提交和认证逻辑。
3. 返回畅课后，用浏览器中学校站点的登录凭证调用 `/api/profile`。
4. 取得学生编号，并核验资料中的学号或邮箱是否与配置账号一致。
5. 关闭浏览器，使用同一个网络客户端继续查询。

不再导航第一门课的签到页面，不监听 `/student/.../rollcalls` 请求以提取学生编号，
也不保留旧流程登录成功后的固定 1 秒等待。
浏览器会话不保存到磁盘；交互模式在同一次运行中复用登录，独立运行命令仍需重新认证。

正常登录不显示浏览器窗口。遇到验证码或额外认证时，默认报错退出，按提示显式显示浏览器：

```bash
./rollcall --show-browser courses
```

账号密码仍由文件填入；在网页中完成学校要求的验证码或其他验证即可。
不会绕过学校验证。默认后台认证总时限 60 秒；显示浏览器时总时限 240 秒，
额外验证阶段最多 180 秒。

浏览器未能自动找到时，指定浏览器可执行文件，例如 macOS：

```bash
./rollcall --browser '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' courses
```

## 查询命令

```bash
./rollcall                          # 登录后显示课程并进入交互模式
./rollcall courses                  # 本学期课程
./rollcall rollcalls 1              # 第 1 门课程今天的签到列表
./rollcall code 1                   # 第 1 门课程最新一次签到码
./rollcall attendance 1             # 第 1 门课程最新一次签到人数
./rollcall help attendance

./rollcall code --course-id 110405 --date 2026-10-08
./rollcall attendance --course-id 110405 --date 2026-10-08 --rollcall-id 441597
```

课程列表序号和真实 `--course-id` 二选一。日期严格使用 `YYYY-MM-DD`；
`--rollcall-id` 仅用于 `code`、`attendance`，必须同时提供 `--date`。
全局参数 `--config-dir`、`--browser`、`--show-browser` 可放在子命令前后。

交互模式使用相同查询规则：输入裸序号等同于 `code 序号`，`courses` 刷新列表，
`help` 查看帮助，`exit`、`quit` 或空行退出。查询失败后可以继续输入。
切换账号目录或浏览器选项需要退出后重新启动。

## 查询规则与 Python 版的边界

- 课程分页读取、按编号去重；查询共享网络连接与登录凭证，请求超时为 15 秒。
- 日期输入和显示采用北京时间；按日查询并行请求覆盖该日的两个 UTC 日期，
  按发起时间过滤并按签到编号去重。任一天失败均报错，不展示部分结果。
- 未指定日期仍查询课程学生签到列表的第一页、最多 99 项，并取最后一项定位最新签到。
  因而仍依赖学校接口的排序与覆盖范围。
- 签到码保留前导零；签到信息只使用新课程日期接口，不回退旧详情接口。
- 人数按学生去重；冲突或未知状态归入其他或未知，不推断为缺勤。统计范围仅为接口返回名单。
- 获取当前学期失败时 Go 版直接报错，**不会沿用 Python 的固定学期默认值 29/12**。
- Go 版日志不输出终端颜色；业务结果和退出码沿用原有约定。

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功、帮助，或正常无记录 |
| 1 | 配置、认证、网络或查询失败 |
| 2 | 命令和参数错误 |
| 130 | Ctrl+C 中断 |

## 代码结构

```text
go-cli/cmd/rollcall/      入口与中断处理
go-cli/internal/cli/     参数、交互输入、输出与查询编排
go-cli/internal/store/   账号文件定位、读取和空白模板创建
go-cli/internal/auth/    浏览器认证、验证码处理与 profile 身份确认
go-cli/internal/client/  学校接口、共享连接、分页与并行日期查询
go-cli/internal/rollcall/模型、日期规则和人数统计
```

认证和查询均为 Go 实现，未调用 Python 子进程。浏览器由 chromedp 控制，
模块版本与校验信息记录在 `go.mod`、`go.sum`。

## 测试与跨平台构建

在 `go-cli` 目录运行：

```bash
go test -race ./...
go vet ./...

# 可选：仅本机模拟网页和虚构账号，不访问学校
ROLLCALL_BROWSER_TEST=1 go test -race ./internal/auth -run TestLocalBrowserAuthentication -v

# 以下交叉构建命令适用于 macOS / Linux shell
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o ../dist/go-cli/rollcall-macos-arm64 ./cmd/rollcall
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o ../dist/go-cli/rollcall-windows-amd64.exe ./cmd/rollcall
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../dist/go-cli/rollcall-linux-amd64 ./cmd/rollcall
```

普通测试隔离账号读取、学校服务和真实登录；可选浏览器测试也只连接本机。
其他平台的构建通过不代表已在该平台实际运行。实际学校登录、验证码变化及接口权限
需结合真实使用验证；本地模拟浏览器测试不能替代这些验证。

本轮验证记录（2026-10-21）：Go 全量 `-race` 测试、本机 Chrome 模拟认证测试和
`go vet` 通过；原 Python 的 80 项离线测试全部通过。
已使用原有账号文件完成真实只读登录、课程查询，以及同一交互会话中的按日签到列表、
签到码和人数查询；身份通过 `/api/profile` 获取并核验，未执行签到。
macOS 本机程序可运行，Windows 和 Linux 版本仅验证交叉构建。

# free_rollcall 源码运行环境

当前维护 `rollcall_service.py`、`free_rollcall_cli.py` 和 `terminal_log.py`。
`free_rollcall_app.py` 作为历史桌面源码保留，未适配新的业务层登录接口。
当前不维护打包配置，旧应用与其他子目录不参与源码运行。

## Python 环境

建议使用 Python 3.11+ 和项目虚拟环境。2026-09-16 的本地环境记录为
Python 3.14.7，这只是当时环境信息，不是项目的固定版本要求。
本次文档整理不安装、升级或删除依赖。

新环境可按需初始化：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m playwright install chromium
```

以上路径写法适用于 macOS / Linux；Windows 虚拟环境解释器位于
`.venv/Scripts/python.exe`。

## 依赖用途

| 依赖 | 用途 |
| --- | --- |
| requests | 学期、课程和签到接口查询 |
| playwright | 浏览器登录、Cookie 获取、监听学生 ID |
| customtkinter | 桌面 UI，CLI/service 不导入它 |
| PySocks | requests 使用 SOCKS 代理时所需，保留兼容能力 |
| tkinter / Tcl/Tk | 桌面图形界面底层支持，由 Python/系统环境提供 |

`terminal_log.py` 只使用 Python 标准库，无额外依赖。
PyInstaller 不属于源码运行要求；`requirements.txt` 目前未锁定具体版本。

## 启动和验证

```bash
# CLI
.venv/bin/python -B free_rollcall_cli.py

# 导入检查：不启动浏览器或桌面窗口
.venv/bin/python -B -c "import rollcall_service, free_rollcall_cli, terminal_log"
```

`-B` 表示不生成或更新字节码缓存。
命令行使用 Playwright Chromium 后台填写账号密码，业务层只在显式调用登录函数时启动浏览器。
有效默认配置存在时等待 2 秒，Enter 切换到终端明文输入；默认配置位于根目录 `account.json`，
填写方法见 README。连续 3 次凭证错误后打开网页登录；验证码或其他额外认证可以提前转入网页。
命令行不做账号格式正则校验，网站自身的规则仍然生效。
账号文件不随仓库提交，空白模板 `account.example.json` 随仓库提供。

输入被重定向时不倒计时、不打开人工认证窗口；完整无交互课程查询尚未提供。
限时按键使用标准库，macOS / Linux 和 Windows 分别处理；不支持时退回普通输入选择。
桌面端的 CustomTkinter、tkinter / Tcl/Tk 依赖保留作历史参考，本次不清理依赖，
也不再将桌面端启动成功作为当前版本的验证要求。

终端日志中 SUCCESS 为绿色、ERROR 为红色、WARN 为黄色，INFO 保持默认颜色。
重定向输出、非空 `NO_COLOR` 环境变量或 `TERM=dumb` 会关闭颜色。
桌面窗口内的日志文本不带终端颜色控制码。

## 常见环境问题

- 提示缺少 Playwright 浏览器时，使用当前解释器执行
  `python -m playwright install chromium`。
- 提示 `Missing dependencies for SOCKS support` 时，检查当前环境是否安装了
  `PySocks`。
- 提示缺少 `tkinter` 时，需要为当前 Python 安装对应的 Tcl/Tk 支持。
  原环境文档记录采用 Homebrew 的 `python-tk@3.14`；本轮未重新安装或验证系统包。

当前没有保留自动化测试脚本；导入检查仅验证模块和依赖能否加载。
真实登录仍需网络和有效账号；是否要求验证码由学校认证系统决定。
模拟验证不能替代真实账号的登录与查询，实际验证范围见 `CLI_ACCOUNT_LOGIN_PLAN.md`。

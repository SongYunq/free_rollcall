# free_rollcall 源码运行环境

本文件说明当前 4 个源码文件的运行环境：`rollcall_service.py`、
`free_rollcall_cli.py`、`free_rollcall_app.py` 和 `terminal_log.py`。
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
# 桌面端
.venv/bin/python -B free_rollcall_app.py

# CLI
.venv/bin/python -B free_rollcall_cli.py

# 导入检查：不启动浏览器或桌面窗口
.venv/bin/python -B -c "import rollcall_service, free_rollcall_cli, terminal_log"
.venv/bin/python -B -c "import free_rollcall_app"
```

两端分别启动。`-B` 表示不生成或更新字节码缓存。
桌面端保留 Edge → Chrome → Playwright Chromium 的启动顺序；CLI 仍直接启动
Playwright Chromium。业务层只在显式调用登录函数时打开浏览器。

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
真实登录仍需网络和用户在浏览器中完成身份认证，需另行验证查询流程。

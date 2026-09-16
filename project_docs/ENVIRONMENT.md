# free_rollcall 源码运行环境

本文件说明拆分业务层后的源码运行方式。旧应用与其他子目录保持原样；
当前不维护打包配置，不执行构建或清理产物操作。

## Python 环境

建议使用 Python 3.11+ 和项目虚拟环境。本轮检查时，现有 `.venv/bin/python`
为 Python 3.14.7，能够导入 requests、Playwright 和 CustomTkinter。
此次重构没有安装、升级或删除任何依赖，也没有改动虚拟环境。

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

PyInstaller 不属于本轮源码运行要求。环境中已经安装的打包工具保持原样。
依赖版本沿用现有环境，`requirements.txt` 本轮没有修改。

## 启动和验证

```bash
# 桌面端
.venv/bin/python -B free_rollcall_app.py

# CLI
.venv/bin/python -B free_rollcall_cli.py

# 离线回归测试
.venv/bin/python -B -m unittest -v test_rollcall_service
```

统一入口已删除，两端分别启动。`-B` 表示不生成或更新字节码缓存。
桌面端保留 Edge → Chrome → Playwright Chromium 的启动顺序；CLI 仍直接启动
Playwright Chromium。业务层只在显式调用登录函数时打开浏览器。

## 常见环境问题

- 提示缺少 Playwright 浏览器时，使用当前解释器执行
  `python -m playwright install chromium`。
- 提示 `Missing dependencies for SOCKS support` 时，检查当前环境是否安装了
  `PySocks`。
- 提示缺少 `tkinter` 时，需要为当前 Python 安装对应的 Tcl/Tk 支持。
  原环境文档记录采用 Homebrew 的 `python-tk@3.14`；本轮未重新安装或验证系统包。

离线测试不需要校园账户。真实登录仍需网络和用户在浏览器中完成身份认证；
线上联调不属于离线回归结论。

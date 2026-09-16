"""CLI 和桌面端共用的终端日志输出。"""

import os
import sys


_COLORS = {
    "[SUCCESS]": "\033[32m",
    "[ERROR]": "\033[31m",
    "[WARN]": "\033[33m",
}


def log_to_terminal(message: str):
    """按级别着色；INFO 和重定向输出保持普通文本。"""
    if (
        sys.stdout is not None
        and sys.stdout.isatty()
        and not os.environ.get("NO_COLOR")
        and os.environ.get("TERM") != "dumb"
    ):
        for prefix, color in _COLORS.items():
            if message.lstrip().startswith(prefix):
                print(f"{color}{message}\033[0m")
                return
    print(message)

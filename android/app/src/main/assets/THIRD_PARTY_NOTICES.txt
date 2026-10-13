# 第三方代码说明

雷达计算和请求顺序参考 [签到机器人参考项目](https://github.com/KrsMt-0113/XMU-Rollcall-Bot) 的 `xmu-rollcall-cli/xmu_rollcall/verify.py`，参考版本为 `c7de02b11da3433a047bab29dbbbbbb4c855a484`。数字签到请求的字段也参考该文件。

对应移植文件：`app/src/main/java/cn/freerollcall/android/core/RadarSubmission.kt` 和 `TronclassClient.kt`。应用不包含或运行参考项目的定时监控功能。

MIT License

Copyright (c) 2025 KrsMt.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

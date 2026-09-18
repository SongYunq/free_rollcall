"""
free_rollcall 签到助手 - CustomTkinter 桌面版
工作流：
 1. 主页点击“开始登录” -> 启动浏览器 / 完成统一身份认证
 2. 获取认证 Cookie 与 Student ID -> 拉取本学期课程列表 -> 跳转课程页
 3. 选择课程 -> 查询最新签到码 -> 跳转结果页
 4. 结果页可返回课程页继续查询；右上角支持展开详细运行日志
"""

import asyncio
import threading
import customtkinter as ctk
from datetime import datetime, timezone, timedelta

from terminal_log import log_to_terminal
from rollcall_service import (
    get_courses,
    get_current_semester_info,
    get_latest_rollcall_id,
    get_number_code,
    login_and_get_cookie,
)

# ── 颜色 / 字体常量 ────────────────────────────────────────
BG        = "#0F0E17"
SURFACE   = "#1A1828"
SURFACE2  = "#221F33"
ACCENT    = "#4F46E5"
ACCENT_DK = "#4338CA"
TEXT_PRI  = "#FFFFFE"
TEXT_SEC  = "#A7A9BE"
SUCCESS   = "#06D6A0"
WARN      = "#FFD166"
DANGER    = "#EF476F"

# ==============================================================================
# 异步与线程工具
# ==============================================================================

def run_async(coro, callback):
    def _run():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            result = loop.run_until_complete(coro)
            callback(result, None)
        except Exception as e:
            callback(None, e)
        finally:
            loop.close()
    threading.Thread(target=_run, daemon=True).start()


def run_sync_in_thread(fn, callback, *args, **kwargs):
    def _run():
        try:
            result = fn(*args, **kwargs)
            callback(result, None)
        except Exception as e:
            callback(None, e)
    threading.Thread(target=_run, daemon=True).start()


# ==============================================================================
# UI 辅助组件
# ==============================================================================

def make_label(parent, text, size=13, color=TEXT_PRI, bold=False, anchor="w", wraplength=0):
    weight = "bold" if bold else "normal"
    return ctk.CTkLabel(
        parent, text=text, font=("Microsoft YaHei", size, weight),
        text_color=color, anchor=anchor, wraplength=wraplength,
        justify="center" if anchor == "center" else "left",
    )


def make_button(parent, text, command, fg=ACCENT, hover=ACCENT_DK, width=200, height=40, size=13):
    return ctk.CTkButton(
        parent, text=text, command=command,
        fg_color=fg, hover_color=hover, text_color=TEXT_PRI,
        font=("Microsoft YaHei", size, "bold"),
        width=width, height=height, corner_radius=12,
    )


def separator(parent):
    return ctk.CTkFrame(parent, height=1, fg_color=SURFACE2)


# ==============================================================================
# 主应用类
# ==============================================================================

class FreeRollcallApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        # ── 窗口基础设置 ─────────────────────────────
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("dark-blue")
        self.title("free_rollcall - XMU")
        self.geometry("500x700")
        self.resizable(False, False)
        self.configure(fg_color=BG)

        # ── 共享状态 ─────────────────────────────────
        self._cookie     = None
        self._student_id = None
        self._courses    = []
        self._busy       = False

        # ── 日志缓冲 ─────────────────────────────────
        self._log_lines  = []

        # ── 根布局：顶栏 + 内容区 ─────────────────────
        self._build_topbar()
        self._content = ctk.CTkFrame(self, fg_color=BG)
        self._content.pack(fill="both", expand=True, padx=0, pady=0)

        # ── 日志抽屉 ─────────────────────────────────
        self._log_drawer_visible = False
        self._build_log_drawer()

        # ── 初始主页面 ───────────────────────────────
        self._show_home()

    def _build_topbar(self):
        bar = ctk.CTkFrame(self, fg_color=SURFACE, height=48, corner_radius=0)
        bar.pack(fill="x", side="top")
        bar.pack_propagate(False)

        make_label(bar, "free_rollcall", size=15, color=TEXT_PRI, bold=True).pack(
            side="left", padx=16
        )
        ctk.CTkButton(
            bar, text="📋 日志", width=72, height=30,
            fg_color=SURFACE2, hover_color="#2E2C3F", text_color=TEXT_SEC,
            font=("Microsoft YaHei", 12), corner_radius=8,
            command=self._toggle_log_drawer,
        ).pack(side="right", padx=12, pady=9)

    def _build_log_drawer(self):
        self._drawer = ctk.CTkFrame(self, fg_color=SURFACE, corner_radius=0)
        self._log_text = ctk.CTkTextbox(
            self._drawer,
            fg_color="#0A0912", text_color=TEXT_SEC,
            font=("Courier New", 11),
            wrap="word", state="disabled",
            corner_radius=8,
        )
        self._log_text.pack(fill="both", expand=True, padx=12, pady=(8, 12))

        ctk.CTkButton(
            self._drawer, text="✕ 关闭日志", width=120, height=28,
            fg_color=SURFACE2, hover_color=ACCENT_DK, text_color=TEXT_SEC,
            font=("Microsoft YaHei", 12), corner_radius=8,
            command=self._toggle_log_drawer,
        ).pack(pady=(0, 8))

    def _toggle_log_drawer(self):
        if self._log_drawer_visible:
            self._drawer.place_forget()
            self._log_drawer_visible = False
        else:
            self._drawer.place(relx=0, rely=0.08, relwidth=1, relheight=0.92)
            self._log_drawer_visible = True

    def _log(self, msg: str):
        self._log_lines.append(msg)
        log_to_terminal(msg)
        self.after(0, self._flush_log, msg)

    def _flush_log(self, msg: str):
        self._log_text.configure(state="normal")
        self._log_text.insert("end", msg + "\n")
        self._log_text.see("end")
        self._log_text.configure(state="disabled")

    def _clear_content(self):
        for w in self._content.winfo_children():
            w.destroy()

    # ─────────────────────────────────────────────────────
    # 第 1 页：主页
    # ─────────────────────────────────────────────────────
    def _show_home(self):
        self._clear_content()
        f = self._content

        ctk.CTkFrame(f, fg_color=BG, height=60).pack()

        make_label(f, "free_rollcall", size=28, bold=True, anchor="center").pack()
        make_label(f, "厦大畅课签到码查询助手", size=13, color=TEXT_SEC, anchor="center").pack(pady=(6, 0))

        ctk.CTkFrame(f, fg_color=BG, height=44).pack()

        # 开始按钮主体
        btn_frame = ctk.CTkFrame(
            f, fg_color=SURFACE, width=180, height=180, corner_radius=90
        )
        btn_frame.pack()
        btn_frame.pack_propagate(False)

        btn_icon = ctk.CTkLabel(
            btn_frame, text="⚡", font=("Segoe UI Emoji", 70), fg_color="transparent"
        )
        btn_icon.place(relx=0.5, rely=0.42, anchor="center")

        btn_text = ctk.CTkLabel(
            btn_frame, text="开始登录", font=("Microsoft YaHei", 14, "bold"),
            text_color=TEXT_PRI, fg_color="transparent"
        )
        btn_text.place(relx=0.5, rely=0.74, anchor="center")

        def on_enter(e):
            if not self._busy:
                btn_frame.configure(fg_color="#2A244D")
        def on_leave(e):
            btn_frame.configure(fg_color=SURFACE)
        def on_click(e):
            if not self._busy:
                self._start_login()

        for w in (btn_frame, btn_icon, btn_text):
            w.bind("<Enter>", on_enter)
            w.bind("<Leave>", on_leave)
            w.bind("<Button-1>", on_click)

        ctk.CTkFrame(f, fg_color=BG, height=24).pack()

        self._home_status = make_label(
            f, "", size=12, color=TEXT_SEC, anchor="center", wraplength=420
        )
        self._home_status.pack()

        ctk.CTkFrame(f, fg_color=BG, height=20).pack()

        make_label(
            f, "厦门大学统一身份认证畅课签到码查询工具",
            size=11, color=TEXT_SEC, anchor="center"
        ).pack(side="bottom", pady=16)

    def _set_home_status(self, msg, color=TEXT_SEC):
        self.after(0, lambda: self._home_status.configure(text=msg, text_color=color))

    def _start_login(self):
        self._busy = True
        self._set_home_status("加载统一身份认证登录页面")

        def on_done(result, err):
            if err or result is None:
                self._log("[ERROR] 登录失败" + (f": {err}" if err else ""))
                self._busy = False
                self._set_home_status("登录失败，请重新尝试", DANGER)
                return

            cookie, student_id = result
            if not cookie or not student_id:
                self._log("[ERROR] 获取登录凭证或学生ID失败")
                self._busy = False
                self._set_home_status("获取登录凭证或学生ID失败，请重新登录", DANGER)
                return

            self._cookie     = cookie
            self._student_id = student_id
            self._set_home_status("登录成功，正在获取课程列表...", SUCCESS)
            self._log("[SUCCESS] 登录凭证获取成功")

            def fetch_courses():
                s_id, y_id = get_current_semester_info(cookie, self._log)
                return get_courses(cookie, s_id, y_id, self._log)

            def on_courses(courses, err2):
                self._busy = False
                if err2:
                    self._log(f"[ERROR] 课程列表获取失败: {err2}")
                    self._set_home_status("课程列表获取失败，请重新尝试", DANGER)
                    return
                if not courses:
                    self._log("[WARN] 课程列表为空")
                    self._set_home_status("未获取到课程，请稍后重试", WARN)
                    return
                self._courses = courses
                self._log(f"[SUCCESS] 已获取 {len(courses)} 门课程")
                self.after(0, self._show_courses)

            run_sync_in_thread(fetch_courses, on_courses)

        run_async(
            login_and_get_cookie(log=self._log, browser_channels=("msedge", "chrome")),
            on_done,
        )

    # ─────────────────────────────────────────────────────
    # 第 2 页：课程列表
    # ─────────────────────────────────────────────────────
    def _show_courses(self):
        self._clear_content()
        f = self._content

        hdr = ctk.CTkFrame(f, fg_color=BG)
        hdr.pack(fill="x", padx=20, pady=(16, 8))

        back_btn = ctk.CTkButton(
            hdr, text="← 返回主页", width=80, height=28,
            fg_color=SURFACE2, hover_color=SURFACE, text_color=TEXT_SEC,
            font=("Microsoft YaHei", 12), corner_radius=8,
            command=self._show_home,
        )
        back_btn.pack(anchor="w", pady=(0, 10))

        make_label(hdr, "选择课程", size=24, bold=True).pack(anchor="w")
        make_label(
            hdr, f"共 {len(self._courses)} 门课程，点击查询签到码",
            size=12, color=TEXT_SEC
        ).pack(anchor="w", pady=(2, 0))

        separator(f).pack(fill="x", padx=20, pady=4)

        scroll = ctk.CTkScrollableFrame(f, fg_color=BG, scrollbar_button_color=SURFACE2)
        scroll.pack(fill="both", expand=True, padx=12, pady=4)

        for course in self._courses:
            self._make_course_row(scroll, course)

    def _make_course_row(self, parent, course):
        name = course.get("display_name") or course.get("name") or "未知课程"
        cid  = course.get("id")

        row = ctk.CTkFrame(parent, fg_color=SURFACE, corner_radius=12)
        row.pack(fill="x", pady=5, padx=4)
        row.grid_columnconfigure(1, weight=1)

        icon = ctk.CTkLabel(
            row, text="📚", font=("Segoe UI Emoji", 22),
            width=44, height=44, fg_color=SURFACE2, corner_radius=10
        )
        icon.grid(row=0, column=0, padx=(10, 8), pady=10, sticky="n")

        info = ctk.CTkFrame(row, fg_color="transparent")
        info.grid(row=0, column=1, sticky="ew", pady=10)
        name_label = ctk.CTkLabel(
            info, text=name,
            font=("Microsoft YaHei", 13, "bold"),
            text_color=TEXT_PRI, anchor="w", justify="left",
            width=1, wraplength=300,
        )
        name_label.pack(fill="x")
        id_label = ctk.CTkLabel(
            info, text=f"ID: {cid if cid is not None else '未知'}",
            font=("Courier New", 11),
            text_color=TEXT_SEC, anchor="w"
        )
        id_label.pack(fill="x")

        arrow = ctk.CTkLabel(row, text="›", font=("Arial", 22), text_color=TEXT_SEC, width=16)
        arrow.grid(row=0, column=2, padx=12)

        def on_click(e, _cid=cid, _name=name):
            self._show_code(_cid, _name)

        def on_enter(e):
            row.configure(fg_color=SURFACE2)
        def on_leave(e):
            row.configure(fg_color=SURFACE)

        for w in (row, icon, info, name_label, id_label, arrow):
            w.bind("<Button-1>", on_click)
            w.bind("<Enter>",    on_enter)
            w.bind("<Leave>",    on_leave)

    # ─────────────────────────────────────────────────────
    # 第 3 页：签到码结果
    # ─────────────────────────────────────────────────────
    def _show_code(self, course_id, course_name):
        self._clear_content()
        f = self._content

        hdr = ctk.CTkFrame(f, fg_color=BG)
        hdr.pack(fill="x", padx=12, pady=(14, 4))

        back_btn = ctk.CTkButton(
            hdr, text="← 返回", width=72, height=32,
            fg_color=SURFACE2, hover_color=SURFACE, text_color=TEXT_SEC,
            font=("Microsoft YaHei", 12), corner_radius=8,
            command=self._show_courses,
        )
        back_btn.pack(side="left")

        make_label(
            hdr, text=course_name, size=14, bold=True,
            color=TEXT_PRI, anchor="w", wraplength=330
        ).pack(side="left", padx=10)

        separator(f).pack(fill="x", padx=20, pady=6)

        self._code_card_frame = ctk.CTkFrame(f, fg_color=BG)
        self._code_card_frame.pack(fill="both", expand=True, padx=20, pady=10)

        self._show_loading_card()
        self._log(f"[INFO] 正在查询签到码: {course_name}")

        def fetch():
            r_id, r_time = get_latest_rollcall_id(
                course_id, self._cookie, self._student_id
            )
            if not r_id:
                return None
            number_code, status, _ = get_number_code(r_id, self._cookie)
            if r_time:
                try:
                    dt = datetime.fromisoformat(r_time.replace("Z", "+00:00"))
                    time_str = dt.astimezone(timezone(timedelta(hours=8))).strftime(
                        "%Y-%m-%d %H:%M"
                    )
                except Exception:
                    time_str = str(r_time)
            else:
                time_str = "未知时间"
            return {"code": number_code, "status": status, "time": time_str, "rid": r_id}

        def on_result(result, err):
            if err:
                self._log(f"[ERROR] 签到查询失败: {err}")
                self.after(0, self._show_result_card, None, course_id, course_name, True)
                return
            if result is None:
                self._log(f"[WARN] 暂无签到记录: {course_name}")
            else:
                level = "SUCCESS" if result["code"] else "INFO"
                self._log(
                    f"[{level}] 签到查询完成\n"
                    f"  课程名称: {course_name}\n"
                    f"  发起时间: {result['time']}\n"
                    f"  签到结果: {result['code'] or '无数字签到码'}"
                )
            self.after(0, self._show_result_card, result, course_id, course_name)

        run_sync_in_thread(fetch, on_result)

    def _show_loading_card(self):
        for w in self._code_card_frame.winfo_children():
            w.destroy()
        card = ctk.CTkFrame(self._code_card_frame, fg_color=SURFACE, corner_radius=20)
        card.pack(fill="both", expand=True)
        ctk.CTkLabel(
            card, text="🔍", font=("Segoe UI Emoji", 48)
        ).place(relx=0.5, rely=0.4, anchor="center")
        ctk.CTkLabel(
            card, text="正在查询签到码...",
            font=("Microsoft YaHei", 14), text_color=TEXT_SEC
        ).place(relx=0.5, rely=0.56, anchor="center")
        ctk.CTkProgressBar(
            card, width=200, mode="indeterminate",
            progress_color=ACCENT, fg_color=SURFACE2
        ).place(relx=0.5, rely=0.68, anchor="center")
        for w in card.winfo_children():
            if isinstance(w, ctk.CTkProgressBar):
                w.start()

    def _show_result_card(self, result, course_id, course_name, failed=False):
        for w in self._code_card_frame.winfo_children():
            w.destroy()

        card = ctk.CTkFrame(self._code_card_frame, fg_color=SURFACE, corner_radius=20)
        card.pack(fill="both", expand=True)

        inner = ctk.CTkFrame(card, fg_color="transparent")
        inner.place(relx=0.5, rely=0.5, relwidth=0.9, anchor="center")

        if failed:
            ctk.CTkLabel(inner, text="⚠", font=("Segoe UI Emoji", 52), text_color=DANGER).pack()
            make_label(inner, "签到查询失败", size=18, color=DANGER, bold=True, anchor="center").pack(pady=(8, 2))
            make_label(inner, "请稍后重试，详情可查看日志", size=13, color=TEXT_SEC, anchor="center", wraplength=340).pack()

        elif result is None:
            ctk.CTkLabel(inner, text="📋", font=("Segoe UI Emoji", 52)).pack()
            make_label(inner, "暂无签到记录", size=18, bold=True, anchor="center").pack(pady=(8, 2))
            make_label(inner, "未查询到该课程的签到记录", size=13, color=TEXT_SEC, anchor="center", wraplength=340).pack()

        elif result["code"]:
            status_map   = {"active": ("进行中", SUCCESS), "finished": ("已结束", TEXT_SEC)}
            status_txt, status_clr = status_map.get(result["status"], (result["status"] or "未知状态", TEXT_SEC))

            ctk.CTkLabel(inner, text="🎯", font=("Segoe UI Emoji", 46)).pack()
            make_label(inner, "数字签到码", size=13, color=TEXT_SEC, anchor="center").pack(pady=(4, 0))

            code_entry = ctk.CTkEntry(
                inner, width=240, height=80,
                font=("Arial Black", 48),
                text_color=ACCENT, fg_color="transparent",
                border_width=0, justify="center",
            )
            code_entry.insert(0, str(result["code"]))
            code_entry.configure(state="readonly")
            code_entry.pack(pady=4)

            status_frame = ctk.CTkFrame(inner, fg_color=SURFACE2, corner_radius=20)
            status_frame.pack(pady=4)
            ctk.CTkLabel(
                status_frame, text=status_txt,
                font=("Microsoft YaHei", 12, "bold"),
                text_color=status_clr
            ).pack(padx=16, pady=5)

            make_label(
                inner, f"发起时间：{result['time']}",
                size=12, color=TEXT_SEC, anchor="center"
            ).pack(pady=(6, 0))

        else:
            ctk.CTkLabel(inner, text="📍", font=("Segoe UI Emoji", 52)).pack()
            make_label(inner, "无数字签到码", size=18, bold=True, anchor="center").pack(pady=(8, 2))
            make_label(
                inner, "本次签到可能采用定位或扫码等其他方式",
                size=12, color=TEXT_SEC, anchor="center", wraplength=300
            ).pack()
            make_label(
                inner, f"发起时间：{result['time']}",
                size=12, color=TEXT_SEC, anchor="center"
            ).pack(pady=(6, 0))

        make_button(
            self._code_card_frame, "🔄 重新查询",
            command=lambda: self._show_code(course_id, course_name),
            width=300, height=42
        ).pack(pady=(12, 4))


# ==============================================================================
# 入口
# ==============================================================================
if __name__ == "__main__":
    app = FreeRollcallApp()
    app.mainloop()

package cli

import (
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"freerollcall/internal/rollcall"
)

var schoolTimezone = time.FixedZone("Asia/Shanghai", 8*60*60)

func printHelp(out io.Writer, topic string) {
	if topic == "" || topic == "help" {
		fmt.Fprintln(out, "用法: rollcall [全局参数] [命令]")
		fmt.Fprintln(out, "查询本学期课程、签到记录、签到码和签到人数")
		fmt.Fprintln(out, "\n可用命令:")
		fmt.Fprintln(out, "  courses      查看本学期课程列表")
		fmt.Fprintln(out, "  rollcalls    查看课程指定日期的签到记录，默认今天")
		fmt.Fprintln(out, "  code         查看签到码，默认课程最新一次签到")
		fmt.Fprintln(out, "  attendance   查看签到人数，默认课程最新一次签到")
		fmt.Fprintln(out, "  help [命令]  查看全部命令或某个命令的说明")
	} else if topic == "courses" {
		fmt.Fprintln(out, "用法: rollcall courses [全局参数]")
		fmt.Fprintln(out, "查看或刷新本学期课程列表")
	} else {
		fmt.Fprintf(out, "用法: rollcall %s <课程序号> | --course-id ID [--date YYYY-MM-DD]", topic)
		if topic == "code" || topic == "attendance" {
			fmt.Fprint(out, " [--rollcall-id ID]")
		}
		fmt.Fprintln(out, "\n\n  课程序号       courses 列表中从 1 开始的序号")
		fmt.Fprintln(out, "  --course-id ID  直接使用真实课程 ID，与课程序号二选一")
		fmt.Fprintln(out, "  --date 日期     按北京时间查询 YYYY-MM-DD")
		if topic == "code" || topic == "attendance" {
			fmt.Fprintln(out, "  --rollcall-id ID 选择该日指定签到，必须同时提供 --date")
			fmt.Fprintf(out, "\n示例: rollcall %s --course-id 110405 --date 2026-10-08 --rollcall-id 441597\n", topic)
		}
	}
	fmt.Fprintln(out, "\n全局参数（也可放在命令之后）:")
	fmt.Fprintln(out, "  --config-dir 目录  账号文件所在文件夹，默认为程序旁的 accounts")
	fmt.Fprintln(out, "  --browser 路径     Chrome 或 Chromium 可执行文件")
	fmt.Fprintln(out, "  --show-browser     显示浏览器以处理验证码；账号仍从配置文件读取")
	fmt.Fprintln(out, "  -h, --help         查看帮助")
	if topic == "" || topic == "help" {
		fmt.Fprintln(out, "\n不带命令进入交互模式；直接输入课程序号查看签到码；Enter、exit 或 quit 退出")
		fmt.Fprintln(out, "账号仅从 account.json 读取，不在终端输入密码")
	}
}

// displayWidth covers the CJK text and ordinary Latin text used by these tables.
func displayWidth(text string) int {
	width := 0
	for _, char := range text {
		if unicode.Is(unicode.Mn, char) || unicode.Is(unicode.Me, char) || char == '\u200d' {
			continue
		}
		if char >= 0x1100 && (char <= 0x115f || char == 0x2329 || char == 0x232a ||
			(char >= 0x2e80 && char <= 0xa4cf && char != 0x303f) ||
			(char >= 0xac00 && char <= 0xd7a3) || (char >= 0xf900 && char <= 0xfaff) ||
			(char >= 0xfe10 && char <= 0xfe19) || (char >= 0xfe30 && char <= 0xfe6f) ||
			(char >= 0xff00 && char <= 0xff60) || (char >= 0xffe0 && char <= 0xffe6) ||
			(char >= 0x1f300 && char <= 0x1faff) || (char >= 0x20000 && char <= 0x3fffd)) {
			width += 2
		} else {
			width++
		}
	}
	return width
}

func printTable(out io.Writer, headers []string, rows [][]string) {
	widths := make([]int, len(headers))
	all := append([][]string{headers}, rows...)
	for _, row := range all {
		for index, cell := range row {
			if width := displayWidth(cell); width > widths[index] {
				widths[index] = width
			}
		}
	}
	for _, row := range all {
		var line strings.Builder
		line.WriteString("  ")
		for index, cell := range row {
			line.WriteString(cell)
			if index < len(row)-1 {
				line.WriteString(strings.Repeat(" ", widths[index]-displayWidth(cell)+2))
			}
		}
		fmt.Fprintln(out, strings.TrimRight(line.String(), " "))
	}
}

func valueString(value any) string {
	if value == nil {
		return ""
	}
	return fmt.Sprint(value)
}

func timeText(record rollcall.Record) string {
	started, err := rollcall.RecordTime(record)
	if err != nil {
		return "未知时间"
	}
	return started.In(schoolTimezone).Format("2006-01-02 15:04")
}

func statusText(record rollcall.Record) string {
	status := valueString(record["status"])
	switch status {
	case "active":
		return "进行中"
	case "finished":
		return "已结束"
	case "":
		return "未知"
	default:
		return status
	}
}

func printRecordHeader(out io.Writer, course rollcall.Course, record rollcall.Record) {
	name := course.Name
	if details, ok := record["course"].(map[string]any); ok {
		if display := valueString(details["display_name"]); display != "" {
			name = display
		} else if display := valueString(details["name"]); display != "" {
			name = display
		}
	}
	if name == "" {
		name = "未知课程"
	}
	fmt.Fprintf(out, "\n课程: %s (ID: %s)\n", name, course.ID)
	fmt.Fprintf(out, "签到 ID: %s\n时间: %s\n状态: %s\n", rollcall.RecordID(record), timeText(record), statusText(record))
}

func printAttendance(out io.Writer, record rollcall.Record) error {
	summary, err := rollcall.Summarize(record)
	if err != nil {
		return err
	}
	unsignedLabel := "未签到"
	if valueString(record["status"]) == "finished" {
		unsignedLabel = "缺勤"
	}
	printTable(out, []string{"统计项", "人数"}, [][]string{
		{"统计人数", strconv.Itoa(summary.Total)},
		{"已签到", strconv.Itoa(summary.Signed)},
		{unsignedLabel, strconv.Itoa(summary.Unsigned)},
		{"其他或未知", strconv.Itoa(summary.Unknown)},
	})
	fmt.Fprintln(out, "统计范围：本次接口返回的出勤记录，按学生去重")
	if len(summary.StatusCounts) > 0 {
		fmt.Fprintln(out, "\n状态分布：")
		keys := make([]string, 0, len(summary.StatusCounts))
		for key := range summary.StatusCounts {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		rows := make([][]string, 0, len(keys))
		for _, key := range keys {
			rows = append(rows, []string{key, strconv.Itoa(summary.StatusCounts[key])})
		}
		printTable(out, []string{"原始状态", "人数"}, rows)
	}
	return nil
}

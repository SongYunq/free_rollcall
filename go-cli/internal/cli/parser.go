package cli

import (
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type arguments struct {
	command, topic             string
	course                     int
	courseID, date, rollcallID string
	configDir, browser         string
	showBrowser, help          bool
	rootFlags                  bool
}

type usageError struct{ message string }

func (e *usageError) Error() string { return e.message }

func usage(format string, values ...any) error {
	return &usageError{message: fmt.Sprintf(format, values...)}
}

func positiveID(value string) (string, error) {
	if value == "" {
		return "", usage("请输入大于 0 的整数")
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return "", usage("请输入大于 0 的整数")
		}
	}
	value = strings.TrimLeft(value, "0")
	if value == "" {
		return "", usage("请输入大于 0 的整数")
	}
	return value, nil
}

func validDate(value string) bool {
	date, err := time.Parse("2006-01-02", value)
	return err == nil && date.Year() >= 1 && date.Format("2006-01-02") == value
}

func knownCommand(command string) bool {
	switch command {
	case "courses", "rollcalls", "code", "attendance", "help":
		return true
	default:
		return false
	}
}

func parse(args []string) (arguments, error) {
	var result arguments
	var positionals []string
	var queryFlags bool
	options := true
	for i := 0; i < len(args); i++ {
		argument := args[i]
		if options && argument == "--" {
			options = false
			continue
		}
		if !options || !strings.HasPrefix(argument, "-") || argument == "-" {
			positionals = append(positionals, argument)
			continue
		}
		name, value, inline := strings.Cut(argument, "=")
		switch name {
		case "-h", "--help":
			if inline {
				return result, usage("%s 不接收参数", name)
			}
			result.help = true
			continue
		case "--show-browser":
			result.rootFlags = true
			result.showBrowser = true
			if inline {
				parsed, err := strconv.ParseBool(value)
				if err != nil {
					return result, usage("--show-browser 需要 true 或 false")
				}
				result.showBrowser = parsed
			}
			continue
		case "--config-dir", "--browser", "--course-id", "--date", "--rollcall-id":
		default:
			return result, usage("无法识别的参数: %s", name)
		}
		if !inline {
			i++
			if i >= len(args) || strings.HasPrefix(args[i], "--") {
				return result, usage("%s 缺少参数", name)
			}
			value = args[i]
		}
		if value == "" {
			return result, usage("%s 的参数不能为空", name)
		}
		switch name {
		case "--config-dir":
			result.rootFlags = true
			result.configDir = value
		case "--browser":
			result.rootFlags = true
			result.browser = value
		case "--date":
			queryFlags = true
			if !validDate(value) {
				return result, usage("日期格式应为 YYYY-MM-DD，例如 2026-10-08")
			}
			result.date = value
		case "--course-id", "--rollcall-id":
			queryFlags = true
			id, err := positiveID(value)
			if err != nil {
				return result, err
			}
			if name == "--course-id" {
				result.courseID = id
			} else {
				result.rollcallID = id
			}
		}
	}
	if len(positionals) == 0 {
		if queryFlags {
			return result, usage("请先指定查询命令")
		}
		return result, nil
	}
	result.command = positionals[0]
	if !knownCommand(result.command) {
		return result, usage("无法识别的命令: %s", result.command)
	}
	positionals = positionals[1:]
	if result.command == "help" {
		if queryFlags || len(positionals) > 1 {
			return result, usage("用法: help [命令]")
		}
		result.help = true
		if len(positionals) == 1 {
			result.topic = positionals[0]
			if !knownCommand(result.topic) {
				return result, usage("无法识别的命令: %s", result.topic)
			}
		}
		return result, nil
	}
	if result.help {
		result.topic = result.command
		return result, nil
	}
	if result.command == "courses" {
		if queryFlags || len(positionals) != 0 {
			return result, usage("courses 不接收课程或日期参数")
		}
		return result, nil
	}
	if len(positionals) > 1 {
		return result, usage("只允许一个课程序号")
	}
	if len(positionals) == 1 {
		index, err := positiveID(positionals[0])
		if err != nil {
			return result, err
		}
		result.course, err = strconv.Atoi(index)
		if err != nil {
			return result, usage("课程序号超出支持范围")
		}
	}
	if (result.course == 0) == (result.courseID == "") {
		return result, usage("请提供课程序号或 --course-id，且只能选择一种")
	}
	if result.command == "rollcalls" && result.rollcallID != "" {
		return result, usage("rollcalls 不接收 --rollcall-id，请使用 code 或 attendance")
	}
	if result.rollcallID != "" && result.date == "" {
		return result, usage("--rollcall-id 必须与 --date 一起使用")
	}
	return result, nil
}

// splitLine accepts shell-style quoting without executing shell commands.
func splitLine(line string) ([]string, error) {
	var words []string
	var current strings.Builder
	var quote rune
	escaped, started := false, false
	for _, char := range line {
		if escaped {
			current.WriteRune(char)
			escaped, started = false, true
			continue
		}
		if char == '\\' && quote != '\'' {
			escaped, started = true, true
			continue
		}
		if quote != 0 {
			if char == quote {
				quote = 0
			} else {
				current.WriteRune(char)
			}
			continue
		}
		if char == '\'' || char == '"' {
			quote, started = char, true
		} else if unicode.IsSpace(char) {
			if started {
				words = append(words, current.String())
				current.Reset()
				started = false
			}
		} else {
			current.WriteRune(char)
			started = true
		}
	}
	if quote != 0 || escaped {
		return nil, usage("命令中的引号或转义未闭合，请重新输入")
	}
	if started {
		words = append(words, current.String())
	}
	return words, nil
}

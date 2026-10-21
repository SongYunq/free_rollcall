// Package cli provides the command line and interactive query entry points.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"freerollcall/internal/auth"
	"freerollcall/internal/rollcall"
	"freerollcall/internal/store"
)

// QueryClient is the school query surface used by the CLI.
type QueryClient interface {
	Courses(context.Context) ([]rollcall.Course, error)
	Latest(context.Context, string, string) (rollcall.Record, error)
	Daily(context.Context, string, string) ([]rollcall.Record, error)
	Detail(context.Context, string, string, string) (rollcall.Record, error)
}

type Session struct {
	Profile rollcall.Profile
	Client  QueryClient
}

// Dependencies keep tests offline and keep terminal input out of authentication.
type Dependencies struct {
	ResolveDir func(string) (string, error)
	Load       func(string) (store.Account, error)
	Login      func(context.Context, store.Account, auth.Options) (*Session, error)
	Now        func() time.Time
}

type Runner struct{ Deps Dependencies }

func (r Runner) dependencies() Dependencies {
	deps := r.Deps
	if deps.ResolveDir == nil {
		deps.ResolveDir = store.ResolveDir
	}
	if deps.Load == nil {
		deps.Load = store.Load
	}
	if deps.Login == nil {
		deps.Login = func(ctx context.Context, account store.Account, options auth.Options) (*Session, error) {
			session, err := auth.Login(ctx, account, options)
			if err != nil {
				return nil, err
			}
			if session == nil {
				return nil, errors.New("获取登录凭证或学生 ID 失败")
			}
			return &Session{Profile: session.Profile, Client: session.Client}, nil
		}
	}
	if deps.Now == nil {
		deps.Now = time.Now
	}
	return deps
}

// Run returns the process exit code: success 0, operational error 1, usage error 2.
func Run(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer) int {
	return (Runner{}).Run(ctx, args, in, out, errOut)
}

func (r Runner) Run(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer) int {
	parsed, err := parse(args)
	if err != nil {
		fmt.Fprintf(errOut, "[ERROR] %s\n使用 help 或 --help 查看命令说明\n", err)
		return 2
	}
	if parsed.help {
		printHelp(out, parsed.topic)
		return 0
	}
	if err := ctx.Err(); err != nil {
		fmt.Fprintln(errOut, "[ERROR] 操作已取消")
		return 1
	}
	deps := r.dependencies()
	dir, err := deps.ResolveDir(parsed.configDir)
	if err != nil {
		fmt.Fprintf(errOut, "[ERROR] %s\n", err)
		return 1
	}
	account, err := deps.Load(dir)
	if err != nil {
		fmt.Fprintf(errOut, "[ERROR] %s\n", err)
		return 1
	}
	if parsed.command == "" {
		fmt.Fprintln(out, strings.Repeat("=", 50))
		fmt.Fprintln(out, "   free_rollcall(CLI) - XMU")
		fmt.Fprintln(out, strings.Repeat("=", 50))
	}
	log := func(message string) { fmt.Fprintln(errOut, message) }
	verified, err := deps.Login(ctx, account, auth.Options{
		BrowserPath: parsed.browser, ShowBrowser: parsed.showBrowser, Log: log,
	})
	if err != nil {
		fmt.Fprintf(errOut, "[ERROR] %s\n", err)
		return 1
	}
	if verified == nil || verified.Client == nil || verified.Profile.ID == "" {
		fmt.Fprintln(errOut, "[ERROR] 获取登录凭证或学生 ID 失败")
		return 1
	}
	session := querySession{client: verified.Client, studentID: verified.Profile.ID, out: out, now: deps.Now}
	if parsed.command == "" {
		return interactive(ctx, in, errOut, &session)
	}
	return report(session.execute(ctx, parsed), errOut)
}

func report(err error, errOut io.Writer) int {
	if err == nil {
		return 0
	}
	fmt.Fprintf(errOut, "[ERROR] %s\n", err)
	var usage *usageError
	if errors.As(err, &usage) {
		return 2
	}
	return 1
}

type querySession struct {
	client        QueryClient
	studentID     string
	courses       []rollcall.Course
	coursesLoaded bool
	out           io.Writer
	now           func() time.Time
}

func (s *querySession) loadCourses(ctx context.Context, refresh bool) ([]rollcall.Course, error) {
	if !s.coursesLoaded || refresh {
		courses, err := s.client.Courses(ctx)
		if err != nil {
			return nil, err
		}
		s.courses, s.coursesLoaded = courses, true
	}
	return s.courses, nil
}

func (s *querySession) showCourses(ctx context.Context) error {
	courses, err := s.loadCourses(ctx, true)
	if err != nil {
		return err
	}
	if len(courses) == 0 {
		fmt.Fprintln(s.out, "[INFO] 本学期暂无课程")
		return nil
	}
	fmt.Fprintln(s.out, "\n本学期课程：")
	rows := make([][]string, 0, len(courses))
	for index, course := range courses {
		name := course.Name
		if name == "" {
			name = "未知课程"
		}
		rows = append(rows, []string{strconv.Itoa(index + 1), name, course.ID})
	}
	printTable(s.out, []string{"序号", "课程名称", "课程 ID"}, rows)
	return nil
}

func (s *querySession) selectCourse(ctx context.Context, args arguments) (rollcall.Course, error) {
	if args.courseID != "" {
		return rollcall.Course{ID: args.courseID}, nil
	}
	courses, err := s.loadCourses(ctx, false)
	if err != nil {
		return rollcall.Course{}, err
	}
	if args.course < 1 || args.course > len(courses) {
		return rollcall.Course{}, usage("课程序号超出范围，请输入 courses 查看课程列表")
	}
	return courses[args.course-1], nil
}

func (s *querySession) queryRecord(ctx context.Context, args arguments, courseID string) (rollcall.Record, error) {
	if args.date == "" {
		record, err := s.client.Latest(ctx, courseID, s.studentID)
		if err != nil || record == nil {
			return record, err
		}
		return s.client.Detail(ctx, courseID, rollcall.RecordID(record), rollcall.RecordStartedAt(record))
	}
	records, err := s.client.Daily(ctx, courseID, args.date)
	if err != nil {
		return nil, err
	}
	if args.rollcallID != "" {
		for _, record := range records {
			if rollcall.RecordID(record) == args.rollcallID {
				return record, nil
			}
		}
		return nil, errors.New("该课程在指定日期没有找到此签到，请先使用 rollcalls 查看签到编号")
	}
	var latest rollcall.Record
	var latestTime time.Time
	for _, record := range records {
		started, err := rollcall.RecordTime(record)
		if err != nil {
			return nil, errors.New("签到时间缺失或格式有误，无法确定最新签到，请使用 --rollcall-id 指定")
		}
		if latest == nil || started.After(latestTime) {
			latest, latestTime = record, started
		}
	}
	return latest, nil
}

func (s *querySession) execute(ctx context.Context, args arguments) error {
	if err := ctx.Err(); err != nil {
		return errors.New("操作已取消")
	}
	if args.command == "courses" {
		return s.showCourses(ctx)
	}
	course, err := s.selectCourse(ctx, args)
	if err != nil {
		return err
	}
	if _, err := positiveID(course.ID); err != nil {
		return errors.New("课程缺少有效 ID，无法查询")
	}
	if args.command == "rollcalls" {
		date := args.date
		if date == "" {
			date = s.now().In(schoolTimezone).Format("2006-01-02")
		}
		records, err := s.client.Daily(ctx, course.ID, date)
		if err != nil {
			return err
		}
		if len(records) == 0 {
			fmt.Fprintf(s.out, "[INFO] 该课程在 %s 暂无签到记录\n", date)
			return nil
		}
		fmt.Fprintf(s.out, "\n%s 的签到记录 (课程 ID: %s)：\n", date, course.ID)
		rows := make([][]string, 0, len(records))
		for _, record := range records {
			code := "—"
			if record["number_code"] != nil {
				code = valueString(record["number_code"])
			}
			rows = append(rows, []string{rollcall.RecordID(record), timeText(record), statusText(record), code})
		}
		printTable(s.out, []string{"签到 ID", "时间", "状态", "签到码"}, rows)
		return nil
	}
	record, err := s.queryRecord(ctx, args, course.ID)
	if err != nil {
		return err
	}
	if record == nil {
		fmt.Fprintln(s.out, "[INFO] 该课程暂无符合条件的签到记录")
		return nil
	}
	printRecordHeader(s.out, course, record)
	if args.command == "attendance" {
		return printAttendance(s.out, record)
	}
	if code := valueString(record["number_code"]); code != "" {
		fmt.Fprintf(s.out, "签到码: 【 %s 】\n", code)
	} else {
		fmt.Fprintln(s.out, "本次签到无数字签到码")
	}
	return nil
}

func interactive(ctx context.Context, in io.Reader, errOut io.Writer, session *querySession) int {
	input := newLineReader(in)
	defer func() { input.stop(ctx.Err() != nil) }()
	if err := session.showCourses(ctx); err != nil {
		report(err, errOut)
	}
	fmt.Fprintln(session.out, "\n输入 help 查看命令；直接输入课程序号查看签到码；输入 exit 或按 Enter 退出")
	for {
		if ctx.Err() != nil {
			fmt.Fprintln(errOut, "[ERROR] 操作已取消")
			return 1
		}
		fmt.Fprint(session.out, "\nfree_rollcall> ")
		result, err := input.next(ctx)
		if err != nil {
			fmt.Fprintln(errOut, "[ERROR] 操作已取消")
			return 1
		}
		if !result.scanned {
			if result.err != nil {
				fmt.Fprintln(errOut, "[ERROR] 无法读取终端输入")
				return 1
			}
			fmt.Fprintln(session.out, "\n退出程序")
			return 0
		}
		line := strings.TrimSpace(result.text)
		if line == "" || line == "exit" || line == "quit" {
			fmt.Fprintln(session.out, "退出程序")
			return 0
		}
		words, err := splitLine(line)
		if err != nil {
			report(err, errOut)
			continue
		}
		if len(words) == 1 {
			if _, err := positiveID(words[0]); err == nil {
				words = append([]string{"code"}, words...)
			}
		}
		args, err := parse(words)
		if err != nil {
			report(err, errOut)
			continue
		}
		if args.rootFlags {
			report(usage("已在登录会话中，修改账号目录或浏览器参数请退出后重新运行"), errOut)
			continue
		}
		if args.help || args.command == "" {
			printHelp(session.out, args.topic)
			continue
		}
		report(session.execute(ctx, args), errOut)
	}
}

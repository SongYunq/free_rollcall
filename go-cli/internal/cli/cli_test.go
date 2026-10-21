package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"freerollcall/internal/auth"
	"freerollcall/internal/rollcall"
	"freerollcall/internal/store"
)

type queryCall struct{ courseID, studentID, date, recordID, startedAt string }

type fakeClient struct {
	courses                  []rollcall.Course
	latest, detail           rollcall.Record
	daily                    []rollcall.Record
	courseErr, latestErr     error
	detailErr, dailyErr      error
	courseCalls              int
	latestCalls, detailCalls []queryCall
	dailyCalls               []queryCall
}

func (f *fakeClient) Courses(context.Context) ([]rollcall.Course, error) {
	f.courseCalls++
	return f.courses, f.courseErr
}

func (f *fakeClient) Latest(_ context.Context, courseID, studentID string) (rollcall.Record, error) {
	f.latestCalls = append(f.latestCalls, queryCall{courseID: courseID, studentID: studentID})
	return f.latest, f.latestErr
}

func (f *fakeClient) Detail(_ context.Context, courseID, recordID, startedAt string) (rollcall.Record, error) {
	f.detailCalls = append(f.detailCalls, queryCall{courseID: courseID, recordID: recordID, startedAt: startedAt})
	return f.detail, f.detailErr
}

func (f *fakeClient) Daily(_ context.Context, courseID, date string) ([]rollcall.Record, error) {
	f.dailyCalls = append(f.dailyCalls, queryCall{courseID: courseID, date: date})
	return f.daily, f.dailyErr
}

type harness struct {
	runner                     Runner
	client                     *fakeClient
	resolved, loaded, loggedIn int
	dir                        string
	authOptions                auth.Options
	loadErr, loginErr          error
}

func fixtureRecord(id, code, startedAt string) rollcall.Record {
	return rollcall.Record{
		"id": id, "number_code": code, "rollcall_time": startedAt, "status": "active",
		"student_rollcalls": []any{
			map[string]any{"student_id": "77", "status": "present", "name": "不应显示的学生", "account": "private-account"},
			map[string]any{"student_id": "78", "status": "absent"},
		},
	}
}

func newHarness() *harness {
	record := fixtureRecord("441597", "0007", "2026-10-08T00:20:00Z")
	h := &harness{client: &fakeClient{
		courses: []rollcall.Course{{ID: "110405", Name: "高等数学"}, {ID: "110406", Name: "English"}},
		latest:  record, detail: record, daily: []rollcall.Record{record},
	}}
	h.runner.Deps = Dependencies{
		ResolveDir: func(explicit string) (string, error) {
			h.resolved++
			h.dir = explicit
			return "/offline/accounts", nil
		},
		Load: func(dir string) (store.Account, error) {
			h.loaded++
			return store.Account{Username: "offline-user", Password: "offline-password"}, h.loadErr
		},
		Login: func(_ context.Context, account store.Account, options auth.Options) (*Session, error) {
			h.loggedIn++
			h.authOptions = options
			if account.Username != "offline-user" || account.Password != "offline-password" {
				return nil, errors.New("未使用配置文件账号")
			}
			return &Session{Profile: rollcall.Profile{ID: "42"}, Client: h.client}, h.loginErr
		},
		Now: func() time.Time { return time.Date(2026, 10, 20, 20, 0, 0, 0, time.UTC) },
	}
	return h
}

func (h *harness) run(args []string, input string) (int, string, string) {
	var out, errOut bytes.Buffer
	status := h.runner.Run(context.Background(), args, strings.NewReader(input), &out, &errOut)
	return status, out.String(), errOut.String()
}

func TestHelpAndUsageDoNotReadAccountOrAuthenticate(t *testing.T) {
	cases := []struct {
		args []string
		code int
	}{
		{[]string{"help"}, 0}, {[]string{"--help"}, 0}, {[]string{"-h"}, 0},
		{[]string{"help", "attendance"}, 0}, {[]string{"code", "--help"}, 0},
		{[]string{"help", "unknown"}, 2}, {[]string{"unknown"}, 2},
		{[]string{"code"}, 2}, {[]string{"courses", "1"}, 2},
		{[]string{"code", "1", "--course-id", "110405"}, 2},
		{[]string{"code", "--course-id", "0"}, 2},
		{[]string{"code", "--course-id", "-1"}, 2},
		{[]string{"code", "--course-id", "1.5"}, 2},
		{[]string{"attendance", "1", "--rollcall-id", "2"}, 2},
		{[]string{"rollcalls", "1", "--rollcall-id", "2", "--date", "2026-10-08"}, 2},
		{[]string{"rollcalls", "1", "--date", "2026-02-30"}, 2},
		{[]string{"rollcalls", "1", "--date", "2026-1-8"}, 2},
		{[]string{"rollcalls", "1", "--date", "0000-01-01"}, 2},
		{[]string{"rollcalls", "1", "--date", "20261008"}, 2},
		{[]string{"code", "1", "--course-id"}, 2},
		{[]string{"--date", "2026-10-08"}, 2},
		{[]string{"--manual-login", "courses"}, 2},
		{[]string{"--show-browser=invalid", "courses"}, 2},
	}
	for _, test := range cases {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			h := newHarness()
			code, out, errOut := h.run(test.args, "")
			if code != test.code {
				t.Fatalf("exit %d, want %d; output=%s; error=%s", code, test.code, out, errOut)
			}
			if h.resolved != 0 || h.loaded != 0 || h.loggedIn != 0 {
				t.Fatalf("help/usage touched account or authentication: %+v", h)
			}
		})
	}
}

func TestCommandHelpDescribesSelectorsAndFileOnlyLogin(t *testing.T) {
	h := newHarness()
	code, out, _ := h.run([]string{"help", "attendance"}, "")
	for _, want := range []string{"--course-id", "--date", "--rollcall-id", "--config-dir", "--browser", "--show-browser", "账号仍从配置文件读取"} {
		if code != 0 || !strings.Contains(out, want) {
			t.Errorf("help missing %q: exit=%d, %s", want, code, out)
		}
	}
	if strings.Contains(out, "--manual-login") {
		t.Fatal("removed password flow still documented")
	}
}

func TestRootFlagsAfterCommandAndConfigCredentialsReachLogin(t *testing.T) {
	h := newHarness()
	code, out, errOut := h.run([]string{"courses", "--config-dir", "/tmp/account folder", "--browser=/tmp/chrome", "--show-browser"}, "must never be read")
	if code != 0 || errOut != "" || h.dir != "/tmp/account folder" || h.authOptions.BrowserPath != "/tmp/chrome" || !h.authOptions.ShowBrowser {
		t.Fatalf("unexpected flags/login: code=%d err=%s dir=%s options=%+v", code, errOut, h.dir, h.authOptions)
	}
	if h.loaded != 1 || h.loggedIn != 1 || !strings.Contains(out, "高等数学") || !strings.Contains(out, "110406") {
		t.Fatalf("unexpected courses: %s", out)
	}
}

func TestExplicitCourseIDSkipsCourseListAndPreservesCode(t *testing.T) {
	h := newHarness()
	h.client.courseErr = errors.New("不应查询课程列表")
	code, out, errOut := h.run([]string{"code", "--course-id", "110405"}, "")
	if code != 0 || errOut != "" || h.client.courseCalls != 0 || !strings.Contains(out, "【 0007 】") {
		t.Fatalf("code=%d out=%s err=%s course calls=%d", code, out, errOut, h.client.courseCalls)
	}
	if len(h.client.latestCalls) != 1 || h.client.latestCalls[0].studentID != "42" || len(h.client.detailCalls) != 1 {
		t.Fatalf("unexpected query calls: %+v %+v", h.client.latestCalls, h.client.detailCalls)
	}
	if call := h.client.detailCalls[0]; call.recordID != "441597" || call.startedAt != "2026-10-08T00:20:00Z" || call.courseID != "110405" {
		t.Fatalf("detail did not retain identity and original timestamp: %+v", call)
	}
}

func TestCourseIndexSelectsExactCourseAndOutOfRangeExitsTwo(t *testing.T) {
	h := newHarness()
	code, _, _ := h.run([]string{"code", "2"}, "")
	if code != 0 || h.client.latestCalls[0].courseID != "110406" {
		t.Fatalf("wrong course selected: %+v", h.client.latestCalls)
	}
	h = newHarness()
	code, _, _ = h.run([]string{"code", "3"}, "")
	if code != 2 || len(h.client.latestCalls) != 0 {
		t.Fatalf("out-of-range course queried or wrong exit: %d %+v", code, h.client.latestCalls)
	}
}

func TestDailyUsesBeijingDateAndListsAllCodes(t *testing.T) {
	h := newHarness()
	h.client.daily = append(h.client.daily, fixtureRecord("441598", "0123", "2026-10-08T01:30:00Z"))
	code, out, errOut := h.run([]string{"rollcalls", "--course-id", "110405"}, "")
	if code != 0 || errOut != "" || h.client.dailyCalls[0].date != "2026-10-21" {
		t.Fatalf("wrong local date/query: code=%d err=%s calls=%+v", code, errOut, h.client.dailyCalls)
	}
	for _, want := range []string{"0007", "0123", "2026-10-08 08:20", "2026-10-08 09:30"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s: %s", want, out)
		}
	}
	if len(h.client.latestCalls) != 0 || len(h.client.detailCalls) != 0 {
		t.Fatal("daily query requested latest/detail endpoint")
	}
}

func TestDateLatestUsesTimestampAndExplicitRecordIsExact(t *testing.T) {
	for _, test := range []struct {
		name, selected, want string
	}{
		{"latest by time", "", "0222"},
		{"specific id", "999", "0111"},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness()
			h.client.daily = []rollcall.Record{
				fixtureRecord("2", "0222", "2026-10-08T01:20:00Z"),
				fixtureRecord("999", "0111", "2026-10-08T00:20:00Z"),
			}
			args := []string{"code", "--course-id", "110405", "--date", "2026-10-08"}
			if test.selected != "" {
				args = append(args, "--rollcall-id", test.selected)
			}
			code, out, errOut := h.run(args, "")
			if code != 0 || errOut != "" || !strings.Contains(out, "【 "+test.want+" 】") {
				t.Fatalf("code=%d out=%s err=%s", code, out, errOut)
			}
			if len(h.client.latestCalls) != 0 || len(h.client.detailCalls) != 0 {
				t.Fatal("date query unexpectedly used latest/detail")
			}
		})
	}
}

func TestMissingDailyTimestampAndUnknownRecordFailWithoutFallback(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		h := newHarness()
		delete(h.client.daily[0], "rollcall_time")
		args := []string{"code", "1", "--date", "2026-10-08"}
		if explicit {
			args = append(args, "--rollcall-id", "999")
		}
		code, out, errOut := h.run(args, "")
		if code != 1 || errOut == "" || strings.Contains(out, "签到码:") || len(h.client.latestCalls) != 0 {
			t.Fatalf("expected exact-query failure: code=%d out=%s err=%s", code, out, errOut)
		}
	}
}

func TestAttendanceShowsSummaryWithoutStudentDetails(t *testing.T) {
	for _, status := range []string{"active", "finished"} {
		h := newHarness()
		h.client.detail["status"] = status
		code, out, errOut := h.run([]string{"attendance", "1"}, "")
		label := "未签到"
		if status == "finished" {
			label = "缺勤"
		}
		if code != 0 || errOut != "" || !strings.Contains(out, "已签到") || !strings.Contains(out, label) || !strings.Contains(out, "按学生去重") {
			t.Fatalf("invalid summary: code=%d out=%s err=%s", code, out, errOut)
		}
		for _, secret := range []string{"不应显示的学生", "private-account", "offline-password"} {
			if strings.Contains(out+errOut, secret) {
				t.Errorf("output disclosed student/credential information: %s", secret)
			}
		}
	}
}

func TestEmptyResultsAreSuccessfulAndQueryFailuresExitOne(t *testing.T) {
	for _, args := range [][]string{{"courses"}, {"code", "1"}, {"rollcalls", "1"}} {
		h := newHarness()
		if args[0] == "courses" {
			h.client.courses = nil
		}
		h.client.latest, h.client.daily = nil, nil
		code, _, errOut := h.run(args, "")
		if code != 0 || errOut != "" {
			t.Fatalf("empty result was an error: args=%v code=%d err=%s", args, code, errOut)
		}
	}
	h := newHarness()
	h.client.detailErr = errors.New("离线查询失败")
	code, out, errOut := h.run([]string{"code", "1"}, "")
	if code != 1 || !strings.Contains(errOut, "离线查询失败") || strings.Contains(out, "无数字签到码") {
		t.Fatalf("query failure became empty result: code=%d out=%s err=%s", code, out, errOut)
	}
}

func TestAccountOrLoginFailureStopsQueries(t *testing.T) {
	for _, failLoad := range []bool{true, false} {
		h := newHarness()
		if failLoad {
			h.loadErr = errors.New("请填写 account.json")
		} else {
			h.loginErr = errors.New("账号认证失败")
		}
		code, _, errOut := h.run([]string{"courses"}, "")
		if code != 1 || errOut == "" || h.client.courseCalls != 0 || failLoad && h.loggedIn != 0 {
			t.Fatalf("failed auth reached queries: code=%d err=%s calls=%d login=%d", code, errOut, h.client.courseCalls, h.loggedIn)
		}
	}
}

func TestInteractiveLogsInOnceCachesCoursesAndContinuesAfterErrors(t *testing.T) {
	h := newHarness()
	code, out, errOut := h.run(nil, "unknown\ncode 1 --date invalid\ncode 1 --date \"unfinished\nhelp attendance\n2\nattendance 1\ncourses\nexit\n")
	if code != 0 || h.loggedIn != 1 || h.client.courseCalls != 2 || len(h.client.latestCalls) != 2 {
		t.Fatalf("interactive calls/exit: code=%d login=%d courses=%d latest=%+v err=%s", code, h.loggedIn, h.client.courseCalls, h.client.latestCalls, errOut)
	}
	if h.client.latestCalls[0].courseID != "110406" || h.client.latestCalls[1].courseID != "110405" {
		t.Fatalf("wrong interactive selectors: %+v", h.client.latestCalls)
	}
	for _, want := range []string{"无法识别的命令", "日期格式", "未闭合"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("error not reported: %s; %s", want, errOut)
		}
	}
	if !strings.Contains(out, "退出程序") || !strings.Contains(out, "0007") || !strings.Contains(out, "--rollcall-id") {
		t.Fatalf("missing interactive output: %s", out)
	}
}

func TestInteractiveQueryErrorDoesNotEndSessionOrChangeLogin(t *testing.T) {
	h := newHarness()
	h.client.detailErr = errors.New("临时查询失败")
	code, out, errOut := h.run(nil, "code 1\n--config-dir elsewhere courses\ncourses\n\n")
	if code != 0 || h.loggedIn != 1 || h.client.courseCalls != 2 || !strings.Contains(out, "退出程序") {
		t.Fatalf("unexpected interactive recovery: %d %s %s", code, out, errOut)
	}
	if !strings.Contains(errOut, "临时查询失败") || !strings.Contains(errOut, "退出后重新运行") {
		t.Fatalf("missing recovery error: %s", errOut)
	}
}

func TestCancelledContextDoesNotReadCredentials(t *testing.T) {
	h := newHarness()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	code := h.runner.Run(ctx, []string{"courses"}, strings.NewReader(""), io.Discard, io.Discard)
	if code != 1 || h.resolved != 0 || h.loaded != 0 || h.loggedIn != 0 {
		t.Fatalf("cancelled startup touched credentials: code=%d loaded=%d login=%d", code, h.loaded, h.loggedIn)
	}
}

type watchedInput struct {
	io.ReadCloser
	started chan struct{}
	closed  chan struct{}
	once    sync.Once
}

func (input *watchedInput) Read(buffer []byte) (int, error) {
	input.once.Do(func() { close(input.started) })
	return input.ReadCloser.Read(buffer)
}

func (input *watchedInput) Close() error {
	err := input.ReadCloser.Close()
	close(input.closed)
	return err
}

func TestInteractiveCancellationInterruptsBlockedInput(t *testing.T) {
	h := newHarness()
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	input := &watchedInput{ReadCloser: reader, started: make(chan struct{}), closed: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	returned := make(chan int, 1)
	go func() {
		returned <- h.runner.Run(ctx, nil, input, io.Discard, io.Discard)
	}()
	select {
	case <-input.started:
	case <-time.After(time.Second):
		t.Fatal("interactive input was never read")
	}
	cancel()
	select {
	case code := <-returned:
		if code != 1 {
			t.Fatalf("cancelled interactive exit=%d, want 1", code)
		}
	case <-time.After(time.Second):
		t.Fatal("context cancellation did not interrupt blocked terminal input")
	}
	select {
	case <-input.closed:
	case <-time.After(time.Second):
		t.Fatal("cancelled input was not closed asynchronously")
	}
	wrote := make(chan error, 1)
	go func() {
		_, err := writer.Write([]byte("must not block"))
		wrote <- err
	}()
	select {
	case err := <-wrote:
		if !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("cancelled input remained open: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled input was not closed asynchronously")
	}
}

type blockingInput struct {
	started  chan struct{}
	release  chan struct{}
	finished chan struct{}
}

func (input *blockingInput) Read([]byte) (int, error) {
	close(input.started)
	<-input.release
	close(input.finished)
	return 0, io.EOF
}

type blockingCloseInput struct {
	*blockingInput
	closeStarted  chan struct{}
	closeRelease  chan struct{}
	closeFinished chan struct{}
}

func (input *blockingCloseInput) Close() error {
	close(input.closeStarted)
	<-input.closeRelease
	close(input.closeFinished)
	return nil
}

func releaseInput(channel chan struct{}) {
	select {
	case <-channel:
	default:
		close(channel)
	}
}

func TestInteractiveCancellationDoesNotDependOnReadOrClose(t *testing.T) {
	for _, withClose := range []bool{false, true} {
		name := "uncancellable reader"
		if withClose {
			name = "blocking close"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness()
			blocked := &blockingInput{
				started: make(chan struct{}), release: make(chan struct{}), finished: make(chan struct{}),
			}
			t.Cleanup(func() { releaseInput(blocked.release) })
			var input io.Reader = blocked
			var closer *blockingCloseInput
			if withClose {
				closer = &blockingCloseInput{
					blockingInput: blocked, closeStarted: make(chan struct{}),
					closeRelease: make(chan struct{}), closeFinished: make(chan struct{}),
				}
				input = closer
				t.Cleanup(func() { releaseInput(closer.closeRelease) })
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			returned := make(chan int, 1)
			go func() {
				returned <- h.runner.Run(ctx, nil, input, io.Discard, io.Discard)
			}()
			select {
			case <-blocked.started:
			case <-time.After(time.Second):
				t.Fatal("interactive input was never read")
			}
			cancel()
			select {
			case code := <-returned:
				if code != 1 {
					t.Fatalf("cancelled interactive exit=%d, want 1", code)
				}
			case <-time.After(time.Second):
				t.Fatal("Run waited for an uninterruptible Read or Close")
			}
			// Explicitly release both test operations, so the test leaves no blocked
			// reader or cleanup goroutine behind after proving prompt cancellation.
			releaseInput(blocked.release)
			select {
			case <-blocked.finished:
			case <-time.After(time.Second):
				t.Fatal("test reader was not released")
			}
			if closer != nil {
				select {
				case <-closer.closeStarted:
				case <-time.After(time.Second):
					t.Fatal("cancelled input was not closed asynchronously")
				}
				releaseInput(closer.closeRelease)
				select {
				case <-closer.closeFinished:
				case <-time.After(time.Second):
					t.Fatal("test close was not released")
				}
			}
		})
	}
}

func TestSplitLineAcceptsQuotedArgumentsWithoutExecutingShell(t *testing.T) {
	words, err := splitLine(`code --course-id 110405 --date "2026-10-08"`)
	if err != nil || strings.Join(words, "|") != "code|--course-id|110405|--date|2026-10-08" {
		t.Fatalf("quoted arguments: %q, %v", words, err)
	}
	words, err = splitLine(`help "$(touch /tmp/must-not-execute)"`)
	if err != nil || len(words) != 2 || words[1] != "$(touch /tmp/must-not-execute)" {
		t.Fatalf("shell syntax was interpreted: %q, %v", words, err)
	}
}

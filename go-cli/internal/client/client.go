// Package client implements read-only school API queries. The same HTTP client
// and cookie jar are shared by every query in a login session.
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"time"

	"freerollcall/internal/rollcall"
)

const requestTimeout = 15 * time.Second

// ErrUnauthenticated lets login polling distinguish a session which is not yet
// established from an API failure or an actual permission denial.
var ErrUnauthenticated = errors.New("登录已失效，请重新登录后重试")

type Client struct {
	baseURL string
	http    *http.Client
}

// NewHTTPClient supplies the transport policy also used by browser-cookie login.
func NewHTTPClient() *http.Client {
	jar, _ := cookiejar.New(nil)
	return &http.Client{
		Jar: jar, Timeout: requestTimeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func New(baseURL string, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = NewHTTPClient()
	} else {
		// Keep the caller's shared jar/transport, without changing its other users.
		copyClient := *httpClient
		httpClient = &copyClient
		if httpClient.Jar == nil {
			httpClient.Jar, _ = cookiejar.New(nil)
		}
		httpClient.Timeout = requestTimeout
		httpClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	}
	return &Client{baseURL: strings.TrimRight(baseURL, "/"), http: httpClient}
}

func (c *Client) read(ctx context.Context, method, path, subject string, query url.Values, payload any) (any, error) {
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("%s查询参数有误", subject)
		}
		body = bytes.NewReader(encoded)
	}
	endpoint, err := url.Parse(c.baseURL + path)
	if err != nil || endpoint.Scheme != "http" && endpoint.Scheme != "https" || endpoint.Host == "" || endpoint.User != nil {
		return nil, errors.New("学校服务地址配置有误")
	}
	endpoint.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), body)
	if err != nil {
		return nil, fmt.Errorf("%s查询参数有误", subject)
	}
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	req.Header.Set("User-Agent", "FreeRollcall-Go/1.0")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Referer", c.baseURL+"/user/index")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		// Do not wrap transport errors: url.Error can contain the endpoint or
		// authentication data supplied by a custom transport.
		if ctx.Err() != nil {
			return nil, errors.New("查询已取消或超时")
		}
		var timeout interface{ Timeout() bool }
		if errors.As(err, &timeout) && timeout.Timeout() {
			return nil, fmt.Errorf("%s查询超时，请稍后重试", subject)
		}
		return nil, fmt.Errorf("%s查询失败，请检查网络后重试", subject)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return nil, fmt.Errorf("%s查询：%w", subject, ErrUnauthenticated)
	}
	if resp.StatusCode == http.StatusForbidden {
		return nil, fmt.Errorf("无权查询%s，请确认账号权限", subject)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s查询失败，服务返回状态码 %d", subject, resp.StatusCode)
	}
	// Cap an unexpectedly large response rather than buffering an arbitrary
	// school error document or roster. No raw response is included in errors.
	const maxResponseBytes = 32 << 20
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil || len(raw) > maxResponseBytes {
		return nil, fmt.Errorf("%s查询返回的数据无法读取", subject)
	}
	trimmed := bytes.TrimSpace(raw)
	if bytes.HasPrefix(bytes.ToLower(trimmed), []byte("<!doctype")) || bytes.HasPrefix(bytes.ToLower(trimmed), []byte("<html")) {
		return nil, fmt.Errorf("%s查询：%w", subject, ErrUnauthenticated)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var result any
	if err := decoder.Decode(&result); err != nil {
		return nil, fmt.Errorf("%s查询返回的数据无法解析，请稍后重试", subject)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("%s查询返回的数据无法解析，请稍后重试", subject)
	}
	return result, nil
}

func (c *Client) Profile(ctx context.Context) (rollcall.Profile, error) {
	data, err := c.read(ctx, http.MethodGet, "/api/profile", "账号信息", nil, nil)
	if err != nil {
		return rollcall.Profile{}, err
	}
	row, ok := data.(map[string]any)
	if !ok {
		return rollcall.Profile{}, malformed("账号信息")
	}
	profile := rollcall.Profile{ID: rollcall.ScalarID(row["id"]), Account: rollcall.ScalarID(row["user_no"])}
	profile.Name, _ = row["name"].(string)
	profile.Email, _ = row["email"].(string)
	if profile.ID == "" || profile.Account == "" {
		return rollcall.Profile{}, malformed("账号信息")
	}
	if profile.Name == "" {
		profile.Name = profile.Account
	}
	return profile, nil
}

func (c *Client) Courses(ctx context.Context) ([]rollcall.Course, error) {
	data, err := c.read(ctx, http.MethodGet, "/api/current-semester-info", "当前学期", nil, nil)
	if err != nil {
		return nil, err
	}
	term, ok := data.(map[string]any)
	if !ok {
		return nil, malformed("当前学期")
	}
	semester, _ := term["semester"].(map[string]any)
	year, _ := term["academic_year"].(map[string]any)
	semesterID, yearID := rollcall.ScalarID(semester["id"]), rollcall.ScalarID(year["id"])
	if semesterID == "" || yearID == "" {
		return nil, errors.New("未能获取当前学期，请稍后重试")
	}
	payload := map[string]any{
		"conditions": map[string]any{"semester_id": []string{semesterID}, "academic_year_id": []string{yearID},
			"keyword": "", "classify_type": "recently_started", "display_studio_list": false},
		"fields": "id,name,display_name", "page_size": 30, "showScorePassedStatus": false,
	}
	seen := make(map[string]bool)
	courses := make([]rollcall.Course, 0)
	for page := 1; page <= 100; page++ {
		payload["page"] = page
		data, err := c.read(ctx, http.MethodPost, "/api/my-courses", "课程列表", nil, payload)
		if err != nil {
			return nil, err
		}
		rows, container, err := queryRows(data, "courses", "课程列表")
		if err != nil {
			return nil, err
		}
		added := 0
		for _, row := range rows {
			id := rollcall.ScalarID(row["id"])
			if id == "" {
				return nil, errors.New("课程列表查询返回的课程编号有误")
			}
			if seen[id] {
				continue
			}
			seen[id] = true
			name, _ := row["display_name"].(string)
			if name == "" {
				name, _ = row["name"].(string)
			}
			if name == "" {
				name = "未命名课程"
			}
			courses = append(courses, rollcall.Course{ID: id, Name: name})
			added++
		}
		more, err := hasMore(data, container, page, 30, len(rows))
		if err != nil {
			return nil, err
		}
		if len(rows) > 0 && added == 0 {
			return nil, errors.New("课程列表分页返回了重复数据，无法确认完整课程列表，请稍后重试")
		}
		if !more {
			return courses, nil
		}
		if len(rows) == 0 {
			return nil, errors.New("课程列表分页数据不完整，请稍后重试")
		}
	}
	return nil, errors.New("课程列表分页数量异常，请稍后重试")
}

func (c *Client) Latest(ctx context.Context, courseID, studentID string) (rollcall.Record, error) {
	if !validID(courseID) || !validID(studentID) {
		return nil, errors.New("课程或学生编号有误")
	}
	path := "/api/course/" + courseID + "/student/" + studentID + "/rollcalls"
	data, err := c.read(ctx, http.MethodGet, path, "签到列表", url.Values{"page": {"1"}, "page_size": {"99"}}, nil)
	if err != nil {
		return nil, err
	}
	rows, _, err := queryRows(data, "rollcalls", "签到列表")
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	latest := rows[len(rows)-1]
	if rollcall.RecordID(latest) == "" {
		return nil, errors.New("签到列表查询返回的签到编号有误")
	}
	return latest, nil
}

func (c *Client) Timetable(ctx context.Context, courseID, date string) ([]rollcall.Record, error) {
	if !validID(courseID) {
		return nil, errors.New("课程编号有误")
	}
	if _, err := parseDate(date); err != nil {
		return nil, err
	}
	data, err := c.read(ctx, http.MethodGet, "/api/timetable_rollcalls", "签到",
		url.Values{"course_ids": {courseID}, "rollcall_date": {date}}, nil)
	if err != nil {
		return nil, err
	}
	root, ok := data.(map[string]any)
	if !ok {
		return nil, malformed("签到")
	}
	values, ok := root["rollcalls"].([]any)
	if !ok {
		return nil, malformed("签到")
	}
	rows := make([]rollcall.Record, 0, len(values))
	for _, value := range values {
		row, ok := value.(map[string]any)
		if !ok {
			return nil, malformed("签到")
		}
		course, _ := row["course"].(map[string]any)
		returnedID := rollcall.ScalarID(course["id"])
		if returnedID == "" {
			returnedID = rollcall.ScalarID(row["course_id"])
		}
		if returnedID == "" || returnedID == courseID {
			rows = append(rows, rollcall.Record(row))
		}
	}
	return rows, nil
}

func (c *Client) Daily(ctx context.Context, courseID, date string) ([]rollcall.Record, error) {
	localDay, err := parseDate(date)
	if err != nil {
		return nil, err
	}
	previousDay := localDay.AddDate(0, 0, -1)
	if previousDay.Year() < 1 {
		return nil, errors.New("查询日期超出支持范围")
	}
	if !validID(courseID) {
		return nil, errors.New("课程编号有误")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		rows []rollcall.Record
		err  error
	}
	// Buffer both replies so caller cancellation cannot strand a sending goroutine.
	results := [2]chan result{make(chan result, 1), make(chan result, 1)}
	for index, day := range []time.Time{previousDay, localDay} {
		go func(index int, day time.Time) {
			rows, err := c.Timetable(ctx, courseID, day.Format("2006-01-02"))
			results[index] <- result{rows, err}
		}(index, day)
	}
	// Consume in UTC-date order regardless of network completion order. No rows
	// escape if either request fails or any response record is malformed.
	rows := make([]rollcall.Record, 0)
	seen := make(map[string]bool)
	for _, channel := range results {
		var reply result
		select {
		case <-ctx.Done():
			return nil, errors.New("查询已取消或超时")
		case reply = <-channel:
		}
		if reply.err != nil {
			return nil, reply.err
		}
		for _, row := range reply.rows {
			startedAt, err := rollcall.RecordTime(row)
			if err != nil {
				return nil, err
			}
			localTime := startedAt.In(rollcall.SchoolTimezone)
			if localTime.Year() < 1 || localTime.Year() > 9999 {
				return nil, errors.New("签到时间超出支持范围，无法确定所属日期")
			}
			if localTime.Format("2006-01-02") != date {
				continue
			}
			id := rollcall.RecordID(row)
			if id == "" {
				return nil, errors.New("签到查询返回的签到编号有误")
			}
			if !seen[id] {
				seen[id] = true
				rows = append(rows, row)
			}
		}
	}
	return rows, nil
}

func (c *Client) Detail(ctx context.Context, courseID, rollcallID, startedAt string) (rollcall.Record, error) {
	if strings.TrimSpace(rollcallID) == "" {
		return nil, errors.New("签到编号缺失或格式有误，无法查询本次签到")
	}
	started, err := rollcall.ParseTime(startedAt)
	if err != nil {
		return nil, err
	}
	utcDate := started.UTC()
	if utcDate.Year() < 1 || utcDate.Year() > 9999 {
		return nil, errors.New("签到时间超出支持范围，无法确定签到查询日期")
	}
	rows, err := c.Timetable(ctx, courseID, utcDate.Format("2006-01-02"))
	if err != nil {
		return nil, err
	}
	for _, row := range rows {
		if rollcall.RecordID(row) == rollcallID {
			return row, nil
		}
	}
	return nil, errors.New("该日期的查询结果中未找到本次签到，请重新选择课程重试")
}

func malformed(subject string) error {
	return fmt.Errorf("%s查询返回的数据格式有误", subject)
}

func validID(value string) bool {
	if value == "" {
		return false
	}
	nonzero := false
	for _, c := range value {
		if c < '0' || c > '9' {
			return false
		}
		nonzero = nonzero || c != '0'
	}
	return nonzero
}

func parseDate(value string) (time.Time, error) {
	parsed, err := time.ParseInLocation("2006-01-02", value, rollcall.SchoolTimezone)
	if err != nil || parsed.Year() < 1 || parsed.Year() > 9999 || parsed.Format("2006-01-02") != value {
		return time.Time{}, errors.New("查询日期有误，请使用 YYYY-MM-DD 格式的有效日期")
	}
	return parsed, nil
}

func queryRows(data any, key, subject string) ([]rollcall.Record, map[string]any, error) {
	container := data
	root, _ := data.(map[string]any)
	if root != nil {
		if _, exists := root[key]; !exists {
			if nested, ok := root["data"].(map[string]any); ok {
				container = nested
			}
		}
	}
	object, _ := container.(map[string]any)
	var values []any
	var ok bool
	if object != nil {
		value, exists := object[key]
		if !exists {
			value = object["data"]
		}
		values, ok = value.([]any)
	} else {
		values, ok = container.([]any)
	}
	if !ok {
		return nil, nil, malformed(subject)
	}
	rows := make([]rollcall.Record, 0, len(values))
	for _, value := range values {
		row, ok := value.(map[string]any)
		if !ok {
			return nil, nil, malformed(subject)
		}
		rows = append(rows, rollcall.Record(row))
	}
	return rows, object, nil
}

func hasMore(data any, container map[string]any, page, pageSize, count int) (bool, error) {
	root, _ := data.(map[string]any)
	for _, key := range []string{"has_more", "pages", "total"} {
		value := container[key]
		if value == nil {
			value = root[key]
		}
		if value == nil {
			continue
		}
		if key == "has_more" {
			flag, ok := value.(bool)
			if !ok {
				return false, errors.New("课程列表查询返回的分页信息有误")
			}
			return flag, nil
		}
		text := rollcall.ScalarID(value)
		for _, digit := range text {
			if digit < '0' || digit > '9' {
				text = ""
				break
			}
		}
		number, err := strconv.ParseUint(text, 10, 64)
		if err != nil {
			return false, errors.New("课程列表查询返回的分页信息有误")
		}
		if key == "pages" {
			return uint64(page) < number, nil
		}
		return uint64(page*pageSize) < number, nil
	}
	return count >= pageSize, nil
}

package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"freerollcall/internal/rollcall"
)

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func semester(w http.ResponseWriter) {
	writeJSON(w, map[string]any{"semester": map[string]any{"id": 29}, "academic_year": map[string]any{"id": "12"}})
}

func TestProfileUsesSharedCookiesAndPreservesNumericIdentifiers(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/profile" || r.Method != http.MethodGet {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		cookie, err := r.Cookie("session")
		if err != nil || cookie.Value != "offline-cookie" {
			t.Error("shared login cookie not present")
		}
		writeJSON(w, map[string]any{"id": json.Number("9007199254740993"), "user_no": "20260001", "email": "student@example.edu"})
	}))
	defer server.Close()
	httpClient := NewHTTPClient()
	endpoint, _ := url.Parse(server.URL)
	httpClient.Jar.SetCookies(endpoint, []*http.Cookie{{Name: "session", Value: "offline-cookie", Path: "/"}})
	api := New(server.URL, httpClient)
	if api.http.Jar != httpClient.Jar || api.http.Timeout != 15*time.Second {
		t.Fatal("client did not preserve shared jar and timeout")
	}
	got, err := api.Profile(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "9007199254740993" || got.Account != "20260001" || got.Name != got.Account || !got.Matches("STUDENT@EXAMPLE.EDU") {
		t.Fatalf("profile = %#v", got)
	}
}

func TestProfileErrorsAreSafeAndRedirectsAreNeverFollowed(t *testing.T) {
	for _, test := range []struct {
		name, body string
		status     int
		unauth     bool
	}{
		{"unauthorized", "private-response", 401, true},
		{"forbidden", "private-response", 403, false},
		{"redirect", "private-response", 302, true},
		{"html", "<!DOCTYPE html><html>private-response</html>", 200, true},
		{"invalid-json", "private-response", 200, false},
		{"trailing-json", `{"id":1,"user_no":"test"} {"secret":"private-response"}`, 200, false},
		{"server-error", "private-response", 500, false},
		{"invalid-profile", `{"id":1}`, 200, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.Header().Set("Location", "/private-response")
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			api := New(server.URL, server.Client())
			_, err := api.Profile(context.Background())
			if err == nil {
				t.Fatal("expected an error")
			}
			if errors.Is(err, ErrUnauthenticated) != test.unauth {
				t.Fatalf("unauthenticated = %v, error %v", errors.Is(err, ErrUnauthenticated), err)
			}
			if strings.Contains(err.Error(), "private-response") || strings.Contains(err.Error(), server.URL) || calls.Load() != 1 {
				t.Fatalf("unsafe error or followed redirect: %v, calls %d", err, calls.Load())
			}
		})
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestTransportErrorNeverLeaksRawDetails(t *testing.T) {
	api := New("https://offline.example", &http.Client{Transport: roundTripperFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("private-cookie private-password private-url")
	})})
	_, err := api.Profile(context.Background())
	if err == nil || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "offline.example") {
		t.Fatalf("unsafe transport error: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := api.Profile(ctx); err == nil || strings.Contains(err.Error(), "private") {
		t.Fatalf("unsafe cancellation error: %v", err)
	}
}

func TestCoursesPaginatesDeduplicatesAndKeepsFirstOrder(t *testing.T) {
	var pages []int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/current-semester-info" {
			semester(w)
			return
		}
		if r.URL.Path != "/api/my-courses" || r.Method != http.MethodPost {
			t.Errorf("unexpected query %s %s", r.Method, r.URL.Path)
		}
		var body struct {
			Page       int `json:"page"`
			PageSize   int `json:"page_size"`
			Conditions struct {
				Semester []string `json:"semester_id"`
				Year     []string `json:"academic_year_id"`
			} `json:"conditions"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body.PageSize != 30 || !reflect.DeepEqual(body.Conditions.Semester, []string{"29"}) || !reflect.DeepEqual(body.Conditions.Year, []string{"12"}) {
			t.Errorf("unexpected request body %#v", body)
		}
		pages = append(pages, body.Page)
		if body.Page == 1 {
			rows := make([]any, 30)
			for i := range rows {
				rows[i] = map[string]any{"id": i + 1, "name": fmt.Sprintf("课程%d", i+1)}
			}
			writeJSON(w, map[string]any{"courses": rows, "total": 31})
		} else {
			writeJSON(w, map[string]any{"data": map[string]any{"courses": []any{
				map[string]any{"id": "30", "display_name": "重复课程"},
				map[string]any{"id": 31, "name": "旧名称", "display_name": "展示名称"},
			}, "total": 31}})
		}
	}))
	defer server.Close()
	courses, err := New(server.URL, server.Client()).Courses(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(pages, []int{1, 2}) || len(courses) != 31 || courses[29].Name != "课程30" || courses[30].Name != "展示名称" {
		t.Fatalf("courses = %#v, pages %v", courses, pages)
	}
}

func TestCourseResponseShapesAndPaginationFailures(t *testing.T) {
	for _, test := range []struct {
		name, body string
		fail       bool
	}{
		{"list", `[{"id":1,"name":"one"}]`, false},
		{"legacy", `{"data":[{"id":"1","name":"one"}]}`, false},
		{"nested", `{"data":{"courses":[{"id":1}],"has_more":false}}`, false},
		{"named-wins", `{"courses":[{"id":1}],"data":[{"id":2}]}`, false},
		{"invalid-pagination", `{"courses":[{"id":1}],"has_more":"false"}`, true},
		{"invalid-total", `{"courses":[{"id":1}],"total":true}`, true},
		{"incomplete", `{"courses":[],"has_more":true}`, true},
		{"repeated", `{"courses":[{"id":1}],"has_more":true}`, true},
		{"bad-row", `{"courses":[null]}`, true},
		{"bad-id", `{"courses":[{"id":true}]}`, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/current-semester-info" {
					semester(w)
					return
				}
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			rows, err := New(server.URL, server.Client()).Courses(context.Background())
			if (err != nil) != test.fail {
				t.Fatalf("courses %#v, error %v", rows, err)
			}
			if test.fail && rows != nil {
				t.Fatal("failed pagination returned partial data")
			}
			if !test.fail && (len(rows) != 1 || rows[0].ID != "1") {
				t.Fatalf("unexpected courses %#v", rows)
			}
		})
	}
}

func TestLatestPreservesLastItemAnd99RecordPage(t *testing.T) {
	var empty atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/course/10/student/20/rollcalls" || r.URL.Query().Get("page") != "1" || r.URL.Query().Get("page_size") != "99" {
			t.Errorf("unexpected latest request %s", r.URL.RequestURI())
		}
		if empty.Load() {
			writeJSON(w, map[string]any{"rollcalls": []any{}})
			return
		}
		writeJSON(w, map[string]any{"rollcalls": []any{
			map[string]any{"id": 1, "rollcall_time": "2026-10-09T00:00:00Z"},
			map[string]any{"rollcall_id": "2", "created_at": "2026-10-08T00:00:00Z"},
		}})
	}))
	defer server.Close()
	api := New(server.URL, server.Client())
	row, err := api.Latest(context.Background(), "10", "20")
	if err != nil || rollcall.RecordID(row) != "2" {
		t.Fatalf("latest = %#v, %v", row, err)
	}
	empty.Store(true)
	row, err = api.Latest(context.Background(), "10", "20")
	if row != nil || err != nil {
		t.Fatalf("empty latest = %#v, %v", row, err)
	}
}

func TestDetailUsesUTCDayFiltersCoursesAndKeepsLeadingZeroCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/timetable_rollcalls" || r.URL.Query().Get("course_ids") != "10" || r.URL.Query().Get("rollcall_date") != "2026-10-07" {
			t.Errorf("unexpected detail request %s", r.URL.RequestURI())
		}
		writeJSON(w, map[string]any{"rollcalls": []any{
			map[string]any{"id": 7, "course": map[string]any{"id": 99}, "number_code": "WRONG"},
			map[string]any{"id": "7", "course_id": 10, "number_code": "0539", "status": "finished"},
		}})
	}))
	defer server.Close()
	row, err := New(server.URL, server.Client()).Detail(context.Background(), "10", "7", "2026-10-08T01:03:17+08:00")
	if err != nil || row["number_code"] != "0539" || row["status"] != "finished" {
		t.Fatalf("detail = %#v, %v", row, err)
	}
}

func TestDailyQueriesConcurrentlyButMergesInUTCDateOrder(t *testing.T) {
	started := make(chan string, 2)
	gate := make(chan struct{})
	currentDone := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		day := r.URL.Query().Get("rollcall_date")
		started <- day
		select {
		case <-gate:
		case <-r.Context().Done():
			return
		}
		if day == "2026-10-14" {
			<-currentDone
			writeJSON(w, map[string]any{"rollcalls": []any{
				map[string]any{"id": 0, "rollcall_time": "2026-10-14T15:59:59Z"},
				map[string]any{"id": 1, "rollcall_time": "2026-10-14T16:00:00Z", "number_code": "0001"},
				map[string]any{"id": 2, "rollcall_time": "2026-10-14T23:59:59Z"},
			}})
		} else {
			writeJSON(w, map[string]any{"rollcalls": []any{
				map[string]any{"id": "1", "rollcall_time": "2026-10-14T16:00:00Z", "number_code": "0002"},
				map[string]any{"id": 3, "rollcall_time": "2026-10-15T00:00:00Z"},
				map[string]any{"id": 4, "rollcall_time": "2026-10-15T16:00:00Z"},
			}})
			close(currentDone)
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	type reply struct {
		rows []rollcall.Record
		err  error
	}
	done := make(chan reply, 1)
	go func() {
		rows, err := New(server.URL, server.Client()).Daily(ctx, "10", "2026-10-15")
		done <- reply{rows, err}
	}()
	for i := 0; i < 2; i++ {
		select {
		case <-started:
		case <-ctx.Done():
			close(gate)
			t.Fatal("both UTC-date requests did not start concurrently")
		}
	}
	close(gate)
	result := <-done
	if result.err != nil {
		t.Fatal(result.err)
	}
	ids := make([]string, 0, len(result.rows))
	for _, row := range result.rows {
		ids = append(ids, rollcall.RecordID(row))
	}
	if !reflect.DeepEqual(ids, []string{"1", "2", "3"}) || result.rows[0]["number_code"] != "0001" {
		t.Fatalf("daily ordering/dedup = %#v", result.rows)
	}
}

func TestDailyFailureNeverReturnsPartialRecords(t *testing.T) {
	for _, invalidBody := range []string{"", `{"rollcalls":[{"id":2}]}`} {
		t.Run(invalidBody, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("rollcall_date") == "2026-10-14" {
					writeJSON(w, map[string]any{"rollcalls": []any{map[string]any{"id": 1, "rollcall_time": "2026-10-14T16:00:00Z"}}})
					return
				}
				if invalidBody == "" {
					w.WriteHeader(500)
					return
				}
				_, _ = w.Write([]byte(invalidBody))
			}))
			defer server.Close()
			rows, err := New(server.URL, server.Client()).Daily(context.Background(), "10", "2026-10-15")
			if err == nil || rows != nil {
				t.Fatalf("partial daily records returned: %#v, %v", rows, err)
			}
		})
	}
}

func TestInvalidArgumentsNeverSendRequests(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer server.Close()
	api := New(server.URL, server.Client())
	ctx := context.Background()
	for _, value := range []string{"", "2026-02-30", "2026-1-1", "20261015", "0000-01-01", "0001-01-01"} {
		if _, err := api.Daily(ctx, "10", value); err == nil {
			t.Errorf("accepted invalid daily date %q", value)
		}
	}
	if _, err := api.Latest(ctx, "10/private", "20"); err == nil {
		t.Error("accepted invalid course ID")
	}
	if _, err := api.Detail(ctx, "10", "7", ""); err == nil {
		t.Error("accepted missing detail timestamp")
	}
	if calls.Load() != 0 {
		t.Fatalf("invalid arguments caused %d requests", calls.Load())
	}
}

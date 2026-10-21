package rollcall

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestParseTimeUsesSchoolTimezoneAndUTCDay(t *testing.T) {
	for _, test := range []struct {
		input, utc, local string
	}{
		{"2026-10-08T00:03:17Z", "2026-10-08T00:03:17Z", "2026-10-08"},
		{"2026-10-08T01:03:17+08:00", "2026-10-07T17:03:17Z", "2026-10-08"},
		{"2026-10-08T07:56:23", "2026-10-07T23:56:23Z", "2026-10-08"},
		{"2026-01-01 00:00:00", "2025-12-31T16:00:00Z", "2026-01-01"},
		{"2026-10-07T12:03:17-05:00", "2026-10-07T17:03:17Z", "2026-10-08"},
		{"2026-10-08T08:00:00.123456+0800", "2026-10-08T00:00:00Z", "2026-10-08"},
	} {
		t.Run(test.input, func(t *testing.T) {
			parsed, err := ParseTime(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if got := parsed.UTC().Format("2006-01-02T15:04:05Z"); got != test.utc {
				t.Fatalf("UTC = %s, want %s", got, test.utc)
			}
			if got := parsed.In(SchoolTimezone).Format("2006-01-02"); got != test.local {
				t.Fatalf("school day = %s, want %s", got, test.local)
			}
		})
	}
	for _, value := range []string{"", "not-a-time", "2026-02-30T00:00:00Z", "0000-01-01T00:00:00Z"} {
		if _, err := ParseTime(value); err == nil {
			t.Errorf("ParseTime(%q) unexpectedly succeeded", value)
		}
	}
}

func TestRecordIdentityAndTimeFallback(t *testing.T) {
	row := Record{"id": json.Number("9007199254740993"), "rollcall_id": 9,
		"rollcall_time": "", "created_at": "2026-10-08T01:00:00+08:00"}
	if got := RecordID(row); got != "9007199254740993" {
		t.Fatalf("RecordID = %q", got)
	}
	if RecordStartedAt(row) != row["created_at"] {
		t.Fatal("created_at fallback was not retained verbatim")
	}
	if parsed, err := RecordTime(row); err != nil || parsed.UTC().Format("2006-01-02") != "2026-10-07" {
		t.Fatalf("RecordTime = %v, %v", parsed, err)
	}
	if got := RecordID(Record{"id": false, "rollcall_id": "7"}); got != "7" {
		t.Fatalf("invalid primary ID fallback = %q", got)
	}
	if got := RecordID(Record{"id": "0", "rollcall_id": "7"}); got != "0" {
		t.Fatalf("string zero must not use numeric-zero fallback: %q", got)
	}
	if got := RecordID(Record{"id": true, "rollcall_id": "7"}); got != "" {
		t.Fatalf("invalid truthy primary ID must not hide malformed data: %q", got)
	}
	for _, invalid := range []any{true, 1.25, json.Number("1.5"), " ", nil} {
		if got := ScalarID(invalid); got != "" {
			t.Errorf("ScalarID(%v) = %q", invalid, got)
		}
	}
}

func TestProfileMatchesAccountOrEmail(t *testing.T) {
	profile := Profile{ID: "7", Account: "Student001", Email: "student@example.edu"}
	for _, value := range []string{"Student001", "STUDENT@EXAMPLE.EDU"} {
		if !profile.Matches(value) {
			t.Errorf("expected %q to match", value)
		}
	}
	for _, value := range []string{"", "student001", "7", "another@example.edu"} {
		if profile.Matches(value) {
			t.Errorf("unexpected identity match %q", value)
		}
	}
	if (Profile{}).Matches("") {
		t.Fatal("empty identities must not match")
	}
}

func TestSummarizeDeduplicatesAndDoesNotGuessUnknownStates(t *testing.T) {
	row := Record{"student_rollcalls": []any{
		map[string]any{"id": 10, "student_id": 1, "status": "on_call"},
		map[string]any{"id": 11, "student_id": "1", "status": "on_call"},
		map[string]any{"id": 12, "student_id": 2, "status": "absent"},
		map[string]any{"id": 13, "student_id": 3, "status": "present"},
		map[string]any{"id": 14, "student_id": 3, "status": "absent"},
		map[string]any{"student_id": 4, "status": "not_on_call"},
		map[string]any{"student_id": 5, "status": nil, "rollcall_status": " LATE "},
		map[string]any{"id": 99, "status": "unknown"},
		map[string]any{"id": "99", "status": "unknown"},
		map[string]any{"status": "on_call_fine"},
		map[string]any{"status": "on_call_late"},
	}}
	before, _ := json.Marshal(row)
	result, err := Summarize(row)
	if err != nil {
		t.Fatal(err)
	}
	want := Summary{Total: 8, Signed: 4, Unsigned: 1, Unknown: 3, StatusCounts: map[string]int{
		"on_call": 1, "absent": 1, "conflict": 1, "not_on_call": 1, "late": 1,
		"unknown": 1, "on_call_fine": 1, "on_call_late": 1,
	}}
	if !reflect.DeepEqual(result, want) {
		t.Fatalf("summary = %#v, want %#v", result, want)
	}
	after, _ := json.Marshal(row)
	if string(before) != string(after) {
		t.Fatal("summary mutated the roster")
	}
}

func TestSummarizeEmptyAndMalformedRoster(t *testing.T) {
	for _, value := range []any{[]any{}, []Record{}} {
		got, err := Summarize(Record{"student_rollcalls": value})
		if err != nil || got.Total != 0 || got.StatusCounts == nil {
			t.Fatalf("empty roster = %#v, %v", got, err)
		}
	}
	for _, value := range []any{nil, "roster", []any{1}, []any{nil}, []Record{nil}} {
		if _, err := Summarize(Record{"student_rollcalls": value}); err == nil {
			t.Errorf("accepted malformed roster %#v", value)
		}
	}
}

// Package rollcall contains the school-independent query and attendance rules.
package rollcall

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

type Record map[string]any

type Course struct {
	ID   string
	Name string
}

type Profile struct {
	ID      string
	Account string
	Name    string
	Email   string
}

func (p Profile) Matches(username string) bool {
	return username != "" && (p.Account == username || p.Email != "" && strings.EqualFold(p.Email, username))
}

type Summary struct {
	Total        int
	Signed       int
	Unsigned     int
	Unknown      int
	StatusCounts map[string]int
}

// SchoolTimezone is fixed at UTC+8, including when the host has another timezone.
var SchoolTimezone = time.FixedZone("Asia/Shanghai", 8*60*60)

// ParseTime follows the Python client's rule: a timestamp without an offset is
// school local time. Dates used by the timetable API are derived separately in UTC.
func ParseTime(value string) (time.Time, error) {
	for _, layout := range []string{
		time.RFC3339Nano,
		"2006-01-02T15:04:05.999999999-0700",
		"2006-01-02T15:04:05.999999999-07",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02 15:04:05.999999999-0700",
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02T15:04",
		"2006-01-02 15:04",
		"2006-01-02",
	} {
		parsed, err := time.ParseInLocation(layout, value, SchoolTimezone)
		if err == nil && parsed.Year() >= 1 && parsed.Year() <= 9999 {
			return parsed, nil
		}
	}
	return time.Time{}, errors.New("签到时间缺失或格式有误，无法确定签到查询日期")
}

// ScalarID normalizes string and integer JSON identifiers without converting
// numeric strings (or codes) to numbers or losing large integer precision.
func ScalarID(value any) string {
	switch v := value.(type) {
	case string:
		if strings.TrimSpace(v) != "" {
			return v
		}
	case json.Number:
		text := string(v)
		if isInteger(text) {
			return text
		}
	case int:
		return strconv.Itoa(v)
	case int64:
		return strconv.FormatInt(v, 10)
	case int32:
		return strconv.FormatInt(int64(v), 10)
	case uint64:
		return strconv.FormatUint(v, 10)
	case uint:
		return strconv.FormatUint(uint64(v), 10)
	case float64:
		// Decoded network data uses json.Number; float64 is accepted for callers
		// constructing records directly, only while its integer value is exact.
		if !math.IsNaN(v) && !math.IsInf(v, 0) && math.Trunc(v) == v && math.Abs(v) <= 1<<53 {
			return strconv.FormatFloat(v, 'f', 0, 64)
		}
	}
	return ""
}

func isInteger(value string) bool {
	if strings.HasPrefix(value, "-") {
		value = value[1:]
	}
	if value == "" {
		return false
	}
	for _, c := range value {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func RecordID(record Record) string {
	value := record["id"]
	if !truthy(value) {
		value = record["rollcall_id"]
	}
	return ScalarID(value)
}

func truthy(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return v != ""
	case json.Number:
		parsed, err := strconv.ParseFloat(string(v), 64)
		return err != nil || parsed != 0
	case int:
		return v != 0
	case int64:
		return v != 0
	case float64:
		return v != 0
	case []any:
		return len(v) != 0
	case map[string]any:
		return len(v) != 0
	}
	return true
}

func RecordTime(record Record) (time.Time, error) {
	return ParseTime(RecordStartedAt(record))
}

func RecordStartedAt(record Record) string {
	value := record["rollcall_time"]
	if !truthy(value) {
		value = record["created_at"]
	}
	text, _ := value.(string)
	return text
}

func Summarize(record Record) (Summary, error) {
	rows, ok := rosterRows(record["student_rollcalls"])
	if !ok {
		return Summary{}, errors.New("签到查询未返回有效学生名单，无法统计人数")
	}
	states := make(map[string]map[string]struct{})
	for index, row := range rows {
		identity := fmt.Sprintf("row:%d", index)
		for _, field := range []string{"student_id", "id"} {
			if id := ScalarID(row[field]); id != "" {
				identity = field + ":" + id
				break
			}
		}
		statusValue := row["status"]
		if statusValue == nil {
			statusValue = row["rollcall_status"]
		}
		status, _ := statusValue.(string)
		status = strings.ToLower(strings.TrimSpace(status))
		if status == "" {
			status = "unknown"
		}
		if states[identity] == nil {
			states[identity] = make(map[string]struct{})
		}
		states[identity][status] = struct{}{}
	}
	result := Summary{Total: len(states), StatusCounts: make(map[string]int)}
	for _, statuses := range states {
		status := "conflict"
		if len(statuses) == 1 {
			for value := range statuses {
				status = value
			}
		}
		switch status {
		case "on_call", "on_call_fine", "on_call_late", "present", "attended", "late":
			result.Signed++
		case "absent":
			result.Unsigned++
		default:
			result.Unknown++
		}
		result.StatusCounts[status]++
	}
	return result, nil
}

func rosterRows(value any) ([]Record, bool) {
	switch rows := value.(type) {
	case []Record:
		for _, row := range rows {
			if row == nil {
				return nil, false
			}
		}
		return rows, true
	case []any:
		result := make([]Record, 0, len(rows))
		for _, value := range rows {
			var row Record
			switch v := value.(type) {
			case map[string]any:
				row = Record(v)
			case Record:
				row = v
			default:
				return nil, false
			}
			if row == nil {
				return nil, false
			}
			result = append(result, row)
		}
		return result, true
	}
	return nil, false
}

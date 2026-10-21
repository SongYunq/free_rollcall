// Package store reads the Go CLI's file-based account configuration.
package store

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type Account struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// ResolveDir defaults to accounts beside the executable, independent of cwd.
func ResolveDir(explicit string) (string, error) {
	if explicit != "" {
		dir, err := filepath.Abs(explicit)
		if err != nil {
			return "", fmt.Errorf("无法确定账号目录")
		}
		return dir, nil
	}
	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("无法确定程序位置，请使用 --config-dir 指定账号目录")
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	return filepath.Join(filepath.Dir(executable), "accounts"), nil
}

// Load never prompts for credentials and never overwrites an existing account.
func Load(dir string) (Account, error) {
	path := filepath.Join(dir, "account.json")
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return Account{}, fmt.Errorf("无法创建账号目录，请手动创建 %s", dir)
		}
		created, createErr := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if os.IsExist(createErr) {
			return Load(dir)
		}
		if createErr != nil {
			return Account{}, fmt.Errorf("无法创建账号文件，请手动创建 %s", path)
		}
		_, writeErr := io.WriteString(created, "{\n  \"username\": \"\",\n  \"password\": \"\"\n}\n")
		closeErr := created.Close()
		if writeErr != nil || closeErr != nil {
			return Account{}, fmt.Errorf("无法写入账号模板，请检查 %s", path)
		}
		return Account{}, fmt.Errorf("已创建空白账号文件，请填写 username 和 password 后重新运行：%s", path)
	}
	if err != nil {
		return Account{}, fmt.Errorf("无法读取账号文件：%s", path)
	}
	defer file.Close()
	// Bound configuration size and never echo malformed content or passwords.
	data, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(data) > 65536 {
		return Account{}, fmt.Errorf("账号文件无法读取或过大：%s", path)
	}
	var account Account
	if err := json.Unmarshal(data, &account); err != nil {
		return Account{}, fmt.Errorf("账号文件格式有误，username 和 password 必须为字符串：%s", path)
	}
	account.Username = strings.TrimSpace(account.Username)
	if account.Username == "" || account.Password == "" {
		return Account{}, fmt.Errorf("请在账号文件填写 username 和 password：%s", path)
	}
	return account, nil
}

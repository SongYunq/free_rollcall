package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMissingAccountCreatesTemplateWithoutOverwriting(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "accounts")
	if _, err := Load(dir); err == nil {
		t.Fatal("missing account must ask user to fill the file")
	}
	path := filepath.Join(dir, "account.json")
	content := []byte(`{"username":" user ","password":" secret "}`)
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	account, err := Load(dir)
	if err != nil || account.Username != "user" || account.Password != " secret " {
		t.Fatalf("account must trim username only: %#v %v", account.Username, err)
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(content) {
		t.Fatal("existing account was overwritten")
	}
}

func TestMalformedAccountDoesNotLeakCredentials(t *testing.T) {
	for _, data := range []string{
		`{"username":"user","password":123,"secret":"sensitive-marker"}`,
		`{"username":"user","password":"sensitive-marker"} trailing`,
		`null`, `[]`, `{"username":"","password":"sensitive-marker"}`,
	} {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "account.json"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Load(dir)
		if err == nil || strings.Contains(err.Error(), "sensitive-marker") {
			t.Fatalf("expected safe configuration error, got %v", err)
		}
	}
}

func TestDefaultDirectoryIsBesideExecutable(t *testing.T) {
	dir, err := ResolveDir("")
	if err != nil || !filepath.IsAbs(dir) || filepath.Base(dir) != "accounts" {
		t.Fatalf("unexpected default directory %q: %v", dir, err)
	}
	explicit, err := ResolveDir("custom-accounts")
	if err != nil || !filepath.IsAbs(explicit) || filepath.Base(explicit) != "custom-accounts" {
		t.Fatalf("unexpected explicit directory %q: %v", explicit, err)
	}
}

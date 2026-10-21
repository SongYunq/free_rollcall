package auth

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"freerollcall/internal/client"
	"freerollcall/internal/store"
)

type fakeBrowser struct {
	location  string
	base      string
	states    []string
	index     int
	submits   int
	navigated []string
	cause     error
}

func (b *fakeBrowser) Navigate(_ context.Context, url string) error {
	b.navigated = append(b.navigated, url)
	return b.cause
}
func (b *fakeBrowser) Location(context.Context) (string, error) { return b.location, nil }
func (b *fakeBrowser) Cookies(context.Context, string) ([]*http.Cookie, error) {
	return []*http.Cookie{{Name: "session", Value: "offline-auth-cookie", Path: "/"}}, nil
}
func (b *fakeBrowser) Evaluate(_ context.Context, script string, target any) error {
	out, ok := target.(*string)
	if !ok {
		return nil
	}
	if script == observeScript {
		if b.index < len(b.states) {
			*out = b.states[b.index]
			b.index++
		} else {
			*out = "waiting"
		}
		return nil
	}
	b.submits++
	*out = "submitted"
	if len(b.states) == 1 {
		b.location = b.base + "/home"
	}
	return nil
}

func TestAuthenticateReadsProfileWithoutCourseNavigation(t *testing.T) {
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.URL.Path != "/api/profile" {
			t.Errorf("unexpected authentication request: %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		cookie, err := r.Cookie("session")
		if err != nil || cookie.Value != "offline-auth-cookie" {
			t.Error("browser session was not transferred")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"id": 41156, "user_no": "learner", "name": "测试账号"})
	}))
	defer server.Close()
	browser := &fakeBrowser{location: identityOrigin + "/login", base: server.URL, states: []string{"ready"}}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	session, err := authenticate(ctx, browser, client.NewHTTPClient(), store.Account{
		Username: "learner", Password: "offline-password",
	}, Options{}, server.URL, identityOrigin)
	if err != nil || session.Profile.ID != "41156" || browser.submits != 1 {
		t.Fatalf("authentication failed: %v, submissions=%d", err, browser.submits)
	}
	if len(paths) != 1 || len(browser.navigated) != 1 || browser.navigated[0] != server.URL {
		t.Fatalf("unexpected requests or page navigation: %v %v", paths, browser.navigated)
	}
}

func TestAuthenticateRejectsMismatchedProfile(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"id":1,"user_no":"another-account"}`))
	}))
	defer server.Close()
	browser := &fakeBrowser{location: server.URL + "/home", base: server.URL}
	_, err := authenticate(context.Background(), browser, client.NewHTTPClient(),
		store.Account{Username: "learner", Password: "secret-marker"}, Options{}, server.URL, identityOrigin)
	if err == nil || !strings.Contains(err.Error(), "不一致") || strings.Contains(err.Error(), "secret-marker") {
		t.Fatalf("expected safe identity mismatch error, got %v", err)
	}
}

func TestCredentialFailuresNeverPromptOrExposePassword(t *testing.T) {
	for _, states := range [][]string{{"manual"}, {"ready", "invalid"}, {"error"}} {
		browser := &fakeBrowser{location: identityOrigin + "/login", base: schoolURL, states: states}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		_, err := authenticate(ctx, browser, client.NewHTTPClient(),
			store.Account{Username: "learner", Password: "secret-marker"}, Options{}, schoolURL, identityOrigin)
		cancel()
		if err == nil || strings.Contains(err.Error(), "secret-marker") {
			t.Fatalf("expected safe credential/verification error, got %v", err)
		}
		if browser.submits > 1 {
			t.Fatal("credentials must never be repeatedly submitted")
		}
	}
}

func TestCredentialsNeverSubmittedToOtherOrigins(t *testing.T) {
	browser := &fakeBrowser{location: "https://untrusted.example/login", states: []string{"ready"}}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := authenticate(ctx, browser, client.NewHTTPClient(),
		store.Account{Username: "learner", Password: "secret-marker"}, Options{}, schoolURL, identityOrigin)
	if err == nil || browser.submits != 0 || browser.index != 0 {
		t.Fatalf("untrusted origin must not receive credentials: %v", err)
	}
}

func TestDriverErrorIsRedactedAndCancellationPreserved(t *testing.T) {
	browser := &fakeBrowser{cause: errors.New("driver echoed secret-marker")}
	_, err := authenticate(context.Background(), browser, client.NewHTTPClient(), store.Account{}, Options{}, schoolURL, identityOrigin)
	if err == nil || strings.Contains(err.Error(), "secret-marker") {
		t.Fatalf("unsafe driver error: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if !errors.Is(browserFailure(ctx, "safe message"), context.Canceled) {
		t.Fatal("cancellation identity was lost")
	}
}

func TestCredentialScriptUsesJSONEncoding(t *testing.T) {
	account := store.Account{Username: `learner'\"`, Password: "quote'\"\\\n<marker>"}
	script := credentialScript(account, identityOrigin)
	for _, value := range []string{account.Username, account.Password, identityOrigin} {
		encoded, _ := json.Marshal(value)
		if !strings.Contains(script, string(encoded)) {
			t.Fatal("credentials must be encoded as JSON literals")
		}
	}
}

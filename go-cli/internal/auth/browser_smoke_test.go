package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"freerollcall/internal/client"
	"freerollcall/internal/store"
	"github.com/chromedp/chromedp"
)

// Opt in to real Chromium against an entirely local fixture, never the school.
func TestLocalBrowserAuthentication(t *testing.T) {
	if os.Getenv("ROLLCALL_BROWSER_TEST") != "1" {
		t.Skip("set ROLLCALL_BROWSER_TEST=1 to run the local Chromium fixture")
	}
	var mu sync.Mutex
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.Path)
		mu.Unlock()
		switch r.URL.Path {
		case "/api/profile":
			if cookie, err := r.Cookie("fixture"); err != nil || cookie.Value != "session" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 710001, "user_no": "learner"})
		case "/":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!doctype html><html><body>
<form id="pwdFromId"><input id="username"><input id="password" type="password"><input id="captcha">
<div id="showErrorTip" style="display:none"></div><button id="login_submit" type="button">登录</button></form>
<script>document.querySelector('#login_submit').onclick=()=>{
 if(document.querySelector('#username').value==='learner' && document.querySelector('#password').value==='test-password'){
 document.cookie='fixture=session;path=/'; location.href='/home';
 }else{let e=document.querySelector('#showErrorTip');e.textContent='账号或密码错误';e.style.display='block';}
};
// Simulate completing the CAPTCHA only after the file credentials were filled.
const completion=setInterval(()=>{
 if(document.querySelector('#username').value==='learner' && document.querySelector('#password').value==='test-password'){
 document.querySelector('#captcha')?.remove();clearInterval(completion);
 }
},30);
</script></body></html>`))
		case "/home":
			_, _ = w.Write([]byte("<html><body>authenticated</body></html>"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	options := append([]chromedp.ExecAllocatorOption{}, chromedp.DefaultExecAllocatorOptions[:]...)
	if path := os.Getenv("ROLLCALL_BROWSER_PATH"); path != "" {
		options = append(options, chromedp.ExecPath(path))
	}
	allocator, closeAllocator := chromedp.NewExecAllocator(ctx, options...)
	defer closeAllocator()
	browserCtx, closeBrowser := chromedp.NewContext(allocator, chromedp.WithErrorf(func(string, ...any) {}))
	defer closeBrowser()
	session, err := authenticate(browserCtx, chromeDriver{}, client.NewHTTPClient(),
		store.Account{Username: "learner", Password: "test-password"}, Options{ShowBrowser: true}, server.URL, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if session.Profile.ID != "710001" {
		t.Fatal("student ID was not read from /api/profile")
	}
	mu.Lock()
	defer mu.Unlock()
	for _, path := range paths {
		if path != "/" && path != "/home" && path != "/api/profile" && path != "/favicon.ico" {
			t.Fatalf("unexpected browser or API path %q", path)
		}
	}
}

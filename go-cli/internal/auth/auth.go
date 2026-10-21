// Package auth authenticates through the school's own form, then reads /api/profile.
package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"freerollcall/internal/client"
	"freerollcall/internal/rollcall"
	"freerollcall/internal/store"

	"github.com/chromedp/chromedp"
)

const schoolURL = "https://lnt.xmu.edu.cn"
const identityOrigin = "https://ids.xmu.edu.cn"

type Options struct {
	BrowserPath string
	ShowBrowser bool
	Log         func(string)
}

type Session struct {
	Profile rollcall.Profile
	Client  *client.Client
}

func Login(ctx context.Context, account store.Account, options Options) (*Session, error) {
	if strings.TrimSpace(account.Username) == "" || account.Password == "" {
		return nil, fmt.Errorf("请先在账号文件填写 username 和 password")
	}
	limit := 60 * time.Second
	if options.ShowBrowser {
		limit = 240 * time.Second
	}
	deadline, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	allocatorOptions := append([]chromedp.ExecAllocatorOption{}, chromedp.DefaultExecAllocatorOptions[:]...)
	allocatorOptions = append(allocatorOptions,
		chromedp.Flag("headless", !options.ShowBrowser), chromedp.Flag("lang", "zh-CN"))
	if options.BrowserPath != "" {
		allocatorOptions = append(allocatorOptions, chromedp.ExecPath(options.BrowserPath))
	}
	allocator, closeAllocator := chromedp.NewExecAllocator(deadline, allocatorOptions...)
	defer closeAllocator()
	// Do not emit underlying driver diagnostics: submitted scripts contain credentials.
	browserContext, closeBrowser := chromedp.NewContext(allocator,
		chromedp.WithErrorf(func(string, ...any) {}))
	defer closeBrowser()
	return authenticate(browserContext, chromeDriver{}, client.NewHTTPClient(), account, options,
		schoolURL, identityOrigin)
}

func authenticate(ctx context.Context, browser browserDriver, transport *http.Client,
	account store.Account, options Options, baseURL, authOrigin string) (*Session, error) {
	log := options.Log
	if log == nil {
		log = func(string) {}
	}
	log("[INFO] 加载统一身份认证页面")
	if err := browser.Navigate(ctx, baseURL); err != nil {
		return nil, browserFailure(ctx, "浏览器启动或登录页面加载失败，请安装 Chrome/Chromium，或用 --browser 指定浏览器")
	}
	base, _ := url.Parse(baseURL)
	identity, _ := url.Parse(authOrigin)
	api := client.New(baseURL, transport)
	submitted, manual, prefilled := false, false, false
	phaseStarted := time.Now()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return nil, browserFailure(ctx, "登录超时，请检查网络或稍后重试")
		}
		current, err := browser.Location(ctx)
		if err != nil {
			return nil, browserFailure(ctx, "登录未完成，浏览器已关闭或连接中断")
		}
		location, err := url.Parse(current)
		if err == nil && location.Scheme == base.Scheme && location.Host == base.Host &&
			location.Path != "/login" && !strings.HasPrefix(location.Path, "/login/") {
			cookies, cookieErr := browser.Cookies(ctx, baseURL)
			if cookieErr != nil {
				return nil, browserFailure(ctx, "无法读取登录会话，请重试")
			}
			// The jar retains cookie scope and never sends identity-provider cookies to the API.
			transport.Jar.SetCookies(base, cookies)
			profile, profileErr := api.Profile(ctx)
			if profileErr == nil {
				if !profile.Matches(account.Username) {
					return nil, fmt.Errorf("登录账号与账号文件不一致，请确认配置后重试")
				}
				log("[SUCCESS] 已通过用户资料接口确认登录身份")
				return &Session{Profile: profile, Client: api}, nil
			}
			if !errors.Is(profileErr, client.ErrUnauthenticated) {
				return nil, profileErr
			}
		}
		// Only the known identity-provider origin may receive account credentials.
		if err == nil && location.Scheme == identity.Scheme && location.Host == identity.Host {
			var state string
			if err := browser.Evaluate(ctx, observeScript, &state); err == nil {
				switch state {
				case "invalid":
					if submitted {
						return nil, fmt.Errorf("账号或密码错误，请修改账号文件后重新运行")
					}
				case "error":
					return nil, fmt.Errorf("统一身份认证暂时不可用，请稍后重试")
				case "manual":
					if !options.ShowBrowser {
						return nil, fmt.Errorf("学校要求验证码或额外认证，请加 --show-browser 后在网页中完成验证；账号密码仍从文件读取")
					}
					if !manual {
						manual = true
						phaseStarted = time.Now()
						log("[INFO] 请在浏览器完成学校要求的验证")
					}
					// A CAPTCHA may be present before the form is submitted. Still fill
					// the file credentials, leaving only the verification to the user.
					if !prefilled && !submitted {
						var outcome string
						if err := browser.Evaluate(ctx, credentialScriptFor(account, authOrigin, false), &outcome); err == nil {
							if outcome == "truncated" {
								return nil, fmt.Errorf("登录页面未接受完整账号或密码，请检查账号文件")
							}
							prefilled = outcome == "filled"
						}
					}
				case "switch":
					if !submitted && !manual {
						var ignored any
						_ = browser.Evaluate(ctx, `document.querySelector('a[href*="type=userNameLogin"]')?.click()`, &ignored)
					}
				case "ready":
					if !submitted {
						script := credentialScript(account, authOrigin)
						var outcome string
						if err := browser.Evaluate(ctx, script, &outcome); err != nil {
							// Navigation can destroy the JS context after the button was clicked.
							// Never retry the password submission blindly.
							submitted = true
							phaseStarted = time.Now()
							break
						}
						switch outcome {
						case "submitted":
							submitted = true
							phaseStarted = time.Now()
							log("[INFO] 已提交文件中的账号密码，等待认证结果")
						case "truncated":
							return nil, fmt.Errorf("登录页面未接受完整账号或密码，请检查账号文件")
						case "manual":
							if !options.ShowBrowser {
								return nil, fmt.Errorf("学校要求额外认证，请加 --show-browser 后完成网页验证")
							}
							manual = true
							phaseStarted = time.Now()
						}
					}
				}
			}
		}
		phaseLimit := 40 * time.Second
		if manual {
			phaseLimit = 180 * time.Second
		}
		if time.Since(phaseStarted) > phaseLimit {
			return nil, fmt.Errorf("登录等待超时，请检查网络或重新运行")
		}
		select {
		case <-ctx.Done():
			return nil, browserFailure(ctx, "登录超时，请检查网络或稍后重试")
		case <-ticker.C:
		}
	}
}

func browserFailure(ctx context.Context, message string) error {
	if errors.Is(ctx.Err(), context.Canceled) {
		return context.Canceled
	}
	return errors.New(message)
}

const observeScript = `(() => {
 const visible = e => e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
 const error = document.querySelector('#pwdFromId #showErrorTip');
 const text = visible(error) ? error.textContent.trim() : '';
 if (text) {
   if (/网络|超时|服务异常|系统异常|network|timeout|unavailable/i.test(text)) return 'error';
   if (/验证码|滑块|短信|动态码|验证身份|重置|禁用|锁定|captcha|locked/i.test(text)) return 'manual';
   if (/账号|帐号|用户|密码|认证失败|登录失败|不允许|非法|username|password|credential/i.test(text)) return 'invalid';
   return 'manual';
 }
 if (visible(document.querySelector('#pwdFromId #captcha')) ||
     document.querySelector('#sliderCaptchaDiv')?.children.length ||
     visible(document.querySelector('#dynamicCode'))) return 'manual';
 const warning = document.querySelector('#pwdFromId #showWarnTip');
 if (visible(warning) && warning.textContent.trim()) return 'manual';
 if (visible(document.querySelector('#pwdFromId #username')) && visible(document.querySelector('#pwdFromId #password'))) return 'ready';
 if (visible(document.querySelector('a[href*="type=userNameLogin"]'))) return 'switch';
 return 'waiting';
})()`

func credentialScript(account store.Account, origin string) string {
	return credentialScriptFor(account, origin, true)
}

func credentialScriptFor(account store.Account, origin string, submit bool) string {
	// JSON encoding keeps quotes, backslashes and newlines out of JavaScript syntax.
	username, _ := json.Marshal(account.Username)
	password, _ := json.Marshal(account.Password)
	trustedOrigin, _ := json.Marshal(origin)
	return fmt.Sprintf(`(() => {
 if (location.origin !== %s) return 'waiting';
 const u = document.querySelector('#pwdFromId #username');
 const p = document.querySelector('#pwdFromId #password');
 const button = document.querySelector('#pwdFromId #login_submit');
 if (!u || !p || !button) return 'waiting';
 const username = %s, password = %s;
 for (const [el, value] of [[u, username], [p, password]]) {
   el.focus(); el.value = value;
   el.dispatchEvent(new Event('input', {bubbles:true}));
   el.dispatchEvent(new Event('change', {bubbles:true})); el.blur();
 }
 if (u.value !== username || p.value !== password ||
     (u.maxLength > 0 && username.length > u.maxLength) ||
     (p.maxLength > 0 && password.length > p.maxLength)) return 'truncated';
 if (!%t) return 'filled';
 if (document.querySelector('#pwdFromId #captcha')?.getClientRects().length ||
     document.querySelector('#sliderCaptchaDiv')?.children.length) return 'manual';
 button.click(); return 'submitted';
})()`, trustedOrigin, username, password, submit)
}

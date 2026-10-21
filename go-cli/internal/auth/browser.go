package auth

import (
	"context"
	"net/http"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"
)

// browserDriver is small enough to exercise authentication with local fixtures.
type browserDriver interface {
	Navigate(context.Context, string) error
	Location(context.Context) (string, error)
	Evaluate(context.Context, string, any) error
	Cookies(context.Context, string) ([]*http.Cookie, error)
}

type chromeDriver struct{}

func (chromeDriver) Navigate(ctx context.Context, url string) error {
	return chromedp.Run(ctx, chromedp.Navigate(url))
}

func (chromeDriver) Location(ctx context.Context) (string, error) {
	var url string
	err := chromedp.Run(ctx, chromedp.Location(&url))
	return url, err
}

func (chromeDriver) Evaluate(ctx context.Context, script string, result any) error {
	return chromedp.Run(ctx, chromedp.Evaluate(script, result))
}

func (chromeDriver) Cookies(ctx context.Context, url string) ([]*http.Cookie, error) {
	var result []*http.Cookie
	err := chromedp.Run(ctx, chromedp.ActionFunc(func(ctx context.Context) error {
		cookies, err := network.GetCookies().WithURLs([]string{url}).Do(ctx)
		if err != nil {
			return err
		}
		for _, cookie := range cookies {
			converted := &http.Cookie{
				Name: cookie.Name, Value: cookie.Value, Path: cookie.Path,
				Domain: cookie.Domain, Secure: cookie.Secure, HttpOnly: cookie.HTTPOnly,
			}
			if cookie.Expires > 0 {
				converted.Expires = time.Unix(int64(cookie.Expires), 0)
			}
			switch cookie.SameSite {
			case network.CookieSameSiteStrict:
				converted.SameSite = http.SameSiteStrictMode
			case network.CookieSameSiteLax:
				converted.SameSite = http.SameSiteLaxMode
			case network.CookieSameSiteNone:
				converted.SameSite = http.SameSiteNoneMode
			}
			result = append(result, converted)
		}
		return nil
	}))
	return result, err
}

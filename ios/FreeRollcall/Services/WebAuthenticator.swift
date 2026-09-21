import Foundation
import WebKit
import Observation
import RollcallCore

struct AuthenticatedSession {
    let accountID: UUID
    let generation: UUID
    let profile: UserProfile
    let client: TronclassClient
}

@MainActor @Observable final class WebAuthenticator: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    var manual = false
    var progress = "加载统一身份认证页面"
    var cancelled = false
    var displayAccount = ""
    @ObservationIgnored private var navigationError: Error?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }
    func cancel() { cancelled = true; webView.stopLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let host = url.host?.lowercased() ?? ""
        // Credentials and authenticated pages stay within the school domains.
        if url.scheme == "https" && (host == "xmu.edu.cn" || host.hasSuffix(".xmu.edu.cn")) {
            return .allow
        } else { return .cancel }
    }

    func authenticate(accountID: UUID, username: String, password: String, knownID: String?,
                      forceManual: Bool = false, reusePage: Bool = false) async throws -> AuthenticatedSession {
        cancelled = false; navigationError = nil; manual = forceManual; displayAccount = username
        if !reusePage { webView.load(URLRequest(url: URL(string: "https://lnt.xmu.edu.cn")!)) }
        var didSubmit = false
        var phaseStarted = Date()
        let started = Date()
        while true {
            if cancelled || Task.isCancelled { throw RollcallError.cancelled }
            if navigationError != nil { throw RollcallError.message("登录页面加载失败，请检查网络后重试") }
            let host = webView.url?.host ?? ""
            let path = webView.url?.path ?? ""
            if host == "lnt.xmu.edu.cn", !path.hasPrefix("/login"), !webView.isLoading {
                progress = "确认登录账号"
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let client = TronclassClient(transport: SchoolTransport(cookies: cookies))
                do {
                    let profile = try await client.profile()
                    // Automatic submission binds the known credentials to the result. Manual login must match.
                    if let knownID, profile.id != knownID { throw RollcallError.identityMismatch }
                    if manual && !profile.matches(username, knownID: knownID) { throw RollcallError.identityMismatch }
                    guard didSubmit || manual || profile.matches(username, knownID: knownID) else {
                        throw RollcallError.identityMismatch
                    }
                    return AuthenticatedSession(accountID: accountID, generation: UUID(), profile: profile, client: client)
                } catch RollcallError.expiredSession {
                    // Intermediate school page; wait for its redirect to finish.
                }
            }
            if !manual && host == "ids.xmu.edu.cn" {
                if let state = try? await webView.callAsyncJavaScript(Self.observeScript, arguments: [:], in: nil, contentWorld: .page) as? String {
                    switch state {
                    case "manual": manual = true; progress = "请在网页中完成认证"; phaseStarted = Date()
                    case "invalid" where didSubmit: throw RollcallError.invalidCredentials
                    case "error": throw RollcallError.message("统一身份认证暂时不可用，请稍后重试")
                    case "ready" where !didSubmit:
                        progress = "正在使用账号密码登录"
                        let result = try await webView.callAsyncJavaScript(Self.fillScript,
                            arguments: ["username": username, "password": password], in: nil, contentWorld: .page) as? String
                        if result == "truncated" { throw RollcallError.invalidCredentials }
                        if result == "manual" { manual = true; progress = "请在网页中完成认证" }
                        if result == "submitted" { didSubmit = true; progress = "等待认证结果" }
                        phaseStarted = Date()
                    case "switch" where !didSubmit:
                        _ = try? await webView.callAsyncJavaScript("document.querySelector('a[href*=\"type=userNameLogin\"]')?.click()", arguments: [:], in: nil, contentWorld: .page)
                        progress = "切换到账号密码登录"
                    default: break
                    }
                }
            }
            let deadline: TimeInterval = manual ? 180 : 40
            if Date().timeIntervalSince(phaseStarted) > deadline || Date().timeIntervalSince(started) > 240 {
                throw RollcallError.message(manual ? "网页登录超时，请重试" : "登录超时，请检查网络后重试")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static let observeScript = #"""
    const visible = e => e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    const error = document.querySelector('#pwdFromId #showErrorTip');
    const text = visible(error) ? error.textContent.trim() : '';
    if (text) {
      if (/网络|超时|服务异常|系统异常|network|timeout|unavailable/i.test(text)) return 'error';
      if (/验证码|滑块|短信|动态码|验证身份|重置|禁用|锁定|captcha|locked/i.test(text)) return 'manual';
      if (/账号|帐号|用户|密码|认证失败|登录失败|不允许|非法|username|password|credential/i.test(text)) return 'invalid';
      return 'manual';
    }
    if (visible(document.querySelector('#pwdFromId #captcha')) || document.querySelector('#sliderCaptchaDiv')?.children.length || visible(document.querySelector('#dynamicCode'))) return 'manual';
    const warning = document.querySelector('#pwdFromId #showWarnTip');
    if (visible(warning) && warning.textContent.trim()) return 'manual';
    if (visible(document.querySelector('#pwdFromId #username')) && visible(document.querySelector('#pwdFromId #password'))) return 'ready';
    if (visible(document.querySelector('a[href*="type=userNameLogin"]'))) return 'switch';
    return 'waiting';
    """#
    private static let fillScript = #"""
    if (location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
    const u = document.querySelector('#pwdFromId #username');
    const p = document.querySelector('#pwdFromId #password');
    const button = document.querySelector('#pwdFromId #login_submit');
    if (!u || !p || !button) return 'waiting';
    u.focus(); u.value = username; u.dispatchEvent(new Event('input', {bubbles:true})); u.dispatchEvent(new Event('change', {bubbles:true})); u.blur();
    p.focus(); p.value = password; p.dispatchEvent(new Event('input', {bubbles:true})); p.dispatchEvent(new Event('change', {bubbles:true})); p.blur();
    if (u.value !== username || p.value !== password || (p.maxLength > 0 && password.length > p.maxLength)) return 'truncated';
    await new Promise(resolve => setTimeout(resolve, 350));
    const cap = document.querySelector('#pwdFromId #captcha');
    if ((cap && cap.getClientRects().length) || document.querySelector('#sliderCaptchaDiv')?.children.length) return 'manual';
    button.click(); return 'submitted';
    """#
}

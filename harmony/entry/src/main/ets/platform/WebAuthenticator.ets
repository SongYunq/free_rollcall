import { webview } from '@kit.ArkWeb';
import { AuthenticatedSession, AuthPort, newID, SavedAccount } from '../app/Contracts';
import { TronclassClient } from '../core/TronclassClient';
import { RollcallError } from '../core/Errors';
import { HarmonyTransport } from './HarmonyTransport';

/** School SSO in an incognito Web component. The school's original form encrypts the password. */
export class WebAuthenticator implements AuthPort {
  controller: webview.WebviewController = new webview.WebviewController();
  active: boolean = false;
  manual: boolean = false;
  progress: string = '加载统一身份认证页面';
  displayAccount: string = '';
  viewID: number = 0;
  onChange: () => void = (): void => {};
  private sequence: number = 0;
  private attached: boolean = false;
  private pageLoaded: boolean = false;
  private currentURL: string = '';
  private navigationFailed: boolean = false;
  private rejectCancellation?: () => void;

  onControllerAttached(): void { this.attached = true; }

  onPageBegin(url: string): void {
    if (!this.active) { return; }
    this.currentURL = url;
    this.pageLoaded = false;
  }

  onPageEnd(url: string): void {
    if (!this.active) { return; }
    this.currentURL = url;
    this.pageLoaded = true;
  }

  onNavigationError(): void { if (this.active) { this.navigationFailed = true; } }

  /** Return true to intercept (block) a main-frame navigation outside school HTTPS origins. */
  urlLoadIntercept(url: string): boolean {
    if (url === 'about:blank') { return false; }
    const host = WebAuthenticator.schoolHost(url);
    return host.length === 0;
  }

  showManual(): void {
    if (!this.active) { return; }
    this.manual = true;
    this.progress = '请在网页中完成认证';
    this.onChange();
  }

  cancel(): void {
    this.sequence += 1;
    const reject = this.rejectCancellation;
    this.rejectCancellation = undefined;
    this.cleanup();
    if (reject !== undefined) { reject(); }
  }

  async authenticate(account: SavedAccount, password: string, forceManual: boolean): Promise<AuthenticatedSession> {
    if (this.active) { throw new RollcallError('message', '已有登录正在进行，请先取消'); }
    if (account.username.trim().length === 0 || password.length === 0) {
      throw new RollcallError('message', '账号和密码不能为空');
    }
    const token = ++this.sequence;
    this.viewID = token;
    this.attached = false;
    this.pageLoaded = false;
    this.currentURL = '';
    this.navigationFailed = false;
    this.controller = new webview.WebviewController();
    this.displayAccount = account.username;
    this.manual = forceManual;
    this.progress = forceManual ? '请在网页中完成认证' : '加载统一身份认证页面';
    this.active = true;
    // UI mounts Web({incognitoMode:true}) in response to this notification.
    this.onChange();
    const cancelled = new Promise<AuthenticatedSession>((resolve, reject): void => {
      this.rejectCancellation = (): void => { reject(new RollcallError('cancelled')); };
    });
    try {
      return await Promise.race([this.run(account, password, token), cancelled]);
    } catch (error) {
      if (error instanceof RollcallError) { throw error; }
      // Web engine errors can contain full URLs or injected scripts; never expose raw errors.
      throw new RollcallError('message', '登录页面暂时不可用，请检查网络后重试');
    } finally {
      if (token === this.sequence) {
        this.rejectCancellation = undefined;
        this.cleanup();
      }
    }
  }

  private async run(account: SavedAccount, password: string, token: number): Promise<AuthenticatedSession> {
    const started = Date.now();
    while (!this.attached) {
      this.check(token);
      if (Date.now() - started > 10000) { throw new RollcallError('message', '登录页面未能启动，请重试'); }
      await this.pause(100);
    }
    this.check(token);
    // Incognito cookies are global within this application's incognito context. Only one auth runs at a time.
    // Clearing them before every account prevents SSO from silently reusing another account.
    try {
      webview.WebCookieManager.clearAllCookiesSync(true);
      webview.WebCookieManager.putAcceptThirdPartyCookieEnabled(false);
      this.controller.loadUrl(HarmonyTransport.BASE + '/');
    } catch (error) {
      throw new RollcallError('message', '登录页面加载失败，请检查网络后重试');
    }
    let didSubmit = false;
    let phaseStarted = Date.now();
    let wasManual = this.manual;
    let lastProfileAttempt = 0;
    while (true) {
      this.check(token);
      if (this.navigationFailed) {
        throw new RollcallError('message', '登录页面加载失败，请检查网络后重试');
      }
      if (this.manual && !wasManual) { phaseStarted = Date.now(); wasManual = true; }
      const host = WebAuthenticator.schoolHost(this.currentURL);
      const path = this.currentURL.replace(/^https:\/\/[^/]+/i, '');
      if (host === 'lnt.xmu.edu.cn' && !path.startsWith('/login') && this.pageLoaded &&
        Date.now() - lastProfileAttempt > 1000) {
        lastProfileAttempt = Date.now();
        this.setProgress('确认登录账号');
        let cookie = '';
        try {
          // API 11+ sync overload explicitly selects incognito cookies, including HttpOnly cookies.
          cookie = webview.WebCookieManager.fetchCookieSync(HarmonyTransport.BASE + '/api/profile', true);
        } catch (ignored) {}
        if (cookie.length > 0) {
          const client = new TronclassClient(new HarmonyTransport(cookie));
          try {
            const profile = await client.profile();
            this.check(token);
            if ((account.verifiedStudentID !== undefined && profile.id !== account.verifiedStudentID) ||
              (this.manual && !profile.matches(account.username, account.verifiedStudentID)) ||
              (!didSubmit && !this.manual && !profile.matches(account.username, account.verifiedStudentID))) {
              throw new RollcallError('identityMismatch');
            }
            return new AuthenticatedSession(account.id, newID(), profile, client);
          } catch (error) {
            if (error instanceof RollcallError) {
              if (error.code !== 'expiredSession') { throw error; }
            } else {
              throw new RollcallError('message', '确认登录账号失败，请稍后重试');
            }
            // The school may briefly serve an intermediate page before its SSO redirect completes.
          }
        }
      }
      if (!this.manual && host === 'ids.xmu.edu.cn' && this.pageLoaded) {
        const state = await this.evaluate(WebAuthenticator.OBSERVE_SCRIPT, token);
        this.check(token);
        if (state === 'manual') { this.showManual(); phaseStarted = Date.now(); }
        else if (state === 'invalid' && didSubmit) { throw new RollcallError('invalidCredentials'); }
        else if (state === 'error') { throw new RollcallError('message', '统一身份认证暂时不可用，请稍后重试'); }
        else if (state === 'ready' && !didSubmit) {
          this.setProgress('正在使用账号密码登录');
          const result = await this.evaluate(WebAuthenticator.fillScript(account.username, password), token);
          this.check(token);
          if (result === 'truncated') { throw new RollcallError('invalidCredentials'); }
          if (result === 'manual') { this.showManual(); }
          if (result === 'filled') {
            // Let the school page's input listeners settle, then click its original button.
            await this.pause(400);
            this.check(token);
            if (!this.manual) {
              const submitted = await this.evaluate(WebAuthenticator.SUBMIT_SCRIPT, token);
              if (submitted === 'manual') { this.showManual(); }
              if (submitted === 'submitted') { didSubmit = true; this.setProgress('等待认证结果'); }
            }
          }
          phaseStarted = Date.now();
        } else if (state === 'switch' && !didSubmit) {
          await this.evaluate(`(() => { if (location.protocol !== 'https:' || location.hostname !== 'ids.xmu.edu.cn') return 'waiting'; document.querySelector('a[href*="type=userNameLogin"]')?.click(); return 'waiting'; })()`, token);
          this.setProgress('切换到账号密码登录');
        }
      }
      const timeout = this.manual ? 180000 : 40000;
      if (Date.now() - phaseStarted > timeout || Date.now() - started > 240000) {
        throw new RollcallError('message', this.manual ? '网页登录超时，请重试' : '登录超时，请检查网络后重试');
      }
      await this.pause(250);
    }
  }

  private check(token: number): void {
    if (token !== this.sequence || !this.active) { throw new RollcallError('cancelled'); }
  }

  private setProgress(text: string): void {
    if (this.progress !== text) { this.progress = text; this.onChange(); }
  }

  private pause(ms: number): Promise<void> {
    return new Promise<void>((resolve): void => { setTimeout((): void => { resolve(); }, ms); });
  }

  private async evaluate(script: string, token: number): Promise<string> {
    this.check(token);
    let timer: number = -1;
    const timeout = new Promise<string>((resolve, reject): void => {
      timer = setTimeout((): void => { reject(new RollcallError('message', '登录页面暂时无响应，请重试')); }, 5000);
    });
    try {
      const encoded = await Promise.race([this.controller.runJavaScript(script), timeout]);
      this.check(token);
      // runJavaScript serializes string results as JSON on ArkWeb.
      if (encoded.startsWith('"')) { return JSON.parse(encoded) as string; }
      return encoded;
    } catch (error) {
      if (error instanceof RollcallError) { throw error; }
      throw new RollcallError('message', '登录页面暂时无响应，请重试');
    } finally { if (timer >= 0) { clearTimeout(timer); } }
  }

  private cleanup(): void {
    try { if (this.attached) { this.controller.stop(); } } catch (ignored) {}
    try { webview.WebCookieManager.clearAllCookiesSync(true); } catch (ignored) {}
    this.active = false;
    this.attached = false;
    this.pageLoaded = false;
    this.currentURL = '';
    this.onChange();
  }

  private static schoolHost(url: string): string {
    const match = /^https:\/\/([a-z0-9.-]+)(?::443)?(?:[/?#]|$)/i.exec(url);
    if (match === null) { return ''; }
    const host = match[1].toLowerCase();
    return host === 'xmu.edu.cn' || host.endsWith('.xmu.edu.cn') ? host : '';
  }

  private static readonly OBSERVE_SCRIPT: string = `(() => {
    if (location.protocol !== 'https:' || location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
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
  })()`;

  private static fillScript(username: string, password: string): string {
    const accountLiteral = JSON.stringify(username);
    const passwordLiteral = JSON.stringify(password);
    return `(() => {
      if (location.protocol !== 'https:' || location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
      const username = ${accountLiteral}; const password = ${passwordLiteral};
      const u = document.querySelector('#pwdFromId #username');
      const p = document.querySelector('#pwdFromId #password');
      const button = document.querySelector('#pwdFromId #login_submit');
      if (!u || !p || !button) return 'waiting';
      u.focus(); u.value = username; u.dispatchEvent(new Event('input', {bubbles:true})); u.dispatchEvent(new Event('change', {bubbles:true})); u.blur();
      p.focus(); p.value = password; p.dispatchEvent(new Event('input', {bubbles:true})); p.dispatchEvent(new Event('change', {bubbles:true})); p.blur();
      if (u.value !== username || p.value !== password || (p.maxLength > 0 && password.length > p.maxLength)) return 'truncated';
      const cap = document.querySelector('#pwdFromId #captcha');
      if ((cap && cap.getClientRects().length) || document.querySelector('#sliderCaptchaDiv')?.children.length) return 'manual';
      return 'filled';
    })()`;
  }

  private static readonly SUBMIT_SCRIPT: string = `(() => {
    if (location.protocol !== 'https:' || location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
    const cap = document.querySelector('#pwdFromId #captcha');
    if ((cap && cap.getClientRects().length) || document.querySelector('#sliderCaptchaDiv')?.children.length) return 'manual';
    const button = document.querySelector('#pwdFromId #login_submit');
    if (!button) return 'waiting';
    button.click(); return 'submitted';
  })()`;
}

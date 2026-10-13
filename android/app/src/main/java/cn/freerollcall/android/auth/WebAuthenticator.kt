package cn.freerollcall.android.auth

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.webkit.*
import androidx.core.net.toUri
import cn.freerollcall.android.core.*
import com.google.gson.JsonPrimitive
import kotlinx.coroutines.*
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class AuthCredentials(val accountId: String, val username: String, val password: String, val knownId: String?)
data class AuthResult(val profile: Profile, val client: TronclassClient)
data class AuthProgress(val manual: Boolean = false, val text: String = "加载统一身份认证页面")

@SuppressLint("SetJavaScriptEnabled")
class WebAuthenticator(context: Context, private val progress: (AuthProgress) -> Unit) {
    private var loading = false
    private var navigationError = false
    val webView = WebView(context).apply {
        settings.javaScriptEnabled = true; settings.domStorageEnabled = true
        settings.allowFileAccess = false; settings.allowContentAccess = false
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.userAgentString = SchoolTransport.USER_AGENT
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = !allowedUrl(request.url)
            override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) { loading = true }
            override fun onPageFinished(view: WebView, url: String?) { loading = false }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) navigationError = true
            }
            // Default SSL error handling cancels; do not bypass certificate validation.
        }
    }
    suspend fun authenticate(credentials: AuthCredentials, forceManual: Boolean): AuthResult =
        withAuthenticationDeadline(240_000, "登录超时，请重试") { authenticateWithWebView(credentials, forceManual) }

    private suspend fun authenticateWithWebView(credentials: AuthCredentials, forceManual: Boolean): AuthResult {
        CookieManager.getInstance().removeAllAwait()
        WebStorage.getInstance().deleteAllData()
        webView.clearCache(true)
        var manual = forceManual; var didSubmit = false
        var phase = android.os.SystemClock.elapsedRealtime(); val started = phase
        progress(AuthProgress(manual))
        webView.loadUrl(SchoolTransport.BASE)
        while (true) {
            currentCoroutineContext().ensureActive()
            if (navigationError) throw RollcallException.message("登录页面加载失败，请检查网络后重试")
            val url = (webView.url ?: "").toUri()
            if (url.host == SchoolTransport.HOST && !url.path.orEmpty().startsWith("/login") && !loading) {
                progress(AuthProgress(manual, "确认登录账号"))
                val client = TronclassClient(SchoolTransport(CookieManager.getInstance().getCookie(SchoolTransport.BASE).orEmpty()))
                try {
                    val profile = client.profile()
                    if (credentials.knownId != null && profile.id != credentials.knownId ||
                        manual && !profile.matches(credentials.username, credentials.knownId) ||
                        !didSubmit && !manual && !profile.matches(credentials.username, credentials.knownId))
                        throw RollcallException(RollcallException.Reason.IDENTITY, "登录账号与所选账号不一致，请使用所选账号登录")
                    return AuthResult(profile, client)
                } catch (error: RollcallException) { if (error.reason != RollcallException.Reason.EXPIRED) throw error }
            }
            if (!manual && url.host == "ids.xmu.edu.cn" && !loading) {
                when (webView.evaluate(OBSERVE)) {
                    "manual" -> { manual = true; phase = android.os.SystemClock.elapsedRealtime(); progress(AuthProgress(true, "请在网页中完成认证")) }
                    "invalid" -> if (didSubmit) throw RollcallException(RollcallException.Reason.INVALID_CREDENTIALS, "账号或密码错误")
                    "error" -> throw RollcallException.message("统一身份认证暂时不可用，请稍后重试")
                    "switch" -> if (!didSubmit) webView.evaluate("document.querySelector('a[href*=\"type=userNameLogin\"]')?.click(); 'waiting'")
                    "ready" -> if (!didSubmit) {
                        progress(AuthProgress(false, "正在使用账号密码登录"))
                        val script = "(function(){ const username=${JsonPrimitive(credentials.username)}; const password=${JsonPrimitive(credentials.password)}; $FILL })()"
                        when (webView.evaluate(script)) {
                            "truncated" -> throw RollcallException(RollcallException.Reason.INVALID_CREDENTIALS, "账号或密码未完整填入，请修改后重试")
                            "manual" -> { manual = true; progress(AuthProgress(true, "请在网页中完成认证")) }
                            "submitted" -> { didSubmit = true; progress(AuthProgress(false, "等待认证结果")) }
                        }
                        phase = android.os.SystemClock.elapsedRealtime()
                    }
                }
            }
            val now = android.os.SystemClock.elapsedRealtime()
            if (now - phase > (if (manual) 180_000 else 40_000) || now - started > 240_000)
                throw RollcallException.message(if (manual) "网页登录超时，请重试" else "登录超时，请检查网络后重试")
            delay(250)
        }
    }
    fun destroy() {
        webView.stopLoading()
        CookieManager.getInstance().removeAllCookies(null)
        WebStorage.getInstance().deleteAllData()
        webView.clearCache(true)
        webView.destroy()
    }
    companion object {
        fun allowedUrl(url: Uri): Boolean = url.scheme == "https" &&
            (url.host == "xmu.edu.cn" || url.host?.endsWith(".xmu.edu.cn") == true)
        private val OBSERVE = """
            (function(){
            if (location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
            const visible = e => e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
            const error = document.querySelector('#pwdFromId #showErrorTip');
            const text = visible(error) ? error.textContent.trim() : '';
            if(text){
              if(/网络|超时|服务异常|系统异常|network|timeout|unavailable/i.test(text)) return 'error';
              if(/验证码|滑块|短信|动态码|验证身份|重置|禁用|锁定|captcha|locked/i.test(text)) return 'manual';
              if(/账号|帐号|用户|密码|认证失败|登录失败|不允许|非法|username|password|credential/i.test(text)) return 'invalid';
              return 'manual';
            }
            if(visible(document.querySelector('#pwdFromId #captcha')) || document.querySelector('#sliderCaptchaDiv')?.children.length || visible(document.querySelector('#dynamicCode'))) return 'manual';
            const warning = document.querySelector('#pwdFromId #showWarnTip');
            if(visible(warning) && warning.textContent.trim()) return 'manual';
            if(visible(document.querySelector('#pwdFromId #username')) && visible(document.querySelector('#pwdFromId #password'))) return 'ready';
            if(visible(document.querySelector('a[href*="type=userNameLogin"]'))) return 'switch';
            return 'waiting';
            })()
        """.trimIndent()
        private val FILL = """
            if(location.hostname !== 'ids.xmu.edu.cn') return 'waiting';
            const u=document.querySelector('#pwdFromId #username');
            const p=document.querySelector('#pwdFromId #password');
            const button=document.querySelector('#pwdFromId #login_submit');
            if(!u || !p || !button) return 'waiting';
            u.focus(); u.value=username; u.dispatchEvent(new Event('input',{bubbles:true})); u.dispatchEvent(new Event('change',{bubbles:true})); u.blur();
            p.focus(); p.value=password; p.dispatchEvent(new Event('input',{bubbles:true})); p.dispatchEvent(new Event('change',{bubbles:true})); p.blur();
            if(u.value !== username || p.value !== password || (p.maxLength>0 && password.length>p.maxLength)) return 'truncated';
            const cap=document.querySelector('#pwdFromId #captcha');
            if((cap && cap.getClientRects().length) || document.querySelector('#sliderCaptchaDiv')?.children.length) return 'manual';
            setTimeout(()=>button.click(),350); return 'submitted';
        """.trimIndent()
    }
}
// The loop's elapsed-time check cannot run while a WebView callback is missing.
// Give callbacks their own deadline and retain the caller's cancellation semantics.
internal suspend fun <T> withAuthenticationDeadline(timeoutMillis: Long, message: String, block: suspend () -> T): T {
    try { return withTimeout(timeoutMillis) { block() } }
    catch (error: TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()
        throw RollcallException.message(message)
    }
}

private suspend fun CookieManager.removeAllAwait() = withAuthenticationDeadline(10_000, "登录页面暂时无响应，请重试") {
    suspendCancellableCoroutine<Unit> { continuation ->
        removeAllCookies { if (continuation.isActive) continuation.resume(Unit) }
    }
}
private suspend fun WebView.evaluate(script: String): String? = withAuthenticationDeadline(10_000, "登录页面暂时无响应，请重试") {
    suspendCancellableCoroutine { continuation ->
        try {
            evaluateJavascript(script) { result ->
                if (continuation.isActive) continuation.resume(runCatching { parseJson(result).text() }.getOrNull())
            }
        } catch (error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
    }
}

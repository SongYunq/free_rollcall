package cn.freerollcall.android.core

import com.google.gson.JsonElement
import kotlinx.coroutines.*
import java.net.*
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class ApiRequest(val path: String, val method: String = "GET", val body: JsonElement? = null, val radarHeaders: Boolean = false)
data class ApiResponse(val status: Int, val body: String) { fun json() = parseJson(body) }
fun interface Transport { suspend fun send(request: ApiRequest): ApiResponse }

/** A cookie jar belongs to one verified login, never the application's global WebView jar. */
class SchoolTransport internal constructor(cookieHeader: String, private val openConnection: (URL) -> HttpURLConnection) : Transport {
    constructor(cookieHeader: String) : this(cookieHeader, { it.openConnection() as HttpURLConnection })
    private val cookies = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
    init {
        cookieHeader.split(';').forEach { part ->
            val pair = part.trim().split('=', limit = 2)
            if (pair.size == 2 && pair[0].isNotEmpty()) {
                cookies.cookieStore.add(URI(BASE), HttpCookie(pair[0], pair[1]).apply {
                    domain = HOST; path = "/"; secure = true; version = 0
                })
            }
        }
    }
    override suspend fun send(request: ApiRequest): ApiResponse = withContext(Dispatchers.IO) {
        val url = URL(BASE + request.path)
        if (!request.path.startsWith("/api/") || url.host != HOST || url.protocol != "https")
            throw RollcallException.message("请求地址无效")
        val connection = openConnection(url)
        val context = currentCoroutineContext()
        suspendCancellableCoroutine { continuation ->
          // HttpURLConnection uses blocking I/O; cancelling withContext alone does not stop it.
          // Closing the connection unblocks a pending read instead of waiting for its timeout.
          continuation.invokeOnCancellation { connection.disconnect() }
          try {
            context.ensureActive()
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000; connection.readTimeout = 20_000
            connection.useCaches = false; connection.requestMethod = request.method
            connection.setRequestProperty("User-Agent", USER_AGENT)
            connection.setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9")
            connection.setRequestProperty("Accept", if (request.radarHeaders)
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" else "application/json, text/plain, */*")
            connection.setRequestProperty("Referer", if (request.radarHeaders)
                "https://ids.xmu.edu.cn/authserver/login" else "$BASE/user/index")
            cookies.get(url.toURI(), emptyMap()).forEach { (name, values) -> connection.setRequestProperty(name, values.joinToString("; ")) }
            context.ensureActive()
            request.body?.let {
                val bytes = it.toString().toByteArray(Charsets.UTF_8)
                connection.doOutput = true; connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { stream -> stream.write(bytes) }
            }
            val status = connection.responseCode
            cookies.put(url.toURI(), connection.headerFields.filterKeys { it != null })
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            context.ensureActive()
            continuation.resume(ApiResponse(status, body))
          } catch (error: Exception) {
            if (continuation.isActive) continuation.resumeWithException(when {
                error !is IOException -> error
                request.method == "PUT" -> RollcallException.uncertain("提交连接中断，结果尚未确认，请先核对签到状态")
                else -> RollcallException(RollcallException.Reason.NETWORK, "网络连接失败或超时，请重试")
            })
          } finally { connection.disconnect() }
        }
    }
    companion object {
        const val HOST = "lnt.xmu.edu.cn"
        const val BASE = "https://lnt.xmu.edu.cn"
        const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }
}

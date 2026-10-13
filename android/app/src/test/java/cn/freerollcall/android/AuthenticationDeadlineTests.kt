package cn.freerollcall.android

import cn.freerollcall.android.auth.withAuthenticationDeadline
import cn.freerollcall.android.core.RollcallException
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class AuthenticationDeadlineTests {
    @Test fun missingBrowserCallbackEndsWithRetryableLoginError() = runTest {
        try {
            withAuthenticationDeadline(10_000, "登录页面暂时无响应，请重试") { suspendCancellableCoroutine<Unit> {} }
            fail("A missing callback must not leave login busy forever")
        } catch (error: RollcallException) {
            assertEquals(RollcallException.Reason.OTHER, error.reason)
            assertEquals("登录页面暂时无响应，请重试", error.message)
        }
    }

    @Test fun callerCancellationIsNotConvertedIntoLoginFailure() = runTest {
        try {
            withTimeout(100) {
                withAuthenticationDeadline(10_000, "不应显示") { suspendCancellableCoroutine<Unit> {} }
            }
            fail("Expected caller timeout")
        } catch (_: TimeoutCancellationException) { /* Activity or dialog cancellation stays cancellation. */ }
    }

    @Test fun timelyCallbacksCanReturnNullWithoutBeingMistakenForTimeout() = runTest {
        val value: String? = withAuthenticationDeadline(10_000, "不应显示") { delay(250); null }
        assertNull(value)
    }
}

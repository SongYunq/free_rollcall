package cn.freerollcall.android

import cn.freerollcall.android.core.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class TransportTests {
    @Test fun cancellingRequestClosesBlockedConnectionPromptly() = runBlocking {
        val reading = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val connection = object : StubConnection() {
            override fun getInputStream(): InputStream {
                reading.countDown()
                if (!disconnected.await(5, TimeUnit.SECONDS)) throw IOException("Timed out")
                throw IOException("Connection closed")
            }
            override fun disconnect() { disconnected.countDown() }
        }
        val operation = async(Dispatchers.Default) { SchoolTransport("") { connection }.send(ApiRequest("/api/profile")) }
        assertTrue("The request must be reading before cancellation", reading.await(2, TimeUnit.SECONDS))
        operation.cancel()
        withTimeout(1_000) { operation.join() }
        assertTrue(operation.isCancelled)
        assertEquals(0L, disconnected.count)
    }

    @Test fun connectionFailureKeepsSubmissionUncertainAndReadRetryable() = runBlocking {
        for ((method, expected) in listOf("GET" to RollcallException.Reason.NETWORK, "PUT" to RollcallException.Reason.UNCERTAIN)) {
            val connection = object : StubConnection() {
                override fun getResponseCode(): Int = throw IOException("Disconnected")
            }
            try {
                SchoolTransport("") { connection }.send(ApiRequest("/api/profile", method))
                fail("Expected a mapped connection failure")
            } catch (error: RollcallException) { assertEquals(expected, error.reason) }
            assertTrue(connection.closed)
        }
    }

    @Test fun cookiesRemainIsolatedAcrossAccountsAndAcceptServerRotation() = runBlocking {
        val first = StubConnection(headers = mapOf("Set-Cookie" to listOf("session=renewed; Path=/; Secure")))
        val second = StubConnection()
        val third = StubConnection()
        val connections = ArrayDeque(listOf(first, second))
        val accountOne = SchoolTransport("session=first") { connections.removeFirst() }
        val accountTwo = SchoolTransport("session=second") { third }
        accountOne.send(ApiRequest("/api/profile"))
        accountOne.send(ApiRequest("/api/profile"))
        accountTwo.send(ApiRequest("/api/profile"))
        assertEquals("session=first", first.getRequestProperty("Cookie"))
        assertEquals("session=renewed", second.getRequestProperty("Cookie"))
        assertEquals("session=second", third.getRequestProperty("Cookie"))
    }

    @Test fun errorBodyAndStatusAreReturnedWithoutFollowingRedirects() = runBlocking {
        val connection = StubConnection(status = 401, body = "{\"error\":\"expired\"}")
        val response = SchoolTransport("") { connection }.send(ApiRequest("/api/profile"))
        assertEquals(401, response.status)
        assertEquals("expired", response.json().field("error").text())
        assertFalse(connection.instanceFollowRedirects)
        assertTrue(connection.closed)
    }

    @Test fun invalidApiPathNeverOpensConnection() = runBlocking {
        var opened = false
        try {
            SchoolTransport("session=private") { opened = true; StubConnection() }.send(ApiRequest("/user/index"))
            fail("Expected invalid address")
        } catch (_: RollcallException) { assertFalse(opened) }
    }

    private open class StubConnection(
        private val status: Int = 200,
        private val body: String = "{}",
        private val headers: Map<String, List<String>> = emptyMap()
    ) : HttpURLConnection(URL(SchoolTransport.BASE + "/api/profile")) {
        var closed = false
        override fun connect() = Unit
        override fun disconnect() { closed = true }
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getHeaderFields() = headers
        override fun getInputStream(): InputStream = ByteArrayInputStream(body.toByteArray())
        override fun getErrorStream(): InputStream = ByteArrayInputStream(body.toByteArray())
        override fun getOutputStream() = ByteArrayOutputStream()
    }
}

package cn.freerollcall.android

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import cn.freerollcall.android.auth.WebAuthenticator
import cn.freerollcall.android.core.*
import cn.freerollcall.android.storage.*
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.security.KeyStore

@RunWith(AndroidJUnit4::class)
class StorageTests {
    private lateinit var context: Context
    private lateinit var store: LocalStore
    private val name = "rollcall-storage-test.db"
    private val alias = "free_rollcall.storage-test"
    @Before fun before() {
        context = ApplicationProvider.getApplicationContext()
        context.deleteDatabase(name); deleteKey()
        store = LocalStore(context, name, CredentialVault(alias))
    }
    @After fun after() { store.close(); context.deleteDatabase(name); deleteKey() }
    private fun deleteKey() { KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) } }
    @Test fun accountRoundTripEncryptsAndBindsPasswordToAccount() {
        val first = store.saveAccount(null, "demo001", "示例密码 !123", "个人")
        val second = store.saveAccount(null, "demo002", "second", "")
        assertTrue(first.isDefault); assertFalse(second.isDefault)
        assertEquals("示例密码 !123", store.password(first.id))
        context.openOrCreateDatabase(name, 0, null).use { db -> db.rawQuery("SELECT password FROM accounts WHERE id = ?", arrayOf(first.id)).use {
            assertTrue(it.moveToFirst()); val encrypted = it.getString(0)
            assertFalse(encrypted.contains("示例密码"))
            try { CredentialVault(alias).decrypt(encrypted, second.id); fail() } catch (_: RollcallException) { }
        } }
        store.makeDefault(second.id)
        assertEquals(listOf(second.id), store.accounts().filter { it.isDefault }.map { it.id })
    }
    @Test fun editsInvalidateVerifiedIdOnlyWhenUsernameChanges() {
        val account = store.saveAccount(null, "demo001", "password", "")
        store.verified(account.id, "1")
        assertEquals("1", store.saveAccount(account.id, "demo001", "new", "备注").verifiedStudentId)
        assertNull(store.saveAccount(account.id, "demo002", "new", "备注").verifiedStudentId)
    }
    @Test fun deletingDefaultSelectsRemainingAccountAndPreservesLogs() {
        val first = store.saveAccount(null, "demo001", "password", "旧账号")
        val second = store.saveAccount(null, "demo002", "password", "")
        val log = store.begin(first, "1", Course("9", "测试课程"), Attendance("11", kind = AttendanceKind.NUMBER, numberCode = "0012"))
        store.update(log.id, LogResult.SUCCESS, "签到成功")
        store.deleteAccount(first.id)
        assertEquals(second.id, store.accounts().single().id); assertTrue(store.accounts().single().isDefault)
        assertEquals("demo001", store.logs().single().username); assertEquals("0012", store.logs().single().code)
    }
    @Test fun interruptedOperationIsRecoveredWithoutLosingSnapshot() {
        val account = store.saveAccount(null, "demo001", "password", "")
        store.begin(account, "1", Course("9", "测试课程"), Attendance("11", kind = AttendanceKind.RADAR))
        store.close(); store = LocalStore(context, name, CredentialVault(alias))
        assertEquals(LogResult.UNCERTAIN, store.logs().single().result)
        assertEquals("雷达签到", store.logs().single().codeText)
        assertTrue(store.logs().single().message.contains("上次操作中断"))
    }
    @Test fun loginOnlyAllowsHttpsSchoolDomains() {
        assertTrue(WebAuthenticator.allowedUrl(Uri.parse("https://ids.xmu.edu.cn/authserver/login")))
        for (url in listOf("http://ids.xmu.edu.cn/", "https://xmu.edu.cn.evil.example/", "file:///etc/passwd", "javascript:alert(1)"))
            assertFalse(WebAuthenticator.allowedUrl(Uri.parse(url)))
    }
}

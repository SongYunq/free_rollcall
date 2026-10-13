package cn.freerollcall.android.storage

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import cn.freerollcall.android.core.*
import java.security.KeyStore
import java.time.Instant
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SavedAccount(val id: String, val username: String, val note: String, val isDefault: Boolean,
    val verifiedStudentId: String?, val createdAt: Long) { val label get() = note.ifEmpty { username } }
enum class LogResult(val title: String) { PROCESSING("处理中"), SUCCESS("成功"), FAILURE("失败"), UNCERTAIN("待确认") }
data class AttendanceLog(val id: String, val createdAt: Instant, val accountId: String, val username: String,
    val accountNote: String, val studentId: String, val courseId: String, val courseName: String,
    val rollcallId: String, val kind: AttendanceKind, val code: String?, val result: LogResult, val message: String) {
    val codeText get() = if (kind == AttendanceKind.RADAR) "雷达签到" else code ?: "未获取"
}
interface Store {
    fun accounts(): List<SavedAccount>
    fun logs(): List<AttendanceLog>
    fun password(id: String): String
    fun saveAccount(id: String?, username: String, password: String, note: String): SavedAccount
    fun makeDefault(id: String)
    fun deleteAccount(id: String)
    fun verified(id: String, studentId: String)
    fun begin(account: SavedAccount, studentId: String, course: Course, record: Attendance): AttendanceLog
    fun update(id: String, result: LogResult, message: String, code: String? = null,
        kind: AttendanceKind? = null, studentId: String? = null)
}

class CredentialVault(private val alias: String = "free_rollcall.accounts.v1") {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    fun encrypt(password: String, id: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key()); updateAAD(id.toByteArray(Charsets.UTF_8))
        }
        return "v1." + Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + "." +
            Base64.encodeToString(cipher.doFinal(password.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }
    fun decrypt(encoded: String, id: String): String = try {
        val parts = encoded.split('.')
        require(parts.size == 3 && parts[0] == "v1")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[1], Base64.NO_WRAP)))
            updateAAD(id.toByteArray(Charsets.UTF_8))
        }
        String(cipher.doFinal(Base64.decode(parts[2], Base64.NO_WRAP)), Charsets.UTF_8)
    } catch (_: Exception) { throw RollcallException.message("无法读取保存的密码，请重新编辑该账号") }
}

class LocalStore(context: Context, databaseName: String = "rollcall.db", private val vault: CredentialVault = CredentialVault()) : Store {
    private val helper = object : SQLiteOpenHelper(context.applicationContext, databaseName, null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE accounts (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, note TEXT NOT NULL, is_default INTEGER NOT NULL, student_id TEXT, created_at INTEGER NOT NULL, password TEXT NOT NULL)")
            db.execSQL("CREATE TABLE logs (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, account_id TEXT NOT NULL, username TEXT NOT NULL, account_note TEXT NOT NULL, student_id TEXT NOT NULL, course_id TEXT NOT NULL, course_name TEXT NOT NULL, rollcall_id TEXT NOT NULL, kind TEXT NOT NULL, code TEXT, result TEXT NOT NULL, message TEXT NOT NULL)")
        }
        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = error("No migration for version $newVersion")
    }
    // Open and recover on the first background read, never in the Activity constructor.
    private val db: SQLiteDatabase by lazy {
        helper.writableDatabase.also { database -> database.update("logs", ContentValues().apply {
            put("result", LogResult.UNCERTAIN.name); put("message", "上次操作中断，请使用原账号核对签到状态")
        }, "result = ?", arrayOf(LogResult.PROCESSING.name)) }
    }
    private fun <T> transaction(block: () -> T): T {
        db.beginTransaction()
        try { return block().also { db.setTransactionSuccessful() } } finally { db.endTransaction() }
    }
    override fun accounts(): List<SavedAccount> = db.query("accounts", null, null, null, null, null, "created_at ASC, id ASC").use { c ->
        buildList { while (c.moveToNext()) add(SavedAccount(c.text("id")!!, c.text("username")!!, c.text("note")!!,
            c.getInt(c.getColumnIndexOrThrow("is_default")) == 1, c.text("student_id"), c.getLong(c.getColumnIndexOrThrow("created_at")))) }
    }
    override fun logs(): List<AttendanceLog> = db.query("logs", null, null, null, null, null, "created_at DESC, id DESC").use { c ->
        buildList { while (c.moveToNext()) add(AttendanceLog(c.text("id")!!, Instant.ofEpochMilli(c.getLong(c.getColumnIndexOrThrow("created_at"))),
            c.text("account_id")!!, c.text("username")!!, c.text("account_note")!!, c.text("student_id")!!,
            c.text("course_id")!!, c.text("course_name")!!, c.text("rollcall_id")!!,
            enumValues<AttendanceKind>().firstOrNull { it.name == c.text("kind") } ?: AttendanceKind.UNKNOWN,
            c.text("code"), enumValues<LogResult>().firstOrNull { it.name == c.text("result") } ?: LogResult.UNCERTAIN, c.text("message")!!)) }
    }
    override fun password(id: String): String = db.query("accounts", arrayOf("password"), "id = ?", arrayOf(id), null, null, null).use {
        if (!it.moveToFirst()) throw RollcallException.message("账号不存在，请重新添加")
        vault.decrypt(it.getString(0), id)
    }
    override fun saveAccount(id: String?, username: String, password: String, note: String): SavedAccount {
        val user = username.trim()
        if (user.isEmpty() || password.isEmpty()) throw RollcallException.message("账号和密码不能为空")
        val accounts = accounts()
        if (accounts.any { it.username == user && it.id != id }) throw RollcallException.message("这个账号已经存在，请修改已有账号")
        val old = id?.let { target -> accounts.firstOrNull { it.id == target } ?: throw RollcallException.message("账号不存在") }
        val saved = SavedAccount(old?.id ?: UUID.randomUUID().toString(), user, note.trim(), old?.isDefault ?: accounts.isEmpty(),
            old?.verifiedStudentId?.takeIf { old.username == user }, old?.createdAt ?: System.currentTimeMillis())
        val encrypted = vault.encrypt(password, saved.id)
        transaction {
            val values = ContentValues().apply {
                put("id", saved.id); put("username", saved.username); put("note", saved.note)
                put("is_default", if (saved.isDefault) 1 else 0); put("student_id", saved.verifiedStudentId)
                put("created_at", saved.createdAt); put("password", encrypted)
            }
            if (old == null) db.insertOrThrow("accounts", null, values)
            else check(db.update("accounts", values, "id = ?", arrayOf(saved.id)) == 1)
        }
        return saved
    }
    override fun makeDefault(id: String) = transaction {
        if (accounts().none { it.id == id }) throw RollcallException.message("账号不存在")
        db.execSQL("UPDATE accounts SET is_default = CASE WHEN id = ? THEN 1 ELSE 0 END", arrayOf(id))
    }
    override fun deleteAccount(id: String) = transaction {
        val removed = accounts().firstOrNull { it.id == id }
        db.delete("accounts", "id = ?", arrayOf(id))
        if (removed?.isDefault == true) accounts().firstOrNull()?.let { makeDefault(it.id) }
        Unit
    }
    override fun verified(id: String, studentId: String) {
        check(db.update("accounts", ContentValues().apply { put("student_id", studentId) }, "id = ?", arrayOf(id)) == 1)
    }
    override fun begin(account: SavedAccount, studentId: String, course: Course, record: Attendance): AttendanceLog {
        val log = AttendanceLog(UUID.randomUUID().toString(), Instant.now(), account.id, account.username, account.note,
            studentId, course.id, course.name, record.id, record.kind, record.numberCode, LogResult.PROCESSING, "正在准备签到")
        db.insertOrThrow("logs", null, ContentValues().apply {
            put("id", log.id); put("created_at", log.createdAt.toEpochMilli()); put("account_id", account.id)
            put("username", account.username); put("account_note", account.note); put("student_id", studentId)
            put("course_id", course.id); put("course_name", course.name); put("rollcall_id", record.id)
            put("kind", record.kind.name); put("code", record.numberCode); put("result", log.result.name); put("message", log.message)
        })
        return log
    }
    override fun update(id: String, result: LogResult, message: String, code: String?, kind: AttendanceKind?, studentId: String?) {
        val values = ContentValues().apply {
            put("result", result.name); put("message", message)
            code?.let { put("code", it) }; kind?.let { put("kind", it.name) }; studentId?.let { put("student_id", it) }
        }
        if (db.update("logs", values, "id = ?", arrayOf(id)) != 1) throw RollcallException.message("本地记录保存失败，请核对学校端结果")
    }
    fun close() = helper.close()
}
private fun Cursor.text(name: String): String? = getColumnIndexOrThrow(name).let { if (isNull(it)) null else getString(it) }

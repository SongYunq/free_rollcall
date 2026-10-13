package cn.freerollcall.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.freerollcall.android.storage.SavedAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal data class AccountDraft(
    val accountId: String?,
    val username: String = "",
    val password: String = "",
    val note: String = "",
    val visible: Boolean = false,
    val readingPassword: Boolean = false,
    val saving: Boolean = false,
    val error: String? = null
)

// Credentials stay in memory across configuration changes; nothing is saved into a Bundle.
internal class AccountEditorState(
    private val readPassword: suspend (String) -> String,
    private val saveAccount: suspend (String?, String, String, String) -> Unit
) : ViewModel() {
    var draft: AccountDraft? by mutableStateOf(null)
        private set
    private var generation = 0
    private var readJob: Job? = null

    fun open(account: SavedAccount?) {
        if (draft?.saving == true) return
        readJob?.cancel()
        val token = ++generation
        draft = AccountDraft(account?.id, account?.username.orEmpty(), note = account?.note.orEmpty(),
            readingPassword = account != null)
        if (account != null) readJob = viewModelScope.launch {
            try {
                val password = readPassword(account.id)
                if (generation == token) draft = draft?.copy(password = password)
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (generation == token) draft = draft?.copy(error = error.message ?: "密码读取失败，请重新填写")
            } finally {
                if (generation == token) draft = draft?.copy(readingPassword = false)
            }
        }
    }
    private fun edit(block: (AccountDraft) -> AccountDraft) {
        draft?.takeUnless { it.saving }?.let { draft = block(it) }
    }
    fun username(value: String) = edit { it.copy(username = value, error = null) }
    fun password(value: String) = edit { if (it.readingPassword) it else it.copy(password = value, error = null) }
    fun note(value: String) = edit { it.copy(note = value, error = null) }
    fun togglePassword() = edit { it.copy(visible = !it.visible) }
    fun cancel() {
        if (draft?.saving == true) return
        clearDraft()
    }
    fun save() {
        val current = draft?.takeUnless { it.saving || it.readingPassword || it.username.trim().isEmpty() || it.password.isEmpty() }
            ?: return
        val token = generation
        draft = current.copy(saving = true, error = null)
        viewModelScope.launch {
            try {
                saveAccount(current.accountId, current.username, current.password, current.note)
                if (generation == token) clearDraft()
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (generation == token) draft = draft?.copy(saving = false, error = error.message ?: "账号保存失败，请重试")
            }
        }
    }
    private fun clearDraft() {
        generation++
        readJob?.cancel()
        readJob = null
        draft = null
    }
    override fun onCleared() { clearDraft() }
}

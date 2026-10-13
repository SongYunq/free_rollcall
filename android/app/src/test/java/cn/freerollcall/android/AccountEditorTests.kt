package cn.freerollcall.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import cn.freerollcall.android.storage.SavedAccount
import cn.freerollcall.android.ui.AccountEditorState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AccountEditorTests {
    private val dispatcher = StandardTestDispatcher()
    private val models = ViewModelStore()
    @Before fun before() { Dispatchers.setMain(dispatcher) }
    @After fun after() { models.clear(); Dispatchers.resetMain() }
    private fun provider(create: () -> AccountEditorState): ViewModelProvider = ViewModelProvider(models,
        object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                @Suppress("UNCHECKED_CAST")
                return create() as T
            }
        })
    private fun account(id: String) = SavedAccount(id, "user$id", "备注$id", false, null, 1)

    @Test fun recreatedOwnerKeepsUnsavedCredentialsOnlyInRetainedViewModel() = runTest(dispatcher) {
        val editor = provider { AccountEditorState({ "" }) { _, _, _, _ -> } }[AccountEditorState::class.java]
        editor.open(null); editor.username("new-user"); editor.password("not-saved"); editor.note("临时备注")
        editor.togglePassword()
        // Android reuses this store for the replacement Activity during a configuration change.
        val restored = provider { error("The retained instance must be reused") }[AccountEditorState::class.java]
        assertSame(editor, restored)
        assertEquals("new-user", restored.draft!!.username)
        assertEquals("not-saved", restored.draft!!.password)
        assertEquals("临时备注", restored.draft!!.note)
        assertTrue(restored.draft!!.visible)
        restored.cancel(); assertNull(restored.draft)
        restored.open(null); assertEquals("", restored.draft!!.password)
    }
    @Test fun canceledPasswordReadCannotPopulateANewAccountDraft() = runTest(dispatcher) {
        val waiting = CompletableDeferred<String>()
        val editor = provider { AccountEditorState({ id ->
            if (id == "a") withContext(NonCancellable) { waiting.await() } else "password-b"
        }) { _, _, _, _ -> } }[AccountEditorState::class.java]
        editor.open(account("a")); runCurrent()
        assertTrue(editor.draft!!.readingPassword)
        editor.cancel(); editor.open(account("b")); runCurrent()
        waiting.complete("stale-password-a"); advanceUntilIdle()
        assertEquals("b", editor.draft!!.accountId)
        assertEquals("password-b", editor.draft!!.password)
        assertFalse(editor.draft!!.readingPassword)
    }
    @Test fun savingContinuesAcrossOwnerRecreationAndClearsDraftOnce() = runTest(dispatcher) {
        val waiting = CompletableDeferred<Unit>()
        val saves = mutableListOf<List<String?>>()
        val editor = provider { AccountEditorState({ "original" }) { id, user, password, note ->
            saves += listOf(id, user, password, note); waiting.await()
        } }[AccountEditorState::class.java]
        editor.open(account("a")); advanceUntilIdle()
        editor.password("replacement"); editor.save(); runCurrent()
        val restored = provider { error("Unexpected replacement") }[AccountEditorState::class.java]
        assertTrue(restored.draft!!.saving)
        restored.save(); restored.cancel(); restored.password("ignored")
        assertEquals("replacement", restored.draft!!.password)
        waiting.complete(Unit); advanceUntilIdle()
        assertEquals(listOf(listOf("a", "usera", "replacement", "备注a")), saves)
        assertNull(restored.draft)
    }
    @Test fun saveFailureKeepsDraftForRetryAndSuccessfulSaveClearsIt() = runTest(dispatcher) {
        var attempts = 0
        val editor = provider { AccountEditorState({ "" }) { _, _, _, _ ->
            if (++attempts == 1) error("存储暂不可用")
        } }[AccountEditorState::class.java]
        editor.open(null); editor.username("new-user"); editor.password("password"); editor.save(); advanceUntilIdle()
        assertFalse(editor.draft!!.saving)
        assertEquals("存储暂不可用", editor.draft!!.error)
        assertEquals("password", editor.draft!!.password)
        editor.save(); advanceUntilIdle()
        assertEquals(2, attempts); assertNull(editor.draft)
    }
    @Test fun clearingOwnerDropsCredentialsAndCancelsPendingRead() = runTest(dispatcher) {
        val waiting = CompletableDeferred<String>()
        var cancelled = false
        val editor = provider { AccountEditorState({
            try { waiting.await() } finally { cancelled = true }
        }) { _, _, _, _ -> } }[AccountEditorState::class.java]
        editor.open(account("a")); runCurrent()
        models.clear(); advanceUntilIdle()
        assertNull(editor.draft); assertTrue(cancelled)
    }
}

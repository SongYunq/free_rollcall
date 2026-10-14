package cn.freerollcall.android.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.freerollcall.android.auth.*
import cn.freerollcall.android.core.*
import cn.freerollcall.android.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

enum class AppTab(val title: String) { HOME("功能"), LOGS("本地日志"), ACCOUNTS("账号管理") }
enum class HomePage { HOME, COURSES, HISTORY }
enum class HomeLoading { NONE, COURSES, HISTORY }
data class LoginPrompt(val id: String = UUID.randomUUID().toString(), val credentials: AuthCredentials,
    val manual: Boolean, val completion: CompletableDeferred<AuthResult> = CompletableDeferred())
data class Session(val accountId: String, val profile: Profile, val client: TronclassClient)
data class UiState(
    val tab: AppTab = AppTab.HOME, val page: HomePage = HomePage.HOME,
    val accounts: List<SavedAccount> = emptyList(), val logs: List<AttendanceLog> = emptyList(),
    val currentAccountId: String? = null, val authenticated: Boolean = false,
    val courses: List<Course> = emptyList(), val selectedCourse: Course? = null,
    val records: List<Attendance> = emptyList(), val history: PageAccumulator<Attendance> = PageAccumulator(),
    val busy: Boolean = false, val initializing: Boolean = false, val homeLoading: HomeLoading = HomeLoading.NONE,
    val submitting: String? = null, val error: String? = null,
    val message: String? = null, val notice: String? = null, val loginPrompt: LoginPrompt? = null
) {
    val accountText: String get() {
        accounts.firstOrNull { it.id == currentAccountId }?.let {
            return "${if (authenticated) "当前账号" else "待重新登录"} · ${it.username}"
        }
        return accounts.firstOrNull { it.isDefault }?.let { "默认账号 · ${it.username}" } ?: "尚未设置账号"
    }
}

class AppModel(val store: Store, private val storageDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val authenticate: (suspend (AuthCredentials, Boolean) -> AuthResult)? = null) : ViewModel() {
    private val mutable = MutableStateFlow(UiState(initializing = true))
    val state: StateFlow<UiState> = mutable.asStateFlow()
    private var session: Session? = null
    private var job: Job? = null
    private var epoch = 0
    private val failures = mutableMapOf<String, Int>()
    private val ready = CompletableDeferred<Unit>()
    init {
        viewModelScope.launch {
            try { reload(); ready.complete(Unit) }
            catch (_: Exception) {
                val error = RollcallException.message("本地数据无法读取，请检查可用存储后重新打开应用")
                ready.completeExceptionally(error); report(error)
            } finally { change { it.copy(initializing = false) } }
        }
    }
    private fun change(transform: (UiState) -> UiState) { mutable.update(transform) }
    private suspend fun <T> storage(block: () -> T): T = withContext(storageDispatcher) { block() }
    private suspend fun <T> remote(block: suspend () -> T): T = withContext(storageDispatcher) { block() }
    private suspend fun reload() {
        val (accounts, logs) = storage { store.accounts() to store.logs() }
        change { it.copy(accounts = accounts, logs = logs) }
    }
    fun switchTab(tab: AppTab) = change { it.copy(tab = tab) }
    fun dismissNotice() = change { it.copy(notice = null) }
    private fun report(error: Exception) {
        if (error !is CancellationException) change { it.copy(notice = error.message ?: "操作未完成，请重试") }
    }
    private fun operation(loading: HomeLoading = HomeLoading.NONE, block: suspend () -> Unit) {
        if (state.value.busy) return
        change { it.copy(busy = true, homeLoading = loading, notice = null) }
        job = viewModelScope.launch {
            try { ready.await(); block() } catch (error: Exception) { report(error) }
            finally { change { it.copy(busy = false, homeLoading = HomeLoading.NONE, submitting = null) } }
        }
    }
    private fun requireIdle() { if (state.value.busy) throw RollcallException.message("请等待当前操作完成") }
    suspend fun password(id: String): String { ready.await(); return storage { store.password(id) } }
    private suspend fun <T> editStore(block: suspend () -> T): T {
        ready.await(); requireIdle()
        change { it.copy(busy = true) }
        // A tab change can cancel its editor, but must not interrupt a committed write's state refresh.
        return viewModelScope.async {
            try { block() } finally { change { it.copy(busy = false) } }
        }.await()
    }
    suspend fun saveAccount(id: String?, username: String, password: String, note: String) = editStore {
        val old = state.value.accounts.firstOrNull { it.id == id }
        val changed = old != null && (old.username != username.trim() || runCatching { storage { store.password(old.id) } }.getOrNull() != password)
        val saved = storage { store.saveAccount(id, username, password, note) }
        if (changed) { failures.remove(saved.id); if (saved.id == state.value.currentAccountId) invalidateSession(false) }
        reload()
    }
    suspend fun makeDefault(id: String) = editStore { storage { store.makeDefault(id) }; reload() }
    suspend fun deleteAccount(id: String) = editStore {
        storage { store.deleteAccount(id) }; failures.remove(id)
        if (id == state.value.currentAccountId) invalidateSession(true)
        reload()
    }
    private fun invalidateSession(clearAccount: Boolean) {
        session = null; epoch++
        change { it.copy(authenticated = false, currentAccountId = if (clearAccount) null else it.currentAccountId,
            page = HomePage.HOME, courses = emptyList(), records = emptyList(), history = PageAccumulator(), selectedCourse = null,
            error = null, message = null) }
    }
    fun logout() { if (!state.value.busy) invalidateSession(true) }
    fun loginAccount(id: String) = operation { login(id) }
    fun cancelLogin() { state.value.loginPrompt?.completion?.cancel(CancellationException("用户取消登录")) }
    fun finishLogin(promptId: String, result: Result<AuthResult>) {
        state.value.loginPrompt?.takeIf { it.id == promptId }?.completion?.let { future ->
            result.fold({ future.complete(it) }, { future.completeExceptionally(it) })
        }
    }
    private suspend fun auth(credentials: AuthCredentials, manual: Boolean): AuthResult {
        authenticate?.let { return it(credentials, manual) }
        val prompt = LoginPrompt(credentials = credentials, manual = manual)
        change { it.copy(loginPrompt = prompt) }
        try { return prompt.completion.await() }
        finally {
            prompt.completion.cancel()
            change { if (it.loginPrompt?.id == prompt.id) it.copy(loginPrompt = null) else it }
        }
    }
    private suspend fun login(id: String): Session {
        val account = state.value.accounts.firstOrNull { it.id == id } ?: throw RollcallException.message("当前账号不可用")
        val credentials = AuthCredentials(id, account.username, password(id), account.verifiedStudentId)
        val result = try { auth(credentials, failures.getOrDefault(id, 0) >= 3) }
        catch (error: RollcallException) {
            if (error.reason != RollcallException.Reason.INVALID_CREDENTIALS) throw error
            val count = failures.getOrDefault(id, 0) + 1; failures[id] = count
            if (count < 3) throw RollcallException.message("账号或密码错误，已连续失败 $count 次，请修改账号后重试")
            auth(credentials, true)
        }
        currentCoroutineContext().ensureActive()
        if (account.verifiedStudentId != null && result.profile.id != account.verifiedStudentId)
            throw RollcallException(RollcallException.Reason.IDENTITY, "登录账号与所选账号不一致")
        storage { store.verified(id, result.profile.id) }
        val changed = state.value.currentAccountId != id
        if (changed) invalidateSession(false)
        val verified = Session(id, result.profile, result.client)
        session = verified; failures.remove(id)
        change { it.copy(currentAccountId = id, authenticated = true) }
        reload()
        return verified
    }
    private suspend fun ensureSession(): Session {
        session?.let { return it }
        val id = state.value.currentAccountId ?: state.value.accounts.firstOrNull { it.isDefault }?.id
            ?: run { switchTab(AppTab.ACCOUNTS); throw RollcallException.message("请先添加一个默认账号") }
        return login(id)
    }
    private fun expireSession() {
        session = null
        change { it.copy(authenticated = false) }
    }
    private suspend fun <T> read(block: suspend (Session) -> T): T {
        val initial = ensureSession()
        return try { remote { block(initial) } } catch (error: RollcallException) {
            if (error.reason != RollcallException.Reason.EXPIRED) throw error
            expireSession()
            val renewed = login(initial.accountId)
            try { remote { block(renewed) } }
            catch (retryError: RollcallException) {
                if (retryError.reason == RollcallException.Reason.EXPIRED) expireSession()
                throw retryError
            }
        }
    }
    fun enterCourses() = operation(HomeLoading.COURSES) {
        ensureSession()
        change { it.copy(page = HomePage.COURSES, error = null, message = null) }
        fetchCourses()
    }
    fun refreshCourses() = operation(HomeLoading.COURSES) { fetchCourses() }
    private suspend fun fetchCourses() {
        change { it.copy(error = null) }
        try { val courses = read { it.client.currentSemesterCourses() }; change { it.copy(courses = courses) } }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { change { it.copy(error = error.message) } }
    }
    fun openCourse(course: Course) = operation(HomeLoading.HISTORY) {
        epoch++
        change { it.copy(page = HomePage.HISTORY, selectedCourse = course, records = emptyList(), history = PageAccumulator(), error = null, message = null) }
        fetchHistory(course, true)
    }
    fun refreshHistory() { state.value.selectedCourse?.let { course -> operation(HomeLoading.HISTORY) { fetchHistory(course, true) } } }
    fun moreHistory() { state.value.selectedCourse?.let { course -> if (state.value.history.hasMore) operation(HomeLoading.HISTORY) { fetchHistory(course, false) } } }
    private suspend fun fetchHistory(course: Course, reset: Boolean) {
        val token = epoch
        change { it.copy(error = null, message = null) }
        try {
            val page = read { it.client.history(course.id, it.profile.id, if (reset) 1 else state.value.history.nextPage) }
            if (token != epoch) return
            val old = state.value.records.associateBy { it.id }
            val accumulator = (if (reset) PageAccumulator() else state.value.history).append(page, Attendance::id)
            var records = accumulator.items.map { if (reset) it else old[it.id] ?: it }
            try {
                for (active in read { it.client.active() }) {
                    val index = records.indexOfFirst { it.id == active.id }
                    if (index >= 0) {
                        // Activity endpoint is authoritative for activity, not individual attendance.
                        records = records.toMutableList().apply { this[index] = this[index].merge(active.copy(personalStatus = null)) }
                    } else if (active.courseId == course.id) records = records + active
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { change { it.copy(error = "历史记录已加载，当前活动刷新失败，可下拉重试") } }
            if (token != epoch) return
            records = records.sortedWith(compareByDescending<Attendance> { it.isActive }.thenByDescending { it.date })
            change { it.copy(records = records, history = accumulator) }
            // Authenticate before concurrent detail reads; each worker remains read-only.
            val current = ensureSession()
            val missing = records.filter { it.kind == AttendanceKind.UNKNOWN || it.kind == AttendanceKind.NUMBER && it.numberCode.isNullOrEmpty() }
            var incomplete = false
            // Publish one list update per batch, rather than rebuilding for every completed code.
            for (batch in missing.chunked(4)) {
                val details = coroutineScope {
                    batch.map { row -> async {
                        try {
                            val courseId = row.courseId ?: course.id
                            val date = row.queryDate
                            row.id to remote { current.client.detail(courseId, row.id, date, current.profile.id) }
                        }
                        catch (error: CancellationException) { throw error }
                        catch (_: Exception) { row.id to null }
                    } }.awaitAll().toMap()
                }
                if (token != epoch) return
                if (details.values.any { it == null || it.kind == AttendanceKind.NUMBER && it.numberCode.isNullOrEmpty() }) incomplete = true
                change { ui -> ui.copy(records = ui.records.map { row -> details[row.id]?.let(row::withCode) ?: row }) }
            }
            if (token == epoch && incomplete) change { it.copy(error = listOfNotNull(it.error, "部分签到码未获取，可下拉刷新重试").joinToString("；")) }
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { if (token == epoch) change { it.copy(error = error.message) } }
    }
    fun back(): Boolean {
        if (state.value.page == HomePage.HOME) return false
        if (state.value.submitting != null || state.value.loginPrompt != null) return true
        epoch++; job?.cancel()
        change { it.copy(page = if (it.page == HomePage.HISTORY) HomePage.COURSES else HomePage.HOME,
            selectedCourse = null, records = emptyList(), error = null, message = null) }
        return true
    }
    fun refreshDetail(id: String) = operation {
        val record = state.value.records.firstOrNull { it.id == id } ?: return@operation
        val courseId = record.courseId ?: state.value.selectedCourse?.id ?: return@operation
        val detail = read { it.client.detail(courseId, id, record.queryDate, it.profile.id) }
        change { it.copy(records = it.records.map { row -> if (row.id == id) record.merge(detail) else row }) }
    }
    fun submit(id: String) = operation {
        val course = state.value.selectedCourse ?: return@operation
        val original = state.value.records.firstOrNull { it.id == id } ?: return@operation
        val accountId = state.value.currentAccountId ?: state.value.accounts.firstOrNull { it.isDefault }?.id
            ?: throw RollcallException.message("请先添加默认账号")
        val account = state.value.accounts.firstOrNull { it.id == accountId } ?: throw RollcallException.message("账号不可用")
        // Persist intent before authentication and all writes to the remote service.
        change { it.copy(submitting = id, message = "正在准备签到") }
        val log = storage { store.begin(account, account.verifiedStudentId.orEmpty(), course, original) }
        var attempted = false; var accepted = false
        try {
            reload()
            // A read can renew an expired session before the first submission, but never retry a write.
            val courseId = original.courseId ?: course.id
            val date = original.queryDate
            var fresh = original.merge(read { it.client.detail(courseId, id, date, it.profile.id) })
            val current = ensureSession()
            storage { store.update(log.id, LogResult.PROCESSING, "正在准备签到", fresh.numberCode, fresh.kind, current.profile.id) }
            replace(fresh)
            if (fresh.isAnswered) {
                storage { store.update(log.id, LogResult.SUCCESS, "该账号已签到，本次未重复提交") }
                change { it.copy(message = "已签到，无需重复提交") }; return@operation
            }
            if (!fresh.canSubmit) throw RollcallException.message("签到已结束、状态未确认或暂不支持此形式，请刷新后重试")
            storage { store.update(log.id, LogResult.PROCESSING, "正在提交签到", fresh.numberCode, fresh.kind) }
            change { it.copy(message = "正在提交签到") }
            when (fresh.kind) {
                AttendanceKind.NUMBER -> {
                    val code = fresh.numberCode?.takeIf { it.isNotEmpty() } ?: throw RollcallException.message("未能取得数字签到码")
                    attempted = true
                    fresh = fresh.merge(remote { current.client.submitNumber(id, code, current.profile.id, courseId, date) })
                }
                AttendanceKind.RADAR -> {
                    attempted = true
                    if (!remote { current.client.submitRadar(id) }) throw RollcallException.message("雷达签到未完成，请稍后重试")
                    fresh = fresh.copy(personalStatus = "on_call_fine")
                }
                else -> throw RollcallException.message("暂不支持此签到形式")
            }
            accepted = true; replace(fresh)
            storage { store.update(log.id, LogResult.SUCCESS, "签到成功", fresh.numberCode, fresh.kind) }
            change { it.copy(message = "签到成功") }
        } catch (error: Exception) {
            val result = if (accepted || error is RollcallException && error.reason == RollcallException.Reason.UNCERTAIN ||
                attempted && error is CancellationException) LogResult.UNCERTAIN else LogResult.FAILURE
            if (error is RollcallException && error.reason == RollcallException.Reason.EXPIRED) {
                expireSession()
            }
            val message = if (error is CancellationException) {
                if (attempted) "操作中断，请核对签到状态" else "操作已取消，尚未提交签到"
            } else error.message ?: "操作未完成，请重试"
            try { withContext(NonCancellable) { storage { store.update(log.id, result, message) } } } catch (saveError: Exception) { report(saveError) }
            change { it.copy(message = message) }
        } finally { withContext(NonCancellable) { reload() } }
    }
    private fun replace(record: Attendance) = change { it.copy(records = it.records.map { row -> if (row.id == record.id) record else row }) }
    fun reconcile(id: String) = operation {
        val log = state.value.logs.firstOrNull { it.id == id } ?: return@operation
        if (state.value.currentAccountId != log.accountId || session == null)
            throw RollcallException.message("请先在账号管理登录这条记录对应的账号")
        val current = session!!
        if (log.studentId.isNotEmpty() && current.profile.id != log.studentId) throw RollcallException.message("登录账号与记录不一致")
        val date = rollcallDate(null, log.createdAt)
        val record = try { remote { current.client.detail(log.courseId, log.rollcallId, date, current.profile.id) } }
        catch (error: RollcallException) {
            if (error.reason == RollcallException.Reason.EXPIRED) expireSession()
            throw error
        }
        storage { when {
            record.isAnswered -> store.update(log.id, LogResult.SUCCESS, "已核对：学校记录显示已签到", record.numberCode,
                record.kind.takeUnless { it == AttendanceKind.UNKNOWN })
            record.isAbsent -> store.update(log.id, LogResult.FAILURE, "签到已结束，学校记录显示本人缺勤")
            else -> store.update(log.id, LogResult.UNCERTAIN, "暂未确认签到结果，可稍后再次核对")
        } }
        reload()
    }
}

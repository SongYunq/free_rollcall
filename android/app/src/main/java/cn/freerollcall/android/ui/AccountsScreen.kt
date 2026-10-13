package cn.freerollcall.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.viewmodel.compose.viewModel
import cn.freerollcall.android.app.*
import cn.freerollcall.android.storage.SavedAccount
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable fun AccountsScreen(model: AppModel, state: UiState) {
    val editor: AccountEditorState = viewModel { AccountEditorState(model::password, model::saveAccount) }
    var deleting by remember { mutableStateOf<SavedAccount?>(null) }
    var localError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    PageHeader("账号管理", action = {
        IconButton(onClick = { editor.open(null) }, enabled = !state.busy) { Icon(Icons.Outlined.Add, "添加账号") }
    })
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 24.dp), contentPadding = PaddingValues(bottom = 20.dp)) {
        item {
            Text(state.accountText, fontWeight = FontWeight.Medium, fontSize = 14.sp)
            Message("点击账号右侧的三个点可登录、修改、设为默认或删除\n未登录时，使用功能会自动登录默认账号")
            localError?.let { Message(it) }
            Spacer(Modifier.height(12.dp))
        }
        if (state.accounts.isEmpty()) item { EmptyState("添加你的第一个账号", "账号保存在本机，可随时修改或删除") }
        items(state.accounts, key = { it.id }) { account ->
            AccountRow(account, state.currentAccountId == account.id && state.authenticated, state.busy,
                login = { model.loginAccount(account.id) }, edit = { editor.open(account) },
                makeDefault = { scope.launch {
                    try { model.makeDefault(account.id) } catch (error: CancellationException) { throw error }
                    catch (error: Exception) { localError = error.message }
                } },
                delete = { deleting = account })
        }
        if (state.authenticated) item {
            TextButton(onClick = model::logout, enabled = !state.busy, modifier = Modifier.padding(top = 14.dp)) { Text("退出当前登录") }
        }
    }
    editor.draft?.let { draft -> AccountEditor(editor, draft) }
    deleting?.let { account -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除账号") },
        text = { Text("删除 ${account.username} 的本机账号和密码，已有签到日志会保留") },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } },
        confirmButton = { TextButton(onClick = {
            scope.launch {
                try { model.deleteAccount(account.id) } catch (error: CancellationException) { throw error }
                catch (error: Exception) { localError = error.message }
            }
            deleting = null
        }, enabled = !state.busy) { Text("删除", color = Danger) } }) }
}
@Composable private fun AccountRow(account: SavedAccount, current: Boolean, busy: Boolean,
    login: () -> Unit, edit: () -> Unit, makeDefault: () -> Unit, delete: () -> Unit) {
    var menuOpen by remember(account.id) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 98.dp).testTag("account-${account.id}"), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.PersonOutline, null, Modifier.width(32.dp), tint = Secondary)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Text(account.label, fontWeight = FontWeight.Medium, fontSize = 16.sp)
                if (account.note.isNotEmpty()) Text(account.username, color = Secondary, fontSize = 12.sp)
                if (account.isDefault || current) Text(listOfNotNull(if (account.isDefault) "默认账号" else null,
                    if (current) "已登录" else null).joinToString(" · "), color = Secondary, fontSize = 12.sp)
            }
            Box {
                IconButton(onClick = { menuOpen = true }, enabled = !busy) { Icon(Icons.Outlined.MoreHoriz, "账号操作 ${account.username}") }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, containerColor = Color.White) {
                    listOf("登录" to login, "修改" to edit, "设为默认" to makeDefault, "删除" to delete).forEachIndexed { index, (title, action) ->
                        DropdownMenuItem(text = { Text(title, color = if (index == 3) Danger else Color.Black) },
                            onClick = { menuOpen = false; action() }, enabled = !busy)
                    }
                }
            }
        }
    HorizontalDivider(color = Line)
}
@Composable private fun AccountEditor(editor: AccountEditorState, draft: AccountDraft) {
    Dialog(onDismissRequest = editor::cancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = Color.White) {
            Column(Modifier.safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp)) {
                Row(Modifier.fillMaxWidth().height(60.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = editor::cancel, enabled = !draft.saving) { Text("取消") }
                    TextButton(onClick = editor::save,
                        enabled = !draft.readingPassword && !draft.saving && draft.username.trim().isNotEmpty() && draft.password.isNotEmpty()) {
                        Text(if (draft.saving) "正在保存…" else "保存", fontWeight = FontWeight.SemiBold)
                    }
                }
                Text(if (draft.accountId == null) "添加账号" else "修改账号", fontSize = 28.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(30.dp))
                OutlinedTextField(draft.username, editor::username, label = { Text("账号") }, singleLine = true,
                    enabled = !draft.saving,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth().testTag("username"))
                Spacer(Modifier.height(16.dp))
                OutlinedTextField(draft.password, editor::password, label = { Text("密码") }, singleLine = true,
                    enabled = !draft.readingPassword && !draft.saving,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    visualTransformation = if (draft.visible) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = { IconButton(onClick = editor::togglePassword, enabled = !draft.saving) {
                        Icon(if (draft.visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (draft.visible) "隐藏密码" else "显示密码")
                    } }, modifier = Modifier.fillMaxWidth().testTag("password"))
                Spacer(Modifier.height(16.dp))
                OutlinedTextField(draft.note, editor::note, label = { Text("备注（可选）") }, singleLine = true, enabled = !draft.saving,
                    modifier = Modifier.fillMaxWidth().testTag("account-note"))
                Spacer(Modifier.height(14.dp))
                Message("密码加密保存在此设备上\n第一个账号会自动设为默认账号")
                draft.error?.let { Text(it, color = Danger, fontSize = 13.sp) }
            }
        }
    }
}

package cn.freerollcall.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.freerollcall.android.app.*

@Composable fun RollcallApp(model: AppModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val pageStates = rememberSaveableStateHolder()
    BackHandler(state.tab == AppTab.HOME && state.page != HomePage.HOME) { model.back() }
    Scaffold(containerColor = Color.White, bottomBar = { Dock(state.tab, model::switchTab) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (state.initializing) Loading("正在读取本地数据")
            else pageStates.SaveableStateProvider(state.tab.name) { when (state.tab) {
                AppTab.HOME -> HomeScreens(model, state)
                AppTab.LOGS -> LogsScreen(model, state)
                AppTab.ACCOUNTS -> AccountsScreen(model, state)
            } }
        }
    }
    // A new login attempt owns a new dialog and WebView, even if prompts change in one frame.
    state.loginPrompt?.let { prompt -> key(prompt.id) { AuthenticationDialog(model, prompt) } }
    state.notice?.let { text -> AlertDialog(onDismissRequest = model::dismissNotice,
        title = { Text("提示") }, text = { Text(text) },
        confirmButton = { TextButton(onClick = model::dismissNotice) { Text("知道了") } }) }
}
@Composable private fun Dock(selected: AppTab, choose: (AppTab) -> Unit) {
    val shape = RoundedCornerShape(40.dp)
    Box(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 38.dp, vertical = 10.dp), contentAlignment = Alignment.Center) {
        Row(Modifier.widthIn(max = 400.dp).fillMaxWidth().border(1.dp, Line, shape).background(Subtle, shape).padding(5.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            AppTab.entries.forEach { tab ->
                val active = selected == tab
                Box(Modifier.weight(1f).height(50.dp).clip(shape).background(if (active) Color.Black else Color.Transparent)
                    .selectable(selected = active, interactionSource = remember { MutableInteractionSource() },
                        indication = null, role = Role.Tab, onClick = { choose(tab) }).semantics { contentDescription = tab.title },
                    contentAlignment = Alignment.Center) {
                    Icon(when (tab) { AppTab.HOME -> Icons.Outlined.GridView; AppTab.LOGS -> Icons.Outlined.History
                        AppTab.ACCOUNTS -> Icons.Outlined.PersonOutline }, null, tint = if (active) Color.White else Secondary)
                }
            }
        }
    }
}

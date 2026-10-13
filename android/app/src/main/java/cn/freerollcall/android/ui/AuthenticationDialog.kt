package cn.freerollcall.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import cn.freerollcall.android.app.*
import cn.freerollcall.android.auth.*
import kotlinx.coroutines.CancellationException

@Composable fun AuthenticationDialog(model: AppModel, prompt: LoginPrompt) {
    Dialog(onDismissRequest = model::cancelLogin, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val context = LocalContext.current
        var progress by remember(prompt.id) { mutableStateOf(AuthProgress(prompt.manual)) }
        val engine = remember(prompt.id) { WebAuthenticator(context) { progress = it } }
        DisposableEffect(engine) { onDispose { engine.destroy() } }
        LaunchedEffect(prompt.id) {
            try { model.finishLogin(prompt.id, Result.success(engine.authenticate(prompt.credentials, prompt.manual))) }
            catch (error: CancellationException) { /* A recreated activity will restart the pending login. */ }
            catch (error: Exception) { model.finishLogin(prompt.id, Result.failure(error)) }
        }
        Column(Modifier.fillMaxSize().background(Color.White).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = model::cancelLogin) { Text("取消") }
                Spacer(Modifier.weight(1f))
                Text(if (progress.manual) "网页登录" else "登录账号", fontSize = 16.sp)
                Spacer(Modifier.width(76.dp))
            }
            Box(Modifier.fillMaxSize()) {
                AndroidView(factory = { engine.webView }, update = { view ->
                    view.importantForAccessibility = if (progress.manual) android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                        else android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                }, modifier = Modifier.fillMaxSize())
                if (!progress.manual) Column(Modifier.fillMaxSize().background(Color.White), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    CircularProgressIndicator(Modifier.size(30.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.height(24.dp)); Text(progress.text, fontSize = 18.sp)
                    Spacer(Modifier.height(12.dp)); Text(prompt.credentials.username, color = Secondary, fontSize = 14.sp)
                }
            }
        }
    }
}

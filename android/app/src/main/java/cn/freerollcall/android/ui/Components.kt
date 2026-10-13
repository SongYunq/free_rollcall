package cn.freerollcall.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag

@Composable fun PageHeader(title: String, back: (() -> Unit)? = null, action: (@Composable () -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {
        Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            if (back != null) IconButton(onClick = back, modifier = Modifier.offset(x = (-12).dp)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "返回")
            } else Spacer(Modifier.weight(1f))
            if (back != null) Spacer(Modifier.weight(1f))
            action?.invoke()
        }
        Text(title, fontSize = 30.sp, fontWeight = FontWeight.Bold, lineHeight = 38.sp)
        Spacer(Modifier.height(20.dp))
    }
}
@Composable fun Message(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.fillMaxWidth().padding(vertical = 12.dp), color = Secondary, fontSize = 13.sp, lineHeight = 20.sp)
}
@Composable fun EmptyState(title: String, subtitle: String = "") {
    Column(Modifier.fillMaxWidth().padding(vertical = 64.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.Medium)
        if (subtitle.isNotEmpty()) Text(subtitle, color = Secondary, fontSize = 13.sp)
    }
}
@Composable fun Loading(text: String) {
    Row(Modifier.fillMaxWidth().testTag("page-loading").padding(20.dp), horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(12.dp)); Text(text, color = Secondary, fontSize = 13.sp)
    }
}
@Composable fun FieldLine(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        Text(title, Modifier.width(76.dp), color = Secondary, fontSize = 14.sp)
        SelectionContainer(Modifier.weight(1f)) { Text(value, fontSize = 14.sp, lineHeight = 21.sp) }
    }
    HorizontalDivider(color = Line)
}
@Composable fun CodeText(text: String) {
    SelectionContainer { Text(text, fontSize = 18.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold) }
}

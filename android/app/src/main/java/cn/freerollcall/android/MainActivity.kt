package cn.freerollcall.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import cn.freerollcall.android.app.AppModel
import cn.freerollcall.android.storage.LocalStore
import cn.freerollcall.android.ui.*

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T {
                @Suppress("UNCHECKED_CAST")
                return AppModel(LocalStore(applicationContext)) as T
            }
        }
        val result = runCatching { ViewModelProvider(this, factory)[AppModel::class.java] }
        setContent {
            RollcallTheme {
                result.fold({ RollcallApp(it) }, {
                    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp), verticalArrangement = Arrangement.Center) {
                        Text("本地数据无法打开")
                        Spacer(Modifier.height(12.dp))
                        Text("请检查本机可用存储后重新打开应用")
                    }
                })
            }
        }
    }
}

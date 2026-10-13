# free_rollcall · Android

面向作者个人使用的独立原生安卓应用，适配作者所在高校的教学平台。最低支持 Android 8.0，使用 Kotlin 和 Jetpack Compose，界面参考本项目 iOS 版本，白色底色、黑色主题和普通胶囊底部栏。

安卓工程独立位于本目录，不调用根目录 Python 服务或 Swift 代码。

## 打开与构建

在 Android Studio 中打开 **`android/` 目录**，等待 Gradle 同步完成，选择手机或模拟器运行 `app`。

所需环境：JDK 17 或 21、Android SDK Platform 36、Build Tools 35.0.0。工程固定 Gradle 8.11.1、Android Gradle Plugin 8.10.1、Kotlin 2.0.21 和 Compose BOM 2024.12.01。首次构建需要下载依赖。

命令行构建，在本目录执行：

```bash
./gradlew assembleDebug
```

调试安装包位于 `app/build/outputs/apk/debug/app-debug.apk`，用于开发调试。

日常验收建议使用经过优化的 `preview` 包：

```bash
./gradlew assemblePreview
```

产物为 `app/build/outputs/apk/preview/app-preview.apk`。此版本关闭调试、启用 Release 同等的代码与资源优化，并使用本机调试签名，可直接安装。包名和签名与同一台电脑生成的调试版一致，可覆盖升级并保留账号与日志。正式分发仍使用你自己的 Release 签名。

```bash
./gradlew testDebugUnitTest lintDebug assembleRelease
```

Release 产物是 `app/build/outputs/apk/release/app-release-unsigned.apk`，需要你自己的签名后安装。可在 Android Studio 的 **Build → Generate Signed App Bundle or APK** 中签名，不把密钥写进仓库。

命令行找不到 SDK 时，在忽略的 `local.properties` 中填写 `sdk.dir`；Android Studio 通常会自动生成这个文件。包名为 `cn.freerollcall.android`。

## 使用

### 账号管理

- 点右上角加号添加账号、密码和可选备注，第一个账号自动设为默认。
- 编辑账号时旋转屏幕会保留当前输入；草稿只在内存中保留，取消或成功保存后清除。
- 点击账号右侧的三个点，打开登录、修改、设为默认、删除菜单；账号条目不使用横向滑动。
- 登录成功后整个应用沿用该账号；未登录进入课程时，自动登录默认账号。
- 设置默认只影响后续默认登录，不切换当前会话。修改当前账号的凭证会使会话失效；删除默认账号后，剩余的最早账号成为默认。
- 自动登录使用统一身份认证网页自身的表单与加密脚本；需要验证码时会显示网页供你完成。连续三次凭证错误改为网页登录，网络异常不计入次数。
- 登录时可取消。手动网页登录必须使用所选账号，防止签到归到另一个账号。

### 功能

- 默认打开功能页，点击“进入课程”只列出当前学期课程，课程分页由程序自动处理。
- 选择课程查看历史签到，数字签到码会直接出现在列表里，包含已经结束的记录，保留前导零。部分代码未获取时可下拉刷新。
- 已签到与迟到保持对应文案；明确为本人未签到且活动已结束的记录显示红色“缺勤”；正在进行的未签到显示“正在签到”。未知本人状态不会直接判为缺勤。
- 点击进行中的可用条目直接签到，数字码自动填写并保留在屏幕上，雷达采用既有参考机器人流程。其他条目可查看详情。
- 下拉或点击右上角刷新可重新查询；历史较多时用“加载更多记录”翻页。

### 本地日志

每次签到尝试记录时间、课程、形式、结果、账号信息和数字码；雷达的码栏显示“雷达签到”。日志可离线查看，删除账号会保留过去的账号快照和日志。

数字提交后会短暂重查本人状态，避免服务端更新延迟导致立刻显示待确认。若连接中断、结果查询失败或应用退出，日志可能为“待确认”，这表示最终结果尚未取得。登录原账号后，在详情中点“核对学校端结果”，只查询，不再次提交。

## 数据与权限

账号和日志使用应用私有 SQLite 数据库。密码由 Android Keystore 的 AES-GCM 加密，绑定账号标识保存；不写入日志。登录会话只保留在内存中，每次登录清理网页登录状态，并将 Cookie 隔离到当前账号的教学平台会话。

应用仅声明联网权限，不申请定位、文件或通知权限。雷达完全参考已有方案，不读取设备位置。关闭系统云备份与设备迁移，卸载应用会删除本地数据。

## 代码位置

| 目录 | 职责 |
| --- | --- |
| `app/src/main/java/cn/freerollcall/android/core/` | 接口、模型、分页、数字和雷达签到 |
| `app/src/main/java/cn/freerollcall/android/auth/` | 网页登录和账号身份确认 |
| `app/src/main/java/cn/freerollcall/android/storage/` | 账号加密存储和本地日志 |
| `app/src/main/java/cn/freerollcall/android/app/` | 全局会话、操作状态和页面导航 |
| `app/src/main/java/cn/freerollcall/android/ui/` | 三个入口与页面交互 |
| `app/src/test/` | 离线接口与状态单元测试 |
| `app/src/androidTest/` | 模拟器加密存储和界面测试 |

测试只使用虚拟账号和响应，测试数据注入只在测试包中，不提供生产演示模式。运行设备测试：

```bash
./gradlew connectedDebugAndroidTest
```

实施方案见 [实施计划](project_docs/IMPLEMENTATION_PLAN.md)，测试及交互与性能修复结果见 [验证记录](project_docs/IMPLEMENTATION_PROGRESS.md)，当前版本的完整目录检查见 [安卓检查与修复](project_docs/ANDROID_AUDIT.md)。真实学校登录和签到需后续真机验收，本轮使用离线响应验证。第三方移植说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

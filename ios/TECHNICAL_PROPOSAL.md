# free_rollcall iOS 版技术方案参考

编写日期：2026-09-14  
状态：源码评估与架构建议；尚未创建 iOS 应用工程，也未验证学校系统在 iPhone 上的登录和接口行为。

## 1. 推荐结论

建议在当前项目中单独建立 `ios/`，采用 **Swift + SwiftUI 原生界面、轻量 MVVM 分层、WebKit 登录适配、URLSession 接口请求**，重新实现现有核心功能。第一版不增加自建服务器，不嵌入 Python 运行环境。

你的“根据核心文件和方法，新做一个独立文件夹，后续用 Xcode 打开”的想法是可行的。需要补充的是：**最终交付应包含可直接打开的 `.xcodeproj` 工程，而不仅是一组源码文件。** 现在的 `ios/` 只存放本文；下文目录为后续实施建议。

推荐理由：现有功能集中、界面规模小，最值得保留的是查询流程和字段处理规则；桌面界面与浏览器自动化本身都需要换成适合 iOS 的实现。Apple 将 SwiftUI 定位为创建新应用的优先选择，适合此类新建的 iOS 工具应用。[Apple：SwiftUI apps](https://developer.apple.com/documentation/technologyoverviews/swiftui)

**建议后续使用 Xcode 完成首次运行、真机调试和签名配置；日常编辑代码不必一直打开 Xcode。** 本地编译仍需要完整 Xcode 及 iOS SDK，单独安装 Command Line Tools 不够。[Apple：命令行工具说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

该推荐有一个关键前提：先验证 iOS 上能完成学校登录、取得有效会话及内部学生 ID，并成功查询数据。原生架构适合本项目，不等于这些外部条件已经验证通过。

## 2. 当前项目的核心在哪里

以下判断来自当前源码，不依赖 `dist/` 中已有的打包产物。

| 文件 | 实际职责 | iOS 迁移时的用途 |
| --- | --- | --- |
| `free_rollcall.py` | 按启动参数选择 GUI 或 CLI | 仅参考入口关系；改用 SwiftUI App 入口 |
| `free_rollcall_app.py` | 同时包含业务函数、Playwright 登录、线程调度和 CustomTkinter 界面 | **主要行为参考**，提取核心业务与页面流程 |
| `free_rollcall_cli.py` | 与 GUI 大体重复的登录、学期、课程和签到查询逻辑 | **交叉核对参考**，避免遗漏处理规则 |
| `rollcall_capturer.py` | 基于页面元素操作的独立抓取脚本，可使用 `state.json` | 当前 GUI/CLI 入口没有导入它，不作为新版本主干 |
| `requirements.txt` | requests、playwright、customtkinter、PySocks | 描述 Python 桌面依赖，不作为 iOS 依赖清单 |
| `free_rollcall.spec`、`dist/` | PyInstaller 配置及桌面产物 | 不纳入 iOS 构建 |
| `.venv/`、`__pycache__/`、IDE 配置 | 本地运行环境、缓存与编辑器设置 | 无需整理，也无需复制到新工程 |

因此，不必先清理或重构原项目。新工程可以在运行和构建上完全独立，只把旧源码作为行为参考。已有 `LICENSE` 中的版权与许可声明应随迁移内容保留。

当前主流程为：

```text
用户在浏览器中登录学校统一认证
             ↓
获取畅课 Cookie，并从请求 URL 中提取内部 student_id
             ↓
查询当前学期 → 查询课程列表
             ↓
选择课程 → 查询签到记录 → 查询签到详情
             ↓
显示数字码、状态和发起时间；支持再次查询
```

这里的 `student_id` 是畅课内部标识，不能默认等同于用户输入的学号。源码中的“后端业务逻辑”只是本地 Python 函数，项目没有独立部署的业务服务器；当前实现查询签到信息，没有提交签到操作。

### 2.1 核心方法及迁移映射

| 当前方法（GUI 文件行号） | 当前行为 | 推荐 iOS 归属 |
| --- | --- | --- |
| `login_and_get_cookie`（60） | 打开浏览器，监听请求获取 ID，收集 Cookie | `AuthCoordinator` + `StudentIdentityResolver` + `SessionStore` |
| `get_current_semester_info`（45） | 查询学期、学年；失败返回固定值 | `TronclassAPIClient.fetchCurrentSemester()`；移除固定学期回退 |
| `get_courses`（162） | 提交筛选条件、解析列表并按 ID 去重 | `CourseRepository`；补充分页与类型校验 |
| `get_latest_rollcall_id`（209） | 获取记录并直接取数组最后一项 | `RollcallRepository`；明确排序和分页后选择最新记录 |
| `get_number_code`（236） | 从详情读取数字码、状态、结束时间 | `RollcallRepository` + `RollcallDetail` 模型 |
| `run_async` / `run_sync_in_thread` | 后台线程执行，回调更新桌面界面 | Swift `async/await`、任务取消、`@MainActor` 界面状态 |
| `FreeRollcallApp` | 登录、课程、结果及日志页面 | SwiftUI 页面与对应 ViewModel |

行号对应本次检查的文件版本，后续旧源码变更后可能变化。

### 2.2 接口参考清单

主机为 `https://lnt.xmu.edu.cn`。下面是源码已经使用的接口，**并非已确认稳定的官方开放 API 契约**；还没有实际登录验证其当前响应。

| 请求 | 作用 | 源码依赖的响应字段 |
| --- | --- | --- |
| `GET /api/current-semester-info` | 当前学期与学年 | `semester.id`、`academic_year.id` |
| `POST /api/my-courses` | 课程查询 | 列表本身，或 `courses` / `data`；课程 `id`、`name`、`display_name` |
| `GET /api/course/{course_id}/student/{student_id}/rollcalls` | 某课程的个人签到记录 | 列表本身，或 `rollcalls` / `data`；`id` / `rollcall_id`、时间字段 |
| `GET /api/rollcall/{rollcall_id}/student_rollcalls` | 签到详情 | `number_code`、`status`、`end_time` |

课程查询当前按学期、学年及 `recently_started` 筛选，固定请求第 1 页、每页 30 条；签到记录固定第 1 页、每页 99 条。要保留筛选意图，但不能据此声称一定获得全部课程或全部签到记录。

## 3. 架构路线对比：优缺点与主流程度

“主流”在此指技术成熟度、平台支持和生态常见程度的工程判断，不是市场占有率排名；“适合本项目”另行判断。

| 方案 | 是否主流 | 优点 | 缺点及本项目适配成本 | 建议 |
| --- | --- | --- | --- | --- | --- |
| **Swift + SwiftUI 原生** | **Apple 官方主流，新项目优先路线** | 原生体验好；WebKit、网络与系统存储直接接入；依赖少；Xcode 工程清晰 | Python 逻辑需重写；Android 不能直接复用界面；仍需验证登录 | **当前首选** |
| Swift + UIKit 原生 | Apple 官方成熟主流 | 控件和生命周期控制细；成熟项目经验丰富 | 当前几个简单页面需写更多界面代码，收益有限 | 局部需要时与 SwiftUI 混用，不必全量采用 |
| Flutter + Dart | 主流跨平台路线 | iOS/Android 可共享较多界面和业务代码；适合统一视觉 | 要重写 Python；引入 Flutter 工具链；登录桥接仍依赖 iOS 能力 | 明确近期要做 Android 时再优先考虑 |
| React Native + TypeScript，配合 Expo | 主流跨平台路线 | 适合已有 React 技术积累；可用云构建；多平台复用 | 当前没有 React 代码可复用；Cookie 与复杂登录可能需要原生模块；增加依赖维护 | 有 React 经验或明确云构建需求时考虑 |
| Python 移动框架，例如 Kivy | 可行但属于较小众的 iOS 路线 | 部分纯 Python 规则可能复用 | CustomTkinter UI 和当前 Playwright 浏览器链路不能原样保留；桥接和打包成本仍在 | 不建议仅为保留这几段 Python 函数而采用 |
| 网页/PWA | 成熟 Web 交付方式，不等同于原生 App | 浏览器访问、部署更新方便；网页本身不需要 Xcode | 本项目没有现成 Web 前端；跨域和认证会话不能照搬 Python；未必能独立直连学校接口 | 只有接受网页形态且认证/API 条件允许时再评估 |
| iOS 客户端 + 自建 Python 服务 | 常见客户端/服务器架构 | 可复用部分服务端查询逻辑；集中维护接口适配 | 需部署、运维、网络可达与会话隔离；交互登录仍要另做；手机依赖服务器 | 本项目第一版没有足够收益，不推荐 |

SwiftUI 支持与 UIKit 混用；Flutter 和 React Native 均有正式 iOS 开发路径。[Apple：SwiftUI](https://developer.apple.com/swiftui/)、[Flutter：iOS 开发配置](https://docs.flutter.dev/platform-integration/ios/setup)、[React Native：环境配置](https://reactnative.dev/docs/set-up-your-environment)

Kivy 的 iOS 打包路线本身仍包含 Xcode 工程与平台构建步骤；选择 Python 并不意味着可以继续使用现在的桌面打包方式。[Kivy：iOS 打包](https://kivy.org/doc/stable/guide/packaging-ios.html)

PWA 的具体限制是：自建网站与学校网站属于不同来源，浏览器脚本读取跨域接口响应需要服务器的 CORS 配合；打开学校登录页不会自动让自建网站获得可使用的认证凭据。因此，“改成网页就不需要处理登录迁移”不成立。这是根据浏览器标准对本项目的推断，学校实际 CORS 配置尚未检查。[WHATWG：Fetch / CORS 协议](https://fetch.spec.whatwg.org/#http-cors-protocol)

## 4. 推荐的原生应用内部架构

采用**轻量 MVVM + 服务/数据层**。MVVM 是常见组织方式，并非 SwiftUI 强制要求；此处用它把页面状态与网络、登录逻辑分开，方便学校接口变化时集中修改。

```text
SwiftUI 页面：登录 / 课程 / 签到详情
                   ↓
ViewModel：加载、成功、空数据、错误、会话过期
                   ↓
Repository：课程规则 / 最新签到选择 / 数据转换
                   ↓
TronclassAPIClient：URLSession + JSON 解析
                   ↓
学校现有 HTTPS 接口

AuthCoordinator ─→ WKWebView 登录适配 ─→ SessionStore
                                             ↓
                                      APIClient 的会话
```

| 层或组件 | 技术与职责 | 取舍 |
| --- | --- | --- |
| 界面层 | SwiftUI；必要时用 `UIViewRepresentable` 包装 `WKWebView` | 原生页面保持简单，登录网页单独封装 |
| 页面状态 | ViewModel；主线程发布状态；使用 `async/await` 发起任务 | 取代桌面线程回调，切换页面时取消过时任务 |
| 数据模型 | Swift `Codable`；学期、课程、签到记录、详情模型 | 将可选字段与异常结构集中处理 |
| 查询层 | 轻量 Repository | 统一分页、去重和最新记录选择，不扩展成复杂框架 |
| 网络层 | 系统 `URLSession` | 第一版不引入第三方网络库 |
| 会话层 | 内存会话 + WebKit Cookie 管理；如需持久化凭据，使用 Keychain | 不把 Cookie 存入普通配置文件 |
| 配置与缓存 | `UserDefaults` 存非敏感偏好；课程可先只缓存在内存 | 当前无需数据库、云同步或自建账号系统 |
| 调试 | 脱敏日志，记录请求结果、耗时、错误类型 | 不照搬含签到码、完整响应正文的桌面日志 |

Keychain 是 Apple 用于存储小型敏感数据的加密存储机制；它不负责延长服务器会话有效期，保存了 Cookie 仍可能需要重新登录。[Apple：Keychain services](https://developer.apple.com/documentation/security/keychain-services)

建议第一版暂定支持 **iOS 17 及以上**，以控制适配工作量。这是项目范围建议，不是 SwiftUI 的最低系统要求；如果目标手机系统更旧，可以调整实现。最低部署版本、编译所用 SDK 版本是两个不同概念。

## 5. 最需要先验证的部分：登录与学生 ID

### 5.1 现有 Playwright 逻辑不能直接平移

当前代码通过桌面 Chrome/Edge/Chromium 登录，再用 `page.on("request")` 监听请求 URL 获取学生 ID。iOS 新应用需要重写这一段，不应打包桌面浏览器，也不应把“嵌入一个网页”视为完整替代方案。

Apple 的 `WKNavigationDelegate` 用于导航管理和导航进度，**不是覆盖页面所有 XHR/fetch 请求的 Playwright 式网络监听器**。所以仅监听网页跳转 URL，不能保证获取现有代码依赖的 `/student/.../rollcalls` 请求。[Apple：WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate)

### 5.2 登录路径的选择顺序

**如果学校提供可接入的标准认证回调：优先使用系统认证会话。**

使用 `ASWebAuthenticationSession`，由认证服务通过回调交付应用所需凭据。这是系统提供的网页认证路径。但当前源码只有网页登录和 Cookie 提取，没有证明学校提供面向这个第三方 App 的认证注册、回调或凭据交换能力。不能自行设定一个回调地址，就假定学校会配合；该 API 也不是导出 Safari Cookie 或读取页面内容的通用接口。[Apple：ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)

**在现有条件下：先用 `WKWebView` 做兼容性原型。**

让用户在学校原有网页中完成登录，验证统一认证跳转、验证码以及成功后的会话。通过 `WKHTTPCookieStore` 管理这个 WebView 的 Cookie，并验证适用于畅课主机的会话能否供原生查询使用。它管理的是 App 自己的 WebView 数据，不能据此读取系统 Safari 的任意会话。[Apple：WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)

如果认证系统不接受嵌入式登录，必须重新评估官方认证接入条件；更换成 Flutter 或 React Native 不会自动解决服务端认证限制。

### 5.3 StudentIdentityResolver 的职责

先核实登录后是否存在当前用户信息响应、页面初始化数据等可靠的内部 ID 来源。**目前没有确认这样的接口或字段，不能预设一个 `/api/me` 就开始依赖它。**

如果只能依赖网页自身请求，可评估在受控的畅课页面中通过 WebKit 脚本桥接识别必要的 ID 元数据。这只是兼容性备选：页面脚本结构、执行时机、iframe 或 Worker 都可能影响覆盖范围，不等同于完整网络抓包。桥接应限定学校业务页面的来源和消息内容，不能依靠它读取密码或把全部请求内容传给应用。

无课程账号也应能结束登录流程并显示“暂无课程”，不能因没有第一门课程可用来触发请求而永久卡在登录界面。

### 5.4 Cookie 与原生请求的边界

WebKit Cookie 存储和 `URLSession` 使用的会话存储应按两个需要显式协调的组件设计，不能假设自动同步。迁移时需核对：

- Cookie 的 domain、path、Secure、有效期及同名 Cookie；不要复刻当前简单字符串筛选与拼接。
- 仅向匹配主机和路径的请求附带所需 Cookie，不能把所有学校子域的认证 Cookie 都转发给畅课接口。
- 查询是否还需要 CSRF token、特定头字段或网页状态；当前 Python 代码不足以证明 Cookie 永远是唯一条件。
- 会话更新、失效和退出时，同步清理原生会话与应用管理的网页登录数据。
- 以受保护接口的有效响应确认登录成功，不能只凭“离开登录域名”判断。

如果原生请求无法复现有效会话，而学校页面内的同源请求可用，可评估把请求暂留在 WebView 中，再将必要结果返回原生层。这会增加网页耦合，应作为验证后的备选，并在工程中明确标注。

## 6. 迁移时应直接改正的旧逻辑

这些修改只在新版本中实施，无需为此整理原有目录。

| 源码现状 | 可能产生的结果 | 新版本要求 |
| --- | --- | --- |
| 学期查询失败就返回 `29`、`12` | 接口异常被掩盖，查询错误学期 | 显示可重试错误；若使用历史缓存，要明确标注 |
| 课程固定只取 30 条，且附带特定课程分类 | 列表不完整，标题可能误称“全部课程” | 核实筛选语义并实现分页 |
| 签到记录取 `rollcalls[-1]`，只读一页 | 排序与预期不一致时选错“最新” | 核实服务端排序/分页；按可靠时间字段选择，不能只对不完整一页排序后声称全局最新 |
| 多数请求未设置超时，状态码校验不足 | 长时间等待；登录页 HTML 被误当 JSON | 统一超时、取消、状态码、重定向和响应类型校验 |
| GUI 查询异常最终展示“暂无签到记录” | 把网络故障当作业务空数据 | 分开显示无数据、无权限、会话过期、网络错误和解析失败 |
| GUI/CLI 详情主要读取顶层字段 | 嵌套结构或字段变化时丢失结果 | 根据实际响应定义兼容解码，未知结构显式报错 |
| 以真假值判断数字码 | 空值、数字零与字符串可能混淆 | 统一展示为字符串，区分缺失与有效值；字符串保留前导零 |
| 状态与时间处理较分散 | 已结束或未知状态的记录容易被误解 | 状态枚举保留未知值；明确已结束状态；按 `Asia/Shanghai` 展示课程时间 |
| 后台回调可能在页面切换后返回 | 过时结果更新错误页面 | 支持取消，并校验当前课程/请求身份 |
| 日志包含签到码或完整错误响应 | 调试输出包含不必要的个人信息 | 仅保留脱敏诊断内容 |

第一版保留“手动查询、手动刷新”即可，不承诺切到后台后持续监控。

## 7. 独立文件夹与最终交付形式

后续建议形成以下结构，当前仅本文已创建：

```text
free_rollcall/
├── 原有 Python 文件及目录……
└── ios/
    ├── TECHNICAL_PROPOSAL.md       # 本文
    ├── README.md                  # 打开、运行、签名、已知限制
    ├── LICENSE                    # 保留原许可声明
    ├── FreeRollcall.xcodeproj/     # 后续使用 Xcode 打开的入口
    ├── FreeRollcall/
    │   ├── App/                   # 应用入口及依赖组装
    │   ├── Features/
    │   │   ├── Auth/              # 登录界面与协调器
    │   │   ├── Courses/           # 课程列表与状态
    │   │   └── Rollcall/          # 签到详情与状态
    │   ├── Core/
    │   │   ├── Models/
    │   │   ├── Networking/
    │   │   ├── Session/
    │   │   └── Repositories/
    │   └── Resources/             # 图标、颜色等
    └── FreeRollcallTests/          # 关键解析、排序、会话错误测试
```

验收时应确认：把整个 `ios/` 复制到其他位置，仍可独立打开和构建；不能引用上层 `.venv`、Python 文件或桌面产物。工程文件、资源、构建设置及共享 Scheme 应一并提供，避免你手动把散落源码拖进 Xcode。

## 8. 到底要不要用 Xcode

需要把“写代码”“构建”“安装运行”分开看。

| 你要做的事情 | 是否必须打开 Xcode 界面 | 是否需要 Xcode 工具链 |
| --- | --- | --- |
| 阅读或编辑 Swift 源码 | 不必须，可用其他编辑器 | 仅编辑文本不需要 |
| 本地编译推荐的原生工程 | 不必须，配置完成后可用 `xcodebuild` | **需要完整 Xcode 和 iOS SDK** |
| 初次在自己的 iPhone 上调试 | 强烈建议，签名和设备配置更直观 | 本地开发需要 |
| 持续集成或远程 Mac 构建 | 本机不必打开 | 构建端仍需要 Apple 工具链 |
| Flutter / React Native 本地 iOS 构建 | 可主要使用其他编辑器和命令行 | 仍需要 |
| Expo EAS 等云构建 | 可不在本机安装或打开 | 工具链由云端构建环境承担 |
| 仅交付网页/PWA | 不需要 | 网页交付不需要，但不解决本项目认证条件 |
| 在手机上使用已安装且签名有效的 App | 不需要 | 手机不安装 Xcode，也不需要 Python 环境 |

Apple 提供 `xcodebuild` 执行构建、测试和归档；这些工作可以自动化，不要求日常一直打开 IDE。[Apple：命令行构建 FAQ](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)

Expo EAS 可以将项目上传到云端生成应用二进制，其 iOS 构建在 macOS 环境执行。因此可以减少本机工具安装，但会增加云服务配置、凭据管理和远程调试成本；不建议仅为避开 Xcode 而让这个小项目改用另一套语言和框架。[Expo：EAS Build](https://docs.expo.dev/build/introduction/)

### 8.1 你这台电脑的检查结果

本次只读命令检查得到：

- macOS：26.6。
- 当前开发工具路径：`/Applications/Xcode.app/Contents/Developer`。
- `xcodebuild -version`：Xcode 26.6，Build 17F113。
- `xcodebuild -showsdks`：列出了 iOS 26.5 与 iOS Simulator 26.5 SDK。

说明本机已有完整 Xcode 和 iOS SDK 基础，不必先改走云构建。命令执行中出现了文件事件流/缓存路径诊断提示，但成功返回版本与 SDK 信息；尚未验证实际工程构建、模拟器运行时安装、设备连接和账号签名。

### 8.2 安装到手机与发布是不同阶段

个人测试可以使用 Xcode 的免费 Personal Team。Apple 当前说明此类配置描述文件在签发后 7 天过期，需要重新构建并安装；它不是永久分发方式。TestFlight 或 App Store 分发通常需要加入 Apple Developer Program 并完成相应流程。架构选择本身不代表已经获得发布资格或通过审核。[Apple：开发者账号与 Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account)

对你当前阶段的建议是：先用模拟器检查界面，再用自己的 iPhone 验证登录和完整查询，不必为了技术选型提前决定公开发布方式。

## 9. 后续实施顺序与完成标准

### 阶段一：核心链路验证

在独立工程中只做最小登录页面和一条查询链路，验证：

1. 真机内能完成学校登录，取消、失败和重新登录都能正常返回。
2. 能获取当前用户的内部 ID 和有效会话；无课程情况也能正常结束流程。
3. 能取得学期、课程、签到记录及详情，明确原生请求是否可行。
4. 明确接口排序、分页、字段类型，以及会话过期后的返回形式。

**进入完整界面开发的条件：在真机走通上述链路，或清楚限定缺失的外部条件。** 如果卡在学校认证能力，不应继续堆界面并声称功能可用。

### 阶段二：完整功能迁移

完成登录、课程列表、签到详情和手动刷新；加入退出登录、统一错误状态与必要的会话管理，落实第 6 节的数据处理修正。保持与当前查询工具一致的功能范围。

### 阶段三：工程交付与验证

- Xcode 可直接打开，模拟器构建通过，独立目录不依赖旧项目环境。
- 真实账号在真机上完成登录及查询；账号密码由用户在学校网页内输入。
- 使用脱敏响应样例验证不同列表结构、缺失数字码、未知状态、时间排序和分页。
- 验证会话过期、无课程、无签到记录、网络失败、重复刷新和切换页面时的表现。
- README 写明工程入口、最低系统版本、签名操作和仍存在的限制。

本次已经完成的是核心源码审阅、技术路线比较、Apple/框架官方文档核对及本机工具链信息检查。尚未创建应用代码、登录学校账号、调用真实业务接口或进行 iOS 编译测试。下一步最有价值的工作是验证原生登录与查询链路，再据此完成独立的 Xcode 工程。

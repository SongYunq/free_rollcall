# free_rollcall · HarmonyOS

面向 **HarmonyOS 5.0.0（API 12）及以上**的独立原生客户端。功能与界面参考同仓库 iOS 版：白底黑色主题、纵向列表、底部依次为「功能、本地日志、账号管理」，保留当前账号优先于默认账号的规则。

整个 `harmony/` 目录可以单独复制使用。运行时不依赖上层 Python、Go、iOS、安卓、账号文件或自建服务器，也没有第三方运行库。

## 在 DevEco Studio 中打开

1. 安装与本工程兼容的 **DevEco Studio 稳定版**。开发态版本以 `hvigor/hvigor-config.json5` 为准，最低兼容和目标系统设置为 `5.0.0(12)`；编译使用开发工具内置的配套 SDK。工具版本与应用最低系统版本是两个独立设置。
2. 选择 **Open**，打开整个 `harmony/` 目录，等待工程同步完成；无需重新创建项目，也不要只打开 `entry/`。
3. 选择 `entry` 模块与 `default` 产品。首次打开时，根据工具提示配置本机 SDK 路径并下载所需设备镜像；本仓库没有写入作者机器的绝对路径。
4. 选择模拟器或连接自己的鸿蒙真机。真机运行时，在 **Project Structure → Signing Configs** 登录自己的华为开发者账号，配置自动签名。默认应用包名为 `cn.freerollcall.harmony`，需要时自行修改。
5. 点击 Run。进入「账号管理」添加账号，返回「功能」点击「进入课程」，使用默认账号登录；也可以左滑账号，主动登录另一个账号。

工程不附带本机签名、密钥或真实账号；自动签名由 DevEco 在使用者机器上生成。`local.properties`、签名文件、构建产物和编辑器缓存已忽略。

## 已实现功能

- 三个底部入口与独立页面状态，课程列表、签到列表、签到详情、日志详情和账号编辑。
- 账号添加、修改、登录、设为默认、删除；第一个账号自动默认，删除默认账号后不自动指定其他账号；删除账号保留历史日志。
- 修改默认账号不切换当前登录账号；切换账号失败保留原来的有效会话；修改当前账号凭证后使旧会话失效，只改备注则保持会话。
- 使用学校原始网页登录页面，自动填写并触发原有表单，由学校页面处理密码加密；验证码、额外认证可手动完成，支持取消和超时。同一账号连续三次明确的凭证错误转为人工登录，网络错误不计入次数。
- 每次网页登录使用独立的隐私网页，清理旧认证数据，核验学校返回的学生身份；认证凭证只留内存，不存入账号配置或日志。
- 获取当前学期与学年，再查询本学期课程，自动处理课程分页。签到历史去重，活动优先，支持刷新和继续加载；无法证明完整时如实说明范围。
- 按课程和北京时间日期批量取得数字签到码，保留前导零；只识别当前学生自己的出勤状态，缺失或未知状态不会被判成缺勤，也不会覆盖已确认的签到或迟到记录。
- 数字签到真实请求实现与提交后的本人状态回读；雷达按 iOS 已采用的参考算法和提交顺序移植，不调用定位、不申请位置权限。
- 点击「点击此条目签到」即提交；提交前再查询活动，已签到时不重复提交，提交期间阻止重复点击。请求中断或结果未确认时保存「待确认」，支持原账号只读核对。
- 本地日志保存时间、课程、形式、账号、数字码和结果；上次中断的「处理中」记录在下次启动转为「待确认」。

账号密码由系统 **Asset Store** 安全存储，设置为设备解锁后访问、不同步；账号信息和日志由 **Preferences** 保存在应用本地。不会将密码降级为明文配置，不读取根目录 `account.json`。

底栏使用鸿蒙组件实现胶囊和模糊背景，不包含 iOS 专属的液态玻璃材质。应用保持白色外观，界面支持列表滚动、换行与基础无障碍名称；具体字号、键盘、滑动和设备适配效果仍需在 DevEco 环境验收。

## 项目结构

```text
AppScope/                        应用名称、包名、图标、版本
build-profile.json5              产品、最低系统与构建配置
hvigor/                          华为构建工具配置
entry/src/main/module.json5      原生入口与网络权限
entry/src/main/ets/
  entryability/                  原生应用生命周期
  pages/Index.ets                三个入口及所有页面
  app/AppModel.ts                账号、会话、课程、提交和日志协调
  app/Contracts.ts               本地数据与平台接口
  core/                         数据模型、学校接口、签到与雷达逻辑
  platform/                     网络、原生网页认证和安全存储
entry/src/main/resources/        图标、字符串、页面注册
tests/                          离线业务及模拟平台测试
scripts/                        离线检查入口
project_docs/                   实施与验证记录
```

业务逻辑使用普通 TypeScript，原生界面和平台连接使用 ArkTS；前者能够离线测试，后者由鸿蒙工具编译。两者通过明确的类型接口连接，不在原生页面里处理动态学校响应。

## 离线测试

只检查项目结构与资源，不需要安装依赖：

```sh
cd harmony
node scripts/check-project.mjs
```

运行完整离线测试需要 Node.js 22 或更新版本及开发依赖：

```sh
cd harmony
npm install
npm test
```

已有 TypeScript 编译器时也可以使用 `TSC_PATH=/absolute/path/to/typescript/bin/tsc npm test`，不必另外安装一份。Node.js 和 TypeScript 仅用于这些电脑端检查，不是应用运行依赖；DevEco 自带的构建工具独立于此测试配置。

测试先检查原生工程配置、相对导入和资源，再编译业务代码，最后执行离线测试。平台测试以模拟的华为接口执行适配层行为，**不代表 ArkTS 原生编译通过**。构建和测试输出保存在已忽略的 `.build/`。

2026-10-22：**55 项离线测试通过**，包括 24 项业务核心、24 项应用流程和 7 项模拟平台适配测试。安装 DevEco 后已通过原生类型检查、ArkTS 编译及未签名调试包构建；没有读取本机真实账号、访问学校服务、提交真实签到、启动容器或模拟器。

## 当前验证边界

- **原生编译和未签名调试包构建已通过，真实登录、真机安全存储及界面运行尚未验证**。构建目前只提示未配置本机签名；需要安装到真机时，在 DevEco 中配置自己的签名。
- 自动登录依赖学校网页现有的表单结构；学校网页或非公开接口变更后可能需要调整。验证码和额外认证保留原网页手动入口。
- 数字和雷达签到都已实现请求逻辑，但仅经过离线验证，没有学校端真实成功记录。扫码和其他签到形式暂不实现。
- 待确认日志只执行查询，不再次提交；应先登录日志所属账号。旧日志缺少签到日期时按原始签到 ID 查历史，不以今天或日志创建日期替代。

详细验证和后续操作见 [实施记录](project_docs/IMPLEMENTATION_PROGRESS.md)。第三方算法出处及许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 官方资料

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)
- [开发工具版本配套说明](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/deveco-studio-new-features-2600)
- [最低兼容系统与构建设置](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hmos-hvigor-build-profile-app)
- [Web 隐私模式](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/web-incognito-mode)
- [系统资产存储接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-asset)

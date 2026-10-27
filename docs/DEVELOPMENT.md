# Gather 开发与贡献指南

Gather 是 macOS 14+ 的 Swift/SwiftUI 原生桌面应用。业务能力位于
`desktop/native/gather-core`，界面与应用生命周期位于 `desktop/native/gather-app`；
仓库不依赖 Node.js、Electron、浏览器渲染层或本地 HTTP 服务。

本文档合并原 `TEST.md`（测试清单）与 `IPC_CONTRACT.md`（历史命令面契约基线）的精华；
测试与契约细节以本节为准，两份旧文档已删除。

## 环境要求

- macOS 14 或更高版本
- Xcode 或 Xcode Command Line Tools
- Swift 6.0 或更高版本（两个包均为 `swift-tools-version: 6.0` 且显式
  `.swiftLanguageMode(.v6)`；迁移记录见 `docs/reviews/functional-design-review.md`）
- Capture One 仅在需要验证原生插件/导入联动时才需要

**Swift 6 并发约定（新增代码必须遵守）**
- 类若含可变状态，须由具名锁保护；跨隔离域传递时标 `@unchecked Sendable` 并紧贴声明写明
  "被保护字段 + 锁字段"的理由注释（参考 `JobService`、`WalkChannel`、`DBConnection`）。
- 无任何可变状态（全 `let`）的类型可直接标 `Sendable` 或 `@unchecked Sendable`（注明"零可变"）。
- **禁止**在 `async` 上下文直接调用 `NSLock.lock()/unlock()`（Swift 6 报错）：把临界区抽进
  `private func xxxLocked(...)` 同步辅助方法，async 调用方只调它。
- **禁止**用 `@preconcurrency import`/`nonisolated(unsafe)` 掩盖诊断；全局可变状态一律改成
  "锁盒子 + 计算属性"（参考 `GatherLocalization.appLanguage`、`CaptureOneBridge.shared`）。
- 有界并发统一走 `batchAsync`（`Concurrent/BatchRunner.swift`），其 `body` 为 `@Sendable`，
  共享收集状态必须收进锁盒子（参考 `MetadataCollector`、`PhaseOneCollector`）。

真实人脸推理质量、代码签名/公证/安装升级和商业信号不属于代码验收范围。

## 目录结构

```text
desktop/native/
├── gather-core/                     # 5 个库 target（零第三方依赖，另有 GatherTestSupport 夹具）
│   ├── Sources/GatherProtocol/      # 值类型、16 个域 API 协议、GatherErrorCode、路径策略
│   ├── Sources/GatherPersistence/   # SchemaV1、Database、Repositories
│   ├── Sources/GatherDelivery/      # DeliveryCoordinator / 写回 / XMP 文件锁
│   ├── Sources/GatherAnalysis/      # Face/Image/Concurrent/Similarity 算法
│   ├── Sources/GatherApplication/   # Services 编排、JobService
│   ├── Tests/GatherTestSupport/     # 测试共享夹具（makeTestDB 等）
│   ├── Sources/GatherSchema/        # schema 导出可执行
│   ├── Sources/GatherCoreBenchmarks/ + GatherFaceBenchmarks/  # 基准
│   └── Tests/GatherCoreTests/       # core 测试（数量/套件数以 swift test 汇总行为准）
├── gather-app/                      # 3 个 target
│   ├── Sources/GatherUI/            # 页面/状态层/本地化资源（en/zh-Hans lproj）
│   ├── Sources/GatherHost/          # AppComposition、AppRuntime、Live*API、RootView、菜单/桥接
│   ├── Sources/GatherApp/           # @main 入口
│   └── Tests/GatherAppTests/        # app 测试（数量/套件数以 swift test 汇总行为准）
docs/                                # 当前文档；历史快照在 docs/archive/
```

## 本地开发

### 核心库测试

```bash
cd desktop/native/gather-core
swift test
```

### 应用测试

应用测试包含 SwiftUI 页面模型、域 API 实现、服务接线与组合根。macOS 上如遇
Clang 模块缓存权限问题，指定工作区可写的缓存目录：

```bash
cd desktop/native/gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --no-parallel
```

应用测试与其他 app 用例共享 MainActor 状态层与进程级语言/通知槽，默认并行在
调度满载时会拖穿异步等待窗口（历史 flake 集中在 ControlCenter/Gallery 的
生命周期断言）。因此 app 测试**始终加 `--no-parallel`**（CI 同口径）；core
本地默认并行，CI 用 `--no-parallel` 避免日志套件竞态。

### 构建应用（发布/打包）

完整 `.app` 组装只在发布/打包时执行；日常测试不跑本步骤。

```bash
./desktop/native/build.sh
```

产物为 `release/Gather.app`（`OUTPUT_DIR` 可覆盖；相对路径按仓库根解析，
脚本拒绝 `/`、`//`、结尾斜杠以及含 `.`/`..` 段的路径）。脚本会构建
gather-core、GatherApp，并在存在 Capture One SDK 时按 `GATHER_ARCHS` 的每个
切片构建 `GatherLink.coplugin`（缺切片时发布模式直接失败）。默认产物未签名、
架构跟随 SwiftPM 主机默认；`CODESIGN_IDENTITY` 存在时才签名（`--options
runtime --timestamp` + `desktop/native/Gather.entitlements`），签名后会用
`codesign -d --entitlements :-` 复核 entitlement 真的进入签名。WP6c 起版本注入、
universal 组装、公证与 staple 也由本脚本负责，契约见下节；`GATHER_RELEASE=1`
是发布硬门（版本、universal、Developer ID、公证凭据、Capture One 插件任一
缺失即 exit 1）。

#### 隔离数据目录（QA/实机验收）

默认数据目录是 `~/Library/Application Support/Gather`。实机验收建议使用独立目录，
避免旧库 fail-closed 或污染真实数据：

```bash
defaults write com.gather.desktop.native GatherApplicationSupportDirectory /tmp/gather-acceptance
open -n release/Gather.app
defaults delete com.gather.desktop.native GatherApplicationSupportDirectory
```

也可用 `--data-dir <path>` 参数或 `GATHER_APPLICATION_SUPPORT_DIR` 环境变量；
三者都只在显式设置时生效，生产默认路径不变。

### 可复现发布（universal / 签名 / 公证 / 版本注入）

同一组环境变量在本地与 CI release job 语义一致；本地不设 `GATHER_RELEASE` 时，
缺签名/公证凭据只警告并跳过，仍产出可运行的未签名 `.app`。

- **`GATHER_ARCHS`**：`universal` / `arm64` / `x86_64`；不设 = SwiftPM 主机
  默认（保持旧行为）。`universal` 用 `swift build --arch arm64 --arch x86_64`
  产出 fat Mach-O，组装后 `lipo -archs` 断言两个切片都在，缺一个即失败。
- **Capture One 插件架构**：`GatherLink.coplugin` 与 app 使用同一组切片；
  `universal` 时分别以 `arm64` / `x86_64` 编译，再用 `lipo -create` 合成，
  构建后用 `lipo -archs` 断言期望切片齐全。SDK 存在但缺切片时
  `GATHER_RELEASE=1` 直接 exit 1（本地非发布构建保留已构建切片并告警）。
  SDK 的 `CaptureOnePlugins.framework` 本身是 `x86_64 arm64`，插件源码不依赖
  宿主架构。插件部署目标与 app 对齐为 14.0（`build.sh` 用 make 命令行覆盖
  `TARGET`，不改 `Makefile`）；嵌入 app 的插件副本会注入与 app 相同的
  `CFBundleShortVersionString` / `CFBundleVersion`。`Makefile` 仍会为构建机生成
  相对 `LC_RPATH`；`build.sh` 只从嵌入 app 的副本删除这条相对路径（保留
  `@`/绝对路径），源目录与 `Makefile` 不动，仍需在 Capture One 实机加载验证。
- **`GATHER_VERSION`**：未设时回退到 `git describe --tags --abbrev=0`；两者都
  没有（如无 tag 的开发树）时保留 `Info.plist` 的 `3.0.0`，不凭空造版本。
  写入产物 `CFBundleShortVersionString`（去掉前导 `v`，并做格式校验）。
- **`GATHER_BUILD_NUMBER`**：未设时用 `git rev-list --count HEAD`，再否则由版本号
  派生数字串；写入 `CFBundleVersion`（只允许数字与点，脚本会校验；公证不要求
  单调递增，但 tag/提交数天然单调）。没有解析出版本时单独设置它会被警告并
  忽略——设 `GATHER_VERSION` 或打 tag 才会生效。
- **`CODESIGN_IDENTITY`**：Developer ID Application 身份。先签嵌套项（PlugIns /
  Frameworks / 资源 bundle），再签主 bundle（`--entitlements`），签后执行
  `codesign --verify --deep --strict` 与 entitlement 复核；`--timestamp` 是
  notarytool 的硬要求（ad-hoc 身份 `-` 除外）。
- **`GATHER_NOTARIZE=1`**：`ditto` 打包 `release/Gather.zip` →
  `xcrun notarytool submit --wait` → `xcrun stapler staple/validate` →
  `spctl -a -t exec`。凭据取 `GATHER_NOTARY_PROFILE`（keychain profile），或
  `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_PASSWORD`；两者都没有时本地明确
  skip 并 exit 0，`GATHER_RELEASE=1` 时 exit 1。
- **`GATHER_RELEASE=1`**：发布门。版本、`GATHER_ARCHS=universal`、Developer ID
  签名身份、公证凭据、Capture One 插件任一缺失即失败；CI release job 固定设 1，
  不允许产出未签名/未公证/单架构/无插件的“发布包”。本机在 SDK <26 时只告警并
  把实际 sdk 写入 `build-info.json`；CI release 在构建前硬失败（见下）。

本机完整发布（有 Developer ID 与公证凭据时）：

```bash
GATHER_RELEASE=1 \
GATHER_ARCHS=universal \
GATHER_VERSION=3.1.0 \
CODESIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)" \
GATHER_NOTARIZE=1 \
GATHER_NOTARY_PROFILE=gather-notary \
./desktop/native/build.sh
```

没有 keychain profile 时把 `GATHER_NOTARY_PROFILE` 换成
`APPLE_ID=<apple-id> APPLE_TEAM_ID=<team-id> APPLE_APP_PASSWORD=<app-specific-password>`。

只验证 universal 与版本注入（不签名/不公证）：

```bash
GATHER_ARCHS=universal GATHER_VERSION=0.0.0-dev ./desktop/native/build.sh
lipo -archs release/Gather.app/Contents/MacOS/Gather        # 期望 x86_64 arm64
lipo -archs release/Gather.app/Contents/PlugIns/GatherLink.coplugin/Contents/MacOS/GatherLink
                                                            # 有 SDK 时期望 x86_64 arm64
plutil -extract CFBundleShortVersionString raw -o - \
  release/Gather.app/Contents/Info.plist                     # 期望 0.0.0-dev
plutil -extract CFBundleVersion raw -o - \
  release/Gather.app/Contents/Info.plist                     # 期望 git 提交数
# Mach-O 实际值（期望 minos 14.0，sdk 为构建时 SDK）
vtool -arch arm64 -show-build release/Gather.app/Contents/MacOS/Gather | grep -E 'minos|sdk'
vtool -arch x86_64 -show-build release/Gather.app/Contents/MacOS/Gather | grep -E 'minos|sdk'
# 有 SDK 时，插件版本应已被注入为与 app 相同
plutil -extract CFBundleShortVersionString raw -o - \
  release/Gather.app/Contents/PlugIns/GatherLink.coplugin/Contents/Info.plist
```

发布前检查（缺一不发布）与产物校验：

```bash
codesign -dv --verbose=4 release/Gather.app 2>&1 | grep -E 'Timestamp|Runtime Version'
codesign -d --entitlements :- release/Gather.app   # 含 com.apple.security.automation.apple-events
xcrun stapler validate release/Gather.app
spctl -a -t exec -vvv release/Gather.app
plutil -convert xml1 -o /dev/null release/Gather.app/Contents/Resources/build-info.json
( cd release && shasum -a 256 Gather.zip > Gather.zip.sha256 )
# build.sh 在 staple 之后重打 zip；解压分发包再验一次，确认 ticket 随包分发
rm -rf /tmp/gather-zip-check && ditto -x -k release/Gather.zip /tmp/gather-zip-check
xcrun stapler validate /tmp/gather-zip-check/Gather.app
```

产物内的 `Contents/Resources/build-info.json` 记录 version / build / commit /
dirty / archs / plugin / minos / sdk_version / sdk_version_declared（固定键序、
不含时间戳，同样的输入产出同样的内容）。`dirty` 是 git 工作区状态
（true/false，读取失败时 unknown）；`plugin` 是嵌入插件的 `lipo -archs`
切片或 `none`；`sdk_version` 取 Mach-O `LC_BUILD_VERSION.sdk` 实际值，
`sdk_version_declared` 是 `GATHER_SDK_VERSION`/探测结果/默认值，用于区分
“声明了但未链进产物”的情况。发布版本以 `Info.plist` 与 tag 为准。

CI：`.github/workflows/ci.yml` 的 `release` job 只在 `v*` tag 或手动
`workflow_dispatch`（`version` 输入为必填）时运行，`needs: [gates, gather-app]`，
先跑全部门禁与测试。它显式注入 `GATHER_SDK_VERSION`、`GATHER_VERSION`（tag 名或
输入）、`GATHER_ARCHS=universal`、`GATHER_NOTARIZE=1`、`GATHER_RELEASE=1`。
签名/公证 secrets 只在 Import Developer ID certificate 与 Build 两个 step 注入
（不上传到 artifact 上传 step）：`CODESIGN_IDENTITY`、`MACOS_CERT_P12`、
`MACOS_CERT_PASSWORD`、`KEYCHAIN_PASSWORD`，公证用 `GATHER_NOTARY_PROFILE`
（仅 self-hosted runner，需预先 `store-credentials`）或 `NOTARY_APPLE_ID` /
`NOTARY_TEAM_ID` / `NOTARY_APP_PASSWORD`；hosted runner 请留空 profile、使用
三件套。secret 缺失时 job 直接失败，不会上传未签名包；成功时上传
`release/Gather.zip` 与 `.sha256`。

release job 在构建前执行 `Assert release SDK`：要求 macOS 26 SDK（Liquid Glass
所需的 `LC_BUILD_VERSION.sdk >= 26`）。当前 `runs-on: macos-14` 的镜像无法提供
Xcode 26，因此 tag release 会 fail closed；正式发版必须把该 job 移到
`macos-26` 或装有 Xcode 26 的 self-hosted runner。构建后还会用 `vtool` 断言
每个切片的 `minos=14.0` 且 `sdk` 与注入值一致，并校验 `build-info.json`、
app 双切片、插件双切片/版本/minos；授权 SDK 不在仓库内，runner 未安装 SDK 时
`build.sh` 在 `GATHER_RELEASE=1` 下直接 exit 1，不会静默产出无 C1 插件的包。

没有签名/公证环境时，可把假的 `swift` / `lipo` / `codesign` / `xcrun` 放到
`PATH` 前面做 dry-run：断言 `--arch` 组合、`lipo` 断言、codesign 参数顺序、
版本注入结果与“缺凭据时 skip/失败”分支，不触碰真实证书。真实签名、公证与
Gatekeeper 验收只能在有 Developer ID 的机器或 tag 触发的 release job 上完成。

**universal 的 float16 读回**：`GatherAnalysis/Face/EmbeddingModel.swift` 的连续
`.float16` 快路径包在 `#if arch(arm64)` 内（`Float16` 指针 + `Float($0)`）；
x86_64 macOS 没有 `Float16`（`@available(macOS, unavailable)`），落到同一函数
末尾的逐元素 `Float(truncating:)`，数值一致、只多一次装箱。因此
`GATHER_ARCHS=universal` 在两个切片上都能编译；脚本仍以 `lipo -archs` 的实际
切片为准，不静默降级。

打包门在组装前/后断言以下资产与签名输入，失败即停止并打印缺失的精确路径：

- **人脸模型**：`FaceModels/SFace.mlpackage` 必须是目录且含 CoreML 的
  `Manifest.json`；同目录的 `manifest.json`（`model` 必须为 `SFace`）、
  `native_ramp_reference.json`、`LICENSE.txt` 必须存在且非空。运行期经
  `Bundle.module` 读取内置 SFace（`GatherAnalysis/Face/EmbeddingModel.swift`），
  模型改名/换包会产生 `modelNotFound`，因此不再接受“任意 .mlpackage”。
- **本地化**：源码 `GatherUI/Resources/{en,zh-Hans}.lproj/Localizable.strings`、
  两个 SPM 资源 bundle 内的同名文件、以及主 bundle 的副本都必须存在且非空；
  只有空 `.lproj` 目录不算通过。

`desktop/native/Gather.entitlements` 只声明
`com.apple.security.automation.apple-events`（Capture One 桥接用 AppleScript 发送
Apple Events；hardened runtime 分发包缺少它会被 TCC 拒绝，-1743）。**不开启
App Sandbox**：当前签名与运行模型没有沙盒容器，授权路径访问、SPM 资源 bundle
和 Capture One 插件都按非沙盒语义工作；沙盒化需要单独的容器迁移与
`files.*` entitlement，不能随发布门一并打开。

## 架构约定

```text
SwiftUI（GatherUI：页面 / ViewModel / LanguageStore）
  ↓ AppServices（16 个域 API / 124 个类型化方法，同进程直连）
GatherHost（AppComposition 组合根、AppRuntime、Live*API）
  ↓
GatherApplication 服务（交付编排在 GatherDelivery）
  ├── GatherPersistence：SQLite WAL + SchemaCurrent（44 表 / 384 列 / user_version=4）
  ├── GatherAnalysis：图片读取、Vision 人脸、RAW/ImageIO 解码
  ├── JobService（可恢复任务，executor + checkpoint + dedupeKey）
  └── DeliveryCoordinator：deliveries 写回（重试 / 冲突 / 重启恢复）
```

### 页面与路由

- `RootView`（`Sources/GatherHost/RootView.swift`，148 行）只保留依赖、`@State`
  与 modifier 接线；导航/侧栏/工具栏/详情/通知由 `RootShell*.swift` 拆分承载。
  页面按目的地**条件构建**（不再用 `.opacity(0)` 常驻），`NavigationSplitView`
  负责侧栏材质与选中语义。
- 会话页由 `GatherUI/Shell/SessionPageHost.swift` 按 `SessionPage` 分发 workspace 里的
  ViewModel；session 切换用 `.id("session-page-\(sessionId)-\(page.rawValue)")` 保留身份
  （不是语言重建开关）。
- 工作区状态由 `SessionStore`/`SessionWorkspace` 持有（每会话一套 + LRU），
  入口意图经 `WorkspaceIntent` 取用即清；页面经 `AppServices` 的域协议访问
  核心服务，保持 session 范围隔离。
- Jobs、Settings、Face Keywording、Duplicates、Culling、Export 和 Control Center
  均由 SwiftUI 原生页面承载。

### 数据与任务

- SQLite 使用 WAL；唯一建库入口是 `Database.open(at:)`：新库按
  `SchemaCurrent.createSQL` 单事务建库并写 `PRAGMA user_version = 4`
  （44 表 / 384 列 / 72 索引 / 65 外键）。只有空库与当前版本可直接使用；
  旧版本（V1/V2 迁移链已删除）、版本更高、版本 0 有表、形态不符、非 SQLite 文件
  默认 fail closed；开发重置策略才把 db/-wal/-shm 改名为 `<db>.incompatible-<ts>`
  后重建（ADR-005/006）。
- 导入创建 session、写入照片资产后，立即提交 `metadata.scan` 任务；任务中心负责
  进度、失败显示、重试和取消。
- 元数据写回经 `DeliveryCoordinator` + `deliveries/delivery_sessions/delivery_items/
  delivery_intents`，支持失败重试、冲突处理和重启后恢复。
- 文件操作必须使用数据库中已授权的资产路径；删除、移动和覆盖类操作需要显式确认。
- 重复资产按逻辑资产处理，避免 RAW/JPEG 配对造成重复分析或重复写回。

### 原生边界

- 应用不包含 WKWebView、JavaScriptCore、React、TypeScript IPC 或 Electron 主进程。
- 类型化 API 只接受明确输入；非法/未知输入返回可诊断错误，不应静默成功。
- UI 不直接持有数据库连接或执行任意文件路径操作，服务层负责授权和事务边界。

## 本地化体系

界面文案统一经 `Support/L10n.swift` 的值类型 + `Support/GatherLocalization.swift`
的错误码表，禁止硬编码裸码直显。

### 入口与回退语义

- `L10n`（`Support/L10n.swift:120`）：**key 即中文文案**；渲染期显式携带
  `language`（`L10n.Language.zhCN/en`），经 `Bundle.module` 的 `.lproj` 查表——
  `zh-Hans.lproj` 只有 9 个占位键，未命中自动回退 key（即中文）；`en.lproj`
  （1,494 键）提供英文翻译，未翻译的 key 仍回退中文。`L10nStringCache` 按
  (language, key) 缓存查表结果，避免每帧重走 Bundle 查找。
- 页面经 `LanguageStore`（`@MainActor @Observable`）取得 `languageStore.l10n`；
  切语言只更新 store 并触发 Observation 重渲染，不再用 `.id(languageVersion)`
  重建整棵页面树。
- 错误码翻译：`L10n.errorText(_:)` 覆盖 **184 项** `GatherErrorCode`（P0 后含 Triage/Keyword/Face/Maintenance；B03 起旧
  `GatherLocalization` 翻译出口已删，`errorMessages` 码表仍由它持有）
  （`errorMessages` 表与枚举逐项对齐，缺失即测试红）；未知码回退通用文案。
- 任务侧映射：`jobStatusText` / `jobTypeText` / `progressPhaseText` 分别覆盖
  `jobs.status.*` / `jobs.type.*` / `progress.*` 相位键。
- 通用出口：`APIErrorPresentation.message(for:with:)` 统一翻译 `APIError` / `NSError`
  等错误对象（`RouterCommandError` 仅作为旧错误载体保留，不是命令面）；
  `L10n.jobErrorMessage` 只翻译错误码，非错误码回退通用文案（原始细节留给 tooltip）。
- 语言持久化：设置页经 `SettingsAPI` 写 `settings.ui_language`（唯一真相源）；
  `LanguageStore.set` 更新内存并广播 `languageChanged`。Phase 4 收口后菜单单轨
  （只有 SwiftUI `.commands`），**标准菜单项语言跟随系统语言**，应用内切换只
  重渲染窗口内容——不再有 `GatherAppDelegate` 重建菜单；`languageChanged` 的
  生产消费方是 `LanguageStore`（跟随外部写入）与 `DashboardView`（日期格式化）。

### 新增文案规范

1. 页面文案调用 `l10n("中文文案")`（或 `l10n.format(...)`），需要英文时同步补
   `en.lproj/Localizable.strings`（key 为同一中文串）；**禁止新增**
   `GatherLocalization.l(` 调用（Cut 4 已把 1,481 处 codemod 到 0）。
2. 错误先以 `GatherErrorCode` 从服务层抛出，UI 经 `errorText` / `message(for:)` /
   `L10n` 映射，不直接展示 rawValue。
3. 参数插值走 `l10n.format(key, args)` / `String(format:)`，占位符语义与 en 表一致。
4. 界面语言选项名（中文 / English）为固定品牌名，两语言文件同值，不本地化。
5. 孤儿键：`LocalizationParityTests` 断言 en 表无代码未引用键（仅 allowlist
   `检测模型路径` 由测试构造）；删键前必须逐个人工 A/B，防止运行时空白文案。

## HIG 规范约定

### 语义字体

- 页面层级使用系统语义字号：`.largeTitle`（页头）、`.title3.weight(.semibold)`
  （区块标题）、`.headline` / `.callout` / `.caption`（正文与辅助信息），
  不散落字号字面量；数值展示用 `tabular-nums` 保持对齐。

### 按钮层级

- 侧栏/工具栏导航按钮：`.buttonStyle(.plain)` + 自定义 hover/选中态
  （见 `RootView.swift` 的 `SidebarView`），选中项加 `.accessibilityAddTraits(.isSelected)`。
- 主操作：系统 `Button` 经根视图 `.tint(GatherTheme.primary)` 统一着色，保持
  控件原生形态。
- 破坏性操作：`role: .destructive` + `confirmationDialog` 双确认（如重置挑片、
  清理备份）；高频确认（写回/组决策/完成同步）由 API 层的 `Confirmed<T>` 标记
  承担，不再弹窗（对齐旧版零弹窗语义）。
- 弹层统一使用系统 sheet/confirmationDialog，不复刻自绘 Dialog（Electron 时代
  的 APG 焦点管理 ADR-018 由系统组件天然覆盖）。

### 无障碍

- 常驻隐藏页 `.accessibilityHidden(!isVisible)`，避免隐藏控件被 Tab/VoiceOver
  触达（RootView 五个常驻页均有）。
- 图标按钮与语义化控件补 `.accessibilityLabel`；动画跟随
  `@Environment(\.accessibilityReduceMotion)` 降级（`.transition`/`.animation`
  判断 reduceMotion）。

### 主题令牌

- 颜色/圆角/间距统一取 `Support/GatherTheme.swift`（primary `#A54D2A`、背景
  `#F5F0EB`、语义色、`Radius`/`Spacing` 阶梯，含明暗动态适配），禁止内联色值
  字面量；卡片统一用 `gatherCard()` 修饰符。

## 测试与验收

### 自动化门禁

提交前在仓库根目录至少运行：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-core

# app 测试串行：与 CI 同口径（共享 MainActor/进程级状态，并行会拖穿等待窗口）。
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --package-path desktop/native/gather-app --no-parallel
```

**不要在日常提交里跑 `./desktop/native/build.sh`**：完整 `.app` 组装只在发布/打包
（tag、`workflow_dispatch` 或明确的打包任务）执行；PR/日常测试只构建 test target。
CI 的 `gather-app` job 单独 `swift build` 一次可执行（菜单/场景装配的编译回归），
仍不附带 bundle build；`.app` 组装由 nightly 与 release job 覆盖。

默认套件按三层组织：

| 层 | 何时跑 | 内容 |
|---|---|---|
| Unit/Correctness | 每次 PR | 行为、边界、错误码、成员集合、不变量 |
| Integration | 夜间（`GATHER_MODEL_TESTS=1`）；真实照片用例仅手动（`GATHER_FACE_FIXTURE`，nightly 不设） | CoreML/Vision/真实照片/ImageIO |
| Quality/Benchmark | 夜间/发版 | F1/ARI/P/R、margin 边界、LSH 召回、增量复用与性能基线（`gather-core-benchmarks --quality/--margin/--smoke/--incremental`）；**benchmark 内置阈值，超限即 exit 1**，nightly 直接吃退出码 |

夜间命令示例：

```bash
swift build -c release --package-path desktop/native/gather-core
desktop/native/gather-core/.build/release/gather-core-benchmarks --quality
desktop/native/gather-core/.build/release/gather-core-benchmarks --margin
desktop/native/gather-core/.build/release/gather-core-benchmarks --smoke
desktop/native/gather-core/.build/release/gather-core-benchmarks --incremental
./desktop/native/build.sh            # 未签名 bundle 组装（PR 不跑，夜间补）
GATHER_MODEL_TESTS=1 swift test --package-path desktop/native/gather-core \
  --no-parallel --filter 'FaceIdentityArchitectureTests|FaceEmbeddingModelTests|FaceInferenceTests'
GATHER_TEST_MATRIX_STEPS=200 swift test --package-path desktop/native/gather-core \
  --no-parallel --filter 'ClusterGraphIncrementalAssemblyTests|IncrementalClustererReconciliationTests'
```

验收记录至少包含：gather-core 测试总数/套件数/失败数、gather-app 同名指标、
fixture-dependent skip 与未执行的外部验收项；`.app` 组装仅在发布/打包验收时记录。
（台账中的 1,092/157、581/66 是重构收口时的历史值；当前以 `swift test` 汇总为准。）

**skip 不计入“通过”的有效执行数**：`swift test` 的 `N tests passed` 包含被
`.enabled(if:)` / `.disabled` 跳过的用例。报告口径写成“声明 N / skip S / 有效执行
N−S”；当前 skip 共 **17** 条（`check-test-catalog.sh` 实测）：
`FaceRealPhotoPipelineTests` 3 条（无 `GATHER_FACE_FIXTURE`）、模型集成 8 条
（无 `GATHER_MODEL_TESTS=1`）与 P0 性能门 6 条（`GATHER_CULLING_PERF` /
`GATHER_BACKUP_PERF` / `GATHER_UI_PERF`；夜间 CI 已置位三类 env），必须单列，
不能算作通过。skip 元数据与门禁见 `check-test-catalog.sh --strict`
（识别 `.enabled(if:)`、`@Test`/`@Suite` 的 `.disabled`、`withKnownIssue`；要求
`skip-owner` + 到期 + 原因）。

验收时要区分：

- 测试/编译成功：证明代码链路可构建和可执行；
- 真实照片、人脸推理质量、签名公证安装和商业材料性能：明确排除，不能用自动化
  绿灯替代这些外部证据；
- 如果测试输出含 fixture-dependent skip（`FaceRealPhotoPipelineTests` 3 条 +
  模型集成 8 条），应单独记录 skip 数，不得标成失败，也不得计入“有效执行/通过”。
  两类 skip 均带 `skip-owner`、到期与手动 CI 条件；`check-test-catalog.sh --strict`
  缺任一元数据即红。

### 手工检查清单（按变更面选择）

- **启动与导航**：`.app` 可启动、页面互导航、session 不串数据、`Cmd+Q` 遵循
  生命周期、启动不依赖本地 HTTP。
- **工作区与图库**：建会话即自动 `metadata.scan`；含中文/空格/特殊字符路径可
  建资产；分页、缩略图、星级色标；撤销/重做后 UI 与持久化一致；空态明确。
- **相似度/重复/挑片**：分析可启动/取消；阈值与组大小修改后状态一致；破坏性
  重复处理有确认且失败有原因；挑片写回触发元数据同步；重复提交分析不产生
  不可控任务。
- **人脸关键词**：只验收链路与写回安全，不评价真实推理质量；分析/簇/审核状态
  可见；写回失败可诊断可重试；重启后 deliveries 可恢复；无脸/损坏图有明确状态。
- **导出/任务/元数据**：进度可见、支持取消/重试；失败不静默；导出目标不覆盖
  未授权源资产；重启后可恢复可恢复任务；XMP deliveries 重试/冲突/清理。
- **错误与安全**：非法输入返回结构化错误；缺记录不崩溃；写回/删除/覆盖均有
  确认边界；资产路径来自授权记录；不兼容库整体重置为 `.incompatible-<ts>`
  （含 -wal/-shm），不就地迁移、不留下半迁移状态。
- **签名分发包**（发布环境）：`codesign -d --entitlements :- release/Gather.app`
  能看到 `com.apple.security.automation.apple-events`；首次从签名包触发 Capture One
  导入会弹出系统“自动化”授权，未签名本机构建不能替代这一步 TCC 验收。

### 原生边界与清理门禁

Cut 1 后字符串命令面已删除；当前机器判据（CI 的 boundary job 亦直接执行）：

```bash
./scripts/check-no-legacy.sh             # 7 条 enforced + 6 项 tracked：无 Legacy/Compat/Adapter、
                                         # 无 WebKit/JS、无 Electron、app 层无 JSONSerialization；
                                         # R5 对 Router 三类旧文件做 0 文件断言
./scripts/check-cleanup-ratchet.sh       # 5 个清理指标不得超过 docs/cleanup-baseline.json
./scripts/check-docs.sh --strict         # ADR 路径、当前文档（非 archive）md 链接、docs/archive、当前 schema 版本
./scripts/check-layering.sh              # 19 条依赖方向（UI 不 import Persistence/Domain/Analysis/Delivery/Host）
./scripts/check-protocol-surface.sh --strict  # Protocol public 类型/声明/零引用/Router 信封 ratchet
./scripts/check-duplicate-symbols.sh --strict
./scripts/check-test-catalog.sh --strict # 测试文件头注释 / skip 元数据（.enabled、@Suite(.disabled)、owner/到期/原因）
./scripts/check-test-catalog.sh --self-test # 负例：缺元数据应 exit 1，补齐后 exit 0（非独立门禁）
./scripts/check-select-star.sh           # Sources 4 处 / Tests 白名单 1 处
./scripts/check-preview-surface.sh --strict  # 18 个 #Preview / 13 个文件
./scripts/check-coded-errors.sh          # 错误码类型化：Persistence 无裸码字符串；Host 反解须标 allow: string-code
./scripts/check-backlog-evidence.sh      # cleanup-backlog 的 pending/deferred 段必须有证据标记
```

门禁与扫描一律以当前工作树为准；未暂存的删除仍会被 `git ls-files` 列出，不能据此
判断文件仍然存在。

**backlog 状态规则**（R2）：`docs/cleanup-backlog.md` 里每个 `status: pending|deferred` 的
CL 段必须写可复核的证据（`证据` / `未完成原因` / `实测` / `最终复核` / `验收偏差` 之一），
否则 `check-backlog-evidence.sh` 失败；状态改 `done` 时同时写证据与验收口径。

## 类型化 API 契约（Cut 1 收口）

Cut 1 已用 **16 个域协议 / 124 个方法**替代 118 条字符串命令：
Session、Culling、Export、Job、Duplicate、Face、Similarity、Photo、Album、Person、
Metadata、Settings、Navigation、Asset、Quality、Maintenance（`GatherProtocol/API/*API.swift`；
Template 域已于 2026-10-24 按 ADR-031 删除）。
UI 经 `AppServices` 注入 `any XxxAPI`；`AppComposition` 构造唯一服务实例，
`AppRuntime` 管理任务生命周期。旧 Router 的 118 条命令与
`check-command-surface.sh` 已删除；逐条映射保留在
[api-migration-map.md](archive/cuts/api-migration-map.md)（历史快照）。

### API 输入与确认

- **破坏性操作**只接收 `Confirmed<T>`：类型层面禁止裸 Bool；UI 必须在真实确认
  弹窗分支构造，API 实现不再解析 `confirmed`。
- 输入类型在 `init`/`decode` 完成非空、长度、枚举、范围与数量上限校验；非法输入
  抛 `GatherError.invalidParameter`（字段名进 params），不再有 `MISSING_PARAM:*`。
- 路径授权由 `PhotoPathPolicy.requireKnown/filterKnown` 承担；未授权路径抛
  `PHOTO_NOT_FOUND`，不得退化为任意文件读取。
- 未知/非法输入必须显式失败，不静默降级；错误码映射仍以
  `L10n.errorText` 与 `APIErrorPresentation` 为唯一漏斗。

### 历史命令分组 → 域 API 对照

> 下表只用于理解旧行为去向；字符串命令已不存在，新增代码不得按命令名派发。

| 组 | 旧命令（历史） | 取消/状态（现语义） |
|---|---|---|
| Session/photo | `session.*`、`photo.list_page` | session 状态持久化；导入错误按文件返回 |
| Culling | `culling.*`（分页 `culling.list_page`） | 逐 session 同步状态；写回失败可重试 |
| Similarity | `sim.analyze`、`sim.recluster`、`sim.result`、写回族 | analyze/recluster 均走 JobService executor（ADR-024） |
| Face/person | `fkw.*`、`person.*` | 分析取消；person 破坏性变更需确认 |
| Metadata | `metadata.*` | 变更与恢复需确认；未知 XMP 字段保留 |
| Assets/index | `assets.*`、`index.scan` | 重连需确认；扫描为持久任务，缺失文件保留 |
| Jobs | `jobs.list/cancel/retry/clear_completed` | 状态/租约/进度/重试持久化 |
| Quality/navigation | `quality.*`、`navigation.*` | AI 输出仅建议；组拆分/合并是导航覆盖 |
| Duplicate/filter/album | `dup.*`、`filter.*`、`album.*` | 重复处理破坏性；全局查询库内分页 |
| Export/template | `export.*`、`template.*` | 导出可取消；执行/应用/删除需确认 |
| Image/settings | `image.*`、`settings.*` | 尽力而为，不得使 API 崩溃 |

### 兼容性规则

1. 不重命名 API/事件/枚举而不迁移契约测试（`Tests/GatherAppTests/API*Tests.swift`、
   `Tests/GatherCoreTests/Protocol/*ContractTests`）。
2. 追加参数必须对既有调用方向后兼容。
3. 长任务必须持久化足够状态，使 UI 能区分 running/failed/cancelled/completed
   （JobService lease/checkpoint/dedupeKey 语义）。
4. AI 输出仅建议，未经用户显式操作不得改动 Pick/Reject/Rating/Label。
5. 元数据变更按 patch 而非整文档处理；写入方负责路径解析、基线比较、合并、
   备份与恢复。

### 分页契约（`CullingAPI.page`）

- 页按**逻辑资产**分组（`COALESCE(asset_id, id)`）：RAW+JPEG 变体永不跨页，每
  资产跨页恰好出现一次。
- `afterRowId`/`nextRowId` 是**不透明 keyset 游标**，UI 原样回传、不得解析。
- `total` 按逻辑资产计数；过滤谓词下推到**首选变体**（RAW 扩展名优先）。

### 事件通道

- 推送走 `GatherEventCenter.shared.wire(jobService:)`（`Support/GatherEventCenter.swift`）：
  `jobs:progress` 逐帧（终态帧驱动整页刷新）、`culling:sync-status`（C1 队列
  状态转换）、`gather:notification`（错误码，UI 经 `errorText` 映射）、
  `languageChanged`（LanguageStore/Dashboard 订阅）、`importCompleted`。
- 轮询兜底：Dashboard 活跃 2s/空闲 30s，控制中心 3s/15s，C1 胶囊 12s；事件与
  轮询双通道语义保留，事件丢失不致静默。

### 后台任务

- `metadata.scan`（session 范围，去重键 `metadata.scan:<sessionId>`）、
  `checksum.backfill`（`checksum.backfill:<sessionId>`）、`sim.analyze`、
  `face.analyze`、`duplicate.scan`、`quality.score`、`export.execute`、
  `thumbnail.build` 均由 JobService executor 承载；重聚类（recluster）亦已任务化
  （ADR-024）。

### 相似度结果档位

- `similarity_results` 可存多档结果（主档 + 预计算邻居阈值 T±4/T±8，
  `"precomputed": true`）；"最新结果"判定（`getLatest`、culling 相似组 SQL、
  质量相对排名）必须排除 precomputed 行（不变量由 `reuse-and-tiers` 测试强制）。

### 增量聚类与簇版本

状态表、启用条件、不变量与复杂度分析的唯一真相源是 [ADR.md](ADR.md) 的
ADR-027（增量聚类：状态持久化 + 引擎语义复刻 + 定期全局收敛）；对账矩阵见
`Tests/GatherCoreTests/Similarity/IncrementalClustererTests.swift`。

## 提交与 Pull Request

提交信息建议遵循 Conventional Commits，例如：

```text
refactor(native): 完成原生任务中心路由
```

Pull Request 应说明：

1. 变更涉及的页面、服务或数据边界；
2. 已运行的测试命令及结果（发布/打包变更再列 `build.sh` 与产物）；
3. 未验证或明确排除的外部条件；
4. 是否涉及数据迁移、写回、删除或恢复行为。

不要把构建产物、个人照片、模型文件或本地数据库提交到仓库。

例外：`desktop/native/gather-core/Sources/GatherAnalysis/FaceModels/SFace.mlpackage`
（`weight.bin` 约 38.5MB，Apache-2.0）是内置人脸模型的构建必需资产，已明确入库；
替换/新增模型需在 PR 说明来源、许可与体积，并优先评估 LFS。

## 常见问题

### 构建失败并提示 Clang module cache

将 `CLANG_MODULE_CACHE_PATH` 指向 `/private/tmp` 下可写目录后重试：

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test \
  --package-path desktop/native/gather-core
```

### 为什么没有 npm 命令？

Node/Electron 运行时和 TypeScript 前端已随原生迁移移除。开发、测试和打包入口
统一为 Swift Package 与 `desktop/native/build.sh`。

### 为什么生成的 `.app` 未签名？

这是源码构建的默认边界：未设置 `CODESIGN_IDENTITY` 时 `build.sh` 只校验
`desktop/native/Gather.entitlements` 存在、plist 合法且含 Apple Events 键，不执行
签名。需要发布签名时由发布环境提供 `CODESIGN_IDENTITY`，脚本会带 hardened
runtime 与该 entitlements 签名并复核；签名、公证和安装验证属独立发布活动，
不属于代码验收。

## 相关文档

- [项目总览](README.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
- [历史文档归档](archive/README.md)

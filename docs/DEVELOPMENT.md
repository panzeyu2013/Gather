# Gather 开发与贡献指南

Gather 是 macOS 26+ 的 Swift/SwiftUI 原生桌面应用。业务能力位于
`desktop/native/gather-core`，界面与应用生命周期位于 `desktop/native/gather-app`；
仓库不依赖 Node.js、Electron、浏览器渲染层或本地 HTTP 服务。

本文合并原 `TEST.md` 与 `IPC_CONTRACT.md` 的精华，测试与契约细节以本文为准；
迁移记录见 git 历史与 [ADR.md](ADR.md)。

## 环境要求

- macOS 26+、Xcode 26+（macOS 26 SDK）、Swift 6.2+；两个包均为
  `swift-tools-version: 6.2` 且显式 `.swiftLanguageMode(.v6)`。
- Capture One 仅在验证插件/导入联动时需要。
- 真实人脸推理质量、代码签名/公证/安装升级和商业性能不属于代码验收范围。

### Swift 6 并发约定（新增代码）

- 含可变状态的类由具名锁保护；跨隔离域传递标 `@unchecked Sendable`，紧贴声明写明
  「被保护字段 + 锁字段」理由（参考 `JobService`、`WalkChannel`、`DBConnection`）。
- 全 `let` 类型可直接 `Sendable` / `@unchecked Sendable`（注明「零可变」）。
- 禁止在 `async` 上下文直接 `NSLock.lock()/unlock()`：把临界区抽进
  `private func xxxLocked(...)` 同步辅助方法。
- 禁止用 `@preconcurrency import` / `nonisolated(unsafe)` 掩盖诊断；全局可变状态改为
  「锁盒子 + 计算属性」（参考 `GatherLocalization.appLanguage`、`CaptureOneBridge.shared`）。
- 有界并发统一走 `batchAsync`（`GatherPersistence/Support/BatchRunner.swift`），共享收集状态收进锁盒子
  （参考 `MetadataCollector`、`PhaseOneCollector`）。

## 目录结构

```text
desktop/native/
├── gather-core/                     # 5 个库 target + GatherTestSupport 夹具
│   ├── Sources/GatherProtocol/      # 值类型、16 个域 API 协议、GatherErrorCode、路径策略
│   ├── Sources/GatherPersistence/   # SchemaCurrent、Database、Repositories
│   ├── Sources/GatherDelivery/      # DeliveryCoordinator、写回、XMP 文件锁
│   ├── Sources/GatherAnalysis/      # Face/Image/Concurrent/Similarity
│   ├── Sources/GatherApplication/   # Services 编排、JobService
│   ├── Sources/GatherSchema/        # schema 导出可执行
│   ├── Sources/GatherCoreBenchmarks/ + GatherFaceBenchmarks/
│   ├── Tests/GatherTestSupport/     # makeTestDB 等共享夹具
│   └── Tests/GatherCoreTests/
├── gather-app/                      # 3 个 target
│   ├── Sources/GatherUI/            # 页面/状态层/本地化资源（en/zh-Hans lproj）
│   ├── Sources/GatherHost/          # AppComposition、AppRuntime、Live*API、RootView、菜单
│   ├── Sources/GatherApp/           # @main
│   └── Tests/GatherAppTests/
docs/                                # 当前文档（历史快照已清理，见 git 历史）
```

## 本地开发

### 测试

```bash
# 本地入口：core 并行主批 + 进程级状态套件串行批；app 并行
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh core
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh app
./scripts/test.sh all
```

- `scripts/test.sh` 只做编排：core 中 `LoggerTests` / `TraceLoggingTests` /
  `LogFileSinkTests` / `ReadPoolTests` 改动进程级日志或慢事务阈值，脚本自动扫描后放进
  第二遍串行跑（`--skip-build`）；其余并行，app 也并行。
- 单例或共享状态排障直接 `swift test --no-parallel`。
- CI 只跑串行（`swift test --no-parallel` + 日志落盘 + 20 分钟看门狗）：macOS runner
  只有 3–4 vCPU，进程内并行 + 阻塞型锁会耗尽协作线程池，2026-10-29 复盘见
  [test-runtime-audit.md](test-runtime-audit.md) §9。
- 默认套件只验证正确性；CoreML/Vision/真实照片与质量基线是手动 opt-in：
  `GATHER_MODEL_TESTS=1`、`GATHER_FACE_FIXTURE`、`GATHER_TEST_MATRIX_STEPS=200`；
  benchmark 用 `gather-core-benchmarks --quality/--margin/--smoke/--incremental`
  （内置阈值，退出码即结论）。
- `swift test` 的 `N tests passed` 包含 skip；报告口径写成「声明 N / skip S / 有效执行
  N−S」。skip 元数据（owner/到期/原因）由 `check-test-catalog.sh --strict` 校验。
- 测试期间不出现可见窗口或系统面板：真实挂载用例的宿主 NSWindow 置 `alphaValue = 0`
  （`WorkspaceVisibilityTests` 守卫）；`NSOpenPanel`/`NSSavePanel`/`NSAlert` 只由手工
  验收触发。
- 测试/编译成功只证明链路可构建可执行；真实照片、人脸推理质量、签名公证、商业性能
  与 GUI 行为（窗口生命周期、面板焦点、C1 联动）是明确排除的外部证据，不能用自动化
  绿灯替代。

### 构建与发布

日常不组装 `.app`；完整 bundle 只在发布/打包时执行：

```bash
./desktop/native/build.sh        # 产物 release/Gather.app（OUTPUT_DIR 可覆盖）
```

- 脚本构建 gather-core + GatherApp，并在存在 Capture One SDK 时按 `GATHER_ARCHS`
  逐切片构建 `GatherLink.coplugin`；组装前断言内置 `FaceModels/SFace.mlpackage` +
  `manifest.json` 与两套非空 `Localizable.strings`。
- 默认不签名；`CODESIGN_IDENTITY` 存在时才签（hardened runtime +
  `desktop/native/Gather.entitlements`，签后复核 entitlement 进入签名）。

| 变量 | 语义 |
|---|---|
| `GATHER_ARCHS` | `universal` / `arm64` / `x86_64`；不设 = SwiftPM 主机默认。universal 用 `lipo -archs` 断言双切片。 |
| `GATHER_VERSION` | 未设回退 `git describe --tags --abbrev=0`，再回退 Info.plist 的 `3.0.0`；写入 `CFBundleShortVersionString`。 |
| `GATHER_BUILD_NUMBER` | 未设用 `git rev-list --count HEAD`；写入 `CFBundleVersion`（只允许数字与点）。 |
| `CODESIGN_IDENTITY` | Developer ID Application 身份；先签嵌套项再签主 bundle，`--timestamp` 是公证硬要求。 |
| `GATHER_NOTARIZE=1` | `ditto` → `notarytool submit --wait` → `stapler` → `spctl`；凭据取 `GATHER_NOTARY_PROFILE` 或 Apple ID 三件套，缺省时本地 skip。 |
| `GATHER_RELEASE=1` | 发布门：版本、universal、Developer ID、公证凭据、插件任一缺失即 exit 1。 |
| `GATHER_SWIFT_FLAGS` | 追加给 `swift build` 的额外参数（默认空）。外层已有沙箱时（CI runner / 容器 / 受限桌面）需要 `--disable-sandbox`，否则 SwiftPM 自带的 `sandbox-exec` 会报 `sandbox_apply: Operation not permitted`。 |

- `release/Gather.app/Contents/Resources/build-info.json` 记录 version / build /
  commit / dirty / archs / plugin / minos / sdk 等固定键序字段，不含时间戳。
- 发布产物是 universal + 签名 + 公证。CI release job 只在 `v*` tag 或
  `workflow_dispatch` 时运行（`needs: [gates, gather-app]`，要求 macOS 26 SDK）。
  授权 SDK 不在仓库内；真实签名、公证与 Gatekeeper 验收只能在具备条件的机器或
  release runner 上完成。
- `desktop/native/Gather.entitlements` 只声明
  `com.apple.security.automation.apple-events`（Capture One 桥接）。**不开启 App
  Sandbox**：当前签名/运行模型没有沙盒容器，沙盒化需要单独的容器迁移与
  `files.*` entitlement。

### 隔离数据目录（QA/实机验收）

默认数据目录是 `~/Library/Application Support/Gather`。实机验收建议用独立目录，
避免旧库 fail-closed 或污染真实数据：

```bash
defaults write com.gather.desktop.native GatherApplicationSupportDirectory /tmp/gather-acceptance
open -n release/Gather.app
defaults delete com.gather.desktop.native GatherApplicationSupportDirectory
```

也可用 `--data-dir <path>` 或 `GATHER_APPLICATION_SUPPORT_DIR`；三者都只在显式设置时
生效，生产默认路径不变。

## 架构约定

```text
SwiftUI（GatherUI：页面 / ViewModel / LanguageStore）
  ↓ AppServices（16 个域 API / 172 个类型化方法，同进程直连）
GatherHost（AppComposition 组合根、AppRuntime、Live*API）
  ↓
GatherApplication（服务编排；交付在 GatherDelivery）
  ├── GatherPersistence：SQLite WAL + SchemaCurrent
  │     （55 表 / 451 列 / 86 索引 / 81 外键，user_version=1）
  ├── GatherAnalysis：图像读取、Vision 人脸、RAW/ImageIO 解码
  ├── JobService（可恢复任务：executor + checkpoint + dedupeKey）
  └── DeliveryCoordinator：deliveries 写回（重试 / 冲突 / 重启恢复）
```

### 页面与路由

- `RootView`（`GatherUI/Shell/RootView.swift`）只保留依赖、`@State` 与 modifier 接线；
  导航/侧栏/工具栏/详情/通知由 `RootShell*.swift` 拆分承载。页面按目的地**条件构建**，
  `NavigationSplitView` 负责侧栏材质与选中语义。
- 会话页由 `GatherUI/Shell/SessionPageHost.swift` 按 `SessionPage` 分发 ViewModel；
  session 切换用 `.id("session-page-\(sessionId)-\(page.rawValue)")` 保留身份。
- 工作区状态由 `SessionStore`/`SessionWorkspace` 持有（每会话一套 + LRU），入口意图经
  `WorkspaceIntent` 取用即清。
- Jobs、Settings、Face Keywording、Duplicates、Culling、Export、Control Center 均为
  SwiftUI 原生页面。

### 数据与任务

- SQLite 用 WAL；唯一建库入口是 `Database.open(at:)`：新库按
  `SchemaCurrent.createSQL` 单事务建库并写 `PRAGMA user_version = 1`。只有空库与当前
  版本可直接使用；旧版本、版本更高、版本 0 有表、形态不符、非 SQLite 文件默认 fail
  closed。开发重置策略才把 db/-wal/-shm 改名为 `<db>.incompatible-<ts>` 后重建
  （ADR-005/006）。
- 导入创建 session、写入照片资产后立即提交 `metadata.scan` 任务；任务中心负责进度、
  失败显示、重试和取消。
- 元数据写回经 `DeliveryCoordinator` + `deliveries/delivery_sessions/delivery_items/
  delivery_intents`，支持失败重试、冲突处理和重启后恢复。
- 文件操作必须使用数据库中已授权的资产路径；删除、移动和覆盖类操作需要显式确认。
- 重复资产按逻辑资产处理，避免 RAW/JPEG 配对造成重复分析或重复写回。

### 原生边界

- 应用不包含 WKWebView、JavaScriptCore、React、TypeScript IPC 或 Electron 主进程。
- 类型化 API 只接受明确输入；非法/未知输入返回可诊断错误，不应静默成功。
- UI 不直接持有数据库连接或执行任意文件路径操作；服务层负责授权和事务边界。

## 本地化

- `L10n`（`Support/L10n.swift`）：**key 即中文文案**；渲染期携带 `language`，经
  `Bundle.module` 的 `.lproj` 查表，未命中回退 key。`L10nStringCache` 按
  (language, key) 缓存查表结果。
- 新增文案调 `l10n("中文文案")` 并补 `en.lproj/Localizable.strings`；禁止新增
  `GatherLocalization.l(` 调用（Cut 4 已 codemod 到 0）。
- 错误码一律以 `GatherErrorCode` 从服务层抛出，UI 经 `errorText` / `message(for:)`
  映射，不直接展示 rawValue；错误码与 `errorMessages` 表逐项对齐，缺失即测试红。
- 语言持久化：`settings.ui_language` 是唯一真相源；`LanguageStore` 更新内存并广播
  `languageChanged`。菜单单轨（只有 SwiftUI `.commands`），标准菜单项跟随系统语言。
- 孤儿键：`LocalizationParityTests` 断言 en 表无代码未引用键（allowlist 仅测试构造）。
- **中文表只有占位**：`zh-Hans.lproj` 是 9 条占位键（中文即 key，运行时直接回退），
  `en.lproj` 才是唯一翻译表。因此"中文覆盖率"不在门禁范围；新增文案必须补 en，
  否则英文界面回落中文（parity 用例会红）。

## HIG 约定

- 语义字号：`.largeTitle`（页头）、`.title3.weight(.semibold)`（区块）、
  `.headline`/`.callout`/`.caption`（正文与辅助）；数值用 `tabular-nums`。
- 主操作走系统 `Button` + 根视图 `.tint(GatherTheme.primary)`；破坏性操作用
  `role: .destructive` + `confirmationDialog` 双确认，高频确认由 `Confirmed<T>` 承担。
- 常驻隐藏页 `.accessibilityHidden(!isVisible)`；图标按钮补 `.accessibilityLabel`；
  动画跟随 `accessibilityReduceMotion` 降级。
- 颜色/圆角/间距统一取 `GatherUI/DesignSystem/Tokens/GatherTheme.swift`，卡片统一 `gatherCard()`，
  禁止内联色值字面量。

## 门禁

CI 的 `boundary` / `gates` / 两个测试 job 执行以下命令（本地手动跑同一组；
`check-warnings` 在两个测试 job 内）：

```bash
./scripts/check-no-legacy.sh             # 无 Legacy/兼容层、WebKit/JS、Electron；app 无 JSONSerialization
./scripts/check-cleanup-ratchet.sh       # 5 个清理指标不超 docs/cleanup-baseline.json
./scripts/check-layering.sh              # 依赖方向（UI 不 import Persistence/Domain/Analysis/Delivery/Host）
./scripts/check-protocol-surface.sh --strict
./scripts/check-duplicate-symbols.sh --strict
./scripts/check-test-catalog.sh --strict # 测试文件头注释 / skip 元数据
./scripts/check-select-star.sh --strict
./scripts/check-preview-surface.sh --strict
./scripts/check-coded-errors.sh
./scripts/check-backlog-evidence.sh
./scripts/check-design-system.sh
./scripts/check-warnings.sh              # core/app Sources -warnings-as-errors
```

门禁与扫描以当前工作树为准；未暂存的删除仍会被 `git ls-files` 列出，不能据此判断
文件仍然存在。

## 类型化 API 契约

- 16 个域协议 / 172 个方法（`GatherProtocol/API/*API.swift`）。旧 118 条字符串命令已
  删除，历史映射见 git 历史。
- **破坏性操作**只接收 `Confirmed<T>`：类型层面禁止裸 Bool；UI 必须在真实确认弹窗
  分支构造。
- 输入类型在 `init`/`decode` 完成非空、长度、枚举、范围与数量上限校验；非法输入抛
  `GatherError.invalidParameter`（字段名进 params）。
- 路径授权由 `PhotoPathPolicy.requireKnown/filterKnown` 承担；未授权路径抛
  `PHOTO_NOT_FOUND`，不得退化为任意文件读取。
- 分页：`CullingAPI.page` 按**逻辑资产**分组（`COALESCE(asset_id, id)`），
  `afterRowId`/`nextRowId` 是不透明 keyset 游标，`total` 按逻辑资产计数。
- 事件：`GatherEventCenter.shared.wire(jobService:)` 推送 `jobs:progress`、
  `culling:sync-status`、`gather:notification`、`languageChanged`、`importCompleted`；
  轮询兜底（Dashboard 活跃 2s/空闲 30s、控制中心 3s/15s、C1 胶囊 12s）。
- 长任务由 JobService executor 承载：`metadata.scan`、`checksum.backfill`、
  `sim.analyze`、`face.analyze`、`duplicate.scan`、`quality.score`、`output.run`、
  `thumbnail.build` 与 recluster。
- 相似度结果可存多档（主档 + 预计算邻居阈值）；"最新结果"判定必须排除
  `precomputed` 行（不变量由 `reuse-and-tiers` 测试强制）。
- 增量聚类见 [ADR.md](ADR.md) 的 ADR-027；schema 只有当前版本，旧库默认 fail closed，
  显式重置才归档重建。

## 提交与 Pull Request

- 提交信息按 Conventional Commits，例如 `refactor(native): 完成原生任务中心路由`。
- PR 说明：变更涉及的页面/服务/数据边界；如已运行测试，附命令与结果（发布/打包变更
  再列 `build.sh` 与产物）；未验证或明确排除的外部条件；是否涉及迁移、写回、删除或
  恢复行为。
- 不要把构建产物、个人照片、模型文件或本地数据库提交到仓库。
  例外：`desktop/native/gather-core/Sources/GatherAnalysis/FaceModels/SFace.mlpackage`
  （`weight.bin` 约 38.5MB，Apache-2.0）是构建必需资产；替换/新增模型需在 PR 说明
  来源、许可与体积，并优先评估 LFS。

## 常见问题

- **构建报 Clang module cache 错误**：把 `CLANG_MODULE_CACHE_PATH` 指向
  `/private/tmp` 下可写目录后重试。
- **为什么没有 npm 命令**：Node/Electron 运行时已随原生迁移移除；开发、测试和打包
  入口统一为 Swift Package 与 `desktop/native/build.sh`。
- **为什么生成的 `.app` 未签名**：这是源码构建的默认边界；需要签名时由发布环境提供
  `CODESIGN_IDENTITY`。签名、公证和安装验证属独立发布活动，不属于代码验收。

## 相关文档

- [项目总览](README.md)
- [路线图](ROADMAP.md)
- [架构决策记录](ADR.md)
- [测试体系审计与优化](test-runtime-audit.md)
- [设计系统与页面配方](design/appearance-interaction.md)

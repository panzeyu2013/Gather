# Gather App / UI / Host / build / test 宏观架构评审

- 评审对象：`/Users/panzeyu2013/Desktop/code/develop/Gather`，HEAD `30f51f0`，工作区干净。
- 评审范围：`desktop/native/gather-app` 的 GatherApp / GatherHost / GatherUI 三层，及其构建、资源、测试与发布形态；同时对照 `gather-core` 的协议/分层边界。
- 方式：只读静态阅读 + 行数/import/引用统计 + 两个包的全量测试实跑。**除本文件外未改任何源码、测试、Package、脚本或 CI。**
- 口径：文中数字均为本次实测；**已确认** = 本次有文件/行/命令证据；**疑似** = 静态可解释但依赖环境或未复现。

---

## 0. 结论（先看）

**一句话：三层依赖方向是干净的，状态所有权也比典型 SwiftUI 单体清晰；真正的问题不是“缺一个 reducer/store”，而是三个“语义错位”：Host 仍拥有 UI 外壳、UI 内又藏着 Live 适配器、同步 provider 迫使同一能力维护两套 API。**

| 维度 | 判断 | 主要依据 |
| --- | --- | --- |
| 三层依赖方向 | **强** | `GatherApp` 111 行只做 `@main`/Scene；`GatherUI` 对 Persistence/Domain/Analysis/Host 的 import 为 0；strict import check + `check-layering.sh` 双重门禁 |
| 层归属（谁该拥有什么） | **中** | `GatherHost` 里有 882 行纯 SwiftUI 外壳（RootView/RootShell*），与 D-017“Host 只留装配与 Bridge”不一致；`GatherUI` 里又有 3 个生产用 `Live*DataProvider` |
| UI 状态所有权 | **强偏中** | `SessionStore → SessionWorkspace → 7 VM → 页面 @State` 层级明确；但 7 个 VM 的可见性/生命周期各自实现，7 份 `setVisible/shutdown`，默认值与字段名不统一 |
| Host 组合根 | **中** | 单一组合根与单一 `AppRuntime` 是优点；但 29 个字段、33 个局部构造、269 行 `make` 主函数，新增一个域要改 5+ 个文件 |
| API 适配层 | **中** | 16 个 Live API、111 个协议方法、约 4,059 行；主体是薄适配，不是重复实现；代价是 27 个同步核 + 18 个同步端口方法 + UI 侧再包一层 provider |
| 构建/资源 | **强偏中** | 资源/entitlements/模型断言很扎实；但 `Package.swift` 在 manifest 阶段执行 `xcrun`，SDK 版本不可复现，app 包缺 core 的 CLT 测试路径探测 |
| 测试 | **强** | core **1128 tests / 159 suites**、app **616 tests / 68 suites**，均 exit 0；但 app 必须 `--no-parallel`，测试夹具 app 侧 2,723 行且无法复用 core 的 GatherTestSupport |
| 发布 | **弱（缺口，不是 bug）** | `build.sh` 只组装 + 可选签名；无 universal、无 notarization/staple、无版本注入、CI 无 release job |

**总判断：不需要引入全局 reducer / TCA / actor。需要的是“把边界落到归属上”和“删掉历史同步面”，而不是再加一层状态框架。**

---

## 1. 范围、方法与实测

### 1.1 阅读范围

- 两个 `Package.swift`、`.github/workflows/ci.yml`、`desktop/native/build.sh`、`Gather.entitlements`、`Info.plist`、`Resources/*.lproj`。
- `GatherApp`（1 文件）、`GatherHost`（43 文件，含 APIs/RootShell*/AppBootstrap/AppRuntime/AppComposition/Bridge）、`GatherUI`（178 文件，11 个页面目录 + Support/Shell/PreviewSupport）。
- 状态层：`SessionStore`、`SessionWorkspace`、`WorkspaceIntent`、7 个会话 VM、4 个全局页面 VM、`LanguageStore`、`GatherEventCenter`、`CommandError`、`APIErrorPresentation`。
- 测试：`GatherAppTests` 67 文件 / 22,494 行；`GatherCoreTests` 97 文件 / 34,817 行；`GatherTestSupport` 2 文件 / 162 行。

### 1.2 实测命令与结果

```bash
# app（本机需 --disable-sandbox 才能跑 SwiftPM；其余与 CI 同口径）
swift test --package-path desktop/native/gather-app --disable-sandbox --no-parallel \
  --explicit-target-dependency-import-check error
# → Test run with 616 tests in 68 suites passed after 16.754 seconds，exit 0

# core
swift test --package-path desktop/native/gather-core --disable-sandbox \
  --explicit-target-dependency-import-check error
# → Test run with 1128 tests in 159 suites passed after 3.862 seconds，exit 0

# 只读门禁
./scripts/check-layering.sh        # OK
./scripts/check-duplicate-symbols.sh
./scripts/check-preview-surface.sh # #Preview=14, PreviewSupport 5 files/2031 lines
```

> 计数偏差：源码中 `@Test` 声明 app 为 618 条，运行汇总为 616 条（2 条非执行/条件声明）；以运行汇总为准。core 声明与运行均为 1128。任务书写的“1128/616”与实测一致。

### 1.3 未执行 / 限制

- 未执行 `build.sh`（会写 `release/Gather.app`，超出本次“只写报告”的边界）；未做 codesign/notarization 实测。
- 无 GUI 自动化，未做视觉、交互、TCC 人工验收。
- 未观测远端 GitHub Actions；CI 结论基于 workflow 文件与本地同口径测试。
- CLT-only 环境下 app 测试链接失败是静态推断（见 §5.2），本机有完整 Xcode，未复现。

---

## 2. 三层边界、依赖方向、组合根与端口

### 2.1 物理结构与依赖方向（已确认）

| Target | 文件 / 行数 | 对外 import（非系统） | Package 依赖 |
| --- | ---: | --- | --- |
| GatherApp | 1 / 111 | SwiftUI、AppKit、GatherUI、GatherHost | GatherHost、GatherUI |
| GatherHost | 43 / 8,804 | GatherProtocol×34、GatherDomain×31、GatherAnalysis×29、GatherPersistence×28、GatherUI×21、SwiftUI×7 | 四层 core + GatherUI |
| GatherUI | 178 / 28,726 | GatherProtocol×144、SwiftUI×100、AppKit×28、Foundation×75、Observation×4、Combine×2 | 仅 GatherProtocol |
| gather-core | 145 / 43,462 | 四层分层 target | — |

依赖方向由三处共同守住：

1. `gather-app/Package.swift:87-133` 的 target dependencies 只允许上述方向；
2. `build.sh:24-27` 与 CI 的 `--explicit-target-dependency-import-check error`；
3. `scripts/check-layering.sh` 对 GatherUI 禁 Persistence/Domain/Analysis/Host、对 GatherApp 禁四层 core、对 Host 禁 GatherApp。

本次实测 GatherUI 对四个禁止模块的 import 均为 **0**；GatherApp 对四层 core 的 import 均为 **0**；`check-layering: OK`。这是本仓库最扎实的架构资产之一。

### 2.2 边界判断：编译器干净，语义归属不干净

**（1）Host 仍拥有 UI 外壳（已确认，最重要）。**

- `RootView.swift`（154 行）+ `RootShellNavigation/Detail/Sidebar/Toolbar/Overlay/Workspace`（合计 728 行）= **882 行**，全部只 import SwiftUI / AppKit / Foundation / Observation / GatherProtocol / GatherUI，**没有一行 import Persistence/Domain/Analysis**（见各文件头部 import）。
- 这些文件是纯 SwiftUI 导航外壳、侧栏、工具栏、Toast/导入入口、workspace 生命周期；它们不构造服务、不碰 AppServices，只消费 UI 类型 `RootShellDependencies` / `SessionStore` / `LanguageStore`。
- D-017 的原意是“Cut 4 再把 Shell 与页面迁入 GatherUI，Host 只留装配与 Bridge”；当前 Cut 4 只做了 RootView 内部拆分（4c-2k），没有完成归属迁移。
- 影响：Host 被 SwiftUI 污染（7 处 import SwiftUI），RootView 的测试被迫依赖 Host；组合根与表现层无法分开做 headless 测试；新人无法从 target 名判断 RootView 在哪一层。

**（2）GatherUI 里藏着生产 Live 适配器（已确认）。**

- `LiveDashboardDataProvider`（DashboardViewModel.swift:85）、`LiveGalleryDataProvider`（GalleryViewModel.swift:124）、`LiveLibraryDataProvider`（LibraryViewModel.swift:203）都在 GatherUI，且由 Host 的 `AppBootstrap` 构造注入。
- 这三个类不是 Preview/测试替身，而是生产实现；它们只依赖 GatherProtocol 的 API，所以不违反编译边界，但语义上属于 Host 的适配层。
- 结果：同一份“API → 页面形状”的适配知识分散在 Host 的 Live API 与 UI 的 Live provider 两处；UI 不再是纯“视图 + VM + 端口”。

**（3）宽端口 `RootShellDependencies` 是新的耦合点（已确认）。**

- 16 个字段：12 个 `any *API` + 1 个 C1 桥 + 3 个 provider（RootShellDependencies.swift:15-32），`package init` 逐字段透传。
- 每新增一个页面依赖，就要同时改：GatherUI 的 struct + Host 的 AppBootstrap + SessionWorkspaceFactory + 测试夹具。端口本身是 UI-owned、Host 实现，方向正确；但它把“壳层需要哪些能力”固化成一个 16 字段的上帝包。

**（4）端口/适配器的正面：**

- UI 对 Host-only 能力有明确端口：`ImageDecoderPort`、`ImportPathRules`、`CaptureOneSyncStateRules`、`JobProgressSource`、`DomainErrorMessaging`、`JobCancellationMarker`，避免了 UI→Analysis/Domain 的反向依赖。
- 但前三个是**进程级静态注册表**（`ImageDecodingRegistry` / `ImportPathRulesRegistry` / `CaptureOneSyncStateRulesRegistry`，各带 NSLock + `nonisolated(unsafe)`），由 AppBootstrap 安装；视图深处直接 `Registry.current()`。这是服务定位器，不是依赖注入：测试要安装/清理全局，预览要预置全局。

### 2.3 组合根与端口适配的总评

- 组合根只有一个，且 `AppRuntime` 只从 `AppComposition` 取实例，没有第二套 db/JobService/executor；AppCompositionTests 对同指针/同缓存/8 executor 有契约测试。这一点应保持。
- 但“组合根 + AppServices + RootShellDependencies + SessionWorkspaceFactory”形成一条 **5 文件装配链**：新增一个域 API，至少改协议（core）、Live 适配器（Host）、AppComposition、AppServices、RootShellDependencies/AppBootstrap/Factory。组合根不是“太重”，而是**变更放大**太强。
- `AppServices.assemble` 的 9 个可选覆盖参数（culling/face/similarity/…，AppServices.swift:123-131）只有 `live(composition:)` 一个调用点且全部传 nil；9 个 `makeX` 也只是把 composition 字段包成 Live 实例。这是可删的模板代码，不是架构能力。

---

## 3. UI 状态架构：SessionStore + SessionWorkspace + 7 VM + 页面 state

### 3.1 状态所有权（已确认）

| 状态 | 持有者 | 生命周期 | 可见性/刷新 | 测试接缝 |
| --- | --- | --- | --- | --- |
| 目的地 / 返回栈 / 来源 | `RootNavigation`（Host，`@State` 在 RootView） | 与 RootView 同寿命 | `destination` 驱动 detail 条件构建 | `RootView` 可注入 navigation；RootNavigationTests |
| 活动 workspace 表 / lastSessionId / LRU | `SessionStore`（UI，`@Observable`） | AppBootstrap 创建，进程寿命 | `activate/evict/endSession`；capacity 6 | FactoryTests；工厂闭包注入 |
| 每会话 7 个 VM + 标题缓存 + 入口意图 | `SessionWorkspace`（UI，`@Observable`） | 首次 `workspace(for:)` 创建；LRU 淘汰或删除会话时 `close()` | 二级可见性：会话级 `setVisible` + 页面级 `setPageVisible` | 7 个 VM 均可注入 API；SessionWorkspaceFactory 在 Host |
| Dashboard / Library / Persons | RootView 的 `@State` | 与 RootView 同寿命 | Dashboard 有 `isVisible` + 自动刷新；Library/Persons 事件驱动 | 3 个 provider 协议 + stub |
| Settings | SettingsView 的 `@State` | Settings scene | 独立窗口；12s C1 轮询在 VM | SettingsViewModel 注入 |
| 页面瞬时态（弹窗/焦点/选中） | 各 View 的 `@State/@FocusState/@SceneStorage` | 页面条件构建，切页签销毁 | 135 个 `@State`、17 个 `@FocusState`、9 个 `@SceneStorage`、62 个 `@Environment`、13 个 `@Bindable` | 布局/Factory 测试直接构造 View |

层级本身是合理的：**没有把页面状态提升成全局单例，也没有让 View 直接持有服务**。7 个会话 VM 由 `SessionWorkspaceFactory`（Host）构造，UI 只持有 workspace 引用；导航与 workspace 生命周期解耦（SessionStore 不持有 destination）。

### 3.2 生命周期与可见性：语义不统一（已确认）

- 7 个 VM 各自实现 `setVisible` / `shutdown`：CullingViewModel.swift:274/290、Duplicates 165/171、Export 91/98、Face 130/137、Control 88/124、Gallery +Core.swift:16/35、Similarity 297/311。`SessionWorkspace.setPageVisible` 用一个 7 分支 switch 路由（SessionWorkspace.swift:119-137）。
- 默认值不一致：Control `isVisible = false`（ControlCenter/SessionControlViewModel.swift:49），Culling 用 `isActive = true`（CullingViewModel.swift:136），Gallery/Duplicates/Export/Face/Similarity 用 `isVisible = true`（如 GalleryViewModel.swift:291）。语义上“默认可见”与“默认不可见”并存，靠 init 后立即 `setPageVisible` 纠正。
- 副作用不同：Control 的 `setVisible(true)` 启动轮询；Gallery 的 `setVisible(true)` 恢复轮询 + 首载激活 + 补隐藏期事件；Culling 的 `setVisible(true)` 补领域刷新 + 恢复画质轮询；Export/Face/Duplicates 主要是置位。统一协议若只表达 bool 会丢语义，但至少可以统一“默认值 + 关闭终态 + 幂等”的契约。
- 正面：两级可见性已经修正了旧 review 的“进入会话 7 VM 全量扇出”；本次 SessionWorkspace 测试明确验证“进入 culling 只有 culling 启动，gallery/control/similarity 请求计数 0”（测试输出可见）。`close()` 是终态、幂等，`endSession` 已从 RootView 的 `onSessionDeleted` 接线（RootView.swift:80-82），旧“幽灵会话”问题不再成立。

### 3.3 跨页共享：容器共享，数据不共享（已确认）

- 共享的是 **workspace 容器 + API 实例 + 入口意图**，不是照片/选择集：Culling 的选中集、Gallery 的选中集、Duplicates 的分组各自持有。
- 跨页一致性靠 `GatherEventCenter.postDomainChange` + 页面 `.onReceive` 刷新；全仓 35 处 NotificationCenter 订阅、32 处 post（含 job progress/C1/domain）。各页刷新自己的数据源，不做整树重建。
- 代价：同一实体可能被多个 VM 各查一份（Gallery 的 pages、Culling 的 page、Library 的 global page）；事件风暴下重复查询，但由可见性门控限制在“当前挂载页”，不会 7 页同时打库。对当前规模可接受。
- 入口意图用 `WorkspaceIntent`（6 种 Kind）传参，由目标页 `.task` take 后消费；这比把 pending 状态塞进 RootView 更好，跨页动作有明确归属。

### 3.4 可测试性

- 强项：所有 VM 都是 `@MainActor @Observable`，依赖以协议注入；616 条 app 测试覆盖 VM/API/布局/本地化；53 个文件 `@testable import GatherUI`，能直接断言内部状态。
- 弱项 1：VM 状态被文件拆分放宽为 `internal(set)`（107 处）与 `private(set)`（58 处）；跨文件 extension 可写，模块外只读。这不是错误，但“状态只能由 VM 自己改”的约束在模块内是约定，不是编译器保证。
- 弱项 2：`DashboardViewModel.init(provider:)` 把 provider 下转成具体 `LiveDashboardDataProvider` 来偷 `sessionAPI/jobAPI`（DashboardViewModel.swift:387-396）；`LiveLibraryDataProvider` 把 `any SessionAPI` 下转成 `any SessionSyncAPI`（LibraryViewModel.swift:228-236）。测试必须构造 Live 实现才能覆盖 async 路径——协议端口没有真正封装实现选择。
- 弱项 3：全局单例（GatherToastCenter/C1StatusService/GatherEventCenter/registries）使 app 测试必须串行；CI 与文档已统一 `--no-parallel`，16.7s 可接受，但这是“用调度顺序换稳定”，不是隔离。

### 3.5 是否应引入 reducer / feature store / actor？

**结论：不应引入全局 reducer/TCA，也不应把 UI 状态搬进 actor；可以引入“薄生命周期/加载状态契约”，但不值得为此重写 7 个 VM。**

- **Reducer/TCA**：当前状态转换是“用户动作 → async API → 多字段赋值 + 轮询/取消 + 事件广播”，副作用与状态强耦合。改成 reducer 需要 effects 系统、依赖容器、全量页面重写；收益是集中可测，成本是 5k+ 行 VM 与 616 条测试的重构。当前页面间没有复杂共享状态机，收益不成立。
- **Feature store**：`SessionWorkspace` 已经是“每会话 feature container”；再引入一个横跨 7 页的 store 会把页面隔离换成全局耦合，和现有“按页可见性”方向相反。若要共享照片缓存，应单独做 per-session `PhotoCache`，而不是状态大仓。
- **Actor**：SwiftUI 观察要求 MainActor；VM 的 await 已经让出主线程，API/DB 层有并发控制。把 VM 改成 actor 只会增加 hop 与 `@Observable` 不兼容，不解决任何现有问题。
- **值得做的替代**：统一 `LoadPhase`（已有 4 个列表页（Dashboard/Library/Gallery/Persons）使用，Similarity 自造 `Phase`，Culling/Control/Face/Duplicates/Export 用 `isLoading`）与统一“可见性契约”（默认值、关闭终态、幂等），再把 EventCenter/Toast/Language 改为可注入实例以恢复并行测试。这是低成本、行为可保真的收敛。

---

## 4. Host：组合根、16 个 Live API、Bootstrap/Runtime、全局状态

### 4.1 AppComposition：不是行数过重，是扇出过宽（已确认）

- `AppComposition.swift` 390 行；`make` 主函数 269 行（127-388），33 个局部 `let`，35 处 Service/Repo/Coordinator 构造，29 个存储字段，import 四层 core + GatherUI。
- 它同时负责：Repo/Service 构造、XMP /provider 选择、delivery 事件 sink、XMP 文件锁共享、metadata flush 闭包、thumbnail/cluster provider 闭包、executorDeps、AppRuntime 构造。
- 正面：所有共享实例只有一个来源；`runtime` 也由这里构造；测试用 `make(db:)` 接缝，生产用 `make(database:)`；AppCompositionTests 锁定同指针/同缓存。
- 负面：新增域要穿过 5 个文件；闭包策略（如 `warmMetadata`、`thumbnailProvider`、`clusterProvider`）写在组合根里，组合根承担了“策略”而不只是“装配”。这不是 P0，但会让每次域扩展都变成多点编辑。

### 4.2 AppServices / Live API：薄适配，但有两套面（已确认）

- 16 个 Live API，协议 111 个方法，Live 层约 4,059 行（含 Input/PathPolicy），平均每方法 ~35 行（含大量注释/校验）。主体是“转调 + 错误收敛”，不是重复业务实现；**不应把 Live API 当成冗余层删掉**。
- 真正的重复面：
  - 6 个域保留同步核：Session 7、Album 5、Asset 5、Job 5、Navigation 4、Photo 1，共 **27 个** `func *Sync`（Live*.swift）。
  - GatherUI 定义 4 个同步端口（SessionSyncAPI/AlbumSyncAPI/AssetSyncAPI/JobSyncAPI，共 18 个方法，LiveSyncPorts.swift:22-58），Host 用 18 个 public extension 转发（SyncAPIPortBridge.swift:13-73）。
  - 这 18 个方法只为 Dashboard/Library 的同步 provider 存在；生产 UI 的 async 路径又优先走 API。结果是同一能力有 async、sync、provider 三个入口。
- 错误收敛不统一：只有 Album/Asset/Navigation/Person/Culling 5 个 Live API 使用 `LiveAPIErrorMapping`（30 处）；其余 11 个直接抛服务错误。UI 侧 `CommandError` 需要认识 `GatherError/SessionServiceError/CaptureOneBridgeError/APIError/RouterCommandError/BridgeError` + 两个 `DomainErrorMessaging` 协议。不是错误，但“边界归一化”是每个适配器各自决定的，不是统一策略。
- 消费者缺口：`template` 域在生产 UI 0 调用（D-008 已记录），但仍在 AppServices/AppComposition 中完整装配；这是组合根的“静态重量”，不是运行时问题。

### 4.3 AppBootstrap / AppRuntime（已确认）

- `AppBootstrap` 318 行，`makeScene` 151 行，线性执行 12 步：目录/权限 → Database.open → Composition → AppServices → 冷启动语言 → runtime.start → 事件接线 → embedding 迁移 → 3 个 provider → C1 桥 → delegate wire → rootDeps/sessionStore/scene。顺序有注释契约，测试可传 temp dir。
- `AppRuntime` 229 行：executor 注册、start/shutdown 幂等、delivery replay 后台、`NSLock` 保护 lifecycle、shutdown 先 await replay 再关库。这是 Host 里质量最高的一段，不建议改。
- 组合根/启动层的真实风险不是“太大”，而是：`AppBootstrap` 同时做文件系统权限、数据库、服务、语言、provider、桥、delegate、scene 发布；任何一步新增都改同一个函数。可拆成 private static `makeDatabase` / `makeServices` / `makeSceneState`，但保留单一 `startup` 入口即可，收益是可读性/可测性，不是架构重构。

### 4.4 错误 / 事件 / 语言的全局状态影响

- **错误**：`CommandError` 只搬运码/参数/诊断，渲染期由 `L10n` 解析（CommandError.swift:20-118；APIErrorPresentation.swift:19-46）。方向正确；问题是各 VM 仍有 202 处 `errorMessage` 引用、5 种错误载体（errorMessage/actionError/jobsError/createError/notice），没有统一的“页面错误状态”。这不是全局状态问题，是页面状态形状不统一。
- **事件**：`GatherEventCenter` 是 `@MainActor @Observable` 单例，静态 Notification 名 + 4 类事件；`wire(jobEvents:)` 按 JobService 身份幂等重接。页面通过 `.onReceive` 订阅。事件是进程级、无类型注册表、无 per-session 隔离；测试必须串行。对单窗口应用可接受，但“页面刷新”依赖字符串通知名，重构时没有编译期保护。
- **语言**：`LanguageStore` 是唯一写入口，AppBootstrap 播种，RootView/Settings 注入，958 处 `l10n(` 文本（含定义/注释，调用面约 900+）；旧 `GatherLocalization.appLanguage` 仍存在但只作为 `LanguageStore` 的同步镜像与启动兜底，页面不再直接读它。方向已收敛。残余风险是 52 处 `languageStore?.l10n ?? L10n(language: .zhCN)` 固定兜底：如果生产注入漏了，界面会静默中文而不是报错；这是“可选环境 + 固定默认”的架构选择，不是第二个写点。

---

## 5. 构建、资源、测试、CI/发布

### 5.1 两个 Package 与构建可复现性

- `gather-app/Package.swift` 135 行、`gather-core/Package.swift` 119 行；app 仅依赖 core 的 4 个 library product，core 另有 schema/benchmark 可执行。两包分离让 core 可独立测试/复用，方向正确。
- **manifest 执行外部进程**：`gather-app/Package.swift:40-54` 在 manifest 顶层启动 `/usr/bin/xcrun --show-sdk-version`，失败静默回退部署目标 14.0；`GATHER_SDK_VERSION` 可覆盖（:58）。这会让：
  - 每次 manifest 求值有外部进程/环境依赖（manifest 本应声明式）；
  - 同一源码在不同 Xcode/SDK 机器上产出不同 `LC_BUILD_VERSION.sdk`，直接影响 Liquid Glass 外观；
  - xcrun 失败时“静默退回旧外观”，release 无法从产物判断原因。
- **linker unsafeFlags**：`:63-70` 用 `-Xlinker -platform_version` 写入 SDK 版本；只对最终可执行生效，位置正确。代价是 app 包不能被其他包当依赖消费（对本仓库无影响）。
- **工具链设置重复**：core 的 `Package.swift:13-32` 探测 CLT-only 并给测试 target 加 `-F/-rpath`；app 的 `Package.swift` 没有这段。app 测试同样 `import Testing`，在“只装 Command Line Tools、无 Xcode”的机器上，core 能链接 Swift Testing，app 可能不能。**疑似**（本机有 Xcode，未复现），但这是两包工具链设置漂移的明确静态证据。

### 5.2 资源 / Info.plist / entitlements

- `Info.plist` 位于 `GatherUI/Support` 并被 target exclude，由 build.sh 拷入 app bundle；本地化在 `GatherUI/Resources`，SPM 生成 `gather-app_GatherUI.bundle`，同时把 `.lproj` 再拷进主 bundle（N08 系统菜单）。这是“一个真相源、两处消费”的合理折中，但真相源分散在 Package.swift resources / Info.plist / build.sh 三处。
- `build.sh` 的断言质量高：en/zh-Hans 非空、FaceModels 精确到 `SFace.mlpackage/Manifest.json`、manifest model=SFace、entitlements plist 合法且 apple-events=true、签名后复核 entitlement（:39-49、:77-128、:130-147、:190-213）。
- `Gather.entitlements` 只有 apple-events，明确不沙盒；与当前 C1/SPM 资源/插件模型一致。签名仅在 `CODESIGN_IDENTITY` 存在时执行，CI 的 bundle build 实际产出**未签名** app；TCC 行为无法在 CI 验证。
- 发布缺口：无 universal binary（build.sh 用 host arch 的 `swift build` 输出）、无 notarization/staple、无 DMG/archive、`CFBundleShortVersionString` 硬编码 3.0.0、无 git SHA/SDK 元数据。对开发期可接受，对分发不成立。

### 5.3 测试架构与 GatherTestSupport

- 数量与结果：core 1128/159、app 616/68，均 exit 0；app 必须 `--no-parallel`（CI:90、README/DEVELOPMENT 已统一）。这是当前基线，不是“疑似红”。
- `GatherTestSupport` 是 core 包 `Tests/GatherTestSupport` 下的普通 library target（Package.swift:89-94），不是 product；app 测试无法依赖它。于是 app 侧复制了 `AsyncGate`（39 行 vs core 46 行）；DB 夹具 `makeGatherTestDB` 19 行，core 的 `DatabaseTestSupport.swift` 116 行（含多个 insert helper），另有 15 个文件 / 2,723 行的 API stub。
- 评估：**不建议为这 ~60 行重复专门建第三个 package**。app 的 2,723 行 stub 是 app 专属协议替身，本来就不能被 core 复用；真正可共享的只有 DB fixture/AsyncGate。若未来 app 测试需要更多 core 夹具，最低成本是把 `GatherTestSupport` 暴露为 core 的 library product（不改变运行时分发，因为 app 不链接它），而不是新建包；收益小、优先级低。
- 测试真正的问题不是数量，而是确定性依赖：全局 EventCenter/Toast/C1/Language/registries + 2s 墙钟等待，导致必须串行。改进优先级高于“共享 test support package”。

### 5.4 CI

- `.github/workflows/ci.yml`：Ubuntu 上跑 8 个静态门禁；macOS-14 上 core tests（:52-69）、app tests + bundle（:71-92，app 串行）、macos-latest 上 toolchain drift build（:94-110）。
- 覆盖了“能编译 + 门禁 + 测试 + 组装”，但没有 release job（签名/公证/产物上传/版本）；也没有把 `GATHER_SDK_VERSION` 固定进 CI。cache key 只按 Package.swift hash，源码变更不影响 cache key（SwiftPM 会自行失效，但 cache 命中率/可解释性一般）。
- 未观测远端执行；本机同口径 core/app 均绿。

---

## 6. 目标架构选项与取舍

| 选项 | 做法 | 收益 | 成本/风险 | 结论 |
| --- | --- | --- | --- | --- |
| A. 保持三层，只补契约 | 不拆 target；统一可见性/LoadPhase，删同步面，补 release | 最低风险，保住现有测试 | 变更放大仍在 | **基线** |
| B. 完成 D-017：Shell 迁入 UI | RootView + RootShell* + RootNavigation（882 行）迁 GatherUI（可新建 GatherUIShell 子目录/target） | Host 回归“装配 + Bridge”；RootView 测试不再依赖 Host；层名与职责一致 | 7 文件搬移 + 测试 import 调整；低风险 | **推荐（第一优先）** |
| C. Host 内部拆适配器 target | 把 APIs/Bridge（约 4.7k 行）拆 `GatherAdapters`，Composition/Bootstrap/Runtime 留 `GatherComposition` | 适配器可独立对 core 测试；组合根不依赖 UI 适配器 | 多一个 target/测试 import；中等收益 | 可选，排在 B 后 |
| D. 11 个 feature module | 每页一个 SwiftPM target + shared state/shell | 编译隔离、所有权清晰 | `SessionWorkspace` 同时持有 7 个 VM，feature 又依赖 workspace，需类型擦除/重构；manifest/测试爆炸；28.7k 行规模不值 | **不建议现在做** |
| E. 全局 reducer / feature store | 单一 state + action/effect | 状态集中、可回放 | 重写 7 VM + 5k 行 + 616 测试；与 SwiftUI Observation/async 副作用不匹配 | **不建议** |
| F. 共享 test support package | 第三个包或 core 暴露 product | 去掉 ~60 行重复 | 多包/多 CI 面；app stub 仍无法共享 | 低优先级，暂缓 |

**推荐组合：B + A 的契约收敛 + 删同步面；D/E 明确不做。**

---

## 7. 建议（收益 / 成本 / 验收）

### R1. 完成 D-017：把 RootView/RootShell*/RootNavigation 迁入 GatherUI（优先级最高）

- 动作：移动 8 个文件（882 行）到 `GatherUI/Shell`（或 `GatherUIShell` target）；Host 只保留 `AppBootstrap/AppComposition/AppRuntime/AppImport/AppDelegate/Commands/Bridge/APIs`。
- 收益：Host 不再因 UI 外壳 import SwiftUI；RootView 可直接用 UI 测试构造；target 名与职责一致；为后续适配器 target 拆分铺路。
- 成本：机械搬移 + 测试 import 调整，预计 <1 人日；无行为变更。
- 验收：`grep -R "import SwiftUI" GatherHost` 只剩 Commands/必要 AppKit 桥（或为 0，视 Commands 归属）；`check-layering` 仍 OK；616/68 不变；RootView 测试只 `@testable import GatherUI`。

### R2. 删除同步双面：provider 全面 async，移除 27 个 sync core/18 个 sync port/SyncAPIPortBridge

- 动作：把 Dashboard/Library/Gallery 三个 provider 协议改成 async；VM 只依赖 async API；删除 `LiveSyncPorts.swift`、`SyncAPIPortBridge.swift` 与 Live API 的 internal `*Sync`；同时去掉 `DashboardViewModel` 对 `LiveDashboardDataProvider` 的具体下转、`LiveLibraryDataProvider` 对 `SessionSyncAPI` 的下转。
- 收益：同一能力只有一条路径；删除“未配置同步 API”这类运行时错误；适配层减约 18+ 方法/96 行桥接/若干测试夹具；测试可注入纯 stub，不必构造 Live 实现。
- 成本：中高，触及 3 个全局页 VM + 3 个 provider + 测试；建议先 Dashboard（最小，已有 async 路径），再 Library，最后 Gallery。
- 验收：`grep -R "SyncAPI\|SyncAPIPortBridge\|as? Live.*Provider" Sources` 为 0；616 条测试仍绿；新增一条“provider 只依赖 async API”的架构断言。

### R3. 组合根内部拆分 + AppServices 去模板（低风险、立即见效）

- 动作：AppComposition 的 269 行 `make` 按域拆成 private static `makeMetadataStack/makeAnalysisStack/makeWorkspaceStack`，返回小型 struct；删除 AppServices 的 9 个未使用 optional override 参数与 9 个 `makeX`（或改成表驱动），保留 `live(composition:)` 单一入口。
- 收益：新增域从“5 文件 + 269 行函数”降到“composition stack + 一个 Live 适配器”；组合根可分段测试；AppServices 可明显缩短（模板代码约占一半）。
- 成本：低-中，纯重构；AppCompositionTests 可先加同指针断言再动。
- 验收：组合根字段/服务指针测试不变；`AppServices.swift` 行数下降；无新增 public API。

### R4. 统一“页面生命周期 + 加载状态”契约，不引入 store/reducer

- 动作：定义 `SessionPageLifecycle`（默认可见性、`setVisible` 幂等、`close` 终态、可见性变化回调）供 7 个 VM 实现；把 4 个列表页的 `LoadPhase` 推广到 Culling/Control/Face/Duplicates/Export 的加载态；把 EventCenter/Toast/Language 从单例改为可注入实例（至少测试可注入）。
- 收益：SessionWorkspace 的 7 分支 switch 可退化为协议调用；新增页面不再复制默认值/终态逻辑；app 测试有望恢复并行（当前必须串行）。
- 成本：中；7 个 VM 的可见性副作用不同，协议只能约束“状态 + 幂等 + 终态”，不能强行统一轮询细节；需逐页回归生命周期测试。
- 验收：7 个 VM 的 `setVisible/shutdown` 语义矩阵测试通过；app 测试在默认并行下稳定（先跑 10 次）；616 条不减少。

### R5. 构建/发布可复现：SDK 版本显式化 + release job

- 动作：
  1. release 配置下若 `xcrun --show-sdk-version` 失败则失败，不静默回退 14.0；把 SDK/Swift/git SHA 写入构建元数据（Info.plist 或 sidecar）；
  2. CI/README 固定 `GATHER_SDK_VERSION` 或在 release job 记录实际值；
  3. 给 app 测试补 core 同款 CLT `-F/-rpath` 探测（或抽共享工具链设置）；
  4. 新增 release job：universal（`--arch arm64 --arch x86_64`）、codesign、notarytool、staple、DMG/zip、产物校验；版本从 tag 注入而不是硬编码 3.0.0。
- 收益：同一 tag 可复现同一外观/同一签名产物；消除“SDK 回退导致 Liquid Glass 消失”的静默失败；CLT-only 开发机 app 测试可跑。
- 成本：1-4 为低-中；notarization/DMG 需要证书与 CI secret，约 1-2 人日 + 发布流程约定。
- 验收：连续两次 release 构建的 SDK/版本元数据一致；`codesign -d --entitlements` 与 `spctl -a` 通过；CI 上传产物并记录校验和。

---

## 8. 边界声明：本报告不做什么

- 不重复既有 review 的 bug 清单（P0/P1 数据完整性、CI 并行红、Delivery/测试 flake 等）；本报告只讨论**当前 HEAD 的宏观结构与演进成本**。
- 不把“旧 review 提过、当前已修”的点当新发现：两级可见性、`endSession` 接线、Gallery init 不自动取页、CI `--no-parallel` 统一，均按当前代码重新核实。
- 不做视觉/交互/TCC/签名人工验收；不声称 `build.sh` 已执行。
- 行号/计数以 HEAD `30f51f0` 为准；后续改动需重新 grep。

# Cut 4 UI 状态模型 / View 拆分 · 只读评审（post-refactor R4）

- 评审角色：独立评审员（只读；唯一写入本文件）
- 仓库：/Users/panzeyu2013/Desktop/code/develop/Gather（工作区未提交）
- 评审时间：2026-10-22
- 验收口径：只写静态可复核证据；本机无 GUI 自动化，不声称做过视觉/交互验收
- 约定：`UI/` = `desktop/native/gather-app/Sources/GatherUI`，`HOST/` = `desktop/native/gather-app/Sources/GatherHost`，`TEST/` = `desktop/native/gather-app/Tests/GatherAppTests`

## 0. 结论

- **P0：0 条**（未发现崩溃、数据破坏、安全/权限绕过、不可恢复写入的静态证据）。
- **P1：5 条**（其中 1 条为疑似）；**P2：16 条**。最高风险集中在两处：
  1. `SessionWorkspace.setVisible(true)` 对 7 个 VM 的**全量扇出**，把"页面可见"扩大成"整会话可见"，导致从未挂载的页面在后台轮询/刷新（P1-2）；
  2. 会话**删除路径没有接 `SessionStore.endSession`**，已删会话在工作区表/侧栏里变成幽灵条目，workspace 不 close（P1-3）。
- 另有一条**验收阻断**（P1-1）：`.github/workflows/ci.yml` 的 app 测试未带 `--no-parallel`；本机两次默认并行跑均 `exit 1`（`DuplicatesControlCenterAPITests.swift:384` 在 2s 等待窗内没等到第 2 次轮询），而串行跑也出现另一条同类生命周期断言失败（`GalleryViewModelTests.swift:896`）。**当前"app 581/66 绿"的口径只在本机串行 + 无并发负载时成立，不能当作 CI 基线。**
- Cut 4 的核心目标（错误只存 `CommandError`、文案渲染期解析、VM 不存格式化字符串、11 个巨型 View 拆分、14 个 `#Preview`）静态检查**基本达成**，残余问题集中在生命周期/可见性语义与几处未接线的状态层 API。

## 1. 范围与方法

### 1.1 范围

| 组 | 文件 |
| --- | --- |
| 状态层 | `UI/Support/SessionStore.swift`、`SessionWorkspace.swift`、`WorkspaceIntent.swift`、`CommandError.swift`、`ViewState.swift`、`LoadPhase.swift`、`LocalizedText.swift`、`L10n.swift`、`LanguageStore.swift` |
| 外壳 | `HOST/RootView.swift`、`RootShellNavigation.swift`、`RootShellSidebar.swift`、`RootShellToolbar.swift`、`RootShellDetail.swift`、`RootShellOverlay.swift`、`RootShellWorkspace.swift`、`SessionWorkspaceFactory.swift`、`GatherApp.swift`、`AppBootstrap.swift` |
| 11 个 View | Dashboard / Library / Gallery / Culling / Duplicates / FaceKeywording / Similarity / Export / Settings / Persons / SessionControl（含 `Shell/SessionTabHost.swift`、`Shell/SessionTab.swift`） |
| Preview | `UI/PreviewSupport/*`（5 文件）、`scripts/check-preview-surface.sh` |
| 验收 | `TEST` 中 SessionStore/Workspace、RootView、Gallery/Similarity/Control 生命周期用例；`.github/workflows/ci.yml` |

### 1.2 方法

1. 逐文件读状态层与外壳；对 7 个 VM 的 `setVisible`/`shutdown`/轮询实现逐条核对（含 `+Core`/`+Index`/`+Load` 分区文件）。
2. 对所有 VM 的错误/提示载体做 grep 普查（`errorMessage`/`actionError`/`notice`/`LocalizedText`/`l()`/`l10n.format`），验证"渲染期本地化"。
3. 对 11 个 View 做 `@State`/`@SceneStorage`/`@FocusState`/`.task`/`.onAppear`/`.sheet`/`.alert`/`.confirmationDialog`/`.id(` 清单化。
4. 实测 app 测试两种模式（命令与结果见 §1.3）。
5. 对 `staleDomains` 做了全仓 grep：**仓库中不存在该符号**。与之对应的实现是 `RootShellWorkspace.pruneWorkspaceIntents`（目的地驱动失效）+ `CullingViewModel.pendingDomainRefresh` / `GalleryViewModel.deferredRefreshWhileHidden`（VM 内隐藏期登记）。本报告按这一实际实现评审，并在 P2-2 给出口径差异。

### 1.3 实测记录（本机，2026-10-22）

| 命令（app 目录） | 结果 |
| --- | --- |
| `CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --disable-sandbox --cache-path ../.build/shared-cache --scratch-path ../.build/scratch`（默认并行，跑 2 次；未加 strict import check） | 两次 `exit 1`：`Test run with 581 tests in 66 suites failed ... 1 issue`；失败点均为 `TEST/DuplicatesControlCenterAPITests.swift:384:9`（`waitUntilAsync { sessionAPI.getCalls.count >= 2 }` 超时 2s，同套件 `B5b ControlCenter API 迁移`） |
| 同上 + `--no-parallel`（跑 1 次） | `exit 1`：`Test run with 581 tests in 66 suites failed ... 1 issue`；失败点 `TEST/GalleryViewModelTests.swift:896:9`（`stub.workspaceStatusCalls == shutDown`），套件 `GalleryViewModel` |

> 两次失败不是同一条用例：并行失败在控制中心轮询，串行失败在图库索引轮询。两者都是 Cut 4 的 `setVisible`/`shutdown` 生命周期断言，说明这组用例对调度时序敏感，**不能把任一模式的结果当成稳定基线**。详见 P1-1。

### 1.4 状态层逐项核查（对照任务清单）

| 项 | 结论 | 证据 / 备注 |
| --- | --- | --- |
| active / last / pinned | active、last 由 `activate` 唯一写入，受测；pinned **无生产写点**（仅测试），保护语义实际从未启用 | `UI/Support/SessionStore.swift:19-27,62-79,81-86`；`TEST/FactoryTests.swift:220-246`；P2-3 |
| LRU capacity 6 | 淘汰顺序/受保护项顺延有测试；`workspace(for:)` 在"新项尚未受保护"时执行 `enforceCapacity`，小容量下可自淘汰新项 | `SessionStore.swift:16,44-55,120-127`；`TEST/FactoryTests.swift:186-217`；P2-1 |
| `workspace(for:)` | 命中复用、未命中工厂建；工厂内 `GalleryViewModel.init` 立即取页，故"登记意图"也会触发 DB 查询 | `SessionStore.swift:44-55`；`UI/Gallery/GalleryViewModel.swift:355-357`；P1-4 |
| `activate(nil)` | 只 suspend 当前 workspace，不淘汰、不清 `lastSessionId`；重复调用 no-op；不触发容量兜底 | `SessionStore.swift:62-69`；`TEST/FactoryTests.swift:241-246` |
| close / shutdown | 终态、幂等；7 VM `shutdown` + 清 intents/name；但只有 LRU 淘汰会 close，删除会话未接线 | `UI/Support/SessionWorkspace.swift:125-140`；`TEST/FactoryTests.swift:356-377`；P1-3 |
| intent take-and-clear | 6 种 Kind、同 Kind 后到覆盖、take 取出即清，受测；失效策略不按会话限定，Export 有 await 后再 take 的窗口 | `UI/Support/WorkspaceIntent.swift:10-43`；`SessionWorkspace.swift:111-119`；P2-2/P2-6 |
| staleDomains | 仓库无此符号；实际是 `pruneWorkspaceIntents` + 各 VM 的 `pendingDomainRefresh`/`deferredRefreshWhileHidden`；隐藏期登记依赖 `isActive`，被 fan-out 破坏 | P1-2、P2-2 |
| sessionName 缓存 | 幂等单查、close 清空、关闭后不再查（受测）；首次失败后同一次停留期间不重试 | `SessionWorkspace.swift:97-107`；`TEST/FactoryTests.swift:334-354`；P2-13 |
| 并发 / 重入 / 泄漏 | 全部 `@MainActor` 串行，工厂闭包同步且不回调 store，无重入；关闭在 store 内同步扇出，VM 只 cancel 不回调；泄漏点是未 endSession 的 workspace（P1-3）、Preview observer（P2-15）、shutdown 不等待在途请求（P2-4） | 静态审查 |

### 1.5 外壳与 11 个 View 逐项核查

**外壳修饰符顺序**（`HOST/RootView.swift:111-146`）：6 个 `.onReceive`（111-131）→ `.overlay(ToastView)`（132-134）→ `.onAppear`（135-138）→ `.onChange(of: destination)`（139-141）→ `.task(id: destination)`（144-146）。首帧由 init（85-88）与 onAppear 兜底；目的地变化由 onChange + task 双入口处理（P2-5 冗余）。Toast 在 detail 之外、文案在事件发生时解析（与"渲染期本地化"的唯一例外）。

| 页面 | 状态所有权 | 生命周期钩子 | 弹层 / 结论 |
| --- | --- | --- | --- |
| Dashboard | 8 `@State`（sheet/alert×2/pendingFolderPath/selectedIds/节流时间戳） | `.task`(91) + `.onAppear`(110) + `.onChange`(111) + 2 `.onReceive` | sheet(121) → alert(127) → alert(146)；新建请求由外壳 Binding 代收，竞态已处理；OK |
| Library | 10 `@State` + `@SceneStorage("library.inspectorVisible")` | `.task`(121) + 3 `.onReceive`；无 onDisappear（无轮询） | 5 个确认分挂不同卡片节点（`LibraryView+Support.swift:85,143,159,237,283`）→ 符合单节点一 dialog 的约定；OK |
| Gallery | 7 `@State` + `@SceneStorage("gallery.inspectorVisible")` | `.task(id: sessionId)`(117) + `.onChange(sessionId)`(150) + `.onDisappear`(156) + 3 `.onReceive` | `.sheet(lightbox)`(188)；意图 take 在首个 await 之前；标题双源（P2-12）；灯箱状态自持（见 2.1） |
| Culling | 6 `@State` + `@SceneStorage("culling.inspectorVisible")` | `.task`(72) + `.onAppear`(95) + `.onDisappear`(98) + 4 `.onReceive` | 单 `pendingAction` + 单 confirm(72)；页签切换丢 `conflictChoices/compareCount/faceAlign`（P2-11） |
| Duplicates | 4 `@State` | `.task`(143) + `.onReceive(jobProgress)` | 2 个确认分挂 ScrollView/外层 VStack（124、150），注释即"避免抢同一宿主"；项目范式来源 |
| Face | 13 `@State`（8 pending + 计数/提示） | 两个 `.task`(82/98) + `.onReceive` + 2 `.onChange` | 8 个确认同节点（P1-5 疑似）；step 在 VM、可见簇计数在 View（P2-11） |
| Similarity | 6 `@State`（4 pending） | `.task(id:)`(96) + `.onChange(sessionId)`(102) + `.onAppear`(106) + `.onDisappear`(109) + `.onReceive` + `.onChange(keywords)` | 4 个确认同节点（P1-5 疑似）；展开态已迁 VM（C-1）、页级错误只读 `phase`（4c-3） |
| Export | 3 `@State` + 2 `@FocusState` | `.task`(89) + `.onDisappear`(104) + `.onChange(planSignature)`(107) + `.onReceive` | 1 个 confirm(120)；`@FocusState` 以 Binding 下传（同源）；take 在 await 后（P2-6） |
| Settings | 7 `@State` + 1 `@FocusState` | 3 个 `.task`(137/140/142) + 2 `.fileImporter` + `.onReceive` | 2 个确认同节点（P1-5 疑似）；12s 轮询多跑一次（P2-10）；`.page(.settings)` 死路由（P2-9） |
| Persons | 5 `@State`（sheet/alert/搜索） | `.task`(84) + `.onReceive(domainChanged)` + `.sheet`(94) | 详情行自持 onAppear/onChange/alert(420-428)；OK |
| SessionControl | 4 `@State` | `.task`(157) + `.onAppear`(164) + `.onDisappear`(167) + 3 `.onReceive` + `.onChange(scrollToStagesRequested)` | 轮询在 VM；本页是 P1-1 测试失败点所在链路的页面 |

**Grid / Lightbox**：灯箱以 `currentID`（id 而非下标）定位，`photos` 缩水时按旧下标钳制到边界（`UI/Gallery/LightboxView.swift:21-54,79-90`），不会因事件刷新缩水崩溃；网格布局缓存以 `filteredFingerprint` 失效（`GalleryView.swift:159-166`）。**Tab 切换重置**：`.id("session-tab-…")`（`HOST/RootShellDetail.swift:120`）是会话/页签身份，保证跨会话不串 VM，但会销毁页面 `@State`（P2-11）。

## 2. P0

**无。** 已核查但未构成 P0 的点：

- 状态层全部 `@MainActor`，`SessionStore`/`SessionWorkspace` 无锁、无跨 actor 共享（`UI/Support/SessionStore.swift:12-14`、`SessionWorkspace.swift:18-20`）；`L10nStringCache` 是 `Sendable` + `OSAllocatedUnfairLock`（`UI/Support/L10n.swift:46-118`），未见数据竞争。
- 所有破坏性入口都有 `Confirmed<T>` 门控，`confirmed: true` 只在确认分支出现（如 `UI/Export/ExportView.swift:120-139`、`UI/Culling/CullingView.swift:72-86`）。
- 预览替身命令方法一律 throw（`UI/PreviewSupport/PreviewAPIs.swift:6-18`），无真实写。

### 2.1 已核查通过（非缺陷，供对照）

- **错误载体**：11 个 VM 的 `errorMessage`/`actionError` 全部是 `CommandError`（Similarity 的 `errorMessage` 在 4c-3 已退化为只读代理，`actionError` 单独承载操作级错误，`UI/Similarity/SimilarityViewModel.swift:198-209`）；`notice`/`errorDetail` 全部是 `LocalizedText`/`CullingNotice`/`SimilarityNotice`/`FaceNotice`。全仓未发现 VM 存储"已格式化文案"的字段；页面/VM 的裸 `l()` 调用为 0（仅 Support 内部实现用）。
- **渲染期本地化与语言切换**：页面统一 `@Environment(.languageStore)` + 计算属性 `l10n`；`LanguageStore` 是 `@Observable`，切换语言经 Observation 重渲染、不再 `.id(languageVersion)` 整树重建（`UI/Support/LanguageStore.swift:16-123`、`HOST/RootView.swift:99-105`）。窗口标题/侧栏/页签/确认框都在渲染期取 `l10n`。**唯一例外**：Toast 在事件发生时解析成 String（`HOST/RootShellOverlay.swift:55-66,76`；`UI/Support/GatherToast.swift:37`），已显示的 toast 不随语言切换变；属可接受的瞬态提示，记 P3 级观察、不列为缺陷。
- **CommandErrorText 政策**：只有 `origin == .localValidation` 且 key 含 CJK 时才把 code 当本地文案上屏（`UI/Support/NativeBanner.swift:26-59`）；API/核心散文只进 diagnostic，不上屏。
- **PreviewSupport 只读性**：整个目录 `#if DEBUG`；命令方法一律 throw、查询返回内存 fixture（`UI/PreviewSupport/PreviewAPIs.swift:6-18`）；`PreviewCaptureOne.checkHealth()` 刻意返回 failure 以避开真实 `osascript`（同文件 390-395）。**无真实 DB/网络/文件写**。进程内副作用见 P2-15。
- **灯箱/网格状态**：见 §1.5 末段；灯箱不因事件刷新缩水而崩、网格缓存按指纹失效。
- **意图 take-and-clear 的基本语义**：6 种 Kind 单槽覆盖 + 取出即清，已有测试（`TEST/FactoryTests.swift:311-332`）；本报告的问题只在"谁在什么时机 take"（P2-2/P2-6），不在容器本身。

## 3. P1

### P1-1（已确认）app 测试在默认并行下必红；串行也不稳定，CI 门禁不可用

- 位置：`.github/workflows/ci.yml:86-87`；`TEST/DuplicatesControlCenterAPITests.swift:382-384`；`TEST/GalleryViewModelTests.swift:890-896`。
- 证据：
  - CI 的 `App tests` 步骤命令为 `swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`，**没有 `--no-parallel`**（ci.yml:87）。
  - 项目自己的绿基线全部写明串行：`docs/final-report.md:38`（app 带 `--no-parallel`）、`:72`（命令含 `--no-parallel`）、`:80`（`581 tests in 66 suites passed after 12.896s`）。
  - 本机实测（§1.3）：并行两次均 `exit 1`，失败点固定 `DuplicatesControlCenterAPITests.swift:384`；串行一次 `exit 1`，失败点 `GalleryViewModelTests.swift:896`。
  - 失败断言正是"隐藏/关闭后不得再发命令"（`SessionControlViewModel` 轮询、`GalleryViewModel` 索引轮询）。
- 影响：CI 的 `gather-app tests + bundle` job 会红（或依赖机器负载侥幸绿），Cut 4 的"app 581/66 绿"无法作为合并门禁；且这两条用例是可见性语义的唯一自动化守门，失败会掩盖真实回归。
- 修复建议（二选一，建议都做）：
  1. CI 显式加 `--no-parallel`（与台账/最终报告口径一致），并在 `docs/DEVELOPMENT.md` 写明原因；
  2. 把两条断言改成"隐藏/关闭后不再**开始新**轮询"的确定性写法（例如注入可控时钟/闸门，或在 `setVisible(false)`/`shutdown()` 内同步等待在途 tick 结束），消除对 100ms 墙钟窗口和主线程调度的依赖。
- 说明：这是**验收/测试**层面的确认项；是否同时存在产品级"隐藏后多跑一次请求"的窗口，见 P2-4（疑似）。本机为多 subagent 共享工作区，其他构建/测试负载可能放大时序窗口；但两次并行失败点完全一致，说明与并行执行强相关，串行失败则更像负载下的同型窗口。

### P1-2（已确认）`SessionWorkspace.setVisible(true)` 全量扇出：7 个 VM 一起可见，未挂载页面在后台轮询/刷新

- 位置：`UI/Support/SessionWorkspace.swift:78-89`（唯一扇出点）；触发链 `HOST/RootShellWorkspace.swift:121-130` → `UI/Support/SessionStore.swift:62-79`。
- 证据：
  - `setVisible(visible)` 无条件对 `culling/duplicates/export/face/control/gallery/similarity` 逐个调用 `setVisible`（SessionWorkspace.swift:82-88），没有任何"当前目的地/当前页签"参数。
  - `SessionControlViewModel.setVisible(true)` → `startPolling()`（`UI/ControlCenter/SessionControlViewModel.swift:88-96,100-115`），每 15s（索引活跃 3s）执行一次 `load()`：`session.get` → `status` → `culling.syncStatus` → `jobs.list`（同文件 140-173）。
  - `GalleryViewModel.setVisible(true)` → `startIndexStatusPolling()`（`UI/Gallery/GalleryViewModel+Core.swift:15-27`、`+Index.swift:60-72`），每 3s/15s 查 `workspace.status`。
  - `SimilarityViewModel.setVisible(true)`：分析中恢复进度轮询、`result == nil` 时恢复结果轮询（`UI/Similarity/SimilarityViewModel.swift:302-312`、`+Load.swift:85-96`），结果轮询 2s × 最多 30 轮（`+Load.swift:98-130`）。
  - `CullingViewModel.setVisible(true)` 把 `isActive = true` 并立即 `flushDeferredDomainRefresh()`；此后 `handleDomainChange` 在"可见"时直接 `refreshSilently()`（`UI/Culling/CullingViewModel.swift:250-259,274-286`）。页面钩子里的"隐藏页不发命令"只认 `isActive`，而 `isActive` 已被 workspace 置真。
  - 页面级钩子只覆盖 4 个页面：`SessionControlView.swift:157-169`、`GalleryView.swift:144-158`、`SimilarityView.swift:96-111`、`CullingView+Content.swift:92-100`；`Duplicates/Face/Export` 页面**没有**可见性钩子。因此：从图库/相似度直接进入会话时，控制中心页从未挂载，它的 `setVisible(false)` 永远不会被调用，轮询持续到离开会话为止；反之从控制中心进入时，图库索引轮询/相似度结果轮询在后台启动。
- 影响：
  - 隐藏页空转：停在图库时控制中心每 15s 打 4 个 API（含 `jobs.list` 全表过滤）；停在任何会话页时相似度可能无意义地轮询 60s；
  - 语义漂移：`CullingViewModel` 的"隐藏期只登记"分支在 fan-out 后基本不可达，隐藏的挑片页会随 `domainChanged` 做全量 `refreshSilently()`；
  - 文档/注释失真：`SessionWorkspace.swift:38` 称 `isVisible` 是"唯一可见性真相"，但页面钩子会绕过 workspace 直接改 VM（`GalleryView.swift:148`、`SimilarityView.swift:98/107` 等），二者可以不一致。
- 修复建议：把可见性拆成两级——workspace 级 `sessionVisible` 只负责 suspend/shutdown；VM 级 `setVisible(true)` 只由**当前目的地页面**调用。`SessionWorkspace.setVisible(true)` 应只置自身状态（或只对 destination 对应的那一个 VM 置真、其余置假），不要全量置真；`false` 可以保留全量扇出（离会话时必须全停）。若短期不改，至少让 7 个 VM 的 `setVisible(true)` 全部改为"仅恢复自己页面在挂载时的轮询"并从 workspace 侧删除 true 分支。

### P1-3（已确认）删除会话未调用 `SessionStore.endSession`：幽灵会话、workspace 不 close、`lastSessionId` 悬空

- 位置：`UI/Support/SessionStore.swift:97-102`（`endSession` 定义）；`UI/Dashboard/DashboardViewModel+Actions.swift:169-188`（删除实现）；`HOST/RootShellSidebar.swift:83-85`（`lastSessionId` 回退）；`HOST/RootShellWorkspace.swift:121-130`（进入会话即 activate）。
- 证据：
  - `grep -rn "endSession" Sources Tests` 只有 `SessionStore.swift:97` 一处定义，**0 个调用点**；`pin` 同样只在 `TEST/FactoryTests.swift:207` 出现（见 P2-3）。
  - Dashboard 删除成功只做 `lastFullRefreshAt = .distantPast; await refreshAll()`（Actions.swift:181-183），没有任何回调/通知把被删 id 交给 `RootView` 或 `SessionStore`。
  - 侧栏"当前会话" = `navigation.currentSessionId ?? sessionStore.lastSessionId`（RootShellSidebar.swift:84），而 `lastSessionId` 只在 `activate` 写入、只在 `removeWorkspace`/`endSession` 清除。
- 影响：
  - 删除当前/最近会话后，侧栏仍显示"当前会话"；点击它会 `activate` 一个已不存在的会话（workspace 若还在则复用，若已被 LRU 淘汰则工厂新建 7 个 VM），控制中心 `session.get` 报 `SESSION_NOT_FOUND`，页面进入错误态；
  - 该 workspace 的 7 个 VM 永不 `shutdown`（内存与潜在轮询泄漏），`pinned/active/lastSessionId` 也不清；
  - 若删除的正是当前活动会话（从工作台删除时通常不在会话页，但批量删除/深链可以），`activeSessionId` 也可能指向已删会话。
- 修复建议：删除成功后由 Dashboard 回调 shell（`onSessionsDeleted([String])` 或 `GatherAppNotification.sessionsDeleted`），`RootView` 对每个 id 调 `sessionStore.endSession(id)`；若 `navigation.currentSessionId` 命中被删 id，导航回 `.dashboard`。补 `endSession` 的 Store 测试（active/last/pinned 三清 + workspace.close）。

### P1-4（已确认）工作区构造即触发图库首屏取页：进入任何会话页（甚至只登记意图）都会打一次 `photo.list_page`

- 位置：`UI/Gallery/GalleryViewModel.swift:336-358`（init 内 `initTask = Task { await self.loadIfNeeded() }`，355-357）；`HOST/SessionWorkspaceFactory.swift:12-13`（注释自认"gallery 的 init 自带一次首屏补载，因此本类型在 RootView 迁移前不会被调用"）；`UI/Support/SessionStore.swift:44-55`（`workspace(for:)` 用工厂构造）；`HOST/RootShellWorkspace.swift:18-49`（`openFaceAnalyze`/`openCullingConflicts`/`openExport` 等先 `workspace(for:)` 再导航）。
- 证据：
  - `SessionWorkspaceFactory.makeWorkspace` 每次都 new `GalleryViewModel`（Factory.swift:32-80），后者 init 立刻起 `loadIfNeeded()`（GalleryViewModel.swift:355-357），会取会话 + 第一页（200 行）。
  - 首次进入控制中心/人脸/挑片/导出，或从控制中心点"分析已过期→重新分析"（先 enqueue 意图再切页），都会先建 workspace → 触发取页；该页面可能根本不会被打开。
  - LRU 淘汰后重进同一会话会再次触发（`SessionStore.workspace(for:)` 重新工厂构造）。
  - Preview 也受影响：`PreviewFactory.workspace()` 每次调用都新建（`UI/PreviewSupport/PreviewFactory.swift:129-141`），`PreviewShellViews.sessionDetail` 在 body 内创建（`UI/PreviewSupport/PreviewShellViews.swift` 的 `private var sessionDetail`），画布重绘会反复起加载 Task（见 P2-15）。
- 影响：每次会话工作区创建多一次 DB 分页查询与一次会话查询；在"点控制中心意图但没进图库"的路径上是纯浪费；与 Cut 4 "workspace 只做对象图装配、不查库"的注释（SessionWorkspaceFactory.swift:11-13）矛盾。
- 修复建议：删除 init 内的 `initTask`，把首载收敛到页面 `.task`（`GalleryView.swift:117-149` 已存在 `loadIfNeeded()`，并有 `onChange(of: sessionId)` 兜底）；如需保留"VM 重建不滞留 loading"，改由外壳在激活后显式 `loadIfNeeded()`。

### P1-5（疑似）多个 `.confirmationDialog` 堆在同一视图节点：破坏性确认可能只弹最后一个

- 位置：`UI/FaceKeywording/FaceKeywordingView+Confirmations.swift:141-220`（**8 个** `.gatherDestructiveConfirm` 链在同一 `content` 上）；`UI/Similarity/SimilarityView.swift:122-153`（4 个）；`UI/Settings/SettingsView.swift:155-173`（2 个）。对照实现：`UI/Support/GatherCommonViews.swift:294-313`（每个修饰符 = 一个 `.confirmationDialog`）。
- 证据（项目自证）：
  - `UI/Duplicates/DuplicatesView.swift:122-124` 明确注释："成员保留状态确认挂在 ScrollView 节点：与组处置确认（外层 VStack）分属不同视图节点，**避免两个 confirmationDialog 抢同一呈现宿主**"——代码也确实拆成两处（124、150）。
  - `docs/archive/reviews/native-refactor-report.md:237` 记录过同型修复："**重复**：两个 `confirmationDialog` 从同一视图节点拆开"。
  - 现状与上述约定相反：人脸页 8 个、相似度 4 个、设置页 2 个全部挂在同一节点。
- 影响（若 SwiftUI 在 macOS 14 上只保留一个呈现宿主）：除最后一个确认框外，其余 7 个（人脸）/3 个（相似度）/1 个（设置）破坏性入口点确认后**不弹框**，动作不可达；这属于功能级阻断，故按 P1 疑似处理。
- 为什么标疑似：本机无 GUI 自动化，无法目视验证 macOS 14 的多 `.confirmationDialog` 行为；仅能证明"违反项目自己已记录的约束"。
- 修复建议：按 Duplicates 的模式把每个确认拆到不同视图节点（例如每类 pending 各自包一层 `Group`/`background` 容器），或在 `FaceKeywordingView`/`SimilarityView` 用一个统一的 `enum PendingAction` + 单个对话框（把 8 个 pending 收敛为 1 个，与 `CullingView.pendingAction` 同型）。

## 4. P2

### P2-1（疑似，边界）`activate` 先建 workspace、后置 active：容量被 active+pinned 占满时新 workspace 会被自己淘汰，`activeSessionId` 指向不存在的表项
- 位置：`UI/Support/SessionStore.swift:44-55`（`workspace(for:)` 内部先 `enforceCapacity`）、`:62-79`（`activate` 在 `workspace(for:)` 之后才写 `activeSessionId`）、`:120-127`（淘汰候选只排除 active/pinned）。
- 证据：新建的 workspace 在 `workspace(for:)` 期间尚未受保护；`enforceCapacity` 的 `recent.last(where:)` 在 capacity 很小且其余项都被保护时会选中新 id 自己 → `evict` → `close()`。随后 `activate` 仍执行 `workspace.setVisible(true)`（对 closed 是 no-op）并写 `activeSessionId = id`。
- 影响：`activeSessionId` 可以指向不在 `workspaces` 里的 id；`RootShellDetail` 用 `sessionStore.workspaces[sessionId]` 取页面（`HOST/RootShellDetail.swift:57-69,73-89,115`），会一直显示 `loadingPlaceholder`；而 `switchWorkspace` 的相等 guard（`HOST/RootShellWorkspace.swift:126`）会阻止任何重试。
- 可达性：生产 `capacity = 6`（SessionStore.swift:16）且 `pin` 无调用点（P2-3），需要 active+pinned 占满才可能触发，当前**生产不可达**；单测用 `capacity: 2` + `pin` 可复现。
- 修复：`activate` 先写 active（或临时把新 id 加入保护集）再 `enforceCapacity`；`activate` 返回前校验 `workspaces[id] != nil`，否则撤销 `activeSessionId` 并重试一次。

### P2-2（已确认）意图失效策略不按会话限定（staleDomains 的实际对应物）
- 位置：`HOST/RootShellWorkspace.swift:55-89`。`keepsGallery/keepsCullingConflicts/keepsFaceAnalyze/keepsExportRange` 只判断目的地**类型**，不判断 sessionId；只有 `.faceRole` 按会话保留（66-67、78）。
- 证据：`pruneWorkspaceIntents` 只要目的地是任一 `.sessionTab(_, .culling)`，就会保留**所有** workspace 的 `.cullingConflicts`；`.gallery`/`.export` 同理。
- 影响：跨会话切换时，s1 的未消费意图在 s2 的同类页面打开期间不会被清，之后回到 s1 会被 `.task` take 并套用（例如强制"只看冲突"筛选）。窗口很小（页面 `.task` 通常立即消费），但语义上是 stale 的。
- 修复：keep 条件按 `destinationSessionId` 限定（与 `.faceRole` 同型）；或把意图存到"进入时即取走"的外壳临时槽。

### P2-3（已确认）`pin` 与 `endSession` 一个无调用点、一个无接线，`pinnedSessionId` 恒 nil
- 位置：`UI/Support/SessionStore.swift:81-86`、`:97-102`；唯一 `pin` 调用在 `TEST/FactoryTests.swift:207`。
- 影响：`pinnedSessionId` 的"不淘汰"保护在生产中从未启用（当前只靠 active 保护）；`endSession` 的注释描述了一条不存在的清理路径（见 P1-3）。`FactoryTests` 却把 pinned 语义当作已交付验收项。
- 修复：接上 deletion 流程（P1-3）；`pin` 要么由"当前打开会话"写入，要么删除该 API 与相关测试，避免死代码占账本。

### P2-4（疑似）隐藏/关闭时在途请求不被取消，隐藏后仍可能写回一次状态
- 位置：`UI/Gallery/GalleryViewModel+Index.swift:87-99`（`refreshWorkspaceStatus` 只做 `statusRequestID` 代次校验，不查 `isVisible`/`isShutdown`/`Task.isCancelled`）；`UI/ControlCenter/SessionControlViewModel.swift:140-173`（`load()` 同理，只查 `loadGeneration`）；`UI/Gallery/GalleryViewModel+Core.swift:31-48`、`SessionControlViewModel.swift:124-131`（shutdown 只 cancel，不等待在途请求）。
- 证据：`shutdown()` 之后，已经开始的 `provider.workspaceStatus`/`sessionAPI.get` 仍会返回并赋值（写 `workspaceStatus`/`session`），因为回调里没有 `isShutdown` 检查。测试里因此出现"shutDown 快照后计数又 +1"的窗口（§1.3 串行失败）。
- 影响：隐藏/关闭后的最后一次请求不会被取消（隐藏页仍发一次命令），状态可能在关闭后写回；对 UI 用户影响小（页面已销毁），但违反"隐藏页不发命令"的文档承诺，并直接造成 P1-1 的不稳定断言。
- 修复：在 `refreshWorkspaceStatus`/`load` 的响应分支加 `guard !isShutdown, isVisible`（或 `Task.isCancelled`）；`shutdown` 记录代次使旧响应作废。测试端可改为"隐藏后不得**开始**新请求"的确定性断言。

### P2-5（已确认）`switchWorkspace` 被三个入口重复调用（init / onAppear / onChange / task(id:)）
- 位置：`HOST/RootView.swift:85-88`（init）、`:135-138`（onAppear）、`:139-141`（onChange）、`:144-146`（task(id:)）；`HOST/RootShellWorkspace.swift:121-130`。
- 证据：同一目的地变化会同时触发 `onChange` 与 `.task(id:)` 各一次 `switchWorkspace`；非会话目的地会重复 `activate(nil)`（第二次是 no-op）。会话目的地靠 `activeSessionId != sessionId` 早退（RootShellWorkspace.swift:126）。
- 影响：当前幂等、无用户可见错误；但 `.task(id:)` 与 `.onAppear` 完全冗余，增加"两次扇出/两次 intent take"的维护风险（任何一次 guard 被改动都会变成真的双执行）。
- 修复：只保留 `onChange(of: destination)` + 首帧 `onAppear`（或只保留 `.task(id:)`），删除第三入口。

### P2-6（已确认）`ExportView` 先 await 再 take 意图：页面消失窗口内仍会消费 `.exportRange`
- 位置：`UI/Export/ExportView.swift:89-96`：`await viewModel.loadSessionName()` → `workspace.take(.exportRange)` → `applyRangeIntent` → `refreshPlan()`。
- 证据：`.task` 取消不会阻止同步代码继续执行；`loadSessionName` 是异步网络/DB 调用，若期间切走，take 仍会执行并把意图清掉（`SessionWorkspace.take` 取出即清，`UI/Support/SessionWorkspace.swift:117-119`）。
- 影响：控制中心"去导出"在极快切页时丢失范围意图（下次进入导出页是默认范围），症状静默。
- 修复：把 take 提到第一个 await 之前（`GalleryView.swift:117-139` 与 `CullingView+Content.swift:72-90` 已是这个顺序），或 take 后在 `Task.isCancelled` 时回写。

### P2-7（已确认）Face 页两个 `.task`：role 意图与 reload 并发，当前靠幂等兜住
- 位置：`UI/FaceKeywording/FaceKeywordingView.swift:82-87`（take `.faceRole` → `applyRoleFilterFromDeepLink`）与 `:98-109`（`await viewModel.reload()` → take `.faceAnalyze`）。
- 证据：注释 101-105 自认"两个 .task 的启动顺序无保证"，并把 analyze 意图挪到 reload 之后；但 role 意图仍在另一个 `.task`。当前两端的写入（`roleFilter`/`step`）对顺序不敏感（`FaceKeywordingViewModel.swift:276-290,205-227`），所以结果正确。
- 影响：无已确认错误；但同一页两条生命周期入口是脆弱结构，后续任何一端加"重置 roleFilter/step"就会复现 A5 那类静默失效。
- 修复：合并为单个 `.task`：`await reload()` → 依次 take `.faceRole`/`.faceAnalyze` → 应用。

### P2-8（已确认，账本口径）`ViewState` 零生产调用点
- 位置：`UI/Support/ViewState.swift:1-2`（头注释自述"零调用点"）；全仓 grep 只在 `TEST/ViewStateTests.swift` 出现；`LoadPhase` 仍被 4 个 VM 使用（`UI/Support/LoadPhase.swift:13-22`）。
- 证据：`docs/refactor-progress.md:129` 把 `ViewState` 列为 4a-1 的 10 个状态层交付之一；但生产代码没有任何 `ViewState<...>` 属性。
- 影响：不是运行时缺陷，是"交付/账本"偏差：读者会以为 11 个 VM 已切到五态状态机；实际只交付了类型与测试。
- 修复：要么在 Cut 5 前把至少一个 VM（Dashboard/Library 最合适）切到 `ViewState`，要么在 progress/decisions 中改记为"类型储备、未接线"，并把测试标为类型契约。

### P2-9（已确认）`.page(.settings)` 是死路由
- 位置：`HOST/RootShellDetail.swift:44-53`；侧栏条目只有 dashboard/currentSession/library/persons（`HOST/RootShellSidebar.swift:22-46`）；⌘, 与各页"设置"统一 `openSettings()` 打开独立 Settings 场景（`HOST/RootShellOverlay.swift:38-41`、`Sources/GatherApp/GatherApp.swift:85-100`）。
- 证据补充：`selectWeb(.settings)` 只出现在测试（`TEST/RootViewTests.swift:27,86`），侧栏 `SidebarItem.web` 只能由 persons 条目产生（`RootShellSidebar.swift:33-36,57`）。
- 影响：`RootShellDetail` 的设置分支与 `SettingsView` 的 environment 注入路径永远不会在主导航中执行；测试/预览仍可达。属于残留分支（不危险）。
- 修复：删除 `.page(.settings)` 分支与 `WebPage.settings`，或明确它是深链入口并补一条真实入口。

### P2-10（已确认）Settings 页 3 个独立 `.task`；12s 轮询取消后多跑一次
- 位置：`UI/Settings/SettingsView.swift:137-148`：`task { load() }`、`task { checkC1Health() }`、`task { refreshSyncState(); while !Task.isCancelled { try? await sleep(12s); await refreshSyncState() } }`。
- 证据：`try? await Task.sleep` 吞掉 `CancellationError`，随后无条件 `await refreshSyncState()`；取消只在下一轮 `while` 条件处生效 → 页面消失后仍会多打一次 `syncStatus`。
- 影响：离开设置窗口/页面时多一次查询；与 P2-4 同类（隐藏页最后一次命令）。
- 修复：`do { try await Task.sleep(...) } catch { return }`，或在 refresh 前检查 `Task.isCancelled`。3 个 `.task` 可以合并为 1 个（load → health → loop），减少"页面重建时的启动顺序"不确定面。

### P2-11（已确认）页签切换销毁页面，`@State` 重置语义只对 Similarity 做了迁移
- 位置：`HOST/RootShellDetail.swift:120`（`.id("session-tab-…")` 使每次页签切换重建页面）；残留 `@State`：`UI/Culling/CullingView.swift:31-34`（`pendingAction/conflictChoices/compareCount/faceAlign`）、`UI/FaceKeywording/FaceKeywordingView.swift:26-38`（8 个 pending + `visibleClusterCount/hoveredClusterId/stepGateHint`）、`UI/ControlCenter/SessionControlView.swift:40-42`、`UI/Export/ExportView.swift:10-17`。
- 证据：Similarity 明确把"跨页签保留"的展开态搬进 VM（`UI/Similarity/SimilarityView.swift:38-42` 注释 + `SimilarityViewModel.swift:233-241`），说明项目把"页签切换保留浏览态"当作产品语义；挑片的逐字段冲突裁决 `conflictChoices`、对比张数/对齐开关仍是页内 `@State`，切页签即丢。
- 影响：用户在挑片页勾了一半冲突裁决、切去图库再回来，草稿清空（无提示）；`compareCount/faceAlign` 等查看器偏好也每次重置。是否算缺陷取决于产品预期，但当前只有 Similarity 有注释说明，Culling 没有。
- 修复：把需要跨页签保留的状态迁到对应 VM（与 Similarity 同型），或在 Culling 注释/文档里明确"页签切换重置"是有意语义并补测试。

### P2-12（已确认）窗口标题双源：图库页在会话未加载时会把标题顶成"图库"
- 位置：`HOST/RootShellToolbar.swift:53-58`（外壳 `windowTitle` 读 `SessionWorkspace.sessionName` 缓存）；`UI/Gallery/GalleryView.swift:98`（页面自己 `.navigationTitle(viewModel.session?.name ?? l10n("图库"))`）。
- 证据：`viewModel.session` 由图库 VM 的 `loadIfNeeded` 异步填充；缓存标题由 workspace 的 `SessionAPI.get` 异步填充（`UI/Support/SessionWorkspace.swift:97-107`）。两者独立、完成时刻不同；会话加载失败/未完成时，页面 title 覆盖外壳 title。
- 影响：会话名短暂显示为"图库"；若图库 VM 的 session 读取失败，整个会话停留期间窗口标题都是"图库"（而 workspace 缓存可能已有名字）。
- 修复：页面在 `session == nil` 时不要设 `.navigationTitle`（或回退到 `workspace.sessionName ?? ""`），统一由外壳标题兜底。

### P2-13（已确认）`sessionName` 缓存失败后不重试（同一次会话停留期间）
- 位置：`UI/Support/SessionWorkspace.swift:97-107`；唯一调用点 `HOST/RootShellWorkspace.swift:127-129`；早退 guard `:126`。
- 证据：`loadSessionNameIfNeeded` 只在 `activate` 后调用；`switchWorkspace` 在 `activeSessionId == sessionId` 时直接 return。若第一次 `SessionAPI.get` 失败（保留 nil），再次进入同一会话只有先离开（`activate(nil)`）再回来才会重试。
- 影响：窗口标题退化为 "Gather"（`RootShellToolbar.swift:56`）直到离开会话；无其他功能影响。
- 修复：失败时记 `nameLoadFailed` 并在下次 `onAppear`/事件刷新时重试；或订阅会话变更事件更新缓存。

### P2-14（已确认 init 副作用；重算为疑似）`RootView.init` 在视图构造期产生副作用；Scene body 重算可能重复构造 3 个 VM
- 位置：`HOST/RootView.swift:62-89`（init 里 `sessionStore.activate(...)`、构造 Dashboard/Library/Persons VM）；`Sources/GatherApp/GatherApp.swift:26-47`（Scene body 读 `bootstrap.languageStore.language/l10n`，语言切换会使 WindowGroup content 重算）。
- 证据：初始目的地为会话时（测试/预览注入 `navigation`），init 即 `activate` → 7 VM `setVisible(true)` → 起轮询（确定）；`@State(initialValue:)` 会丢弃重算时新建的 3 个 VM（`RootView.swift:75-81`），但构造已完成。Scene body 是否在语言切换时真的重跑 WindowGroup content，取决于 SwiftUI 对 Scene 值的重算策略，本机无 GUI 无法验证，故重算部分标疑似。
- 影响：正常启动（dashboard）无；语言切换会多构造 3 个 VM（无副作用，纯浪费）；预览/测试里 init 是可观察的副作用点，和"View init 必须纯"的直觉冲突。
- 修复：把初始目的地登记移出 init（交给 onAppear/task 的 `switchWorkspace`），VM 构造改为 `@State` 的惰性 holder 或 `@StateObject` 等价物。

### P2-15（已确认，仅 DEBUG）PreviewSupport 无真实业务副作用，但有进程级内存/观察者/Task 副作用
- 位置：`UI/PreviewSupport/PreviewFixtures.swift:937-964`（`PreviewThumbnailSeeder.seedOnce` 写全局 `PhotoThumbnailCache`）；`PreviewFactory.swift:16-23`（每个 Preview 入口调用）；`PreviewFactory.swift:129-141`（每次调用新建 workspace → 7 VM）；`PreviewShellViews.swift` 的 `sessionDetail` 在 body 内 `PreviewFactory.workspace()`；`UI/Support/LanguageStore.swift:36-63`（默认 NotificationCenter 注册 observer，token 丢弃、不移除）。
- 证据：
  - 替身的命令方法全部 throw、查询返回固定 fixture（`PreviewAPIs.swift:6-18`）；`PreviewCaptureOne.checkHealth()` 刻意返回 `.failure(.notRunning)` 以避免真实 `osascript`（`PreviewAPIs.swift:390-395`），`preflight` 全通过但不执行脚本。
  - 但 `GalleryViewModel.init` 的 `initTask`（P1-4）会在预览中真的起 Task；`PreviewShellViews` 每次 body 求值都新建 workspace（含 7 VM + 一次 `loadIfNeeded`），预览画布重绘会反复起任务。
  - `seedOnce` 只写进程内缓存、不落盘（注释 930-935），但会污染与真实解码共享的 `PhotoThumbnailCache` 键空间（同一进程内跑 App 预览时）。
  - `LanguageStore(language:)` 在预览里用默认 `.default` NotificationCenter，observer 永不移除（每个 preview 实例一个）。
- 影响：不影响生产（`#if DEBUG`）；Preview 打开多个页面时会出现后台取页 Task、观察者累积、缩略图缓存被占位色块覆盖（预览进程内）。
- 修复：`PreviewFactory.workspace()` 缓存到 static；`PreviewShellViews` 的 workspace 移到 `@State`；`LanguageStore` 注入独立 `NotificationCenter()`（测试已是这个做法：`TEST/FactoryTests.swift:138-140`）；`seedOnce` 之后清理或改用独立缓存命名空间。

### P2-16（已确认，文档口径）`SessionWorkspace.isVisible` 的双真相与"7 VM 扇出"注释
- 位置：`UI/Support/SessionWorkspace.swift:38`（"唯一可见性真相"）、`:7-10`（"页面只在自己的 onAppear/onDisappear 里调对应 VM 的钩子；会话区域进出由外壳调 workspace.setVisible"）。
- 证据：页面钩子直接调 `vm.setVisible`（GalleryView.swift:148/157、SimilarityView.swift:98/107/110、SessionControlView.swift:161/165/168、CullingView+Content.swift:96/99），不经过 workspace；`workspace.isVisible` 只在 `activate`/`close` 变。
- 影响：`workspace.isVisible` 不能代表任一 VM 的实际可见性；`docs/refactor-progress.md:129` 的"7 VM setVisible"读起来像逐页语义，实际是全会话开。与 P1-2 同源，单独列出作为文档/接口口径问题。
- 修复：P1-2 落地时同步改注释与台账；`isVisible` 要么删掉，要么改名为 `isSessionActive`。

## 5. 已确认 vs 疑似

| 编号 | 级别 | 状态 | 一句话 |
| --- | --- | --- | --- |
| P1-1 | P1 | 已确认（实测） | CI app 测试无 --no-parallel；并行 2/2 红，串行 1/1 红（不同用例），绿基线不成立 |
| P1-2 | P1 | 已确认（代码路径） | workspace.setVisible(true) 全量扇出 → 未挂载页面轮询/刷新 |
| P1-3 | P1 | 已确认（grep 0 调用点） | 删除会话不 endSession → 幽灵会话 / workspace 不 close |
| P1-4 | P1 | 已确认（init 内起 Task） | 建 workspace 即 photo.list_page，与打开哪页无关 |
| P1-5 | P1 | **疑似**（无 GUI） | 8/4/2 个 confirmationDialog 同节点，可能只弹最后一个 |
| P2-1 | P2 | 疑似（生产不可达） | activate 先建后置 active，小容量下自淘汰 |
| P2-2 | P2 | 已确认 | 意图失效不按会话限定（staleDomain 意图） |
| P2-3 | P2 | 已确认 | pin/endSession 死代码 |
| P2-4 | P2 | 疑似 | 隐藏/关闭后在途请求不取消，仍写一次状态 |
| P2-5 | P2 | 已确认 | switchWorkspace 三入口重复 |
| P2-6 | P2 | 已确认 | Export 先 await 再 take 意图 |
| P2-7 | P2 | 已确认 | Face 页两个 .task，靠幂等兜住 |
| P2-8 | P2 | 已确认 | ViewState 零生产调用点（账本口径） |
| P2-9 | P2 | 已确认 | .page(.settings) 死路由 |
| P2-10 | P2 | 已确认 | Settings 3 个 .task；12s 轮询取消后多跑一次 |
| P2-11 | P2 | 已确认 | 页签切换重置 @State（Culling 草稿等） |
| P2-12 | P2 | 已确认（双源）/影响待 GUI | 图库页标题覆盖外壳缓存标题 |
| P2-13 | P2 | 已确认 | sessionName 失败不重试 |
| P2-14 | P2 | 已确认 init；疑似重算 | RootView.init 副作用 + 语言切换可能重建 3 VM |
| P2-15 | P2 | 已确认（仅 DEBUG） | Preview 全局缓存/观察者/Task 副作用 |
| P2-16 | P2 | 已确认（口径） | isVisible 双真相与注释不符 |

## 6. 与账本/文档的口径偏差

1. `docs/refactor-progress.md:129` 把 `ViewState` 列为 4a-1 状态层交付；实际 0 生产调用点（P2-8）。建议在 progress 中改记为"类型 + 测试，未接线"，避免下一刀误判已完成。
2. `docs/refactor-progress.md:129` 的"7 VM setVisible/shutdown"与 `UI/Support/SessionWorkspace.swift:7-10,38` 的"页面钩子/唯一真相"描述，与 P1-2/P2-16 的实际语义不符；建议在修复 P1-2 时同步改注释与台账。
3. `docs/final-report.md:38,72,80` 的 app 绿基线明确带 `--no-parallel`，而 `.github/workflows/ci.yml:86-87` 未带；这是 P1-1 的文档-实现漂移（不是 plan drift，是验收命令漂移）。
4. 任务书中提到的 `staleDomains` 在仓库中不存在；本报告以 `pruneWorkspaceIntents`（P2-2）与 VM 内 `pendingDomainRefresh`/`deferredRefreshWhileHidden`（P1-2 证据）对应。

## 7. 结论与建议顺序

**结论**：Cut 4 的"错误载体/渲染期本地化/View 拆分"三条主线静态质量达标；**不通过**的是生命周期语义：workspace 可见性扇出把页面级启停扩大成会话级，删除会话没有清理状态层，workspace 构造带隐藏 I/O；验收门禁（CI）当前红。没有 P0，但 P1-2/P1-3/P1-4 会在真实使用中表现为"后台空转、幽灵会话、无谓取页"，P1-1 会阻断合并。

建议顺序（每步都可独立验收）：

1. **P1-1**：CI 加 `--no-parallel`，同时把两条生命周期断言改为确定性（可控时钟/闸门）。先让门禁可信，再改代码。
2. **P1-3**：删除回调 → `endSession` + 导航回退；补 Store 测试（active/last/pinned/close）。
3. **P1-2**：拆两级可见性；页面钩子成为 `true` 的唯一来源；补"隐藏页 0 请求"的自动化断言（可用 stub 计数）。
4. **P1-4**：删 `GalleryViewModel.init` 的 `initTask`，首载收敛到页面 `.task`；确认 `onChange(of: sessionId)` 兜底仍覆盖 VM 重建。
5. **P1-5**：拆 confirmationDialog 或收敛为单 `pendingAction`；无 GUI 也应按项目既有约定（DuplicatesView 注释）先改。
6. P2 按 P2-3（死代码清理）→ P2-5/P2-6/P2-7（入口幂等与意图顺序）→ P2-11/P2-12/P2-13（页面状态与标题）→ 其余。

**未做/不可做**：本机无 GUI 自动化，未做 Preview 目视、页签/弹窗/灯箱交互验收；P1-5、P2-1 的运行时行为只能按代码与项目历史约定推断，已在正文标"疑似"。

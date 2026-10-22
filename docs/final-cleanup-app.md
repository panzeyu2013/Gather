# App 层收尾清理报告（gather-app）

> 范围：`desktop/native/gather-app/Sources/**`、`Tests/GatherAppTests/**`（仅删除符号同步）。
> core / Package / scripts / 其它 docs 未改。本文件是任务书第 4 条要求的交付物（docs 唯一落盘文件）。
> 口径：先 grep 全仓（`desktop/**` 源码 + Tests，含 core 交叉引用）确认**代码零引用**才删；
> 动态字符串、协议/AppKit 覆写、测试钉住的契约一律保留。行为不变，测试声明数不变。

## 1. 删除清单（Sources）

| # | 符号 / 位置 | 行数 | 引用证据 |
|---|---|---|---|
| 1 | `DashboardViewModel.deleteSessionSilently` — Dashboard/DashboardViewModel+API.swift | -7 | 全仓 0 调用（仅 docs 历史评审提及） |
| 2 | `SessionStore.pin` + `pinnedSessionId` + evict/enforceCapacity/endSession 的 pinned 分支 — Support/SessionStore.swift | -16 | 生产 0 调用；状态恒 nil（仅测试调用） |
| 3 | `.page(.settings)` 死路由：`WebPage.settings`（case/title/systemImage）+ `RootShellDetail` 渲染分支 + `isSettings` — RootShellNavigation.swift / RootShellDetail.swift | -14 | 设置是独立窗口（⌘, / `openSettings()`），侧栏从不产生 `.settings`；生产 0 构造点 |
| 4 | `PreviewData.faceAnalysisResult`、`PreviewData.exportResult` — PreviewSupport/PreviewFixtures.swift | -14 | DEBUG 预览夹具 0 引用 |
| 5 | `L10nStringCache.resetStats()` — Support/L10n.swift | -8 | 0 调用（`stats` 仍被测试使用，保留） |
| 6 | `DisplayDateFormatters.timeWithSeconds` — Support/DateFormatting.swift | -10 | 0 调用（C1 胶囊走自己的格式化） |
| 7 | `SimilarityViewModel.noteResultParams` — Similarity/SimilarityViewModel.swift | -5 | 0 调用（`resultParams` 直接赋值，`isResultStale` 保留） |
| 8 | `SettingsView.downloadButtonTitle` — Settings/SettingsView+Model.swift | -13 | 0 调用（真实 UI 走 `installBlock` 的 downloadPhase 分支） |
| 9 | `GalleryView.pendingPhotoIds` — Gallery/GalleryView+Content.swift | -3 | 0 调用 |
| 10 | `GatherGlass.isAvailable` / `gatherSecondaryActionButton()` / `gatherConcentricContainer(cornerRadius:)` — Support/GatherGlass.swift | -32 | 0 调用（仅 docs 归档评审提及） |
| 11 | `GatherTheme` 零引用兼容别名：`primaryHover`、`textPrimary`、`formLabelWidth` 与 `Color.gatherAccent/gatherWindowBackground/gatherContentBackground/gatherBackgroundSecondary/gatherTextPrimary`；`Color.gatherPrimary/gatherBackground/gatherSurface/gatherBorder` 随同名块删除 — Support/GatherTheme.swift | -27 | 每个符号全仓 0 引用（仍有用的 primary/primarySoft/background/backgroundSecondary/surface/border 保留） |
| 12 | `GatherBadge` 旧色板 12 个常量 + `init(_:foreground:background:)` + 私有 `init(approximating:)` — Support/GatherBadge.swift | -29 | 0 调用；`Color(hex:)` 仍被 CullingDisplayFormat 使用，已保留 |
| 13 | `JSONValue.decoded(as:)` — Support/JSONValueDecoding.swift | -7 | 0 调用（`JSONValue.init(from:)` 仍用，保留） |
| 14 | 死本地化键 `下载中…`/`下载失败`/`已安装`/`自动下载模型` — Resources/en.lproj/Localizable.strings | -4 | 第 8 项删除后 en 表孤儿键（LocalizationParityTests 反向 parity 报红）；zh 表本就无这 4 键 |

### 重复 helper 收敛（唯一新增文件）

- `private func requireSessionId` 在 6 个 Live API 中逐字重复 6 份（Duplicate / Face / Similarity / Culling / Metadata / Export，各 12 行）。
- 收敛为 `Sources/GatherHost/APIs/LiveAPIInput.swift`（+21 行，`enum LiveAPIInput.requireSessionId`），6 处改为调用；错误码、`field`、reason 文案逐字不变。
- 净行数：-78（6×12 份实现删 66 行 + 调用点改写 + 新增 21 行）。

### 旧注释清理（不改变语义）

- `Support/LoadPhase.swift`：两处 `ViewState.failed(CommandError)` / `ViewState.error` 引用（ViewState 已在 CL-04 删除）。
- `Support/CommandError.swift`、`Support/SessionStore.swift`、`Support/RootShellDependencies.swift`：删除「零调用点」过期描述。
- `GatherTheme` 兼容别名块头「400+ 调用点」、`GatherBadge`「Badge.module.css 色板」注释随死代码一并删除。

## 2. 行数账（`git diff --numstat`，仅本会话未暂存改动）

- Sources：**+32 / -291**（含 6 文件调用点改写；另有新增文件 LiveAPIInput.swift +21 未计入 numstat）。
- Tests：**+32 / -33**（FactoryTests / RootViewTests 的符号同步与用例迁移）。
- 合计：**-324 行删除 / +64 行改写 / +21 行新增文件**，净 **-239 行**；删除文件 **0** 个，新增文件 **1** 个（去重 helper）。

## 3. 保留候选及原因

| 候选 | 结论 | 原因 |
|---|---|---|
| `pin` 的删除 | 已删 | 生产 0 调用；3 个测试迁移为 active 保护语义（用例数不变 616），LRU 淘汰语义仍有覆盖 |
| `RouterCommandError` / `BridgeError` / `APIError.emptyResponse` | 保留 | 错误展示漏斗（APIErrorPresentation / GatherLocalization / CommandError）按文档约定支持历史错误载荷，测试钉住；删除会改动漏斗语义 |
| `SessionWorkspace.isClosed`、`CullingViewModel.apply*ForTesting`、`GalleryViewModel.default*PollInterval`、`FaceModelPathIssue.templateKeys` | 保留 | 生产 0 引用但被测试/本地化 parity 钉住，属测试可观测契约 |
| `map` / `mapAsync`（11 份同名私有实现） | 保留 | 每份的 `Self.translate(error)` 域错误映射不同；抽通用需引入 translate 闭包，风险高于收益，记入残余 |
| `FaceNotice` / `SimilarityNotice` / `CullingNotice`、两个 `PendingRetry.scopeText`、两个 `reportCancellation` | 保留 | 结构相同但分属不同公开类型/页面文案模板；合并需改公开 API 或跨页模板，超出「确认无用」口径 |
| `PreviewShellViews` 的 settings 预览项 | 保留 | DEBUG-only 组件展示（#Preview 数不变），不是生产路由 |
| `WebPage` 只剩 `persons` 一个 case | 保留 | 侧栏选中语义与 `Destination.page(WebPage)` 契约仍需该类型；折叠成 `.persons` 是 API 改名，收益低 |
| AppKit 覆写（`applicationShouldTerminate` / `hitTest` 等） | 保留 | 框架动态调用，非死代码 |

## 4. 验证数字（实跑，2026-10-22）

改动期间 core 有并发迁移（`GatherDomain/Services/CaptureOneSyncState.swift` 一度缺文件），已恢复；以下为恢复后实测。

| 项 | 结果 |
|---|---|
| app 串行（`swift test --no-parallel`） | **616 tests / 68 suites passed**，exit 0（基线同为 616/68, 16.829s → 16.758s） |
| app 并行 ×3（默认并行） | 3 次均 **616 / 68 passed**，exit 0（7.843s / 7.921s / 7.907s） |
| core build | `Build complete! (6.29秒)`，exit 0 |
| 门禁 9 条 | `check-no-legacy`、`check-layering`、`check-duplicate-symbols --strict`、`check-select-star`、`check-preview-surface --strict`、`check-test-catalog --strict`、`check-cleanup-ratchet`、`check-docs --strict`、`check-test-catalog --self-test` 全部 exit 0 |

命令（与 DEVELOPMENT.md 同口径，仅补 DSH 沙箱所需 flags）：

```bash
cd desktop/native/gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache \
  swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch --no-parallel
# 并行：去掉 --no-parallel，连跑 3 次
```

未执行 / 限制：无 GUI 人工验收（本环境无自动化）；`build.sh` 未作为本轮判据。

## 5. 残余（下一刀建议）

1. `Live*` API 的 `map` / `mapAsync` / `requireNonBlank`（4 份，trimming 语义有差异）仍重复；建议后续以 `LiveAPIInput` 为落点统一（需逐个核对域错误映射）。
2. `docs/review-remediation-report.md` 第 51 行仍把 `deleteSessionSilently`、`pin`、`ViewState` 注释列为未清项；本轮已清，文档（白名单外）待主 agent 记账。
3. `PreviewShellViews` 的 settings 预览项保留：若后续统一「设置只走独立窗口」，预览侧栏也应同步（不影响生产）。

# 测试体系审计与优化（2026-10-29）

> 范围：`desktop/native/gather-core/Tests`（150 个文件）、`gather-app/Tests`（88 个文件）、
> `GatherTestSupport` 与 `scripts/test.sh` / `check-test-catalog.sh` / CI 测试步骤。
> 机器：Apple Silicon（18 核 / 48GB）、macOS 26.0.1、Swift 6.4、Debug、执行器 18 workers。
> 口径：测试耗时取 Swift Testing 汇总行（不含构建）；CPU/RSS 取 `/usr/bin/time -l` 的
> `--skip-build` 单次运行（只统计测试进程，不含编译）。覆盖率用 `--enable-code-coverage`
> + `llvm-cov report`，行覆盖（line coverage）为主。数字随机器负载浮动。

## 1. 结论

| 指标 | 优化前 | 优化后 | 变化 |
| --- | --- | --- | --- |
| core 用例 / 套件 | 1,433 / 214 | **1,443 / 216** | +10 / +2（补模型初审落库与编排） |
| core 测试耗时（串行 → 拆分并行） | 13.31s | **1.42s**（主批 1.23s + 状态批 0.19s） | **−89%（6.5~9.4×）** |
| app 用例 / 套件 | 762 / 89 | 762 / 89 | 持平（改并行） |
| app 测试耗时 | 12.47s | **2.68s** | **−78%（窗口 SIGSEGV 修复后）** |
| 默认套件总耗时 | 25.8s | **4.1s** | **−84%** |
| core 测试进程峰值 RSS | 360MB（串行） | 600MB（并行） | +240MB（内存换墙钟，见耗步行） |
| app 测试进程峰值 RSS | 199MB | 233MB | +34MB（内存换墙钟，见耗步行） |

- **两包都并行**。app 整包并行的 SIGSEGV 已定位到真实挂载用例的 `NSWindow.close()`
  （SwiftUI/KVO 二次 release），改为 `orderOut()` 后 50 次并行重复全绿；见 §4。
- 默认套件仍是“正确性”层；模型/Vision/2GB 备份/20k 性能门继续由 opt-in 的
  `GATHER_MODEL_TESTS` / `GATHER_*_PERF` 套件覆盖（原 nightly workflow 已于 2026-10-29 移除），
  未借优化之名删除。
- 覆盖率不是“全仓一个数”：core **83.41%** 行覆盖，app 源码 **46.59%**（其中非 View
  逻辑 **67.96%**、SwiftUI View/Preview **32.59%**）。缺口按“逻辑 / 视图 / 外部验收”分开记账。

## 2. 并行拆分（`scripts/test.sh`）

core 的 1,443 例里只有 4 个套件依赖**进程级**状态：

| 套件 | 为什么不能并行 |
| --- | --- |
| `LoggerTests` | 替换 `GatherLogger.output`/`minimumLevel`，逐行计数 |
| `TraceLoggingTests` | 同上，按 job/delivery trace 过滤 |
| `LogFileSinkTests` | 替换 `GatherLogger.output` 落盘 |
| `ReadPoolTests` | 改 `DBConnection.slowTransactionThresholdMilliseconds` 全局阈值 + logger |

证据：同一次 `--parallel` 覆盖率运行里出现 2 个假红（`ReadPoolTests.slowTransactionLogs`
收不到自己写的 warn；`TraceLoggingTests.jobRunningCancelTerminalLogsTrace` 丢帧），
而把 4 个套件拆到第二个进程串行跑后 30 次重复全绿。因此：

app 侧没有进程级 logger 类套件；并行安全由 `AppLanguageLock`（语言槽）与
`WorkspaceVisibilityTests` / `CullingGridPerfTests` 的 `.serialized` 保证。

```bash
./scripts/test.sh core   # 主批 --parallel（--skip 四套件）+ 第二遍 --no-parallel --skip-build
./scripts/test.sh app    # --parallel
./scripts/test.sh all    # 两包
```

CI 的 `gather-core` / `gather-app` step 已改为调用该脚本；README / DEVELOPMENT 同步。

## 3. 覆盖率（行）

> 采样口径：本节数字来自 2026-10-29 tests 分支（`79e688ef`，基于 `d70343e5`）的全量
> `--enable-code-coverage` 运行；合入 main 的源码改动后未整体重测。`ModelReviewRepo` /
> `ModelReviewService` 的用例数在合并后为 5/5（`latestByAssetFile` 已删），百分比按该次
> 快照理解；需要当前值请按 §8 重跑。

### 3.1 模块

| 包 / 模块 | 行数 | 覆盖 |
| --- | ---: | ---: |
| GatherApplication | 21,537 | 86.69% |
| GatherPersistence | 15,465 | 86.95% |
| GatherAnalysis | 3,436 | 87.78% |
| GatherDelivery | 4,853 | 71.48% |
| GatherProtocol | 3,779 | 61.50% |
| **core 合计** | **49,070** | **83.41%** |
| app 逻辑（非 View/Preview） | 22,494 | 67.96% |
| app SwiftUI View + Preview | 34,351 | 32.59% |
| **app 源码合计** | **56,845** | **46.59%** |

### 3.2 主要缺口（按风险排序）

1. **交付崩溃恢复**：`DeliveryCleanupFlow+Finalize` 55.2%、`DeliveryReplayFlow` 56.4%、
   `DeliveryCleanupFlow+Cleanup` 64.5%、`DeliveryMirrorWriter` 64.2%、`DeliveryStateWriter`
   66.4%。主路径有测试，回放/收尾的异常分支仍有空档，属于 P0 恢复语义。
2. **维护/备份**：`MaintenanceService` 47.5%、`RestoreSupport` 65.3%、`BackupStore` 68.1%；
   2GB 备份门只在 opt-in 门，PR 只覆盖小库路径。
3. **人脸约束/写回收敛**：`FaceKwService+Constraints` 47.8%、`WritebackService+Converge`
   48.1%、`WritebackService+Recover` 54.6%；约束拒绝与收敛分支多为集成路径。
4. **模型初审**：审计前 `ModelReviewRepo` **0%**、`ModelReviewService` **10.6%**；
   本轮补 10 例后为 **95.3% / 53.9%**（`latestByAssetFile` 已在 main 收口删除，对应 1 例随合并去掉）。
   剩余缺口集中在 Vision 人脸/审美分支
   （默认套件不跑 Vision，由手动 opt-in 的 `GATHER_MODEL_TESTS` 覆盖）。
5. **app 启动与监视**：`AppBootstrap` 1.3%（472 行）、`SessionDirectoryMonitor` 9.6%
   （387 行）、`GatherAppDelegate` 23.5%；`SettingsViewModel+C1Health/Loading/Download/Sync`
   0~6.7%、`ExportViewModel+Delivery` 11.3%。这些是宿主逻辑，不是纯 View。
6. **协议输入 DTO**：`FaceInputs` / `MetadataTemplateInputs` / `PhotoInputs` /
   `SimilarityInputs` 在 core 侧 0%，app 侧 34~37%；属于 app/host 构造的 Decodable 入参，
   不是 core 单测的主战场，但 `MetadataTemplateInputs` 两侧都低，建议随模板 UI 验收补一条
   构造/解码往返。

### 3.3 视图空白是策略而非遗漏

`PreviewSupport` 0% 与 `DashboardView`/`LightboxView` 等 0% 属于手工验收面
（`docs/DEVELOPMENT.md` 的“手工检查清单”）；对应 ViewModel 多为 80~99%。
把 View 行覆盖直接当成“测试不足”会误导预算，本审计按逻辑/视图分开记账。

## 4. app 并行 SIGSEGV：根因与修复

### 4.1 现象与证据

修复前 `--parallel`（workers 2/4/8/默认）**4/4 稳定复现**：所有测试都打印 passed，
进程在收尾时退出码 1；`.ips` 栈为
`objc_autoreleasePoolPop → objc_release`（EXC_BAD_ACCESS，主线程 Swift 并发 job）。

用 `NSZombieEnabled=YES NSAutoreleaseFreedObjectCheckEnabled=YES` 复跑，得到
`*** -[NSKVONotifying_NSWindow release]: message sent to deallocated instance 0x…`
（SIGTRAP）。二分确认：`--parallel --skip WorkspaceVisibilityTests` 3/3 全绿，
说明触发点是该套件的**真实挂载窗口**。

### 4.2 根因

`WorkspaceVisibilityTests.mountedSessionPageDrivesPageVisibility` 用 `NSHostingView`
承载 `GatherSessionPage`，再挂到真实 `NSWindow` 验证 `onAppear/onDisappear`。
旧代码在收尾时调 `window.close()`：

- SwiftUI/AppKit 对窗口有 KVO 观察（`NSKVONotifying_NSWindow`），`close()` 触发
  关闭通知/释放；
- 观察者/自动释放池随后 drain 时仍向已 dealloc 的窗口发 `release` →
  `objc_release` 访问非法地址；
- 串行时池的 drain 时序恰好错开，并行时被放大到**每次必现**（进程退出阶段）。
`isReleasedWhenClosed = false` 单独无效——二次释放来自 KVO/autorelease，
不是 `close()` 自身的 release。

### 4.3 修复与验证

- 窗口只做宿主：`alphaValue = 0`、无阴影、`ignoresMouseEvents`，并加
  `#expect(window.alphaValue == 0)` 防回退到可见窗口；
- 保留 `orderFront` 以维持 macOS 14~26 的 appearance 回调语义，但把
  `window.close()` 改为 `window.orderOut(nil)`（`isReleasedWhenClosed = false`，
  窗口由 ARC 释放）；套件与 `CullingGridPerfTests` 均加 `.serialized`。
- 同时修了一个并行才暴露的测试竞态：`CullingViewModelAPITests.updateUsesTypedInput…`
  断言 `undoOperation.id == 9`，但 detached `refreshSilently` 可能在 update 之后落地，
  用 stub 的空 history 覆盖本地 prepend（实测 50 次中 1 次红）。夹具改为让 history
  快照也包含 op 9，与真实 service 一致。

验证：修复前并行 **15/15 失败**（含 skip-build 与完整构建）；修复后
**50/50 并行全绿**（2.6~3.8s），`NSZombie` 5/5 无 deallocated 日志，
`--skip WorkspaceVisibilityTests` 3/3 绿，完整 app 762/89 通过。
app 并行测试进程 RSS 233MB / user 3.6s（串行 199MB / 3.5s），墙钟 11.1s → 2.7s。

### 4.4 测试期间的可见窗口（2026-10-29 复核）

用户反馈“测试时偶尔弹出画面”。逐项扫描 `NSWindow` / `orderFront` / `NSHostingView` /
`NSOpenPanel` 后确认：**唯一会在默认 app 套件里出现在屏幕上的，是真实挂载用例的
宿主窗口**。

| 位置 | 窗口 | 何时运行 | 用途 | 是否必要 |
| --- | --- | --- | --- | --- |
| `WorkspaceVisibilityTests.mountedSessionPageDrivesPageVisibility` | 640×480 内容（frame 640×512）的 `.titled` NSWindow + `NSHostingView`；旧实现 `orderFront` 且 alpha=1、收尾 `close()` | 每次 app 测试 | 验证 `GatherSessionPage` 的 SwiftUI `onAppear/onDisappear` 真的调用 `workspace.setPageVisible` | 集成断言必要；**可见窗口不必要** |
| `CullingGridPerfTests.gridWindowFirstFrame` | 1,600×1,000 borderless，alpha=0，`orderBack` | 仅 `GATHER_UI_PERF=1`（手动 opt-in） | 真实 NSWindow 首帧 800ms p95 门 | 性能门必要；窗口已不可见 |
| `LayoutBudgetTests` | 无窗口，只有 `NSHostingView.fittingSize` | 每次 app 测试 | 最小窗口/页面宽度预算 | 不产生窗口 |

处理：
- 真实挂载窗口改为 `alphaValue = 0` + 无阴影 + `ignoresMouseEvents`，保留
  `orderFront` 以维持 macOS 14~26 的 appearance 回调语义；收尾 `close()` → `orderOut()`
  （见 §4.2）；并加 `#expect(window.alphaValue == 0)` 防止回退。
- 性能门窗口补上 offscreen / 无阴影 / transient 设置（其隔离运行 2 例通过，
  p95 分别为 38.5ms / 31.9ms）。
- 用 `CGWindowListCopyWindowInfo` 在整包 app 测试期间采样：只出现
  `swiftpm-testing-helper` 的窗口（内容 640×480 / frame 640×512），alpha=0；
  没有 NSOpenPanel/NSSavePanel/NSAlert。
- 测试里没有任何地方调用文件选择器或系统弹窗；`AppCommandCenterTests` 的
  `importFolder` 是安装 no-op handler，不会触发面板。

结论：**不要删除这个真实挂载用例**（它守住 SwiftUI 生命周期接线，单测替代不了）；
只需保持窗口不可见。后续新增 UI 集成测试同样遵守“最多 alpha=0 的宿主窗口”。

## 5. 重叠审计

- 审计时 2,195 条声明（补 10 例后 2,205），显示名/函数名重复仅 **7** 组，且都是不同仓储/套件的同名方法
  （如 `getUnknownReturnsNil`、`listOrdersByUpdatedAtDescending`），不是复制。
- 归一化函数体完全相同的测试 **2 组**（抽检分别是不同层的同一格式化路径与同一模板
  行为，不是整例复制）；4-token shingle MinHash
  相似度 ≥0.72 的测试对 **42 组**，抽检均为“同一行为的不同边界”（如 cleanup 的
  applied/finalize 两阶段、undo 星级守卫的 4 种盘上状态），没有可安全删除的整例。
- 跨文件逐字相同的 helper 体 **28 组**：`jsonKeys` ×11（Protocol 契约）、
  `TestWorkspaceGalleryProviderStub` ×4、`waitUntil` ×3（core services）、
  `NoopXMP` ×3。它们不重复执行用例，但增加维护面；建议下一步收进
  `GatherTestSupport` / 单个 `ProtocolTestSupport.swift`，本轮未动以控制 diff。
- 跨层“同行为”覆盖（Service ×95 例 / Live API / ViewModel）是**有意的分层防线**：
  同一输入在持久层、编排层、UI 状态层各断言一次，删除会降低定位能力；不建议按名字去重。

## 6. 本轮改动

| 改动 | 收益 |
| --- | --- |
| 新增 `scripts/test.sh` + CI 改用 | core/app 都并行；本地/CI 同口径 |
| `ReadPoolTests` 用信号量替代 `Thread.sleep(1.0)` | 该例 1.023s → 0.011s；串行批 1.18s → 0.19s |
| Gallery D04/D05/D07 固定 500/400/80ms → `waitUntilAsync`/负向窗口 | 0.62s/0.58s/0.50s → 0.21s/0.10s/0.005s，且不再靠调度余量 |
| `WorkspaceVisibilityTests`：嵌套 RunLoop → async settle；窗口 alpha=0；`close()` → `orderOut()` | 消除 app 并行的 SIGSEGV 根因；app 11.1s → 2.7s，50/50 并行全绿 |
| `CullingViewModelAPITests`：history 快照补本次 op | 并行 flake（1/50）→ 0；不再依赖 detached refresh 的落地顺序 |
| `CullingGridPerfTests` 加 `.serialized` | 真实窗口性能门不与其它用例并发，`GATHER_UI_PERF` 口径不变 |
| 新增 `ModelReviewRepoTests`（5）+ `ModelReviewAnalysisTests`（5） | Repo 0% → 95.3%；Service 10.6% → 53.9%（缓存/失败/批次/取消） |
| test-catalog ratchet 2,195/241 → **2,205/242** | 新用例计入下限，防后续静默删除 |

## 7. 残余项（按优先级）

1. **CI 观察**：app 并行已在本地 50/50；CI 首次启用后观察 1~2 周。若出现罕见 flake，
   用 `swift test --no-parallel` 或 `--filter` 二分，并把新增的窗口/通知类测试按
   §4.4 的 `alpha=0` + `orderOut` 约定落位。
2. **ModelReviewService 剩余 46%**：主要是 Vision 关键点/审美分支；若要在 PR 覆盖，
   需要把 `faceSignal`/`aestheticScores` 抽成可注入端口，或用受控合成 face box + 手动 opt-in 门。
3. **交付恢复分支**：Finalize/ReplayFlow 的崩溃窗口需要故障注入（当前 55~64%），
   这是比再加 happy-path 用例更高的收益点。
4. **缓存写放大（生产观察，非测试缺陷）**：`ModelReviewService.analyze` 缓存命中后仍会
   `INSERT OR REPLACE` 整行（测试里可直接观察到 JSON 被重编码）。20k 张的重复 analyze
   会重写 20k 行；建议命中缓存的 WorkItem 跳过落库，再补一条“命中不写库”的断言。
5. **剩余固定等待**：`APIDuplicateQualityTests`/`APIExportMetadataTests` 的 500ms
   用于“第二个调用已进入 waitForResult”的竞态窗口；要彻底去掉需要给 JobService 暴露
   只读 waiter 计数（test hook）或让测试注入完成屏障。
6. **构建耗时**：`swift test` 仍会编译 benchmark / triage-eval 可执行产物（构建日志可见），
   冷构建占 CI 大头；若要继续压缩，优先把基准拆独立 package 或按 trait 裁剪，而不是
   再砍测试用例。

## 8. 复现

```bash
# 默认套件（core：并行主批 + 4 个进程级状态套件串行；app：并行）
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh core
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh app

# SIGSEGV 回归：并行重复；疑似窗口过度释放时加 NSZombie
for i in $(seq 1 20); do
  swift test --package-path desktop/native/gather-app --parallel
done
NSZombieEnabled=YES NSAutoreleaseFreedObjectCheckEnabled=YES \
  swift test --package-path desktop/native/gather-app --parallel --filter WorkspaceVisibilityTests

# 覆盖率（core / app 分开；app 链接了 core，需过滤 gather-core 才能看 app 自身）
swift test --package-path desktop/native/gather-core --enable-code-coverage --no-parallel
xcrun llvm-cov report desktop/native/gather-core/.build/debug/GatherCoreTests.xctest/Contents/MacOS/GatherCoreTests \
  -instr-profile desktop/native/gather-core/.build/debug/codecov/default.profdata \
  -ignore-filename-regex='Tests/|\.build/'
```

历史口径（Cut 0 的 994/298 与合并建议）见 [test-audit.md](test-audit.md)；日常命令与手工
验收清单见 [DEVELOPMENT.md](DEVELOPMENT.md)。

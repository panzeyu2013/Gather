# Round3 运行时性能：启动阶段并行+计时、缓存/内存边界、服务批量化审计（task-18 / perf-runtime）

- 日期：2026-11-17（评审目录 2026-11-17-round3-perf）
- 基线：`42a89e01` + round-3 同伴未提交改动（本 agent 未触碰他人文件，也未回滚任何既有改动）
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode → **未编译、未运行、无 Instruments**。Swift 6.2 toolchain 只做
  `swiftc -parse`（语法级，不是类型/并发检查）。下文所有「收益」都是成本模型推导，不是 macOS 实测。
- 行为约束：无用户可见文案/布局/API 变更；无 schema DDL/fingerprint 变更；无新增 `@unchecked Sendable`
  （cleanup ratchet 维持 60/60）；未 git commit。
- 写域：`GatherHost/AppBootstrap.swift`、`GatherUI/Support/PhotoThumbnailView.swift`、
  `GatherUI/Support/ThumbnailDiskCache.swift`、`GatherApplication/Services/{Metadata,Export,Delivery,Session,Maintenance,Output,Workflows}`。

## 0. 摘要（做了什么 + 证据）

| # | 类型 | 位置 | 改动 | 证据 / 理由 |
|---|------|------|------|-------------|
| R1 | 启动并行 | `AppBootstrap.swift:396-437` | `storedInterfaceLanguage`（语言播种）与 `runtime.start`（executor 注册 + JobService 启动 + delivery 回放调度）由串行改为 `Task.detached` 先发射、两者并行等待 | 两者互不依赖（证明见 §1.3）；隐藏的时间 = min(两段)，语义不变 |
| R2 | 启动计时 | `AppBootstrap.swift:25-58, 148-199, 245-257, 293-449, 686-711, 782-790` | 新增 `StartupPhaseTimings`（单调时钟、MainActor 局部、无锁），冷启动成功/失败各一行日志：`restore / dbOpen / composition / languageSeed / runtimeStart / embeddingPrep / wire` + `firstScene / total` | 7 次 `DispatchTime` 读取 + 1 行日志；日志 sink 写入成本与既有每行日志相同，无逐帧成本 |
| R3 | 缓存计量 | `PhotoThumbnailView.swift:803-825` | `PhotoThumbnailCache` 的 NSCache cost 从 `NSImage.size`（点）改为 `NSImageRep.pixelsWide/High`（位图像素），仍保留 RGBA 4B/像素 + 20% + 256KB 下限 | 300dpi 的 2048px JPEG 旧 cost 被低估 17.4×（§2.2），512MB 上限失去约束；**2026-11-18 评审 R2-A3/R5-05 补充**：修正后上限真实生效，2560 预览在 300dpi 下可缓存数量可能从数百张降到约 24 张，淘汰悬崖尚未真机实测（属可重生缓存，随时可调 totalCostLimit） |
| R4 | 缓存清理 | `ThumbnailDiskCache.swift:28-29, 41-58` + `AppBootstrap.swift:274-280` | 新增 `pruneAtStartupIfNeeded()`：启动时把上次进程遗留的超限磁盘缓存清理丢到 `Task.detached(priority: .utility)`，进程内至多一次、仅缓存 JPEG | 旧实现只有「下一次 store」才发现超限，枚举目录成本落在首屏解码线程上 |
| R5 | 服务批量 | `Services/Metadata/MetadataKeywordWriter.swift:124-148` | 关键词预览的缓存行读取：循环内逐张 `cacheStore.get` → 循环前一次 `cacheStore.getBatch`（按 800/块 IN 查询） | 500 张预览 500 条 SELECT → 1 条（§3.1）；预览/应用失败语义不变 |
| R6 | 服务 hoist | `Services/Maintenance/BackupStore.swift:89-118` | `BackupStore.list()` 的 `JSONDecoder()` 与兜底 `ISO8601DateFormatter()` 从逐文件构造提到循环外 | ≤20 个备份文件 × 2 个昂贵构造 → 2 个；输出逐字不变 |

改动只涉及 5 个源文件（§4.4 列出）；`Services/Delivery`、`Services/Session` 两个目录**不存在**
（相关服务在 `GatherDelivery` target / `Services/SessionService.swift`），审计项 N/A，见 §3.3。

## 1. 启动：阶段拆分 + 唯一可证明安全的并行

### 1.1 现状审计（`startup` → `makeScene` 的每个可观察阶段）

| 阶段 | 位置 | 线程/方式 | 启动期是否阻塞主线程 | 本次动作 |
|------|------|-----------|----------------------|----------|
| 目录/权限/registry/日志 sink | `makeScene` 开头 | MainActor 同步 | 是（毫秒级 IO，少量 stat） | 不动 |
| 跨进程恢复 journal（RestoreCoordinator/RestoreLock） | `makeScene` | MainActor 同步 | 是（仅 journal 存在时） | 不动（必须早于 Database.open） |
| Database.open（schema inspect/迁移/可能归档重建） | `makeScene` | `Task.detached(userInitiated)`（round-2 C5） | 否 | 不动；本次只加计时 |
| 组合根 `AppComposition.make` + `AppServices.live`（24 服务/16 API） | `makeScene` | MainActor 同步 | **是**（唯一的同步装配段） | 不动（见 §1.4 原因） |
| 语言播种（settings.ui_language 读取 + `LanguageStore.seed`） | `makeScene` | async；`LiveSettingsAPI.get` 是 nonisolated async（协作池执行单条 SELECT），seed 在 MainActor | 否（等待期间主线程让出） | **与 runtime.start 并行**（R1） |
| `runtime.start`（8 executor 注册 + JobService 启动 + recoverStale/resumeInterrupted，之后后台回放 delivery） | `makeScene` | `Task.detached(userInitiated)`（既有） | 否 | **与语言播种并行**（R1） |
| 后台维护任务（retention GC / keyword backfill） | `scheduleBackgroundMaintenance` | `Task.detached(utility)` ×2（既有） | 否 | 不动 |
| 事件总线接线 | `makeScene` | MainActor 同步（仅挂 sink） | 否 | 不动 |
| 原生 embedding 一次性迁移（settings.set + listSessions + 每会话 face.analyze job.create） | `AppImport.prepareNativeEmbeddingRerun` | MainActor，除 settings.set 外均为同步 DB | 是（仅首次启动/每个 DB 一次，marker 命中后立即 return） | 不动（必须严格在 runtime.start 之后，见 §1.4） |
| provider / C1 桥 / Delegate 接线（`wire`） | `makeScene` | MainActor 同步（构造引用 + 注入闭包，无 IO） | 否 | 加计时 |
| `maintenance.startScheduler` + Delegate 停机钩子 | `startup` | async（scheduler 自身 off-main 逻辑） | 否 | 加 total/firstScene 计时 |

结论：round-2 已把最重的 `Database.open` 与 `runtime.start` detach；本轮剩下的**可证明安全**的
并行只有「语言播种 ∥ runtime.start」。组合根装配仍是主线程同步段（§1.4 说明为什么不搬）。

### 1.2 改动前后（`AppBootstrap.swift`）

改动前（串行，节选）：

```swift
if let stored = await storedInterfaceLanguage(using: appServices.settings) {
    languageStore.seed(L10n.Language(rawLanguage: stored))
}
...
let replayPendingDeliveries = !didRestore
_ = try await Task.detached(priority: .userInitiated) {
    try runtime.start(replayPendingDeliveries: replayPendingDeliveries)
}.value
```

改动后（先发射 detached start，再 await 语言播种，最后 await start）：

```swift
let replayPendingDeliveries = !didRestore
let runtimeStartStartedAt = startupTicks()
let runtimeStartTask = Task.detached(priority: .userInitiated) {
    try runtime.start(replayPendingDeliveries: replayPendingDeliveries)
}
let languageSeedStartedAt = startupTicks()
if let stored = await storedInterfaceLanguage(using: appServices.settings) {
    languageStore.seed(L10n.Language(rawLanguage: stored))
}
phaseTimings.record("languageSeed", since: languageSeedStartedAt)
_ = try await runtimeStartTask.value
phaseTimings.record("runtimeStart", since: runtimeStartStartedAt)
```

await 顺序有意保持「语言先、start 后」：即使 `runtime.start` 抛错走 catch，失败文案
（`APIErrorPresentation.userFacingMessage(..., with: languageStore.l10n)`）读到的仍是已播种的语言 ——
与改动前的可观测错误文案一致。

### 1.3 并行安全证明（四条，逐条可核对）

1. **无共享可变内存状态**：语言侧只读 `settings.ui_language`（SettingsAPI.get 单条 SELECT）并写
   `LanguageStore`（`AppBootstrap` 持有、MainActor 独占）；`LanguageStore.seed` 的注释明确
   **不广播**（`Sources/GatherUI/Support/LanguageStore.swift:82-91`：不走 `set`，故不会 post
   `languageChanged`，启动期也无订阅方）。`runtime.start` 只碰 executor 注册 / JobService 生命周期 /
   delivery 回放 Task，不认识 `languageStore`，两者没有交集；seed 顺带写的进程级
   `GatherLocalization.setAppLanguage` 只被 UI 文案出口读取，而 `runtime.start` 路径
   （`JobService` / `AppRuntime` / `WorkflowRegistry`）零引用该全局（grep 验证）。
2. **DB 访问安全**：两条路径都经组合根唯一 `DBConnection`（`@unchecked Sendable`，句柄访问在
   `connectionLock` 临界区内；`Sources/GatherPersistence/Database/DB.swift:167-172`；读路径另有只读池
   的独立小锁）。语言侧是一次只读 SELECT，start 侧是 executor 注册与 job 恢复查询；不存在同一行
   被两条路径交错写出的窗口。
3. **顺序不变量**：`scene` 发布前两者都已 `await` 完成；首个读 `l10n` 的视图在 scene 发布后求值，
   因此语言播放在并行窗口里早/晚几十 µs 对用户不可见。
4. **失败/取消语义**：两者都失败可捕获；`Task.detached` 与改动前同为 detached（不随 startup 的父
   任务取消），取消/优先级行为不变。`runtime.start` 的返回值本就丢弃（恢复结果由 runtime 内部落库）。

### 1.4 明确**没有**并行/搬移的候选（证据）

| 候选 | 不做的原因 |
|------|-----------|
| `AppComposition.make` + `AppServices.live` 搬出主线程 | 同步构造 24 个服务/16 个 Live API 与 @MainActor 桥接对象；迁出需要逐一证明 Sendable 与「构造期不碰 MainActor 状态」，Linux 上无法用类型检查验证（只有 -parse），风险远大于收益。保留为主线程装配段并记录耗时（`composition` 字段）。 |
| `AppImport.prepareNativeEmbeddingRerun` 与 `runtime.start` 并行 | 迁移里 `jobService.create(face.analyze)` 与 start 的 `recoverStale/resumeInterrupted` 都改 `analysis_jobs` 行：谁先谁后不可证（恢复可能看不到/误判刚建的行）。且该迁移每个 DB 只跑一次、marker 命中即 no-op，并行收益一次性且极小；**保持串行**。可作为后续单独任务（把迁移整体移到后台并加 macOS 集成验证）。 |
| 语言播种与 `Database.open` 并行 | settings 服务来自组合根，组合根需要 open 后的 `database` 实例（顺序硬依赖）。 |
| 恢复 journal 与 DB open 并行 | 恢复需要在 open 前 swap 库文件（既有 ADR/B0 语义，禁止变更）。 |
| 后台维护任务 | 已是 detached（round-2 既有），无需改。 |
| 事件总线 `wire` | 同步挂 sink（微秒级），没有可重叠的异步工作。 |

### 1.5 阶段计时（一次性、低成本、可复核）

- 实现：`AppBootstrap.swift:25-58`（`StartupPhaseTimings` + `startupTicks()` / `startupMillisecondsText`）。
  `DispatchTime.uptimeNanoseconds` 单调时钟；累加全在 MainActor 局部、无锁、无静态状态。
- 成功日志（每次冷启动一行，info）：
  `startup phases: total=<T>ms firstScene=<F>ms restore=..ms dbOpen=..ms composition=..ms languageSeed=..ms runtimeStart=..ms embeddingPrep=..ms wire=..ms`
- 失败日志（沿用原 error 级别调用点，只补耗时）：`bootstrap failed after <T>ms: <error>`。
- 口径说明：`firstScene` = startup 入口 → `self.scene = state` 的墙钟，是「场景发布时刻」而非真实
  首帧（draw call 在 startup 返回后由 SwiftUI 驱动，本文件观测不到）；`total` = 到
  `maintenance.startScheduler` 与 Delegate 停机钩子接线完成。并行段的 `languageSeed` 与
  `runtimeStart` 各自计时，二者之和可大于窗口（这是并行，不是重复计时）。
- 成本：每阶段一次 `DispatchTime` 读取 + 最终一次字符串拼接 + 一行 `GatherLogger.log`；日志文件
  sink 的每行同步写入成本与既有启动日志相同（`LogFileSink.maxFileBytes=5MB/maxFiles=5` 有界）。
  无任何逐帧/逐照片开销。
- macOS 验证指引（本次无法执行）：在 `~/Library/Application Support/Gather/Logs/gather.log` 搜
  `startup phases:`，即可拿到真机各阶段 ms。

## 2. 缓存 / 内存边界审计

原则：只对**缓存**加界/淘汰（可重生数据），绝不淘汰用户数据；无法证明安全的（依赖全量已加载行、
影响排序/定位/撤销语义的）只记录不改。

### 2.1 缓存与集合总表（审计时口径）

| # | 缓存/集合 | 位置（审计时） | 上限 / 键 | cost / 淘汰 | 判定 | 本次动作 |
|---|-----------|----------------|-----------|-------------|------|----------|
| 1 | `PhotoThumbnailCache`（NSCache<NSString, NSImage>） | `PhotoThumbnailView.swift:747-825` | 512MB `totalCostLimit`；键 = 模式 + path + size + epoch（epoch 让主动刷新失效） | 按 cost LRU；cost 原=点尺寸×4B×1.2 | 上限正确，**计量在 DPI≠72 的图上低估** | 修正 cost 用位图像素（R3，§2.2） |
| 2 | 查看器区域细节层缓存 | `PhotoDetailTileView`（同 NSCache） | Кey = 模式 + path + 量化 rect(1/128) + targetPixel | 同上 | 键含档位/矩形，受同一 512MB 约束；档位/预算已有界（`PhotoDetailTier.budget(forVisibleCells:)`） | 无 |
| 3 | `PhotoDecodeGate` 在飞去重表 | `PhotoThumbnailView.swift:497-547` | `inFlight` 条目在等待者归零/任务收尾时 `remove`（identity 校验）；并发闸门 4 / 区域 2 | 不累积 | 无界增长风险未发现 | 无 |
| 4 | `ThumbnailDiskCache` | `ThumbnailDiskCache.swift` | 512MB 硬上限；prune 节流 = 128 写 / 64MB / 60s，超限删到 80%；键含源文件 mtime+size | 按 mtime 近似 LRU | 上限足够，但「上次进程遗留超限」要等下一次 store 才清 | 启动后台 prune（R4，§2.2） |
| 5 | 水印 logo 缓存 `WatermarkLogoCache` | `Services/Export/ExportService+Run.swift:695-765` | `maxEntries = 8`；键 = path + size + mtime(ms)；解码期已按最长边 2048 降采样 | 超限驱逐任意旧键 | 有界；最坏 8×2048px CGImage（≈128MB 量级） | 无 |
| 6 | L10n 查表缓存 `L10nStringCache` | `GatherUI/Support/L10n.swift:48-112` | 4096 条；键 = (language, key)；超限整体清空 | O(1) 清空 | 有界；动态 key（错误散文）会触发整清，但内存有界 | 无（非本写域） |
| 7 | AF 机型登记表 `AFPointProfiles` | `GatherAnalysis/Preview/PreviewAnalysis.swift:282-315` | `[机型: AFGrid]`，仅 `install` 增加；出厂空表、生产无调用方 | 无 | 理论无界但增速 = 机型数、值极小；当前生产恒空 | 无（非本写域） |
| 8 | 人脸嵌入 provider 缓存 | `GatherAnalysis/Face/EmbeddingModel.swift:687-743` | 键 = path + version + statFingerprint + computeUnits；**无条目上限** | 无 | **残留风险**：同路径反复换模型权重（fingerprint 变）会累积已编译 provider（每个含 CoreML 模型） | 记录 + 建议（§5） |
| 9 | 图库分页 `pages/pageCursors/loadedPhotos` | `GatherUI/Gallery/GalleryViewModel.swift:242-243`、`+Scroll.swift:174-176`、`flatCache` | 无上限：每页 append；搜索链式可拉满 | 仅筛选/搜索退出时截断首页 | 长会话内存随浏览页数增长（设计使然：定位/折叠兄弟/事件刷新依赖已加载行） | 记录（§5，改上限需产品决策+macOS 验证） |
| 10 | 挑片已加载 id 集 `loadedPhotoIds` | `GatherUI/Culling/CullingViewModel.swift`（symbol） | 每页整体替换/同页 union | — | 随 page 有界，不跨页累积 | 无 |
| 11 | 控制中心 `jobs` / `historyJobs` | `GatherUI/ControlCenter/SessionControlViewModel.swift`（symbol） | `jobAPI.list(status:nil)` 全量 DB 行；`historyJobs` 派生过滤 | 无 | **残留风险**：任务历史随使用增长，UI 一次加载全量 | 记录 + 建议（§5：JobAPI.list 加 limit 或维护期裁剪终态旧行） |
| 12 | 挑片操作历史 `history` | `GatherUI/Culling/CullingViewModel.swift`（symbol） | 按页/按会话从 DB 读 | — | 未发现跨页累积证据 | 无 |
| 13 | 全局 toast 队列 | `GatherUI/DesignSystem/Components/GatherToast.swift:61,87-89` | 上限 3 条，超出丢最旧 | 立即 | 有界 | 无 |
| 14 | 事件总线 `GatherEventCenter` | `GatherUI/Support/GatherEventCenter.swift` | **无缓冲**：收到即 `NotificationCenter.post`；仅域 revision 字典（域数固定） | — | 无队列/无累积 | 无 |
| 15 | 日志文件 sink | `GatherApplication/Logging/LogFileSink.swift:25-29,107-142` | 5MB × 5 轮转 + 按名删旧 | 轮转 | 有界 | 无 |
| 16 | 模板撤销历史 `MetadataApplyBatchStore` | `Services/Metadata/MetadataApplyBatchStore.swift:104-115` | `retention` 上限（20），settings 单 key 持久化 | 截断 | 有界 | 无 |
| 17 | 导出执行期缓冲 | `Services/Export/ExportService+Run.swift:148-242` | 每次 execute 的局部 `errors/plans/state`，函数返回即释放 | — | 无进程级缓存（除 #5） | 无 |
| 18 | 备份列表 | `Services/Maintenance/BackupStore.swift:84-122` | 目录内托管文件 ≤ retention（≤20） | prune | 有界 | hoist 逐文件构造（R6） |

### 2.2 本次改动的 before/after

**(R3) NSCache cost 计量（`PhotoThumbnailView.swift:803-825`）**

- 旧：`let size = image.size.width * image.size.height; cost = max(256KB, Int(size * 4 * 1.2))`。
  `NSImage.size` 是**点**：由 JPEG data 构造的 NSImage 会按文件里的 DPI 元数据折算。
- 新：取 `representations` 中像素面积最大的 `pixelsWide × pixelsHigh` 作为像素数，cost 公式不变；
  `pixelsWide/High` 不可用时退回 `image.size`（小图仍由 256KB 下限兜底）。
- 数值（2048×1365 的 300dpi JPEG）：旧面积 = (2048×72/300) × (1365×72/300) ≈ 161,021 pt² ⇒
  cost ≈ 0.77MB；新面积 = 2,795,520 px² ⇒ cost ≈ 13.4MB，**低估 17.4×**。相机直出多为 72dpi
  （两者相等，所以旧值看起来「常见路径正确」）；PS/导出链常见的 300dpi 图才会触发低估。
- 影响面：只影响 NSCache 淘汰时机（缓存可重生），不改变任何显示/解码结果；小缩略图 cost 仍被
  256KB 下限主导，行为不变。

**(R4) 磁盘缓存启动清理（`ThumbnailDiskCache.swift:28-29,41-58`；调用点 `AppBootstrap.swift:274-280`）**

- 旧：512MB 上限只在 `store()` 后触发（`schedulePruneIfNeeded`）；若上次进程退出/降级时目录已超限，
  超限状态保留到下一次解码写缓存，且那次 prune 的目录枚举成本落在解码线程上。
- 新：`pruneAtStartupIfNeeded()` 在 `ThumbnailDiskCache.isEnabled = true` 之后调用；用 state 锁内
  `didStartupPrune` 保证进程内至多调度一次，实际 `pruneIfNeeded()` 在 `Task.detached(priority:.utility)`
  上执行（只读目录/按 mtime 删缓存 JPEG，删除条件仍是「总量 > 512MB 才删到 80%」）。
- 语义：只触碰 `Application Support/Gather/thumb-cache` 内的缓存文件，不触碰照片/设置/数据库；
  缓存未开启（单测默认）时 no-op；与其它 decode 路径的并发 prune 竞态原实现已存在（删的是可重生缓存）。

### 2.3 为什么没有加 `autoreleasepool`

本任务内的图像解码主循环在 `ExportService+Run.execute`（逐张 copy/ImageIO 转码）与解码器端口内部：
- ImageIO/CoreGraphics 返回的是 `CGImageSourceRef`/`CGImageRef` 等 **CF 对象（Create 规则 +1）**，由
  ARC 在每轮迭代结束释放，不是 Objective-C autoreleased 临时对象；`autoreleasepool` 对它们没有
  可证明的作用。
- 循环体里还有 `URL/Data/NSDictionary` 等桥接对象，但每轮都会在函数返回/作用域结束时释放；没有
  macOS Instruments 证据表明峰值来自 autorelease 积压。
- 在无 macOS 运行验证的前提下加 `autoreleasepool`（仅 Darwin 可用，会引入平台分支）属于「看起来
  专业但无法证明」的改动 —— 按任务要求「只在安全处加」，本轮选择**不加并记录原因**；真机若测得
  峰值 RSS 与处理张数线性相关再试。

## 3. 服务批量化审计（Metadata / Export / Delivery / Session / Maintenance / Output / Workflows）

### 3.1 已修复

**(R5) `MetadataKeywordWriter.keywordPreview`：缓存行 N+1 → 1 条批量查询**

- 位置：`Services/Metadata/MetadataKeywordWriter.swift:124-148`（预览循环前批量读 + 循环内查字典）。
- 旧：`for target in targets { ... do { cachedRow = try cacheStore.get(target.photo.id) } ... }` ——
  每张照片 1 条 `SELECT ... WHERE photo_id = ?`（每条都要过 DBConnection 锁 + 语句准备）。
- 新：循环前 `cacheStore.getBatch(targets.map(\.photo.id))`（`MetadataCacheRepo.getBatch` 按 800/块
  分片 `IN (...)`，`Sources/GatherPersistence/Database/Repositories/MetadataCacheRepo.swift:268-281`），
  循环内 `cachedRowByPhotoId[target.photo.id]`。
- 量级：模板批量预览 500 张 = 500 条查询 → 1 条；2000 张 = 2000 条 → 3 条。
- 语义等价：
  - 行值相同（同一批 `MetadataCacheRow`），`externalChanged` 判定输入不变；
  - 旧逐张 `do/catch → cachedRow = nil` 的失败降级，改为整批 `do/catch → [:] `（缓存读失败不阻塞
    预览/应用，该语义不变）；`getBatch` 只有 SQL 层错误会抛，不存在「部分行失败」的可用语义；
  - 测试兼容：`MetadataMutationServiceTests.keywordPreviewIsReadOnlyAndApplyQueuesDelta` 用真实
    `MetadataCacheRepo`（`getBatch` 正常）；fake `PortFakeMetadataRepo.get` 返回 nil、`getBatch` 返回
    `batchRows`（默认空）⇒ fake 路径前后均无缓存行，行为一致。

**(R6) `BackupStore.list()`：逐文件 `JSONDecoder()`/`ISO8601DateFormatter()` → 循环外各一份**

- 位置：`Services/Maintenance/BackupStore.swift:89-118`。托管备份目录上限 = `backup_retention`
  （≤20），但 `list()` 被 backup/restore/verify/设置页反复调用，且默认配置相同的解码器/格式化器
  复用不改变任何输出字节与日期字符串。perf ratchet 计数不变（构造点行数相同）。

### 3.2 已审计但**未改**（file:line + 证据 + 原因）

| 项 | 证据 | 为什么不在本轮改 |
|----|------|------------------|
| `MetadataDispositionService.conflicts` 逐冲突交付行 `items(deliveryId:)` | `Services/Metadata/MetadataDispositionService.swift:42-64` | 每次 N+1 SELECT + 逐张读 XMP（文件 IO 为主）。批量需给 `MetadataDispositionReading` 端口加 `items(deliveryIds:)`（public protocol 面变更，且该端口在 GatherPersistence = 非本写域）；冲突行通常 0-数个，优先度低。 |
| `MetadataTemplateService.preview` 逐照片 `metadata.photoDetail(photoId:)` | `Services/Metadata/MetadataTemplateService.swift:373-374` | 需要给 `MetadataService` 加批量 detail API（`Services/MetadataService.swift` 不在本任务写域），且逐张 await 读盘（`diskAttributes`）才是主要成本；UI 侧预览列表已有行数上限。 |
| `ExternalMetadataMigrationService` 逐条 update（rating/label/keywords 各自 1 条 UPDATE） | `Services/Maintenance/ExternalMetadataMigrationService.swift:135-143` | 窄更新（COALESCE）是语义：每字段独立不覆盖其余列；Repo 无批量 API，加事务包装不改变单行成本，收益不足以承担写路径风险。 |
| `LibraryPackageService` 导入逐 item insert/upsert | `Services/Maintenance/LibraryPackageService.swift:177-262,330-451,475-501` | 每条都是用户数据写入（照片/集合/堆栈/智能相册/保存搜索/人物绑定），本就一行一条；导出侧 Repo 已 hoist（:44-88,157-163）。批量 API 属写路径设计变更。 |
| `ExportService+Run` 每张照片 1 次 `sidecarVersion` stat | `Services/Export/ExportService+Plan.swift:279-285,486-494`；`+Run.swift:206` | 1 次 stat/张，用于「源 XMP 是否变化 → 是否新交付身份」。只在 includeXmp 语义下有意义，但跳过会改变 `deliveryFingerprint` 公式 —— 指纹参与任务去重/续跑身份且会跨版本持久化，改公式可能让升级后在跑的任务重新导出/产生重复文件。**不属 clearly-safe**。 |
| `OutputService.expandPlaceholders/timestamp` 每次调用新建 DateFormatter | `Services/Output/OutputService.swift:305-319,500-505` | 调用频率 = 配方/产物数（个位数），不是逐照片/逐行；一次交付一次。 |
| `S3ShareTransport` SigV4 每请求 `timestamp/dateStamp` 新建 DateFormatter | `Services/Output/S3ShareTransport.swift:278-292`（签名调用点 :774-775，上传循环 :562） | 每个 HTTP 请求（每文件/每重试）需要**当前** UTC 时间参与签名（15min skew 允许但长批次要新时间）；复用需要新增加锁 formatter 盒子 = 新增 `@unchecked Sendable`/共享状态（ratchet 禁止），或给 SigV4 加注入参数（public API 变更）。DateFormatter ≈55µs 对每次网络请求（≥ms）不显著。 |
| `WorkflowRegistry.decodeJSON/encodeJSONValue` 每次 `JSONDecoder()/JSONEncoder()` | `Services/Workflows/WorkflowRegistry.swift:551-562`（调用点 :277,361-386,422,452） | 频率 = 每 job/每 checkpoint 转换（个位数），非逐行；且属既有 `try?` 计数路径。 |
| `MaintenanceService` 多处 `ISO8601DateFormatter()/JSONEncoder()` | `Services/Maintenance/MaintenanceService.swift:206,231,377,388,403,571,599,609,632` | 全部位于 backup/restore/journal/state **单次操作**路径（不是循环内逐行），每次启动/每次备份一份。 |
| `DiagnosticsCollector` 的时间戳 | `Services/Maintenance/DiagnosticsCollector.swift:61,169` | 每次诊断导出一次。 |
| `MetadataAttributeWriter` 回读后的 cache 投影更新 | `Services/Metadata/MetadataAttributeWriter.swift:152-343` | 每照片 1-3 条 cache UPDATE 是保持投影一致性的必要写入；兄弟索引已按会话缓存（`loadedSessions`，:145,195-206），兄弟读盘已并发批量（`batchAsync(concurrency:4)`，:232-249）。 |
| `MetadataKeywordWriter` apply 侧逐 target `queueKeywordDelta` | `Services/Metadata/MetadataKeywordWriter.swift:294-299`（另 :298-299 逐 id updateKeywords） | 队列写入/DELTA 入队本身是每照片一条语义；Repo 无批量入队 API。 |
| `Output/WebDAVPublisher`、`S3ShareTransport` 上传循环 | `Services/Output/WebDAVPublisher.swift:320-374`、`S3ShareTransport.swift:562-648` | 循环体 = 每文件一次网络上传 + 必要 `Data(contentsOf:)`（内容不在内存常驻），无 formatter/JSON 逐行构造。 |
| `Output/ProofFeedbackService` 逐 item 入队 | `Services/Output/ProofFeedbackService.swift:296-305` | 每条校样反馈一个用户动作，量级小。 |
| `GalleryBuilder/ContactSheetRenderer/PrintDocumentRenderer` 逐 item 渲染 | `Services/Output/GalleryBuilder.swift`、`Services/Export/ContactSheetRenderer.swift`、`PrintDocumentRenderer.swift` | 每件产物必须渲染（缩略图/PDF 单元格），无 formatter/JSON 重复构造；渲染成本是本任务范围外的 IO/CPU。 |

### 3.3 覆盖说明

- `Services/Delivery`、`Services/Session` 目录**不存在**（`ls` 验证）：交付域服务在
  `GatherDelivery` target，会话域在 `Services/SessionService.swift`（两者都不在本任务写域）。
- 本审计的扫描面 = 7 个子目录下全部 `*.swift`（约 30 个文件）；扫描方法 = 逐循环定位
  formatter/JSON coder/DB 调用（脚本扫描 + 人工核对每个命中），命中项全部在上表/§3.1 有交代。

## 4. 验证

### 4.1 语法（Linux，Swift 6.2）

```
.gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <每个被改文件>   # 全部 exit 0，无输出
```

被改文件：`AppBootstrap.swift`、`PhotoThumbnailView.swift`、`ThumbnailDiskCache.swift`、
`MetadataKeywordWriter.swift`、`BackupStore.swift`。**语法级**：不覆盖 Swift 6 类型/并发检查，
也不覆盖 AppKit/image 解码运行期行为。

### 4.2 门禁（交付前最后一次运行，命令与结果）

| 门禁 | 命令 | 结果 |
|------|------|------|
| cleanup ratchet | `./scripts/check-cleanup-ratchet.sh` | PASS（全部指标不超过 baseline；unchecked_sendable 60/60） |
| perf ratchet（额外） | `./scripts/check-perf-ratchet.sh` | PASS（formatter/JSON 构造点计数不变） |
| layering | `./scripts/check-layering.sh` | PASS |
| protocol surface | `./scripts/check-protocol-surface.sh --strict` | PASS |
| design system | `./scripts/check-design-system.sh` | PASS |
| repo hygiene | `PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh` | PASS（[a]-[g] 全绿；含 shellcheck 0.10.0、Markdown 链接、本地化表/用法） |
| 自改文件空白 | `git diff --check -- <本任务 5 个文件>` | exit 0（无行尾空白/多余 EOF） |

中间交叉写盘说明（已恢复）：首次运行 repo-hygiene 时 [b] 命中**同伴 perf-core 正在写**的
`GatherPersistence/.../AssetRepo+Scan.swift` trailing whitespace（不在本 agent 写域，未触碰；同一时刻
本 agent 的 5 个文件单独 `git diff --check` 已通过）。同伴改完后再跑，repo-hygiene 全绿（上表）。
本目录的 `perf-runtime.md` 在交付时是 untracked 文件（git 门禁只扫 tracked），已按 .editorconfig
逐项自查：LF、无行尾空白、单末行换行、UTF-8、无相对 Markdown 链接。

### 4.3 验证天花板（明确未做）

- 未跑 `swift build/test`（无 macOS/Xcode）：类型检查、Swift 6 并发诊断、AppKit/ImageIO/CoreML
  行为均未验证。
- 未跑 macOS 真机/Runner、无 Instruments/内存曲线：启动阶段 ms、缓存实际 RSS、NSCache 淘汰次数
  都是**成本模型**而非实测。
- 新增的 `startup phases` 日志只做了语法验证；其运行时输出（各阶段耗时、firstScene 口径）需要
  macOS 冷启动验证。
- `ThumbnailDiskCache.pruneAtStartupIfNeeded` 的后台 prune 未在真实超限目录上验证（Linux 无法
  启动 AppKit host）；逻辑复用既有 `pruneIfNeeded`，新增的只是「启动时调度一次」。
- 关键词预览批量化未跑 `GatherCoreTests`（Linux 无 SwiftPM 运行环境），只做了实现/调用点核对。

## 5. 残余风险与后续建议

按优先级（P1 先）：

1. **P1（内存，非本写域）人脸嵌入 provider 缓存无上限**（`GatherAnalysis/Face/EmbeddingModel.swift:687-743`）：
   同路径反复换权重（fingerprint 变）会累积已编译 CoreML provider。建议加 `maxEntries`（2-4）LRU，
   或复用现有 `@unchecked Sendable` 锁盒子模式；注意 cleanup ratchet 不允许新类型。
2. **P2 控制中心任务列表全量加载**：`SessionControlViewModel.jobs` = `JobAPI.list(status:nil)` 全量
   （UI 侧`historyJobs`派生）。建议给 `JobAPI.list` 加可选 `limit`（protocol 面变更需评审）或在
   maintenance 的 retention 里裁剪旧终态 job 行（有 schema 语义需对齐）。
3. **P2 图库长会话 `pages/loadedPhotos` 无上限**：随浏览页数增长；当前「定位照片/折叠兄弟/事件刷新」
   依赖已加载行，直接截断会破坏语义。建议产品层允许「窗口化」（只保留可视附近 N 页 + 首屏索引），
   需要 macOS 上验证定位/滚动回跳行为后再做。
4. **P3 冲突列表 N+1**（`MetadataDispositionService.conflicts`）：需要给
   `MetadataDispositionReading` 加批量 items API（协议面变更）；冲突行通常很少，等真实用户出现
   上百条冲突再处理。
5. **P3 模板预览逐照片 detail**：需要 `MetadataService` 批量 API + 真实读盘成本评估；预览列表
   行数受限，收益中等。
6. **P3 启动组合根装配仍为主线程同步段**：若要继续压缩冷启动，需要在 macOS 上先有
   `startup phases: composition=..ms` 数据；软件层面搬出主线程需要全量 Sendable 审计（风险高）。
7. **观察项**：新增阶段日志建议在 round-3 合并后由 lead 在 macOS 上抓一条真机日志贴进本目录
   overview，确认 `dbOpen/runtimeStart/composition` 的量级后再决定下一刀往哪切。

## 6. 改动清单

| 文件 | 行（本次改动后） | 内容 |
|------|------------------|------|
| `desktop/native/gather-app/Sources/GatherHost/AppBootstrap.swift` | 16（import Dispatch）；25-58（计时器）；132-139（顺序注释）；148-199（成功/失败计时日志）；245-257（phaseTimings 变量）；274-280（启动 prune 调用）；293-321（restore 计时）；322-364（dbOpen 计时）；365-397（composition 计时）；398-437（语言 ∥ runtime.start + 计时）；438-449（embeddingPrep 计时）；686-711（wire 计时）；760-790（返回 phaseTimings） | R1/R2/R4 调用点 |
| `desktop/native/gather-app/Sources/GatherUI/Support/PhotoThumbnailView.swift` | 803-825 | R3 cost 计量 |
| `desktop/native/gather-app/Sources/GatherUI/Support/ThumbnailDiskCache.swift` | 28-29, 41-58 | R4 启动 prune API |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataKeywordWriter.swift` | 124-148 | R5 getBatch |
| `desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/BackupStore.swift` | 89-118 | R6 hoist |

未 commit；未改 schema/DDL/fingerprint、未改公开 API 签名、未改 en.lproj/design baseline。

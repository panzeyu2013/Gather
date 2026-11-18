# R3 第三轮独立评审：gather-app（GatherUI / GatherHost）—— round-2 修复验证 + 残余风险

- 评审人：review3-app（第三轮；未参与任何生产改动，全程只读）
- 评审对象（app 侧）
  - HEAD **3486be0b** 上 `desktop/native/gather-app/Sources/**` 相对 `origin/main`（e5c54f37）的全部本地改动：**109 文件 +1662/−639**（全仓 22 commits / 234 文件）；
  - round-2 修复提交 **5bcf915b** 的 app 部分（仅 2 文件：`CullingViewModel.swift` +6/−2、`Support/DateFormatting.swift` +1/−1）的独立复验；
  - 顺带复验会影响 app 语义的 core 侧 round-2 修复 `JSONValueCodingTests`（P0-4，gather-core Tests）。
- 工作区快照：评审期间 lead 已合入 round-3 修复（worktree 未提交）。**app 侧唯二未提交差异是 `GalleryGrid.swift` 的一行注释**（`git diff` 确认：仅 rowIndex 文档注释，无代码语义），本报告结论对 HEAD 与当前工作区同时成立；core 噪声不在本册范围。
- 环境：Linux Ubuntu 22.04，无 macOS/Xcode。Swift 6.2（`.gather/swift62/usr/bin/swiftc`）、 freshly-built `GatherProtocol` 模块、shellcheck、sqlite3、python3。
- **验证上限（必须保留）**：未在 macOS 构建/链接/运行 App，未 `swift build/test`（gather-app），未跑 `check-warnings`/SwiftUI 运行时/Instruments/真机。AppKit/SwiftUI 文件在 Linux 无法编译；本册所有"真实 typecheck"仅覆盖纯 Foundation/不 import Apple 框架的文件（详见 §1、§4）。

## 0. 摘要（先给结论）

1. **round-2 的 app P0 修复全部验证通过，未发现引入新 P0/P1**：
   - **P0-1 DateFormatting 多尾闭包标签**：HEAD 版真实 `-typecheck -swift-version 6` = **EXIT 0**（该文件仅 Foundation；`withFormatter` 是 private，单文件 typecheck 即覆盖全部 **4 个调用点** 77/108/120/132）。旧 per-call 语义对拍：15 组环境 × 1467 checks = **22,005 次比较 0 mismatch**；16 线程混合调用锤测 **4000 轮 0 失败/无死锁**；锁作用域/环境键静态复核成立。
   - **P0-2/P0-3 `@ObservationIgnored private(set)` 跨文件只读**：真实模块级 typecheck 试验（`CullingViewModel.swift` + 6 个同型扩展 + 15 个 support 文件，共 **22 个真实 GatherUI 源文件**）中，**被检文件 0 error**，仅剩被排除的 Darwin-only 依赖 `L10n.swift` 的 4 条错误（Apple-only `OSAllocatedUnfairLock` / Darwin 上 `NSNumber: CVarArg`）——即 `+Navigation.swift:238/245` 读 `navigationGroupsVersion` 与 `CullingViewModel.swift` 的声明都真实通过 Swift 6 检查。两文件最小探针另行验证：`private(set)` **外部写被编译器拒绝**（负向探针）、`didSet` 在 `@Observable` 下**确实触发**、Observation 依赖矩阵符合预期（§1.2）。
   - **P0-4 JSONValueCodingTests 的 `try` 位置**：对 freshly-built `GatherProtocol` 真实 `-typecheck` = **EXIT 0**；把该测试的全部断言重写成独立 harness 用真实模块**跑通 40 checks 0 failure**（含新增 `!cached.contains("\n")` 格式漂移守卫与 `"a/b 路径/转义"` 字节等价）。
2. **本轮新发现：0 P0、0 P1、0 新 P2**；新增 3 条 P3（1 条纯文档、2 条交叉域加固），并复核确认前两轮的 7 条残余仍然存在（preload 守卫 false-negative、rowIndex 直接写不变量、gap 未入几何键、NSCache 预算/DPI 口径、filmstrip 续页下标、LRU 触碰窗口、启动计时口径）。其中 R2A-04/R2A-05/R2A-06 属"已知未修"而非漏报。
3. **Linux 门禁 16/16 PASS**（HEAD 实跑，含 boundary 的 check-no-legacy）；app Swift `-parse` **463/463 EXIT 0**。这些只证明语法/静态规则，不证明可编译。
4. 需要 macOS 才能闭环的项：round-2 三处修复的 macOS 构建确认、SwiftUI body 失效时序、@Observable+didSet 运行时刷新、NSCache 淘汰/NSImage DPI、DateFormatting 在 Darwin 的逐字节输出与并发安全、启动时序。

## 1. round-2 fix（5bcf915b）逐项复验

### 1.1 DateFormatting：`withFormatter` 签名与 4 个调用点（R2A-01）

代码（HEAD，`Sources/GatherUI/Support/DateFormatting.swift`）：
- 声明 `:59` `private func withFormatter<T>(key: String, make: () -> DateFormatter, body: (DateFormatter) -> T) -> T`；
- 多尾闭包调用 `:77 / :108 / :120 / :132` 均写 `body:` 标签（`mediumShort`/`pattern`/`localizedTemplate`/`shortShort`）。
- 该函数 `private` ⇒ 调用点只可能在本文件；**单文件 `-typecheck` 通过即证明 4 处标签全部正确**，不依赖 `-parse`。

证据（本轮实跑）：
```text
$ CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc .gather/swift62/usr/bin/swiftc \
    -typecheck -swift-version 6 .gather/r3app-review3/DateFormatting.swift   # HEAD blob 原样拷贝
EXIT=0（无诊断）
```
语义回归（旧 per-call oracle：每次新建同配置 formatter/ISO 解析器/ByteCountFormatter 类方法）：
```text
# .gather/r3app-review3/dfprobe：把 HEAD DateFormatting.swift 原样与 oracle main.swift 一起 -O 编译
15 组环境（TZ ∈ Shanghai/New_York/Berlin/UTC/Kiritimati × LC_ALL ∈ en_US/de_DE/th_TH）
每组 checks=1467 mismatches=0（5/11 locales × 8 dates × {mediumShort, shortShort, 6 pattern,
4 localizedTemplate, ISO 输出, 3 fixedUTC} + 16 fileSize + 11 ISO 解析 + 7×3 parseFixedUTC）
```
并发/锁作用域：
```text
# .gather/r3app-review3/dfhammer（同一 DateFormatting.swift + 16 线程 × 250 轮，每轮 ~86 次混合调用）
group_wait=success iterations=4000 failures=0   # 约 34 万次格式化，无死锁/无输出漂移
```
静态复核：
- 持锁范围 = 取/建 formatter + `body(formatter)` 全程；`make`/`body` 闭包只构造 `DateFormatter` 或调用 `string(from:)`，**不回调本类**（`:59-70`）⇒ NSLock 非重入无死锁路径；
- `fileSize(:146)`、ISO 解析/输出（`:89/:96/:162`）、`parseFixedUTC/formatFixedUTC(:168/:174)` 各自持同一把锁，`fixedUTCFormatter(:185)` 注释声明"调用方已持锁"（唯一调用点都在锁内）⇒ 无重入；
- 环境键 `:196-198` = base|locale.identifier|Calendar.current.identifier|TimeZone.current.identifier，等价于旧实现"每次新建时取隐式环境"；与 `fileSize` 的 Locale.current 失效口径一致。
- **限制**：Linux corelibs 的 `Locale.current` 不随 `LC_ALL` 变化（15 组环境输出同 en_001），`TimeZone.current` 也只在进程启动时读取 ⇒ "运行中改时区/日历换 formatter"的缓存跟随只能在 macOS 动态验证；输出对拍在 5 个 TZ 进程内为 0 mismatch。

### 1.2 CullingViewModel：两个 `private(set)` 成员（R2A-02 / R2A-03）

代码（HEAD）：
- `CullingViewModel.swift:156` `@ObservationIgnored private(set) var pageAssignmentCount = 0`（`page.didSet :46-47` 自增）；
- `CullingViewModel.swift:322` `@ObservationIgnored private(set) var navigationGroupsVersion = 0`（`navigationGroups.didSet :318` 自增）；
- 跨文件**只读**：`+Preload.swift:188/196`、`+Navigation.swift:238/245`；全仓无其它写点（grep 声明唯一、写点只在本文件 didSet）。

证据 A：真实模块级 typecheck（本轮新做，非 parse）。用 `GatherProtocol` 真模块 + 最小 `SwiftUI` 替身（只 re-export Foundation/Observation——`CullingViewModel.swift` 只 import SwiftUI 而**不使用任何 SwiftUI 符号**，grep 证实，任何真实符号使用都会报未定义而不是被静默放过），编译：
`CullingViewModel.swift`、`+Actions`、`+Keywords`、`+Load`、`+Navigation`、`+Triage`、`+Writeback`（均为真实文件），以及 `SessionPageModel/PageVisibility/CommandError/LocalizedText/JSONValueDecoding/DeliveryErrorPresentation/GatherLocalization/CullingNotice/CullingSelectionSnapshot/CullingFilterState/CullingGroupDecision/CullingViewStateStore/CullingSyncFlow/C1RoundTripPorts` 等 15 个真实 support 文件（另 2 个文件 `L10n.swift`/`GatherEventCenter.swift` 为 scratch 副本、仅删掉未使用的 `import os` 行；`L10n` 含 Apple-only API 因此成为剩余 4 条错误的唯一来源）；仅 4 个符号来自被排除的 `+Grid/+Preload`（AppKit/SwiftUI 文件），用声明桩提供：
`applyClientProjection`、`CullingClientProjection`、`CullingClientProjectionCache`、`invalidateSelectionSnapshot`、`scheduleNeighborPreload`（后两者为真实函数体的逐字副本/空实现）。
```text
$ swiftc -typecheck -swift-version 6 -module-name GatherUI -I <GatherProtocol> -I <SwiftUI stub> ...
EXIT=1
# 全部 4 条主错误（10 行）都在 .gather 里被排除的 Darwin-only 依赖 L10n.swift：
#   L10n.swift:77/81 cannot find type 'OSAllocatedUnfairLock'（os 模块，Apple-only）
#   L10n.swift:558/572 cannot convert (String, NSNumber) to (format, any CVarArg)（Darwin NSNumber 一致性，Linux 差异）
# 22 个真实 GatherUI 被检文件：0 error（含 CullingViewModel.swift 全部改动区 + +Navigation.swift:238/245）
```
说明：`+Preload.swift` 本身 import AppKit（`NSImage`）且依赖 `PhotoThumbnailCache/ThumbnailDiskCache`，Linux 不能整文件编译，其实质修复（`:188/196` 读 `pageAssignmentCount`）由下面的最小两文件探针覆盖；`+Navigation.swift` 已在上面的真实 typecheck 中通过。

证据 B：最小两文件探针（`.gather/r3app-review3/obs2`，`-O -swift-version 6` 编译并运行）：
- 声明文件 `VM.swift` 复刻 `@MainActor @Observable final class` + `@ObservationIgnored private(set)` 两成员 + 同型缓存访问器（`navigationGroupSizeByPhotoID`/`similarGroupAssets` 的命中路径先读被观察属性）+ didSet；另一文件 `Ext.swift` 只读两成员。
- 编译 EXIT 0（跨文件只读合法）；负向探针（另一文件赋 \`pageAssignmentCount = 99\`）→ 编译失败：
  `error: cannot assign to property: 'pageAssignmentCount' setter is inaccessible`、`navigationGroupsVersion` 同 ⇒ `private(set)` 写面确实收紧（round-2 建议的收口方式成立）。
- 运行结果（真实 `Observation.withObservationTracking`）：
```text
1 navigationGroupsChanged fired=true     # R5-01/R2-A1 依赖仍然有效
2 versionOnlyBump fired=false            # 版本号 @ObservationIgnored，不是伪依赖
3 pageChanged fired=true                 # similarGroupAssets 依赖 page
4 assignmentOnlyBump fired=false         # 纯缓存代数不触发视图失效
5 ignoredVersionRead fired=false         # 跨文件读 private(set) 成员不登记依赖
```
- 另测 `@Observable` + `public internal(set) var` + didSet + `@ObservationIgnored tuple` 组合（`.gather/r3app-review3/obs3`）编译通过；`@Observable` 属性 didSet 在 Swift 6.2 下会触发（`.gather/r3app-review3/observe-didset`：counter 按预期自增、`withObservationTracking` onChange 触发）⇒ app 里 5 处 `didSet` 自增缓存的机制成立。
- 结论：round-2 两处 `private(set)` 修复**正确、完整（无遗漏写点/调用点）、无行为副作用**（只读语义不变，@ObservationIgnored 语义不变）；仍需 macOS `swift build` 最终确认。

### 1.3 JSON/oracle 相关（round-2 P0-4，core Tests；app 语义相邻）

- 真实 typecheck：freshly build `GatherProtocol`（`swiftc -emit-module/-emit-library` 全 target 源 ET EXIT 0）后
  `swiftc -typecheck -swift-version 6 -I <protocol> Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift` → **EXIT 0**（修复了 `try` 位于 `==` 右侧的编译中断）。
- 语义 harness（`.gather/r3app-review3/jsonharness`，链接真实 `libGatherProtocol`）：按测试逐条断言运行
  `checks=40 failures=0`，覆盖：10 个值（含新增 `.string("a/b 路径/转义")`）的 stringify↔parse 等价、**新增 `!cached.contains("\n")` 守卫**（对含换行字符串值也成立：JSON 转义后无字面换行）、非对象字节等价、roundTrip 的 `parsedBaseline` 复用（`:131-134`）、`JSONValue(encoding:)` 与默认 coder 等价、malformed 抛 `DecodingError`。
- 影响面：app 侧 `Support/JSONValueDecoding.swift:63-67` 的 `JSONValue(from:)` 由"每次新建 JSONEncoder/Decoder"改为 `JSONValue(encoding:)`（共享 `JSONValueCoding` 静态实例）。输出/错误类型等价已由上述 harness 实测（Linux）；**新增的跨线程暴露见 R3A-02（P3）**。

## 2. Findings（本轮新发现 + 复核确认的残余）

> 前两轮已记录且本轮确认"仍存在/未修"的项标注原 ID，不算漏报；"新"列 = 本轮独立发现。

| ID | 严重度 | 位置（HEAD file:line / commit） | 问题 | 证据（本轮实跑） | 建议修复 | 置信度 | macOS 不可验证 |
|---|---|---|---|---|---|---|---|
| **R3A-01**（新） | P3（文档） | `Support/DateFormatting.swift:41,46` | 注释仍写旧函数名 `formatter(key:)`，实现已改名 `withFormatter`（6e940350 改名、5bcf915b 改标签时未同步）。误导后续维护者对锁/缓存语义的判断。 | `grep -n "formatter(key:" → 仅注释一处`；实现声明在 `:59` | 注释改为 `withFormatter(key:make:body:)` | 高 | No |
| **R3A-02**（新，交叉域） | P3 | `Support/JSONValueDecoding.swift:63-67`（242d6b21/2b9bf100 起）；core `GatherProtocol/Protocol/Core.swift:122-125` | app 的 `JSONValue(from:)` 现在使用 **共享静态** `JSONValueCoding.encoder/decoder`；Apple 未承诺 `JSONEncoder/JSONDecoder` 并发安全，而 app 调用点 `LiveExportAPI` 是 `@unchecked Sendable`（`:41`，调用 `:405/:471`），可能与其他线程/core 调用并发使用同一实例。当前 swift-foundation 实现每次 encode/decode 新建内部 writer/reader、实例本身只读，故实践上大概率安全，但属未验证假设（Darwin Foundation 实现不同）。 | 读代码 + grep 调用点；Linux 无法跨线程复现 Darwin 行为；JSON 值等价已闭环（§1.3） | 二选一：共享 coder 加锁（core 侧，代价 µs）、或在注释/文档标注"仅顺序复用"并避免并发调用；D 类风险交 core 册合并定级 | 中 | Yes（Darwin Foundation 并发语义） |
| **R3A-03**（新，弱） | P3 | `Culling/CullingFilmstrip.swift:74-86` | task-22 把续页判断从"body captured enumerated index"改为 `onAppear` 时 `pageIndex(ofPhotoId: asset.photo.id) ?? 0`：若 body 与 onAppear 之间页被替换（决策回显/刷新），旧资产 id 不在新页 → `?? 0`，`index >= count-4` 对 count>4 恒 false ⇒ 该次 onAppear 不续页（旧实现按旧下标可能触发一轮）。新页尾部项各自 onAppear 会补上，实际影响≈0；且重复 id 取首个（R2A-12 已记录）。 | 读代码 + `pageIndex` 语义（.gather probe 覆盖首现语义）；无 I/O 探针可证真机时序 | 注释说明"stale asset 的 onAppear 预期 no-op"，无需改逻辑 | 高 | Partly（SwiftUI onAppear 时序） |
| **R3A-04**（R2A-04，确认未修） | P3（性能副作用） | `Culling/CullingViewModel+Preload.swift:188-197`；触发方 `+Actions.swift:28-44` | preload 过期守卫用 `pageAssignmentCount`：**任何 page 重新赋值（含决策回显只改 state 的同内容替换）都会让在途预取整体放弃**；而 `applyDecisionStates` 每次决策 `pageVersion += 1; self.page = CullingPage(...)` ⇒ `pageAssignmentCount &+= 1` ⇒ 放弃；决策回显不触发 `scheduleNeighborPreload`（触发点仅 currentPhotoId/pageSignature/onAppear/setVisible），同照片的预热要到下一次切图才重来。正确性无风险（页/当前照片真变化时中止是**对的**）。 | 代码路径逐行 + 触发点 grep（CullingWorkbenchViewer:514/545/558、CullingViewModel:630、+Preload:151）；round-2 R2A-04 建议的"await 后重算 plan 等值比较"仍未落地 | 采用 plan(assets:currentPhotoIndex:) 结果 Equatable 比较代替 assignment 计数（plan 最多 5 项，O(1)），只放弃"目标真变化" | 高 | Partly（时序窗口需 macOS/真机） |
| **R3A-05**（R2A-05，确认未修） | P3（不变量） | `Gallery/GalleryGrid.swift:18-57` | `rows` 仍是 internal 可写；`rowByItemIndex` 只在 `store` 重建，直接写 `rows`（既有测试 `JustifiedLayoutTests.layoutCacheMapsItemIndexToRow` 就如此）依赖兜底线性扫；若未来在 store 之后直接改 rows，映射命中会返回**陈旧行号**。worktree 本轮只补了注释（`git diff` 仅注释），不变量仍靠约定。 | 读代码 + 既有测试 `Tests/GatherAppTests/JustifiedLayoutTests.swift:173-199`（直接写 rows）；生产写点只有 store/reset（grep） | `rows` 收成 `private(set)`+测试改走 `store`，或给 rows 加 didSet 重建映射 | 高 | No |
| **R3A-06**（R2A-06，确认未修） | P3 | `Culling/CullingGrid.swift:224-300`（`sameGeometry` :287）vs 调用点 `:492-499` | 同几何复用只比较 id/量化宽高/精确 width/rowHeight，**未比较 `gap`**；当前全仓唯一调用点传常量 `gap: 8`（grep 确认），现状正确，未来 gap 随密度/主题变化会复用错误行几何。 | `grep -n "gap:" CullingGrid.swift` → 唯一 `:498 gap: 8`；`sameGeometry` 无 gap 入参 | gap 并入复用比较或函数注释写死"gap 必须恒定" | 高 | No |
| **R3A-07**（R2A-08，复核后维持；前提本轮再验） | P3（内存/淘汰，需 macOS 实测） | `Support/PhotoThumbnailView.swift:803-824`；`Support/ThumbnailDiskCache.swift:105-141` | ① cost 由点改像素本身对当前数据路径**≈no-op**（本轮独立复核：`RAWDecoder.encodeJPEG` 只设 `kCGImageDestinationLossyCompressionQuality`，不写 DPI ⇒ `NSImage(data:)` size==像素；round-2 的"17× 悬崖"前提不成立），真正残余是**既有** 512MB/单 NSCache 预算：2560 档 ≈21MB/张 ⇒ ~24 张；② 新增 `touchInterval=3600s` 触碰节流：热文件 mtime 最多滞后 1h，>512MB 时可能先淘汰"1h 前碰过但仍在读"的项（文档已声明该取舍）；③ `data()` 仍为"存在性判定读整份 JPEG"（既有）。 | 读 `gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift:449-459`；本地无 macOS 无法测 NSImage.size/originalRep 行为与淘汰 | 预算/分桶由 macOS 实测后定；`touchInterval` 可接受；可在 `data()` 用 `fileExists` 替代整读（行为等价，需单独验证） | 中 | Yes |
| **R3A-08**（新，弱，文档口径） | P3 | `GatherHost/AppBootstrap.swift:54-61,147-200,424-430` | 启动计时新增：`firstScene` 在 `self.scene = state` 后、C1 重放/回调接线**之前**取（label 自称"场景首次发布墙钟上界"，可接受）；`total` 在接线完成后取；`languageSeed` 与 `runtimeStart` 并行、各自计时（日志已注明）。并行安全抽查：`AppRuntime.swift` 内无 `L10n/GatherLocalization` 引用（grep 空），两 await 均在 scene 发布前完成。风险为**口径误读**（把各行相加会重复计入并行段），非代码缺陷。 | 读代码 + `grep L10n/AppRuntime.swift` 空；`startupMillisecondsText` 取整为四舍五入 0.1ms（`&+50_000 / 100_000` 正确） | 维持；若担心可在 summary 标注 overlap 或把 total 改为"首个阶段→最后阶段" | 高 | Partly（真实启动时序/DB 竞争需 macOS） |
| **R3A-09**（R2A-11/R2A-12 同域，确认） | P3 | `Gallery/GalleryView+Content.swift:332-370`、`Culling/CullingFilmstrip.swift:74-86` | ⌘A 全选（可达 2 万）后方向键：`moveGalleryCursor` 锚点改为 `selectedIds.compactMap{ indexByID[$0] }.min()`，由 O(n×k) 降为 **O(k)**（k=选中数）——仍非 O(1)；filmstrip 重复 id 取首个的语义变化同 R2A-12。 | 读代码 + `indexByID` 构建点 `+Derived.swift:141-159`；无新红测试 | 若要 O(1)：VM 内缓存"最小可见选中下标"（key=filtered 代数+selectionVersion） | 高 | No |

> 说明：R2A-01/02/03/04（round-2 的 3 个 P0 + preload P3）本轮全部确认已修或"已知未修"，**未复现任何编译中断**。

## 3. Verified-OK（本轮独立复核，含 round-1/2 claims 抽查）

1. **5bcf915b app hunks 100% 重读**：DateFormatting 标签、CullingViewModel 两个 `private(set)`；无其它 app 文件改动。HEAD `git show 5bcf915b --stat` 确认 app 仅此 2 文件。
2. **DateFormatting 全部缓存方法**（mediumShort/shortShort/pattern/localizedTemplate/fileSize/ISO 解析/ISO 输出/fixedUTC）：输出对拍 0 mismatch（§1.1）；持锁无重入路径；环境键含 locale+calendar+timeZone；`fileSize` 与 `ByteCountFormatter.string(fromByteCount:countStyle:)` 16 个边界值一致（0/负/Int64.min/1e12…）。
3. **CullingViewModel 系列**（perf task-10/22 与 round-1/2 修复）：
   - `pageAssetIndex` 位置索引：命中 O(1)、同 id 序列 state-only 替换复用、重排/换页重建；重复 photoId 保留首个（与旧 `first(where:)` 同义，逐点读代码 + probe 语义）；
   - `currentAsset/pageIndex/pageAsset/currentPageIndex/similarGroupAssets/navigationGroupSizeByPhotoID/sortedSelectedIds/selectionSummary` 的 Observation 命中路径均先无条件读被观察属性（§1.2 探针 1/3 通过），`@ObservationIgnored` 版本号不产生伪依赖（探针 2/4/5）；
   - `selectionSummary` 键=pageVersion+selectionVersion，且 `page.didSet` 额外清空（双保险）；`selectedPhotoIds.didSet` 对 insert/formIntersection 等 mutate 均自增（`@Observable` didSet 实测触发）。
4. **Gallery 派生缓存**：`pagesGeneration` 的 4 个写点（`+Load:258-259`、`+Events:93-94`、`+Filter:118-119`、`+Scroll:174-175`）都伴随 bump；`flatCache/filteredCache/loadedPhotoLookupCache` 同代数失效；`filteredCache` 新增 ids/indexByID 与 photos 同一次写入（`storeFilteredPhotos` 唯一写点）；`loadedPhotoLookup` 的 id/path/variant/filename 与旧 `contains{...}`/`first(where:)` 语义等价（重复 id 取首个）。
5. **Lightbox 身份校验**：`resolvedCurrentIndex` 命中后校验 `photos[index].id == currentID`，未命中回退线性 `firstIndex`；空数组/nil id/id 消失/重排与旧语义等价；唯一理论差异仍是重复 id（R2A-07 已记录）。`.task(id: currentID)` 预取用 resolved 下标，与旧"任务内按 id 查找"同源。
6. **preload 真变化保护**：await 后 `pageAssignmentCount`/currentPhotoId 双比较能挡住"页/当前照片变了还消费旧 misses"；`computePreloadMisses` 的 nonisolated+Task.detached+静态缓存查询模式用同形探针 `.gather/r3app-review3/preload-compile` 真实 `-typecheck -swift-version 6` EXIT 0（`CullingPreloadCandidate/Plan: Sendable`；`preloadPreviewDimension` 已 `nonisolated`）。
7. **GalleryGrid/CullingGrid 布局缓存**：`rowIndex` O(1) 映射 + 未命中原语义回退（既有测试断言路径成立）；`CullingGridLayoutCache` 首分支（version+Int 宽高+count）与旧 string key 行为逐字等价，新增 `sameGeometry` 仅在同 id/宽高/精确尺寸时复用；`packedSize` clamp 到 UInt32（>4.29e9px 非单射为理论值，实拍不可达，R2A-10 已记录）。
8. **NSCache/DPI 前提**：独立复核 `RAWDecoder.encodeJPEG` 无 DPI 写出（§R3A-07）⇒ round-2 对 R2A-08 的降级成立；像素 cost 实现（取最大 rep 的 pixelsWide×pixelsHigh，线性 fallback）读代码无越界/负 cost。
9. **启动计时**：`DispatchTime.uptimeNanoseconds &-` 单调；0.1ms 四舍五入正确；日志一行/次冷启动；失败路径日志带耗时；未改变控制流。
10. **门禁与语法**：HEAD 16/16 Linux 门禁 PASS（check-no-legacy / cleanup-ratchet / layering / domain-events / domain-writes / duplicate-symbols --strict / test-catalog --strict / preview-surface --strict / design-system / select-star --strict / protocol-surface --strict / coded-errors / backlog-evidence / repo-hygiene（PATH 含 .gather shellcheck）/ docs-facts / perf-ratchet）；app Sources+Tests `-parse` 463/463 EXIT 0。**这些不证明可编译**（round-2 P0 正是 -parse 全绿但 typecheck 红）。
11. **跨文件 private 成员再扫描**（独立重跑 round-2 启发式）：本地 diff 新增 31 个 private 成员名 × 其它 app 文件 `.name` 命中 2 条，均为同名字段/注释误报（`filteredCache.indexByID` 元组字段、注释里的 `LightboxView.prefetchAdjacent`）⇒ 未发现新的跨文件 private 访问编译错误；round-2 已修的两处是唯二真阳性（与 round-2 结论一致）。

## 4. Coverage & Limitations

**已覆盖**
- 5bcf915b app 部分 100% 逐行 + HEAD 实际代码复核；DateFormatting oracle/并发锤测；Observation 依赖矩阵与 `private(set)` 负向探针；真实模块级 typecheck（13 个真实 GatherUI 文件 + 4 个桩符号，2 个 Darwin-only 依赖除外）；JSON 测试真实 typecheck + 断言 harness；app 全量 `-parse`；16 道 Linux 门禁；跨文件 private 访问启发式重扫；NSCache/DPI 前提复核；启动并行安全抽查。
- origin/main..HEAD 中 app 高危/大改动文件（CullingViewModel 系列、CullingGrid、GalleryGrid/+Derived/+Content/Lightbox、AppBootstrap、ThumbnailDiskCache、PhotoThumbnailView、CullingInspector、Persons/Similarity/Duplicates/Export/Metadata 的 formatter 调用迁移、设计令牌迁移）逐一读改动后上下文；`withFormatter/prefetchAdjacent/formatter(key:)/knownGroupCount` 等改名函数的**调用点一致性 grep**（无残留旧调用）。

**未覆盖 / 上限（必须保留）**
1. **无 macOS/Xcode**：未 `swift build`/`swift test`/链接/运行 App，未 `check-warnings`，无 Instruments/真机 UI。Linux 上真实 typecheck 只覆盖不 import Apple 框架的文件；**AppKit/SwiftUI/CryptoKit/CMake 系文件仍只有 `-parse`**（app 109 文件里 80 个 import Apple 框架）。因此 macOS 首跑仍须优先验证：gather-app 全量 build、GatherCoreTests（JSONValueCodingTests）、DisplayDateFormattersTests、UI 冒烟。
2. **SwiftUI 运行时**：body 失效时序、@Observable+didSet 的刷新顺序、ForEach 身份/滚动、NSCache 淘汰与内存峰值、NSImage DPI、`onAppear` 时序等只能在 macOS 复验。
3. **Apple Foundation 与 corelibs 差异**：DateFormatting 的"运行中改时区/日历"缓存跟随、Darwin 上 DateFormatter/ISO8601DateFormatter 的极端输入行为、ByteCountFormatter 成本只能在 macOS 闭环；本轮 15 环境对拍是 Linux 闭环证据。
4. **CullingViewModel 真实 typecheck 的边界**（22 个真实文件；`L10n.swift`/`GatherEventCenter.swift` 为 scratch 副本、其余 2 个依赖为 `os`/Bundle.module 替身）：`+Grid.swift`（SwiftUI 视图+NSEvent）、`+Preload.swift`（AppKit）、所有 View 文件未编译；试验中使用 4 个声明桩（仅签名/空体）与 2 个 Darwin-only 依赖排除 ⇒ 不能替代 macOS 构建；`+Preload` 的跨文件只读由两文件探针覆盖。
5. 性能数字均为 Linux 微基准/结构证据，不代表 Darwin；测试/文档/门禁域细节见 R3-tests/R3-docs/R3-tooling 册。

## 5. 附：本轮证据清单（可复跑）

- `git show 5bcf915b` / `git diff origin/main..HEAD -- desktop/native/gather-app` / `git status --porcelain`（app 仅 GalleryGrid 一行注释未提交）。
- DateFormatting：`.gather/r3app-review3/dfprobe`（HEAD 文件原样 + oracle，15 环境 ×1467 checks，0 mismatch）；`.gather/r3app-review3/dfhammer`（16×250，0 失败）；`.gather/r3app-review3/DateFormatting.swift + typecheck EXIT 0`。
- CullingViewModel：`.gather/r3app-review3/obs2`（IP 两文件探针：编译/运行/负向写拒绝，5 项 Observation 断言）；`.gather/r3app-review3/obs3`（public internal(set)+didSet 组合）；`.gather/r3app-review3/observe-didset`（@Observable didSet 触发）；`.gather/r3app-review3/culling-typecheck/final-errors.txt`（真实模块级 typecheck：22 真实文件 0 error，仅排除的 Darwin-only L10n 4 条）。
- JSON：`.gather/r3app-review3/protocol`（fresh GatherProtocol 构建 EXIT 0）；`swiftc -typecheck ... JSONValueCodingTests.swift` EXIT 0；`.gather/r3app-review3/jsonharness` 运行 checks=40 failures=0。
- 语法/门禁：app `-parse` 463/463；16 道 `scripts/check-*.sh`（CI 同参数）全 EXIT 0。
- 结构核对：`grep -n "pageAssignmentCount\|navigationGroupsVersion" Sources Tests`（声明唯一、写点仅本文件 didSet）；`grep -n "formatter(key:"`（仅注释）；`grep -n "gap:" CullingGrid.swift`（唯一调用点常量 8）；`grep -n "pagesGeneration" Gallery*.swift`（4 写点全 bump）。

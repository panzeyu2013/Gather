# gather-core 性能审计 + 安全修复（task-5）

- **日期**：2026-11-17（数据基线：git HEAD `e5c54f37` + 工作区改动）
- **执行**：perf-core（子代理，写作用域 `desktop/native/gather-core/Sources/**` + 本文档）
- **范围**：GatherProtocol / Persistence / Delivery / Analysis / Application / MetadataIO 的
  热路径静态审计；只做行为保持的机械修复。
- **硬约束遵守情况**：无公开 API 签名变更、无 Schema DDL / fingerprint 变更、无行为/输出
  顺序/错误语义变更、无新增依赖、无测试改动；lead 的未提交机械修复（24 文件去尾随空白 /
  补末行换行）保持原样。

## 1. 结论摘要

共 **7 组修复、10 个文件、约 23 处调用点编辑**（`git diff --stat`：10 files, +107 / −41）。
修复类别覆盖任务要求的四类中的三类半：

| # | 修复 | 类别 | 文件 | 影响面 |
|---|------|------|------|--------|
| F1 | JSONValue 编解码器共享实例（`JSONValueCoding`） | (a) 逐次 coder 分配 | GatherProtocol/Core.swift、DescriptiveMetadata.swift | 收口全仓 57 处 `JSONValue.parse/stringify` 调用 + 2 个泛型 JSON 往返辅助；元数据缓存行 `descriptive` 单次访问从 4 个 coder 降到 0 |
| F2 | TriageRepo 逐行 coder hoist（5 处） | (a) 逐行分配 | Persistence/Repositories/TriageRepo.swift | suggestion 读/写、model_review/quality/navigation 装配；20k 会话不再逐行 new coder |
| F3 | QualityService 逐行 decoder hoist（2 处） | (a) 逐行分配 | Application/Services/QualityService.swift | `get` / `getCachedBatch` 每行一次 `JSONDecoder()` → 每批一次 |
| F4 | 仓库层逐行 coder 收口（`RepoJSONCoding` + 3 文件 7 处） | (a) 逐行分配 | Persistence/Repositories/RepositorySupport.swift、CullingHistoryRepo.swift、PersonRepo+Projection.swift、PersonRepo+Identity.swift | 历史操作逐行解码、人物 bbox/keywords 逐行编解码 |
| F5 | NavigationService 日期解析共享化 + 逐行去重 | (a) 逐次 formatter 分配 | Application/Services/NavigationService.swift | 原每行 2 次 `parseISODate`（每次 3 个 formatter）+ 2 次 `filenameSequence`（每次编译正则）→ 每行 1 次共享解析/1 次正则；分组是 1 万张会话主成本之一 |
| F6 | Sidecar 读取去掉冗余 stat | (b) 可省的文件系统调用 | MetadataIO/SidecarXMPProvider.swift | 逐张照片读 sidecar：`fileExists` + `contents` 两次系统调用 → 一次 |
| F7 | `applyRelativeRanks` 消除 O(n²) 线性查找 | (d) 二次方模式 | Application/Services/QualityService.swift | 「相似组 × 组员」× `results.firstIndex` → 预建 photoId→index 字典 |

**未修复但已取证的热点**见 §6（正则编译、剩余 per-call formatter、N+1、sidecar 双解析等），
其中正则项因项目并发约定与 Swift 6.2 `Regex` 非 Sendable 的事实，**无法在 Linux 侧安全验证
macOS 编译**，故按「不做无法验证的修复」原则只报告。

## 2. 方法

1. **起点**：仓库此前已有数轮性能修复（`RepositorySupport.swift` 的 B-12/P2-1 日期
   formatter 共享、`ExportService+Plan` 的 E-3/P2-12 逐张 formatter/目录快照、`PhotoRepo`
   的 E-5 COUNT 下沉、`WorkflowRegistry` 的 D-2/E-2 checkpoint 编码等）。本次从 HEAD 现状
   重新取证，只报**仍然存在**的项，不重复已修项。
2. **检索口径**：在 `Sources/**` 全量 grep 下列模式并逐处确认调用频率（是否在
   `for`/`map`/逐行路径）：
   - 重量级对象逐次构造：`DateFormatter()`、`ISO8601DateFormatter()`、`NumberFormatter()`、
     `JSONEncoder()`、`JSONDecoder()`、`NSRegularExpression(`、`String(format:)`；
   - 文件系统调用：`fileExists` / `attributesOfItem` / `contents(atPath:)` 在循环或逐照片路径里的重复；
   - DB N+1：`for` 循环内的 `*Repo.xxx(` / `connection.prepare`；
   - 二次方模式：循环内 `Array.contains` / `firstIndex(where:)` / 重复 filter。
3. **区分标准**：`static let` 缓存（已修好的）视为 fine；每次调用新建、且在逐行/逐照片
   路径上的才计入。
4. **修复原则**：默认配置/同顺序/同错误分支的等价替换；不引入新依赖；需要
   `nonisolated(unsafe)`/`@unchecked Sendable` 才能通过并发检查的方案一律不做
   （`docs/DEVELOPMENT.md` §Swift 6 并发约定禁止用它们掩盖诊断；cleanup-ratchet 也不允许
   `@unchecked Sendable` 增长）。
5. **验证**：每个改动文件 `swiftc -parse -enable-bare-slash-regex`；跑仓库五个门禁（§5）。

## 3. 逐项修复（before → after）

### F1 JSONValue 编解码器共享实例

- `Sources/GatherProtocol/Protocol/Core.swift`
  - 新增内部 `enum JSONValueCoding`（:115-127）：`static let encoder/decoder`。
  - `JSONValue.stringify` / `parse`（:145 / :151）：由每次调用新建
    `JSONEncoder()/JSONDecoder()`（原 :132 / :139）改为复用 `JSONValueCoding`。
- `Sources/GatherProtocol/Protocol/DescriptiveMetadata.swift`
  - `JSONValue.init(encoding:)` / `decode(_:)`（:770-783）：两条泛型往返辅助同样复用
    `JSONValueCoding`（原每次 1 encoder + 1 decoder）。
- **为什么热**：`JSONValue.parse/stringify` 在 Sources 有 57 处直接调用；典型逐行调用方：
  `MetadataCacheRepo.swift:59-70`（`keywords` / `descriptive` 计算属性，16 处
  `.descriptive` 访问；`descriptive` 单次访问 = parse + JSONValue→DescriptiveMetadata 往返
  = 4 个 coder）、`BBoxParsing.swift:13`（`parseBbox` 13 处调用）、
  `IdentityPolicy.swift:35-38`（`modelSpace` 5 处调用，含逐 embedding 行过滤）、
  `PersonRepo+Projection.swift:158` 等。
- **等价性**：默认配置的 `JSONEncoder/JSONDecoder` 无跨调用可变状态（Foundation 已标
  Sendable；同库 `FaceConstraintCodec` 已有静态实例先例），输出字节与抛错/回落语义不变。

### F2 TriageRepo 逐行 coder hoist

`Sources/GatherPersistence/Database/Repositories/TriageRepo.swift`，5 处：
- `loadSuggestions` :234（原 :238 每行 `JSONDecoder()`）
- `replaceSuggestions` :269（原 :271 每行 `JSONEncoder()`）
- `loadModelReviews` :495（原 :507 每 chunk 内逐行 `JSONDecoder()`）
- `loadQuality` :526（原 :540 同上）
- triage 装配的 navigation_groups 解码 :701（原 :704 逐行 `JSONDecoder()`）
- **为什么热**：triage generate 对整会话（注释口径 20k 张）装配候选；`replaceSuggestions`
  逐条 INSERT，每行一个 encoder。
- **等价性**：decoder/encoder 提到循环外，默认配置不变。

### F3 QualityService 逐行 decoder hoist

`Sources/GatherApplication/Services/QualityService.swift`
- `get(sessionId:photoIds:)` :402-407（原 :405 逐行 `JSONDecoder()`）
- `getCachedBatch` :431-435（原 :431 同上）
- **为什么热**：每张照片一条 `result_json`（`technical_quality`），面板/重算按会话全量读。

### F4 仓库层逐行 coder 收口

- `Sources/GatherPersistence/Database/Repositories/RepositorySupport.swift` :109-119：
  新增内部 `enum RepoJSONCoding`（与 F1 同理由；Persistence 不能引用 Protocol 的 internal 符号）。
- `CullingHistoryRepo.swift` :47-49 增加实例 `encoder/decoder`（SavedSearchRepo 同款先例），
  替换 :61 `append`、:149 `deleteOperationsTouching`（原 :146 每行 `try?` decode）、
  :168 `makeOperation`（原 :165 每行 decode）。
- `PersonRepo+Projection.swift` :177 `decodeBbox`（原 :176）、:193 `jsonString`（原 :192）：
  `decodeBbox` 在 `reconcileSession` 逐 role_binding 行调用，`jsonString` 在逐 observation 插入调用。
- `PersonRepo+Identity.swift` :369 `parseKeywords`（原 :368）、:378 `jsonString`（原 :377）：
  person 合并/更新逐行调用。

### F5 NavigationService：日期解析共享化 + 逐行去重

`Sources/GatherApplication/Services/NavigationService.swift`
- 新增 `private enum LegacyWallDateParsers` :469-482：EXIF（`yyyy:MM:dd HH:mm:ss`）与空格
  （`yyyy-MM-dd HH:mm:ss`）两个**只读**静态 `DateFormatter`（`en_US_POSIX` / GMT，
  与旧实现逐字段一致；与 `IngestService.exifDateFormatter` 同模式）。
- `parseISODate` :484-500：带时区两分支改用 `tsParseISODate`（GatherPersistence 唯一 ISO
  解析器，`[.withInternetDateTime, .withFractionalSeconds]` → `[.withInternetDateTime]`
  的兜底顺序与旧实现逐条相同）；EXIF/空格兜底改用静态 formatter。原实现（:457-479）每次
  调用新建 2 个 `ISO8601DateFormatter` + 1 个 `DateFormatter`，且生产库 `date_taken` 多为
  EXIF 原值 ⇒ 兜底分支每行命中。
- `group(rows:type:gapSeconds:)` :275-316：逐行预计算 `timestamps` / `sequences`
  （:296-297），循环内改用下标（:300 / :304）。原实现每行对「当前行」和「上一行」各解析
  一次时间戳（2×3 formatter）、各 `filenameSequence` 一次（2× `NSRegularExpression` 编译）；
  burst/scene 两遍分组各跑一次全量循环。
- **等价性**：`previous != nil ⇒ 其行号恒为 index-1`（`current` 是连续后缀，仅在边界
  flush 后重新累积），因此下标取到的值与旧实现逐条相同；NaN/`!isFinite` 边界判定不变。

### F6 Sidecar 读取去掉冗余 stat

`Sources/GatherMetadataIO/SidecarXMPProvider.swift` :294-300：`readSidecar` 由
`fileExists(path) && contents(atPath:)`（2 次系统调用）改为只调 `contents(atPath:)`
（不存在/不可读均返回 nil，语义相同）。这是逐张照片读取 sidecar 的路径。
- **等价性**：文件存在可读 → 读出；缺失/不可读/是目录 → `nil` → 返回空 `ParsedSidecar()`，
  与旧实现一致。

### F7 QualityService.applyRelativeRanks 消除 O(n²)

`Sources/GatherApplication/Services/QualityService.swift` :472-505（新增索引 :487-490、
  替换点 :497）：预建
`indexByPhotoId`（保留首次出现下标，与 `firstIndex(where:)` 同义），循环内 O(1) 取位置，
替代原 :489 的逐组员线性 `results.firstIndex`。相似组覆盖整个会话时旧实现是 O(n²)。
- **等价性**：方法内只写 `relativeRank`，不增删 `results` 元素，下标稳定。

## 4. 验证证据

命令（`/root/projects/Gather`，Linux；`.gather/swift62` 为 Swift 6.2 工具链）：

```bash
SC=.gather/swift62/usr/bin/swiftc
for f in <10 个改动文件>; do
  $SC -parse -enable-bare-slash-regex "$f"   # 期望无输出、退出码 0
done
```

实测：10/10 `PARSE_OK`，无输出、无错误。

门禁（全部在改动后运行）：

| 门禁 | 结果 |
|------|------|
| `./scripts/check-protocol-surface.sh --strict` | **PASS**（所有模块 public_types/public_declarations 不高于 baseline；新增符号均为 internal/private） |
| `./scripts/check-layering.sh` | **PASS**（0 处越层 import） |
| `./scripts/check-select-star.sh --strict` | **PASS**（Sources 4 处 = baseline 4；Tests 1 处 = 白名单） |
| `./scripts/check-coded-errors.sh` | **PASS**（0 处裸码字符串；4 处反解均已标注） |
| `./scripts/check-cleanup-ratchet.sh` | **FAIL（+1 unchecked_sendable，非本任务改动）** —— 见下 |

**cleanup-ratchet 唯一 FAIL 的归因**：`unchecked_sendable` 61 vs baseline 60，增量来自
**并发 teammate 在 gather-app 的改动**：
`desktop/native/gather-app/Sources/GatherUI/Support/DateFormatting.swift:104`
`final class DisplayISODateParsers: @unchecked Sendable`（不在本任务写作用域）。
对本任务 10 个改动文件做 `git diff` 逐项核对：新增 `@unchecked Sendable` **0**、
`prepare(` **0**、`nonisolated(unsafe)` **0**、`SELECT *` **0**；`try?` 新增 7 行/删除 7 行
（均为 `JSONDecoder()` → `decoder` 的同行替换，**净增 0**），`try_optional` 实测 260
（baseline 261，未上涨）。该文件修复后此门禁应回绿（需 lead / perf-ui 处理）。

## 5. Linux 限制（验证上限，务必按此口径引用）

- 本机 **无 macOS/Xcode**，不能 `swift build` / `swift test`；因此**没有编译期类型检查、
  没有运行时/基准测量**。现有验证 = 语法解析 + 五个静态门禁（含 ratchet 计数）。
- 涉及并发安全标注的改动（若做）无法在 Linux 用 macOS 26 SDK 验证；本次刻意避开所有需要
  `nonisolated(unsafe)`/`@unchecked Sendable` 的方案。
- 预期收益来自「分配次数/系统调用次数/O(n²)→O(n)」的静态推导与仓库历史实测注释
  （`RepositorySupport.swift:13-18` 记录旧 DateFormatter 实测 ~55µs/次、复用 0.64µs，86×；
  `ExportService+Plan` E-3 记录 1 万张 × 3 遍 ≈ 3 万个 formatter），**不是**本次运行测量。
- 建议在 macOS 上以既有基准入口复测（`swift test --filter NavigationServiceTests` 正确性；
  `gather-core-benchmarks` 观察相似度/triage 相关路径；日志 sink 不在本次范围）。

## 6. 未修复发现（已取证，按热度和风险排序）

### 6.1 逐次正则编译（类别 a，安全阻塞）

| 位置（HEAD 行号） | 现状 | 为什么热 |
|---|---|---|
| `GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:34-75` | 每次调用编译 2 个 `NSRegularExpression`（:37 declRegex、:59 tagRegex）；非规范前缀存在时还要对每个标签 × 每个替换再 `escapedPattern` + `replacingOccurrences(options: .regularExpression)`（每次都编译） | `normalizeKnownPrefixes` 被 `readSidecar` 每张照片调用一次（:310），metadata 全库读/扫描即逐张命中 |
| `GatherMetadataIO/SidecarXMPProvider+IPTC.swift:99-111,127-134` | `mergedAltElement` 每个字段编译 1 个正则；`langAttribute` 每个 `rdf:li` 再编译 1 个 | 逐字段写盘路径（描述性元数据批量写回） |
| `GatherApplication/Services/NavigationService.swift:439-447`（`filenameSequence`） | 每次调用编译 `(#"(\d+)(?!.*\d)"#)`；F5 已把逐行调用次数减半，但仍是每行一次编译 | burst/scene 分组逐行 |

**不做原因**：仓库禁止用 `nonisolated(unsafe)` 掩盖诊断（`docs/DEVELOPMENT.md` §Swift 6
并发约定）；Swift 6.2（Linux 工具链实测）中 `Regex<Output>` 与
`NSRegularExpression`（macOS 侧 Sendable 标注无法在本机确认）都不能直接放 `static let`；
`cleanup-ratchet` 禁止新增 `@unchecked Sendable`。**在 macOS 上**可用
`OSAllocatedUnfairLock(unsafeState:)` + `withLockUnchecked` 的「锁盒子」惰性缓存
（`docs/DEVELOPMENT.md` 推荐模式）重做，并经 `swift build` 验证。

### 6.2 其余逐次/逐行 formatter（类别 a）

- `GatherProtocol/API/Inputs/MetadataInlineInputs.swift:218-261` `normalizedDateTime`：一次
  调用最多新建 6 个 `DateFormatter`（含分支内 wallOutput）。调用点频率：每次 inline
  metadata 写入请求 1 次 + `MetadataDiskReader.swift:196-197` 双源冲突比较每字段 1 次
  （按单张照片 API 触发，非列表行）⇒ 低频，暂不修。
- `GatherApplication/Logging/LogFileSink.swift:56-93`：每条日志 `fileExists` +
  `attributesOfItem` + 打开/关闭 FileHandle + `synchronize()`（fsync）。fsync 占主导；
  去掉一次 stat 收益 <3% 且属于日志可靠性路径，暂不修。
- 已确认**非热点**（逐请求/逐次，不修）：`ExportService+Plan.swift:69/462/478`
  （E-3 已改成每计划一份并循环复用）、`OutputService.swift:305-319/500-505`、
  `BackupStore.swift:52`、`MaintenanceService`、`S3ShareTransport`（网络调用前）、
  `ProofShare.swift:334`、`GatherTriageEval`/`GatherFaceBenchmarks`（CLI/基准）。

### 6.3 N+1 DB 往返（类别 c，仅报告、未改语义）

| 位置 | 现状 | 可用批量 API |
|---|---|---|
| `GatherApplication/Services/Culling/CullingService+Commands.swift:409-425` | 逐 `photoId` 一次 `getDecision`；变体检查再对每个兄弟变体各一次 `getDecision` | `CullingDecisionRepository.getByPhotoIds(sessionId:photoIds:)` 已存在（`CullingDecisionRepo.swift:118`） |
| `GatherApplication/Services/Maintenance/LibraryPackageService.swift:461-479` | 包导入逐 person binding 一次 `personsRepo.get(id:)`（几千条绑定 ⇒ 几千次点查） | `personsRepo.list()` 已在同函数 :457 全量读过 |
| `GatherApplication/Services/Indexer/IndexerService+Scan.swift:239-332` | 逐文件 `relinkMovedFile` / `updateIndexedFile` / `updateChecksum` | 扫描按文件推进、失败隔离语义，批量改写风险高 ⇒ 只报告 |
| `Application/Services/Photo/...` 一般结论 | 其余逐行仓库调用为「逐张独立提交」设计（`CullingRejectMoveService`、`TriageWritebackService`、`MetadataAttributeWriter`），改写会破坏失败隔离语义 | 不改 |

### 6.4 文件系统 stat/读盘（类别 b）

- `GatherMetadataIO/SidecarXMPProvider.swift:294-318`（读路径）：同一份 sidecar 数据被
  **解析两遍**（`SidecarXMLDelegate` + 归一化后的 `IPTCXMLDelegate`），并额外做
  `Data→String→Data` 归一化。合并成一次 SAX 遍历需要重构两个 delegate 的字段映射，
  超出「行为保持的机械修复」，暂不修（潜在收益：sidecar 读路径 XML 解析成本 ÷~2）。
- `GatherMetadataIO/SidecarXMPProvider.swift:195-215`（`readEmbeddedBase`/备份判断路径）：
  每个路径 `fileExists` 后再 `contents`；与 F6 同型但调用频率低（读写备份路径），暂不修。
- `Application/Services/Metadata/PhotoMetadataProjector.swift:29-74`：单张照片详情投影里
  1 次 `assetResolver.resolve`（点查）+ 1 次 `xmp.fileExists`；是单张 API（非列表循环），
  文档已声明「面板翻页不得产生 N 次 IO」，暂不修。
- `Application/Services/Maintenance/MetadataRetentionService.swift:267-268/440-441`：逐行
  `fileExists`（每行路径不同，不可 hoist）。

### 6.5 二次方/数组模式（类别 d）

- 已修：`QualityService.applyRelativeRanks`（F7）。
- 复核后判定**非实质热点**（数据规模小或单次）：`NavigationService.swift:203`
  `all.filter { uniqueIds.contains }`（组数量级≤百）、`PhotoFileOpsService.swift:76-89`
  `issues.contains`（问题列表个位数）、`ExportService+Plan.swift:641`
  `usedNames.contains`（重名唯一化循环，固有）。
- 其余仓库层/分析层（`Clusterer`、`ClusterGraph+*`、`Matcher`、`VectorIndex`）在既有
  基准与逐位一致约束下已高度优化，本次**不触碰**（避免破坏与 TS 位级一致的浮点顺序）。

## 7. 排序后的剩余建议（给 lead / 后续 wave）

1. **（高）macOS 侧补正则缓存**：按 §6.1 用 `OSAllocatedUnfairLock` 锁盒子缓存
   `NSRegularExpression`（`SidecarXMPProvider+IPTCReading`、`+IPTC`、
   `NavigationService.filenameSequence`），需 `swift build` 验证 Sendable 标注；
   预计 metadata 全库扫描（1 万张）省去 ~2 万次正则编译。
2. **（高）QualityService/TriageRepo 批量化读路径**：`TriageRepo.loadCandidates` 已在
   chunk 化；如后续有基准数据，可把 `loadSuggestions` 的逐行 JSON 解码进一步改为
   `JSONDecoder` 直解 DTO（当前已无 coder 分配，剩余为解码 CPU）。
3. **（中）Culling batch pick 的 `getDecision` N+1**：用现成
   `getByPhotoIds(sessionId:photoIds:)` 一次取回整批（含兄弟变体），再在内存判定
   manual 优先级；需保持「逐张失败隔离 + 历史合并成一条操作」语义，建议配测试改。
4. **（中）sidecar 单遍解析**：把 `SidecarXMLDelegate` 与 `IPTCXMLDelegate` 合并为一次
   SAX 遍历（读路径 XML 成本 ÷2）；因涉及两个字段映射表的合并，属重构级，需测试护航。
5. **（中）`MetadataInlineInputs.normalizedDateTime` 的 formatter 缓存**：改为
   锁盒子/共享实例（Protocol 层不能依赖 Persistence 的解析器）；先确认调用频率
   是否只出现在单张 API（当前判断：低频，收益有限）。
6. **（低）`LogFileSink`**：若 debug 日志量成为瓶颈，评估批量写/降低 fsync 频率
   （**会改变崩溃时日志完整性语义**，需产品决策，不建议默认改）。
7. **（低）`NavigationService.safeQuality`** 逐行 `JSONSerialization`：可换
   `Decodable`（注意 `status == "failed"` 与 optional 数值的旧语义），收益中等但风险中等。

## 8. 改动文件清单（10）

```text
desktop/native/gather-core/Sources/GatherProtocol/Protocol/Core.swift
desktop/native/gather-core/Sources/GatherProtocol/Protocol/DescriptiveMetadata.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/RepositorySupport.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/TriageRepo.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CullingHistoryRepo.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo+Projection.swift
desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/PersonRepo+Identity.swift
desktop/native/gather-core/Sources/GatherApplication/Services/QualityService.swift
desktop/native/gather-core/Sources/GatherApplication/Services/NavigationService.swift
desktop/native/gather-core/Sources/GatherMetadataIO/SidecarXMPProvider.swift
```

未触碰：`Sources/GatherSchema/**`（DDL）、`Tests/**`（另一个 agent 作用域）、
`Sources/GatherApplication/Services/C1/**` 等业务语义路径、`Package.swift`。

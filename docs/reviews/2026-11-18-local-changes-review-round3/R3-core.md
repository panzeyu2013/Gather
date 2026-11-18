# R3 gather-core 复核（第三轮）：round-2 修复独立验证 + 全量 core diff 新鲜扫描（review3-core / task-37）

- 基线：committed HEAD = 3486be0b；上游 origin/main = e5c54f37；round-2 基线 = 0288ea8d；round-1 基线 = 5ea5c38f。
- 范围：desktop/native/gather-core/Sources + Tests（origin/main..HEAD 61 文件，+915/−248）。重点：① 独立验证 round-2 core 修复（5bcf915b 中 4 个 core 文件）；② 复核 round-1 core 修复；③ 全量 core diff 新鲜扫描（DB/mmap/close/statement cache/N+1/async retry/LRU/Mutex/prepare 复用）。
- 环境/天花板：Linux Ubuntu 22.04，无 macOS/Xcode/Darwin SDK；Swift 6.2 Linux（.gather/swift62）。未在 macOS 编译、未跑 swift test、未跑 AppKit/CoreML target。本轮真实 typecheck 覆盖：真实 GatherProtocol 模块 + 真实 GatherPersistence 整模块（自建 os/CSQLite 最小 shim）+ 10 个改动文件级 typecheck（含 round-2 修复文件与 round-1 JobService 族）+ 6 个 Linux 语义探针（2 个链接真实仓库模块）。GatherApplication/GatherAnalysis 整模块不可 Linux 编译（CoreGraphics/ImageIO/CoreML/Vision/CryptoKit/CoreServices 的 import 无 #if 守卫）。
- moving target：结论以 committed HEAD 3486be0b 为准。评审期间 lead 已应用未提交 round-3 修复（applyImportedPicks 回退上游实时读、KeywordWriter 注释、DBStatementCache limit 16、Sidecar 锁注释、MetadataDisposition warn、docs 修正）；这些不属于评审基线，§7 只做独立复核记录。

## 0. 结论速览

- 未发现 P0/P1（无编译中断/崩溃/数据丢失/安全/必然回归）。round-2 core P0（JSONValueCodingTests 非法 try）已正确修复；round-2 的 4 处 core 修复 4/4 独立复验通过；round-1 core 修复全部复核通过。
- round-2 core 修复验证：
  1. JSONValueCodingTests：0288ea8d 版本真实 typecheck 4 error（’try’ cannot appear to the right of a non-assignment operator），HEAD 0 error/0 warning；真实 GatherProtocol 模块上 6 个 @Test 的 oracle 逻辑实跑 55 checks/0 fails；对象只比解码值 ⇒ 无 flake；新增换行守卫可拦 .prettyPrinted、slash fixture 可拦 .withoutEscapingSlashes。
  2. MetadataKeywordWriter 回退：语义 = 上游逐张 get + 逐行 catch（只丢失败行），try? 0 增量（try_optional 257/257 门禁复跑）；该文件真实 typecheck EXIT 0（真实 Persistence/Protocol + Delivery 最小 stub）。仅注释过时（R3C-04，worktree 已修）。
  3. SidecarRegexCache 去 T: Sendable：4 个调用点逐一核对（[(prefix,uri)] / [NSRange] / [(attributes,whole)] / String?，无第 5 个）；两个 IPTC 文件原样真实 typecheck（真实 GatherProtocol + Linux-only FoundationXML/同模块 stub）EXIT 0；当前调用点无锁内重入。
  4. CullingService applyImportedPicks：5bcf915b 对该文件 = comment-only；HEAD“主照片实时读 + 变体批前快照”如 round-2 所述：主照片窗口=上游 µs 级、revision 守卫仍是自比自（上游同缺陷）；残余变体窗口 R3C-01。worktree 已回退为与上游忽略注释后逐字节相同的代码（§7）。
- round-1 core 修复复核通过：Database.close、DBStatementCache Entry+owner、NavigationService Mutex 日期解析、JSONValueCoding 对象值等价、JobService detached 200ms 重试（JobService 族真实 typecheck + 5 场景探针）、SidecarRegexCache。
- 新增问题均 P2/P3：R3C-01 变体窗口（P2，worktree 已修）、R3C-02 revision 守卫设计债（P2 记录）、R3C-03 预载白读主照片行（P3，worktree 已修）、R3C-04 过时注释（P3，worktree 已修）、R3C-05 锁内 body 无重入警示（P3，worktree 已加注）、R3C-06 高风险改动无回归测试（P2）、R3C-07 DBStatementCache limit 零余量（P3，worktree 已改 16）、R3C-08 mmap 外部截断残余（P3）、R3C-09 Darwin 编译/Sendable 残余（P3）、R3C-10 5 处测试 target 冗余 try 告警（P3）、R3C-11 注释轮次标签错误（P3）、R3C-12 DISTINCT 删除的无序行序注意（P3）、R3C-13 并发 worker 共用 JSONEncoder 的 Foundation 假设（P3）。
- 门禁（HEAD 独立重跑全部 PASS）：check-cleanup-ratchet（try_optional 257/257 等 9 指标）、check-perf-ratchet（raw_regex_compile 3/3、blocking_sleep 0/0 等 9 指标）、check-test-catalog --strict（断言 14959/14959）、check-protocol-surface --strict、check-layering；git grep ’== try ’ 全仓 0 命中。

## 1. Findings

> P0=崩溃/数据丢失/编译中断/安全；P1=很可能正确性回归/CI 红；P2=风险/健壮性/最优性；P3=nit。位置为 HEAD 3486be0b 行号。worktree 列 = lead 未提交 round-3 修复的处置（不作为评审背书）。

| ID | Sev | 位置 | 问题 | 证据（本机实际跑过什么） | 建议 | worktree 状态 | Conf | macOS 不可验证 |
|----|-----|------|------|--------------------------|------|---------------|------|----------------|
| R3C-01 | P2 | Sources/GatherApplication/Services/Culling/CullingService+Commands.swift:449-462 | applyImportedPicks 的“变体人工保护”读批前快照 preloadedDecisions（:416-439 预载，窗口=整批，数百张可达秒级）；上游 e5c54f37 对每个变体是实时 getDecision。批次期间另一写者（LiveCullingAPI.swift:237 在 Task.detached）给同资产变体置 manual，本批仍会以 imported 覆盖全部变体。主照片已实时读（:440-446），相对上游只放大变体窗口。 | 逐行对比 HEAD 与 git show origin/main 版本；读 updateState:82-98（pickState 写整资产变体）与 :51-63；Python 提取函数体做“忽略注释”diff（HEAD≠上游，worktree==上游）。 | 回退变体为逐变体实时读（每资产变体通常 1-2）。 | 已修（未提交）：整函数回退上游逐张实时读；我验证 worktree 版与上游忽略注释后逐字节相同 | 高（逻辑可证） | 否 |
| R3C-02 | P2（设计债，非本分支回归） | CullingService+Commands.swift:51-63、:466-475；batchUpdate:285-289/:349-369 | updateState 的 revision 守卫：调用方传 preloadedDecision 时 currentRow 与 expectedRevision 同源 ⇒ 恒等式，revisionConflict 对该调用方不可达。HEAD 的 applyImportedPicks 传“刚实时读到的行”（µs 窗口），batchUpdate disjoint 路径传批前预载（上游已存在）。写库 revision 来自事务内 fresh getByPhotoIds（:113-122），不会写坏 revision，损失的是并发冲突检测。 | 读 updateState 全文 + 两调用方；git show origin/main 对比确认 batchUpdate 预载是上游代码。 | 记录设计债；要真乐观锁需事务内 fresh 行校验 expectedRevision 或条件 UPDATE（行为变化，单独立项）。 | 不涉及（上游同缺陷） | 高 | 否 |
| R3C-03 | P3 | CullingService+Commands.swift:416-430 | round-1 把主照片改回实时读后，预载集合仍包含所有勾选照片自身决策行，而代码只用 preloadedDecisions[variant.id]（variant != photoId）⇒ 主照片行白读（500 张≈500 行多余读取，一次 IN 查询，微秒级）。 | 读 :416-439 与 :455-456 唯一使用点。 | 预载只收变体。 | 已修（未提交）：预载整体删除 | 高 | 否 |
| R3C-04 | P3 | Sources/GatherApplication/Services/Metadata/MetadataKeywordWriter.swift:126-151 | round-2 回退语义正确，但紧邻旧注释 :128-130“读取失败整批按无缓存行处理”在回退加入后过时且与代码矛盾（:135-151 实际逐行回退）。 | 读 HEAD 全文 + git diff 0288ea8d..HEAD（该段注释未随回退更新）；try? 0 增量；门禁 try_optional 257/257。 | 改写注释为“批量失败→逐行回退；逐行也失败的行按无缓存行处理”。 | 已修（未提交） | 高 | 否 |
| R3C-05 | P3 | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:18-43 | SidecarRegexCache 是全局非递归 Mutex 且 body 在锁内执行：4 个当前调用点都不重入/不嵌套（langAttribute 在 withRegex 返回后才调用）⇒ 无当前 bug；但未来任何 body 内再调 withRegex 会自死锁；round-4 的 4 路并发读在匹配阶段被这把锁串行。 | 读两文件全部 4 个调用点；真实 typecheck；探针 30 task×200 次并发 0 崩溃。 | 文件头注明 body 内禁止再调 withRegex。 | 已加注（未提交） | 高 | 否 |
| R3C-06 | P2（承接 R2C-05/CORE-03） | core Tests（本轮无新增覆盖） | 高风险运行期改动仍无回归测试：DBStatementCache（新文件/limit/末块/失败路径）、Database.close 幂等、applyImportedPicks 变体 manual 保护、JobService async retry、EmbeddingModel LRU 驱逐、KeywordWriter 回退分支。 | git diff --stat origin/main..HEAD -- Tests：round-2 后仍无对应套件；grep 测试文件 0 命中这些主题；门禁只静态数用例/断言。 | 至少补 DBStatementCache 与 KeywordWriter 回退的纯逻辑测试（Linux 可跑）。 | 未涉及 | 高 | 否（测试可 macOS 跑） |
| R3C-07 | P3 | Sources/GatherPersistence/Database/Repositories/AssetRepo+Scan.swift:57-66 | DBStatementCache(limit: 14) 与 ensurePhoto 的 14 条 distinct SQL 恰好相等（零余量）：未来加第 15 条会静默退化为逐张 prepare（仅性能，不会错）。 | 逐条数 ensurePhoto 内 statements.statement( 调用 = 14；读 DBStatementCache limit 语义。 | limit 提到 16 并注释“当前 14 条”。 | 已改 16（未提交），但见 W-1 缩进缺陷 | 高 | 否 |
| R3C-08 | P3（承接 R2C-07/CORE-12） | Sources/GatherPersistence/Database/DB.swift:13-20、:131-138 | PRAGMA mmap_size=256MB 保留（每连接；:memory: 跳过）。残余：外部进程原地截断库文件时 mmap 连接可能 SIGBUS；仓库内部 restore/reset 均先 close 再换文件。 | 读 DB.swift open 路径 + 全仓 grep reopen/restore 顺序；round-1 Python 探针结论仍适用。 | 可接受；README/DEVELOPMENT 补“运行期间勿截断/原地改写库文件”。 | 未涉及 | 中 | 是 |
| R3C-09 | P3（承接 R2C-04/CORE-04，基本闭环） | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:21-28 | 去 T: Sendable 后 Linux 侧真实文件 typecheck 通过；残余仅为 Darwin SDK（Synchronization/Mutex 可用性、NSRange/NSRegularExpression 标注）——target macOS 26 覆盖 Mutex @available(macOS 15)，同 target 上游已有 Mutex 先例。 | 真实整文件 typecheck EXIT 0；4 调用点逐字探针 38 checks。 | macOS 首跑顺带跑 check-warnings.sh core 即闭环。 | 未涉及 | 中高 | 是 |
| R3C-10 | P3（承接 CORE-14 同类） | Tests/GatherCoreTests/Services/FaceKeywordingServiceTests.swift:391/:1881/:1948；SimilarityServiceTests.swift:959；DuplicateServiceTests.swift:492 | 5 处 try await waitUntilCondition { 非 throwing 闭包 }：helper 是 rethrows，非 throwing 闭包下 try 冗余 ⇒ 诊断 no calls to throwing functions occur within ’try’ expression（-warnings-as-errors 下为 error）。CI core tests 不把测试告警当错误（ci.yml:104-105 只对 Sources 开 warnings-as-errors；check-warnings.sh 头注释排除测试 target）⇒ 不挡 CI，仅噪音；本轮 diff 新增其中 3 处。 | 最小 Swift Testing 探针（#expect(try await rethrowsFn { true })）在 -warnings-as-errors 下复现 macro expansion error；读 ci.yml:104-133 与 scripts/check-warnings.sh:1-8。 | 去掉 5 处非 throwing 闭包的 try，或给 helper 加非 rethrows 重载。 | 未涉及 | 高 | 否（测试运行需 macOS） |
| R3C-11 | P3 | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:21 | 注释写“round-6 评审（CORE-04/R2C-04）”，但 docs/reviews 下不存在 round-5/round-6（只有 round2-hardening、round3-perf、round4-perf 与 local-changes-review round1/2/3），R2C-04 是本地评审 round-2 的 finding ⇒ 轮次标签错误。 | grep -rn ’round-6’ docs = 0 命中；对比 R2C-04 来源（round-2 归档）。 | 改为“round-2 评审（R2C-04）”。 | 未改 | 高 | 否 |
| R3C-12 | P3 | Sources/GatherPersistence/Database/Queries/PhotoFilterQuery.swift:142-160 | 去 DISTINCT 的安全性成立（pmc.photo_id UNIQUE ⇒ 1:1；buildWhereClause 只生成 EXISTS/子查询，主查询无其它 JOIN；visiblePredicate 是标量列谓词）。注意：无 ORDER BY 时行序由 DISTINCT 的 temp b-tree 顺序变为查询计划顺序（未承诺契约，但属可观察变化）。app 侧无 FilterEngine.filterPhotos 调用（仅 filterGlobally，未改动）。 | 读 filterPhotos SQL 全文 + SchemaCurrent+DDLDomain.swift:82（photo_id UNIQUE）+ grep -n ’JOIN’ PhotoFilterQuery.swift（clause 构建区无 JOIN）+ grep -rn filterPhotos app；round-1 真实 DDL+5k 库行集等价探针结论仍适用。 | 无需改；若未来要求有序输出，请显式 ORDER BY。 | 未涉及 | 中高 | 否 |
| R3C-13 | P3 | Sources/GatherApplication/Services/QualityService.swift:137-141/:508-511（+ModelReviewService.swift:64-67、ExternalMetadataMigrationService.swift:53-57） | 新增实例级共享 JSONEncoder/JSONDecoder：QualityService.encodeJSON 在 batchAsync(concurrency: 6) 的 worker 闭包内被并发调用（:338/:339/:364/:365 → :508），同一 encoder 实例被 6 个 task 并发 encode。正确性依赖 Foundation 对 JSONEncoder/Decoder 的 Sendable 声明（Apple SDK 标注；round-1 本机 64 线程共享 decoder 探针 0 错，Darwin 侧不可本机证）。 | 读 QualityService 调用链（:231 batchAsync → :338/:364 encodeJSON）；读 ModelReviewService/ExternalMetadataMigration 使用点；对照 GatherPersistence/Ports/FaceConstraintTypes.swift:103-104 上游先例。 | 无需改（与仓库既有共享 coder 口径一致）；macOS 首跑顺带验证。 | 未涉及 | 中 | 是 |

## 2. round-2 core 修复（5bcf915b）逐项验证

> 4 个 core 文件全部验证；GatherUI 的 2 处（pageAssignmentCount/navigationGroupsVersion）与 DateFormatting 属 app 写域，由 review3-app 覆盖，本文件不越界。

### 2.1 JSONValueCodingTests —— 通过（真实 typecheck + 真实模块实跑 oracle）

- HEAD：:131-134 已拆成 let parsedBaseline = try JSONValue.parse(baseline) + 两条 #expect；:68 的 #expect(try JSONValue.parse(cached) == JSONValue.parse(baseline)) 合法（try 在表达式最左覆盖全表达式）。
- 真实 typecheck（-swift-version 6 -warnings-as-errors -I 真实 GatherProtocol 模块）：0288ea8d 版本 EXIT 1、4 条 error，首条 :128:46: error: ’try’ cannot appear to the right of a non-assignment operator（macro expansion 同处）；HEAD 版本 EXIT 0、日志 0 行。
- oracle 实跑：把 6 个 @Test 断言逻辑落成 Linux 探针，链接真实 GatherProtocol 构建产物（SPM 逐文件 .o）：55 checks/0 fails（JSONVALUE_ORACLE_PROBE_PASS）。覆盖 9 类值 stringify↔baseline 解析值等价、非对象值逐字节相等（含引号/反斜杠/换行与新增 a/b 路径）、!cached.contains(换行)、7 组 parse↔baseline decode、init(encoding:)/decode 往返、roundTrip、6 种损坏输入抛 DecodingError。Linux 实测 JSONValue.stringify(.string(“a/b”)) 与 baseline 同为 “a\/b”。
- 确定性：对象只做解析后值比较，标量/数组才比字节 ⇒ Foundation 键序不承诺稳定不造成 flake（本机 200 次 fresh encoder 对 3-key object 只出现 1 种顺序，结论不依赖该事实）。
- 残余：仍只能 macOS swift test 真正运行。

### 2.2 MetadataKeywordWriter 批量失败回退 —— 语义 + 编译验证通过

- HEAD :131-151：主路径 getBatch(targets.map(\.photo.id))；catch → warn + 逐 target get（只失败行 continue）⇒ 与上游“逐张 get + 逐行 catch 只丢失败行”语义一致（比 round-1 的 cachedRows = [] 更接近旧行为）。
- API 核对：MetadataRepository.get(_:)（Ports/MetadataRepository.swift:10）、getBatch(_:)（:11，实现 MetadataCacheRepo.swift:268-281 按 800 分块、任一分片失败整批抛）、GatherLogger.log(_:level:)（Protocol/Logging/Logger.swift:79）、LogLevel.warn（:6）全部存在。
- 真实 typecheck：该文件原样 + 2 行同模块 typealias shim + GatherDelivery 最小 stub（仅 MetadataMutationPort 签名；其余真实 Persistence/Protocol 模块），Swift 6 -warnings-as-errors ⇒ EXIT 0/0 warning（嵌套 catch、let 双分支初始化、日志插值均编译正确）。
- try? 增量 0；check-cleanup-ratchet try_optional 257/257 复跑通过。

### 2.3 SidecarRegexCache 去 T: Sendable —— 通过（真实文件 typecheck，非探针复刻）

- 签名 HEAD :24-28；锁体 storage.withLock { ... body(compiled) }。
- 4 个调用点（全仓仅 4 + 1 声明）：+IPTCReading:73 → [(prefix: String, uri: String)]（闭包 map 出无标签 tuple）；+IPTCReading:99 → [NSRange]；+IPTC:103 → [(attributes: String, whole: String)]；+IPTC:137 → String?（return 位置推断）。无第 5 个。
- 真实 typecheck（关键证据）：两个 IPTC 文件原样拷到 .gather scratch，只做两处 Linux-only 适配（import FoundationXML：Darwin Foundation 转出口；同模块 SidecarXMPProvider 用 3 行 stub），以真实 GatherProtocol 模块 + Swift 6 -warnings-as-errors 整文件 typecheck ⇒ EXIT 0、0 error/0 warning ⇒ 泛型推断、labeled-tuple 数组转换、Mutex.withLock 的 sending Result、非 Sendable body 闭包捕获全部成立。
- 逐字复刻探针 38 checks/0 fails（4 调用点真实 XML、缓存命中、非法 pattern→nil、30 task×200 次并发）。
- 锁语义：body 在锁内；4 个调用点闭包内不再调 withRegex（langAttribute 在 :111-118 循环、withRegex 返回后调用）⇒ 无嵌套。

### 2.4 CullingService applyImportedPicks —— comment-only 确认；live-read 与 identity 语义复核

- git diff 0288ea8d..HEAD 对该文件 = 仅注释变化（+10/−3 注释行）⇒ 5bcf915b 自身不引入新行为面。
- HEAD 现状：:416-439 批前预载；:440-446 主照片实时 getDecision；:449-462 变体人工保护读预载；:466-475 expectedRevision = existing.revision + preloadedDecision: existing。
- 与上游对比：上游主照片与每个变体都实时读；HEAD 主照片同上游（µs 窗口），变体改快照（窗口=整批）⇒ round-2 的“窗口恢复=上游；变体窗口放大”准确；修正后的注释与代码一致，不再声称恢复 DB 级乐观锁。
- identity 复核：updateState:51-63 currentRevision 与 expectedRevision 同源 ⇒ revisionConflict 对 applyImportedPicks 不可达；写库 revision 来自事务内 fresh getByPhotoIds（:113-122），revision 自增正确。上游同缺陷（R3C-02）。

## 3. round-1 core 修复复核（对 HEAD）

| 第一轮项 | HEAD 复核结果 | 证据 |
|---|---|---|
| CORE-01 applyImportedPicks 实时读 | 主照片已实时读（窗口=上游 µs）；变体仍快照（R3C-01） | §2.4 |
| CORE-02 Database.close 移除 PRAGMA optimize | 通过：close 仅 stateLock guard + connection.close() + 注释；幂等/不抛错/.closed 语义未动；git grep ’PRAGMA optimize’ 仅注释命中 | 读 Database.swift:319-345；Persistence 整模块真实 typecheck 覆盖 |
| CORE-05 DBStatementCache Entry+owner | 通过：Entry{statement,owner}、命中 assert(owner===connection)、count<limit 才缓存（limit 语义未变）；cache 为函数局部；DBStatement 早已强持 owner ⇒ 无新环；query/run/get 均 bind+defer reset ⇒ 复用安全；pooled 语句 readScopeDepth fail-closed 保留 | 读 DBStatementCache.swift 全文、DB.swift:467-620、ReadConnectionPool.swift（acquire 非阻塞⇒无死锁）、12 个缓存实例/21 个调用点；Persistence 整模块真实 typecheck |
| CORE-13 NavigationService Mutex 日期解析 | 通过：LegacyWallDateParsers.state = Mutex(State()) 锁内惰性建 formatter + exif→dashed；parseISODate 先 tsParseISODate（fractional→plain，与旧同序）再 fallback；两把锁顺序获取不嵌套 ⇒ 无锁序问题 | NavigationService.swift 真实 typecheck EXIT 0；读 RepositorySupport.swift:14-75 |
| CORE-09 JSONValueCodingTests 对象值等价 | 通过 | §2.1 |
| CORE-10 JobService detached 200ms 重试 | 通过：settle/writeTerminal 均 async，await Task.detached { try? await Task.sleep(200ms) }.value | JobService 族 4 文件真实 typecheck EXIT 0；探针 5 场景全过（两败 0.200s/attempts=2；首败后成功 0.200s；父取消仍 0.200s 后重试；成功 0.000s/attempts=1；0 行 missed 不重试） |
| CORE-04 SidecarRegexCache Sendable | 已由 round-2 修复并验证 | §2.3 |
| CORE-07 KeywordWriter 整批退化 | 已由 round-2 修复并验证 | §2.2 |
| CORE-03/06/08/11/12/14 | 仍为残余：R3C-06、R3C-05、CORE-08 unsafeDowncast（ImageMetadataProviders，Darwin-only）、CORE-11（LibraryPackageService 人物快照，单进程等价）、R3C-08、R3C-10 | 见各条 |

## 4. 全量 core diff 新鲜扫描（origin/main..HEAD，61 文件）

> 全部 61 个改动文件 diff 与关键上下文逐文件读过（Sources 44 + Tests 17）。除 findings 外按面记录复核内容与本机真实 typecheck 覆盖。

### 4.1 GatherPersistence（22 改动文件）—— 整模块真实 typecheck 通过
- 方法：自建最小 os 模块（仅 OSAllocatedUnfairLock(initialState:)/withLock，与 Darwin 接口同形，仅 typecheck 用）+ 真实 CSQLite modulemap + 真实 GatherProtocol 模块，对 GatherPersistence 全部 116 .swift 执行 swiftc -typecheck -swift-version 6 -warnings-as-errors -parse-as-library -module-name GatherPersistence -package-name gather-core ⇒ EXIT 0/0 error。覆盖 DB.swift/DBStatementCache/Database/CullingReadQuery/GlobalDuplicateQuery/PhotoFilterQuery/CollectionRepo/StackRepo/FaceRepo+Observations/AssetRepo+Scan/TriageRepo/CullingHistoryRepo/PhotoRepo/DeliveryRepo+Read/PersonRepo*/RepositorySupport 等全部改动 Persistence 文件。
- DBStatementCache 语义：全仓 12 个实例均函数局部、无跨线程/静态存储；limit=1（分块 IN/UPDATE 循环，非事务→只占 1 条只读池连接）、limit=2/5/14（均在 connection.transaction 内→写连接非池化）；末块 SQL 不同→cache miss→本次 prepare 后随表达式释放（文档与实现一致）；未发现复用导致 bind/step 状态泄漏（query/run/get 均 defer reset + clear_bindings）。
- prepare 复用新增点：AssetRepo.createRawJpegCandidates 的 candidateInsert 提到循环外（SQL/绑定逐字未变；INSERT 在 depth 0 → 写连接，SELECT 可能借只读池，1+1 不超池大小 2）；PhotoRepo/CollectionRepo/StackRepo/FaceRepo/GlobalDuplicateQuery/CullingReadQuery/DeliveryRepo+Read 的分块循环均为“同 SQL 满块命中、末块现场编译”。
- PhotoFilterQuery 去 DISTINCT：见 R3C-12（DDL UNIQUE + 无主查询 JOIN；行集安全，无承诺行序注意）。
- 共享 coder：RepoJSONCoding（static）+ CullingHistoryRepo 实例 coder，与上游 FaceConstraintTypes 先例同口径；并发依赖 Foundation Sendable（R3C-13 同类，P3）。
- 未发现新问题（无 force unwrap/try!/fatalError 新增；git grep ’== try ’ 0）。

### 4.2 GatherApplication（14 改动文件）—— 文件级真实 typecheck + 探针
- 可 Linux 真实 typecheck 并通过的改动文件：NavigationService.swift、BackupStore.swift、ExternalMetadataMigrationService.swift、LibraryPackageService.swift、MetadataKeywordWriter.swift（Delivery 最小 stub）、JobService+Settle.swift（与 JobService.swift/Claim/Recover 一起 4 文件族）。
- 不能 typecheck 的改动文件：CullingService+Commands.swift（需 CullingDecisionService 整族 + GatherDelivery 的 Darwin 依赖）、ModelReviewService.swift（CoreGraphics/ImageIO/Vision）、QualityService.swift（ImageIO/CoreGraphics）、MetadataDispositionService.swift（GatherDelivery 的 XMPFileLock/DeliveryStateWriter 等）——只到语法 parse + 逐行/API 级 + 语义探针。
- MetadataDispositionService.conflicts（round-4 4 路并发）：用真实 batchAsync（GatherPersistence）+ 真实 DeliveryRow/DeliveryItemRow/MetadataWriteAttributes/MetadataConflict 类型把方法体逐字复刻成探针实跑 4 场景（完成序反转→顺序一一对应/revision 对齐；单条读失败→该条空属性、不串位；调用方取消→detached 隔离仍完整；空 rows→[]）⇒ DISP_CONFLICTS_PROBE_PASS。remotes 与 rows 严格一一对应，防御兜底不可达；catch 静默返回 [] 属 nit（R2C-11；worktree 已加 warn）。
- NavigationService：预计算 timestamps/sequences 后 group() 用 timestamps[index-1] 的等价性成立（previous 非 nil ⇔ current 非空 ⇔ rows[index-1]；flush 后 current=[] 再 append）；filenameSequence 全局 Mutex 缓存只改性能不改语义；真实 typecheck 覆盖。
- JobService async 化：settle 唯一调用点 await（全仓 2 命中：Claim:183 与定义）；探针见 §3；失败路径 activeRuns 清理/pump 最迟晚 200ms 与旧 Thread.sleep 等价（P3 已记录）。
- BackupStore / ExternalMetadataMigration / LibraryPackageService：coder/formatter 提到循环外，默认配置逐字等价；LibraryPackageService 人物快照 list()+knownPersonIDs 与逐条 get 等价（PersonRepo.get 仅存在性判定；upsertByName 新 id 并入集合；单进程导入路径）——真实 typecheck 覆盖。
- ModelReviewService static→instance：全仓调用点仅同文件 2 处（grep 确认，无测试/外部静态调用）⇒ 无编译断裂；实例 coder 并发同 R3C-13。
- QualityService 索引化：indexByPhotoId 保留“首次出现下标”与 firstIndex(where:) 同义；本方法只写 relativeRank、不增删 results ⇒ 等价；encodeJSON 并发见 R3C-13。
- CullingService+Commands：见 §2.4/R3C-01/02/03。未发现其它正确性问题。

### 4.3 GatherAnalysis（2 文件）—— 逐行 + Darwin-only 残余
- EmbeddingModel LRU：逐行读 + 逐字逻辑探针（4 键填满/命中不重载/第 5 键驱逐最久/被逐出键重载/最近命中保护/removeAll）⇒ LRU_PROBE_PASS；驱逐只丢缓存引用（调用方持有 provider 强引用）；single-flight（NSLock 内加载）未变。
- ImageMetadataProviders unsafeDowncast：CFTypeID 判型后 unsafeDowncast 与 as! 前置条件等价；CoreGraphics 本机不可编译/运行 ⇒ CORE-08（P3）维持。

### 4.4 GatherMetadataIO（3 文件）—— 2 个 IPTC 文件真实 typecheck 通过
- IPTC 两文件：真实 typecheck + 行为等价逐行（mergedAltElement/langAttribute/normalizeKnownPrefixes 的 map 化与 escapedPattern 预计算不改值/顺序/逆序替换语义）。
- SidecarXMPProvider.readSidecar 去掉 fileExists：contents(atPath:) 对不存在/目录/不可读均 nil ⇒ 语义等价（少一次 stat）。

### 4.5 GatherProtocol（3 文件）—— 与上游等价 + 真实构建
- JSONValueCoding 共享 coder（默认配置）；DescriptiveMetadata 的 init(encoding:)/decode 改共享 coder（值等价，oracle 覆盖）；C1.swift EOF newline。GatherProtocol 真实 SPM 构建通过（114 文件，Swift 6）。

### 4.6 Tests（17 文件）
- JSONValueCodingTests（§2.1）；AsyncWait.swift 新 helper（ContinuousClock+Task.sleep、取消返回 false、超时最后一次求值）；DatabaseTestSupport 改 throw（不再 preconditionFailure 杀进程）；CullingDecisionRepoTests 钉死 created_at 消除 2ms sleep。测试范围由 round-2 review2-tests 与 review3-compile 覆盖；本文件只记 core 语义影响（R3C-10 的 5 处告警）。

## 5. 验证 OK 清单（本轮实际执行，全部本机复跑）

### 5.1 真实编译 / 类型检查
1. GatherProtocol：swift build --target GatherProtocol（Swift 6）→ 成功（114 文件）。
2. GatherPersistence 整模块：swiftc -typecheck ... 全部 116 .swift + os stub + CSQLite modulemap + 真实 GatherProtocol 模块 ⇒ EXIT 0。
3. IPTC 两文件（真实文件 + Linux-only FoundationXML/同模块 stub）⇒ EXIT 0。
4. JSONValueCodingTests：HEAD ⇒ EXIT 0；0288ea8d 版本 ⇒ EXIT 1（4 error，负数对照）。
5. MetadataKeywordWriter.swift（真实文件 + 2 行 typealias shim + Delivery stub）⇒ EXIT 0。
6. NavigationService / BackupStore / ExternalMetadataMigrationService / LibraryPackageService ⇒ 各 EXIT 0。
7. JobService 族（JobService.swift + Claim + Settle + Recover）⇒ EXIT 0（覆盖 round-1 async 重试修复的编译正确性）。
8. 探针全部 -swift-version 6 -warnings-as-errors 编译。

### 5.2 语义探针
- JSON oracle（真实 GatherProtocol 模块）55 checks 0 fails。
- withRegex 4 调用点 38 checks 0 fails。
- JobService retry 5 场景全过（含父取消仍等满 200ms）。
- EmbeddingModel LRU 6 场景全过。
- MetadataDispositionService.conflicts（真实 batchAsync + 真实行类型）4 场景全过。

### 5.3 门禁（HEAD 独立重跑）
- check-cleanup-ratchet PASS（unchecked_sendable 60/60、try_optional 257/257、try_bang 0/0、as_bang 0/0、fatal_error 0/0、nonisolated_unsafe 7/7、services_prepare 0/0…）。
- check-perf-ratchet PASS（raw_json_decoder 38/38、encode_chain 20/20、decode_chain 22/22、raw_regex_compile 3/3、raw_byte_formatter 1/1、blocking_sleep 0/0）。
- check-test-catalog --strict PASS（@Test 3267、@Suite 419、断言 14959/14959）；check-protocol-surface --strict PASS；check-layering PASS。
- git grep ’== try ’（HEAD 全仓）0 命中；git diff --check 干净（HEAD）。

### 5.4 不能验证（macOS-only）
- macOS 编译（GatherApplication/GatherAnalysis/GatherMetadataIO 全量；AppKit/SwiftUI/CoreML/Vision/CoreGraphics/ImageIO/CryptoKit/CoreServices 无 SDK）；SwiftPM macOS swift build/swift test；check-warnings.sh；Darwin 的 NSRange/NSRegularExpression/DateFormatter/JSONEncoder 实际标注/行为；SQLite macOS 上的 mmap/ANALYZE 行为；UI 并发时序；测试 target 编译（R3C-10 告警优先级只能按 CI 配置判断）。

## 6. 覆盖与限制
- 覆盖：round-2 core 修复 4 文件逐行 + 真实 typecheck；round-1 全部 core 修复逐项复核（2 个新增真实 typecheck 族 + 2 个探针）；core Sources/Test 61 改动文件 diff 全读；Persistence 整模块 + 10 个改动文件真实 typecheck；6 个 Linux 语义探针；5 道相关门禁。
- 限制：GatherApplication（除 6 个文件）/GatherAnalysis/GatherMetadataIO 整模块不可 Linux typecheck（Darwin 框架无守卫 import）⇒ 这些文件仍是源码级 + API 级 + 探针结论；无 macOS 运行证据；探针是逻辑副本而非该 target 编译产物（JSON/dispatch 两例例外，链接真实模块对象）。

## 7. 工作区 round-3 修复观察（非评审基线，仅复核）

| 工作区改动 | 复核 |
|---|---|
| CullingService+Commands.swift applyImportedPicks 回退为上游逐张实时读（删除批前预载） | Python 提取函数体、去注释后与 origin/main 版本 diff：逐字节相同 ⇒ 逻辑=上游（主照片+每变体实时读，无快照窗口），且是上游已在 macOS 编译过的代码形状；-parse EXIT 0；grep preloadIds/preloadedDecisions 0 残留。R3C-01/R3C-03 消解 |
| MetadataKeywordWriter 注释改为“批量失败→逐行回退” | 与代码一致；R3C-04 消解 |
| Database.swift close 注释改为“如需刷新统计应在维护流程显式执行，当前无自动任务” | 与 DEVELOPMENT 口径一致（亦修 peer R3D-10） |
| SidecarXMPProvider+IPTCReading.swift 增加“body 在锁内、闭包内禁止再调 withRegex”注释 | R3C-05 的警示诉求消解（串行化取舍仍在，属设计） |
| MetadataDispositionService catch 中加 GatherLogger.log(...level: .warn) | 修 R2C-11；文件 import GatherProtocol ⇒ API 可用；-parse 通过（整文件本机不可 typecheck，见 §6） |
| AssetRepo+Scan.swift DBStatementCache(limit: 16) + 注释 | R3C-07 消解，但存在 W-1 缩进缺陷（见下） |
| docs 修正 | 属 review3-docs 写域，不评价 |

- W-1（P3，worktree-only）：AssetRepo+Scan.swift 工作区改动中两行缩进错误——“// 恰好相等时未来新增第 15 条…” 与 “let statements = DBStatementCache(limit: 16)” 只有 8 空格缩进（应为 20，与周围闭包体对齐），且打断“// 当前 ensurePhoto 使用 14 条…（评审 R3C-07：”的续行。不阻塞编译/门禁（Swift 不校验缩进；hygiene [a]-[g] 不查缩进），但提交前应修正为与闭包体 20 空格对齐。
- 工作区 6 个 core 文件 swiftc -parse 全部 EXIT 0（含新增注释/代码）。

## 8. 复现命令索引

    # 1) 真实 GatherProtocol 模块
    HOME=$PWD/.gather/home CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc .gather/swift62/usr/bin/swift build \
      --package-path desktop/native/gather-core --scratch-path .gather/r3-review-spm --target GatherProtocol

    # 2) GatherPersistence 整模块 typecheck（os/CSQLite shim；os.swift 提供 OSAllocatedUnfairLock）
    FILES=$(find desktop/native/gather-core/Sources/GatherPersistence -name ’*.swift’)
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors -parse-as-library \
      -module-name GatherPersistence -package-name gather-core \
      -I .gather/r3-review-spm/x86_64-unknown-linux-gnu/debug/Modules \
      -I .gather/r3core3/shims/modules -I desktop/native/gather-core/Sources/CSQLite/include $FILES

    # 3) JSONValueCodingTests 真实 typecheck（负数对照/正数）
    git show 0288ea8d:.../Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift > .gather/r3core3/JSONValueCodingTests-old.swift
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors -I .../Modules .gather/r3core3/JSONValueCodingTests-old.swift  # exit 1, 4 errors
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors -I .../Modules .../JSONValueCodingTests.swift  # exit 0

    # 4) 10 个改动文件真实 typecheck（示例：Navigation/BackupStore/ExternalMigration/LibraryPackage；JobService 族）
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors \
      -I .gather/r3-review-spm/.../Modules -I .gather/r3core3/modules -I .gather/r3core3/shims/modules \
      -I .../Sources/CSQLite/include Sources/GatherApplication/Services/NavigationService.swift ...
    .gather/swift62/usr/bin/swiftc -typecheck ... Sources/GatherApplication/Services/JobService.swift Sources/GatherApplication/Services/Job/*.swift

    # 5) 真实文件 typecheck（IPTC 两文件；Linux-only shims：FoundationXML + SidecarXMPProvider stub）
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors -I .gather/r3-review-spm/.../Modules \
      .gather/r3core3/typecheck-real/Stub2.swift .gather/r3core3/typecheck-real/IPTC.swift .gather/r3core3/typecheck-real/IPTCReading.swift

    # 6) 探针
    .gather/r3core3/json_oracle_probe    # 55 checks PASS（链接真实 GatherProtocol .o）
    .gather/r3core3/regex_generic_probe  # 38 checks PASS
    .gather/r3core3/retry_probe          # RETRY_PROBE_PASS
    .gather/r3core3/lru_probe            # LRU_PROBE_PASS
    .gather/r3core3/disp_conflicts_probe # DISP_CONFLICTS_PROBE_PASS（链接真实 batchAsync）

    # 7) 门禁
    ./scripts/check-cleanup-ratchet.sh && ./scripts/check-perf-ratchet.sh && ./scripts/check-test-catalog.sh --strict \
      && ./scripts/check-protocol-surface.sh --strict && ./scripts/check-layering.sh

## 9. 与前两轮结论的差异（本轮更正/新增）

- 新增（前两轮未报）：R3C-10（5 处测试 target 冗余 try 告警）、R3C-11（round-6 轮次标签错误）、R3C-12（DISTINCT 删除的无序行序注意）、R3C-13（并发 batchAsync worker 共享实例 encoder 的 Foundation 假设）、R3C-03（预载白读主照片行）——均为 P3。
- 级别维持：R3C-01（变体窗口）P2，与 round-2 R2C-02/01b 同源但本文件给出“窗口=整批、主照片=µs”的准确边界；R3C-06 测试缺口 P2 维持。
- 复核确认 round-2 结论准确：CullingService 修复=comment-only；“revision 检测未恢复（上游同缺陷）”；MetadataKeywordWriter 回退=上游逐行语义；SidecarRegexCache 去约束=语义不变。无 round-2 结论被推翻。
- 对账口径补充：round-2 的“GatherPersistence 不能 Linux 编译”在 SPM 默认构建下成立，但本轮用 os 最小 shim 完成了整模块 typecheck（非运行/非链接），把 Persistence 编译风险证据等级从源码级提到真实 Swift 6 类型检查；GatherApplication 仅文件级。

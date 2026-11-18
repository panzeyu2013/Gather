# R1 gather-core correctness review：本地 16 commits 的 GatherCore Sources 改动独立复核（review-core / task-26）

- **日期**：2026-11-18（评审基线：committed HEAD 5ea5c38f；随后 lead/peers 在工作区应用了针对本报告的修正，见 §5）
- **范围**：desktop/native/gather-core/Sources（44 个改动文件，含四轮性能优化 + 卫生提交），基线 origin/main（e5c54f37），HEAD 5ea5c38f。
- **环境**：Linux Ubuntu 22.04，无 macOS/Xcode/SDK；Swift 6.2（Linux 工具链）。**未在 macOS 上编译、未运行任何 macOS 测试**；本文件中的“验证”全部是源码阅读 + Linux 可运行探针 + swiftc -parse + Linux 可类型检查的 GatherProtocol target + 仓库只读门禁。
- **声明**：本文件是独立复核（把 docs/reviews/2026-11-17-* 与 2026-11-18-round4-perf 的说法当**待验证假设**），不是对作者自述的转述。

## 0. 结论速览（先给 lead 的 triage）

- **未发现确定性 P0（编译中断/崩溃/数据丢失/安全）**：44 个改动文件 swiftc -parse 全过；GatherProtocol（含共享 coder 新增）在 Swift 6 语言模式下 swift build --target 通过；protocol-surface / cleanup-ratchet / perf-ratchet / test-catalog / layering / docs-facts / repo-hygiene 7 个门禁本机独立重跑 PASS。
- **未发现确定性 P1（必然的语义回归）**：DISTINCT 删除、批量化、正则缓存、LRU、async 化的常规路径语义均可用源码 + 探针证明等价。
- **最高优先级的真实风险是 1 条条件触发 P1 + 2 条 P2 + 1 条 coverage 完整性缺口**（详见表格）：
  1. **CORE-01（P1，条件触发）**：CullingService.applyImportedPicks 的批前快照使“未在本批触碰的照片”的 **revision 冲突检测被事实关闭**（expectedRevision 与 updateState 的 currentRow 来自同一快照 ⇒ 恒等），并发人工决策可能被 imported 覆盖（旧实现每张实时读，窗口是微秒级；新窗口 = 整批时长）。LiveCullingAPI 在 Task.detached 执行该批，UI 同时挑片是真实场景；串行路径不受影响。代码注释 :409-412 声称“与逐张实现一致”，docs 只承认“快照可能更旧”，比实际语义弱化要轻。
  2. Database.close() 的 PRAGMA optimize 在**每次关闭**时写入规划器统计（ANALYZE），对“只读打开库、不写库”的 CLI（gather-triage-eval）构成行为漂移，且大库首次 ANALYZE 的耗时无上界、发生在应用退出路径；close 的幂等/不抛错语义经 BestEffort 验证保持不变。
  3. 高风险运行期改动（DBStatementCache / applyImportedPicks 修订语义 / JobService async 重试 / EmbeddingModel LRU / PRAGMA close）**没有新增回归测试**（本轮唯一新增测试是 JSONValueCodingTests）。

## 1. Findings 表

> 级别：P0=崩溃/数据丢失/编译中断/安全；P1=很可能正确性回归或行为变化；P2=风险/健壮性/最优性；P3=nit。Confidence 为**仅基于本机可见证据**的置信度；“macOS 不可验证”表示需要 macOS 编译/运行才能定性。

| ID | Sev | 位置（改动后行号 or commit） | 问题 | 证据（看过/跑过什么） | 建议修复 | Conf | macOS 不可验证? |
|----|-----|------------------------------|------|------------------------|----------|------|------------------|
| CORE-01 | **P1**（条件触发：串行/无并发写者时不可观察；并发人工决策与客户校样导入同时发生时才会命中） | GatherApplication/Services/Culling/CullingService+Commands.swift:413-490（preload :428-436、选择逻辑 :444-450、:470-479 传 preloadedDecision）；配合 updateState :50-63；commit 9b1b8aeb | **批前快照使“未在本批触碰的照片”的 revision 冲突检测变成恒等式**：expectedRevision = preloadedDecisions[photoId].revision，同时 updateState(preloadedDecision: existing)，updateState 内 currentRow = preloadedDecision 再与 expectedRevision 比较 ⇒ 永远相等，revisionConflict 分支对这类照片不可达。旧实现每张 getDecision 实时读后再进入 updateState（窗口微秒级）。另：兄弟变体的 decisionSource==manual 判定也用批前快照，批次期间**另一写者**提交的人工决策可能被本批 imported 覆盖。LiveCullingAPI.swift:237 在 Task.detached 里调用，UI 挑片与该批并发是真实可能。 | 逐行读代码：diff hunk 显示旧实现为 getDecision + 逐变体点查；updateState:50-63 的 currentRow/expectedRevision 同源；CullingDecisionRepo.getByPhotoIds :118-135；docs 2026-11-17-round2-hardening/perf-core-round2.md:52-53 只承认“极端并发下快照可能更旧”，代码注释 :409-412 声称“保证 revision 与逐张实现一致”（不准确）。 | 保留 touched 集合机制，但**未触碰照片改为实时 getDecision**（回到旧读法；N+1 只剩每张 1 次而非上千次，仍保留批量降 N+1 的主体收益），或给 updateState 加显式 validateRevisionAgainstDB 分支；至少修正 :409-412 注释并在 docs 记录该竞态窗口被放大。 | 高（代码级）；并发概率无法在 Linux 量化 | 否（逻辑可证），UI 并发时序需 app 运行 |
| CORE-02 | **P2** | GatherPersistence/Database/Database.swift:324-340（commit c6d8a0da） | ① Database.close() 现在会执行 PRAGMA optimize（内部可能 ANALYZE 写 sqlite_stat1），而 GatherTriageEval/main.swift:23 明确文档“只读：打开库、loadCandidates、纯函数评估；不写决策、不写 XMP”，CLI 实际上在 defer close 时首次写库（规划器统计）。② ANALYZE 耗时无上界：大库首次/大改后可能在应用退出/主线程路径上产生不可控延迟，代码只把 busy_timeout 收紧到 250ms（只限制锁等待，不限制 ANALYZE 本身）。③ 无任何测试覆盖 close 的 PRAGMA 路径。close 幂等/不抛错语义**已验证不变**（BestEffort.attempt 是 do/catch + warn，BestEffort.swift:12-19）。 | 读代码 + 运行 Python sqlite3 探针：PRAGMA optimize 在 3.37 小库上 no-op（无 stat1）、事务内返回 OK、只读连接上也返回 OK 不报错；PRAGMA mmap_size 在只读连接可设。schema 安全：SchemaShapeReader 只读 name NOT LIKE 'sqlite_%'（SchemaShape.swift:88-97），stat 表不会触发 assertReady 的列形/指纹失败 —— 故**不是 P0 重置风险**。 | 把 optimize 变成显式选项（如 Options.closeOptimize = true，CLI/测试传 false），或放到 close 前的后台队列并限时；给 close 增加“不抛错 + 幂等 + 只读意图不写库”的回归测试；同步修正 triage-eval 文档口径。 | 高（行为）；耗时 macOS 不可测 | 部分（ANALYZE 实际耗时/是否有写入需 macOS 大库实测） |
| CORE-03 | **P2** | 全部核心性能改动（DBStatementCache、CORE-01 的 revision 语义、JobService async settle、EmbeddingModel LRU、PRAGMA close） | **completeness：高风险运行期改动无回归测试**。本轮 core 新增测试只有 JSONValueCodingTests.swift（130 行）；applyImportedPicks 既有测试（CullingServiceTests.swift:2078-2142）不覆盖同资产多变体 + 并发 revision；无 DBStatementCache 单测（无池连接占用/末块/失败路径）；无 PRAGMA mmap/optimize 测试；无 LRU 驱逐测试（作者自述“既有 3 键测试不触发驱逐”）；JobService async 重试仅靠作者 .gather 探针。 | git diff --stat origin/main...HEAD -- desktop/native/gather-core/Tests 逐文件读；grep applyImportedPicks 看既有测试内容；docs 各轮均写“未新增测试（Tests 不在本任务写域）”。 | 至少补：DBStatementCache 单元测试（读写连接/末块/错误）、applyImportedPicks 同资产多变体 + 并发 revision、LRU 驱逐、Database.close 不抛错/幂等。 | 高 | 否（测试可在 macOS CI 跑） |
| CORE-04 | **P2** | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:19-39（SidecarRegexCache.withRegex<T: Sendable>） | macOS 侧**编译风险（低概率但为 0 成本可消除）**：T: Sendable 约束下调用点传 [NSRange]（normalizeKnownPrefixes 的 tagRanges）。Linux Foundation 的 NSRange 是 Sendable（本机 Swift 6 探针通过），但 Darwin SDK 的 NSRange Sendable 标注无法在本机确认；若未标注则 swift build / check-warnings.sh（CI，Sources 级 -warnings-as-errors）在 macOS 直接失败。 | Linux 探针：SidecarRegexCache 逐字副本 + [NSRange]/tuple 返回在 -swift-version 6 -warnings-as-errors 下编译运行通过；仓库内无既有 NSRange×Sendable 先例可佐证 Darwin 标注。 | 避免泛型 Sendable 约束传递：由 body 返回 String/自定义 Sendable 小结构，或把 T: Sendable 改为在内部提取（如 withRegex 返回已提取的匹配结果），可完全绕开 NSRange 的 Sendable 依赖；或在 macOS 先跑 swift build。 | 中（语言规则同源，仅 Foundation 标注未证） | 是 |
| CORE-05 | P3 | Sources/GatherPersistence/Database/DBStatementCache.swift:42-49；AssetRepo+Scan.swift:57-62 | statement(_ connection:, _ sql:) 命中时**忽略 connection 参数**（缓存仅按 SQL 文本键）。当前 17 个调用点都传同一个 connection，故无实际 bug；但 API 形状允许把 A 连接的缓存语句在 B 连接上使用：DBStatement.requireOpenConnection 只检查自身 owner/代数（DB.swift:505-515），不会发现 B≠A，导致在错误连接上执行/计入 changes。另 limit=14 与当前 ensurePhoto 的 14 条 distinct SQL 恰好相等（我逐条数过），未来加第 15 条会静默退化为每次重新 prepare（仅性能，不会错）。 | 逐调用点核对（PhotoRepo:398-421、DeliveryRepo+Read:14-34、CollectionRepo:309-328/372-389、StackRepo:184-200/319-335/344-365、FaceRepo+Observations:489-522、CullingReadQuery:265-278/328-340、GlobalDuplicateQuery:119-137、AssetRepo+Scan:56-96/196-352）；DBConnection.prepare 的 depth==0 路由（DB.swift:257-273）确认事务内语句非池化。 | 缓存条目记录 owner（struct Entry { let statement: DBStatement; let owner: DBConnection }）并 precondition(owner === connection)（debug）或在命中时校验；limit=14 改为 limit: 16 留余量并注释。 | 高 | 否 |
| CORE-06 | P3 | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:19-39；MetadataDispositionService.swift:52-74（commit c6d8a0da） | ① SidecarRegexCache.withRegex 在**非递归 Mutex 的锁内执行匹配 body**：当前 body 都不再调用 withRegex（已核对 IPTC/IPTCReading 两文件全部调用点），但未来任何“body 内再查缓存”会死锁。② 该全局锁把所有 sidecar read 路径的正则匹配串行化：round-4 把 conflicts() 的 XMP 读改成 4 路并发后，readAttributes → readSidecar → normalizeKnownPrefixes → withRegex 的匹配阶段仍被这一把锁串行（文件 IO + XMLParser 仍并行，所以收益仍在，但 docs 的“4 路并发读盘”表述略高）。 | 读两文件全部 withRegex 调用点；Linux 探针验证 Mutex 锁语义与逐字副本行为一致（15 个文件名 + 并发 32 线程结果与旧实现逐个相等）。 | 编译在锁内、匹配在锁外（NSRegularExpression 不可变；需要时再评估线程安全），或按 pattern 分锁；在文件头注明“body 内禁止重入”。 | 高 | 否 |
| CORE-07 | P3 | GatherApplication/Services/Metadata/MetadataKeywordWriter.swift:127-141（commit 9b1b8aeb） | cacheStore.getBatch(...) 整批失败时 cachedRows = []：旧实现逐张 get + 每行 catch，只丢失败那一行；新实现一行失败/一个 chunk 失败会让**全批** cachedRow = nil，externalChanged 检测静默退化（可能把“外部已改动”误判为未改动）。仅 DB 级错误才触发（此前 photoRepo.getLookupByIds 已成功，概率极低），且失败方向保守（不写入错误值）。 | 读代码 + 对比旧 diff hunk；MetadataCacheRepo.getBatch:268-281（chunk 800，任一 chunk 抛错即整批抛）。 | 保留批量主路径，catch 时回退逐张 get（N 通常 ≤500 且仅在异常路径）；或至少 warn 日志标注语义退化。 | 高（语义）/低（触发概率） | 否 |
| CORE-08 | P3 | Sources/GatherAnalysis/Image/ImageMetadataProviders.swift:163-176（commit 242d6b21） | as! → unsafeDowncast（CF 类型）：typeID 相等后 unsafeDowncast 与 as! 前置条件等价，但 unsafeDowncast 对非原生 Swift 类（CF 对象）属于依赖实现的用法；CoreGraphics 仅 macOS 可用，无法本机编译/运行。 | 读代码 + diff（旧 object as! CGImageMetadataTag）；Linux 无 CoreGraphics，无法验证；注释自述为绕开 warnings-as-errors 的写法。 | 若只是 warnings-as-errors 问题，可回退 as!（强制转换不产生“条件转换恒真”告警）；或写 object as CFTypeRef + unsafeBitCast 等价写法并加注释说明依赖 CF 运行时。 | 中 | 是 |
| CORE-09 | P3 | Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift:58-100；GatherProtocol/Protocol/Core.swift:116-125 | “复用共享 coder 输出逐字节一致”是**针对默认配置不变**的合理断言，但 Foundation 未把它作为跨实例契约：本机 Linux 探针发现**任意普通 Codable 结构（keyed container）在多次 encode 间键序可能变化**（2 种顺序，fresh/shared 均如此），因此该测试若把 baseline oracle 推广到普通模型就会 flaky。对 JSONValue 自身（.object 走字典编码路径）本机实测稳定：9/9 字节相等、init(encoding:)/decode 无损、损坏输入抛 DecodingError；64 线程并发共享 decoder 2000 项 0 错。 | 探针：真实 GatherProtocol 模块（Linux typecheck 构建产物）+ 本机 JSONEncoder 顺序实验（普通结构 500 次 encode 出现 2 种键序；JSONValue 语料 0 漂移）。 | 字节断言统一对两端加 .sortedKeys（或只比较解析后的 JSONValue），把“字节等价”降级为“值等价”；在 macOS 跑一次确认当前 9 条语料通过。 | 中 | 是（Darwin JSONEncoder 实现/键序需 macOS 复跑） |
| CORE-10 | P3 | Sources/GatherApplication/Services/Job/JobService+Settle.swift:205-227；JobService+Claim.swift:183（commit c6d8a0da） | async 化本身语义保持（Linux 探针复刻：失败→200ms 后重试一次、两次失败返回 failed、取消时 sleep 立即返回仍重试一次）。唯一时序差异：**瞬时写失败**时 removeActiveRun/clearGraceTask/pump 最多晚 200ms，且整个 settle 在 job Task 里多了一次可挂起点；仅在 DB 错误路径可见（docs 已承认）。settle 只有 1 个调用点（grep 全仓），Tests 无直接调用。 | 读代码 + 全仓 grep settle(/writeTerminal(；Linux 探针复刻 retry 语义（见 §2）。 | 无需改（可接受）；可在注释补“错误路径下 activeRuns 清理最迟晚 200ms”。 | 高 | 否（时序在 Linux 可近似验证） |
| CORE-11 | P3 | Sources/GatherApplication/Services/Maintenance/LibraryPackageService.swift:459-493（commit 9b1b8aeb） | knownPersonIDs 用 personsRepo.list() 快照替代逐条 get(id:)：非并发导入下等价（list() 无过滤返回全量，PersonRepo+Query.swift:11-15；get 只判存在 :46-54；upsertByName 命中同名返回既有 id :13-29，新 id 也并入集合）。唯一差异：若**另一个写者**在 list() 之后、绑定循环之前创建了 binding.personId 对应人物，旧实现会用它，新实现可能按同名/新建处理（单进程导入路径概率极低）。 | 读 PersonRepo+Query/Identity；对比 diff。 | 无需改（可接受）；或在导入入口用维护锁串行化。 | 高 | 否 |
| CORE-12 | P3 | Sources/GatherPersistence/Database/DB.swift:13-19,134-138（commit c6d8a0da） | PRAGMA mmap_size=256MB（每连接）本身安全（Linux 探针：读写连接/只读连接都可设、>2GB 被 SQLite 静默钳制到 SQLITE_MAX_MMAP_SIZE、:memory: 返回无值可跳过）。残余风险：SQLite 文档明确**外部进程截断数据库文件时，mmap 连接可能 SIGBUS 崩溃**；本仓库内部 restore/backup/reset 流程都先 close 再换文件（已核对），但外部工具/云同步截断属未受控场景；docs 已声明网络卷回退。 | Python sqlite3 探针（mmap 读回 268435456；只读连接同一 PRAGMA 生效；4GB→2147418112 钳制）；读 Database.open/SchemaReset/Restore 路径确认 close-before-replace。 | 可接受；可在 README/DEVELOPMENT 补充“不要在 Gather 运行时截断/原地改写库文件”；若担心外部改写可对明显非本地卷传 0。 | 中 | 是（APFS/FileProvider/外部截断行为） |
| CORE-13 | P3 | Sources/GatherApplication/Services/NavigationService.swift:462-480,487-528（commit 242d6b21/9b1b8aeb） | LegacyWallDateParsers 用共享静态 DateFormatter（未加锁）：Apple 文档说明 macOS 10.9+ DateFormatter 的 format/parse 线程安全（配置不可变），且 IngestService 已有同类静态 formatter 先例，故可接受；但若未来有人改这些 formatter 的配置就会出现数据竞争。filenameSequenceRegex 的 Mutex 在 1 万行两遍分组时串行匹配，属可忽略成本。previous != nil ⇒ 行号 = index-1 的等价性成立（current 是连续后缀，见 :308-333 的 flush 逻辑）。 | 读 group() 全文；Linux 探针：新旧 parseISODate 在 16 种日期形态（含 EXIF 冒号、空格、小数秒、坏输入）与 16 线程并发下结果完全一致；ISO8601DateFormatter() 默认 formatOptions == [.withInternetDateTime]（探针 1907==1907）；filenameSequence 新旧实现在 15 个文件名 + 并发下一致。 | 给静态 formatter 加注释“只读、勿改配置”；考虑把 filenameSequence 的匹配移出锁（同 CORE-06）。 | 高 | 否（DateFormatter 线程安全承诺来自 Apple 文档，非本机可测） |
| CORE-14 | P3 | Tests/GatherCoreTests/Services/FaceKeywordingServiceTests.swift:391/1881/1948、SimilarityServiceTests.swift:959、ReadPoolTests.swift:52-60（commit 708a6b89） | 测试卫生改动里 try await waitUntilCondition { ... } 用于**非 throwing** 闭包（如 entered.value、blocked.value）：rethrows 语义上该调用不抛错，try 会产生 "no calls to throwing functions occur within 'try' expression" 告警。CI 的 check-warnings.sh 只构建 Sources/产品 target（脚本头注释明确“测试 target 的告警不在此门禁内”），因此**不会挡 CI**，只是噪音；另外这些用例依赖 macOS 才能跑。 | 读 check-warnings.sh（只对 Sources/产品 target 加 -warnings-as-errors；CI ci.yml:104 注释同口径）、grep 全部 try await waitUntilCondition 调用点、15 个改动测试文件 swiftc -parse 0 失败。 | 去掉非 throwing 闭包处的 try（保留 throwing 闭包处的 try），或给 helper 加一个非 throwing 的重载。 | 高 | 是（提醒：测试未在 macOS 跑过） |

## 2. 独立验证 OK 清单（我实际做了什么）

### 2.1 静态检查（Linux 可跑部分）

- **语法解析**：改动 core Sources 文件 44 个 + 改动 core Tests 文件 15 个（共 59 个），swiftc -parse -enable-bare-slash-regex **0 失败**。
- **类型检查（唯一 Linux 可编译 target）**：swift build --package-path desktop/native/gather-core --target GatherProtocol（Swift 6 语言模式）**PASS** —— 覆盖本轮新增的 JSONValueCoding 静态 JSONEncoder/JSONDecoder（Swift 6 静态 let 的 Sendable 要求）、DescriptiveMetadata 的 init(encoding:)/decode 改动。
- **仓库门禁独立重跑（全部 PASS）**：check-protocol-surface.sh --strict、check-cleanup-ratchet.sh（无新 @unchecked Sendable/nonisolated(unsafe)；diff 中这两个词只出现在注释里）、check-perf-ratchet.sh（blocking_sleep 0/0）、check-test-catalog.sh --strict、check-layering.sh、check-docs-facts.sh、check-repo-hygiene.sh（含 shellcheck [a]-[g]）。
- 未跑（需要 macOS）：swift build/test（app/GatherUI/AppKit/CoreML）、scripts/check-warnings.sh（Sources 级 -warnings-as-errors，CI 会跑，是 CORE-04 的兜底）、swift test（含新增 JSONValueCodingTests）。

### 2.2 Linux 行为探针（.gather/R1core-probes/，非仓库产物）

探针均用 Swift 6 -swift-version 6 -warnings-as-errors 编译，逻辑副本（不是仓库模块的编译产物，唯一例外是 2.2-1 用真实 GatherProtocol .swiftmodule + build objects 链接）：

1. **真实 GatherProtocol JSONValue 编解码**：JSONValue.stringify 对 9 类值（null/bool/number/string/array/object/中文/emoji）与新建默认 JSONEncoder() **逐字节 0/9 差异**；JSONValue(encoding:)/decode(_:) 往返无损且与 fresh coder 路径相等；6 种损坏输入均抛 DecodingError。
2. **共享 coder 并发**：共享 JSONDecoder 64 线程解码 2000 项 0 错误；共享 encoder 并发往返（语义相等）0 错误。**注意**：发现普通 Codable 结构（keyed container）在 Linux Foundation 下逐次 encode 的键序可能变化（2 种顺序）——不改变本仓库 JSONValue 路径（字典编码稳定），但说明“字节等价”不能作为泛化断言（CORE-09）。
3. **SidecarRegexCache 逐字副本**：Mutex<[String: NSRegularExpression]> + withRegex<T: Sendable> + [NSRange]/tuple 返回在 Swift 6 下编译通过；15 个文件名（尾号/无数字/中文/空串/隐藏文件）新旧 filenameSequence 结果全部相等；32 线程并发调用结果与旧实现一致。
4. **新旧 parseISODate 差分**：16 种输入（ISO 带/不带小数秒、+08:00、EXIF 冒号、空格、坏输入、空串）结果全部一致（含 NaN 相等判断）；ISO8601DateFormatter() 默认 formatOptions == [.withInternetDateTime]；16 线程并发结果一致。
5. **SQLite 语义（python3 3.37.2）**：PRAGMA mmap_size 在 WAL 文件库/只读连接上可设并读回 268435456；>2GB 自动钳制 2147418112；:memory: 下返回空（代码跳过有依据）。PRAGMA optimize 在小库 no-op、事务内不报错、只读连接不报错；本机 3.37 上未生成 sqlite_stat1（说明常规路径成本接近 no-op，但大库行为需 macOS/新 SQLite 实测）。
6. **DISTINCT 删除等价性（真实 DDL + 5k 合成库）**：用 scripts/perf-sqlite-bench.py 的 extract_ddl()（55 表/86 索引/81 FK）建库 + Seeder 造数后：
   - photo.list_page A(DISTINCT) vs B(no DISTINCT)：200/200 行，**行集与顺序完全相同**；
   - 无 ORDER BY 变体：2250/2250 行，行集相同；
   - 追加 buildWhereClause 风格 EXISTS 条件（photo_keywords / person_photos）+ ORDER BY p.filename DESC：id 序列完全相同；再加 LIMIT 50 OFFSET 10 仍完全相同；
   - perf-sqlite-bench.py --rows 1000 --compare 本机 exit 0，A/B 1.28x（与 docs 的 1.2-1.4x 同量级）。
   结合 DDL 中 photo_metadata_cache.photo_id ... UNIQUE（SchemaCurrent+DDLDomain.swift:82-90）与 buildWhereClause/buildConditionSql 内所有 JOIN 都只出现在 EXISTS/子查询里（grep 核对 PhotoFilterQuery.swift:507-1147），**DISTINCT 冗余的证明成立**。
7. **DBStatementCache 作用域核对**（逐调用点）：17 处调用全部是同一 connection 的同步函数局部作用域；事务内（AssetRepo+Scan:57-96、CollectionRepo.removeItems:372-389、StackRepo:323-365、FaceRepo+Observations:489-522）创建的语句走写连接（DBConnection.prepare 仅 depth==0 才借只读池，DB.swift:257-273），非池化；事务外只读循环（PhotoRepo.getLookupByIds、DeliveryRepo.getMany、CollectionRepo.existingPhotoIds、CullingReadQuery.existingPhotoIds、GlobalDuplicateQuery、StackRepo.directMembers、CullingReadQuery.clearCullingProjection）都是 SELECT/UPDATE，不会跨事务边界执行，DBStatement.readScopeDepth 的 fail-closed 不会被这些站点触发（read-scope 守卫 DB.swift:505-515）。缓存随作用域 deinit → finalize/归还池连接的顺序正确（DBStatement.deinit:496-500）。
8. **LRU 逻辑**（Linux 探针逐字复刻 Cache 的 LRU 逻辑，实测输出 LRU loads=6 count=4 loadsAfterHits=4：4 键填满→命中不重载→插入第 5 键驱逐最久→被逐出键重载）与作者 docs 的 LRU_PROBE_OK 一致；驱逐只丢缓存引用，FaceInferenceEngine 持有 provider 强引用（Inference.swift:50,57），不会释放正在推理的实例。
9. **JobService async retry 语义**（Linux 探针逐字复刻 writeTerminal，实测）：首败后 elapsed=0.20024s 重试一次成功（attempts=2）；两次失败返回 failed（attempts=2）；Task 取消时 elapsed=0.00004s 立即返回、仍重试一次（attempts=2）——与 docs 的 RETRY_PROBE_OK（200.3ms/0.0ms）一致。settle 全仓仅 1 个调用点（JobService+Claim.swift:183，已改为 await），Tests 无直接调用（compile 无悬空调用点）。
10. **LibraryPackageService 人物绑定**：list() 返回全量 persons（无过滤，PersonRepo+Query.swift:11-15）、get(id:) 仅存在性判定（:46-54）、upsertByName 同名返回既有 id（PersonRepo+Identity.swift:13-29），新 id 也并入 knownPersonIDs ⇒ 非并发导入下与逐条 get 等价。
11. **其它等价性**：QualityService.applyRelativeRanks 的 firstIndex→字典映射保持“首次出现下标”（:485-505）；NavigationService.group 的 previous==行[index-1] 成立（:292-333）；SidecarXMPProvider.readSidecar 去掉多余 fileExists 后语义等价（contents 对不存在/目录/不可读都返回 nil，:293-300）；BackupStore.list 的 decoder/ISO formatter 提到循环外不改变配置；ExternalMetadataMigrationService 静态 decoder 无跨调用可变配置（outputFormatting 等全仓只在**局部** encoder 上设置，共享 coder 从未被 mutate —— grep 核对）。
12. **公开 API / 协议面**：本轮 core 改动未新增/修改 public 符号（DBStatementCache/JSONValueCoding/RepoJSONCoding/SidecarRegexCache/LegacyWallDateParsers 均 internal/private；mmapSizeBytes internal；settle/decodeCached/makeInsert 均 internal 且仅同模块调用点）。check-protocol-surface --strict PASS 佐证。

## 3. Coverage & limitations（覆盖与验证天花板）

- **覆盖**：git diff origin/main...HEAD -- desktop/native/gather-core/Sources 的 **44 个文件全部读过改后代码上下文**（不是只看 diff），并逐一核对了任务列出的 6 个热点：DBStatementCache 全部 17 个调用点、PRAGMA mmap/optimize、共享 coder、Mutex 正则缓存、PhotoFilterQuery DISTINCT、N+1/async 重构（CullingService/LibraryPackageService/MetadataKeywordWriter/MetadataDisposition/EmbeddingModel/ExternalMetadataMigration/JobService）。
- **不能验证（macOS-only）**：① macOS 编译（app/UI/GatherMetadataIO 等 target，含新增 Synchronization.Mutex 用法在 Darwin 的可用性——目标平台 macOS 26，Mutex 需 15+，静态层面满足）、check-warnings.sh（Sources 级 warnings-as-errors，CORE-04 的兜底）；② swift test 全部 1970+ core 测试与新增 JSONValueCodingTests；③ SQLite 在 macOS 系统版本上的 mmap/optimize 实际行为与耗时（本机 3.37 探针只证明 PRAGMA 可设/不报错）；④ AppKit/CoreML/CoreGraphics 行为（unsafeDowncast、DateFormatter 线程安全承诺、mmap 在 APFS/FileProvider 上的表现）；⑤ UI 并发时序（CORE-01 的实际触发概率需要 app 内“导入客户校样 + 用户同时挑片”的真机复现）；⑥ 性能数字（作者 docs 的 bench 数据只能用 scripts/perf-sqlite-bench.py 在 Linux 复现相对趋势，不能代表 macOS/Instruments 结果）。
- **本文件未修改任何源码/测试/脚本/其他 docs**；探针与日志只写在 .gather/（gitignored）。

## 4. 附：证据命令索引（可复现）

    # 语法（44 files, 0 fail）
    for f in $(git diff --name-only origin/main...HEAD -- 'desktop/native/gather-core/Sources/**/*.swift'); do
      .gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex "$f" || echo "FAIL $f"; done

    # 唯一 Linux 可类型检查 target（PASS）
    HOME=$PWD/.gather/home .gather/swift62/usr/bin/swift build \
      --package-path desktop/native/gather-core --scratch-path .gather/R1core-spm --target GatherProtocol

    # 门禁（本机独立重跑）
    for g in check-protocol-surface.sh check-cleanup-ratchet.sh check-perf-ratchet.sh \
             check-test-catalog.sh check-layering.sh check-docs-facts.sh; do ./scripts/$g; done
    PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh

    # 探针（我新增在 .gather/R1core-probes/，非仓库文件）
    .gather/swift62/usr/bin/swiftc -swift-version 6 -O .gather/R1core-probes/probe.swift \
      -o .gather/R1core-probes/probe && .gather/R1core-probes/probe
    python3 .gather/R1core-probes/distinct_probe.py     # DISTINCT 行等价（真实 DDL）
    python3 .gather/R1core-probes/sqlite_probe.py       # mmap/optimize 语义
    python3 scripts/perf-sqlite-bench.py --rows 1000 --compare

## 5. 评审后工作区修正（2026-11-18 02:40+，lead/peers 已应用）与残余

> 本节是应 lead 要求（“持久化当前发现后继续完善”）在**评审结论已写入之后**，对工作区
> （未提交 diff）里针对本报告 PDF 的修正做的**二次复核**。工作区不再等于评审基线
> HEAD 5ea5c38f；下述修正均经我重新读代码 + swiftc -parse 复核（无 macOS 编译）。

| 对应 finding | 工作区修正 | 我的复核 | 残余 |
|---|---|---|---|
| CORE-01 | CullingService+Commands.swift 当前版本：未触碰照片也恢复逐张实时 getDecision（preloadedDecisions 现在只用于变体人工保护）。syntax parse OK。 | 读 :440-455 当前代码：expectedRevision 与 updateState 的 currentRow 都来自实时行 ⇒ revision 冲突检测恢复（与旧实现同窗口）。 | **残余 CORE-01b（P3）**：兄弟变体的 decisionSource==manual 判定仍读批前快照（并发写者在批次期间给同资产另一变体设 manual 仍可能被覆盖；窗口=整批，概率低）；且 touchedPhotoIds/touchedAssetIds/needsLiveRead 已成为死代码（仅 _ = needsLiveRead），:409-413 注释仍描述旧逻辑。建议：删除死代码或改回变体实时读（每照片变体数通常 1-2，代价可接受），并修正注释。 |
| CORE-02 | Database.close() 的 PRAGMA optimize + busy_timeout 调整整体移除（Database.swift 当前版本注释引用 CORE-02）；docs perf-db4.md 已改为“经独立评审移除”。 | 读当前 close()：仅 connection.close()，幂等/不抛错语义保持；swiftc -parse OK。 | 无功能残余；建议仍补一条 close 不抛错/幂等回归测试（CORE-03 的一部分）。 |
| CORE-05 | DBStatementCache 增加 Entry{statement, owner} + 命中时 assert(owner === connection)。 | 读当前实现 + parse OK：DEBUG 下可拦跨连接复用；release 下仍无检查（可接受）。 | 无（可选：limit=14 余量问题仍在，属 CORE-05 附注）。 |
| CORE-13（及 CORE-06 相邻） | NavigationService 的 LegacyWallDateParsers 从无锁 static DateFormatter 改为 Mutex 锁盒子里惰性创建 + 锁内解析。 | 读当前版本 + parse OK；另用独立 Swift 6 探针逐字复刻该 Mutex/State/DateFormatter 结构，-warnings-as-errors 编译通过，EXIF/空格/坏输入解析结果正确。 | 无；锁内解析会串行化 fallback 解析（仅无时区/EXIF 形态命中，量小）。 |
| CORE-09 | JSONValueCodingTests 对 .object 改为“解析后值等价”，仅对标量/数组保留裸字节断言。 | 读当前测试 diff + parse OK；与我探针结论（JSONValue 语料字节稳定、General Codable 键序不保证）一致。 | macOS 上仍需实际跑一次（测试未运行）。 |
| CORE-10 相关（R5-04） | JobService+Settle.writeTerminal 的取消语义改为 detached sleep：取消时也等满 200ms 再重试（严格保持旧 Thread.sleep 语义）。 | 读当前实现：detached 任务不受父取消影响，await .value 等待满 200ms；与旧实现「停机路径也等满 200ms」一致；无新挂起风险（仅在罕见错误路径多一次 detached task 分配）。 | 无；CORE-10 的“失败路径 pump 最迟晚 200ms”仍在（与旧实现等价，docs 已记录）。 |
| CORE-04 | 未修（SidecarRegexCache 的 T: Sendable + [NSRange]）。 | 本机无法证实 Darwin NSRange: Sendable。 | 保持 P2：请在 macOS 跑 swift build / check-warnings.sh core 确认，或按建议改为内部提取结果。 |
| CORE-03/07/08/11/12/14 | 未修（测试缺口、批读回退、unsafeDowncast、人物快照、mmap 外部截断、测试 try 噪音）。 | 同前。 | 维持对应级别；其中 CORE-03（测试缺口）仍是本轮最高优先级 completeness 项。 |

**修正后门禁复核**：工作区改动只涉及 core Sources/Tests 与 docs/scripts（其他评审的修复）；我重新跑了
check-cleanup-ratchet.sh、check-perf-ratchet.sh、check-test-catalog.sh --strict 均 PASS（工作区状态），
6 个被改 core 文件 swiftc -parse OK。**仍未做 macOS 编译/测试**。

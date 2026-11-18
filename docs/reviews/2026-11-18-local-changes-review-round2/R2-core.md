# R2 gather-core 复核（第二轮）：评审修复验证 + 残余风险独立复核（review2-core / task-31）

- **日期**：2026-11-18（第二轮全量评审）
- **评审基线**：committed HEAD = 0288ea8d（git rev-parse HEAD）；上游 = origin/main = e5c54f37；第一轮基线 = 5ea5c38f，第一轮结论在 docs/reviews/2026-11-18-local-changes-review/R1-core.md。
- **本文件范围**：desktop/native/gather-core/Sources（本地 diff 44 文件，+612/−154）与 Tests（15 文件，+274/−92）。重点：独立验证修复提交 6e940350 的 5 处 core 代码改动 + 1 处 core 测试改动（JSONValueCodingTests），再以新鲜视角复核整个本地 core diff 与第一轮残余项。
- **环境 / 验证天花板**：Linux Ubuntu 22.04，**无 macOS/Xcode/Darwin SDK**；Swift 6.2 Linux 工具链（.gather/swift62）。**本机不能编译 GatherPersistence / GatherApplication / GatherMetadataIO**（GatherPersistence/Database/DB.swift:8 'import os'，Darwin-only；swift build --target GatherPersistence 实测在此失败），**未运行任何 macOS 编译/测试**。本文件的“验证” = 逐行读改后代码 + swiftc -parse（59 个改动 core 文件）+ 唯一可类型检查的 GatherProtocol 及其上的测试文件 -typecheck + **Linux 可运行逻辑探针**（精确复刻改动代码片段）+ 只读门禁。
- **基线纪律**：全部结论以 **HEAD 0288ea8d** 为准。评审进行中工作区出现并行 peer 的对评审响应性改动（未提交，见 §7）；这些**不属于**本评审基线，除明确标注处外不纳入结论。本评审未修改任何 tracked 文件；探针只在 .gather/R2core-probes/（gitignored）。

## 0. 结论速览（triage）

- **1 条确定性 P0（测试 target 编译中断 ⇒ CI 必红）**：修复提交 6e940350 在 JSONValueCodingTests.swift:128 引入非法 Swift（try 出现在 == 右侧）。**core 测试 target 无法编译，CI 的 swift test 必然失败**（产品 target/Sources 告警门禁不受影响）。本机 swiftc -typecheck 确定复现；swiftc -parse 不报，故第一轮 §5 的“parse OK”没拦住。**评审期间工作区已出现一份未提交修复（非本评审所做），我独立 typecheck 通过**（见 §2.6/R2C-01）。
- **5 处修复的语义验证**：
  - **JobService+Settle detached 200ms 重试：修复正确**（Linux 逐字探针 18 断言全过：父任务先取消/等待中取消都仍等满 ~200ms 后重试一次，成功路径零等待、无双重 sleep；对照旧 Task.sleep 版本取消时 40ms 立即重试，证明 R5-04 修复有效）。
  - **NavigationService Mutex 日期解析：修复正确**（22 种输入与上游逐值 0 mismatch，16×500×22 并发 0 漂移；顺序 exif→dashed 保留）。**macOS 编译风险基本解除**：工具链 Synchronization 接口明确 Mutex 无条件 @unchecked Sendable（对 State 无 Sendable 要求），且同 target 上游已有 Mutex(IngestUnsupportedFormats()) 先例（见 §2.3）。
  - **Database.close 移除 PRAGMA optimize：完全移除、语义未变**（全仓仅剩一行注释；幂等/.closed/不抛错逻辑未动；BestEffort 引用清零但该类型仍被 10+ 处使用，未变死代码）。
  - **DBStatementCache Entry+owner：无新增泄漏环、release 语义不变**（DBStatement 原本已强持 owner；cache 仅函数局部作用域，DBConnection 不持有 cache；assert release 剔除；limit 语义逐字未变）。
  - **CullingService applyImportedPicks：实时读已恢复（与上游同窗口），但“revision 冲突检测恢复”的结论不成立**——preloadedDecision: existing 使 updateState 的 revision 比较仍为恒等式（上游亦然）；变体人工判定仍读批前快照（CORE-01b 残余）。行为相对上游无回归（丢失更新窗口回到 µs 级），评 P2（注释/论断准确性问题，非行为回归）；工作区已在改注释（§7）。
- **第一轮残余复核**：CORE-03（高风险改动无回归测试）仍在且被 P0 放大（测试 target 都编译不过）；CORE-04 重新评估为**低风险**（C 结构体 importer 字段级隐式 Sendable 的证据 + 工作区去泛型约束修复经探针验证；仍无 Darwin SDK 不能 100% 断言）；CORE-07 KeywordWriter 整批退化仍在（工作区已加回逐行 fallback）；CORE-12 mmap 外部截断仍在（可接受，建议文档声明）；DBStatementCache limit=14 零余量仍在。
- **门禁**：HEAD 上 check-protocol-surface --strict、check-cleanup-ratchet、check-perf-ratchet、check-test-catalog --strict、check-layering、check-docs-facts、check-repo-hygiene（含 shellcheck [f]/l10n [g]）**全部 PASS**（注意：门禁不编译测试 target，因此不会发现 R2C-01）。

## 1. Findings 表

> 级别：P0=崩溃/数据丢失/编译中断/安全；P1=很可能正确性回归或 CI 红；P2=风险/健壮性/最优性；P3=nit。位置均为 **HEAD 0288ea8d 行号**（工作区并行改动会改变行号）。Conf = 仅基于本机证据的置信度。

| ID | Sev | 位置 | 问题 | 证据 | 建议 | Conf | macOS 不可验证? |
|----|-----|------|------|------|------|------|------------------|
| R2C-01 | **P0** | Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift:128（commit 6e940350 引入） | '#expect(try JSONValue.parse(json) == try JSONValue.parse(baseline), …)' 非法：try 不能出现在非赋值运算符右侧。**GatherCoreTests 编译失败 ⇒ CI 'gather-core tests' job 必红**（swift test 会构建测试 target；scripts/check-warnings.sh 只构建 Sources，不拦）。 | 本机 swiftc -typecheck -swift-version 6 -warnings-as-errors -I <GatherProtocol module> 对 HEAD 版本直接报 'error: try cannot appear to the right of a non-assignment operator'（macro expansion 同处）；git grep '== try ' HEAD -- '*.swift' 全仓仅此 1 处；该行由 git show 6e940350 新增（5ea5c38f 无）。CI 证据：.github/workflows/ci.yml:106-133 的 'Core tests' step（swift test --package-path desktop/native/gather-core 在 :117；该 step 会构建 GatherCoreTests）。**工作区已有未提交修复（先取值再断言），我独立 typecheck 通过；最小修复（仅删右侧 try）也 typecheck 通过**（见 §2.6）。 | 提交该修复（或等价：删第二个 try；行首 try 覆盖整个表达式）。修后必须重跑 core 测试 target 编译（macOS 上 swift test；本机只能对测试文件 typecheck）。 | **高**（语法规则平台无关） | 否 |
| R2C-02 | **P2** | Sources/GatherApplication/Services/Culling/CullingService+Commands.swift:439-472（对照 updateState:50-63、上游 e5c54f37 同函数） | **CORE-01 修复只缩小了窗口，没有恢复 revision 冲突检测**：:442-443 每张实时 getDecision 后，:463 expectedRevision = existing.revision、:471 preloadedDecision: existing 一起传给 updateState ⇒ updateState:52-57 的 currentRow = preloadedDecision 与 expectedRevision 同源，:59-63 的 revisionConflict 分支对本函数**不可达**（修复提交新增注释 :439-441 自称消除“同源恒等式”，与代码自相矛盾）。上游也是同样写法 ⇒ 这不是本分支引入的行为回归；实际收益是丢失更新窗口从“整批时长”缩回上游的“逐张 µs 级”。**残余 CORE-01b**：:446-458 变体人工判定仍读批前快照（:433-435 批量预载），批次窗口内另一写者给同资产变体设 manual 仍可能被 imported 覆盖；:450-451 注释“批量快照与实时读同义”只在无并发写者时成立（本批自身写入不会产生 manual，故单线程下成立）。 | 逐行读 HEAD/上游两版 + updateState 全文；LiveCullingAPI.swift:223-244 在 Task.detached 里调用本函数 ⇒ UI 同时挑片与该批并发是真实场景（批次窗口=整批）。 | 若要**真正**恢复检测：在 updateState 事务内用 existingRows[photoId] 的 revision 校验 expectedRevision（而不是事务前的 preloadedDecision）；退一步：不传 preloadedDecision（每张多 1 次查询）。变体人工判定改回逐变体实时读（每资产变体通常 1-2 张；会重新引入部分 N+1，需权衡）。至少让注释准确（工作区已改，见 §7）。 | 高（逻辑可证） | 否 |
| R2C-03 | P3 | 同上 :409-412 | HEAD 注释“本批自己写过的照片/资产在后续迭代改用实时单行读，保证 revision 与逐张实现一致”描述的是**已被删除**的 touchedPhotoIds/touchedAssetIds 逻辑（git grep touchedPhotoIds/touchedAssetIds HEAD = 0 命中）；属于对 6e940350 修复的过时残留说明。 | 读 HEAD 与 git diff 5ea5c38f..HEAD。 | 删除/改写为当前语义（工作区已改，§7）。 | 高 | 否 |
| R2C-04 | P3（第一轮 P2，**重新评估降级**） | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:21-39（HEAD） | CORE-04：SidecarRegexCache.withRegex<T: Sendable> + 调用点 :96 返回 [NSRange] ⇒ 若 Darwin SDK 未给 NSRange Sendable，macOS 编译会失败。**新证据表明风险低**：① 本机 Swift 6.2 用 Glibc C 结构体验证 importer 对 C struct 是**字段级隐式 Sendable**（timespec() 通过 requireSendable，含指针的 tm() 不通过）；Darwin 的 NSRange 是 typedef struct _NSRange { NSUInteger; NSUInteger; } 的 C 结构体 ⇒ 同规则应隐式 Sendable。② 即便 Darwin 侧不成立，工作区已把 T: Sendable 去掉（§7），我用逐字复刻探针（T 无约束 + 调用点传 [NSRange]/(String,String) 元组）在 Swift 6 -warnings-as-errors 下**编译并运行通过**（Mutex.withLock 的 sending Result 不要求 T Sendable）。残余：仍无 macOS SDK 不能 100% 断言。 | Linux 探针：sendable_cstruct.swift（C struct 隐式 Sendable 规则）、regex_generic_probe.swift（无约束 withRegex + NSRange 调用点）。 | 采用工作区的“去 T: Sendable”修复即可闭环；macOS 首跑顺带跑 check-warnings.sh core。 | 中高 | 是（Darwin SDK 标注） |
| R2C-05 | **P2** | 全部 core 性能/并发改动（DBStatementCache、applyImportedPicks revision 语义、JobService async 重试、EmbeddingModel LRU、Database.close、applyImportedPicks 变体 manual 保护） | **CORE-03 未修**：高风险运行期改动仍无回归测试。修复提交 6e940350 对 core Tests 只改了 JSONValueCodingTests（且还编译不过，R2C-01），未新增任何 core 回归测试；git diff 5ea5c38f..HEAD -- desktop/native/gather-core/Tests = 1 个文件。现有 ClientSelectionApplyTests（CullingServiceTests.swift:2071-2138）只覆盖基本语义，不覆盖“同资产多变体 manual 保护 + 并发 revision”。 | git diff --stat 5ea5c38f..HEAD；读 CullingServiceTests.swift:2071-2138；门禁 check-test-catalog 只数 @Test/#expect 不编译。 | 至少补：applyImportedPicks 同资产多变体 manual 保护（可纯函数/SQLite 测试）；DBStatementCache（跨连接 DEBUG assert、末块、失败路径）；Database.close 幂等/.closed；JobService 取消+重试；LRU 驱逐。注意：这些测试要能跑起来的前提是 R2C-01 先修。 | 高 | 否（测试可在 macOS CI 跑） |
| R2C-06 | P3 | Sources/GatherApplication/Services/Metadata/MetadataKeywordWriter.swift:127-141（HEAD） | CORE-07 未修：getBatch 整批失败 → cachedRows = []；旧实现逐张 get + 逐行 catch 只丢失败行。DB 级错误时 externalChanged 检测对**全批**退化为“无缓存行”（保守方向，不写错误值；触发概率极低）。 | 读 HEAD 代码 + MetadataCacheRepo.getBatch 的 chunk 800 整批抛语义。工作区已加逐行 fallback（§7），未提交。 | 采纳工作区 fallback（catch 内逐张 try? + warn）。 | 高（语义）/低（概率） | 否 |
| R2C-07 | P3 | Sources/GatherPersistence/Database/DB.swift:13-19,131-138（CORE-12） | PRAGMA mmap_size=256MB 保留：外部进程原地截断库文件时 mmap 连接有 SIGBUS 风险；仓库内部 restore/reset 均先 close 再换文件（第一轮已核对，本次代码未改）。 | 读 HEAD（本分支只有新增说明与设置，无其它 mmap 改动）；第一轮 Python 探针（可设、只读连接生效、>2GB 钳制）结论仍适用。 | 可接受；在 README/DEVELOPMENT 增一句“Gather 运行期间勿截断/原地改写库文件”。 | 中 | 是（APFS/FileProvider/外部截断） |
| R2C-08 | P3 | Sources/GatherPersistence/Database/DBStatementCache.swift:31-57；AssetRepo+Scan.swift:62 | CORE-05 修复本身 OK（见 §2.5）。附注：AssetRepo+Scan 的 limit: 14 与 ensurePhoto 的 **14 条 statements.statement 调用恰好相等（零余量）**——未来加第 15 条 SQL 会静默退化为逐张 prepare（仅性能，不会错）。release 下跨连接复用仍无检查（Entry.owner 只在 DEBUG assert；与修复前一致，属既有 API 形状）。 | grep -c 'statements.statement('（ensurePhoto 区域 = 14）；读 DBStatementCache 全文与调用点。 | limit: 16 留余量并在调用点注释“当前 14 条”；可选：release 下对 owner 做一次 precondition（会改变 release 行为，不建议）。 | 高 | 否 |
| R2C-09 | P3 | Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift:19-40；MetadataDispositionService.swift:57-76 | CORE-06 残余：SidecarRegexCache 是**全局非递归 Mutex 且 body 在锁内执行**：① 未来任何 body 内再调 withRegex 会死锁；② round-4 把 conflicts() 的 XMP 读改成 4 路并发后，normalizeKnownPrefixes/langAttribute 的**正则匹配阶段仍被这把锁串行**（文件 IO/XMLParser 仍并行）。当前调用点无嵌套（liMatches 锁外再循环调 langAttribute），且只返回 Sendable 值。 | 读 HEAD 全部 withRegex 调用点（4 处，IPTC/IPTCReading）；SidecarRegexCache 结构对照。 | 在文件头注释“body 内禁止再调 withRegex”；若要真正并行，把匹配移出锁（NSRegularExpression 不可变，需确认线程安全）或按 pattern 分锁。 | 高 | 否 |
| R2C-10 | P3 | docs（**不属本写域，移交 docs-steward**）：docs/reviews/2026-11-18-local-changes-review/00-overview.md:21；docs/reviews/2026-11-17-round2-hardening/perf-core-round2.md:13,48-54 | 文档论断与 HEAD 代码不符：① 00-overview 列的“修复提交 33ef7313（本轮评审归档与文档修正）”**不是 HEAD 的祖先**（git merge-base --is-ancestor 33ef7313 HEAD = false；HEAD 的归档提交是 0288ea8d；33ef7313 是 dangling commit，随时可能被 GC）。② perf-core-round2 说 touched* 集合“仅保留给变体判定注释口径”，实际代码里已被**整个删除**（只剩一行过时注释）。③ perf-core-round2:13 说“每张 1 次实时读 + **2 次**批量预载”，HEAD 只有 **1 次**批量预载（:428-436）。④ 00-overview:22 声称 R3-T01 已修，但 HEAD 的修复行编译不过（R2C-01；工作区修复提交后此条成立）。 | git cat-file -t 33ef7313（commit，但非祖先）；git log --oneline -3 33ef7313；对照 HEAD 代码 grep。 | 把 33ef7313 改成 0288ea8d；修正“touched* 保留”与“2 次批量预载”表述；待 P0 修复提交后复核 00-overview #3。 | 高 | 否 |
| R2C-11 | P3 | Sources/GatherApplication/Services/Metadata/MetadataDispositionService.swift:57-76 | 新增的 Task.detached 包 batchAsync 读 XMP：设计合理（不随调用方取消、保序一一对应），但 catch 分支静默返回 []（注释称“理论不可达”），一旦未来 batchAsync 语义变化会**静默**把全部 remote 属性当空（不 warn）。 | 读 HEAD 代码 + BatchRunner.swift 的取消/错误契约；确认捕获类型全部 Sendable（DeliveryRow/DeliveryItemRow/MetadataWriteAttributes/XMPProvider: Sendable）⇒ 编译 plausibility OK。 | catch 里加 GatherLogger.log(level: .warn)；或断言。 | 高 | 否 |
| R2C-12 | P3 | CullingService+Commands.swift:50-63（updateState） | 系统性既有设计（非本分支引入）：任何调用方传 preloadedDecision 都会让 updateState 的 revision 守卫变成“自己和自己比”（applyImportedPicks、batchUpdate 的 disjoint 路径等）。若未来依赖该守卫做并发保护，需改为在事务内基于 fresh 行校验。 | 读 updateState + batchUpdate:330-369 + applyImportedPicks。 | 记录为设计债务；需要时加 validateRevisionAgainstDB 参数/事务内校验。 | 高 | 否 |

## 2. 修复提交 6e940350 逐项验证

### 2.1 CullingService+Commands.applyImportedPicks（结论：窗口恢复=上游；检测未恢复；CORE-01b 仍在）

- HEAD 代码：:409-436 批前 getByPhotoIds 预载（供变体人工判定）；:437-443 每张主照片实时 getDecision；:463-472 expectedRevision+preloadedDecision: existing 调 updateState。touched*/死代码已删（git grep touchedPhotoIds HEAD 0）。
- 与上游逐行对比：上游 e5c54f37 同为“逐张 getDecision + preloadedDecision: existing + 逐变体实时 getDecision”；HEAD 的差异只有变体判定改用批前快照（性能收益，CORE-01b 窗口）与批前多一次预载查询。**主照片行为与上游同构、同窗口（µs 级）**。
- revision 检测：实测逻辑不可达（见 R2C-02/R2C-12 证据），因此“修复了 revision 冲突检测”的说法不成立；但这一缺陷上游同样存在，不是本分支回归。第一轮 §5 表格里“revision 冲突检测恢复（与旧实现同窗口）”的论断应更正为“**丢失更新窗口恢复为上游逐张语义；DB 级乐观锁本就未生效**”。
- history/失败语义：整批 historySink 一条历史（:396-405/:481-484）；CullingServiceError 计 failed 继续（:474-479）；其它错误上抛——均与 5ea5c38f/上游一致；删掉 touched 集合后失败项无需补偿（每张已实时读）。
- 性能：主照片 1 次单行查询/张（旧 N+1 的变体逐点查收益保留在预载）；数百张=数百次 µs 级查询，可接受。

### 2.2 JobService+Settle.writeTerminal（结论：**验证通过 ✅**）

- HEAD :212-228：失败后 await Task.detached(priority: .utility) { try? await Task.sleep(for: .milliseconds(200)) }.value，再原样重试一次；try? 吞掉 detached 内取消（detached 不受父取消影响）。
- **逐字探针**（.gather/R2core-probes/retry_probe.swift，swiftc -swift-version 6 -warnings-as-errors -O，5 场景 18 断言 **RETRY_PROBE_PASS**）：
  - 无取消、两败 → failed、attempts=2、elapsed=0.2002s；
  - 首败后成功 → written、0.2001s；
  - **父任务先取消** → 仍 failed/attempts=2/**0.2002s**；
  - **等待中取消** → 仍 0.2001s 后重试一次；
  - 成功路径 → 0.0000s、attempts=1（**无双重 sleep**）；
  - 对照旧实现（plain Task.sleep）取消时 0.0401s 立即重试 ⇒ R5-04 修复确实恢复了旧 Thread.sleep 的“等满 200ms”语义。
- 调用点：writeTerminal 4 处（:119/:143/:159/:181）全部 await；settle 唯一调用点 JobService+Claim.swift:183 'await settle(...)'（全仓 grep 确认）；不存在悬空同步调用。
- actor/priority：settle/writeTerminal 均为 nonisolated（JobService 是 @unchecked Sendable 类，无 actor）；detached 不继承 actor/取消；Task<Void,Never>.value 不抛错（探针证实）。仅 stdlib API，macOS 编译无特有风险。
- 残余（与第一轮相同、非回归）：瞬时写失败时 activeRuns 清理/pump 最多晚 200ms（旧 Thread.sleep 同样阻塞 200ms，只是不阻塞线程池）。

### 2.3 NavigationService.LegacyWallDateParsers（结论：**验证通过 ✅**，macOS 编译风险基本解除）

- HEAD :494-525：private static let state = Mutex(State())（State 持两个 lazy DateFormatter?），withLock 内先 exif 后 dashed 解析；make 的 locale=en_US_POSIX、timeZone=GMT0、格式串与上游逐字一致；:528-539 parseISODate 先 tsParseISODate 再 fallback（=上游的两次 ISO8601 尝试）。
- **值等价探针**（.gather/R2core-probes/date_probe.swift，逐字复刻上游 e5c54f37 与 HEAD 两版）：22 种输入（EXIF 冒号、空格、ISO 带/不带小数秒、+08:00、无时区、纯日期、坏输入、闰日/非法日、前后空格、空串…）**0 mismatch**（NaN 视为相等）；16 task × 500 轮 × 22 输入并发调用 HEAD 实现 **0 bad**；exif/dashed/garbage 三断言通过。
- **编译 plausibility**：探针含 import Synchronization + private static let state = Mutex(State()) + 锁内解析，在 Swift 6 -warnings-as-errors 下编译/运行通过。工具链接口 .gather/swift62/usr/lib/swift/linux/Synchronization.swiftmodule/x86_64-unknown-linux-gnu.swiftinterface:1529,1547,1553 表明：Mutex<Value> 只要求 Value: ~Copyable，且 'extension Mutex: @unchecked Sendable where Value: ~Copyable'（**无 State Sendable 要求**），withLock 的 body 是 (inout sending Value) -> sending Result。因此 **Darwin 侧 DateFormatter 是否 Sendable 不影响编译**；Mutex 的 @available(macOS 15.0, …) 被 target macOS(.v26)（gather-core/Package.swift:39）覆盖。**同 target 上游先例**：GatherApplication/Services/Ingest/IngestService.swift:16,56 在 e5c54f37 已有 import Synchronization + Mutex(IngestUnsupportedFormats())（该 target 在 macOS CI 编译过）⇒ 该 target 用 Mutex 是既有可行做法。无法验证：本机无 Darwin SDK，未真编译该文件。
- **锁纪律**：解析（含首次 formatter 创建）全在锁内且无重入（make 不回调 date）；与 tsParseISODate 的 RepositoryDateFormatters 锁不嵌套（先释放再取下一把）⇒ 无死锁、无锁序问题。
- **性能**：Linux 200k 次 fallback 解析 HEAD **9.11s** vs 上游 **35.35s**（lock-per-parse 开销相对 DateFormatter 解析可忽略，且远快于旧实现每次新建 3 个 formatter）。锁会串行化同一进程内并发 analyze 的 fallback 解析，但总工作量已降 4x（第一轮已有同类结论）。

### 2.4 Database.close（结论：**验证通过 ✅**）

- HEAD :323-336：stateLock 下 guard !closed → closed = true → connection.close()；中间只有解释性注释。git grep 'PRAGMA optimize' HEAD -- desktop/native **只命中注释行**（:329），无任何可执行 optimize/busy_timeout 代码；BestEffort 在本文件 0 引用（该工具类型仍被 LogFileSink/BackupStore/FaceKwService/AppBootstrap 等使用，未变死代码 ⇒ 无“死类型”新问题）。
- **幂等/不抛错/.closed 语义**：guard !closed else { return } 未动；isClosed（:339-343）与 withOpenConnection 的 guard !closed else { throw .closed }（:349-354）未动；connection.close() 本身不抛。⇒ 无变化。
- **只读 CLI 语义**：close 不再有任何可能写库的路径（原 optimize 可能触发 ANALYZE 写 sqlite_stat1），gather-triage-eval 的“只读”承诺恢复。无法在本机跑 Database（Persistence 因 import os 不能 Linux 编译），验证为源码级 + 全仓 grep。

### 2.5 DBStatementCache Entry+owner（结论：**验证通过 ✅**，含附注）

- HEAD :34-57：private struct Entry { let statement: DBStatement; let owner: DBConnection }；命中时 assert(cached.owner === connection, …)；未命中 connection.prepare 且 statements.count < limit 才入缓存 ⇒ **limit 语义与修复前逐字相同**；release 下 assert 被编译剔除（assert autoclosure 不产生副作用）。
- **无新增泄漏环**：DBStatement 早已强持有 private let owner: DBConnection（DB.swift:470，修复前既有）；DBStatementCache 只作为**函数局部变量**出现（git grep 'DBStatementCache(' = 12 个实例全部局部；DBConnection 无该属性），因此 cache→Entry→owner→connection 不构成环，也不会延长连接生命周期超出语句原有范围。
- **调用点复核**：12 个实例 + 21 个 statements.statement(...) 调用点全部在单一同步函数作用域内，传入的都是该 repo 实例的同一个 connection 存储属性（如 AssetRepo.connection、CollectionRepo.connection…）；AssetRepo+Scan.ensurePhoto 把 cache 作为参数传入但连接仍是同一实例属性 ⇒ 不会触发 DEBUG assert（也即该 assert 目前不会误报；真正的跨连接守护仍是 future-proofing）。
- **附注**：limit=14 零余量（R2C-08）；release 下仍允许跨连接复用（与修复前一致，Entry.owner 仅 DEBUG 生效）。

### 2.6 JSONValueCodingTests（结论：**HEAD 有 P0 编译错误；工作区存在未提交修复，我独立验证其正确**）

- HEAD :128 非法（R2C-01）。第一轮的“diff + swiftc -parse OK”只证明语法树可解析，不证明类型检查通过；CI 的 swift test 会构建测试 target。
- **工作区修复（非本评审所做）**：:126-131 改为先 let parsedBaseline = try JSONValue.parse(baseline) / let parsedJSON = try JSONValue.parse(json) 再 #expect(parsedBaseline == value, …) / #expect(parsedJSON == parsedBaseline, …)。我把该工作区文件复制到 scratch 后 swiftc -typecheck -swift-version 6 -warnings-as-errors（-I 指向本机构建的 GatherProtocol module）**0 error**。
- **最小修复也验证**：对 HEAD 版本仅删右侧 try（#expect(try JSONValue.parse(json) == JSONValue.parse(baseline), …)）同样 typecheck 通过（行首 try 覆盖整个表达式）。
- 注意：该修复只解决“能编译”；测试的**运行**仍只能在 macOS（JSONValue/Foundation 行为）——本机无法跑 swift test。

## 3. 第一轮残余项复核 + 全量 core diff 新鲜扫描

### 3.1 第一轮残余项状态（对 HEAD）

| 第一轮 ID | 本轮状态 | 说明 |
|---|---|---|
| CORE-01b（变体 manual 批前快照） | **仍在（P3 残余，R2C-02）** | 主照片已实时读；变体判定仍快照；单线程下等价，并发外写者窗口=整批 |
| CORE-02（close optimize） | **已修（验证通过）** | §2.4 |
| CORE-03（缺回归测试） | **仍在（P2，R2C-05）** | 且被 R2C-01 放大（测试 target 编译不过） |
| CORE-04（NSRange Sendable） | **降级 P3，且工作区已有闭环修复** | §2.3/§3.2；C struct 隐式 Sendable + 无约束泛型探针 |
| CORE-05（DBStatementCache owner） | **已修（验证通过）** | §2.5；附注 limit 零余量 R2C-08 |
| CORE-06（正则全局锁内 body） | **仍在（P3，R2C-09）** | 全局串行化 + 未来重入死锁风险 |
| CORE-07（KeywordWriter 整批退化） | **仍在（P3，R2C-06）**；工作区已有 fallback 修复（未提交） | |
| CORE-08（unsafeDowncast CF 类型） | 不变（P3） | CoreGraphics macOS-only，无法本机验证；实现按 CFTypeID 判型后 unsafeDowncast，风险与 as! 等价 |
| CORE-09（JSON 字节断言） | 已改值等价（但 HEAD 编译错误 R2C-01） | 第一轮 Linux 探针（JSONValue 路径稳定、普通 Codable 键序漂移） |
| CORE-10（settle async 时序） | 已接受（P3 不变） | §2.2 |
| CORE-11（人物 list 快照） | 已接受（P3 不变） | 单进程导入等价；并发写者窗口极小 |
| CORE-12（mmap 外部截断） | 仍在（P3，R2C-07） | |
| CORE-13（静态 DateFormatter） | **已修（验证通过）** | §2.3 |
| CORE-14（测试 try 噪音） | 不在本任务写域/复核范围（测试卫生） | R3-tests 负责 |
| CORE-01（批前快照 revision 恒等） | **行为窗口已修；检测仍不生效（R2C-02）** | 见 §2.1 |

### 3.2 全量 core Sources diff 新鲜扫描（44 文件，1816 行 diff 全读）补充观察

- **MetadataDispositionService.conflicts（round-4 新增 4 路并发）**：新增 Task.detached 包装 batchAsync，捕获类型经核对全部 Sendable（DeliveryRow/DeliveryItemRow: Sendable、MetadataWriteAttributes: Sendable、XMPProvider: Sendable）⇒ 编译 plausibility OK；不随调用方取消是**有意**的（batchAsync 取消会返回缺项，按下标对齐会错位）。仅 catch 静默返回 [] 为 nit（R2C-11）。
- **共享 JSON coder 扩展面**：本轮把更多逐行 coder 迁到共享实例（JSONValueCoding、RepoJSONCoding、QualityService.jsonEncoder、CullingHistoryRepo.encoder/decoder、ModelReviewService.jsonEncoder/Decoder、LibraryPackageService.jsonDecoder、ExternalMetadataMigrationService.keywordDecoder）。**编译依据**：上游 e5c54f37 已有同型先例 GatherPersistence/Ports/FaceConstraintTypes.swift:103-104（private static let encoder/decoder = JSONEncoder()/JSONDecoder()）⇒ 该 SDK 的 JSONEncoder/Decoder 满足 Sendable，macOS 编译风险低。并发安全依赖 Foundation 的 Sendable 标注（第一轮 Linux 64 线程共享 decoder 探针 0 错）——仍是“假设 Foundation 标注正确”的 P3 级风险，非新引入。
- **ModelReviewService.decodeCached/makeInsert 由 static 改 instance**：全仓调用点只有同文件 :159/:214（都已改），无测试/外部静态调用（grep 确认）⇒ 无编译断裂。
- **BackupStore/ExternalMetadataMigrationService/LibraryPackageService 的 formatter/decoder 上提循环外**：均为不可变配置、逐次等价（第一轮已核 coder 默认配置；ISO8601DateFormatter 默认 options 用法一致）。
- **PhotoFilterQuery 去 DISTINCT**：第一轮已用真实 DDL + 5k 合成库证明行集/顺序等价（join 均为 EXISTS/子查询、photo_metadata_cache.photo_id UNIQUE）；本轮重读 SQL 结构一致，未发现新风险。
- **AssetRepo+Scan 语句缓存**：14 条语句全在 connection.transaction 内创建（写连接、非池化）；candidateInsert 循环外 prepare（INSERT，链写连接）→ 与旧行为等价。**注意**：ensurePhoto 的 14 条恰好用满 limit（R2C-08）。
- **FaceRepo.invalidateDerivedResults/StackRepo 缓存**：均在事务内（写连接），每块 SQL 固定 5/2 条，limit 与语句数匹配；末块不同 SQL 不入缓存（仅性能）。
- **未发现新的 force unwrap / try! / fatalError / nonisolated(unsafe) / @unchecked 新增**：全量 diff 里这些词只出现在注释；新增的 unsafeDowncast（CORE-08）与新增 Task.detached（JobService、MetadataDisposition）都已在上面覆盖。
- 本轮新增/修改的 static let 均为不可变配置对象（coder/formatter/Mutex），无 static var。

## 4. 验证 OK 清单（我实际做了什么）

- **语法**：git diff --name-only origin/main..HEAD -- 'desktop/native/gather-core/**/*.swift' 的 59 个文件 swiftc -parse -enable-bare-slash-regex **0 失败**（Sources 44 + Tests 15）。
- **类型检查（Linux 可做的部分）**：swift build --package-path desktop/native/gather-core --target GatherProtocol（Swift 6，成功构建出 .swiftmodule）；用它 -typecheck 了 JSONValueCodingTests.swift（HEAD=编译错误，修复版=0 error）。GatherPersistence/GatherApplication 因 import os 无法在 Linux 构建（swift build --target GatherPersistence 实测失败于 DB.swift:8），故其余 core 文件无类型检查证据。
- **逻辑探针（Linux，Swift 6 -warnings-as-errors -O，均逐字复刻仓库代码）**：
  1. retry_probe.swift：writeTerminal 取消/重试语义，18 断言 PASS（§2.2）。
  2. date_probe.swift：parseISODate HEAD vs 上游 22 形态 0 mismatch、并发 0 漂移、Mutex/State 编译、性能 9.11s vs 35.35s（§2.3）。
  3. regex_generic_probe.swift：无 T: Sendable 约束的 withRegex + [NSRange] 调用点编译/运行通过（R2C-04 工作区修复的 plausibility）。
  4. sendable_cstruct.swift：Glibc C struct 字段级隐式 Sendable（timespec 通过 / tm 因指针不通过）。
- **门禁（HEAD 上独立重跑，全部 PASS）**：check-protocol-surface.sh --strict、check-cleanup-ratchet.sh、check-perf-ratchet.sh、check-test-catalog.sh --strict、check-layering.sh、check-docs-facts.sh、PATH=.gather:$PATH check-repo-hygiene.sh（[f] shellcheck 0 finding、[g] l10n 全包裹）。**门禁不含“编译测试 target”，因此不会发现 R2C-01**（check-test-catalog 只静态数 @Test/#expect）。
- **代码阅读覆盖**：完整读过 HEAD 的 44 个改动 core Sources 文件的**全部 1816 行 diff 及关键上下文**（非只看 diff）；core Tests 读了 JSONValueCodingTests 全文与 CullingServiceTests 的 imported-picks 相关套件（:2071-2138），其余 14 个测试文件改动由 R3-tests 范围覆盖（我只核了 stat 与 compile 影响）。

## 5. 覆盖与限制（Coverage & limitations）

- **覆盖**：修复提交 6e940350 的 6 个 core 文件全部逐一验证（§2）；第一轮全部 core 残余项复核（§3.1）；本轮新增 core Sources diff 全量扫描（§3.2）；门禁 7 个 PASS；59 个改动 core 文件语法 0 失败；3 个 Linux 逻辑探针。
- **不能验证（macOS-only）**：① macOS 编译（GatherPersistence/GatherApplication/GatherMetadataIO 以及任何依赖 Darwin SDK 的语义——本机无 SDK、无 Xcode；Persistence 因 import os 连 Linux 都编不了）；② swift test（core 1970+ 测试，即使修好 R2C-01 也只能在 macOS 跑）；③ Darwin NSRange/DateFormatter/JSONEncoder 的 Sendable/线程安全标注（§2.3/R2C-04 只能给证据与推断）；④ SQLite 在 macOS 系统版本上的 mmap 实际行为（本机 Python 3.37 探针只证 PRAGMA 语义；optimize 已删）；⑤ Database/DBStatementCache 的真实运行行为（无法编译 Persistence）；⑥ app/UI 并发时序（applyImportedPicks 的真实触发概率）；⑦ 性能数字只在 Linux 逻辑副本上测，不代表 macOS/Instruments。
- **探针性质**：所有 Linux 探针都是对仓库代码的**逐字逻辑副本**（不是仓库模块编译产物），能证明逻辑等价性/语法/并发语义，不能替代 macOS 真编译。

## 6. 复现命令索引

    # 1) 基线与 diff
    git rev-parse HEAD                                 # 0288ea8d
    git diff --stat origin/main..HEAD -- 'desktop/native/gather-core/Sources/**/*.swift'   # 44 files, +612/-154
    git diff --stat origin/main..HEAD -- 'desktop/native/gather-core/Tests/**/*.swift'     # 15 files, +274/-92

    # 2) 语法（59 files, 0 fail）
    for f in $(git diff --name-only origin/main..HEAD -- 'desktop/native/gather-core/**/*.swift'); do
      .gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex "$f" || echo "FAIL $f"; done

    # 3) 编译 GatherProtocol（Linux 唯一可构建 target）
    HOME=$PWD/.gather/home CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc \
      .gather/swift62/usr/bin/swift build --package-path desktop/native/gather-core \
      --scratch-path .gather/R2core-spm --target GatherProtocol

    # 4) R2C-01：HEAD 测试文件 typecheck（期望报错）与修复版（期望 0 error）
    export CLANG_MODULE_CACHE_PATH=$PWD/.gather/cc HOME=$PWD/.gather/home
    git show HEAD:desktop/native/gather-core/Tests/GatherCoreTests/Protocol/JSONValueCodingTests.swift > .gather/R2core-probes/typecheck/head.swift
    .gather/swift62/usr/bin/swiftc -typecheck -swift-version 6 -warnings-as-errors -I .gather/R2core-spm/x86_64-unknown-linux-gnu/debug/Modules .gather/R2core-probes/typecheck/head.swift

    # 5) 逻辑探针
    .gather/swift62/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -parse-as-library .gather/R2core-probes/retry_probe.swift -o .gather/R2core-probes/retry_probe && .gather/R2core-probes/retry_probe
    .gather/swift62/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O -parse-as-library .gather/R2core-probes/date_probe.swift -o .gather/R2core-probes/date_probe && .gather/R2core-probes/date_probe
    .gather/swift62/usr/bin/swiftc -swift-version 6 -warnings-as-errors -O .gather/R2core-probes/regex_generic_probe.swift -o .gather/R2core-probes/regex_generic_probe

    # 6) 门禁
    ./scripts/check-protocol-surface.sh --strict && ./scripts/check-cleanup-ratchet.sh \
      && ./scripts/check-perf-ratchet.sh && ./scripts/check-test-catalog.sh --strict \
      && ./scripts/check-layering.sh && ./scripts/check-docs-facts.sh
    PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh

## 7. 工作区并行修复观察（非本评审基线，仅记录）

评审进行中，工作区出现 peer 对评审意见的响应性未提交改动（git status 记录时间点：HEAD 仍为 0288ea8d）。**这些不是本评审结论的一部分**，也不是本评审所做；我只独立验证了两处与编译相关的点：

1. Tests/.../JSONValueCodingTests.swift：把非法断言拆成先取值再断言；**我 typecheck 通过**（R2C-01 若按此提交即闭环）。
2. Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift：withRegex<T: Sendable> → withRegex<T>；**我用逐字复刻探针验证该签名 + [NSRange] 调用点在 Swift 6 -warnings-as-errors 下编译/运行通过**（R2C-04 闭环）。
3. CullingService+Commands.swift 注释已按 R2C-02/R2C-03 改写（承认 preloadedDecision 同源、变体快照窗口=整批）；MetadataKeywordWriter.swift 已加 R2C-06 的逐行 fallback（语法 parse OK）。
4. docs/reviews/2026-11-18-local-changes-review/00-overview.md:21 的 dangling 提交引用（R2C-10 ①）在工作区已被改为 0288ea8d（并注明 33ef7313 为 amend 前父提交）——按 HEAD 基线该文档错误仍成立，提交后即闭环。
5. 这些改动提交前需重新跑一遍门禁与（在 macOS 上）测试 target 编译；本评审不为其正确性背书，只记录状态。

## 8. 与第一轮结论的差异（更正）

- **R1-core §5 “revision 冲突检测恢复（与旧实现同窗口）” 不成立**：恢复的是“实时读窗口”，updateState 的 revision 比较仍是自比自（上游同缺陷）。见 R2C-02/R2C-12。
- **CORE-04 从 P2 降为 P3 且已有可行闭环**：C 结构体字段级隐式 Sendable + 去泛型约束探针（§2.3/R2C-04）。
- **本轮新增 P0（R2C-01，第一轮漏掉）**：第一轮 §5 说 JSONValueCodingTests “读当前测试 diff + parse OK”，但只做了语法解析；类型检查缺失导致漏掉 CI 红。
- 第一轮“44 文件全部读过”仍成立（本轮复核后确认改动面统计：44 Sources + 15 Tests）。

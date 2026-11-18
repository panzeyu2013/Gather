# gather-core 性能审计 R2：N+1 / 正则 / formatter / 查询计划（task-11）

- **日期**：2026-11-17（基线：git HEAD `4cb3228d` + 本轮工作区改动）
- **执行**：perf-core（子代理；写作用域 `desktop/native/gather-core/Sources/**` + 本文档）
- **约束遵守**：无 Schema DDL / fingerprint 变更、无公开 API 签名变更、无行为/输出顺序/
  错误语义变更、无新依赖、无测试改动、未 commit；未回退 peers 的未提交改动。
- **改动面**：7 个文件，`git diff --stat` = **7 files, +194 / −51**。

## 1. 结论摘要

| # | 修复 | 文件 | 主要收益 |
|---|------|------|----------|
| R1 | N+1：`applyImportedPicks` 批前一次取齐决策行 | CullingService+Commands.swift | 几百张勾选从 ~1000 次单行查询 → 每张 1 次实时读 + 2 次批量预载（2026-11-18 评审 CORE-01 修正：批前快照不能当 revision 冲突检测的 currentRow，未触碰照片恢复逐张实时读；人工保护语义保留） |
| R2 | N+1：包导入人物绑定复用 `list()` | LibraryPackageService.swift | 每条绑定一次点查 → 0 次（数千条绑定） |
| R3 | 正则：`Mutex` 锁盒子缓存 NSRegularExpression | NavigationService.swift | 逐行分组路径每次调用一次正则编译 → 首次编译后 0 次 |
| R4 | 正则：sidecar 读写路径 4 个正则编译缓存 | SidecarXMPProvider+IPTCReading.swift / +IPTC.swift | 逐照片（读）/逐字段（写）路径每次重新编译 → 0 次 |
| R5 | 逐行预计算上提到 `analyze` | NavigationService.swift | 时间戳解析/文件名序号从 2 pass × 每行 → 1 pass × 每行（1 万行省 ~1-2 万次） |
| R6 | 逐行 JSON coder 收口 | QualityService.swift / ModelReviewService.swift / LibraryPackageService.swift | 结果/警告编码、缓存命中的解码从逐行新建 coder → 0 次 |

另产出：**Python sqlite3 查询计划证据**（§5）与**对 round-1「10 个 FK 子列缺前导索引」结论的更正**（实测 1 个）。

## 2. 方法

1. 输入：round-1 审计的静态热点清单（N+1 ×2、逐次正则 ×3、逐次 formatter/coder）+ task-11 指定项；
   从 HEAD `4cb3228d` 复核现状（round-1 修复已进入 `242d6b21`）。
2. 分类标准：`static let`/既有缓存池（`RepositoryDateFormatters`、`RepoJSONCoding`、
   `JSONValueCoding`）已覆盖的视为 fine；逐行/逐照片路径上「每次新建」的才计为热点。
3. 等价性验证手段（Linux 可编译运行小探针）：
   - 正则/Unicode 语义：`swiftc` 编译并运行 Foundation 探针，对 1,112,064 个 Unicode 标量做
     穷举与 2 万随机串差分（脚本在 `.gather/tmp/r2/`，gitignored）；
   - 查询计划：Python `sqlite3` 在内存库重放 `SchemaCurrent` 全部 DDL 后 `EXPLAIN QUERY PLAN`
     （脚本 `.gather/tmp/r2/query_plans.py`）。
4. 验证门禁：`swiftc -parse`（全部改动文件）+ `swift build --target GatherProtocol`（Linux 唯一
   可类型检查的 target）+ 仓库 5 个门禁（§6）。

## 3. N+1 修复（before → after）

### R1 `CullingService+Commands.applyImportedPicks`（客户校样勾选应用）

- **Before**（HEAD :409-425）：每张 photoId 一次 `cullingDecisionRepo.getDecision`，若照片有
  assetId 再对同资产每个兄弟变体各点查一次直到发现人工决策（几百张勾选 ≈ 上千次单行查询）。
  `updateState` 内部还会把同资产全部变体的 revision 一起 +1。
- **After**（:406-497）：
  1. 先按「勾选照片 ∪ 其资产变体」并集收集 `preloadIds`（去重、保持首见顺序）；
  2. 一次 `getByPhotoIds(sessionId:photoIds:)`（仓库内部已按 800 分块）建 `photoId → CullingDecisionRow`；
  3. 主循环按原顺序逐张处理；~~**本批已写过的照片/资产**（`touchedPhotoIds`/`touchedAssetIds`）
     后续迭代回退到实时 `getDecision`，因此同资产多张勾选/重复 photoId 时 revision 与逐张
     实现一致~~ → **评审 CORE-01 修正（2026-11-18）**：批前快照同源会让「未触碰照片」的
     expectedRevision 校验变成恒等式；现已让所有照片在 updateState 前实时 `getDecision`
     （每张 1 次），touched* 集合已随修复删除；批量收益仅来自变体预载，
     updateState 内部比较仍与传入行同源（上游既有设计，不声称恢复 DB 级乐观锁）；
  4. 兄弟变体的人工保护检查读批前快照：本批写入只会把非人工源改成 `imported`，人工行在
     `updateState` 前已被跳过 ⇒ `decisionSource == manual` 判定与逐张实时读同义（注释 :460-462）。
- **语义保持**：结果顺序、`appliedPhotoIds`、`failed` 计数、历史合并、错误分支不变；唯一
  可观察差异是极端并发（另一写者在批处理中途提交）下批前快照可能比逐张读旧——该 API 无
  跨整批事务，属既有竞态窗口，已在实现中把「本批写入」这一确定来源完全处理。

### R2 `LibraryPackageService` 包导入人物绑定

- **Before**（:461-479）：每条 binding 一次 `personsRepo.get(id: binding.personId)`（包内绑定
  可达数千条 ⇒ 数千次单行查询）。
- **After**（:459-493）：`:464` 复用一个 `personsRepo.list()` 结果建 `knownPersonIDs: Set<String>`
  + 姓名索引（原实现本来就要 list() 建 `personIDByName`）；`:486` 用集合判定；
  `upsertByName` 新建的 id 立即并入集合。
- **语义保持**：三级身份解析顺序、首见姓名优先、`skippedUnmappedItems`/计数、后续 `addPhotos`
  分批顺序不变。

## 4. 正则：6 个 NSRegularExpression 站点审计

### 4.1 为什么没有改用「静态 Swift Regex 字面量」

task 假设 `Regex` 是 Sendable 值类型可直接静态复用；**本机 Swift 6.2 实测不成立**：

```text
$ swiftc -swift-version 6 probe.swift   # Regex 字面量 static let
error: static property 'tailDigits' is not concurrency-safe because non-'Sendable' type
       'Regex<(Substring, Substring)>' may have shared mutable state
note: generic struct 'Regex<Output> does not conform to the 'Sendable' protocol
```

此外，Swift Regex 与原 ICU（NSRegularExpression）语义**不等价**：同一 pattern
`(\d+)(?!.*\d)` 在 5,000 个含 Unicode 数字/行终止符的随机串上差分数出 **1,412 处不一致**
（例：`a²1` 旧实现取 `1`，Swift Regex 取 `²1`；`aⅫ1` 同理——Swift Regex 的 `\d` 比 ICU 宽，
把 No/Nl 也当数字）。故「替换成 Swift Regex」会改变输出，违反行为保持硬约束。

### 4.2 采用方案：`Synchronization.Mutex` 锁盒子缓存 NSRegularExpression

`NSRegularExpression` 创建后不可变，但未标注 Sendable；按 `docs/DEVELOPMENT.md` §Swift 6
并发约定（禁止 `nonisolated(unsafe)`/`@preconcurrency` 掩盖诊断）用 stdlib 的
`Mutex<NSRegularExpression?>` 锁盒子持有（与 `OSAllocatedUnfairLock` 同类的锁盒子写法，
**不新增 `@unchecked Sendable`**，cleanup-ratchet 的 unchecked_sendable 保持 60）。
模式/options/引擎完全不变 ⇒ 行为逐字节等价。
此外**匹配也在锁内执行、只把 Sendable 结果（String/NSRange/元组）带出锁**——不依赖
「NSRegularExpression 匹配跨线程安全」这类未写进文档的假设；`filenameSequence` 同样是
锁内完成匹配后返回 `Int?`。

小探针验证（Linux 编译并运行）：`Mutex<NSRegularExpression?>` + `withLock` 首次编译、后续
命中；`IMG_0001.JPG → 1`、`IMG_0042_EDIT.jpg → 42`、`IMG.JPG → nil`、`IMG_١٢٣.jpg → nil` 全部正确。

### 4.3 站点处理

| 站点 | 调用频率 | 处理 |
|------|----------|------|
| `NavigationService.filenameSequence:461-475`（原 :444-453） | 逐行分组（1 万行 × 1-2 pass） | **已缓存**（:462 `Mutex` 盒子）+ R5 预计算上提 |
| `SidecarXMPProvider+IPTCReading:37`（declRegex，sidecar 读） | 逐照片 sidecar 读 | **已缓存**（`:69-77` → `SidecarRegexCache.withRegex`，锁内取出 `[(prefix,uri)]`） |
| `SidecarXMPProvider+IPTCReading:59`（tagRegex，非规范前缀替换） | 逐照片读（仅出现别名前缀时） | **已缓存**（`:94-97` → `[NSRange]`）；`escapedPattern` 从「每标签×每替换」上提到循环外（`:100-108`） |
| `SidecarXMPProvider+IPTC:103`（rdf:li 合并） | 逐描述性字段写 | **已缓存**（`:103-112` → `withRegex`，锁内取出 `[(attributes,whole)]`） |
| `SidecarXMPProvider+IPTC:129`（xml:lang，逐 rdf:li） | 逐字段/逐 li 写 | **已缓存**（`:129-137` → `withRegex`，锁内取 `String?`） |
| `OutputPostCommandRedaction:30`（导出后命令脱敏） | 每次导出命令 × 规则（非逐行） | **不修**：冷路径，保持原样 |

缓存实现位置：`SidecarRegexCache`（`SidecarXMPProvider+IPTCReading.swift:17-44`，internal，
按 `options.rawValue|pattern` 键缓存；两个文件共用）：`withRegex(_:options:_:)` 持锁编译+
匹配，返回 `T: Sendable`。上面的 helper 形状已在 Linux 用独立探针编译并运行验证
（`static let Mutex<[String: NSRegularExpression]>` + `withLock` + 泛型 `T: Sendable` 返回）。

## 5. 查询计划证据（Python sqlite3，仅建议不改 schema）

从 `SchemaCurrent+DDLCore/Domain/Indexes/Workbench` + `SchemaCurrent.addendumDDL` 按
`ddlCore + ddlDomain + ddlIndexes + addendumDDL + workbenchDDL` 顺序提取 DDL 并在内存库重放，
**校验通过：55 表 / 86 显式索引 / 81 外键**（与 `SchemaCurrent.expected*` 完全一致，说明提取无遗漏）。

生产库不执行 `ANALYZE`（源码 0 处），故以下为「无 sqlite_stat1」的生产默认计划：

| 查询（对应仓库位置） | `EXPLAIN QUERY PLAN` | 评价 |
|---|---|---|
| photo.list_page（`PhotoFilterQuery.filterPhotos:145-155` + filename 排序/limit） | `SEARCH p USING INDEX idx_photos_asset_group (session_id=?)` + 相关子查询 `SEARCH fo USING INDEX idx_face_observations_photo (photo_id=?)` + `USE TEMP B-TREE FOR DISTINCT` + `USE TEMP B-TREE FOR ORDER BY` | 索引可用；`DISTINCT`+`ORDER BY` 需临时 B 树排序（全会话行）。若要优化，建议评估把图库分页改为 `PhotoRepo.getAssetPage` 的游标路径（已存在），而非加索引 |
| analysis_jobs 队列轮询（`AnalysisJobRepo.list(status:)`） | `SEARCH analysis_jobs USING INDEX idx_analysis_jobs_status_priority (status=?)` | **恰好覆盖 ORDER BY(priority, updated_at, rowid)**，好 |
| triage_suggestions 载入（`TriageRepo.loadSuggestions`） | `SEARCH ... USING INDEX idx_triage_session_confidence (session_id=?)` + `USE TEMP B-TREE FOR ORDER BY` | 索引只有 session 前导；`ORDER BY photo_id` 需排序。**建议**（下次 user_version 迁移）：`(session_id, photo_id)` 覆盖索引可消除排序 |
| culling_history 窗口（`CullingHistoryRepo.list`） | `SEARCH ... USING INDEX idx_culling_history_session (session_id=?)` | 好（id DESC 由 rowid 倒序，无需排序） |
| deliveries 按 xmp_path 批量读（`DeliveryRepo+Read`） | `SEARCH deliveries USING INDEX sqlite_autoindex_deliveries_1 (xmp_path=?)` | 好 |
| delivery_items 按 delivery_id 读 | `SEARCH delivery_items USING INDEX sqlite_autoindex_delivery_items_1 (delivery_id=?)` | 好（UNIQUE 自动索引） |
| photo_metadata_cache 按 session | `SEARCH ... USING INDEX idx_metadata_cache_session_rating (session_id=?)` | 好 |
| asset_files volume+path 查（Scan/Relink 热路径） | `SEARCH ... USING INDEX idx_asset_files_volume_path (volume_id=? AND normalized_path=?)` | 好 |

### 5.1 对 round-1「10 个 FK 子列缺前导索引」的更正

用 `PRAGMA foreign_key_list` + `PRAGMA index_list/index_info` 逐列核对（PK/UNIQUE 自动索引
也算可用 BTREE）：

- **真正缺前导索引的 FK 子列 = 1 个**：`session_assets.display_file_id → asset_files`
  （点查计划为 `SCAN session_assets`），且源码中**没有任何按 `display_file_id` 过滤的查询**
  （只在 INSERT/UPDATE 写入，:304/:671 等），当前无实际性能影响；
- 「只计显式 `CREATE INDEX`、忽略 `sqlite_autoindex`（UNIQUE/PK）」口径下 = **19 个**——
  但自动索引同样是真实 BTREE，等值点查与 FK 子行查找可用，不应算缺失；
- 两种口径都复现不出「10」。**建议 lead 在总览里把该数字更正为「1 个（无实际查询使用）」**，
  或在下次 schema 迁移时顺手补 `CREATE INDEX idx_session_assets_display ON session_assets(display_file_id)`
  （同时需更新 `expectedExplicitIndexCount` 86→87 与 `expectedShapeFingerprint`，属单独变更）。

## 6. Formatter / JSON coder 审计（其余 per-call 站点）

### 6.1 本轮修复（逐行路径）

| 位置 | Before | After |
|---|---|---|
| `QualityService.encodeJSON`（:509） | 每张照片 result + warnings 各 new `JSONEncoder()`（1 万张 ≈ 2 万次） | 实例 `jsonEncoder`（:140）复用，0 次 |
| `ModelReviewService.decodeCached`（:398）/`makeInsert`（:406） | 每条缓存命中 new decoder；每条结果 new 2 个 encoder | 实例 `jsonEncoder/jsonDecoder`（:66-67），0 次 |
| `LibraryPackageService.decodeKeywords:852` / `decodeDescriptive:864` | 包导出/导入每张照片各 new `JSONDecoder()` | 静态 `jsonDecoder`（:30），0 次 |
| `NavigationService`（R5） | 每个分组 pass 各算一遍 `parseISODate`/`filenameSequence` | `analyze` 预计算一次（:115-118），两个 pass 共用（签名 :284-289） |

### 6.2 复核后判定「非热点/不修」的站点（保留原样）

| 位置 | 频率 | 结论 |
|---|---|---|
| `MetadataInlineInputs.normalizedDateTime`（Protocol，最多 6 个 DateFormatter/次） | 每次 inline metadata 请求；双源冲突比较按单张照片 API | 非逐行；且 Protocol 不能复用 Persistence 缓存、`ISO8601DateFormatter` 非 Sendable（无 @unchecked 前提下无法静态化） |
| `LogFileSink.rotate`（DateFormatter） | 仅日志轮转（5MB 一次） | 冷 |
| `S3ShareTransport` / `OutputShareManifest` / `BackupStore` / `MaintenanceService` / `DiagnosticsCollector` / `RestoreSupport` / `ResetSupport` / `TriageService` 的 ISO/Date formatter | 每次分享/备份/诊断/恢复/generate | 一次性操作，相对 IO/网络成本可忽略 |
| `CullingService+Paging.filterKey`（每次翻页 new JSONEncoder） | 每页 1 个 | 单次分配，非逐行 |
| `WorkflowRegistry` JSONValue 往返（:552/:561）、`JobInputs`（每次 API）、`SmartAlbumRepo.filterCriteriaJSON`（每次写） | 每请求/每写 | 非逐行 |
| `ExternalMetadataMigrationService.decodeKeywords`（迁移命令逐行 decoder） | 维护命令、数千行 | 候选但本次未改（命令级、收益有限，见 §8） |

## 7. 验证

### 7.1 逐文件语法解析（全 PASS）

```bash
$ .gather/swift62/usr/bin/swiftc -parse -enable-bare-slash-regex <7 changed files>
PARSE PASS=7 FAIL=0
```

### 7.2 Linux 类型检查（GatherProtocol；本轮改动不在 Protocol，仍按门禁要求跑）

```bash
$ export HOME=$PWD/.gather/home PATH=$PWD/.gather/swift62/usr/bin:$PATH
$ swift build --package-path desktop/native/gather-core --target GatherProtocol
Build of target: 'GatherProtocol' complete! (0.47s)   BUILD_EXIT=0
```

**Linux 验证上限（实测）**：`--target GatherPersistence` → `error: no such module 'os'`；
`--target GatherAnalysis/Application` → `error: no such module 'CoreGraphics'`。因此
Application/MetadataIO 的改动只有语法解析 + 门禁验证，最终类型检查需 macOS CI。

### 7.3 仓库门禁（全部 PASS）

| 门禁 | 结果 |
|---|---|
| `./scripts/check-protocol-surface.sh --strict` | **PASS**（新增符号均 internal/private） |
| `./scripts/check-cleanup-ratchet.sh` | **PASS**：unchecked_sendable 60=60、try_optional 257≤260（净 −3）、nonisolated_unsafe 7=7、其余 0 |
| `./scripts/check-layering.sh` | **PASS** |
| `./scripts/check-select-star.sh --strict` | **PASS** |
| `./scripts/check-coded-errors.sh` | **PASS** |

## 8. 排序后的剩余建议

1. **（中）macOS CI 首跑关注点**：`Synchronization.Mutex`（NavigationService/MetadataIO）与
   实例/静态共享 JSON coder（QualityService/ModelReviewService/LibraryPackageService）的
   并发契约：前者是 stdlib 锁盒子（Linux 已编译运行验证同形代码），后者依赖 Foundation
   `JSONEncoder/JSONDecoder: Sendable` 标注（与 round-1 已提交的 `JSONValueCoding`/
   `RepoJSONCoding` 同一前提）；若 macOS 编译器有异议，回退方式是「每批/每次调用内局部
   coder」而不改语义。
2. **（中）schema 微优化（下次 user_version 迁移一次做完）**：
   `triage_suggestions(session_id, photo_id)` 覆盖索引（当前计划 `USE TEMP B-TREE FOR ORDER BY`）；
   视需要补 `session_assets(display_file_id)`；同步 `expectedExplicitIndexCount`/形态指纹。
3. **（低）外部元数据迁移命令**：`ExternalMetadataMigrationService.decodeKeywords` 可仿 §6.1
   改为共享 decoder（命令级冷路径，收益有限）。
4. **（低）`photo.list_page` 的 DISTINCT+ORDER BY 临时 B 树**：进一步优化应走
   `PhotoRepo.getAssetPage` 的游标分页（已有实现），不建议为此加索引。
5. **（信息）round-1 总览的 FK 数字**：见 §5.1，建议更正为「1 个且无查询使用」。

## 9. 改动文件清单（7）

```text
desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Commands.swift   +48 / -4
desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/LibraryPackageService.swift +20 / -5
desktop/native/gather-core/Sources/GatherApplication/Services/NavigationService.swift               +40 / -15
desktop/native/gather-core/Sources/GatherApplication/Services/QualityService.swift                    +5 / -1
desktop/native/gather-core/Sources/GatherApplication/Services/ModelReview/ModelReviewService.swift   +11 / -7
desktop/native/gather-core/Sources/GatherMetadataIO/SidecarXMPProvider+IPTCReading.swift             +52 / -10
desktop/native/gather-core/Sources/GatherMetadataIO/SidecarXMPProvider+IPTC.swift                  +18 / -9
合计 7 files, +194 / -51
```

未触碰：`Sources/GatherSchema/**`、`Tests/**`、`Package.swift`、任何 peers 的 UI 改动。
证据脚本（gitignored）：`.gather/tmp/r2/{probe,exhaustive,regex_probe,mutex}.swift`、
`.gather/tmp/r2/query_plans.py`。

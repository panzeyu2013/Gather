# Gather 功能设计评审 · 收敛台账

> 本文是「7 域功能设计评审（7 个只读子代理 + 编排者复核）→ 全量重写 → 无用代码深度清理 → 文档与测试精简」的**收敛版**：只保留当前仍然有效的结论、不可再删清单与未决项。
> 过程记录（原 §一–§八 逐域静态分析、§九·一–九·六 逐轮修复台账，以及已归档的 `docs/ARCHITECTURE-AUDIT.md` 结构审计与 `docs/ARCHITECTURE-REFACTOR-PLAN.md` 重写计划）可在 git 历史中查阅。

---

## 一、当前验收基线（2026-09-28 实测）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| core 构建 | `swift build --package-path desktop/native/gather-core` | 0 error |
| core 测试 | `swift test --package-path desktop/native/gather-core` | **795 tests / 112 suites 通过**（约 3.5s；6 条 VectorIndex 对账用例受 `GATHER_RECONCILIATION_VECTOR=1` 门控默认跳过） |
| app 构建 | `swift build --package-path desktop/native/gather-app` | 0 error |
| app 测试 | `CLANG_MODULE_CACHE_PATH=… swift test --package-path desktop/native/gather-app` | **173 tests / 20 suites 通过**（约 0.5s） |
| 命令面门禁 | `./scripts/check-command-surface.sh` | exit 0：118/118 注册、异步 36、双注册 0、确认载荷 7 处均伴随真实弹窗 |
| 遗留边界门禁 | `./scripts/check-no-legacy.sh` | exit 0：4 条强制规则 + 8 项跟踪指标 |

## 二、评审与修复摘要（按域，一条一件）

| 域 | 关键结论与落地 |
| --- | --- |
| 元数据写回内核 | 命名空间注入改为按**替换后文档** + 作用域栈注入缺失声明，写盘前 `assertNamespacePrefixes` 强制；`transition()` 成为唯一状态迁移入口；双会话 `confirmSync` 抛 `XMP_CONFIRM_OTHER_SESSION_PENDING` 并指名阻塞会话；provider `restore` 改拷贝语义；`finalizeSessionReporting` 返回真实计数。 |
| 存储 / 索引 / 迁移 | 迁移合并改为**运行时枚举**引用 `photos.id` 的 JSON/文本列（默认重写，4 列显式豁免）；`PhotoRepo.preferredRowOrderSQL(alias:)` 是代表行唯一规则；`AssetRepo.rawExtensions` 是 RAW 扩展名唯一真相源；`sessions.analysis_status` **删列**，状态完全由 `analysis_jobs` 派生。 |
| 相似度 / 重复 | `recluster` **job 化**（与 analyze 互斥、进度/取消、提交前取消零落库）；结果与簇状态单事务原子写；阈值档**单趟**（基准 2k 3.13×、20k 2.84×，逐档结果 identical）；`has_duplicates` 判据改为"组内仍有未决策成员"；`dup.scan` 阈值校验为 `0...64` 整数。 |
| 人脸 / 人物关键词 | `FaceRepo` 全量重写：计数唯一真相 = 实时 `COUNT(face_cluster_members)`；失效唯一入口 `invalidateDerivedResults(sessionId:photoIds:)`；`FaceMatcher` + `person_embeddings` 端到端接线（含真实跨会话用例）；`eps` 语义冻结为"相似度下限，越大越严格"。 |
| 挑片 | 读路径全部改认 `photo_metadata_cache`（决策行镜像列永不读）；undo/redo 栈唯一规则；`reset` 单事务清决策+投影+历史；强解包 P1 消除（改分块 id 校验 + 类型化错误）；代表行同共享规则（JPEG 先入仍选 RAW）。 |
| 应用外壳 / UI | 三张任务文案表收敛为「码→key」+ `l()`（先本地化再插值）；导航单一表示；删除整树重建的根 `.id(languageVersion)`（只挂无状态子树）；破坏性操作确认载荷与真实弹窗一一对应。 |
| 任务 / 导出 / 质量 | 任务状态机硬化（租约丢失触发 signal、取消宽限期 + 强制终态、`stop()` 超时）；导出 `dedupeKey` 纳入 options/目标摘要；QualityService 批量游标；JobService 的 `print` 全部改 `GatherLogger`。 |

## 三、不可再删清单（"看起来无用但必须保留"）

| 对象 | 为什么必须保留 |
| --- | --- |
| `tests/fixtures/` | `.gitignore` 明确保留的**本地夹具**目录（ONNX 模型 + 人脸 RAW 照片），非垃圾。 |
| `Capture_One_Plugin_SDK_(Mac)_v1.0.1/` | `desktop/coplugin/Makefile` 的 `SDK_PATH`/`FRAMEWORK_PATH` 引用。 |
| `desktop/resources/Info.plist` | 被 `Package.swift` exclude，但 `desktop/native/build.sh` 会拷入 app bundle。 |
| `docs/fixtures/schema.snapshot.json` | `MigrationTests` 读取（schemaVersion 34 / 43 表；v34 加 face_observations 质量列）。 |
| `Protocol/*.swift` 约 112 个 `*Params/*Result/Data` 结构体 | Codable IPC 契约基线，生产用 `[String: JSONValue]` 动态分发，无直接引用不等于无用。 |
| `CaseIterable` 枚举的 `allCases` | 隐式引用。 |
| 全部协议 witness | AppKit 委托方法（`applicationDidFinishLaunching` 等）、`XMPProvider`/`MetadataSyncPort`/`CullingSyncPort`/`FaceWritebackProvider` 等实现，均经协议调用。 |
| `HelperProtocol.handleLine`、`CosineHnswIndex.searchTopK`、`DBConnection.reopen` | 分别被 helper 可执行、Benchmarks、`Migrations` 调用。 |
| `applySyncSummaryForTesting` | app 侧测试钩子。 |
| `ImageCache.swift` 的 `SHA256`/`UInt64.bigEndianBytes` | 写回/指纹/索引生产在用（文件里其余 `ImageCache` 类已删）。 |
| `CaptureOneSessionState`/`aggregateSessionState` | `SimilarityViewModel` 生产在用（同文件其余类/协议已删）。 |
| 1176 处 `// TS:` 溯源注释 + 158 处历史措辞注释 | 编码"旧契约对应关系"与防回归决策；批量删除会丢失对账依据。 |

## 四、已知限制与残余风险

1. 写回内核之外仍有 **~11 处裸 `TSPath.xmpSidecarPath(...)`**（AssetRepo 5、WritebackService 2、CullingService 2 等），依赖内核入口归一扫尾。
2. `MetadataWritebackFailure` **尚未接 UI 报告卡**（用户看不到失败明细）。
3. app 侧**无"真实路由 × 全 118 命令"运行时契约测试**：门禁只做静态覆盖（同步/异步错配、确认载荷）；`StubCommandRouter` 是 35 行测试替身。
4. 多进程并发写、符号链接目录、APFS 大小写敏感性**仅静态核对**（`lstat` 不递归）。
5. Gallery **无法显示星级/色标**：`photo.list_page` 行不含该字段，扩 payload 需单独决策。
6. en 缺翻译 **26 条**（集中在 `LibraryView`、`ExportView`、`GatherAppDelegate`、`GatherApp`）。
7. `SettingsView` 的模型下载入口与 ADR-026 的现状描述仍不一致。
8. `VectorIndexReconciliationTests`（6 条，3.6MB 夹具）默认跳过，仅在 CI 的 `GATHER_RECONCILIATION_VECTOR=1` 门控步骤运行。

## 五、未决项与技术债（建议单独立项）

1. **重复实现去重**：core 有 6 份字节级同构的并发游标类 `BatchCursor`（MetadataSyncCoordinator / IndexerService / QualityService / DuplicateService / WritebackService / MetadataService，约 138 行）；app 有 8 组重复函数（`isDirectoryURL`×3、`finderURL`×3、`documentProbeScript`×2、`parseISO8601`×2、`scheduleEventRefresh`×2、`removeKeyDownMonitor`×2、`resetTransform`×2、`reportCancellation`×2）。
2. **Schema 单源化**：迁移只保留转换逻辑、DDL 统一引用 `SchemaSQL`；快照测试升级为列/类型/默认值/FK/索引级。
3. **公共基础设施抽取**：`BatchRunner`（取消传播 + 保序）、`Cursor`、`JSONColumn`、`TimeFormat`、`SHA256.hex`、`PaginationFooter`、`GatherErrorBanner`、`LoadStateView`、`WindowKeyMonitor`、`Debouncer`、`CaptureOneColorLabel`。
4. **查询性能**：`filterGlobally` 避免 `SCAN pmc`、候选对账预聚合 + 双索引、`DBStatement` LRU 缓存、事务内移除文件 IO、`sha256` 改流式。
5. **早期 P2 遗留**（来自已归档审计）：导航拆分、~120 处裸 SQL、CI 基准冒烟。
6. **测试侧**：`MetadataCacheRepoTests.getBatchEmptyAndChunked` 的 810 次 upsert 可包进 `db.transaction {}`（约 2s CPU）；跨用例共享"已迁移 DB 模板"可省约 8s CPU，但会改变隔离语义，收益不足 1s 墙钟，暂不做。

## 六、文档与测试精简记录（2026-09-28）

- **文档**：2805 行 → **1380 行（−51%）**。删除两份已被修复推翻的历史文档（`ARCHITECTURE-AUDIT.md` 764 行、`ARCHITECTURE-REFACTOR-PLAN.md` 285 行）；`ADR.md` 补齐现状并新增 **ADR-028**（未接线资产删除裁决）；`DEVELOPMENT.md` 成为构建/门禁/命令面唯一真相源；`README`、`docs/README`、`ROADMAP` 只保留入口与两态台账。
- **测试**：core 797→**795** 条、墙钟 **25.6s → 3.5s**（真凶是 `IncrementalClustererTests` 一条 2 万张的 O(n²) 遍历，占 95%：改为 2 千张下采样，仍走同一条 bitset 路径、断言全保留）；app 198→**173** 条、墙钟 **5.2s → 0.5s**（`GatherToastCenter` 的 5s 自动消失时长改为**可注入**，生产默认值不变并有显式断言；测试侧 53 处 `Task.sleep` 归零，改条件等待）。
- **测试质量修复**（顺带发现）：补上"取消后进度不得推进"这一类原本**空断言**的竞态检查；修掉一条**不可能失败**的用例（未播种档位）；给依赖调度顺序的 toast 套件加 `.serialized`；`SimilarityServiceTests` 5 处 `runRow(...)!` 强解包改 `try #require`（原会在失败时 fatal 而非断言失败）。

## 七、语义级深度分析（第二轮，5 个领域代理）

**方法**：按域派出 5 个语义分析代理，要求"读全实现与调用链 + 对每个等价/冗余/不可达断言给出**可执行证明**（探针测试 / 真实 schema / EQP 执行计划）"，**禁止只做引用计数式静态扫描**。临时探针一律 `ZZ` 前缀且用后删除（收尾检查残留 = 0）。

### 7.1 挖出的真实缺陷（非风格问题）

| # | 缺陷 | 证明 | 修复 |
| --- | --- | --- | --- |
| 1 | **并发收集内存损坏（P0）**：`batchAsync` 并发执行非 Sendable body，而 `MetadataService.getMetadata`/`batchSet`、`WritebackService.execute` Phase1 直接改 `Dictionary`/数组 → SIGSEGV 或**静默丢项** | 探针 96/64 项可复现 SIGSEGV（backtrace 命中 `Dictionary.setValue`/`Array.append`，来自 `BatchRunner`），另一轮 `totalAffected ≠ 64` | 临界区内串行收集（无 await）；4 连跑通过 + **TSan 0 warning**；新增并发回归套件 |
| 2 | **内嵌关键词损坏（P0）**：`rdf:Bag` 元素实为 `CGImageMetadataTag`，旧代码走 `String(describing:)` 兜底 → 写出 `"Optional(<CGImageMetadataTag 0x…>)"` 伪关键词进入缓存/写回/UI | 真实 JPEG 探针：修复前 derived 为伪值，修复后 `["alpha","beta"]` | `json()` 递归解包 tag + `stringList()`；真实 JPEG 回归用例 |
| 3 | **导出用了第 4 份漂移的 RAW 清单**：漏 `.eip/.mef/.kdc/.mrw/.erf`，多出 `.gpr/.raw/.rwl/.sr2`（后者还不在解码器能力表内 → 非 original 导出必失败） | 探针 18 组边界 **6 处分歧** → 修复后 **0 分歧** | 改用唯一真相源 `AssetRepo.rawExtensions` |
| 4 | **导出顺序不确定**：变体分组走 `Dictionary.values`，进程哈希种子不同则顺序不同，`{counter}` 命名随之变化 | 探针 24 张/12 组：修复前 `["o-11b","o-2b",…]`，修复后 = 资产导入序 | 显式"资产首见序"数组 |
| 5 | **错误码被丢成通用文案**：Gallery/Persons 的错误漏斗对 `NativeCommandError`/`BridgeError` 走 NSError 桥接 → 丢码（可达：`person.get` 缺行 → `PERSON_NOT_FOUND` 显示通用文案）；Library 的门槛把 `CODE: param` 判为非码 → 丢参数化模板 | 差分测试证明"旧漏斗恒为通用文案、新漏斗等于映射文案"；探针实测 `errorText("…: s1")` 含 `s1` | 收敛到 `userFacingMessage(for:)` 单漏斗 + `isParameterizedErrorCode`；断言改为**正确码文案**（非放宽） |
| 6 | **既有测试 flake**：切语言用例跨套件并行时与本地化断言竞争 | 复现到 4 个套件间歇失败 | 新增 `AppLanguageLock`（只加锁、断言不动） |

### 7.2 语义等价的合并（删重复实现）

- **`BatchCursor` 6 份 → 1 份**（`Concurrent/BatchCursor.swift`）：先读全部调用点确认"失败即停"语义一致，唯一真实差异（`@unchecked Sendable` 标注 3 有 3 无）统一；删 144 行；新增 4 条并发用例。
- **`batchAsync`/`mapConcurrent` 6 份 → 1 份**（`Concurrent/BatchRunner.swift`）：归一化 diff 仅函数名与 `sort{}.map`/`sorted{}.map`（索引唯一 → 全序，等价）；12 个调用点的并发上限（16/10/…/2）与错误策略作为参数表写入文档注释；删约 200 行；新增 5 条用例；门禁指标 `batchAsync copies` 4 → 1（仅剩共享实现）。
- **仓储层单一真相源**：`nowISO`×7 / `newUUID`×4 / ISO8601 解析×2 → `RepositorySupport`（35 万日期样本 0 差异）；AssetRepo 换路径 SQL×3 → 1；`addPhotos` 删掉多余"先查后插"（唯一索引已强制）；活跃 job 状态字面量**刻意不并入 Swift**（EQP 证明改序即丢 `idx_analysis_jobs_active_dedupe`），改为单一 SQL 常量 + 索引回归测试。
- **写回/元数据**：标签集与可写字段集改为由协议枚举派生（`CaptureOneColorLabel`/`MetadataField.writableNames`）；`normalizeKeywords` 双重载合一；Phase2 失败由散文改结构化码。
- **相似度/重复**：`0...64` 阈值校验两处 → `DHash.isValidThreshold`（布尔恒等证明）。
- **app**：`reportCancellation`×4 → `cancellationNotice`（状态面保留在调用点）；`LoadPhase`×4 → 单一类型；URL/日期辅助各 3 处与 2 处 → `URLHelpers`/`DateFormatting`；`SettingsView.parseISO8601` 第 3 份消除。

### 7.3 经证明"看似重复、语义不同"而**刻意不合并**（防错误抽象）

代表行规则（SQL vs CullingService 内存实现）：18 组边界矩阵下 SQL 直算 / `list` / `listPage(.all/.filtered)` / `filterGlobally` **五路全等**；两处"可疑分歧"（`asset_id=''`、隐藏名 `.nef`）经运行时证伪为不可达 → 保留双形态。其余：`RAWDecoder.supportedExtensions`（解码能力）≠ `AssetRepo.rawExtensions`（相机 RAW 分类）；导出 `.preferred`（RAW>JPEG>首个）≠ 代表行（RAW>最小 rowid）；`PhotoAssets.extensionName` ≠ `TSPath.extname`（Node 语义）；质量排名"本次结果集内"≠"会话内全部结果"；`normalizeKeywordList` ≠ `normalizeKeywords`；`outbox` ≠ `writeback_items`；两处 `indexHeaderCopy`；**C1 同步状态机分歧**（见下）。

### 7.4 已知语义分歧与遗留（报告，未改）

1. **C1 同步态两处推导**：core `aggregateSessionState`（终态行须 `reloadAckedAt` 才 `safeToCleanup`）vs `CullingViewModel.syncFlowState`（`synced>0` 即 safe，忽略 ack）。差异可达（`clearReloadAck` 置 NULL 而 synced 行仍在）→ Culling 页会提前启用"确认同步/清理"；**不丢数据**（命令层 `requireReloadAck` 抛 `XMP_RELOAD_NOT_ACKED`）。收敛需独立变更 + 更新 `CullingSyncFlowTests` 矩阵。
2. **写后不读（建议停写、不删列）**：`face_clusters.member_count`（读点皆实时 COUNT）、`metadata_outbox.owner_session_id`/`created_by_session_id` 及 owner 两索引、`assets.status`/`capture_fingerprint`（assets 只有 DELETE）、`asset_backfill_state` 除 `last_photo_rowid` 外 8 列、`person_embeddings.quality/face_bbox/created_at`、`face_observations.source_file_size/_mtime_ms/analysis_signature`、`writeback_items.backup_path`（真备份在 outbox）、`photos.metadata/result` 恒写 `'{}'`、**`asset_file_metadata` 整表 0 引用**。
3. **无生产者的错误码/分支**：`MetadataContractError.{keywordsInvalid, patchInvalid, unsupportedSource}`、`MetadataMutationError.unsupportedField`、FKW `keywordsOpInvalid`（编译器 `default will never be executed` 佐证）；`mergePatch` 的 CASE 可把遗留 `clean/cleaned` 改写成 `pending` 绕过 `canTransition`（仓储层待收敛）。
4. **路径口径**：`WritebackService.preview/batchSet` 兜底、app `SidecarXMPProvider.resolveSidecarPath` 未走 `ScanPath.canonical`（当前可达输入等价，建议防御性统一）。
5. **`FaceVector` 无生产消费者**（仅对账测试用），与 `vectorDot/verifyCandidates` 契约不同（长度截断 vs 等长；零幅值返回 0 vs 跳过候选）→ 删/并需同时改对账断言，待裁决。

### 7.5 本轮后的验证基线（2026-09-28）

core **818 tests / 117 suites**（约 1.8s）、app **185 tests / 21 suites**（约 0.28s）、两包 `swift build` 0 error、两条门禁 exit 0。

## 八、测试用例语义分析（第三轮，4 个变异测试代理）

**方法**：不数用例、不读注释，而是**变异测试**——在生产代码里精确改坏一处（错误码/事务边界/状态迁移条件/判等规则/排序规则/取消与超时/路径规范化/边界比较符/守卫取反），跑定向套件，记录"谁杀了它"，随后**立即还原并核对文件哈希**。**没有任何用例失败 = 未守住的契约（SURVIVED）**，必须补一条能真红的用例（用独立 oracle：手算期望/不变量，而不是调用被测实现自己算）。同时体检测试替身保真度、确定性与覆盖空洞。

**规模**：4 域共 **88 个变异点**；约 **44 条新用例**（每条都自证"生产改坏→新用例变红"）；生产代码哈希全部还原一致（30/30、16/16、24/24、41/41）。

### 8.1 变异测试直接挖出的生产缺陷（用户可见）

| 缺陷 | 语义根因 | 后果 | 修复 |
| --- | --- | --- | --- |
| `SimilarityDataProvider.syncStateItems` | 方法**只在协议扩展里定义、未声明为 requirement**；ViewModel 持有 existential → 调用永远静态分发到扩展默认 `[]` | Live 实现成死代码：`syncView` 恒 `.synced`、`written` 恒 0 → **相似度页 C1 同步面板（加载元数据/确认同步/清理）永久全禁用** | 声明为 requirement（一行）+ 回归用例转严格断言 |
| `GalleryDataProvider.thumbnailSize` | 同一类缺陷（extension-only + existential 调用） | Live 实现成死代码：**用户的缩略图尺寸设置永不生效**（恒 1024） | 同上 |

> 这类缺陷**只有"替身体检 + 变异"能发现**：单测里 stub 覆写了方法但从不被调用（静态分发到默认实现），表面覆盖良好。两处修复后 app 套件从 "193/22 **with 7 known issues**" 变为 "193/22 **0 known issues**"。

### 8.2 被变异证明"零覆盖/弱覆盖"并已修补的用例

- **拿被测实现当 oracle**：2 处路径规范化用例用 `TSPath.xmpSidecarPath(ScanPath.canonical(…))` 当期望值（= 复述实现），变异下仍绿 → 改为手算期望（`/v/deep/IMG_9.xmp`、`/private/tmp`→`/tmp`、`./..` 折叠）。
- **弱断言**：`newestCandidateAcrossChunkBoundary` 只有 1 个合格候选（"最新"与"首个"不可区分）；`betweenProducesTwoParams` 只数参数个数（两参同值仍绿）；`edgesAndExposure` 只断言 `sharpness>0`；`frames.count<=8` 在节流被删时仍绿 → 全部加强为精确值/边界。
- **注释声称的覆盖并不存在**：`heartbeatSqlErrorDoesNotAbortOrCancelJob` 自称覆盖"≥3 次抛错读回"，把阈值改成 1 仍绿 → 已补强（读回确认因无注入缝暂不守，已记录）。

### 8.3 测试替身保真度（"比真实实现更宽松"的替身会掩盖真缺陷）

| 替身 | 宽松点 | 掩盖的缺陷 | 处置 |
| --- | --- | --- | --- |
| `StubSimilarityProvider` | 未覆写 `syncStateItems` | 8.1 的 P0（协议 requirement 缺失） | 已修 + 用例转严格 |
| `IndexerServiceTests.getSetting` | 未知键 identity 返回默认值 | 设置键名写错/默认值改错全绿（M2/M3 证明） | 补 `settingsKeysAndDefaultsArePinned` 钉死 (key, default) |
| `StubMutationPort.queueMutation` | "成功但什么都不写" | 撤销/写回丢失 | 改为显式抛错 |
| `FakeFSXMPProvider.backup/restore` | 无侧车仍返回备份路径；备份缺失静默删侧车 | 与真实 `SidecarXMPProvider` 语义不符 | 对齐真实（返回 `""`／抛 `backupMissing`） |
| `StubCommandRouter` / `RecordingCommandRouter` | 恒 `ok`、忽略 params | 命令失败路径、FaceKw 错误路径 | 已记录；失败路径由 Failing/EmptyData router 部分覆盖 |

### 8.4 新增的契约护栏

- **`GatherErrorCode` 完整清单契约**（`Protocol/ErrorCodeContractTests.swift`）：173 个码的完整钉死清单 + 唯一性/大写/非空断言。此前只钉"数量 + 4 个 spot"，**任取一个码改名没有任何用例会失败**（T3 实测 SURVIVED）——错误码是跨进程契约，改名即破坏兼容。
- **错误码 ↔ 本地化交叉契约**（app 侧 `ErrorLocalizationCoverageTests.swift`）：① 每个码都必须有文案（否则 `errorText` 落通用兜底"发生未知错误"）；② 文案表不得含枚举外的码（防生产者在枚举外自造裸字符串）。**该护栏当场抓出 2 例**：`C1_SCRIPT_TIMEOUT`（`CaptureOneBridge` 里是裸字符串）、`C1_NO_SELECTED_PHOTOS`（`GatherAppDelegate` 通知载荷）——已收进枚举，生产者改取 `rawValue`。
- **命令面运行时契约**（app 侧 `CommandSurfaceRuntimeTests.swift`）：用真实 `SessionCommandRouter`（`:memory:` 库 + 迁移 + `makeDefault`）逐条派发冻结清单，断言"被识别"（非 `notImplemented`）并带伪造命令对照组；82 同步 + 36 异步由机械扫描得出（不相交、并集 118）。结果 **118/118 被识别，0 超时 / 0 崩溃 / 0 非 BridgeError**（68 业务错误 + 36 异步 ok:false + 14 只读 no-op），对照组灵敏。
  该测试还抓出 2 处"文案当错误码"（`filter.*` 的 `Filter criteria is invalid`、`album.delete requires confirmation`）——这类裸英文串会让 UI 显示"发生未知错误，请稍后重试"，用户**完全看不到真实原因**；已改为新增结构化码 `FILTER_CRITERIA_INVALID` / `ALBUM_DELETE_CONFIRM_REQUIRED`（含中英双语文案与桥接 `BridgeError.coded`）。
- 各域新增的 44 条用例覆盖了：JobService 权重预算/取消幂等/跨进程取消/停止终态/进度节流/租约恢复；Culling 分页边界不重复、写回关键词去重；Indexer 预热 id、canonical 折叠、禁根祖先；导航与 TTL 边界；写回 mergePatch 的 synced/conflict/legacy 迁移、claim 重试、按侧车去重、GPS 符号与曝光边界、缓存新鲜度判据、损坏侧车守卫；导出 `status != 'removed'` 过滤与 `.all` 策略；质量指纹缓存失效、平局保序；相似度外部取消不落库、全解码失败抛 `SIM_NO_HASH_DATA`。

### 8.5 确定性修复

- app 侧 5 个套件（WorkspaceStageMarks/InboxItems/C1Preflight/Dashboard/Library）文案断言加 `withCopy("zh-CN")`，`IndexHeaderCopy` 两套件改 `withCopy`：实验（临时"持 en 2s"）证明原锁只护参与者，其余套件在切语言窗口内会红。
- 夹具期望改用 `ScanPath.canonical(dir)` 而非 `/var` 原始拼写（不再依赖符号链接拼写）。

### 8.6 覆盖空洞与处置

1. ~~118 命令无运行时派发测试~~ → **已补**（见 8.4，118/118 被识别）。残留：当前只验"命令被识别"，尚未逐条验"给定真实数据时的结果形状"；只读 no-op 的 14 条是低价值重复覆盖。

2. **零覆盖的生产方法**：`MetadataService.setMetadata`（含 `unsupportedFields` 错误码）、`WritebackService.removeOwnedFaceKeywords`、`updateLocalProjection` 的 face_kw 归属、`coordinator.resolveOrphan`/`finalizeSessionReporting`。
3. ~~门控测试的盲区~~ → 门控对账消费的死码已删除（见 8.8）；检索热路径的内联数学由该文件其余 5 条对账用例覆盖（门控开启实测 5/5 通过）。
4. ~~`FaceVector.dot/cosineSimilarity` 死码~~ → **已删除**（见 8.8）。
5. ~~`scanIsSingleFlight` 挂起~~ → **已改有界等待**并变异自证（见 8.8）。

### 8.7 本轮后的验证基线（2026-09-28）

core **855 tests / 119 suites**（约 1.9s）、app **199 tests / 24 suites**（约 0.27s，**0 known issues**）、两包 `swift build` 0 error、两条门禁 exit 0；临时探针与 `withKnownIssue` 包装均为 0。工作区含新文件待提交（`Concurrent/`、`RepositorySupportTests`、`URLHelpers`、`DateFormatting`、`LoadPhase`、`AppLanguageLock`、`AsyncWait`、`PersonsViewModelTests`、`ImageMetadataProviders` 等）。

### 8.8 追加清理（本轮收尾，均带变异/门控自证）

- **删除 `FaceVector.dot` / `cosineSimilarity(to:)`（约 60 行）**：无任何生产消费者，只被默认跳过的对账用例断言；生产检索在连续缓冲上按偏移内联同一数学（抽公共函数会让**每个候选分配一次数组**，不能合并）。同时删掉只测该死 API 的 `faceVectorDotAndCosine` 用例，并在热循环处注明语义差异（长度固定 `dim` 不截断、零幅值候选 `continue` 跳过）。门控开启复核 `VectorIndexReconciliationTests` 5/5 通过。
- **`scanIsSingleFlight` 改有界等待**：单飞守卫的失败模式是"阻塞"而非"抛错"——原用例在单飞键被改坏时**永久挂起**（实测拖死整包，无诊断价值）。改为 continuation 竞速：**不能用 `withTaskGroup`**（结构化作用域返回时要等全部子任务，被取消的等待子任务仍阻塞在 `Task.value` 上，实测同样挂起，已复现）。变异自证：单飞键忽略阈值 → **3.05s 失败**并输出"超时 = 单飞键忽略阈值"，哈希还原。

## 九、事故记录：一次未提交文件的误还原（2026-09-28）

- **经过**：为 `scanIsSingleFlight` 做变异自证时，用 `git checkout -- <file>` 还原变异。该命令恢复到 **HEAD**，而本会话全部改动**尚未提交**——`DuplicateService.swift` 的会话版（含"重扫时按 `photo_id` 存续裁决"、`Double` 阈值校验与结构化码、已删除的局部 `batchAsync` 副本）被一并抹掉；`swift build` 随即报 `invalid redeclaration of 'BatchCursor'`（还原把已合并的局部副本带回来了）。
- **恢复**：`/private/tmp/t2_backup_Sources_GatherCore_Services_DuplicateService.swift`（T2 代理做变异前留的备份）即会话版（812 行：含 `validateDuplicateThreshold`、`case thresholdInvalid`、16 处"决策存续"逻辑，且无局部并发副本）。恢复后 core 0 error、**855 tests 全绿**。完整性核对：同批备份的 `ExportService.swift`/`PhotoRepo.swift`/`Matcher.swift` 与工作区**逐字节一致**；`VectorIndex.swift` 仅差本轮有意删除的死 API。
- **教训与规定**：
  1. 变异/实验的还原**必须用实验前的 `cp` 备份**；本仓工作区即交付物且大量改动未提交，**禁止用 `git checkout`/`git restore` 还原**。
  2. 还原后必须**比对哈希**（本次若不比哈希就不会发现差异）。
  3. agents 的"改前 `shasum` + `cp` 备份"自证流程是有效安全网——本次正是靠代理留下的备份救回。
  4. macOS **没有 `timeout` 命令**：变异自证用工具侧超时或有界等待，别用 `timeout N cmd`（会静默不执行）。
  5. 生产文件的临时改动须落在 `/private/tmp/<name>.<purpose>.bak`，并在报告里给出"改前/改后哈希一致"的证据。

---

## 十、配套评审文档（2026-09-28 续）

| 文档 | 内容 | 来源 |
| --- | --- | --- |
| [ux-review.md](ux-review.md) | 用户视角体验评审：主线旅程摩擦、功能完整度矩阵、交互/信息架构/状态设计/无障碍/规模性能、P0–P2 修复清单、"值得学的产品模式" | 4 个只读审查代理（挑片浏览 / 相似重复 / 库人物人脸 / 外壳设置导出） |
| [face-clustering-benchmark.md](face-clustering-benchmark.md) | 人脸识别与聚类对标：本仓 as-is、Immich/PhotoPrism/digiKam 技术对照、聚类质量与参数治理、**数据去向（是否污染原文件）**、10 项可学项与 5 项不建议照抄 | 1 个本仓只读盘点 + 2 个竞品调研（官方文档/源码/issue，均附 URL） |

**两条最关键的跨文档结论**

1. **算法代差**：本仓人脸管线**无关键点对齐**，嵌入用**通用图像特征**（Vision `VNGenerateImageFeaturePrint` rev2，实测 768 维、契约 512），而 Immich（ArcFace 512）与 PhotoPrism（SFace 128）都先做 5 点对齐到 112×112；质量筛选、模型版本治理、增量聚类亦缺。工程骨架（表/状态机/写回影响面预览/断点恢复）不弱于竞品，差在算法核心。
2. **体验上的三类系统性缺陷**：①承诺与实现脱节（⌘Z 无人 `post`、文案称可拆分但无 `fkw.split`、设置提示打内部 key）；②批量与规模不成立（重复页 230 组 ≈ 690 次点击；人脸簇成员被后端硬截断为前 4 ⇒ 误聚类不可修；万张库筛选链式拉满整库）；③失败与回滚无回路（取消后服务端槽位仍占用、写回回滚被"先同步"顺序锁死、初始化失败只进 stdout）。

## 十一、Swift 6 迁移（2026-09-28 完成 core；app 同波次）

**目标**：两个包都切到 `swift-tools-version: 6.0` + `.swiftLanguageMode(.v6)`（此前均为 5.9 默认 v5 模式）。

| 阶段 | 内容 | 结果 |
| --- | --- | --- |
| 1. 锁波次 | `async` 上下文里直接 `NSLock.lock()/unlock()`（v5 下仅警告）→ 临界区抽成 `private func xxxLocked(...)` 同步辅助；先例 `DuplicateService.beginScan/endScan` + `ScanSlotDecision` | MetadataService 6 处、JobService 2 处、IndexerService 2 处、MetadataSyncCoordinator 3 处、WritebackService 3 处、QualityService 1 处（`AnalyzeProgressCounter`） |
| 2. Sendable/region 波次 | `batchAsync` 加 `<T: Sendable, R: Sendable>` + `body: @Sendable`；服务类按"锁保护"标注；continuation 载荷去 `Any?`（新 `JobResultValue` 不可变盒子） | BatchRunner、JobService、IndexerService、DuplicateService、SimilarityService、QualityService、MetadataService、WritebackService 等 10 源文件 + 7 测试文件 |
| 3. app 全局可变状态 | `static var appLanguage`、`CaptureOneBridge.shared` → 锁盒子 + 计算属性（公开 API 不变） | `GatherLocalization.swift`、`CaptureOneBridge.swift` |
| 4. app provider 协议 | `@MainActor` ViewModel 持有的 provider existential 在 async 调用中被"发送" → 协议加 `: Sendable`，实现按 let/锁依据处理 | 5 个 protocol + Live 实现 + 测试替身（进行中） |

**core 验收**：`swift build` **0 error / 0 warning**；`swift test` → `855 tests / 119 suites passed（~2s）`。

**新增 `@unchecked Sendable` 清单（信任锁纪律或不可变性，编译器不可验证——日后改动须重审）**
- 有锁：`JobAbortSignal`、`JobRunContext`、`JobService`、`DuplicateService`、`IndexerService`（`seamLock`）、`WalkChannel`、`MetadataCollector`、`BatchSetCollector`、`PhaseOneCollector`、测试侧 `AsyncGate`/`ProgressRecorder`/`BoolBox`/`OrderBox`/`ImageCallBox`。
- **无锁**（依据"当前零可变状态"，加 `var` 即失效）：`QualityService`、`MetadataService`、`WritebackService`、`Registration`（全 `let`）、`JobResultValue`（`Any?` 只读 + 由 `JobService.lock` 串行）。
- app 侧：`AppLanguageStorage`、`CaptureOneBridgeStorage`（各由 `NSLock` 保护单一字段）。
- 人脸模块（算法改造第二轮）：`CoreMLFaceEmbedder`（**无锁**——`spec` 是值类型、`MLModel` 加载后只读，每次 `embed` 新建 VNCoreMLRequest）、`FaceEmbeddingModelFactory.Cache`（**有锁**——NSLock 保护 providers 字典，模型加载刻意在锁外，代价是同键并发未命中可能重复加载一次）；测试侧 `FingerprintTestCounter`/`LockedCounter`/`VectorStore`/`PhaseCollector`/`IncrementalFaceHarness`/`MutableSettings`。

**遗留（低危）**：`IndexerService.stat/fileHasher` 热路径多一次无竞争锁；`batchAsync` 的 `body` 现为 `@Sendable`，新调用点捕获非 Sendable 状态会被编译器拒绝（这是期望行为，请用锁盒子）。

**既有告警（与本轮无关，冷编才可见）**：source 构建 0 error / 0 warning；`swift build --build-tests` 强制重编后有 **23 条 warning**，全部落在 10 个既有测试文件（`MetadataSyncCoordinatorTests` 5、`MetadataOutboxRepoTests` 4、`SessionServiceTests` 3、`MetadataWritebackStateMachineTests` 3、`JobServiceTests` 2、`CullingServiceTests` 2，其余各 1），类型是"未使用的返回值/未使用的局部变量/多余的 `try`"。本轮新增与改动的文件 **0 条**。清理它们是独立的小任务（机械改动），没有并入算法改造轮次。


## 十二、人脸算法改造第二轮：模型层 / 增量 / 试算 / 基线（2026-09-28）

第一轮把"接口留缝"当终点；第二轮把缝里的实现补齐，并按对抗审查修掉两轮共 4 个阻断项。逐项状态与诚实边界见 `docs/ADR.md` ADR-029 决策 7–11 与 `docs/reviews/face-clustering-benchmark.md` §6b。

**本轮验证（全量实跑）**

- core：`swift test --package-path desktop/native/gather-core` → **951 tests / 134 suites passed**（约 2.0–6.8s，视冷热）；`swift build` 0 error / 0 warning。
- app：`swift test --package-path desktop/native/gather-app` → **212 tests / 27 suites passed**（约 0.3s）。
- 门禁：`check-command-surface.sh`（118/118 = 82 sync + 36 async）与 `check-no-legacy.sh` 均通过。
- 真实素材：`GATHER_FACE_FIXTURE=<jpg> swift test --filter FaceRealPhotoPipelineTests` → 3/3（真实人像检测 + 5 点对齐 + 768 维单位向量 + 两次编码一致；编码失败计数）。默认跳过：本机测试进程无法从 Data 解 RAW。

**对抗审查修掉的阻断项（每条都有回归测试，且测试在旧实现上会失败）**

1. `.mlmodelc` 包内权重不进指纹（原地替换不改目录 mtime）→ 递归**全内容**指纹（分段链式 SHA-256）+ 递归 stat 缓存键；回归用**同尺寸**替换强制该路径。
2. 逐脸嵌入失败被吞 → 照片被当成"没有脸"（删旧观测、写 analysis_state 永不重试、重聚类连带清簇与人工绑定）→ `FaceEncodeBatch.encodeFailures` 上抛 + 服务层对"检测到脸但一张都没编码成功"的照片保留旧观测与旧状态、整批失败不清簇。
3. ARI 公式写错（0.7177 vs 真值 0.4040，且变化方向与真值相反）→ 两种等价实现互证 + 手算小例（4/9、−0.5）精确断言。
4. margin 结论来自测试内复刻 → 改为生产 `analyze` → `matched_person_id` 全路径（49 查询、6 人库）；出货默认 0.01：错绑 3→2、拦下 2 条歧义、同覆盖率精度 0.9655→1.0000。
5. 设置表被手改成 `NaN`/`inf` 时 `Int(getNumber(...))` 会 **trap 崩溃**（`Int(inf)` 不是抛错而是 SIGTRAP）→ `Double.safeInt(fallback:)` 统一兜底（13 处；正常值语义不变），纯函数边界 + 服务层"手改 inf 不崩"各有用例。
6. 第二轮对抗验证（V1）补的三个真实缺陷：①**部分失败漏保护**（1 成功 + 1 失败会写 analysis_state 且丢弃失败的脸 ⇒ 永不重试）→ 只要本次有编码失败就不写 state（部分结果仍落库）；②签名与推理由两次 `make` 解析，模型文件在两者之间被换会"用 A 的签名标注 B 的向量"→ 一次运行只创建**一个**嵌入实例，签名与推理同源；③`.DS_Store` 这类系统噪声会改变内容指纹 ⇒ 全库重算 → 指纹递归时跳过点开头文件。
7. V1 还指出多输出"恰好一个合法"会误杀带分类头的真实导出 → 保守地按名字排除 logits/softmax/fc 等分类头，排除后仍不唯一才报歧义（不含"指定输出名"设置项，属已知限制）。
8. V1 证明"错误可见性"第一版**没生效**：路由与设置页都改了，但分析页的显示层把非错误码文案一律回落"发生未知错误"（四类中文诊断全被吞）→ 显示路径改为三段判定（错误码→本地化模板；含中日韩字符→原样上屏；其余→通用文案 + 原文进 tooltip，不泄露英文散文）；同时把"保存即加载模型+整包哈希"（256 MiB 实测 48.4s，@MainActor 假死）降级为廉价校验（存在性/扩展名/软链/`~`），"能否真正加载"交给分析路径；`done + encodingFailures > 0` 不再显示"分析完成"，改为可见警示。

**测试基建（顺手加固）**：`GatherLocalization.appLanguage` 是进程级全局量，切语言的套件与"断言本地化文案"的套件并行时会产生间歇失败（实测到一次：`DashboardViewModelTests.loadFailureSetsFailedPhase`）。已把 6 个未加锁文件（Dashboard / Gallery / Persons / RootView / ErrorLocalizationCoverage / FaceReclusterConfirm）的 15 处文案断言放进既有的 `AppLanguageLock`（约定见 `Support/AppLanguageLock.swift`）；连跑两次全绿。

**明确降级的结论**（避免过度承诺）

- 干净集 = 生成器自检，不是性能证据；合成 embedding ≠ 真实识别精度；单 seed、观测 ≤64；子集试算会与全量分叉（试算计数只对传入观测集成立）；不得替代 Stretch 门与真实标注集复核。

**仍未做 / 已知边界**

- 簇的拆分/改派/隐藏状态：需要扩**冻结的**命令面（当前 118 条为门禁基线）；
- 参数试算接 UI：同样需要扩命令面或 app 内直调，且内核同步、2k 观测 debug 实测约 28.5s，接 UI 前必须后台化 + 可取消；
- `settings.get_ml_status` 展示当前嵌入模型：需要改 `MLStatusData` 协议形状；
- MWG-rs 区域导出（opt-in）；
- CoreML 真实推理路径 **0 覆盖**（仓库无 `.mlmodel`/`.mlmodelc` 夹具）：首次接入真实模型必须人工确认维度、归一化与输出名。

---

*本台账由编排者维护；完整过程记录见 git 历史中的本文早期版本与已归档的两份架构文档。*

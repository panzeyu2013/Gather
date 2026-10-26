# 清理与重构记录（2026-10-26）

> 授权：早期阶段，不再保持向后兼容/增量路径；删除死代码、补丁式兼容层与重复实现，收敛到单一当前实现。本文记录本轮实际删除/修复与验证结果。

## 0. 结论

本轮完成三项结构性收敛：**Schema 单一当前版本**（V1/V2 迁移链整链删除）、**分页单一 cursor**（nextRowId/afterRowId/pageFiltered/pageSimilarity 删除）与**Template 死功能整块删除**（7 文件 + workflow_templates 表），并修复第三轮审计的全部 5 个 P1，补 6 条回归。core/app 全量测试与 8 道 strict 门禁全绿。

| 指标 | 结果 |
|---|---|
| core | **1230 tests / 182 suites**（清理前 1277/188） |
| app | **683 tests / 77 suites** |
| Schema | 44 表 / 383 列 / 72 索引 / 65 外键 / user_version=3；<code>gather-schema verify</code> 通过 |
| 协议面 | 16 协议 / 112 方法；错误码 184（baseline 已收紧） |
| 门禁 | docs/layering/no-legacy/select-star/duplicate-symbols/design-system/cleanup-ratchet/protocol-surface 全绿 |

## 1. 删除的结构性兼容层

| 项 | 删除内容 | 替代 |
|---|---|---|
| Schema 迁移链 | SchemaCatalog / SchemaSnapshot / SchemaVersion / SchemaMigrator / SchemaBackup / MigrationV1ToV2 / MigrationV2ToV3 / SchemaMigration / HistoricalV1Shape / SchemaV2 / SchemaV3（11 文件） | <code>SchemaCurrent</code> 单一 DDL + 三态 open（empty/current/incompatible）；旧库默认 fail closed，显式 reset 才归档重建 |
| 迁移测试 | SchemaMigrationTests（1036 行）、MigrationTests（94 行）、SchemaV1Tests 重写为 SchemaCurrentTests | 44/383/72/65 + 指纹 + 逐表列数 + CHECK/FK 门禁 |
| Template 死功能 | Protocol/API/Inputs/Service/Repo/Port/Live（7 文件）、2 个测试文件、<code>workflow_templates</code> 表、4 个 TEMPLATE_* 错误码、Composition/AppServices/Root 注入 | 删除；协议面 17→16、121→115，错误码 204→200 |
| 死 API / 死错误码 | MetadataAPI get/set/batchSet（3 方法 + 3 输入类型 + Live/Preview/Stub 实现 + 4 条测试）；服务层 setMetadata/batchSet + BatchSetCollector/BatchFlushSessions/MetadataSetOutcome + BatchMetadataResult/MetadataBatchUpdate；16 个只在枚举/文案出现的错误码 | 协议面 115→112；错误码 200→184；MetadataService 1082→819 行；en 孤儿文案同步删除 |
| 死设置键（14） | onnx_provider、face_thumbnail_size/quality/dir、memory_cache_size/max_size_mb、disk_cache_max_size_gb/eviction、thumbnail_concurrency、c1_timeout_ms/retries/reload_delay_ms、metadata_write_debounce_ms、capture_one_color_compatibility | 默认表 63→49；SettingsCatalog/Clearable/PreviewFixtures/tests 同步；en 文案删 30 条 |
| 死关键词补丁分支 | MetadataMutationPort.queueMutation + 实现 + MetadataPatch 家族（7 类型）+ normalizeKeywords/validateMetadataPatch + MetadataContract.swift + 8 条测试 | 生产 0 调用；关键词统一走 queueKeywordDelta；协议类型 276→268、声明 1467→1442 |
| 双游标 | <code>CullingPage.nextRowId</code>、<code>afterRowId</code>、<code>pageFiltered</code>、<code>pageSimilarity</code>、fake 默认 pageSorted | 全 scope 统一 <code>pageSorted</code> + <code>CullingPageCursor</code>；相似度 scope 也支持排序 |
| Summary fallback | getSummary Swift 全量循环、<code>loadSummaryCacheByPhoto</code>、<code>summaryCacheRows</code>、<code>CullingSummaryCacheRow</code>、端口 nil 默认 | <code>summaryCounts</code> 非可选 SQL 聚合唯一路径 |
| 测试替身默认 | CullingRepository.pageSorted 退化、summaryCounts nil、FaceRepository 13 个默认实现 | fake 显式实现；未模拟的写路径抛 <code>unimplemented</code> |
| 死符号 | GatherSection、contentMinHeight、shadowMd、primarySoft、Radius.group/sm/md、TriageDisplayPolicy.unfiltered、MaintenanceStateFile.lastAttemptAt、falseKeepRate/keepPrecision | 语义名直接使用（canvas/surface/selection/card/thumbnail/panel） |
| 静默失败 | <code>loadSessionPhotos</code> 的 try? 全行兜底 | 投影读取失败上抛，不再伪装空会话 |

## 2. 修复的 P1（与清理同批）

| 缺陷 | 修复 | 回归 |
|---|---|---|
| 拍摄时间排序在 EXIF 冒号日期上失效 | sort SQL 先 <code>GLOB '????:??:??*'</code> 归一，再 <code>strftime</code> | <code>captureSortNormalizesExifDates</code>（EXIF/ISO/NULL 混排） |
| rating 游标 INTEGER 被读成 0，第 2 页丢数据 | <code>CAST(... AS REAL)</code>，cursor 键按 keyKind 取 <code>.int</code>/<code>.text</code>/<code>.real</code> | <code>ratingSortPaginatesAllRatings</code>（24 组/limit 5 全量跨页） |
| T0 人工淘汰的最佳仍占锚点，整组误判 reject | buildContexts 先把 manual-reject 从 eligible 移除 | 2 条 evaluator 用例（similarity/exact） |
| K0 delta 用 written item 旧快照做基线，删除静默 no-op | 仅 pending/failed item 用 item.keywords，否则用盘上快照 | <code>keywordDeltaUsesDiskAfterWrite</code> |
| 恢复 swap 回滚删旧库 WAL | 回滚前把 dbPath-wal 归入 pre 套件 | <code>restoreRollbackKeepsOrphanedWal</code> |

## 2.5 同批修复的 P2

| 项 | 修复 |
|---|---|
| T0 提前返回漏重建 | 指纹一致之外还要求 <code>existing.count == eligible</code>；人工决策撤销后缺行会补回（新增回归） |
| T0 review 置信度/理由 | 非最佳时 confidence 取 <code>cReject</code>（不再恒 0）；只有确实无合格替代才 <code>noAlternative</code>，否则 <code>closeCall</code> |
| T0 verdict 过滤无门控 | 未启用 T0 时带 verdict 过滤直接报 <code>CULLING_FILTER_INVALID</code>，不再把历史行当现状 |
| 门限设置不刷新 | 6 个 triage 设置键触发通知；VM 在 T0 开启时静默重取当前页 |
| F0 约束轮数上限 | 删除 <code>min(64, n*3)</code>，改为 <code>count+2</code>，第 64 条后的约束不再静默失效 |
| F0 separate 选错簇 | 取 member/peer 两侧簇集合的交集（公共簇），跨簇拆分不再丢失 |
| F0 绑定簇合并面板 | <code>binding != nil</code> 时不渲染必然失败的合并面板 |
| 恢复结果解码 | <code>MaintenanceStateFile</code> 对缺失字段给默认值；只写 lastRestore 的文件不再整份解码失败 |
| 恢复错误文案 | <code>RestoreOutcome</code> 带 message；banner 优先展示原因，错误码含 %@ 时回退“恢复失败” |
| 备份 checkpoint 锁 | 改用第二连接执行 <code>wal_checkpoint(TRUNCATE)</code> |
| 复核游标 | <code>String "v1:cohesion:id"</code> → <code>Int? memberId</code>；删 parse/format 两个 helper |
| 排序跨页签 | <code>@SceneStorage("culling.sort")</code> 持久化；页签重建不再重置已翻页网格 |
| ⌥ 数字色标 | <code>KeyPress</code> 在 Option 下取 <code>key.character</code>，不再读到 ¡/™ |
| 错误参数插值 | <code>needed/available/backup</code> 加入有序键，恢复/备份错误不再串位 |
| T0 summary 全量解码 | 改为 SQL COUNT/MAX/SUM 聚合 + verdict GROUP BY；不再把 20k 行的 reasons_json 搬进 Swift |
| T0 apply 全会话扫描 | <code>loadApplyTargets</code> 目标资产下推 SQL（800 分块 IN），只返回所选资产及变体 |
| 续页重复 total | cursor != nil 复用首页 30s 缓存；首页/reset 重算并覆盖，mutation 后 reset 自然失效 |
| 关键词面板每帧 O(n) | 目标集索引缓存（selection+pageVersion），chip partial 改用计数，不再逐 chip 扫全部资产 |
| triage 过滤仍命中人工资产 | <code>filteredWhere</code> 的 EXISTS 增加“资产无 manual 决策”条件；人工 P 后不再出现在“建议淘汰”里 |
| 每次决策重建整页 | 无筛选且非 rating/T0 排序时只刷 summary/aux；外部 domain/关键词变更显式 forcePage |
| 陈旧 partial 备份 | 备份开始清理 <code>*.sqlite.partial</code>，崩溃残留在下次备份时消失 |
| 备份自动暂停覆盖 | 前置权限/空间/第二连接/checkpoint/VACUUM 失败都计入连续失败；busy/restoreBusy 不计数 |
| 备份目录/临时文件权限 | 目录 0700 在写库前收紧；VACUUM 产物 0600 在 verify 前收紧 |
| K0 移除词来源失效 | 写盘后对“写前有、写后无”的词 deactivate 该模块 origin，避免其它模块重新引入时被旧所有权误拦 |

## 3. 后续可选优化（非阻塞）

> 第三轮审计的 P1 与 P2 正确性项已全部修复；以下是纯性能/体量优化，不影响正确性、门禁或单一当前路径。

- **可选性能**：F0 revision 12 聚合、关键词建议 O(资产) 本地兜底。
- **大文件拆分**：MetadataService 819、TriageEvaluator 782、TriageRepo 722、CullingGrid 523、MaintenanceService 523、RestoreSupport 513。
- **TS 注释/outbox 注释**：约 1049 行 <code>// TS</code> 仅为迁移期对照，可批量压缩。

## 4. 验证

- <code>swift test --disable-sandbox</code>（core）：1230/182 通过。
- <code>swift test --disable-sandbox --no-parallel</code>（app）：683/77 通过。
- <code>gather-schema verify</code>：tables=44 columns=383 indexes=72 fks=65 user_version=3 foreign_key_violations=0。
- 8 道 strict 门禁全绿；protocol baseline 已重写为 1443 声明 / 7044 行。
- 20k/2GB perf 门未在本轮重跑；分页路径已统一，后续需复跑并收紧阈值。

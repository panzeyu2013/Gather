# Gather P0 第三轮全量检查（2026-10-26）

> 目标：对 feature 分支（91 commits + 162 项工作区改动，P0 五工作流 G0/T0/K0/F0/B0/X0）做正确性、完整性、最优性、简洁性检查，重点补前两轮未覆盖的**兼容性**与**性能**。方法：七路只读 subagent（G0、T0、K0、F0、B0、兼容性、性能/架构）+ 主代理逐条复核 + 可执行验证。不执行照片质量验收，不宣称误杀率。

## 0. 结论

没有新的 Schema/协议级 P0；迁移、备份、写回主路径可用。但本轮确认 **5 个 P1**，其中两个是「新代码对既有数据形状的假设错误」，在测试里完全不可见：

1. **拍摄时间排序在真实 EXIF 日期上整体失效**：<code>date_taken</code> 实际是 <code>YYYY:MM:DD HH:MM:SS</code>，SQL 的 <code>strftime</code> 直接返回 NULL，所有组并列成空串，capture_desc/asc 静默退化为导入序。
2. **评分排序从第 2 页起丢数据**：<code>MAX(rating)</code> 是 INTEGER，游标用 <code>doubleValue</code> 读成 0，第 2 页起只剩 0 星组。
3. **T0 选「组内最佳」未排除人工淘汰成员**：人工淘汰组内最佳后重新生成，其余成员会被判 reject（置信度 0.95），整组误杀，触及「宁可漏杀不可错杀」红线。
4. **K0 delta 以旧 delivery_items 快照为基线**：外部新增词的删除会静默 no-op（返回 0/0/0，草稿被清空，XMP 未改）。
5. **B0 恢复 swap 的窄崩溃窗口会删掉旧库 WAL**：主库已搬到 pre、-wal 未搬时中断，下次启动回滚无条件删 <code>dbPath-wal</code>，丢失已提交事务。

测试全绿但都不是这些形状：排序测试只喂 ISO/REAL、评分用例不足一页；T0 无 manual-best 用例；K0 无 written-item 基线用例；B0 无 swap 崩溃注入。

| 维度 | 评分 | 依据 |
|---|---|---|
| 正确性 | 7.5/10 | 主链测试扎实；上面 5 个 P1 都是真实数据/跨页/崩溃路径 |
| 兼容性 | 8.5/10 | V3 严格增量、协议纯追加、L10n 全覆盖；数据形状兼容与 2 处文案插值是缺口 |
| 性能 | 8.5/10 | 20k/2GB 均达标；<code>.filtered</code> 每页计数、T0 汇总、静默刷新是下一档瓶颈 |
| 完整性 | 8/10 | 功能齐全；G0 状态条/全选入口、T0 计数口径、错误呈现仍有洞 |
| 简洁性 | 7.5/10 | 分层正确、无第二真相源；6 个超过 500 行文件、fake 端口绕过新 SQL、注释漂移 |

## 1. 验证基线（本机实测）

| 检查 | 结果 |
|---|---|
| core 全量测试 | **1277 tests / 188 suites 通过**（<code>swift test --disable-sandbox</code>） |
| app 全量测试 | **689 tests / 78 suites 通过**（<code>--no-parallel</code>） |
| 8 道 strict 门禁 | docs/layering/no-legacy/select-star/duplicate-symbols/design-system/cleanup-ratchet/protocol-surface 全 OK |
| Schema | <code>gather-schema verify</code>：45 表 / 389 列 / 72 显式索引 / 65 外键 / user_version=3 / FK 违规 0 |
| 协议面 | 17 个 API 协议 / **121** 个方法；错误码 **204**；与 x0-contracts 一致 |
| 20k SQL 分页 | capture p95 **46.7ms**、rating **36.7ms**、triage **39.0ms**（<code>GATHER_CULLING_PERF=1</code>） |
| 20k service | 10 页 p95 **9.7ms**；summary p95 **3.4ms** |
| 2GB 备份 | **3.07s**（<code>GATHER_BACKUP_PERF=1</code>，上限 30s） |
| 工作区 | 162 项改动；<code>git diff --check</code> 仅 ADR 末尾空行 |

## 2. P1（建议进合并阻断清单）

### 2.1 拍摄时间排序在真实数据上失效（G0，影响所有既有库）

- 位置：<code>CullingAssetPageQuery.swift:149</code>：
<code>COALESCE(strftime('%Y-%m-%dT%H:%M:%S', MAX(c.date_taken)), '')</code>
- 事实：导入链路把 ImageIO 的 <code>DateTimeOriginal</code> 原样写入缓存（<code>MetadataService.swift:445</code>、<code>:239-241</code>），测试也断言格式是 <code>2024:05:01 10:20:30</code>（<code>ImageMetadataProvidersTests.swift:52</code>）；SQLite 的 <code>strftime</code> 不接受冒号日期，返回 NULL。
- 实测：20k 合成库，EXIF 格式 → **1 个不同 sort_key**、首 5 组为 a00000…a00004（即导入序）；ISO 格式 → 420 个 key、顺序正确。
- 契约：<code>t0-g0-data-contracts.md:386-390</code> 明确规定先 <code>GLOB '????:??:??*'</code> + <code>replace(substr(...))</code> 归一，再 <code>strftime</code>；实现漏了归一。
- 触发：任何真实导入会话切「拍摄时间（新→旧/旧→新）」。
- 修法：按契约表达式归一（或统一入库格式）；补 EXIF/ISO/NULL/同秒混合用例，并断言跨页顺序。
- 测试缺口：<code>CullingSortPaginationTests.swift:35/67</code> 只喂 ISO；20 页测试不含 EXIF。

### 2.2 评分排序第 2 页起丢数据（G0）

- 位置：<code>CullingAssetPageQuery.swift:229</code>：<code>numberKey: last.sortKey.doubleValue ?? 0</code>。
- 事实：<code>photo_metadata_cache.rating</code> 是 INTEGER（<code>SchemaV1+DDLDomain.swift:94</code>），<code>MAX(rating)</code> 返回 <code>.int</code>；<code>DBValue.doubleValue</code> 只接受 <code>.real</code>（<code>DB.swift:646-649</code>）→ 游标恒 0。
- 后果：第 2 页谓词变成 <code>sort_key &lt; 0 OR (sort_key = 0 AND rowid &gt; x)</code>，1-4 星与剩余 5 星被跳过；只有 0 星组能继续翻页。
- 测试缺口：<code>ratingDescTiesUseRowid</code> 只有 4 行 / limit 10，不生成 cursor（<code>CullingSortPaginationTests.swift:126-145</code>）；20k perf 只断言「页非空 + p95 低于 300ms」，10 页全 0 星也绿（<code>CullingPagingPerfTests.swift:58-100</code>）。
- 修法：SQL <code>CAST(MAX(c.rating) AS REAL)</code> 或游标回退 <code>Double(intValue ?? 0)</code>；perf 断言累计覆盖组数。

### 2.3 T0 组内最佳未排除人工淘汰成员（T0，红线）

- 位置：<code>TriageEvaluator.swift:237-265</code>（<code>analyzed</code> 只按 quality 过滤，<code>bestId = qualified.first</code>）、<code>:591-593</code>（<code>hasQualifiedAlternative</code> 只排除 candidate 自己）。
- 后果：人工淘汰组内最佳后重新生成，该照片仍占 bestScore；其余成员 <code>gap = best - self</code> 达到 reject 线且「有合格替代」成立 → reject 0.95；批量 apply 会把整组淘汰。
- 触发：T0 开启 → 人工 reject 组内最佳 → 重新生成 → 应用全部。可撤销，但用户很难发现「整组被 AI 淘汰」。
- 修法：选 best/second/qualified 时排除「manual + reject」候选（manual keep 可继续作为锚点）；补 evaluator 用例：manual-rejected best 场景下其余成员不得 reject。
- 注意：<code>TriageService.generate</code> 只删建议行（<code>TriageService.swift:159-161</code>），不把人工决策移出上下文。

### 2.4 K0 delta 基线取旧 item 快照，外部新增词的删除静默失效（K0）

- 位置：<code>MetadataMutationService.swift:234-237</code>：
<code>existing = unique(pending?.isEmpty == false ? pending! : diskKeywords)</code>
<code>pending</code> 来自 <code>deliveryRepo.item(xmpPath:module:)</code>，该查询不筛 status（<code>DeliveryRepo+Read.swift:84-96</code>）。
- 场景：先成功 apply 一次（item=written/synced，keywords 是当时的词表）→ C1 外部加词 Bird → 回 Gather 删 Bird → preview 显示将变更 → apply 返回 0/0/0，<code>plan.changed == false</code>（<code>:253</code>）→ UI 因 <code>failed == 0</code> 清空草稿（<code>CullingViewModel+Keywords.swift:214-221</code>），XMP 未改。
- 修法：仅当 <code>pendingItem.typedStatus</code> 为 pending/failed 才用 item.keywords，否则用盘上快照；补「written item + 盘上差异」回归。
- 关联：origin 只在 face 路径 <code>deactivate</code>（<code>WritebackService.swift:323</code>），cleanup 不注销 → 模块清理后同名词仍被 owned；见 3.14。

### 2.5 恢复 swap 中断时删除旧库 WAL（B0，窄窗口数据风险）

- 位置：<code>RestoreSupport.swift:321-325</code> 先搬主库、再搬 -wal/-shm，<code>:325</code> 才写 <code>oldMoved</code>；<code>:466-469</code> 回滚时无条件 <code>removeIfExists(dbPath + "-wal")</code>。
- 场景：上一会话崩溃留下未 checkpoint 的 WAL；恢复安装期间在主库已搬走、WAL 未搬走时断电；下次启动回滚把旧库搬回，但旧库 WAL 已被删除 → 已提交事务丢失。
- 修法：回滚前若 pre 无 -wal 而 dbPath 有，先把 WAL 归入 pre 套件；或恢复前 <code>wal_checkpoint(TRUNCATE)</code>；补 swap 崩溃注入测试。

## 3. P2（建议合并前修复或明确排期）

| # | 位置 | 问题 | 触发 / 证据 | 修法 |
|---|---|---|---|---|
| 1 | <code>TriageService.swift:162-175</code> | 早退只校验已有行指纹，不校验覆盖率：人工决策删行后撤销，建议永久缺失，stale 仍 false | 人工决策→generate 删行→撤销→自动生成不重建 | 早退前比对行数与 eligible 数，不等则重建 |
| 2 | <code>TriageEvaluator.swift:497-501</code> | review 置信度写 0、理由 no_alternative 与事实相反 | gap 达到 0.12 但 cReject 未过 0.75；契约 <code>Triage.swift:51-52</code> 要求 max(cKeep,cReject) | 返回 cReject；理由改 close_call/weaker_than_group_best |
| 3 | <code>TriageRepo.swift:308-330</code> | apply 读全会话 + 逐行代表子查询，20k 只应用几条也全表扫 | 20k 会话 apply | 目标 id 下推 SQL IN，复用 revision |
| 4 | <code>TriageRepo.swift:258-298,674-711</code> + <code>LiveCullingAPI.swift:88-98</code> | T0 开启后每次键动作的 summary = 全量建议 + 4 次 O(session) 聚合 + 逐行 JSON | 20k 建议、每次 P/X（refreshSilently） | summary 一条 GROUP BY + coverage 合并；按 gate 寿命缓存 |
| 5 | <code>CullingService+Paging.swift:72-76</code> + <code>CullingAssetPageQuery.swift:242-254</code> | 每页重算精确 total（GROUP BY + 相关子查询）；.filtered 20k 实测 +11ms/页 | 翻页；perf 门只测 pageSorted/.all | 续页 includeTotal=false 或按 (session,filter,sort) 缓存 |
| 6 | <code>CullingViewModel+Load.swift:15-18,52-53,104-167</code>；<code>+Actions.swift:176,230</code> | 每次决策重建 min(2000, max(pageLimit, loaded)) 的页 + 4 个会话级查询 | 深翻后按 P/X；与 g0 设计「不整页刷新」冲突 | 只 applyDecisionStates + 异步 summary，取消页重取 |
| 7 | <code>CullingInspector.swift:111-121</code>；<code>CullingService+Paging.swift:53-55</code>；<code>+Load.swift:301-306</code> | 相似度 scope 只支持导入序，但排序 Picker 不禁用；失败后 scope 已切、旧页不回滚 | 非导入序切「相似度分组」→报错且网格仍是全部照片 | 进相似度 scope 强制 import 并重载；失败回滚 scope |
| 8 | <code>CullingView+Content.swift:73-92</code>；<code>+Load.swift:210-223</code> | 页签重建/切布局都 reset 到首屏，loadedPhotoIds 被重置，跨页选择丢失 | 翻 5 页→切图库→回来 | 仅 page 为 nil 才 load；resize 不 reset |
| 9 | <code>CullingView.swift:36-38</code> | 排序无 SceneStorage/设置持久化，重启回落 import | 与 g0:140/338 不符 | 加 SceneStorage，setSort 写回 |
| 10 | <code>CullingGrid.swift:321-329</code> | Option 色标用 <code>press.characters</code>（Option 会改字符），⌥1-7 实际失效 | 设计 g0:118 要求 press.key；测试直接喂 "1" | 改 press.key/charactersIgnoringModifiers |
| 11 | <code>CullingAssetPageQuery.swift:370-388</code> vs <code>CullingService+Queries.swift:350-361</code> | triage 过滤只查建议表；人工决策后建议被隐藏但 SQL 仍命中 | 应用建议后手动 P，再筛「建议淘汰」 | EXISTS 增加「无 manual 决策」条件 |
| 12 | <code>SettingsViewModel+Fields.swift:187-190</code> | 三个置信度阈值不广播 settingsChanged | 改阈值后卡片仍可应用，点了才报 TRIAGE_STALE | 三键也发通知并重取 summary |
| 13 | <code>MetadataMutationService.swift:214-272</code> | 关键词 apply 无 per-path 串行；与改评分并发 flush 抢租约 → 后到者 failed | 两次 apply / apply+setMetadata | 复用 PathSerialChain 按 xpath 串行 |
| 14 | <code>WritebackService.swift:417-436</code> + <code>+Converge.swift:75</code> | 生成词 origin 只记不注销（仅 face 有 deactivate） | cleanup 后同名词永久 owned | cleanup/模块 reset 按 xpath+source deactivate |
| 15 | <code>FaceKwService+Constraints.swift:62-66,216-225</code> | separate 的公共簇取「最低 id 簇」，成员跨簇时取不到 A/B 同处簇 C，约束静默跳过 | 拆出组被 DBSCAN 拆成 2 簇 | memberClusters 与 peerClusters 交集逐个处理 |
| 16 | <code>FaceKwService+Constraints.swift:33,107-109</code> | 轮数上限 64、每轮只应用 1 条，超过 63 条待生效约束静默不应用 | 3000 张活动照可达 | 上限改 count+2 或以「无变化」为唯一终止 |
| 17 | <code>FaceKwService+Constraints.swift:35-45,191-214</code> | 每轮重读全部簇/成员/绑定 + 线性 resolve，持写事务 | 10k 成员/20 约束，设计 600ms 预算无测试 | 建 observationId/photoId 索引，补 perf 断言 |
| 18 | <code>FaceReviewStep.swift:147-148,329-333</code> | 当前簇已绑定时仍渲染合并面板，确认后必报 FACE_CLUSTER_BOUND | 绑定簇页面 | binding 非 nil 时隐藏/禁用面板 |
| 19 | <code>RestoreSupport.swift:171-187</code> + <code>MaintenanceService.swift:7-19,476-484</code> | writeState 只写 lastRestore，状态文件其余字段必填 → 无既有文件时解码失败，设置页不显示恢复结果 | 首次恢复失败后打开设置 | 写全字段或 decodeIfPresent 给默认值 |
| 20 | <code>CommandError.swift:178-195</code> + <code>LiveMaintenanceAPI.swift:57-63</code> | needed/available、backup/current 被字母序重排，空间/版本文案数值互换 | 备份空间不足、恢复更高版本 | preferredKeys 补 needed→available→backup 顺序 |
| 21 | <code>SettingsView+MaintenanceSection.swift:38-41</code> + <code>L10n.swift:263-265</code> | RESTORE_FAILED 模板带 %@ 但只传 code → 字面「恢复失败：%@」；RESTORE_STATE_CONFLICT/BACKUP_INVALID/BACKUP_CHANGED 未入码表 → 未知错误 | 任意恢复失败/冲突 | RestoreOutcome 存 code+params；三码入 GatherErrorCode + 文案 |
| 22 | <code>MaintenanceService.swift:128,168-201</code> | .partial 直写默认 0644，成功后才 chmod 600；陈旧 partial 永不清理；无 fsync | 备份中退出、非 700 目录 | 提前 0600/0700；启动清 *.partial；文件+目录 fsync |
| 23 | <code>MaintenanceService.swift:117-119</code> | 主连接跑 wal_checkpoint(TRUNCATE)，大 WAL 时卡 UI | 大批导入后手动备份 | 用已开第二连接 / PASSIVE |
| 24 | <code>MaintenanceService.swift:70-106,152-231</code> | 连续失败计数只在 do 块 catch，权限/空间/锁等 do 前失败永不 autoPaused | 只读目录 + 自动备份每 6h 重试 | 计数上移覆盖整个 backup |
| 25 | <code>x0-contracts.md:229-242</code> vs <code>SettingsService.swift:106-118</code> | 契约 14 键、实现 16 键（缺 triage_auto_generate、triage_keep_confidence_min）；triage_policy 默认 v1 vs triage-v1 | 按契约实现的新调用方漏键 | 契约补 2 行、默认值修正，加 defaults 覆盖契约的门禁 |

## 4. P3（清理项，不阻断）

- 注释/文档漂移：<code>GatherSchema/main.swift:3,9</code>、<code>SchemaV1.swift:11</code>、<code>SchemaCatalog.swift:3</code>、<code>Schema.swift:4</code> 仍写 V2/43 表；<code>SettingsService.swift:22</code> 写 40 键（实 63）、<code>GatherLocalization.swift:66</code> 156 项（实 204）、<code>L10n.swift:5</code> 179 码（204）、<code>APIContractIndex.swift:5</code> 16 协议/110 方法（17/121）；GatherSchema 二次硬编码 45/389/72/65。
- ADR 自相矛盾：<code>docs/ADR.md:92</code> 仍「以 SchemaV2（43 表）为准」，ADR-032/033 状态仍「设计冻结（实现中）」；文件末尾多一个空行（<code>git diff --check</code>）。
- 文档基线过期：<code>README.md:40</code> 1,270/687、en 1,530；实测 1,277/689、1,541。
- 370 列历史 V1 备份：Database.open 支持 HistoricalV1Shape，但 <code>BackupVerifier.swift:54-64</code> 按 373 列快照判「形状不符」，同类备份无法恢复。
- 旧代码/未达路径：<code>CullingReadQuery.swift:294-299</code> + <code>CullingService+Queries.swift:144,584-593</code> 的 summary fallback 生产不可达（应标注 fake-only）；rating 排序用例不生成 cursor。
- 测试质量：<code>CullingServiceTests.swift:2612</code> 20k service 门限 800ms（实测 9.7ms）；CullingGridPerfTests 用 200 占位资产且直塞 vm.page；PortFakeSupport 不实现 pageSorted/summaryCounts，端口漂移不会红（<code>CullingRepository.swift:56-79</code>）。
- 未覆盖分支：skippedConflict（<code>TriageService.swift:329-343</code>）零测试；together/skippedBound 零测试；RESTORE_STATE_CONFLICT 等失败码无文案。
- 诊断导出：日志 stat 失败仍按 0 继续、非 UTF-8 读成空串（<code>DiagnosticsCollector.swift:259-268</code>），上一轮声称的「视为导出失败」未落地；裁剪用例用随机字节，实际空跑。
- 简洁性：超过 500 行文件 6 个：MetadataService.swift(1082)、TriageEvaluator.swift(766)、TriageRepo.swift(719)、CullingGrid.swift(523)、MaintenanceService.swift(523)、RestoreSupport.swift(513)；建议按「候选装配/指纹/摘要/apply 目标」拆 TriageRepo。
- 交互完整性：网格状态条缺「已加载 X / 共 Y」与排序/筛选摘要（<code>CullingGrid.swift:235-255</code>）；⌘A 只选已加载且无可见入口；CullingFilmstrip 仍判 nextRowId 而非 hasMore；导入序/相似度短页仍返回 cursor（<code>CullingAssetPageQuery.swift:99,123</code>）导致多一次空页请求。
- 单位口径：页面 total 按逻辑资产组、summary 按物理照片（<code>CullingInfoBar.swift:44</code> 对比 <code>CullingReadQuery.swift:306-320</code>），RAW+JPEG 会话两个「总数」不一致。

## 5. 兼容性专项

| 面 | 结论 | 证据 |
|---|---|---|
| Schema 增量 | V3 = V2 + 2 表 + 3 索引，既有 43 表列/外键零改动；fresh/migrate 共用 SchemaV3.delta | <code>SchemaV3.swift:16-50</code>；<code>MigrationV2ToV3.swift:12-18</code>；gather-schema verify |
| 迁移安全 | 备份 → BEGIN IMMEDIATE → delta → user_version → foreign_key_check → 形态校验 → COMMIT；失败整体回滚、库停旧版本 | <code>SchemaMigrator.swift:38-75</code>；SchemaMigrationTests 覆盖 V1→V3、370 列、重复 open |
| 协议 | 121 方法纯追加（+11：Culling 2 / Face 2 / Metadata 3 / Maintenance 4），无删除/改签名；新字段均可选带默认值 | git diff；<code>Culling.swift:291</code>；protocol-surface-baseline.json |
| 错误码 | 204 条，新增 25 条与 x0 §4 逐一对应；204 条文案双向覆盖 | GatherErrorCode；ErrorLocalizationCoverageTests |
| 设置 | 16 个新键全部进 defaults + 目录；triage/grid/backup/face_review 均 provider 注入；grid_default_sort 空串回落 | <code>SettingsService.swift:106-118</code>；<code>Core.swift:165-173</code>；<code>SessionWorkspaceFactory.swift:64-78</code> |
| L10n | 214 个新增中文 key 全部存在于 en.lproj；zh-Hans 按设计留空（key 即中文）；占位符序列一致 | 逐个比对；LocalizationParityTests |
| 数据形状 | **两处不兼容**：date_taken 是 EXIF 冒号格式（2.1）；rating 是 INTEGER（2.2）。G0 排序 SQL 假设了 ISO/REAL | 见 2.1/2.2；<code>ImageMetadataProvidersTests.swift:52</code> |
| 旧交付状态 | K0 的 delta 基线把已写 item 当成「现状」（2.4），对升级前已有交付历史不兼容 | <code>DeliveryRepo+Read.swift:84-96</code> |
| 旧备份 | V1/V2 备份可恢复后再迁移；370 列历史 V1 备份被 verifier 拒 | <code>MaintenanceService.swift:307-319</code>；<code>BackupVerifier.swift:54-64</code> |

兼容性判断：Schema/协议层是**干净增量**，可以安全合并；真正需要补的是**既有数据形状**（日期、评分）与**既有交付行状态**（K0 基线）两类运行时兼容。

## 6. 性能专项

实测（本机，20k 合成库 / 2GB 库）：

| 场景 | 结果 | 判断 |
|---|---|---|
| SQL 排序分页 p95 | capture 46.7ms / rating 36.7ms / triage 39.0ms | 达标（设计 50k 预算内） |
| service 分页 p95（.all） | 9.7ms | 达标 |
| summary p95（20k） | 3.4ms | 达标 |
| 2GB 备份 | 3.07s | 达标（上限 30s） |
| .filtered 每页 total | +约 11ms/页（20k 空筛选实测） | 不必要，P2 |
| T0 开启后每次键动作 | summary 全量建议 + 4 次 O(session) 聚合 | 20k 时的高风险热点 |
| 深翻后每次 P/X | 重建最多 2000 资产页 + 4 个会话级查询 | 延迟随 loaded 线性增长 |
| F0 复核翻页 | 命中缓存仍跑 12 个聚合 revision | 10k 观测时每页固定开销 |
| F0 约束应用 | 每轮重读全量簇/成员 + 线性 resolve，持写事务 | 设计 600ms 预算无测试 |
| 关键词面板 | 每个 chip O(资产×关键词)，body 每帧重算 | 多选数百张时输入卡顿 |

优化性价比排序（只列有证据的）：

1. **先修正确性再谈性能**：rating 游标、capture 归一、T0 manual-best。否则 perf 数字是在「错的数据」上测的。
2. **T0 summary 单条聚合**（一次 GROUP BY verdict + 一次 coverage），预期把 20k 键动作的固定成本从「全量 JSON 解码」降到毫秒级。
3. **续页 includeTotal=false**，.filtered 翻 10 页省约 110ms。
4. **静默刷新不随 loadedCount 放大**：只刷当前页 + 受影响资产，summary 去抖。
5. **F0 revision 改增量**（簇级 MAX + PRAGMA data_version），复核翻页去掉 12 聚合。
6. **关键词面板缓存** effective/partial 集合（selection+pageVersion 键），去掉每帧 O(n)。
7. 低优先级：delivery join 已有 UNIQUE 自动索引（delivery_id 前缀），不需要新增索引；诊断 export 的 Process.waitUntilExit、日志每行 fsync 可后续处理。

## 7. 完整性与简洁性

- 完整性：五工作流主流程齐全；缺口集中在 G0 的「已加载/总数」可见性、全选入口、排序持久化，T0 的计数口径（人工 pending 计入 keep+reject 但 apply 会跳过），B0 的错误呈现，F0 的约束报告被丢弃（ClusterConstraintReport 无 UI/日志）。
- 简洁性：分层（UI→API→Application→Persistence）未破；关键词归一化/游标/排序规则都单点。问题是 6 个文件超过 500 行、TriageRepo 同时做候选装配/指纹/摘要/apply 目标、fake 端口绕过新 SQL（pageSorted/summaryCounts 默认退化）、summary fallback 生产不可达。
- 测试：新增测试质量整体高（先诊断再断言、时间/排序确定性、错误码覆盖）；但「绿」的可信度被三件事削弱：fixture 形状单一、perf 阈值过松（800ms vs 9.7ms）、fake 绕过关键 SQL。

## 8. 建议修复顺序

| 顺序 | 项 | 预估 | 验收 |
|---|---|---|---|
| 1 | 2.1 capture 归一 + 混合格式用例 | 0.5 PD | 20k EXIF/ISO 混合跨页顺序测试；手工 20 页 |
| 2 | 2.2 rating 游标 + 跨页覆盖断言 | 0.3 PD | rating 25 组 / limit 3，10 页无重漏 |
| 3 | 2.3 T0 manual-best 排除 + 用例 | 0.5 PD | 人工淘汰 best 后其余成员不 reject |
| 4 | 2.4 K0 基线按 status 选取 + written-item 用例 | 0.5 PD | 外部加词→删除→XMP 实际变更 |
| 5 | 2.5 恢复 WAL 归位 + swap 崩溃注入 | 0.5 PD | 注入「主库已搬/-wal 未搬」回滚后 WAL 保留 |
| 6 | P2 表中 1-6（T0/K0 正确性 + 性能） | 2-3 PD | nightly 20k/T0 场景 |
| 7 | P2 7-25 + P3 清理 | 3-4 PD | 现有门禁 + 新增契约计数断言 |

## 9. 验证与限制

- 本轮已执行：core/app 全量测试、8 道 strict 门禁、gather-schema verify、20k SQL/service perf、2GB backup perf、协议/错误码/设置键/L10n 逐项计数。
- 未执行：照片质量验收（真实标注集是外部缺口）；10k 真实人脸复核耗时；swap 崩溃注入；真机 20k 缩略图/滚动；⌥1-7 与 ⌘A 的真实键盘路径。
- 只读原则：七路 subagent 均未写文件、未跑 build/test（构建由主代理串行执行）；本报告是唯一写入。
- 过程披露：前两轮留下的「已修复」声明中，本轮抽查到 2 项未真正落地（K0 模块清理 deactivate、B0 诊断 stat 失败视为失败），已在 P2 中标出；其余抽查项属实。

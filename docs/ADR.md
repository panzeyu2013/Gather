# Gather 架构决策记录

> 本文件保存从已归档执行计划（CORE_RELIABILITY_EXECUTION_PLAN /
> CULLING_WORKBENCH_DESIGN_AND_EXECUTION，已于 `9226061` 删除）中恢复的
> **仍具规范性的决策与门禁**。实现细节以代码为准，本文只记录"为什么"与
> "何时允许改变"。
> 2026-08-12 修订：合并 Electron→原生迁移（原 `NATIVE-DEVELOPMENT-ANALYSIS.md`
> 已归档删除）后，**本文件底部新增 ADR-021~028**：性能架构决议（已实现）与
> 四项遗留方案、人脸推理演进。原 ADR-001~020 中引用的 Electron 时代实现路径
> 已随迁移失效，语义与不变量不变，**原生对应实现位置见下表**（未列条目以
> `desktop/native/gather-core` / `gather-app` 代码为准）。

**原实现路径 → 原生实现位置对照**

| ADR | Electron 时代路径（已删除） | 原生实现（迁移后） |
|---|---|---|
| 005/006 | `desktop/src/main/db/migrations.ts`、`tests/unit/...` | `gather-core/Sources/GatherCore/Database/Migrations.swift`、`Schema.swift`；快照校验 `Tests/GatherCoreTests/Database/MigrationTests.swift`（`docs/fixtures/schema.snapshot.json`，schema 34 / 43 表） |
| 007 | `services/image/disk-cache.ts` | `gather-core/Sources/GatherCore/Database/ImageCache.swift`（**ImageCache 类已删除**，见 ADR-028；文件仅保留 `SHA256` 等生产在用的工具） |
| 012/013 | `services/workspace/workspace-status.service.ts` | `gather-core/Sources/GatherCore/Services/WorkspaceStatusService.swift` |
| 014 | `ipc/session.ipc.ts`、`services/session/session.service.ts` | `gather-core/Sources/GatherCore/Services/SessionService.swift` |
| 015 | `services/capture-one/sync-state.ts` | `gather-core/Sources/GatherCore/Services/CaptureOneSyncState.swift`（**`CaptureOneSyncState` 类与 `C1BridgeProvider` 已删除**，见 ADR-028；保留纯函数 `aggregateSessionState`） |
| 016/019/020 | `renderer/locales/`（i18next）、`main/menu.ts`、`main/locale.ts` | `gather-app/Sources/GatherApp/Support/GatherLocalization.swift` + `Resources/{en,zh-Hans}.lproj`；`Host/GatherAppDelegate.swift`（`installMenu` 两语言重建，`languageChanged` 驱动） |
| 017 | `packages/shared/src/errors.ts` | `gather-core` 错误枚举（错误码语义不变）+ `GatherLocalization.errorText`（173 项映射） |
| 018 | `renderer/components/Dialog/Dialog.tsx` | 历史记录：自研 APG 焦点管理仅存在于 Electron 版；原生版由系统 sheet/`confirmationDialog` 天然覆盖（见 DEVELOPMENT.md HIG 约定），"拒绝 roving tabindex"的结论对原生列表仍成立 |

---

## ADR-001 Asset 表示一次逻辑拍摄（D-01）

- 一个 Asset 表示一次拍摄或一张逻辑照片；RAW、机内 JPEG、TIFF、代理图与导出文件是
  同一 Asset 的不同文件成员。
- checksum 相同只表示内容重复证据，**不自动表示**同一个 Asset；不同路径的相同内容
  保留为独立物理文件并进入重复候选。
- Asset 使用应用生成的稳定 UUID，不依赖路径、文件名或 checksum。

## ADR-002 RAW+JPEG 默认折叠显示（D-02）

- 画廊默认每 Asset 一张卡片，带 `RAW+JPEG` 变体徽章；浏览预览默认用 RAW 内嵌 JPEG；
  详情可切换变体，并提供"展开所有变体"。
- Pick/Reject/Pending 作用于逻辑 Asset；Rating、Label、Keywords 按实际 Sidecar
  binding 共享；导出可选择 RAW、JPEG 或首选文件。

## ADR-003 全局状态与 Session 状态分离（D-03）

- **跨 Session 复用**：Rating、Color Label、Keywords（以 Sidecar binding 为真实共享
  边界）、文件技术元数据/checksum/缓存、由 fingerprint 与算法签名确定的相似 hash 与
  人脸检测结果、Person 身份。
- **保持 Session 独立**：Pick/Reject/Pending、Undo/Redo、相似组/Burst/Scene/导航
  工作集、Keep K、筛选/排序/UI 状态、依赖当前工作集的聚类/分组结果。
- 真正的元数据共享边界是 Sidecar binding，不是 Asset 本身。

## ADR-004 RAW/JPEG 保守、可撤销的自动关联（D-04）

- **自动归入同一 Asset**（全部满足）：同一规范化目录、basename 完全相同、受支持的
  RAW+JPEG 组合、拍摄时间均存在且相差 ≤2 秒、相机序列号/图像编号等字段存在时互相兼容。
- **只生成候选、不自动合并**：不同目录、仅 basename 相同、拍摄时间缺失、相机信息缺失或冲突。

---

## ADR-005 数据库迁移不变量与备份/恢复策略

- 迁移前：检查可用磁盘空间（`max(64 MB, 源大小×2)`）→ `wal_checkpoint(TRUNCATE)` →
  用 **SQLite backup API**（非直接复制活动 db）创建带 schema version 与时间戳的备份 →
  校验备份可打开（`integrity_check`）。
- 迁移失败：不写 down-migration；关闭数据库、保留失败副本、从迁移前备份恢复；
  不删除任何用户照片或 XMP。
- 迁移后：`foreign_key_check` + 关键表列不变量断言 + `CURRENT_SCHEMA_VERSION` 校验。

## ADR-006 Schema 快照位置与用途

- 当前 schema 快照：`docs/fixtures/schema.snapshot.json`（记录表名集合）。
- 由 `Tests/GatherCoreTests/Database/MigrationTests.swift` 校验空库迁移后与其一致
  （43 表全对，`CURRENT_SCHEMA_VERSION` 34）；任何表级 schema 变更必须同步更新该快照。
- 索引的"单一规范定义"由迁移实现强制（迁移块内不得重复索引 DDL）。

---

## ADR-007 磁盘缓存元数据：SQLite + 惰性淘汰（实现已删除，见 ADR-028）

- 缩略图磁盘缓存元数据（hash → lastAccess/createdAt/accessCount/fileSize）持久化在
  `cache-meta.db`（better-sqlite3 + WAL，原生为 SQLite.swift 等价实现），替代全量
  `JSON.stringify(cache-meta.json)`：热路径 `onAccess`/`onSet` 纯内存 + debounce 批量
  upsert，主线程无同步序列化。
- 淘汰候选由每策略 SQLite 索引排序窗口提供（`ORDER BY <policy> ASC, hash ASC LIMIT k`，
  O(log n + k)），再与脏集合（值尚未落盘、可能与持久化行不一致的条目）合并、按内存
  当前值重排取 k 个——与全量扫描严格等价，但主线程不再 O(n) 遍历；淘汰前先等待在途
  持久化队列，避免 SQL 旧视图导致错误淘汰。候选按 policy 值升序
  （LRU=lastAccess / FIFO=createdAt / LFU=accessCount）。
- 降级不变量：DB 损坏 → 改名 `.corrupt-<ts>` 重建空库；仍失败（只读目录）→
  `:memory:` 纯内存模式；`waitUntilReady` 永不 reject；退出前 `flush()` 落盘。
- **现状（2026-09-28）：本条实现已删除（ADR-028）。** `Database/ImageCache.swift` 的
  `ImageCache` 类无生产实例化（仅被自身测试引用），已随未接线资产清理删除；同文件的
  `SHA256`/`UInt64.bigEndianBytes` 被生产消费，**文件保留**。缩略图缓存现由
  `Support/PhotoThumbnailView.swift` 的 NSCache 承担。以下不变量仅作为"当时为什么这样
  设计"的历史记录保留，不再约束实现。

## ADR-008 Culling 分页按逻辑资产分组（不变量）

- 分页（`culling.list_page`）以逻辑资产为最小单元：`COALESCE(asset_id, id)` 分组、
  组内 `MIN(rowid)` 作 keyset 游标、组内全行一次加载——RAW/JPEG 变体**永不跨页**，
  跨页遍历每个资产恰好出现一次（回退为按物理行分页将再次引入重复条目，禁止）。
- `total` 一律按逻辑资产计数；过滤谓词下推到**首选变体**（RAW 扩展名优先，否则
  `rowid` 最小者）。
- 游标对渲染层**不透明**：UI 只回传 `nextRowId`，不得解析其含义。
- 与 ADR-001/002 的 Asset 语义联动：任一物理行匹配谓词即入页会导致 total 虚高与
  空页（仅非首选 JPEG 命中时），故 SQL 谓词必须限定首选行。

## ADR-009 相似度"主档"与预计算档位

- `similarity_results` 可存多档结果：分析/重聚类的"主档" + 预计算邻居阈值
  （T±4/T±8）的档位行；档位行在 `stats_json` 内标记 `"precomputed": true`。
- **"最新结果"的判定**（`getLatest`、culling 相似组 SQL、质量相对排名）必须排除
  `precomputed` 行——否则档位插入顺序（主行先、档位后）会让 `MAX(id)` 选中档位，
  造成相似组浏览与相对排名错乱。该不变量由 `reuse-and-tiers` 与 `culling-page`
  测试强制。
- 写回/预览默认按主档解析；渲染端展示档位时按展示阈值解析（`threshold` 参数），
  档位不存在则报错要求重新聚类。

## ADR-010 checksum 双写与乐观更新

- 懒校验（`lazy_checksum`）下，`photos.checksum` 与 `asset_files.checksum` 必须
  **同事务双写**：扫描的未变更检测读 `asset_files.checksum`，backfill 只写
  `photos` 会导致下次全量扫描清空并反复重哈希（不收敛）。
- 写入方向约束：扫描只在 `contentChanged` 时清空 checksum；对未变更但快照缺失
  checksum 的文件**保留现值**（可能是并发 backfill 刚写入的哈希）；backfill 只
  填空值（`AND checksum = ''` 乐观写，`changes = 0` 则不覆盖并跳过）。
- 理由：`metadata.scan` 与 `checksum.backfill` 是独立 job（可并发），不串行化，
  用方向约束 + 条件写消除互相覆盖。

## ADR-011 增量 ANN 索引：HNSW 组件（里程碑 V）

- 内存 HNSW（M=16/Mmax0=32/efConstruction=32/efSearch=32），向量行主序共享
  Float32Array + 逐节点分层邻接表，距离为余弦点积（单位向量前提）。与 LSH 互补：
  LSH 全量 `build()`（O(n·bits·dim)），适合一次性构建；HNSW 增量 `insert()` 只触达
  邻域，适合"新增少量照片"的持续更新场景。
- 连接与裁剪使用论文 Algorithm 4 的多样性启发式（候选按距离序 + 与已选邻居的
  相似度拒绝），防止增量插入把簇间桥剪光导致图退化；候选到中心点的距离在排序前
  一次性缓存，成对相似度按需计算。
- 质量门禁（`hnsw-recall` 测试）：保留集查询（与索引同分布但未索引的 512 维 8 簇
  合成数据）recall@1 ≥ 0.9（查询 ≈0.3ms/次，构建 ≈3.5ms/向量——全量构建应由后台
  任务承载，不承诺构建延迟；M=16/mMax0=64 下增量插入召回波动实测 −0.008）。
- 原生实现：`gather-core/Sources/GatherCore/Face/VectorIndex.swift`
  （CosineHnswIndex + CosineLshIndex，topK 逐位一致/recall ≥ TS 对账门禁）。

---

## ADR-012 分析过期检测：`analysis_runs` + `sessions.index_seq`

- 过期判定 `stale = 最近一次 ok run 的 index_seq < session.index_seq`；`index_seq`
  只在索引提交点自增（扫描事务后），相似度/人脸分析开始时读事务快照写入 run 记录
  （`analysis_runs`）。
- **不采用照片数 COUNT 比较**：删除照片时 COUNT 变小但分析结果并未过期，会产生
  假阳性重算；`index_seq` 只随索引提交自增，语义精确。
- 只取最近一次 `status='ok'` 的 run 参与判定，失败/取消的 run 不掩盖过期。
- 并发约束：`index_seq` 自增走单事务；分析读取用事务快照。
- 后果：新增照片 → Inbox 出现 `analysis_stale`；删图不误报；阶段判定 `indexed`
  以索引 job 成功记录为准。
- **现状（2026-09-28）**：`sessions.analysis_status` 列已删除（方案 A）；分析运行态
  统一从 `analysis_jobs` 的最新终态派生，不再由相似度/人脸两处交叉写同一无 owner 列。

## ADR-013 WorkspaceStatusService：只读聚合 + 离线复核 TTL

- 不引入新权威数据源：全部计数从 photos / analysis_runs / metadata_outbox /
  jobs 派生，是 CQRS 式只读模型。
- 推荐动作 = **固定优先级序列表 + 布尔门控**（scan_incomplete → xmp_conflict →
  analysis_stale → job_failed → 推进流程），拒绝规则引擎。
- 离线照片复核 **TTL ≥ 5 分钟**（`OFFLINE_PHOTOS_TTL_MS = 5 * 60_000`）：
  `photos.status='missing'` 是惰性检测，Inbox 刷新不得全盘 stat，否则退化为
  性能陷阱。
- 刷新策略：轮询兜底 30s（索引活跃期 3s）+ 复用现有推送事件（`jobs:progress`
  终态、`culling:sync-status`），不新增 push 通道。
- 后果：离线计数最多滞后 TTL 5 分钟；Inbox 查询为常量级开销。

## ADR-014 一跳化导入：路径数组不跨 IPC

- 50k 上限是**内存/IPC 载荷约束而非产品上限**；主进程内流式遍历 + 分批落库后，
  上限在数据层消失，仅保留为 UI 计数预览上限。
- `app:scan-directory` 保留仅用于 UI 计数预览，返回
  `ScanResult { files, truncated, scannedTotal, limit }`（`scannedTotal` 持续
  累加、`truncated = scannedTotal > files.length`），截断标记落
  `sessions.truncated_import`。
- 原生形态：`session.create_from_directory` 路径一跳，`IndexerService` 流式 walk +
  分批落库，去重键 `metadata.scan:<sessionId>`；截断导入 UI 显示 "≥" 前缀与
  "扫描中…" 直至索引终态帧。

## ADR-015 CaptureOneSyncState：会话级聚合 + `reload_acked_at` 重启重推导（类已删除，见 ADR-028）

- 机器状态在内存、易失：重启后从 **outbox 行状态 + `reload_acked_at` 重推导**，
  行是持久真相源、机器状态是派生值，不落库整个状态机。
- 会话级聚合规则确定性：`conflict > failed > syncing(pending/writing) >
  safeToCleanup`；未知状态按保守处理，绝不声称 safeToCleanup。
- `reload_acked_at` **只在 reloadMetadata() 成功后写入**，保持"失败即回退、
  不清理"策略；`safeToCleanup` 门控（reload 成功 + 延迟窗口）与 XMP 双写领域
  模型同构。
- 协调器每次 emitSummary 后重推导会话状态并记录状态转换日志，状态机转换全部可观测。
- 后果：重启后跨会话恢复 `safeToCleanup` 而不误清理；清理动作永远不早于 C1
  确认读取。
- **现状（2026-09-28）**：`CaptureOneSyncState` 类与 `C1BridgeProvider` 协议已删除
  （ADR-028）；上述聚合规则保留为纯函数 `aggregateSessionState`，会话级机器状态由
  `MetadataSyncCoordinator` 从 outbox 行状态 + `reload_acked_at` 推导。

## ADR-016 i18n：类型化 key + 主进程只抛错误码

> 原生版由 `GatherLocalization` + `.lproj` 表承接（见 DEVELOPMENT.md 本地化体系），
> 本条目记录当时的边界决策，语义沿用。

- 边界分工：核心层**只抛错误码**与**阶段码**（`progress.*`），界面层统一映射文案
  （`errorText` / `progressPhaseText`），事件推送负载同样代码化，禁止核心层返回
  拼接文案。
- 语言来源：系统语言 zh 前缀 → zh-CN，其余 en；设置覆盖 > 启动开关 > 系统语言。
- 后果：新增文案必须走本地化层并同步两语言表；核心层文案以错误码形式跨路由。

## ADR-017 错误码化的表面边界与文档例外

- 错误码化覆盖两个表面：命令返回值（`C1_*` / `SCAN_*` / `SIM_*` / `FKW_*` /
  `XMP_*` / `WRITEBACK_*` / `CULLING_*` / `EXPORT_*` 等）与事件负载阶段码
  （`progress.<phase>` 键）。
- 已记录例外：导出报告（`ExportService` 生成的 markdown 文档，如"# 人物"
  "# 关键词"）是**文档内容而非 UI 文案**，不纳入本地化与错误码体系；UI 文案
  （按钮、标签、toast、错误提示）一律走本地化层。
- 后果："核心层无自然语言文案"有明确判据（文档内容豁免）；新增错误先加码、
  再在界面层补映射，不得回退到拼接文案。

## ADR-018 Dialog 无障碍：自研 APG 焦点管理（历史记录）

> Electron 时代在 `Dialog.tsx` 自研对齐 W3C APG Dialog 模式（portal + inert、
> Tab 焦点陷阱、焦点恢复）；原生迁移后弹层统一使用系统 sheet/`confirmationDialog`，
> 焦点管理由系统天然覆盖，本条保留为决策背景。
> **拒绝 roving tabindex（APG grid 模式）**的结论仍然有效：相似组是 ≤100 项的
> 静态列表，自然 Tab 顺序即可访问；grid 的复杂度远超收益，仅列表虚拟化/超数百项
> 再引入。组头使用语义化 button + 并列 checkbox，`aria-expanded` 表达展开态
> （SwiftUI 等价：`Button` + `Toggle` + `.accessibilityAddTraits(.isSelected)`）。

## ADR-019 Electron 菜单本地化：主进程 label 映射 + locale 解析链

- 菜单模板持有两套 label 映射（zh-CN/en），按当前 locale 重建；核心进程仍不持有
  通知类自然语言文案，错误码边界不变（与 ADR-016 一致）。
- 原生实现：`GatherAppDelegate.installMenu`（`GatherAppDelegate.swift:170-257`）
  经 `GatherLocalization.l` 构建菜单；`settings.set_language` → `languageChanged`
  通知 → `rebuildMenu()` 即时重建，菜单与界面由同一有效语言驱动，永不撕裂。
- 后果：新增菜单项须经本地化层登记；错误文案仍由界面层映射。

## ADR-020 语言来源优先级 + 菜单重建接线

- 语言优先级：持久化设置 `ui_language` 覆盖 > `--lang` 启动开关 > 系统语言；
  非 zh 前缀一律回退 en。非法覆盖值按未设置处理，不污染解析链。
- 语言切换 = 单命令双动作：`settings.set_language` 校验值（仅 zh-CN/en）、
  持久化 `ui_language`，并触发 `languageChanged` 通知：`GatherAppDelegate` 重建
  菜单（`installMenu`），`RootView` 经 `.id(languageVersion)` 重建外壳双语文案
  （整树重建的取舍见 ADR-025）。
- 语言选项标签（中文 / English）为固定品牌名，两语言文件同值，不随语言本地化：
  选项本身命名的是该语言，本地化会自指，故有意固定。
- 后果：新增语言选项须同步维护语言联合类型、校验与两语言表；错误文案仍由界面
  层映射（ADR-016/017 边界不变）。

---

## 发布门禁（未完成，非未实现代码）

1. **Asset 主读 Cutover**：必须在 dual-read/shadow-read 经历**至少一个完整稳定版本且
   不一致率为 0** 后执行；当前保留兼容桥符合 ADR-001~004 的迁移策略。
2. **Capture One 人工 Load-Metadata 矩阵**：自动化测试已通过 ExifTool 验证 Rating、
   Label、Urgency、Subject 与未知字段保留；RAW 人脸全流程与 XMP 写回内容校验可在
   本地自动跑通。但真实用户 Catalog 的人工 Load Metadata 矩阵仍须在正式发布前由
   测试人员执行。

---

# 原生迁移后的新增决策

## ADR-021 性能架构决议：挑片乐观更新、C1 状态胶囊单例化、Dashboard 增量轮询（已完成实现）

### 动机

原生版首轮审计暴露三类性能/体感问题：挑片快捷键连击与自动前进会因整页刷新丢失
位置；C1 状态胶囊在多个工作区页重复实现且生命周期管理易漏（轮询泄漏）；Dashboard
每 tick 对每个会话 N+1 查询且空闲期滞后 30s。以下三项决议已在 2026-08-12 完成并
闭环。

### 方案

1. **挑片乐观更新**（`gather-app/Culling/CullingView.swift` 的 `commit(patch:shouldAdvance:)`
   / `update(_:patch:nextPhotoId:)`）：
   决策命令（`culling.update` / `batch_update` / `decide_group`）为同进程直连的
   同步短事务，毫秒级落库；成功后**立即整页刷新**而非等待推送事件。乐观语义
   体现在：自动前进目标 `nextPhotoId` 在刷新前预置到 `currentPhotoId`（刷新期间
   位置不丢）；`commit` 以 `isLoading` 门控拒绝重入（连击不再排队风暴）；
   刷新后选择集按 `loadedPhotoIds` 交集保留（`loadPage`）。
2. **C1 状态胶囊单例化**（`Support/C1StatusCapsule.swift`）：
   `C1StatusCapsuleHost` 为自包含宿主，页面只需传入 sessionId + router：内部订阅
   进程级 `C1StatusService`（`C1StatusCapsuleHost`；12s 轮询在 `C1StatusCapsule.swift`）——按 sessionId 分键
   缓存状态、活跃订阅计数门控**单一 12s 轮询任务**（多页常驻不再每实例空转）；
   sessionId 变化时切换订阅（opacity 常驻页切换会话不显示旧状态）、
   `isActive=false` 时取消订阅（隐藏页不轮询）；`culling:sync-status` 事件
   即时刷新 + 轮询兜底。Gallery / Culling / ControlCenter / Similarity 等全部
   工作区页统一复用。
3. **Dashboard 增量轮询**（`Dashboard/DashboardViewModel.swift`）：
   双档轮询——有 queued/running 任务时**增量刷新**：jobs 每 2s 单查询（进度跟手）、
   sessions + N×workspace.status 降到 15s 档；空闲 30s 全量兜底（`autoRefreshTick`）；
   `applyJobEvent` 订阅 `jobs:progress`（视图层 1s 节流）逐帧**局部 patch** 任务
   中心行与索引卡片快照（毫秒级进度，替代整页拉取），仅终态帧整页刷新让权威计数
   落定。事件与轮询双通道，事件丢失不致静默。

### 风险与边界

- 挑片刷新仍为整页（500 条/页 + 辅助查询），大库下每次决策有固定成本；接受当前
  规模，若 10 万级滚动出现卡顿再引入局部 patch。
- 胶囊为进程级单例服务：会话状态在服务端聚合，按 sessionId 分键缓存；路由由首个
  订阅页面注入（各页共享同一 SessionCommandRouter 实例），一致性由服务端兜底；
  `statuses` 缓存随订阅生命周期刷新，隐藏页不触发任何查询。
- 轮询档位参数是运维性常量，改档位须同步 Dashboard 与控制中心，避免轮询风暴。

## ADR-022 遗留方案 1：侧栏/页签迁移 NavigationSplitView（暂缓）

### 动机

- 系统折叠语义：`NavigationSplitView` 提供侧栏收合（toolbar 按钮）、窗口缩放
  自适应与状态恢复，自绘侧栏需手工维护；
- ⌘1-9 窗口/栏切换快捷键与拖拽语义由系统导航组件天然支持；
- 系统侧栏在 macOS 26 下获得一致的折叠动画与 VoiceOver 导航体验。

### 现状

`RootView.swift` 的 `SidebarView`（`:469`）自绘侧栏，宽度可拖拽调整（160–320pt 钳制，
不再固定 200pt），配合 HStack + opacity 常驻页面切换；⌘0/菜单"隐藏侧栏"
经 `menuToggleSidebar` 通知手工切换（`GatherAppDelegate.swift:299`）。

### 方案（分期）

1. **P1**：以 `NavigationSplitView` 替换 HStack 外壳，`SidebarView` 内容原样
   放入 `sidebar` 列，页面区放入 `detail`；`RootNavigation` 保持不变，仅改装配层。
2. **P2**：工作区页签（`Support/SessionTabBar.swift`）保持自绘——split view 的
   列模型不适合密集页签，页签仍由 `sessionTabDestination` 驱动。
3. **P3**：验证 ⌘1-9、侧栏收合状态恢复、`gather://` 深链落点与拖拽导入。

### 风险

- **opacity 常驻与导航重建的冲突**：`NavigationSplitView` 的 detail 切换可能重建
  页面，破坏当前"常驻保状态"语义（滚动/选择/轮询），迁移需同步改造
  `isVisible` 门控；这是暂缓的主因。
- 回归面大：RootView 全部导航/窗口标题/无障碍逻辑都耦合当前装配方式。
- 收合状态持久化后，"隐藏侧栏"菜单项与系统状态的同步需要新接线。

## ADR-023 遗留方案 2：applicationShouldTerminate 优雅停机（原暂缓，2026-09 已实现）

### 动机

退出时若正在执行 `export.execute`（逐文件写盘）或 XMP 写回中途，进程终止可能留下
半写文件。现有 outbox/checkpoint 保证重启后可恢复，但缺少"退出前确认+让活跃任务
收尾"的用户可见闭环。

### 现状（2026-09-28：已实现）

原暂缓理由已不成立：`GatherAppDelegate.applicationShouldTerminate(_:)` 返回
`.terminateLater` 并等待 `onPrepareForTermination` 回调；`GatherApp.swift` 装配处把该
回调指向 `router.prepareForTermination()`（排空写回 + 关闭 SQLite）后再真正终止。
下方"方案"保留为实现设计记录。

### 方案

1. `GatherApp` 装配时把 `jobService`（或 router）注入 `GatherAppDelegate`。
2. 实现 `applicationShouldTerminate`：有活跃任务（running export/写回）时弹
   `NSAlert` 确认（"正在导出 N 张照片，确定退出？"），确认后
   `jobService.cancelScope` 逐范围取消并 `reply(toApplicationShouldTerminate: .terminateLater)`，
   短窗口（秒级）等待 drain 后 `reply(.terminateNow)`。
3. 无活跃任务时直接 `.terminateNow`，不改变现有退出路径。

### 风险

- 过度拦截破坏退出体验：必须只拦截 running 的导出/写回类任务，索引/分析类取消
  即弃；误拦由测试覆盖（注入 fake JobService 矩阵）。
- 写回已有 outbox 恢复，停机拦截是体验优化而非正确性修复——排期应低于
  数据正确性项；`reply(toApplicationShouldTerminate:)` 的双阶段时序需真机验证。

## ADR-024 遗留方案 3：相似度 recluster 任务化（原暂缓，2026-09 已实现）

### 动机

阈值重聚类在 2 万+ 条目下聚类耗时可观，当前实现**同步阻塞且无进度、无取消、
无任务记录**：失败只能看到错误码，无法重试，也与 `sim.analyze` 的任务化体验
不一致。

### 现状（2026-09-28：已实现）

`sim.recluster` 已任务化：`executeAsync` 创建 job（去重键
`similarity.recluster:<sessionId>:<threshold>:<minGroupSize>:<groupingMode>`，
checkpoint 标记 `operation=recluster`），与 `sim.analyze` 共用 `.similarityAnalyze`
executor 并按 checkpoint 分派；取消/进度/重试与 analyze 同链路。recluster 复用已有
hash，只做聚类 + 档位预计算，不重算哈希。

### 方案

- 复用 `sim.analyze` 的任务化链路：`executeAsync` 建 job（类型 `similarity.analyze`
  或独立 `similarity.recluster`）→ executor 内调用 `recluster` → checkpoint/
  dedupeKey/进度复用，UI 经现有 `jobs.list` 轮询展示相位与取消。
- 与 analyze 的互斥沿用会话级分析占用槽（`sessions.analysis_status` 列已删除，
  占用态由 `analysis_jobs` 派生；冲突时报 `SIM_ANALYSIS_RUNNING`）。
- 进度语义：recluster 无哈希阶段，相位单一（`similarity.cluster` → 档位预计算），
  进度可作不定进度或按聚类步长回传。

### 风险

- 任务化后"阈值切换即时生效"的既有体验（现有 UI 可能同步等待结果）需改异步
  采纳，涉及 Similarity 页面状态机改动。
- 与档位预计算并发写 `similarity_results` 的替换语义已有单写者约束，接线时不得
  绕过。

## ADR-025 遗留方案 4：语言切换整树重建取舍（原暂缓；现状改为子树重建，见现状节）

### 现状（2026-09-28：已收敛为子树重建）

`.id(languageVersion)` 现只挂在**无状态外壳子树**（`RootView.swift` 的侧栏
`SidebarView`）：`languageChanged` → `setAppLanguage` → `languageVersion += 1`。
页面子树的 `@State`/滚动位置/选择集保留；旧实现挂在 ZStack 根上会重建整棵树并丢
页面状态，已删除并在 `RootView.swift` 注释中记录该决策。

### 候选

`@Observable LanguageStore` + 文本级刷新：让文案经可观察语言对象读取，切换时仅
重渲染依赖文本的视图，页面状态保留。

### 暂缓理由

- 切换是低频一次性设置操作（Settings 选择器），重置的页面状态都有持久化源或
  可重新加载，代价可控；
- 文本级刷新需全量审计 `GatherLocalization.l` 调用点与 `String(format:)` 参数
  插值在视图缓存中的传播路径，成本高、收益低；
- 菜单重建（`installMenu`）与外壳文案是切换的两个显式副作用，当前单命令双动作
  已保证菜单/界面不撕裂。
- **重复加载防线**：`.id` 重建会重跑 opacity 常驻页的 `.task`——DashboardView /
  LibraryView 已加「已加载不重复查询」守卫（仅 `phase == .loading` 时执行
  `loadAll()`/`load()`；视图模型是 RootView 的 `@State`，重建后数据仍在）；
  Gallery/Similarity 已有 `loadIfNeeded`（`pages.isEmpty && phase == .loading`）
  守卫。PersonsView 的 `.task` 无守卫（语言切换会重复查询，已报告未改，超出
  审计文件范围）。
- **复审条件**：若未来引入常驻语言切换 UI（如 ⌘ 菜单快捷切换）或跨会话语言
  热切换需求，再按此方案重审。

## ADR-026 人脸推理演进：Vision 原生 + ONNX 质量门回退（已实现）

### 现状（已实现）

- **全 Vision 原生管线**：检测 `VNDetectFaceRectanglesRequest`（`Face/Encoder.swift`），
  编码 `VNGenerateImageFeaturePrintRequest` rev2（**768 维**）——`gather-core/
  Sources/GatherCore/Face/{Encoder,Inference}.swift`（原 `Detector.swift`、
  `Preprocessing.swift` 已删除，见 ADR-028）。
- 无模型资产、无下载/更新链路，`FaceProvider` 仅保留 `.vision/.cpu` 枚举语义
  （`Provider.swift:21-40`）；ONNX（SCRFD + ArcFace，512 维）时代模型文件与
  downloader/validator 已删除。
- **ONNX 为质量门回退**：`fallbackToOnnxEnabled` 开关（`Face/Provider.swift:64`）
  在 0.3c 质量对账（ARI/NMI）未过时打开，供上层决定是否仍走旧 ONNX 管线；
  当前真实数据集质量门按范围外跳过，故开关保持关闭。
- 首次启动按数据库写入 768 维 marker 并为既有工作区装配带 dedupe/checkpoint 的
  `face.analyze` 重跑任务（`GatherApp.prepareNativeEmbeddingRerun`），特征空间
  迁移不静默。
- **遗留不一致（2026-09-28）**：设置页仍保留旧 ONNX 模型下载入口
  （`Settings/SettingsView.swift` 的 `startModelDownload`/`ModelInstaller`，下载
  `buffalo_l.zip`），与“无模型资产、无下载链路”不符；属未接线遗留，待产品裁决
  （删除或接线），处置原则见 ADR-028。

### 事实依据

- macOS 26 SDK 公开 API **无 `VNGenerateFaceEmbeddingsRequest`**（tbd/头文件/
  swiftinterface 均无），人脸区域裁剪 + `VNGenerateImageFeaturePrintRequest`
  rev2 是系统唯一公开的通用特征编码路径；**Vision 不提供公开的 face-embedding
  API**，768 维为系统固定输出维度。
- 768 维与 ONNX 512 维特征空间不兼容 → 特征迁移必须全量重算，已由重跑任务装配
  承接（模型版本指纹沿用 `analysis_signature` 机制）。

### 可选演进

1. **ONNX → CoreML 折算**：若真实数据质量门证明 Vision 检测/编码不达标，可将
   原 ONNX 模型转 CoreML 作为一等提供方（而非外部回退），获得 ANE 加速；
2. **移除回退**：若质量门通过（或确认 Vision 质量可接受），删除
   `fallbackToOnnxEnabled` 开关与相关兼容代码，收敛为纯 Vision 单提供方。

### 风险

- 768 维 embedding 的内存/存储成本高于 512 维（约 +50% 向量表），10 万张脸量级
  需按基准复核；HNSW/LSH 索引维度参数已兼容任意维（对账门禁用 512 维合成数据，
  768 维 recall 需补基准）。
- 回退开关长期悬置会累积死代码与双路径测试成本：质量门是发布前置，建议随发布
  门禁一并裁决（保留或移除）。

## ADR-027 增量聚类：状态持久化 + 引擎语义复刻 + 定期全局收敛（已实现）

### 背景

ROADMAP 决策 B（1.3/1.6）：重分析此前按签名复用只重算变更照片的哈希，但聚类
仍是"全量重聚类"——2 万张新增 100 张也要重跑全部 O(n²) 距离比较。规模化
（10 万+）要求新增照片只在邻域内局部更新相似组，且结果必须与全量重聚类一致。

### 决策

1. **状态持久化**：新增 \`similarity_cluster_state\`（session_id, photo_id,
   hash_hex, component_index, group_seed）与 \`similarity_cluster_meta\`
   （参数指纹、member_count、version、incremental_updates、updated_at），
   迁移 v33 / schema 33。\`photo_id\` 不加 photos 外键：照片删除后的残留行是
   增量 diff 的"已移除"依据，由状态重写整体清理。
2. **算法**（\`Similarity/IncrementalClusterer.swift\`）：以状态哈希快照与当前
   条目集做 diff（新增 / 移除 / 哈希变化），新增项对全部现存条目做邻域探测
   （O(|added| × n)），只重算受增删改波及的连通分量，未受影响分量直接复用旧簇。
3. **语义复刻**：分维度复刻 \`ClusterEngine.recomputedBfs\` 的**度门控**规则
   （只有 degree + 1 >= minGroupSize 的节点才向外扩展，minGroupSize >= 4 时
   桥接节点度数不足会把一个连通分量拆成多簇），因此增量与全量在划分、组顺序
   （种子升序）、代表图（组内首元素 = 种子）与未成组集合上逐位一致；组内其余
   成员顺序为规范序，不承诺与全量 BFS 发现序相同。
4. **簇版本化与收敛**：每次状态重写 version + 1；增量路径要求状态参数指纹
   匹配且 incremental_updates < similarity_cluster_convergence_interval
   （默认 10），到期或参数变化即全量重聚类并清零计数。

### 权衡

- 选"复刻引擎语义"而非"重新定义成分量大小 >= minGroupSize"：后者更简单，但会
  与 ClusterEngine/TS 对账基线产生不可解释的差异（对账矩阵会直接判失败）。
- 选"状态表 + 组种子"而非"内存缓存"：聚类服务无状态、进程重启后仍要能增量，
  且组种子是复现组顺序与代表图的唯一依据。
- 未选择 LSH 候选桶：当前实现把邻域探测限制在新增项与全库之间，已满足验收；
  巨型单分量仍是 O(k²)，与全量同阶，列入后续优化而非本期阻塞。

### 后果

- 2 万张真实分布（大量连拍小簇）新增 100 张：增量 0.21s（预算 < 10s）；全量
  状态构建 27s（低于引擎全量聚类 35s，单趟位集图 + 内联邻居遍历）。
- 不变量由 1.6 对账矩阵门禁：随机 200 步增删改/重命名 × 5 组参数，逐步比对
  增量与全量，并对账状态自身（分量与簇逐位相等）。


---

## ADR-028 未接线资产删除裁决：删除而非接线（2026-09-28）

### 背景

原生迁移后遗留一批"已实现但生产零引用"的模块与类型。清理审计（"声明 × 引用计数"，
含插值感知与 `.strings` 转义感知）逐条核实后裁决**删除**，判据三条同时成立：

1. **生产零引用**：无实例化/无调用点（仅测试引用、注释引用不计；协议 witness、
   自由函数与动态分发单独复核，避免把活代码判死）；
2. **无协议 witness 依赖**：删除后不破坏任何被 `any Protocol` 消费的实现；
3. **有活替代实现或能力已撤销**：能力若仍属产品承诺则接线，否则连同文档承诺一并删除。

### 删除清单

| 对象 | 规模 | 判据 | 替代/去向 |
|---|---|---|---|
| `Watch/Coordinator.swift`（FSEvents 目录监听） | 351 行 | 生产零实例化；缺 `kFSEventStreamCreateFlagWatchRoot` 使 RootChanged 分支不可达 | 能力未接线，ROADMAP 的"已完成"叙事一并删除；需要时重新立项 |
| `Logging/Telemetry.swift` | 158 行 | 生产零调用；`GATHER_TELEMETRY` 无读取点 | 日志统一走 `GatherLogger` |
| `Face/Detector.swift`、`Face/Preprocessing.swift` | 322 行 | 生产零调用；`Encoder` 自建 Vision 请求 | 检测/编码合并入 `Face/Encoder.swift` |
| `ImageCache` 类（含 `SerialChain`） | 782→102 行 | 无生产实例化，唯一使用者是自身测试 | 缩略图走 `PhotoThumbnailView` 的 NSCache；同文件 `SHA256`/`UInt64.bigEndianBytes` 被生产消费，**文件保留** |
| `CaptureOneSyncState` 类、`C1BridgeProvider`/`DefaultC1BridgeProvider` | ~130 行 | 零实例化，仅两个纯函数被调用 | 保留 `aggregateSessionState` 等纯函数；机器状态由 `MetadataSyncCoordinator` 推导（ADR-015） |
| 零引用仓储/服务方法与类型（`CullingDecisionRepo`/`FaceRepo`/`PersonRepo`/`WritebackRepo`/`MetadataOutboxRepo`/`SessionRepo`/`MetadataCacheRepo`/`FaceMatcher`/`CosineHnswIndex` 等约 49 个方法、约 440 行） | — | 无调用点、无协议 witness | 清单以删除提交的 diff 为准；需要时按 git 历史恢复 |
| 陈旧产物：`release/Gather.app`、`.DS_Store`、空目录、孤儿夹具 | ~21 MB | 非源码 | 已由 `.gitignore`/构建脚本覆盖 |

### 后果

- **不改变线上契约**：被删对象均不在命令面、数据库 schema 或事件载荷中；命令面仍为
  118 条，`scripts/check-command-surface.sh` 与 `scripts/check-no-legacy.sh` 均通过；
- **同文件活代码保护**：`SHA256` 与 `aggregateSessionState` 属"同文件活代码"，不得随类
  删除——本条固化了此前两次误判的结论；
- **恢复路径**：以上对象均可从删除前的 git 历史恢复。未来需要目录监听或磁盘缓存时按
  新需求重新立项，而不是直接接线旧实现（旧实现自带已知缺陷：FSEvents 缺 WatchRoot、
  ImageCache 与主库双 SQLite 文件）。

## ADR-029 人脸管线算法改造：5 点对齐 + 质量核心点 + 歧义不猜 + 专用模型接缝（schema 34）

**背景**：对标 Immich（ArcFace 5 点 → 112×112）、PhotoPrism（YuNet 5 关键点、
`CLUSTER_CORE`/`CLUSTER_CORE_RETRY`、`MATCH_MARGIN`）与 digiKam 后确认：本仓骨架
（表结构、状态机、写回影响面预览、断点恢复）不弱于竞品，**差距在算法**——此前
embedding 直接按 bbox 裁剪（无关键点对齐）、质量分未计算、聚类没有"核心点"概念，
且匹配是"最近且 ≥ 阈值即绑定"（会把夹在两人之间的脸猜错）。
（对标详情与可学项见 `docs/reviews/face-clustering-benchmark.md`。）

**决策（第一轮，2026-09-28）**

1. **对齐**：`VNDetectFaceLandmarksRequest` 取 5 点（双眼中心、鼻尖、双嘴角），
   `FaceAligner` 做最小二乘相似变换（含尺度、不镜像）到 ArcFace 112×112 模板，
   在**对齐图**上取特征；关键点缺失回退 bbox 裁剪并标记 `aligned = false`。
2. **质量**：`FaceQuality.composite = 0.4·采集质量 + 0.4·尺寸分 + 0.2·滚转分`，
   采集体质量来自 `VNDetectFaceCaptureQualityRequest`（按 bbox IoU ≥ 0.5 配对，
   两次 perform 顺序不保证一致），落 `face_observations.quality/face_size_px/roll_degrees`。
3. **核心点**：`FaceClusterer.coreQualityFloor`（服务默认 0.35）——低于门槛的脸不能
   成为核心点/扩展簇，但仍会被吸收为边界点（**不丢数据**）；`retryMinSamples`
   （服务默认 2）做二遍聚类恢复被严格首遍漏掉的小簇。参数经
   `FaceClusterOptions` 注入，`disabled` 使既有调用语义逐位不变。
4. **歧义不猜**：`face_match_margin`（默认 0.01）——冠军与**人物级**亚军差距不足时
   不写建议。亚军必须按人物聚合（`FaceMatcher.bestScoresPerPerson`）：库里同一人
   常有多条样本，行级次优会把同一人的另一张脸误当竞争者。
5. **缓存失效**：嵌入规格进入 `analysis_signature`；聚类签名含 eps/minPts/质量门槛/
   二遍阈值。换模型或改门槛后旧结果自动判过期并重算，无需单独命令（对比 PhotoPrism
   的 `faces migrate`）。
6. **schema 34**：`face_observations` 追加 6 列（quality / face_size_px /
   roll_degrees / model_id / model_version / embedding_dim）；迁移幂等，旧行默认 0/''。
   快照 `docs/fixtures/schema.snapshot.json` 同步为 34（43 表不变）。

**决策（第二轮：把"接口留缝"改成"缝里真的有实现"，2026-09-28）**

7. **专用嵌入模型可插拔**（`Face/EmbeddingModel.swift`）：
   - `FaceEmbeddingProvider` 协议 + `FaceEmbeddingSpec`（modelId/modelVersion/
     dimension/weightHash/signature）；`VisionFeaturePrintEmbedder` 是默认实现，
     签名与旧 `FaceEncoder.embeddingSpec` **逐字一致**（老库不会因为这次改动被全量重算）。
   - `CoreMLFaceEmbedder`：支持 `.mlmodel`（运行时编译）与 `.mlmodelc`（已编译），
     要求 112×112 图像输入；输出维度 64…8192 且**恰好一个**输出能折叠成合法维度
     （多输出模型直接报错而不是猜，猜错会静默写入错向量）；推理输出长度与声明维度
     不符也报错。
   - 设置键 `face_embedding_model_path` / `face_embedding_model_version`；路径为空 →
     Vision。**禁止静默回退**：路径非空但不可加载时整批分析抛错，错误文案中文可读，
     且在设置页**保存即校验**（当场拒绝，不潜伏到分析时）。
   - 一次运行只创建**一个**嵌入实例，签名与推理由它同源（避免"签名算完后模型被替换"
     导致用 A 的签名标注 B 的向量）；系统噪声文件（`.DS_Store` 等）不计入指纹，否则一次
     Finder 浏览就会让整个库被判定过期重算。
   - 指纹：`FaceEmbeddingFingerprint.contentFingerprint` 递归哈希模型包内**所有文件**
     （`.mlmodelc` 的权重在包内独立文件里，原地替换不改目录 mtime——只哈希
     `model.mlmodel` 会让"换权重"逃过签名，两套向量空间混进同一列）。缓存键用递归
     stat 指纹（路径/大小/mtime 逐文件），内容指纹进 `analysis_signature`。
     `~`、相对路径、软链统一规范化后再做键与加载。
8. **增量聚类**（`face_incremental_clustering`，默认 1）：签名未变 + 已有簇 + 没有
   整体失败时，新照片只对**自己**跑聚类并挂到已有簇质心（按 cluster 的归一化质心
   取最相似且 ≥ eps，与亚军差距 < margin 则不挂）；已有簇 id、`matched_person_id`、
   角色绑定一律不动，只清理"观察已删/为 NULL"的幽灵成员行。挂不上的新脸彼此跑同参
   全量 DBSCAN 出新簇。**已知偏差**（写入测试）：全量会桥接合并的两人，增量不合并
   （夜间重聚类收敛）；质心 ≥ eps 不蕴含与任一成员 ≥ eps，可能多收全量判噪的脸；
   低质量新脸不被已有簇吸收；旧噪声不因增量转正。
9. **参数影响预估（试算）**（`Face/ClusteringImpact.swift`）：纯函数对比"当前参数 vs
   拟用参数"对同一批观测的划分差异，输出换簇数/簇数前后/噪声前后/变化簇数/新增消失
   簇数、`parametersChanged` 与 `partitionChanged`（二者分开，"参数变了但划分没变"
   只提示不重建）、`normalizedParameters`（与生产同刻度：floor 夹取、retry < 2 视为
   关）、`isSubsetOfLibrary`。**口径**：所有计数只对传入观测集成立，子集试算 ≠ 全库
   试算；规范簇 id（簇内最小 observationId）只在单次调用内稳定，不可持久化。
   **尚未接 UI**：需要扩命令面（当前 118 条为冻结基线）或走 app 内进程直调，
   且内核同步（n > 20000 才启用 LSH，此前是 O(n²)·d 精确分支）：2k 观测 debug 实测
   d128 ≈ 4.8s、d512 ≈ 19.4s（另一次未优化配置测得 28.5s），接 UI 前必须后台化 +
   可取消 + onProgress。
10. **准确率基线**（`Tests/.../FaceClusteringAccuracyTests.swift` +
    `Tests/.../FaceMarginDecisionTests.swift`）：
    - 合成标注集（自写 PRNG）：生成器自检（分离度前提 ⇒ 划分=真值，**只证明指标实现正确，
      不是性能证据**）、低质量但方向正确（门槛代价是"少成簇"而非"错聚"）、低质量桥接点
      （量化门槛造成的真实召回损失）；ARI 用"列联表"与"配对计数"两种等价实现互证，
      并对手算小例断言精确值（4/9、−0.5）——此前单实现的公式级错误把 0.4040 打成 0.7177，
      且变化方向与真值相反。
    - margin 曲线：**生产路径**（`fkw.analyze` → `face_clusters.matched_person_id`，49 查询 /
      6 人库），不是测试内复刻判定；出货默认 0.01 时错绑 3→2、拦下 2 条歧义，
      且同覆盖率下精度 0.9655→1.0000（不是靠"少绑定"冒充更准）。
    **边界（必须与结论一起读）**：合成 embedding 层 ≠ 真实识别精度；单 seed、无置信区间；
    全部计数只对传入观测集成立（子集试算会与全量分叉）；不能替代 Stretch 门与真实标注集
    复核。
11. **界面暴露**：`face_core_quality` / `face_core_retry_min_samples` /
    `face_match_margin` 三个滑杆 + 「人脸模型」分组（模型路径 / 版本标签 / 增量开关）；
    新键必须在 `SettingsService.getDefaults()` 注册否则 `set` 白名单会拒绝（有测试守）。
    界面**不显示置信度**（用户明确否决：这个数字对用户没有用），置信度只作为
    内部信号参与 margin 判定。

**兼容性**：`quality = 0` 视为"旧行 / 未提供质量"，聚类按不设限处理——否则升级后
旧库会被门槛整库判成噪声；所有新参数都有默认值，新增字段均带默认值；Vision 路径的
签名与第一轮逐字一致，老库不需要重算。

**已知限制**：
- FeaturePrint 是通用图像特征，与 ArcFace/SFace 特征空间不兼容（换模型必须全量重算，
  由签名自动触发）；
- `coreQualityFloor` 过高会"溶解"以低质量脸为唯一桥点的连通分量（默认 0.35 按
  96px≈0.9 / 30px≈0.6 / 明显模糊或侧倾 <0.3 标定）；
- **CoreML 路径无真实模型夹具，测试覆盖为 0**（纯函数、指纹、strides/fp16 读取、
  工厂错误与缓存失效有覆盖；`MLModel` 加载/推理未覆盖）。首次接入真实模型必须人工确认：
  维度、是否已归一化、多输出模型的输出名。
- 增量聚类与全量在桥接场景下结果不同（见决策 8 的已知偏差）；
- 设置页保存模型路径只做**廉价**校验（展开 `~`/解析软链/存在性/扩展名），不验证"能否真正加载"：`.mlmodelc` 包缺内部文件、输出形状不支持、多输出歧义都要等下一次分析才报（代价换来的是不阻塞主线程——256 MiB 模型加载+整包哈希实测 48.4s，跑在 @MainActor 上会假死）；
- 试算未接 UI（见决策 9）；
- 本机测试进程无法解码 NEF（ImageIO RAW 解码受限），真实素材验证用
  `GATHER_FACE_FIXTURE=<jpg> swift test --filter FaceRealPhotoPipelineTests` 走 JPEG 路径；
- 模型缓存键是**递归 stat 指纹**而不是内容：同尺寸 + 同 mtime（`touch -r`）的替换不会被发现，进程内继续用已加载的旧模型；内容指纹仍决定签名，且一次运行只用一个实例（签名与推理同源）。选 stat 是因为内容哈希代价高（256 MiB ≈ 48s/Debug）；
- 只要一张照片里有**任何**一张脸编码失败，这张照片就不写 `analysis_state` ⇒ 每次运行都会重新处理它（永久编不出来的脸会让该照片长期重试；这是"绝不静默丢数据"的代价，失败数会出现在 run 结果与 UI 警示里）；
- 多输出模型只有"分类头名字（logits/softmax/fc/head…）"能被自动排除；其他多向量导出仍报歧义（**没有**"指定输出名"的设置项，需重导出或改名）。



## ADR-030：原生离线身份模型与人工约束分离（2026-10-03）

状态：已实施。替代 ADR-029 中“默认 Vision 通用特征”“无真实 CoreML 模型推理验证”“NEF 未验证”等当时边界；其余历史记录保留。

生产默认使用固定来源、Apache-2.0 许可的 SFace CoreML FP32 模型，Vision 负责检测/关键点/采集质量。模型规格隔离人物向量空间。人工身份与拒绝记录存为模型无关的持久事实，观测、聚类和人物向量作为可重建投影。模型切换在准备成功后以事务发布，任何失败保留旧结果。相似度门槛采用本地素材对照的保守起点 0.65，既有自定义值不覆盖。

[完整实施依据、对照数据和验证边界](reviews/face-identity-replacement-2026-10-03.md)。

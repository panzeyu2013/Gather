# Gather 架构决策记录

> 本文件保存从已归档执行计划（CORE_RELIABILITY_EXECUTION_PLAN /
> CULLING_WORKBENCH_DESIGN_AND_EXECUTION，已于 `9226061` 删除）中恢复的
> **仍具规范性的决策与门禁**。实现细节以代码为准，本文只记录"为什么"与
> "何时允许改变"。
> 2026-08-12 修订：合并 Electron→原生迁移（原 `NATIVE-DEVELOPMENT-ANALYSIS.md`
> 已归档删除）后，**本文件底部新增 ADR-021~026**：性能架构决议（已实现）与
> 四项遗留方案、人脸推理演进。原 ADR-001~020 中引用的 Electron 时代实现路径
> 已随迁移失效，语义与不变量不变，**原生对应实现位置见下表**（未列条目以
> `desktop/native/gather-core` / `gather-app` 代码为准）。

**原实现路径 → 原生实现位置对照**

| ADR | Electron 时代路径（已删除） | 原生实现（迁移后） |
|---|---|---|
| 005/006 | `desktop/src/main/db/migrations.ts`、`tests/unit/...` | `gather-core/Sources/GatherCore/Database/Migrations.swift`、`Schema.swift`；快照校验 `Tests/GatherCoreTests/Database/MigrationTests.swift`（`docs/fixtures/schema.snapshot.json` 41 表） |
| 007 | `services/image/disk-cache.ts` | `gather-core/Sources/GatherCore/Database/ImageCache.swift` |
| 012/013 | `services/workspace/workspace-status.service.ts` | `gather-core/Sources/GatherCore/Services/WorkspaceStatusService.swift` |
| 014 | `ipc/session.ipc.ts`、`services/session/session.service.ts` | `gather-core/Sources/GatherCore/Services/SessionService.swift` |
| 015 | `services/capture-one/sync-state.ts` | `gather-core/Sources/GatherCore/Services/CaptureOneSyncState.swift` |
| 016/019/020 | `renderer/locales/`（i18next）、`main/menu.ts`、`main/locale.ts` | `gather-app/Sources/GatherApp/Support/GatherLocalization.swift` + `Resources/{en,zh-Hans}.lproj`；`Host/GatherAppDelegate.swift`（`installMenu` 两语言重建，`languageChanged` 驱动） |
| 017 | `packages/shared/src/errors.ts` | `gather-core` 错误枚举（错误码语义不变）+ `GatherLocalization.errorText`（156 项映射） |
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
  （41 表全对）；任何表级 schema 变更必须同步更新该快照。
- 索引的"单一规范定义"由迁移实现强制（迁移块内不得重复索引 DDL）。

---

## ADR-007 磁盘缓存元数据：SQLite + 惰性淘汰

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
- 实现以 `gather-core/Sources/GatherCore/Database/ImageCache.swift` 为准；修改持久化
  格式必须保留损坏/只读降级与重启对账（`readdir` 差集 + 仅对孤儿文件 stat）语义。

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

## ADR-015 CaptureOneSyncState：会话级聚合 + `reload_acked_at` 重启重推导

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

1. **挑片乐观更新**（`gather-app/Culling/CullingView.swift:599-649`）：
   决策命令（`culling.update` / `batch_update` / `decide_group`）为同进程直连的
   同步短事务，毫秒级落库；成功后**立即整页刷新**而非等待推送事件。乐观语义
   体现在：自动前进目标 `nextPhotoId` 在刷新前预置到 `currentPhotoId`（刷新期间
   位置不丢）；`commit` 以 `isLoading` 门控拒绝重入（连击不再排队风暴）；
   刷新后选择集按 `loadedPhotoIds` 交集保留（`loadPage`，`CullingView.swift:428-448`）。
2. **C1 状态胶囊单例化**（`Support/C1StatusCapsule.swift`）：
   `C1StatusCapsuleHost` 为自包含宿主，页面只需传入 sessionId + router：内部订阅
   进程级 `C1StatusService`（`C1StatusCapsule.swift:11-98`）——按 sessionId 分键
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

`RootView.swift:432-570`（`SidebarView`）自绘 **200pt 固定宽度**侧栏
（`frame(width: 200)`），配合 HStack + opacity 常驻页面切换；⌘0/菜单"隐藏侧栏"
经 `menuToggleSidebar` 通知手工切换（`GatherAppDelegate.swift:292-296`）。

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

## ADR-023 遗留方案 2：applicationShouldTerminate 优雅停机（暂缓）

### 动机

退出时若正在执行 `export.execute`（逐文件写盘）或 XMP 写回中途，进程终止可能留下
半写文件。现有 outbox/checkpoint 保证重启后可恢复，但缺少"退出前确认+让活跃任务
收尾"的用户可见闭环。

### 现状

`GatherAppDelegate.swift`（`:110-335`）**无 jobService 引用**：装配只发生在
`GatherApp.swift:73-80`（`router.jobService.start()`、`GatherEventCenter.wire`、
`DashboardViewModel` 注入）；退出路径 `NSApp.terminate`（`GatherAppDelegate.swift:332-334`）
直接终止，无拦截。

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

## ADR-024 遗留方案 3：相似度 recluster 任务化（暂缓）

### 动机

阈值重聚类在 2 万+ 条目下聚类耗时可观，当前实现**同步阻塞且无进度、无取消、
无任务记录**：失败只能看到错误码，无法重试，也与 `sim.analyze` 的任务化体验
不一致。

### 现状

`sim.recluster` 路由直接 `Task { await similarityService.recluster(...) }`
（`SessionCommandRouter.swift:1731-1760`），不创建 JobService job；recluster
复用已有 hash（`SimilarityService.swift:572-609`），只做聚类 + 档位预计算，不重算
哈希。

### 方案

- 复用 `sim.analyze` 的任务化链路：`executeAsync` 建 job（类型 `similarity.analyze`
  或独立 `similarity.recluster`）→ executor 内调用 `recluster` → checkpoint/
  dedupeKey/进度复用，UI 经现有 `jobs.list` 轮询展示相位与取消。
- 与 analyze 的互斥沿用 `analysis_status` 保护（analyze 占用时 recluster 报
  `SIM_ANALYSIS_RUNNING`）。
- 进度语义：recluster 无哈希阶段，相位单一（`similarity.cluster` → 档位预计算），
  进度可作不定进度或按聚类步长回传。

### 风险

- 任务化后"阈值切换即时生效"的既有体验（现有 UI 可能同步等待结果）需改异步
  采纳，涉及 Similarity 页面状态机改动。
- 与档位预计算并发写 `similarity_results` 的替换语义已有单写者约束，接线时不得
  绕过。

## ADR-025 遗留方案 4：语言切换整树重建取舍（暂缓，记录取舍）

### 现状

语言切换经 `.id(languageVersion)` 整树重建（`RootView.swift:242-248`）：
`languageChanged` 通知 → `setAppLanguage` → `languageVersion += 1`，整棵视图树
按新语言重渲染。**正确但重置页面本地状态**（滚动位置、选择集、展开态、轮询
相位显示）。

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

- **全 Vision 原生管线**：检测 `VNDetectFaceRectanglesRequest`，编码
  `VNGenerateImageFeaturePrintRequest` rev2（**768 维**）——`gather-core/
  Sources/GatherCore/Face/{Detector,Encoder,Inference}.swift`。
- 无模型资产、无下载/更新链路，`FaceProvider` 仅保留 `.vision/.cpu` 枚举语义
  （`Provider.swift:21-40`）；ONNX（SCRFD + ArcFace，512 维）时代模型文件与
  downloader/validator 已删除。
- **ONNX 为质量门回退**：`fallbackToOnnxEnabled` 开关（`Provider.swift:46-60`）
  在 0.3c 质量对账（ARI/NMI）未过时打开，供上层决定是否仍走旧 ONNX 管线；
  当前真实数据集质量门按范围外跳过，故开关保持关闭。
- 首次启动按数据库写入 768 维 marker 并为既有工作区装配带 dedupe/checkpoint 的
  `face.analyze` 重跑任务（`GatherApp.prepareNativeEmbeddingRerun`），特征空间
  迁移不静默。

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


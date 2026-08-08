# Gather Architecture Decision Records

> 本文件保存从已归档执行计划（CORE_RELIABILITY_EXECUTION_PLAN /
> CULLING_WORKBENCH_DESIGN_AND_EXECUTION，已于 `9226061` 删除）中恢复的
> **仍具规范性的决策与门禁**。实现细节以代码为准，本文只记录"为什么"与
> "何时允许改变"。

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

已实现于 `desktop/src/main/db/migrations.ts`：

- 迁移前：检查可用磁盘空间（`max(64 MB, 源大小×2)`）→ `wal_checkpoint(TRUNCATE)` →
  用 **SQLite backup API**（非直接复制活动 db）创建带 schema version 与时间戳的备份 →
  校验备份可打开（`integrity_check`）。
- 迁移失败：不写 down-migration；关闭数据库、保留失败副本、从迁移前备份恢复；
  不删除任何用户照片或 XMP。
- 迁移后：`foreign_key_check` + 关键表列不变量断言 + `CURRENT_SCHEMA_VERSION` 校验。

## ADR-006 Schema 快照位置与用途

- 当前 schema 快照：`docs/fixtures/schema.snapshot.json`（记录表名集合）。
- 由 `tests/unit/services/core-reliability-baseline.test.ts` 校验 `SCHEMA_SQL` 与其一致；
  任何表级 schema 变更必须同步更新该快照。
- 每次迁移运行末尾无条件执行 `INDEX_SQL`；索引的"单一规范定义"由
  `tests/unit/shared/architecture-invariants.test.ts` 强制（迁移块内不得重复索引 DDL）。

---

## ADR-007 磁盘缓存元数据：SQLite + 惰性淘汰

- 缩略图磁盘缓存元数据（hash → lastAccess/createdAt/accessCount/fileSize）持久化在
  `cache-meta.db`（better-sqlite3 + WAL），替代全量 `JSON.stringify(cache-meta.json)`：
  热路径 `onAccess`/`onSet` 纯内存 + debounce 批量 upsert，主线程无同步序列化。
- 淘汰候选由每策略 SQLite 索引排序窗口提供（`ORDER BY <policy> ASC, hash ASC LIMIT k`，
  O(log n + k)），再与脏集合（值尚未落盘、可能与持久化行不一致的条目）合并、按内存
  当前值重排取 k 个——与全量扫描严格等价，但主线程不再 O(n) 遍历；淘汰前先等待在途
  持久化队列，避免 SQL 旧视图导致错误淘汰。候选按 policy 值升序
  （LRU=lastAccess / FIFO=createdAt / LFU=accessCount）。
- 降级不变量：DB 损坏 → 改名 `.corrupt-<ts>` 重建空库；仍失败（只读目录）→
  `:memory:` 纯内存模式；`waitUntilReady` 永不 reject；退出前 `flush()` 落盘。
- 实现以 `desktop/src/main/services/image/disk-cache.ts` 为准；修改持久化格式必须
  保留损坏/只读降级与重启对账（`readdir` 差集 + 仅对孤儿文件 stat）语义。

## ADR-008 Culling 分页按逻辑资产分组（不变量）

- 分页（`culling.list_page`）以逻辑资产为最小单元：`COALESCE(asset_id, id)` 分组、
  组内 `MIN(rowid)` 作 keyset 游标、组内全行一次加载——RAW/JPEG 变体**永不跨页**，
  跨页遍历每个资产恰好出现一次（回退为按物理行分页将再次引入重复条目，禁止）。
- `total` 一律按逻辑资产计数；过滤谓词下推到**首选变体**（RAW 扩展名优先，否则
  `rowid` 最小者，与 `assembleAssets` 的 JS 首选逻辑共用同一扩展名常量）。
- 游标对渲染层**不透明**：renderer 只回传 `nextRowId`，不得解析其含义。
- 与 ADR-001/002 的 Asset 语义联动：任一物理行匹配谓词即入页会导致 total 虚高与
  空页（仅非首选 JPEG 命中时），故 SQL 谓词必须限定首选行。

## ADR-009 相似度"主档"与预计算档位

- `similarity_results` 可存多档结果：分析/重聚类的"主档" + 预计算邻居阈值
  （T±4/T±8）的档位行；档位行在 `stats_json` 内标记 `"precomputed": true`。
- **"最新结果"的判定**（`getLatest`、culling 相似组 SQL、质量相对排名）必须排除
  `precomputed` 行——否则档位插入顺序（主行先、档位后）会让 `MAX(id)` 选中档位，
  造成相似组浏览与相对排名错乱。该不变量由 `reuse-and-tiers.test.ts` 与
  `culling-page.test.ts` 强制。
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

- 新增 `face-kw/hnsw-index.ts`（`CosineHnswIndex`）：内存 HNSW（M=16/Mmax0=32/
  efConstruction=32/efSearch=32），向量行主序共享 Float32Array + 逐节点分层邻接表，
  距离为余弦点积（单位向量前提）。与 LSH（`lsh-index.ts`）互补：LSH 全量
  `build()`（O(n·bits·dim)），适合一次性构建；HNSW 增量 `insert()` 只触达邻域，
  适合"新增少量照片"的持续更新场景。
- 连接与裁剪使用论文 Algorithm 4 的多样性启发式（候选按距离序 + 与已选邻居的
  相似度拒绝），防止增量插入把簇间桥剪光导致图退化；候选到中心点的距离在排序前
  一次性缓存，成对相似度按需计算。
- 质量门禁（`hnsw-recall.test.ts`）：保留集查询（与索引同分布但未索引的
  512 维 8 簇合成数据）recall@1 ≥ 0.9（查询 ≈0.3ms/次，构建 ≈3.5ms/向量——
  全量构建应由后台任务承载，不承诺构建延迟；M=16/mMax0=64 下增量插入召回波动
  实测 −0.008）。
- 边界：本期只交付"索引 + 查询"组件；向量持久化与模型版本指纹沿用
  `face_observations`/`analysis_signature` 既有机制，消费方接线（聚类候选生成、
  跨 session 重识别）在 Phase 2/3 排期，不在此引入向量数据库选型。

---

## ADR-012 分析过期检测：`analysis_runs` + `sessions.index_seq`

已实现于 `desktop/src/main/db/migrations.ts`（v30）与
`services/workspace/workspace-status.service.ts`：

- 过期判定 `stale = 最近一次 ok run 的 index_seq < session.index_seq`；`index_seq`
  只在索引提交点自增（`index.service.ts` 扫描事务后），相似度/人脸分析开始时读
  事务快照写入 run 记录（`analysis_runs`）。
- **不采用照片数 COUNT 比较**：删除照片时 COUNT 变小但分析结果并未过期，会产生
  假阳性重算；`index_seq` 只随索引提交自增，语义精确（design_improvements.md
  1.4.2 判定记录 ✅ 落地）。
- 只取最近一次 `status='ok'` 的 run 参与判定，失败/取消的 run 不掩盖过期。
- 并发约束：`index_seq` 自增走单事务；分析读取用事务快照。
- 后果：新增照片 → Inbox 出现 `analysis_stale`；删图不误报；阶段判定
  `indexed` 以索引 job 成功记录为准。

## ADR-013 WorkspaceStatusService：只读聚合 + 离线复核 TTL

已实现于 `desktop/src/main/services/workspace/workspace-status.service.ts`，
IPC `workspace.status`：

- 不引入新权威数据源：全部计数从 photos / analysis_runs / metadata_outbox /
  jobs 派生，是 CQRS 式只读模型（1.3 第一性原理落地）。
- 推荐动作 = **固定优先级序列表 + 布尔门控**（scan_incomplete → xmp_conflict →
  analysis_stale → job_failed → 推进流程），拒绝规则引擎（1.4.3 ✂️ 落地）。
- 离线照片复核 **TTL ≥ 5 分钟**（`OFFLINE_PHOTOS_TTL_MS = 5 * 60_000`）：
  `photos.status='missing'` 是惰性检测，Inbox 刷新不得全盘 stat，否则退化为
  性能陷阱（1.4.5 ➕ 落地）。
- 刷新策略：轮询兜底 30s（索引活跃期 3s）+ 复用现有推送事件（`jobs:progress`
  终态、`culling:sync-status`），不新增 push 通道。
- 后果：离线计数最多滞后 TTL 5 分钟；Inbox 查询为常量级开销。

## ADR-014 一跳化导入：路径数组不跨 IPC

已实现于 `session.create_from_directory`（`desktop/src/main/ipc/session.ipc.ts`
+ `services/session/session.service.ts`）：

- 50k 上限是**内存/IPC 载荷约束而非产品上限**（结构化克隆 5 万条路径的开销）；
  主进程内流式遍历 + 分批落库后，上限在数据层消失，仅保留为 UI 计数预览上限
  （3.2 根因修复落地）。
- `app:scan-directory` 保留仅用于 UI 计数预览，返回
  `ScanResult { files, truncated, scannedTotal, limit }`（`scannedTotal` 持续
  累加、`truncated = scannedTotal > files.length`），截断标记落
  `sessions.truncated_import`（迁移 v29）。
- 后果：`session.create`（文件列表，兼容）与 `session.create_from_directory`
  （路径一跳）双入口并存；UI 计数预览仍受 50k 约束，数据导入不受。

## ADR-015 CaptureOneSyncState：会话级聚合 + `reload_acked_at` 重启重推导

已实现于 `desktop/src/main/services/capture-one/sync-state.ts`；
`sessions.reload_acked_at` 为迁移 v31：

- 机器状态在内存、易失：重启后从 **outbox 行状态 + `reload_acked_at` 重推导**，
  行是持久真相源、机器状态是派生值，不落库整个状态机（2.3.3 ➕ 落地）。
- 会话级聚合规则确定性：`conflict > failed > syncing(pending/writing) >
  safeToCleanup`；未知状态按保守处理，绝不声称 safeToCleanup（2.3.2 ➕ 落地）。
- `reload_acked_at` **只在 reloadMetadata() 成功后写入**，保持"失败即回退、
  不清理"策略；`safeToCleanup` 门控（reload 成功 + 延迟窗口）与 XMP 双写领域
  模型同构（2.3.1 ✅ 落地）。
- 协调器每次 emitSummary 后重推导会话状态并记录状态转换日志（`main/index.ts`
  事件接线、`sync-state.ts` 转换日志），状态机转换全部可观测。
- 后果：重启后跨会话恢复 `safeToCleanup` 而不误清理；清理动作永远不早于 C1
  确认读取。

## ADR-016 i18n：i18next + 类型化 key + 主进程只抛错误码

已实现于 `desktop/src/renderer/locales/`（i18next + react-i18next，
`TranslationKey` 由 zh-CN.json 推导）；P1 页面级迁移完成（697 处 `t()`、
1063 key/语言，术语表冻结于 docs/i18n-glossary.md）：

- 边界分工：主进程**只抛错误码**（`GATHER_ERROR_CODES`，
  packages/shared/src/errors.ts）与**阶段码**（`progress.*`），渲染层统一映射
  文案（`translateError` / `translatePhase`）；事件推送负载同样代码化
  （4.4.2 ➕ 落地），禁止主进程返回拼接文案。
- 拒绝 AST codemod（生成的无上下文 key 仍需全量人工复查，省不了审校时间）与
  saveMissing/locize（无在线后端需求，会污染资源文件）——4.3/4.4.3 ✂️ 落地。
- 语言来源：`navigator.language` 检测（zh → zh-CN，其余 en），fallback 到 en。
- 后果：新增文案必须同时落两语言文件并过术语表；主进程文案以错误码形式跨 IPC。
- P2：eslint 无硬编码守护（`gather/no-hardcoded-text`，见 ADR-019）与 Electron
  菜单本地化（`main/menu.ts`）已落地；语言切换 UI（设置覆盖 + 菜单重建）
  已落地，见 ADR-020。

## ADR-017 错误码化的表面边界与文档例外

- 错误码化覆盖两个表面：IPC 返回值（`C1_NOT_RUNNING` / `C1_NO_DOCUMENT` /
  `C1_NOT_AUTHORIZED` / `C1_SCRIPT_FAILED` / `SCAN_INVALID_DIR` /
  `SCAN_READ_FAILED`）与事件负载阶段码（`progress.<phase>` 键）。
- 已记录例外：导出报告（`desktop/src/main/services/export/report.service.ts`
  生成的 markdown 文档，如"# 人物""# 关键词"）是**文档内容而非 UI 文案**，
  不纳入 i18n 与错误码体系；UI 文案（按钮、标签、toast、错误提示）一律走 i18n。
- 后果："主进程无自然语言文案"有明确判据（文档内容豁免）；新增错误先加码、
  再在渲染层补映射，不得回退到拼接文案。

## ADR-018 Dialog 无障碍：自研 APG 焦点管理（portal + inert），拒绝 roving tabindex

已实现于 `desktop/src/renderer/components/Dialog/Dialog.tsx`：

- 自研实现对齐 W3C APG Dialog 模式：打开时记录触发元素并按内容聚焦
  （`initialFocus` 支持不可逆操作聚焦"最不具破坏性动作"）、Tab 循环焦点陷阱、
  关闭后焦点恢复、`aria-labelledby` 引用可见标题、`descriptionId` 仅在简单描述
  时提供；portal 挂载 + 打开时给背景容器加 `inert`（5.1 ✅ 落地）。
- **拒绝 roving tabindex（APG grid 模式）**：相似组是 ≤100 项的静态列表，自然
  Tab 顺序即可访问；grid 的复杂度远超收益，仅列表虚拟化/超数百项再引入
  （5.2 ✂️ 落地）。组头改为语义化 button + 并列 checkbox，`aria-expanded`
  表达展开态。
- 原生 `<dialog>.showModal()` 作为可选替代评估后未采纳，保持条件渲染 + 自研
  （5.1 P1 可选项）。
- 回归：jest-axe 组件测试（`tests/unit/renderer/a11y-dialog.test.tsx` /
  `a11y-similarity.test.tsx` / `a11y-dashboard.test.tsx`，含焦点陷阱边界用例）；
  对比度修复仅改全局 token（docs/a11y-audit.md §1.2）。

## ADR-019 Electron 菜单本地化：主进程 label 映射 + locale 解析链

已实现于 `desktop/src/main/menu.ts`（P2，工作区落地未提交）：

- 菜单模板在**主进程**持有两套 label 映射（zh-CN/en），按当前 locale 重建并
  `Menu.setApplicationMenu`；主进程仍不持有通知类自然语言文案，错误码边界不变
  （与 ADR-016 一致）。
- locale 解析链：`--lang`（Chromium/Electron 开关）优先，否则 `app.getLocale()`；
  非 zh 前缀一律回退 en。Electron/Chromium 同样消费 `--lang`，应用菜单与
  Chromium 内部对话框语言保持一致。
- 未来语言切换：更新 locale 后调用 `rebuildMenu()` 即可，无其他接线；当前
  **有意不提供语言切换 UI**（menu.ts 注释，P1 scope）。
  **（已被 ADR-020 取代：语言切换 UI 已随 i18n P2 收尾落地，见 Settings
  选择器 + `settings.set_language` + `setAppLocale`，本句作废。）**
- 静态守护：eslint 规则 `gather/no-hardcoded-text`
  （`desktop/eslint/no-hardcoded-text.cjs`）禁止渲染层 JSX 文本节点与
  `aria-label` 出现非 i18n 字符串。
- 后果：新增菜单项须同时落两语言 label 映射与术语表；渲染层文案仍走 i18next。

## ADR-020 语言来源优先级 + 菜单重建接线（i18n P2 收尾）

已实现于 `desktop/src/main/locale.ts`、`desktop/src/main/menu.ts`、
`desktop/src/main/ipc/settings.ipc.ts` 与 `desktop/src/renderer/locales/`：

- 语言优先级（design_improvements.md 4.2）：持久化设置 `ui_language`
  （app_settings）覆盖 > `--lang` 启动开关 > `app.getLocale()`；非 zh 前缀
  一律回退 en。纯函数 `resolveEffectiveLocale(langSwitch, systemLocale,
  uiLanguage)`（`main/locale.ts`，无 electron 依赖，单元测试覆盖整条链）。
  非法覆盖值按未设置处理，不污染解析链。
- 语言切换 = 单命令双动作：`settings.set_language` 校验值（仅
  zh-CN/en）、持久化 `ui_language`，并调用 `menu.ts` 新增的 `setAppLocale()`
  立即重建菜单（`rebuildMenu()` 原导出不变）；渲染层随后 `initI18n(language)`
  使 UI 文案即时切换。菜单与渲染层由同一有效 locale 驱动，永不撕裂。
- 渲染层启动 bootstrap（`main.tsx`）：`app:get-app-locale`（新直连 IPC，
  c1:health 同风格）→ `initI18n(effective)` → 首次 render；IPC 失败回退
  `detectLanguage()`（navigator 检测，模块级默认不变，纯函数 t() 仍可用）。
  首帧渲染前 i18n 已落定，避免 locale flash。
- 语言选项标签（中文 / English）为固定品牌名，两语言文件同值，不随语言
  本地化：选项本身命名的是该语言，本地化会自指（"中文"→"Chinese" 反而
  更长），故有意固定。
- 后果：新增语言选项须同步维护 `AppLocale` 联合类型、preload 白名单与
  两语言文件；错误文案仍由渲染层映射（ADR-016/017 边界不变），主进程
  只负责 locale 决议与菜单 label。

---

## 发布门禁（未完成，非未实现代码）

1. **Asset 主读 Cutover**：必须在 dual-read/shadow-read 经历**至少一个完整稳定版本且
   不一致率为 0** 后执行；当前保留兼容桥符合 ADR-001~004 的迁移策略。
2. **Capture One 人工 Load-Metadata 矩阵**：自动测试已通过 ExifTool 验证 Rating、
   Label、Urgency、Subject 与未知字段保留；`tests/e2e/face-workflow.spec.ts` 现可本地
   自动跑通 RAW 人脸全流程并校验 XMP 写回内容（素材见 `tests/fixtures/local-fixtures.md`）。
   但真实用户 Catalog 的人工 Load Metadata 矩阵仍须在正式发布前由测试人员执行。

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

- 当前 schema 快照：`docs/fixtures/schema-v27.snapshot.json`（记录表名集合）。
- 由 `tests/unit/services/core-reliability-baseline.test.ts` 校验 `SCHEMA_SQL` 与其一致；
  任何表级 schema 变更必须同步更新该快照。
- 每次迁移运行末尾无条件执行 `INDEX_SQL`；索引的"单一规范定义"由
  `tests/unit/shared/architecture-invariants.test.ts` 强制（迁移块内不得重复索引 DDL）。

---

## ADR-007 磁盘缓存元数据：SQLite + 惰性淘汰

- 缩略图磁盘缓存元数据（hash → lastAccess/createdAt/accessCount/fileSize）持久化在
  `cache-meta.db`（better-sqlite3 + WAL），替代全量 `JSON.stringify(cache-meta.json)`：
  热路径 `onAccess`/`onSet` 纯内存 + debounce 批量 upsert，主线程无同步序列化。
- 淘汰采用"有界堆保留 k 个最差候选"的惰性扫描（O(n log k)），只在超预算时触发；
  淘汰候选按 policy 值升序（LRU=lastAccess / FIFO=createdAt / LFU=accessCount）。
- 降级不变量：DB 损坏 → 改名 `.corrupt-<ts>` 重建空库；仍失败（只读目录）→
  `:memory:` 纯内存模式；`waitUntilReady` 永不 reject；退出前 `flush()` 落盘。
- 实现以 `desktop/src/main/services/image/disk-cache.ts` 为准；修改持久化格式必须
  保留损坏/只读降级与重启对账（`readdir` + stat）语义。

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

---

## 发布门禁（未完成，非未实现代码）

1. **Asset 主读 Cutover**：必须在 dual-read/shadow-read 经历**至少一个完整稳定版本且
   不一致率为 0** 后执行；当前保留兼容桥符合 ADR-001~004 的迁移策略。
2. **Capture One 人工 Load-Metadata 矩阵**：自动测试已通过 ExifTool 验证 Rating、
   Label、Urgency、Subject 与未知字段保留；`tests/e2e/face-workflow.spec.ts` 现可本地
   自动跑通 RAW 人脸全流程并校验 XMP 写回内容（素材见 `tests/fixtures/local-fixtures.md`）。
   但真实用户 Catalog 的人工 Load Metadata 矩阵仍须在正式发布前由测试人员执行。

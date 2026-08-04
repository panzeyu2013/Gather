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

## 发布门禁（未完成，非未实现代码）

1. **Asset 主读 Cutover**：必须在 dual-read/shadow-read 经历**至少一个完整稳定版本且
   不一致率为 0** 后执行；当前保留兼容桥符合 ADR-001~004 的迁移策略。
2. **Capture One 人工 Load-Metadata 矩阵**：自动测试已通过 ExifTool 验证 Rating、
   Label、Urgency、Subject 与未知字段保留；`tests/e2e/face-workflow.spec.ts` 现可本地
   自动跑通 RAW 人脸全流程并校验 XMP 写回内容（素材见 `tests/fixtures/local-fixtures.md`）。
   但真实用户 Catalog 的人工 Load Metadata 矩阵仍须在正式发布前由测试人员执行。

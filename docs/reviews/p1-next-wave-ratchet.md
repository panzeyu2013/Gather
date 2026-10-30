# P1 下一波：门禁与遗留（2026-10-30）

## 设计系统 ratchet

- `spacing.literalPadding` 175 → 206（+31），`spacing.literalSpacing` 257 → 261（+4）。
  （合并日按合并后 UI 源码重算；本分支自测时为 208，差异来自主干的交互整改。）
- 同次合并另外两个键是**收紧**：`empty.contentUnavailable` 29 → 28（本分支自测 30，主干 29）、
  `font.callout` 本分支 89 → 合并后 86（主干未改）。`check-design-system.py` 允许静默下调，
  故显式记在这里：上调 2 个键、收紧 2 个键，净增 29 处数字 padding。
- 来源：新增的 Curation 侧栏/集合视图、查看器叠加层（直方图/合焦/参考对比）、校样与元数据同步条、语义检索面板。
- 处置：本轮带 `--allow-growth` 更新 baseline（`scripts/design-system-baseline.json` 为唯一事实来源，本文记录理由）；
  后续统一换成 `GatherMetrics.Space/Layout` token，再次收紧 baseline。

## 测试 ratchet（合并后收紧）

- `check-test-catalog.sh`：`@Test` 2264 → **2438**、`@Suite` 249 → **273**、断言 10509 → **11280**。
- 依据：本次合并带入 11 个 core + 2 个 app 测试文件（约 3,750 行），不收紧会留下
  174 例 / 771 断言的"删除免检额度"。收紧后 `--strict` 实测 2438/2438 · 273/273 · 11280/11280。

## 清理 ratchet（已清零）

- `services_prepare` 已回落 0：新增 `MetadataLifecycleRepo`（候选查询/备份引用/零 item 删除/
  会话读取/状态投影），`MetadataRetentionService` 与 `MetadataDeliveryService` 只保留编排；
  baseline 保持 0，门禁绿。
- `unchecked_sendable` 已回落到 baseline（60）：新增的 KeywordIndexSync/EmbeddedJPEGSession/
  RewriteReportCollector 改为真正的 Sendable（OSAllocatedUnfairLock / 只读 let）；
  KeywordService/KeywordThesaurus 已在后续清理中删除。

## 最终接线（本轮收口）

- C1 自动 reload 已接组合根（写回事件 → 1.5s debounce → preflight → 串行 reload；手动同队列）。
- 校准：`CullingAPI.triageCalibration/applyTriageCalibration` + `TriageCalibrationService` 注入；
  检查器“校准阈值”面板经 Host 映射，不再显示“未接线”。
- 导入后自动初审：`checksum.backfill`(ingest) → `metadata.scan`(autoQuality) → `quality.score`；
  受 `triage_auto_generate`（默认 0）控制，取消/全跳过不触发。
- 语义检索：`PhotoAPI.semanticSearch`（相似照片/标签）+ Gallery“查找相似照片…”面板。
- 裁剪：`CullingAPI.adjustmentHint` 读 sidecar `crs:Crop*`，查看器只读标记。
- 关键词：缓存落库后 `KeywordIndexSync.syncFromCache`；启动后台回填断点续跑。
- 元数据备份 GC：启动 30s 后一次 + 24h 周期。

## 仍不在范围 / 静态审查未闭环

- AF 点真实 MakerNote 解析：机型表空表，按设计只做人脸中心回退（不伪造）。
- 跨页按评分/拍摄时间排序：`PhotoPageQuery.allowedSortFields` 只有 rowid/import_order，
  需要复合游标；本轮只提供“已加载范围”客户端排序。
- 词库管理（树/改名/合并/同义词）：本波未做，半截服务已删除，不保留死层。
- 参考对比的并排模式为“右半格显示参考图”的简化版；分割线拖动/叠加已可用。
- 加密 DMG / 交付到期撤销 job。

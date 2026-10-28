# 历史文档归档

本目录保存**已完成或被取代**的评审、审计与 Cut 执行文档。归档是快照，不是当前口径：

- 归档文档保留当时的行号、文件路径、结论与数字，**不随当前架构回填**；引用前先按符号名重新 grep。
- 当前架构/指标以 [README.md](../README.md)、[DEVELOPMENT.md](../DEVELOPMENT.md)、[ROADMAP.md](../ROADMAP.md)、
  [ADR.md](../ADR.md) 与 [refactor-progress.md](../refactor-progress.md) 为准。
- 归档文档之间的相对链接已随搬迁修正；**不要再按旧 `docs/reviews/<name>.md` 或 `docs/<cut>.md` 路径引用**，
  旧路径不再保留 redirect stub，统一使用本目录路径。
- **术语不回填**：2026-10-28 的 sidecar 术语统一（侧车/边车 → 附属文件 / sidecar）只扫现行文档，
  归档正文保持当时的写法（`git grep '侧车\|边车' docs/archive` 仍会命中，属预期）。
- 归档正文里指向旧 `gather-app/Sources/GatherApp/*` 的**源码链接**（`visual-design-review.md` 30 条、
  `ui-review-2026-09-29-round2-fixes.md` 3 条）按快照保留，不逐条回填；当前有效文档的链接已另行修正。

## reviews/（18 篇，2026-10-22 从 docs/reviews 迁入）

| 归档路径（原路径同名） | 内容 | 归档理由 |
| --- | --- | --- |
| [refactor-design-2026-10-21.md](reviews/refactor-design-2026-10-21.md) | 重构设计方案（非破坏版） | 已被 [破坏性重构方案](../reviews/refactor-design-breaking-2026-10-21.md) 取代 |
| [native-refactor-report.md](reviews/native-refactor-report.md) | Electron → 原生改造报告（截图、设计系统） | 迁移历史 |
| [full-review-2026-09-30.md](reviews/full-review-2026-09-30.md) | 全仓审查 11 项修复台账 | 9 月验收快照 |
| [full-review-2026-09-30-acceptance.md](reviews/full-review-2026-09-30-acceptance.md) | 第三轮全仓审查实际验收报告 | 9 月验收快照 |
| [deep-review-2026-09-30-fixes.md](reviews/deep-review-2026-09-30-fixes.md) | 深审 D1–D8 修复与探针 | 9 月验收快照 |
| [perf-audit-2026-09-30.md](reviews/perf-audit-2026-09-30.md) | 性能审计台账 | 9 月性能快照 |
| [ui-review-2026-09-29-fixes.md](reviews/ui-review-2026-09-29-fixes.md) | UI／交互审查修复台账（F01–F13） | 修复轮已完成 |
| [ui-review-2026-09-29-round2-fixes.md](reviews/ui-review-2026-09-29-round2-fixes.md) | UI 第二轮修复台账（N01–N10） | 修复轮已完成 |
| [ui-review-2026-09-29-round3-audit.md](reviews/ui-review-2026-09-29-round3-audit.md) | 第三轮发散审计与续修（D01–D12） | 修复轮已完成 |
| [ui-review-2026-09-30-fixes.md](reviews/ui-review-2026-09-30-fixes.md) | 9-30 原生版审查（B1–B7） | 修复轮已完成 |
| [visual-design-review.md](reviews/visual-design-review.md) | 视觉／页面／交互设计评审 | 视觉评审快照 |
| [visual-design-review-detail-native-views.md](reviews/visual-design-review-detail-native-views.md) | 原生视图逐页视觉审计 | 视觉评审快照 |
| [visual-design-review-macos-design-reference.md](reviews/visual-design-review-macos-design-reference.md) | macOS 设计语言引用汇编 | 视觉评审参考 |
| [ux-review.md](reviews/ux-review.md) | 用户视角体验评审 | UX 评审快照 |
| [window-layout-research.md](reviews/window-layout-research.md) | 参考应用窗口布局研究 | 布局研究快照 |
| [layout-restructure.md](reviews/layout-restructure.md) | 布局重构方案 | 布局研究快照 |
| [face-identity-replacement-2026-10-03.md](reviews/face-identity-replacement-2026-10-03.md) | Swift 人脸架构替换与素材验证 | ADR-029 前置研究 |
| [liquid-glass-macos-26-27-adoption.md](reviews/liquid-glass-macos-26-27-adoption.md) | Liquid Glass（macOS 26/27）采用调研 | 非当前最低目标（macOS 14+） |

`reviews/assets/` 随 18 篇一并迁入（原 `docs/reviews/assets/`），图片相对链接保持可用。

## cuts/（10 篇，2026-10-22 从 docs/ 根迁入）

| 归档路径（原路径同名） | Cut | 内容 |
| --- | --- | --- |
| [api-migration-map.md](cuts/api-migration-map.md) | 0/1 | 118 字符串命令 → 16 协议 / 110 方法逐条映射（历史对照） |
| [b8-router-removal-map.md](cuts/b8-router-removal-map.md) | 1 | B8 Router 删除映射（执行记录） |
| [cut1-execution-brief.md](cuts/cut1-execution-brief.md) | 1 | Cut 1 执行简报 |
| [cut1-completion-report.md](cuts/cut1-completion-report.md) | 1 | Cut 1 完成报告（118→16/110、Router 删除、门禁） |
| [module-split-map.md](cuts/module-split-map.md) | 3 | 模块拆分映射 v1（已被 v2 取代） |
| [module-split-map-v2.md](cuts/module-split-map-v2.md) | 3 | 模块拆分映射 v2（7 target 落地依据） |
| [schema-v1-draft.md](cuts/schema-v1-draft.md) | 2 | SchemaV1 设计草案（43 表 DDL） |
| [schema-v1-risk-audit.md](cuts/schema-v1-risk-audit.md) | 2 | SchemaV1 风险审计（列级对账 / FK / CHECK） |
| [cut4-ui-audit.md](cuts/cut4-ui-audit.md) | 4 | UI 状态层 / 本地化 / Preview 前置审计 |
| [cut5-algorithm-audit.md](cuts/cut5-algorithm-audit.md) | 5 | 算法单趟化前置审计（聚类 / ANN / 人脸） |

## 保留在 docs/reviews/ 的核心 4 篇（其余新增报告见 reviews/README）

| 文档 | 保留理由 |
| --- | --- |
| [refactor-design-breaking-2026-10-21.md](../reviews/refactor-design-breaking-2026-10-21.md) | 本轮重构的权威计划（多处引用） |
| [architecture-review-2026-10-21.md](../reviews/architecture-review-2026-10-21.md) | 本轮审计的行号台账仍被引用 |
| [face-clustering-benchmark.md](../reviews/face-clustering-benchmark.md) | ADR-029 与 Cut 5 审计引用 |
| [functional-design-review.md](../reviews/functional-design-review.md) | DEVELOPMENT 的 Swift 6 迁移与工程债指针 |

## 归档规则

1. 只在 Cut/评审关闭后归档；归档时同步改写全仓 md 链接（`scripts/check-docs.sh` 不校验普通 md 链接，
   需另跑本仓的链接检查）。
2. 归档文件不改正文结论；只允许修正相对链接与顶部"已归档/已被取代"横幅。
3. 新增归档在本文表格登记；`docs/reviews/README.md` 只列当前有效文档。

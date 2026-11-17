# 评审与审计索引（docs/reviews）

本目录保存各轮只读评审/审计报告与门禁基线变动台账。约定：

- 分轮评审建目录，命名 YYYY-MM-DD-主题，入口文档固定为 00-overview.md
  （早期轮次为 00-synthesis.md / 00-macro-overview.md）；
- 门禁 ratchet 的基线变动与理由必须在本目录记账（见各轮目录或独立台账文件）；
- 索引只链接本目录中已存在的文件；尚未创建的轮次先以纯文本占位。

## 分轮评审

| 轮次 | 主题 | 状态 | 入口 |
| --- | --- | --- | --- |
| 2026-10-30 | 交互与前端显示宏观审计（242 个 UI 文件，六份分模块报告） | 已完成 | [00-macro-overview.md](2026-10-30-interaction-audit/00-macro-overview.md) |
| 2026-11-10 | 对照 Capture One / Adobe Bridge 的功能缺口评审（约 105 条，六份分册） | 已完成 | [00-synthesis.md](2026-11-10-competitive-gap/00-synthesis.md) |
| 2026-11-11 | 功能缺口复核（Wave1–4c 修复后，约 950 行分册） | 已完成 | [00-synthesis.md](2026-11-11-competitive-gap-rereview/00-synthesis.md) |
| 2026-11-17 | 全仓质量加固审计（整洁度 / 规范 / 测试 / 设计 / 性能，round-1） | 已完成（round-1 提交） | [00-overview.md](2026-11-17-quality-hardening/00-overview.md) |
| 2026-11-17 | 第二轮全量加固审计（性能 / 测试 / 门禁 / 国际化 / 设计） | 已完成（round-2） | [00-overview.md](2026-11-17-round2-hardening/00-overview.md) |
| 2026-11-17 | 第三轮性能专项加固审计（DB / 查询、渲染、启动 / 缓存、性能门禁） | 已完成（round-3） | [00-overview.md](2026-11-17-round3-perf/00-overview.md) |

## 单篇评审 / 台账

| 日期 | 内容 | 文件 |
| --- | --- | --- |
| 2026-10-30 | P1 下一波合并后只读评审（5 分面 + 主 agent 构建/测试复核） | [2026-10-30-p1-next-merge-review.md](2026-10-30-p1-next-merge-review.md) |
| 2026-10-30 | P1 下一波门禁 ratchet 记账（design-system 指标） | [p1-next-wave-ratchet.md](p1-next-wave-ratchet.md) |
| 2026-10-31 | appearance 合并与独立审核台账（全量构建 + 12 道门禁 + 5 路评审） | [2026-10-31-appearance-merge-review.md](2026-10-31-appearance-merge-review.md) |
| 2026-11-04 | 架构重构 Wave 1–3 门禁基线变动台账 | [2026-11-04-architecture-refactor-ledger.md](2026-11-04-architecture-refactor-ledger.md) |

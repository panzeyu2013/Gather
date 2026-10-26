# Gather P0 详细设计基线（2026-10-26）

> 本目录是 P0（G0/T0/K0/F0/B0/X0）的唯一设计基线。实现以本目录评审结论 + 代码为准；
> 与本目录冲突时，先改设计再改代码。计划与估算见 P0 执行计划。

## 1. 固定决策（设计不得静默推翻；要改必须在“未决”中说明并评审通过）

| ID | 决策 |
|---|---|
| D1 | Grid Cull 是挑片页的**布局模式**（单图 / 2 图 / 4 图 / 网格），不新增页签、不改 7 页签导航。 |
| D2 | Schema V3 **只做增量**：`triage_suggestions`、`face_cluster_constraints`；不改既有表；迁移前备份、fail-closed。 |
| D3 | 对外统一叫“**技术质量建议（Beta）**”。禁止“AI 审美 / 最佳照片 / 闭眼识别”式承诺；闭眼只作“疑似”进入复核。 |
| D4 | Triage 只写 Gather 决策（`decision_source='ai'`），**绝不自动写 XMP**；应用前确认、可撤销、不覆盖人工决策。 |
| D5 | 人脸拆分 v1 **仅未绑定簇**；拆分必须经 `face_cluster_constraints` 在重聚类后保持；绑定簇先解绑。 |
| D6 | 关键词走既有 delivery 引擎；预览与写回同源；**保留** face/similarity/culling 生成的关键词。 |
| D7 | 新增 API/字段必须更新 `docs/protocol-surface-baseline.json`；新增设置键必须注册 `SettingsService.getDefaults()`。 |
| D8 | 文案：中文为源 key，`en.lproj` 必须在同一 PR 补齐；视觉只用 DesignSystem token，不手写颜色/字体。 |
| D9 | 性能预算：20k 会话首屏 p95 < 800ms；单次键动作 p95 < 50ms；triage 生成 20k < 2s；500 张关键词预览 < 1.5s。 |
| D10 | 每份设计必须给“任务 → 文件 → PD → 验收”拆解，估算总和不得超过 P0 计划。 |

## 2. 文档地图

| 文件 | 范围 | 负责人 | 状态 |
|---|---|---|---|
| [x0-contracts.md](x0-contracts.md) | API/Schema/Settings/门禁 的冻结清单 | X0 | **frozen v1** |
| g0-grid-cull.md | G0 交互 + 前端架构 | G0 | reviewed |
| t0-triage-policy.md | T0 规则/算法/评估/文案 | T0 | reviewed |
| t0-g0-data-contracts.md | V3 DDL、排序分页、查询与性能 | T0/G0 | reviewed |
| k0-keywords.md | K0 关键词 UX + 服务 | K0 | reviewed |
| f0-face-split.md | F0 约束表、拆分、复核 | F0 | reviewed |
| b0-backup-diagnostics.md | B0 备份/恢复/诊断 | B0 | reviewed |

## 3. 每份设计必填章节

1. 目标 / 非目标（一句话可验收）
2. 用户场景与主流程（含失败路径）
3. 状态机与边界（空态、部分态、并发、取消、重入）
4. 交互/视觉规格（视图层级、键盘、焦点、a11y、文案）
5. 数据 / API / DDL（精确签名与 SQL）
6. 算法 / 规则（可转成纯函数）
7. 性能预算与测量方法
8. 测试计划（单测/契约/集成/性能/迁移）
9. 风险与未决问题（含推荐选项）
10. 实施拆解（任务 → 文件 → PD → 验收）

## 4. 评审清单（Definition of Ready）

- [ ] 与固定决策 D1–D10 一致；冲突已显式记录
- [ ] 所有新类型有 Swift 签名，所有表有 DDL，所有查询有 SQL
- [ ] 破坏性操作都走 `Confirmed<T>` 且有真实确认 UI
- [ ] 人工决策优先、失败可恢复、不会静默丢数据
- [ ] 20k 预算与测试方法可执行
- [ ] 文案中英齐全，视觉 token 化
- [ ] 估算与 P0 计划对得上

## 5. 变更流程

设计变更 → 更新本目录对应文档的“未决/决策” → 评审通过 → 同步 `x0-contracts.md` 与 P0 计划 → 再改代码。

## 6. 环境基线（2026-10-24 实测）

- 本机 SwiftPM 必须加 `--disable-sandbox`（否则 manifest 编译报 `sandbox-exec: sandbox_apply: Operation not permitted`）。
- 基线（改动前）：
  - `gather-core`：**1167 tests / 174 suites** 全绿；
  - `gather-app`：**641 tests / 72 suites** 全绿（`--no-parallel`）。
- 命令：

```bash
cd desktop/native/gather-core
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-cache swift test --disable-sandbox

cd ../gather-app
CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache swift test --disable-sandbox --no-parallel
```

- 门禁：`scripts/check-protocol-surface.sh --strict`、`scripts/check-design-system.sh`、
  `scripts/check-cleanup-ratchet.sh`、`scripts/check-docs.sh --strict`（发布前）。
- schema 版本当前 **3**（唯一 DDL；V1/V2 迁移链已删除，旧库默认 fail-closed）。

## 7. 实现状态（2026-10-25）

| 项 | 状态 |
|---|---|
| 六路设计 + X0 契约冻结 | ✅ v1（16 协议 / 112 方法；44 表 / 383 列 / 72 索引 / 65 外键） |
| Schema 代码 | ✅ `SchemaCurrent`（唯一 DDL，fingerprint `fa0f3c8…`）；迁移链已删除 |
| Schema 测试 | ✅ 形态/计数/指纹/CHECK/FK + 三态 open/reset（core **1230/182**、app **683/77**） |
| T0 纯函数核心 | ✅ 17 tests 全绿（Triage 类型 + Evaluator + 单测；未接 API/UI） |
| G0 后端（cursor/sort/keyset） | ✅ core 1192/176、app 641/72；7 条分页测试 + 无建议 nulls-last |
| T0 服务/仓储 | ✅ 27 tests 全绿（候选装配/指纹/generate/summary/apply + 单测） |
| T0 API/组合根接线 | ✅ core 1205/177、app 642/72；4 个 TRIAGE_* 错误码 + 载荷 + strict 门禁 |
| G0 网格 UI | ✅ app 647/73、core --filter Culling 141/20；第 4 布局 + 键盘/多选 + 排序筛选 |
| T0 建议卡/复核队列 | ✅ app 652/74；Beta 卡 + 确认 sheet + review 队列 + nextCursor 修复 |
| K0 关键词后端 | ✅ core 1217/180、app 652/74；planner/preview/delta/API + 12 tests |
| K0 关键词面板 | ✅ app 661/75；chips/补全/预览/确认/结果条 + 9 tests |
| F0 人脸拆分后端 | ✅ core 1221/181、app 661/75；约束/拆分/复核 + 4 tests |
| F0 拆分/复核 UI | ✅ app 670/76；待复核 Badge/多选拆分/复核分页 + 9 tests |
| B0 备份/恢复/诊断后端 | ✅ 第 16 协议 + 12 错误码；cleanup ratchet 229/230、54/54、0/0 |
| B0 cleanup ratchet | ✅ try_optional 229/230、unchecked 54/54、services_prepare 0/0（未改 baseline） |
| B0 设置页 UI | ✅ 备份/恢复/诊断 + 调度 + 保留份数；app 683/77 |
| 全量验收 | ✅ core 1230/182、app 683/77、8 道 strict 门禁全绿；release 20k/50k 基准、20k 排序分页 p95 34–49ms / service p95 9.3ms、2GB 备份 3.0–3.9s；实现审计 P0/P1 已修；release/Gather.app 已组装（unsigned） |
| T0 真实集质量门 | ⏳ 工具已就绪（gather-triage-eval + 指标测试）；外部 400 张双人标注集未提供，不能宣称误杀率 <1% |

> 测试命令必须带 `--disable-sandbox`（见 §6）。下一步：Schema 测试绿 → 协议类型（cursor/triage）→ G0 排序分页。

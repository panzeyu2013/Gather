# Gather P0 全量实现 Review（2026-10-26）

> 目标已重设：对当前实现做正确性、完整性、最优性、可交互性、性能的全量 review，修复确认的 P0/P1；照片质量验收暂不执行。

## 0. 结论

没有发现新的 P0 数据错误；实现整体可用，但不是“做完即完美”。本轮确认并修复 1 个 P0、全部确认的 P1 和若干 P2；剩余为 P2 优化与外部条件。

| 维度 | 评分 | 判断 |
|---|---|---|
| 正确性 | 8.5/10 | 决策/写回/恢复主路径有测试；已修批量隐藏选择、绑定簇合并、缓存失效 |
| 完整性 | 9/10 | 五工作流主流程齐全；T0 少量边界、真实缩略图性能仍缺 |
| 最优性 | 8.5/10 | 首屏 summary 已 SQL 聚合、groups 懒加载；复核排序、预览串行 XMP 仍可优化 |
| 可交互性 | 8/10 | 键盘/选择/确认/错误反馈基本闭环；T0 关闭态控件、草稿保护、a11y 仍需打磨 |
| 性能 | 8.5/10 | 2GB 备份 3.0s、20k service 9.3ms、UI 首帧 27.2ms；首屏 O(session) 聚合仍是隐患 |
| 可维护性/测试 | 8/10 | 1252 core + 687 app tests、8 门禁；VM 级 20k、真实缩略图、契约计数仍缺 |

## 1. 方法

五路只读 subagent：G0/T0、K0/F0、B0/X0、UX/交互、性能/架构/测试；主代理逐条复核代码路径，修复后补回归。不把设计文档承诺当作实现，不把“测试绿”当作“产品完整”。

## 2. 本轮确认并修复

| 级 | 位置 | 问题 | 修复 |
|---|---|---|---|
| P0 | CullingViewModel+Actions.swift | commit 算出 visibleSelection，但 batchUpdate 仍用完整 selectedPhotoIds；缩页/刷新后可见+隐藏选择并存时，P/X 写隐藏照片 | batchUpdate(targets:) 与当前已加载页求交；补 batchCommitUsesVisibleSelection |
| P1 | TriageService / Core.swift / SessionWorkspaceFactory | service 启动时固定 enabled/policy，UI 每会话读设置；开 T0 后新会话卡片出现但 generate 抛 TRIAGE_POLICY_INVALID | service 改 policyProvider/enabledProvider；composition 读设置，变更即时生效 |
| P1 | FaceKwService+Review.swift | 合并已绑定 source 簇会 DELETE role_bindings，人物身份/keywords 静默丢失 | source/target 任一绑定即抛 clusterBound；测试改为拒绝合并并保留绑定 |
| P1 | CullingView / GatherAppCommands / CullingInfoBar | 关键词 TextField 内 ⌘Z 被挑片历史替换；InfoBar 裸 ←/→ 抢文本光标 | TextField（NSTextView firstResponder）时把 undo/redo 交还 field editor；移除 InfoBar 裸方向键，保留网格 onKeyPress |
| P1 | CullingTriageCard / TriageService | apply 成功后按钮仍可用，重复 apply 产生无意义 upsert/history | UI triageApplied 防重复；service 跳过已覆盖同 verdict 的 AI 决策 |
| P1 | CullingViewModel+Load | 每次 loadMore 都拉 summary/groups/sync/history，20k 每页 O(session) | 仅 reset 时拉这些会话级数据；翻页只追加页 |
| P1 | LiveCullingAPI / 质量轮询 | T0 自动生成在 MainActor 同步跑 generate，20k 会卡 UI | generate/apply 移入 Task.detached(priority: .userInitiated) |
| P1 | CullingService.getSummary | 20k 首屏全量搬 photos/decisions/cache 到 Swift | 新增 SQL GROUP/COUNT 聚合；测试替身可回退旧循环 |
| P1 | CullingViewModel groups | 每次 reset 都拉全量 groups，即使从未进入相似度范围 | 只在 similarityGroup scope / 选组/跳组时懒加载 |
| P1(B0) | Composition/Core | 生产 MaintenanceService 未注入 isOtherInstanceRunning | 用同 bundle id 的 NSRunningApplication 检测另一实例；restore/backup 走 BUSY |
| P1（B0） | MaintenanceService / SchemaBackup | cancel 后仍持有 restoreLock；迁移备份未 chmod 0600；restore 未与 backup 共用锁 | cancel 释放/复用锁；SchemaBackup 0600；restore 先拿 BackupLock，写 journal 后释放 |
| P1（边界） | MetadataService / FaceRepo+Constraints | preview 允许跨 session、apply 拒绝；F0 review revision 不含 photos | preview 同单会话 guard；revision 加入 photos count/max(updated_at) |
| P2 | FaceKwService+Split | 只删 selected↔remaining 的 together，selected 与外部簇的约束会保留 | selected 与任何非 selected 的 together 都删除；selected 内部保留 |
| P2 | DiagnosticsCollector | 裁剪后仍返回裁剪前 logFileCount；日期回退原始 ISO | 重算最终日志数；ISO 双 formatter fallback |
| P3 | CullingViewModel 质量完成 | 先 loadPage，再 generateTriage（内部再 loadPage） | 未改：避免与自动生成/刷新竞争，留后续 |

## 3. 仍未关闭

| 级 | 项 | 影响 / 建议 |
|---|---|---|
| P2 | T0 关闭时“建议筛选/建议排序”仍显示，选中后空网格 | 关闭时隐藏/禁用并清 triageVerdicts |
| P2 | K0 apply 中途 blocked 可能留下已入队 pending | 先全量预检 blocked，或事务化入队 |
| P2 | K0 culling/similarity origin 只标记不注销 | 外部删除/模块清理后可能误报 owned；模块清理时 deactivate |
| P2 | F0 review makePage 每页 filter+sort 全部 items | 缓存排序后的数组/前缀索引 |
| P2 | Metadata preview/apply 串行逐 XMP 读 | 500 张/共享 sidecar 可能秒级；按 xmp 去重 + bounded concurrency |
| P2 | F0 绑定簇合并现在拒绝，但 UI 候选未过滤绑定簇 | 服务已兜底；UI 应提前禁用/提示 |
| P2 | F0 cache 内存 8 条全量 items | 10k 复核下内存需实测；可只缓存排序索引 |
| P2 | 关键词草稿切换照片直接 reset，无确认 | 切换前确认/保留草稿；chip remove 的 VoiceOver 动作需独立 |
| P2 | Restore prepared 且 db/pre 同时存在时静默移 journal | 用户可能不知道恢复丢失；写 lastRestore/错误 UI |
| P3 | AppBootstrap 注释仍写 SchemaV1/43 表 | 文档漂移；改成 V3/45 表 |
| P3 | 门禁不校验 x0 的 45/389/121 数字 | 建议加契约计数断言，防文档漂移 |

## 4. 可交互性分析

做得好的：选择/全屏/右键/确认 sheet 的目标语义已多次修正；T0 关闭时有可发现提示；恢复有 banner/取消；K0 blocked 预览会禁用确认；F0 复核分页与摘要合并可用。

仍需打磨：

1. T0 关闭时筛选/排序控件仍可见，用户会得到空网格且无解释；应在关闭时隐藏或禁用。
2. 关键词草稿在切换照片时直接丢弃；高频操作下容易误丢输入。
3. TextField 内 ⌘Z/方向键冲突已修，但 canUndo 始终为 true，无可撤销时点击是 no-op；可接受但不够精细。
4. 备份列表日期、路径、诊断结果的信息层级基本清楚；恢复取消现在有锁保护，但“另一实例”场景仍缺检测。
5. 无障碍：关键词 chip 用 combine 后 remove 按钮可能失去独立 VoiceOver 动作；建议 accessibilityAction。

## 5. 性能分析

| 场景 | 结果 |
|---|---|
| 2GB 备份 | 3.01s（3.0–3.9s 复跑），verified |
| 20k SQL 分页 p95 | capture 49.1ms / rating 37.2ms / triage 37.6ms |
| 20k service 分页 p95 | 9.3ms（10 页，含富化装配） |
| 20k UI 首帧 | 真实 NSWindow 27.2ms；离屏 28.0ms（200/20k，无缩略图解码） |

瓶颈判断：

- 翻页已不再拉 summary/groups/sync/history；但首屏仍全量读 photos/decisions/suggestions，20k 时是下一次优化重点。
- T0 generate/apply 已移出 MainActor；首屏 summary 已 SQL 聚合、groups 懒加载。
- F0 复核缓存省了 evaluate，但每页仍排序全部 items；10k 复核时是 O(n log n)/页。
- K0 preview 串行读 XMP，500 张/共享 sidecar 是潜在秒级操作。
- 2GB 备份/恢复、20k 读路径目前有足够余量；不建议继续微优化，先把首屏/后台生成做对。

## 6. 完整性与最优性

- Schema V3 / 17 协议 / 121 方法 / 45 表 389 列 72 索引 65 外键 / 8 门禁均在；
- T0 默认关闭、自动生成可选，符合 Beta 定位；
- B0 备份/恢复/诊断/取消/保留份数/2GB CI 基本闭环；
- 主要完整性缺口是真实缩略图/滚动/键动作性能，不是功能缺失；
- 架构上 Application/UI 有少量重复状态，但未形成第二真相源；测试 happy path 覆盖较好，VM 级 20k 与失败注入仍不足。

## 7. 建议优先级

1. P2 T0 关闭态控件隐藏；K0 入队预检；F0 排序索引缓存；Metadata 并发读；草稿保护/a11y。
2. P3 文档注释、门禁契约计数、诊断元数据一致性。

## 8. 验证

第二轮扫描与后续 P2 修复见 [p0-second-scan-2026-10-26.md](p0-second-scan-2026-10-26.md)。

- core 1252 tests / 187 suites；app 687 tests / 78 suites；8 道 strict 门禁全绿；
- RC 重建后见 P0 验收报告 hash；
- 本轮不执行照片质量验收，不宣称误杀率 <1%。

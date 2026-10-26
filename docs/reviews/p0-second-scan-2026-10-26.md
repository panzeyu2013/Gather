# Gather P0 第二轮全量扫描（2026-10-26）

> 范围：正确性、完整性、最优性、可交互性、性能；修复残留 P2。照片质量验收与需外部素材的性能测试不执行。

## 0. 结论

- 五路只读扫描 + 主代理复核，**无新 P0/P1**；发现 1 个首轮优化引入的 P1 回归（从“全部”范围直接选相似组失效），已修复。
- 本轮修复 **20 项 P2/P3**；产品性残留 P2 已清零，仅剩需真实缩略图的性能覆盖项（按目标排除）。
- core **1252/187**、app **687/78**、8 道 strict 门禁全绿。

## 1. 方法

五路独立扫描：G0/T0、K0/F0、B0/X0、UX/性能、架构/测试/门禁；每条要求文件:行、触发场景、证据、修法。主代理逐条复核后修复并回归。

## 2. 本轮修复

| 级 | 位置 | 问题 | 修复 |
|---|---|---|---|
| P1 回归 | CullingViewModel+Load | 懒加载 groups 后，从全部范围直接选组时 scope 不是 similarityGroup，force 未加载，选组无反应 | loadSimilarityGroupsIfNeeded(force:)；选组前强制加载；补测试 |
| P2 | CullingInspector / CullingViewModel | T0 关闭时建议筛选/置信度排序仍显示，选后空网格 | 关闭时隐藏控件，清 triageVerdicts，重置 triage 排序并 reload |
| P2 | CullingViewModel | apply 后 undo/redo 不复位 triageApplied，按钮一直禁用 | undo/redo 复位 |
| P2 | CullingViewModel+Grid | setPageLimit 缩页后隐藏选择仍显示 | 缩页清空选择 |
| P2 | MetadataService | apply 逐 target 入队，后一个 blocked 时前一个留 pending | 先全量 preview 预检 blocked/read failed，再入队 |
| P2 | MetadataService / MetadataMutationService | origin 只标记不注销，外部删词后误报 owned | 读取时与磁盘现有词求交，陈旧 origin 不参与 blocked |
| P2 | CullingKeywordPanel | 切换照片直接丢关键词草稿 | 有草稿时保留 chips/query，只清旧 selection 的 preview/result |
| P2 | CullingKeywordPanel | chip combine 后 remove 按钮可能失去独立 VoiceOver 动作 | 改 children: .contain，Text 单独 label |
| P2 | FaceReviewStep | 合并候选未过滤绑定簇，可选后报 clusterBound | 候选只保留 binding == nil |
| P2 | FaceKwService ReviewQueue | 复核每页仍 filter+sort 全部 items；8 份全量 Output 内存重 | 缓存 sortedItems/suspectTotal；不再存 raw Output，10k 结果只留 1 份 |
| P2 | MaintenanceService | backup 先查 journal 再拿锁，窗口内 restore 可插入 | 拿 BackupLock 后重查 journal |
| P2 | MaintenanceService | cancel 在 oldMoved/newInstalled 失败后仍占 restoreLock | 失败释放锁，交给下次启动恢复/回滚 |
| P2 | RestoreSupport | prepared 且 db/pre 并存时静默移 journal | 写 lastRestore 失败结果，清 staging，设置页 banner |
| P2 | DiagnosticsCollector | 最新日志超预算直接 break，旧小日志全不拷 | 改为 continue；size 读取失败视为导出失败；脱敏根扩充 |
| P2 | TriageRepo | fingerprint 只看 photos 计数/maxRowId，relink 可能不 stale | 加入 photos.max(updated_at) |
| P2 | MetadataService | preview 串行逐 XMP readKeywords，500 张可能秒级 | 按 8 路分块并发读，失败仍按 target 标记 |
| P2 | MetadataMutationService / apply | apply 逐 target 再读一遍 XMP，与 preview 重复 | 复用 preflight 的 before.keywords 快照，queue 不再二次读盘 |
| P2 | SessionWorkspaceFactory / Settings | 已打开会话切 T0 开关后卡片状态不刷新 | settingsChanged 通知 + provider 重读，关闭时清过滤/排序 |
| P2 | Composition/Core | 单实例检测在 xctest/裸二进制可能误判 | 仅在 .app bundle 内启用 NSRunningApplication 检测 |
| P2 | 20k 性能门 | 只测 listPage，summary SQL 无回归 | 新增 20k summary p95 测试，实测 3.3ms |
| P3 | AppBootstrap | 注释仍写 SchemaV1/43 表 | 改为 V3/45 表 + V1/V2 迁移 |

## 3. 仍未关闭的 P2

| 项 | 影响 / 建议 |
|---|---|
| 真实缩略图/滚动性能覆盖 | CullingGridPerf 仍用 200 占位资产，nightly 只跑 core；需真实缩略图素材（按目标排除） |

### P3 清单

- 质量完成 → loadPage → generateTriage 双刷新；
- selectSimilarityGroup force 加载后 loadPage 可能再拉一次（已有 isEmpty guard，理论无重复）；
- canUndo/canRedo 恒为 !isBusy，无历史时菜单可点但 no-op；
- 移除 InfoBar 裸方向键后，焦点不在网格时方向键失效；
- Fake 的 summaryCounts/reviewRevision 默认 nil，单测会绕过新 SQL/缓存路径；
- 8 条 review cache 满即全清，无 LRU；
- check-docs 只校验 schema 数字，x0 的 45/389/121 无门禁；
- moveToCorrupt 不清理所有 staging；
- BackupLock/RestoreLock released 标志无原子保护。

## 4. 验证

- core 1252 tests / 187 suites 绿；
- app 687 tests / 78 suites 绿（--no-parallel）；
- 8 道 strict 门禁全绿；
- RC 重建后见 P0 验收记录 hash。

## 5. 过程披露

一个只读扫描 subagent 自述误执行了写操作。主代理核查：git status 仍为 148 项（与扫描前一致）、无冲突标记、git diff --check 无结构错误，并重跑 core/app/gates 全绿；但不能证明每个改动来源。当前工作区变更需在提交前人工 review diff。

# P1 / IPTC 进度（收尾完成）

## 结论

剩余项按推荐方案收尾完成：core **1313/199**、app **713/82** 全绿；12 道 check-*.sh、schema verify、docs/l10n 全过。

## 本轮收尾

- 淘汰移出：AssetRepo.relocatePhotoPathsAfterMove 单事务迁移 photos/deliveries/intents/keyword origins/sidecar bindings/asset_files；RejectedMover 增加迁移闭包，失败回滚文件与 DB。
- 写前基线：metadata/template 首次入队记录 pre-write fingerprint；执行器写前比对，外部改动直接 failed。
- filterGlobally：两个逐行 GROUP_CONCAT 子查询改为 asset_rollup 一次分组聚合；会话筛选限制代表行属于该会话。
- facet：先按资产选代表行再分桶，计数与网格同口径。
- triage：apply 读盘 8 路并发；undo 只删本次追加关键词（delta）。
- 摄取：懒 checksum 对存量现算；{seq} 下共享侧车复用第一张目标；目录递归/全格式；symlink 解析。
- inode relink：旧路径仍存在时拒绝，防硬链接/inode 复用误并。
- FSEvents：start/stop 增加 starting/cancelled 守卫；eventID 仅在扫描任务成功入队后推进。
- 模板：清空/赋值编辑器（文本、列表、contact 只读+清空）。

## 清理

删除 orderedSources、gatherCanvas/gatherNumber、undo 的 now 参数；收敛 triage 批次常量；更新旧注释；ClearSheet 更名 FieldsSheet。

## 基线

protocol 304 类型 / 1713 声明 / 0 零引用；cleanup 60 unchecked / 257 try?（收紧 1）；design system 无回归。

## 剩余（人工/产品确认）

1. culling 星级/色标写回在用户确认同步前保持 written，备份随 confirm/finalize 回收；未确认时行/备份常驻（既定 C1 reload-ack 流程）。
2. filterGlobally 已改写但未跑 100k 基准；需要真实大库验证。
3. FSEvents RootChanged 后的 missing 对账仍依赖全树扫描；LRU 竞态已修。
4. GUI/无障碍需人工验收（VoiceOver、窗口尺寸）。

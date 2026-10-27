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

三条 ratchet 基线本轮**均按实测重写（上限抬高，不是收紧）**，与上一版对比：

| 基线 | 旧 | 新 | 来源 |
|---|---|---|---|
| cleanup `unchecked_sendable` | 54 | 58 | 新增 4 个需 NSLock/端口持有的类型；TriageWritebackService、MetadataTemplateService 已改为编译器校验的 `Sendable` |
| cleanup `try_optional` | 228 | 256 | 新增代码的 best-effort 路径（临时文件清理、回滚、缓存投影、批次留证） |
| design system `literalPadding` | 170 | 175 | 新增 6 个 Sheet/面板 |
| design system `literalSpacing` | 243 | 257 | 同上 |
| protocol `public_types` | 272 | 304 | IPTC/模板/摄取/分面 DTO |
| protocol `public_declarations` | 1469 | 1713 | 同上 |

protocol `zero_reference_types` 1 → 0（改善）。基线与当前实测相等（零余量），
后续任何新增都会被门禁拦下。

可降级的部分已降级：`TriageWritebackService` / `MetadataTemplateService` 去掉
`@unchecked`（存储属性全是不可变 Sendable，交给编译器校验）；其余 4 处保留
`@unchecked` 是因为持有 `NSLock` 保护的 mutable 状态或非 Sendable 端口
（`RejectedMover` 的 `PhotoRepository`/`relocate` 闭包、`DirectoryWatcher` 的
FSEventStreamRef、两个 `*Store` 的缓存 + NSLock），在 macOS 14 目标上无法用
`Mutex`/actor 替代同步 API。`try?` 的 +28 全部是"失败可继续"的路径，改成 `try`
会把清理/回滚失败升级成主流程失败。

## 剩余（人工/产品确认）

1. culling 星级/色标写回在用户确认同步前保持 written，备份随 confirm/finalize 回收；未确认时行/备份常驻（既定 C1 reload-ack 流程）。
2. filterGlobally 已改写但未跑 100k 基准；需要真实大库验证。
3. FSEvents RootChanged 后的 missing 对账仍依赖全树扫描；LRU 竞态已修。
4. GUI/无障碍需人工验收（VoiceOver、窗口尺寸）。

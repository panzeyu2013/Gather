# P1 收口 + P2 补强：执行进度（2026-10-28）

> 计划：[plan-2026-10-28.md](plan-2026-10-28.md)。本文只记"实际落地了什么、证据在哪、门禁实测多少"，设计理由见计划。

## 结论

A1/A2/A3/B1/B2/C1/C2 全部落地；第三轮复核修复后 core **1364 / 200 suites**、app **728 / 84 suites** 全绿；12 个 `check-*.sh`（strict）+ test-catalog `--self-test` + `gather-schema verify`（44/385/72/65、user_version=5、0 违规）+ `check-docs --strict` 全过。合并后再补 5 条回归（可见性 3 + 联系人 P0 1 + 归档恢复 1）→ core **1369 / 200 suites**；清理 ratchet 的 `try?` 收敛到 248（新增路径以显式 do/catch / 失败分支为主），protocol 基线按实测重写（310 类型 / 1751 声明）。

## A1 淘汰移出语义

- **schema v5**：`photos.archived_at`（DDL 末尾追加，不改既有列序）；`userVersion=5`、列数 385、指纹 `38bd1540…`；`Schema.swift` 镜像同步并在 `SchemaCurrentTests` 加"镜像 == userVersion"断言。
- **可见性单一入口**：`GatherPersistence/Database/Queries/PhotoVisibility.swift`；接入挑片网格/计数/摘要/选择集、图库 `filterPhotos/filterGlobally/countGlobally/countPhotos`、facet、导航、triage 候选/eligible 计数、导出范围、重复/相似成员。
- **移出服务端**（`LiveCullingAPI.moveRejected`）：按逻辑资产展开变体；逐张过滤（not_in_session / not_rejected / already_archived）返回 `skipped`，不再整批拒绝；输入上限 20k。
- **共享边车**（`RejectedMover`）：`sharesSidecar` 时复制 `.xmp` 与 `gather-backup-*`，全部移出才移动；回滚按 copy/move 逆操作。DB 侧 `copySidecarBindingForVariant` 为新 xmp 建 binding、复制 metadata state、把被移文件从旧 binding 解绑。
- **归档写入同一事务**：`AssetRepo.relocatePhotoPathsAfterMove(sharesSidecar:archivedAt:)`。
- **跨页选择**：新增 `CullingAPI.selection` + `CullingService.selectableIds` + `representativeIds` SQL；VM 的 `selectedPhotoIds` 不再被页刷新裁剪；⌘A 走 `selectAllInScope()`；`moveRejectedOut` 提交完整选择集、只把真正移出的从选择集移除。
- 测试：`PhotoVisibilityTests`（网格/计数/摘要/选择集/图库/facet/跨页 120+30）、`RejectedMoverTests` 新增共享侧车复制/归档/复制回滚、`CullingViewModelAPITests` 新增跨页提交/skipped/全选。

## A2 triage 安全

- `MetadataApplySnapshot.appliedRating`；undo 先并发读盘上 rating，只有"仍等于本批写入值"才回滚，否则进 `skipped` 且批次照常标记已撤销（`undoSkipsRatingChangedByUser` / `undoRestoresRatingWhenUnchanged`）。
- `MetadataAttributesApplyOutcome.uncertain` + `undoable`；模板与 triage 的批次裁剪统一为 `written ∪ uncertain`。
- `TriageRatingMode`（keep3Reject1 默认 / keep3Only / none）进 `TriageWritebackInput`，planner 按模式产 rating，挑片检查器加下拉；默认值未变。
- 新增 `MetadataAttributesApplyOutcome.undoable == ["a","b"]` 去重测试，以及"回读校验失败仍留批次可撤销"的服务级测试（注入错误回读）。

## A3 keepExternal + 投影合并

- `MetadataTemplatePlanner`：`externallyModified = disk != nil && diskValue != currentValue`（缓存缺该字段但盘上有值 = 冲突）；`unknownCacheIsConflictUnderKeepExternal` 同时覆盖 overwrite。
- 拆分两个写入口：`updateDescriptive` = 完整快照整列替换（读回校验/扫描），`mergeDescriptive` = 增量补丁字段合并（Converge 使用，尊重 `replace_contact`）；`MetadataCacheStore` 端口同步。测试覆盖"整列替换删字段"与"补丁保留未触碰字段/空串清空"。

## B1 JPEG 内嵌 IPTC

- `MetadataService.embeddedAttributesFromParse` 增 `descriptive`：dc/xmp 优先、IPTC-IIM 回退（`Caption/Abstract`、`ObjectName`、`CopyrightNotice`、`Byline`、`City`、`Province/State`、`Country/PrimaryLocation*`、`SubLocation`、`Writer/Editor`、`Scene` 等）；`textValue/listValue` 解包 ImageIO 的 Alt/tag 数组。
- `mergeAttributes` 描述性元数据改逐字段 `applying`（侧车覆盖、内嵌补缺）；删除"IPTC-only 关键词 → nil"的死分支（ImageIO 会合成 dc:subject，实测）。
- 新公开入口 `MetadataService.diskAttributes(photoPath:)`：JPEG 内嵌 + 侧车；模板 apply/preview、triage apply/undo 全部改用它。
- 测试：`mapsEmbeddedDescriptiveMetadata`、`readsRealJpegIPTCDescriptive`（真实 JPEG 写 IIM 再读）、`mergesDescriptivePerField`。

## B2 单张编辑器

- `MetadataTemplateService.applyFields`（模板 apply 改为转调）；`inline` 批次常量；`MetadataAPI.applyDescriptive` + Live 实现（`replaceContact: true`）。
- `MetadataInlineApplyInput`：photoIds ≤ 2000、字段非空、每字段 ≤ 4096/列表 ≤ 100。
- UI：`MetadataEditorSheet`（32 字段 + contact 8 成员）+ `MetadataEditorDraft`（纯差异计算，直测）；挑片与图库检查器各有"编辑元数据…"入口；en 文案补齐。
- 测试：`MetadataEditorDraftTests`（只提交改动/空值清空/列表拆分/contact 计一）、`inlineFieldsAndContactReplacement`（批次 id/名称、replaceContact、undo 整块还原）。

## C1 摄取 EXIF

- `IngestService` 注入 `ExifProvider`；`plan` 改 async；单文件捕获 `DateTimeOriginal → DateTimeDigitized → mtime → now`，`{camera}` 用 `Model`；目录枚举移到同步 helper（NSEnumerator 在 async 上下文不可用）。
- `LiveSessionAPI` 注入 `ImageIOExifProvider()`，plan 改 `await`。
- 测试：EXIF 日期决定目录 + camera、无 EXIF 回退 mtime（预期值按本地日历推导，避免 UTC+8 跨日）。

## C2 + P2

- **watcher 窄扫描**：事件目录进 `pendingScanDirs`，`metadataScan(requestedPaths: dirs)`；用返回 job 的 checkpoint 判断是否被 dedupe 到更窄任务，未覆盖则 2/4/8/16s 退避，超过 4 次退回全树扫描；eventID 只在覆盖成功后持久化；stop/stopAll 清理 pending 与重试。`SessionDirectoryMonitorTests` 覆盖覆盖判定与祖先/兄弟/尾斜杠。
- **多 rdf:Description**：合并为单块后打补丁；子元素同名取第一块、开标签属性补缺；`rdf:about` 不同仍拒绝。测试：合并写入保留两块字段、不同 subject 拒绝；旧"显式拒绝"测试改为合并语义。
- **模板存储**：逐元素解码 + `metadata.templates.corrupt` 留证（Settings 默认表 53→54）；`dropsOnlyCorruptEntries`。
- **模板 apply/preview 上限** 2000（显式 INVALID_PARAM）。
- **README** 中英文工作流表补 Ingest / Metadata & IPTC / Triage / Reject move 四行；API 方法数 126→129。
- **ADR** schema 4→5、384→385、指纹说明同步；`check-docs --strict` 绿。

## 门禁实测

| 项 | 结果 |
|---|---|
| core | 1364 tests / 200 suites，1.7s |
| app | 728 tests / 84 suites，12.1s（--no-parallel） |
| schema verify | tables=44 columns=385 indexes=72 fks=65 user_version=5 violations=0 |
| check-*.sh ×12 | 全 EXIT=0（strict 可用者带 --strict；cleanup 默认即硬门禁） |
| test-catalog --self-test | SELFTEST OK |
| l10n | app 测试内 LocalizationParity 全过（新增 key 均在 en 表） |
| protocol 基线 | public_types 310 / public_declarations 1751 / zero_ref 0 / router 0 |

## 第二轮收口（2026-10-28 复看后）

复看发现的 P0/P1 已全部修掉，并补了对应测试：

- **P0 部分移出丢资产**：`preferredRowPredicate()` 的代表行子查询加
  `p2.archived_at IS NULL`（CullingAssetPageQuery）；`TriageRepo` 的
  loadRepresentatives / loadApplyTargets / quality / coverage 子查询同步。
  新测试：RAW 归档、JPEG 可见时，filtered 网格/计数/选择集仍返回 JPEG。
- **P0 watcher 竞态**：改为 `PendingScan` 状态 + 单会话扫描循环：每次取快照，
  成功后只 `acknowledge(快照)`；await 期间新到的目录保留并立即进入下一轮；
  eventID 只在 pending 清空后持久化；全树回退失败保留 pending。`PendingScan`
  的 ack/eventID 语义有直测。
- **P0 inline 编辑器覆盖外部改动**：`MetadataAPI.diskDescriptive` + Live 实现；
  编辑器初值改读盘（含 JPEG 内嵌），读盘失败 fail-closed 禁用保存。
- **P1 派生面归档泄漏**：`CullingService.list/getGroups` 过滤归档、归档导致
  成员不足的组隐藏（保留 minGroupSize=1 的合法单成员组）；`SimilarityService`
  的成员/ungrouped/legacy 回退同步，`getGroupMembers` 区分"无成员行（nil）"与
  "全部归档（[]）"；`DuplicateService` 隐藏可见成员 <2 的组；Face 簇成员/计数
  排除归档（孤儿成员仍保留）；WorkspaceStatus 用 `countVisibleBySession`。
- **P1 triage**：`TriageWritebackOutcome.undoable` + `TriageWritebackResult.undoAvailable`，
  UI 用 undoAvailable 决定撤销入口；undo 星级探测按 photoId 解析当前路径；
  undo 跳过星级时出提示。
- **P1 B1**：`descriptiveFromParse` 改表驱动，补 `location`、`intellectualGenre`、
  `subjectCode`、event/person/org 等；真实 JPEG 测试断言 IIM ContentLocationName。
- **P2**：共享侧车不再复制备份（孤儿）；模板无日期/相机占位符时跳过 EXIF 解析；
  `photos.requiredTableColumns` 加 archived_at。
- `summary.totalGroups` 从 stats_json 扣掉"成员全部归档"的组；部分归档不改快照
  口径（避免破坏既有摘要契约）。

## 第三轮复核修复（2026-10-28）

针对第三轮只读复核的 7 个 P1：

- triage undo 星级探测失败：区分“读不到”与“值为 nil”，写 failed 并保留批次可重试；
  beforeRating 改用 `diskAttributes`（含 JPEG 内嵌），不再回落缓存 exif.rating。
- 模板 `applyFields` 记录批次后若 `applyMetadataAttributes` 抛错：先 markUndone 再抛，
  不再留下“未写盘但可撤销”的批次。
- `MetadataFieldImpact` 新增 `diskKnown`；盘上读过但字段不存在时 beforeSnapshot
  保持 nil，undo 清空而不是复活缓存旧值。
- watcher 全树保底校验返回 job 的 checkpoint；仍被更窄任务挡住时不 ack、保留 pending
  并重新排队。
- 淘汰移出先筛出实际可移行再算 movingIds；资产内未淘汰兄弟不再被误判为“将移动”，
  共享侧车不会被搬走。
- 重复组 `resolveGroup` 与组级 resolution 派生只使用可见成员，归档件不参与 keep_one 评分。
- 新增 4 条测试（triage 探测失败/盘上基线、beforeSnapshot、重复组归档）；core 1364。

## 未做 / 需人工验收

1. **真机矩阵**：C1 存储卡 RAW+JPEG、Bridge 写内嵌 IPTC 的 JPEG、跨页 100 张移出、共享边车移出、500 张模板、undo 星级守卫；本机未跑（需要真实素材）。
2. **关键词层级/facet、Gallery facet/规则、交付联系表、AI 决策门**：按计划留到 W2，本轮未动。
3. **移出不可撤销**：仍为单向（`_rejects` 人工找回），与计划一致。
4. `sessions.photo_count` 仍是物理登记数（不含"已移出"语义）；UI 未加"已移出 M"文案，属于后续 polish。

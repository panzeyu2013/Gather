# P1 下一波合并后只读评审台账（2026-10-30）

> 对象：合并提交 `ebeb507a`（`feat` d4f72e8c → `main` 1e9a6907）；对照 `git diff 1e9a6907..ebeb507a`。
> 方式：5 个只读分面评审员（A 持久层/数据面、B 服务与交付、C Host/内嵌写回、D UI/ViewModel 与合并语义、
> E 合并语义/测试有效性/门禁与文档），各自只读、不跑构建；主 agent 独占构建/测试并逐条复核关键代码路径。
> 本文只记结论与证据，修复另开提交。

## 1. 合并与验证事实

| 项 | 结果 |
|---|---|
| 合并规模 | 158 文件 +24,125 / −859（Swift 148 文件 +22,704 / −834；测试 25 文件 +4,305） |
| 冲突 | 5 处文档/基线（README、docs/README、DEVELOPMENT、ADR、ROADMAP、design-system-baseline）手工解；14 个双侧改动文件全部自动合并 |
| gather-core | 合并当天 **1,609 / 239** → 修复波后 **1,616 / 240**（1,591 并行主批 + 25 串行状态批），exit 0 |
| gather-app | 合并当天 **829 / 93** → 修复波后 **843 / 95**，exit 0 |
| schema | **55 表 / 449 列 / 86 索引（8 UNIQUE）/ 81 外键**，user_version=1（84→86 是修复波补的两个 FK 索引） |
| 本地化 | en **2,018** 键 / zh 9 占位键 |
| 门禁 | **12 道 `check-*.sh` 全绿**（可用者带 `--strict`；cleanup ratchet 60/255/0/0/0 全持平） |
| design-system | 显式上调 `spacing.literalPadding` 175→206、`literalSpacing` 257→261（`--allow-growth`），理由见 `docs/reviews/p1-next-wave-ratchet.md`；同次的 `empty.contentUnavailable` 29→28、`font.callout` 89→86 是收紧 |
| 测试 ratchet | 合并收口时收紧：`@Test` 2264→2438、`@Suite` 249→273、断言 10509→11280（否则新测试有"删除免检额度"） |
| 命令 | `SWIFT_TEST_FLAGS=--disable-sandbox CLANG_MODULE_CACHE_PATH=/private/tmp/gather-clang-module-cache ./scripts/test.sh core|app` |

## 2. 结论

合并可以留在 main（无 P0；交付/回写主链、schema 三处计数、筛选单一真相源都自洽；
14 个双侧冲突文件逐行核对为真并集，新增测试无空壳断言），
但**在把"立即清理"和"内嵌回退写回"交到用户手上之前，必须先修 4 条 P1**：
内嵌回退路径会清空 Lightroom 层级关键词、`cleanupRetention` 忽略 sessionId 全局删备份、
保留期设 0 仍执行删除、孤儿备份清理用子串白名单（可能误删用户文件）。

## 3. P1（按修复优先级）

| 编号 | file:line | 证据 | 影响 | 修复 | 判定 |
|---|---|---|---|---|---|
| P1-1 | `GatherHost/SidecarXMPProvider+Patching.swift:150` + `Embedded/MetadataWriteRouter.swift:219` | `("lr:hierarchicalSubject", encoded.hierarchical),` / 回退读走 `ImageIOExifProvider().parse`（不返回 lr 命名空间） | 内嵌快路径不可用时（XMP 不可解析 / 头 >4MiB / `embedded_fast_path=0`），基线 keywords 只剩叶子，重写后 lr 层级被拍平成单段——Lightroom 层级关键词静默丢失 | 回退路径也用 `XMPPacketReader` 读 lr；读不到 lr 时不要重写该元素 | 代码路径【已确认】，触发频率未实测 |
| P1-2 | `GatherHost/APIs/LiveMetadataAPI.swift:125-141` | UI 传 `MetadataCleanupInput(sessionId: sessionId, ...)`，Host 只用 `input.value.ignoreReloadAck` → `retention.run(policy:)`（`MetadataRetentionService.swift:156`）无会话参数 | 在某个会话的检查器点"立即清理已确认备份"，会确认（written→synced）并删除**所有会话**的已确认交付行与备份（备份是唯一撤销点） | run 增加 session 作用域；或入口移全局设置页并写明"全部会话" | 【已确认】 |
| P1-3 | `GatherApplication/Services/Maintenance/MetadataRetentionService.swift:175-180`（对照 :34、:63-74） | `purgeEmptyRows(...)` / `purgeVanishedRows(...)` / `purgeOrphanBackups(...)` 在 `if policy.isEnabled { … }` 之外 | `metadata_backup_retention_days=0`（注释写"不自动删"）后仍删"xmp 已消失"行的备份与孤儿备份，设置无法阻止删除 | 三条清理纳入 `isEnabled`，或改文案为"只影响已确认交付的保留期" | 【已确认】 |
| P1-4 | `MetadataRetentionService.swift:400-415` + `GatherDelivery/File/DeliveryBackupPath.swift:93` | `guard DeliveryBackupPath.isControlledName(name) else { continue }` / `return controlledMarkers.contains { name.contains($0) }` | 扫的是 `sessions.source_path`（用户照片目录）第一层，只按"文件名含标记"判定：任何 >24h、DB 无引用的常规文件，名字含 `.gather-backup-`/`.gather-header-`/`.gather-archived-` 就被删；`.gather-archived-` 全仓无生产者 | 复用 `DeliveryBackupPath.validate`（从文件名反推 xmp 并锚定）；删掉无生产者的标记 | 谓词【已确认】 |
| P1-5 | `GatherApplication/Services/Output/ProofFeedbackService.swift:167/193/214` | `if try repo.batchExists(batchId: batchId) {`（短路）… 先 `insertBatch`，后 `applyImportedPicks` | 落库后、应用前抛错（DB 错、`localRatingStates`）会留 `applied_at=''` 的行；重试被 `batchExists` 短路成 alreadyImported/0 变更 → 客户勾选/评分永久丢失且 UI 显示"已导入" | 短路改为"该 batch 的 applied_at 全非空"；或 insert+apply 同事务；或补"未 applied 重放"入口 | 代码路径【已确认】 |
| P1-6 | `GatherDelivery/Writeback/WritebackService+Execute.swift:507-519` + `GatherHost/Embedded/EmbeddedJPEGSession.swift:332/341/348` | `phaseOne.recordBackup(...)` 在 commit 之前 / `state = .closed(path)` 后 `abort()` 直接 `guard !state.isClosed else { return "" }` | commit 失败 → abort 删掉本次新建的 `.gather-header-` 备份，但 phaseOne 仍登记；同组后续 item 成功时把已删路径写进 `deliveries.backup_path` → 之后 cleanup/restore 永久 `XMP_BACKUP_MISSING`，而这次写盘没有活的撤销点 | abort 后清 phaseOne 登记，或把 recordBackup 移到 commit 成功之后 | 代码路径【已确认】 |
| P1-7 | `GatherUI/Curation/StackFoldIndex.swift:70` + `GatherUI/Gallery/GalleryViewModel+Derived.swift:87-90` | `result.append(fold.displayCoverPhotoId ?? photoId)` / `return visible.compactMap { byId[$0] }` | 封面不在当前输入（被 facet/4 档筛掉，或封面在未加载的后续页）时，emit 的封面 id 不在 byId 里被丢弃 → **整堆连同命中成员一起消失**，而徽标仍按全堆张数显示 | 封面仅在输入内时用它，否则回退该堆在输入里的首个成员 | 【已确认】 |
| P1-8 | `GatherPersistence/Database/Repositories/CollectionRepo.swift:231-236`、`StackRepo.swift:116`（对照 `SchemaCurrent+DDLCore.swift:96`） | `-- 所有"用户可见"读面必须加 archived_at IS NULL（PhotoVisibility），` / collection items 只 `JOIN photos p ON p.id = ci.photo_id` | 淘汰移出（filepath 已指向 `_rejects`）的照片仍在集合成员/堆栈折叠里出现；`collection itemCount` 与 keyword facet 的可见口径不一致 | items/folds/members 与 count 子查询加 `PhotoVisibility.visiblePredicate(alias: "p")` | 【已确认】 |
| P1-9 | `GatherApplication/Services/CurationService.swift:290-291` | `_ = try stacks.detachPhotos(photoIds: photoIds)` / `return try stacks.addMembers(stackId: row.id, photoIds: photoIds)` | detach 事务已提交后 add 失败：照片失去原堆栈（旧空堆栈已删），API 却返回失败；同文件 `createStack` 明确把两步包进一个事务 | 用 `connection.transaction` 包住 detach+add；`removeStackMembers` 的判空+delete 同样入事务 | 【已确认】 |
| P1-10 | `GatherHost/C1RoundTripCoordinator.swift:267` + `AppBootstrap.swift:362-364` | `let statusPreflight = await bridge.preflight()` / `"c1_auto_reload", defaultValue: "1"` | 协调器无"本机是否装 C1"判定；没装 C1 的用户每轮写回收敛后都会 spawn osascript（System Events 探测）→ 非预期自动化授权弹窗 | 用组合根的 `c1Required` 前置短路，或缓存"无 C1"结果 | 【已确认】调用存在，弹窗未真机验证 |
| P1-11 | `GatherHost/Composition/Core.swift:134-137`（对照 `DeliveryCoordinator.swift:234/444`） | `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.captureone.captureone") != nil` | 该闭包被 confirm（每模块）、`isAwaitingReloadAck`、`state()`（状态条轮询）逐次读取：每次两次 LaunchServices 查询且落在同步门禁路径；运行中 C1 安装状态变化会中途改变门禁语义；与协作契约"必须是廉价的同步读、由组合根传入设置 + 最近 preflight 缓存"不符 | TTL 缓存 / preflight 结果 + 设置变更失效 | 实现与文档不符【已确认】，耗时未实测 |

## 4. P2（按分面汇总，逐条可定位）

- A（持久层）：A3 `KeywordIndexSync.swift:83` 只物化叶子、`keywords` 与 `photo_keywords` 路径集合永久不一致，`rename("Travel")` 对 `Travel|Paris` 抛 notFound；A4 `PhotoFilterQuery.swift:199` descending 只作用于游标（页内仍升序）且 `allowedSortFields` 无消费者；A5 新表两个 FK 子键无索引（`photo_stacks.cover_photo_id`、`client_proof_feedback.photo_id`）；A6 11 张新表只进列数清单，CHECK/CASCADE 零用例；A7 `usage_count` 只在 `replacePhotoKeywords` 重算（只增不减）；A8 非级联删除不查 `keyword_synonyms`；A9 `moveItem` 读快照在事务外、`reorderItems` 与未列出成员 position 可并列（疑似）。
- B（服务/交付）：B6 `MetadataLifecycleRepo.swift:230` `deleteVanishedRow` 事务内不复核 items/status/lease；B7 `SemanticIndex.swift:254` `limit: 0` = 全会话无上限（20k×2048 展开约 160MB+，每次检索重算）；B8 `TriageCalibrationService.swift:177` `min_samples=0` 变成"恒样本不足"，报告文案自相矛盾。
- C（Host/写回）：C4 `C1RoundTripCoordinator.swift:265` `notSettled` 依赖同 written 计数的下一次事件，失败收敛永不自动 reload 也无提示（疑似）；C6 `JPEGMetadataWriter.swift:308` `.gather-embedded-` 不在孤儿白名单 → 崩溃残留整份照片副本永不回收；C7 `CaptureOneBridge.swift:137` 单路径 `error:<msg>` 被当"未找到"，多路径可能 fallback 成 `open -a` 整批导入；C8 `LiveMetadataAPI.backupStats` 协议+Host 有、UI 无调用（假接线）。
- D（UI/VM）：D2 `ExportView+Delivery.swift:257` 把 `manifest.json`（含绝对路径）加进 WebDAV 发布白名单，客户可读到本机目录结构；D3 `GalleryInspector.swift:169` 注释承诺"清条件"但无清除代码、`_ = await locatePendingPhoto` 丢弃 outOfRange；D4 `GalleryViewModel+Filters.swift:283` 保存查询的搜索词恒还原不出（`searchString` 只认 5 条同字段规则，死分支）；D5 `+Derived.swift:24-28` facet 也算 searchActive → 点一次 facet 就 `chainFetchIfActive` 拉满整命中集；D6 `CullingInspector.swift:565` 校准写入后不广播 `settingsChanged`，挑片页阈值不刷新；D7 `CollectionView.swift:276` "移出集合"是唯一无确认/无撤销的破坏路径（并丢弃手动排序）；D8 `CollectionSidebar.swift:278` 建集合失败复用 `loadFailed`，错误显示成"集合加载失败"；D9 `CullingWorkbenchViewer.swift:314` + `ViewerOverlays.swift:479` 参考胶囊渲染两次；另有两条原始错误串直上屏：`MetadataSyncBar.swift:168`、`SemanticSearchPanel.swift:89`。

### 4.1 E 分面（合并语义 / 测试有效性 / 门禁与文档）

- E-1【已修】`scripts/check-test-catalog.sh:345/369` 的 ratchet 未随合并收紧（2264/10509 vs 实测 2438/11280）→ 已改为 2438/273/11280，`--strict` 复跑绿，记账进 `docs/reviews/p1-next-wave-ratchet.md`。
- E-2 `docs/design/p1-next/plan-2026-10-30.md:988` 写"13 道门禁全绿"：feat 分支验收时确有 `check-docs.sh`（13 道），主干 76db8e41 已删 → 本文保留历史口径，不改成 12。
- E-3 设计系统 baseline 4 个键变动中，`font.callout`（89→86）与 `empty.contentUnavailable`（29→28）是收紧且 `check-design-system.py:134` 允许静默下调 → 已在台账显式补记。
- E-4 `GatherUI/Gallery/GalleryViewModel+Load.swift:61` 注释说"成功后刷新集合菜单数据"，但 `addToCollection`（:62）落库后不调 `refreshCollections()`（`createStack` 会调 `refreshStackFolds()`）→ 加入集合后菜单陈旧。
- E-5 `GalleryViewModel+Load.swift:93-94` `performLoad` 末尾串行两次 RPC（stackFolds + collections），失败只 debug 日志；若 load-more 复用同一入口则每页成本翻倍（疑似）。
- E-6 `Resources/zh-Hans.lproj/Localizable.strings` 只有 9 条占位、`en` 从 1,865 增到 2,015（+150），12 道门禁都不覆盖 zh 覆盖率 → 需明确"zh 不在范围（en-only）"还是补覆盖率门禁。

## 5. 复核过且没问题的点（勿重复排查）

1. **Schema 三处自洽**：DDL 实况 = `SchemaCurrent` 常量 = 逐表列数测试 = 55/449/84(8 UNIQUE)/81；`Schema.swift` 已不是 DDL 镜像（只剩 `currentSchemaVersion` 与 `activeAnalysisJobStatusSQLList`），"两侧 DDL 漂移"不成立。
2. **交付主链**：reload-ack 门禁下沉到 repo 事务（`DeliveryCoordinator.swift:490`），`adoptLegacyRows` 不会把未 ack 的交付翻 synced；finalize 的 module 作用域 + retained 分支 + 备份删除（DB 提交后、有 reappeared 守卫）逐条对得上。
3. **没有 feat 自开写回通道**：`CullingViewModel+Writeback.swift:300-306` 是唯一 reload 出口，自动触发只调 `noteDeliveryStateChanged`，与 main 的 `commitChain` 串行化不冲突；`GalleryViewModel+Load.swift:151` 的 `fetchGeneration` 未被 facet/堆栈绕过。
4. **筛选单一真相源**：facet/规则/4 档/搜索串在 `activeCriteria` 合成一个 `FilterGroup`，reload 时一起提交并清空游标；`LibraryFacetBar` 已改为包装共享 `FacetBar`（不是两套实现）。
5. **SQL 全参数绑定**：新仓储的插值只用于列名/占位符；`KeywordPathSQL.subtreePredicate` 返回 `(sql, params)`，path 走绑定。
6. **内嵌写回工程质量**：FileHandle 分块 + 临时文件 + `replaceItemAt` + 落地后重解析校验；`XMPPacketReader` 对畸形包 fail-closed（返回 nil → 回退）；段重建只替换首个 XMP、非编辑段逐字节保留。
7. **破坏性入口**：writeback / retry / cleanup / finalize / reset / resolve 全部 `Confirmed(…, source: .userDialog)`；新增入口里唯一例外是 D7"移出集合"。
8. **本地化**：`LocalizationParityTests` 通过（无重复键、无孤儿键、代码 key ⊆ en），新增 UI 文案无缺口。
9. **测试与门禁**：25 个测试文件 +4,305 行；`@Test` 2,438 / `#expect` 11,280（ratchet 已收紧到实测值）；12 道门禁全绿、cleanup ratchet 全持平。
10. **14 个双侧文件是真并集**：逐文件比对 `diff(1e9a6907..merge)` 与 `diff(d4f72e8c..merge)` 的行数，恰好互为对方相对 base 的改动量（CullingWorkbenchViewer 393/49、GalleryViewModel+Load 100/25、en.strings 178/13），没有一侧修复被整段吃掉；`RootView` 的 `reduceMotion`（主干）与 `.environment(\\.curationServices)`（feat）都在。
11. **新增测试不是空壳**：13 个新测试文件无 `#expect(true)`、无字面量对字面量断言，断言密度 3–8 条/用例（SemanticIndexTests 8/30 最薄）。
12. **protocol-surface 记账与实测一致**：409 类型 / 2,442 声明，`zero_reference_types=0` 抽查 10 个新类型均有 ≥2 处生产引用，不是空转。

## 6. 未覆盖 / 限制

- 五路评审全部只读：未跑 `swift build/test`、无 GUI/真机/视觉/键盘验收；测试数字来自主 agent 实测。
- P1 均为静态证据；`cleanupRetention` 范围、`retention=0` 仍删、堆栈折叠丢行、内嵌 abort 悬空路径由主 agent 复读代码确认；TCC 弹窗、GC 竞态、LaunchServices 耗时、20k 语义检索内存未真机/插桩验证。
- 无签名/公证、x86_64 只编译不运行；C1 真机（osascript 时序、`replaceItemAt` 在真卷上的原子性）未验证。
- 未审范围外文件：`LiveFaceAPI`/`LiveSimilarityAPI`、`GalleryViewModel+Events`、`CullingGrid/InfoBar/Toolbar` 与交互键位表。

## 7. 建议修复顺序

1. 数据安全：P1-1、P1-2、P1-3、P1-4（改动小、风险最高）。
2. 交付账正确性：P1-5、P1-6。
3. 策展可见性/一致性：P1-7、P1-8、P1-9。
4. C1 体验与门禁性能：P1-10、P1-11。
5. P2 里优先补 A6（新表 CHECK/CASCADE 用例，否则约束改坏不会红）与 D 组"无反馈/无确认"三条。

## 8. 修复波结果（2026-10-30，全量修复）

**结论：11 条 P1 与 24 条 P2 已全部处置**；4 条按"更小改动 + 明确记账"的替代方案落地。
修复后实测：core **1,616 tests / 240 suites**、app **843 tests / 95 suites**（exit 0）、
schema **55 表 / 449 列 / 86 索引（8 UNIQUE）/ 81 外键**、en **2,018** 键；
12 道门禁全绿；test-catalog ratchet 收紧到 2459/276/11342、protocol-surface 收紧到 408 类型 / 2437 声明。

| 编号 | 处置 | 关键位置 / 证据 |
|---|---|---|
| P1-1 | 修：内嵌读增补 XMP 优先合并（读回 lr 层级） | `MetadataWriteRouter.readEmbeddedXMPAttributes` + `readEmbedded`；新增 `MetadataWriteRouterReadTests`（4 例） |
| P1-2 | 修：`run(policy:sessionId:)` + **repo 级会话下推**（候选查询 EXISTS 过滤）+ 会话内孤儿回收（扫描根按会话、引用集合全库） | `MetadataLifecycleRepo`（`expired/empty/vanished/adoption/orphanRoots`）、`MetadataRetentionService`、`LiveMetadataAPI`；`MetadataRetentionTests` 4 例 |
| P1-3 | 修：三条 purge 纳入 `isEnabled` | 同文件；孤儿用例改 `isEnabled: true` |
| P1-4 | 修：锚定式孤儿判定（复用 `validate`），删除无生产者的 `.gather-archived-` | `DeliveryBackupPath.anchoredXMPPath(forBackupName:inDirectory:)` |
| P1-5 | 修：字段级重放（新增 `pick_applied_at`/`rating_applied_at` 两列；勾选与评分各记各的，设置关闭的评分不算待办） | `client_proof_feedback` 两列、`ProofFeedbackRepo.markPickApplied/markRatingApplied`、`ProofFeedbackService`；`ProofFeedbackTests` 2 例 |
| P1-6 | 修（方案 b）：commit 成功后才 `recordBackup`；`EmbeddedJPEGSession` 加 `committed` 锁让 abort 能删本次备份 | `WritebackService+Execute`、`EmbeddedJPEGSession` |
| P1-7 | 修：代表张只在输入内选，展开只插输入内成员 | `StackFoldIndex` + 新 `StackFoldIndexTests`（10 例，每例校验"输出 ⊆ 输入且无重复"） |
| P1-8 | 修：集合/堆栈用户可见读面加 `PhotoVisibility`；判空/封面校验改用不过滤的 `hasAnyMember`/`isMember` | `CollectionRepo`/`StackRepo`/`CurationService`；新 `CurationVisibilityTests`（2 例） |
| P1-9 | 修：detach+add、remove+判空+delete 各自同一事务 | `CurationService` |
| P1-10 | 修：全进程唯一 `C1Installation`（TTL 60s + 后台预热），协调器在 preflight 前短路；设置页挂载不再探测 C1 | `Composition/Core`、`C1RoundTripCoordinator`、`AppBootstrap`、`SettingsView` |
| P1-11 | 修：门禁判定改内存快照（stale-while-revalidate），不再每次查 LaunchServices | 同 `Core.swift` |
| A3 | 修：`ensure(paths:)` 物化全部祖先；**不改** rename 驱动源（会牵动计数口径，ensure 修好后不再分叉） | `KeywordRepo` |
| A4 | 修：行取回按方向排序；`allowedSortFields` 只留 rowid | `PhotoFilterQuery`、`PhotoInputs` |
| A5 | 修：补 `idx_photo_stacks_cover`、`idx_client_proof_photo`（必须在 workbench DDL 段：索引段先于 workbenchDDL，放 DDLIndexes 会 no such table） | `SchemaCurrent+DDLWorkbench`、`SchemaCurrent`（86 + 新指纹） |
| A6 | 修：新表 CHECK 6 例 + CASCADE/SET NULL 4 例（断言行数），索引断言 84→86 | `SchemaCurrentTests` |
| A7 | 修：抽 `recountUsage` 三路复用 + **DB 触发器**兜住照片/会话 CASCADE 删除 | `KeywordRepo`、`trg_photo_keywords_usage_after_delete`（`SchemaCurrent+DDLWorkbench`）；`SchemaCurrentTests` 1 例 |
| A8 | 修：非级联删除加 `hasSynonyms` 守护 | `KeywordRepo` |
| A9 | 修：moveItem 读入事务、reorder 续接未列出成员、create 事务内 nextSortOrder | `CollectionRepo`、`CurationService` |
| B6 | 修：`deleteVanishedRow` 事务内复核 status/lease/intent | `MetadataLifecycleRepo` |
| B7 | 修：语义检索分块扫描 + 有界 top-K（20k 上限、512/块） | `SemanticIndex` |
| B8 | 修：`minSamples <= 0` = 不设门槛（服务 + 协议 + VM + 卡片文案"未设门槛"） | `TriageCalibrationService`/`TriageCalibration`/`CullingViewModel+Triage`/`CullingTriageCard` |
| C4 | 修：`notSettled` 自排延迟重试（上限 5 次 ≈7.5s，超限只记一次日志） | `C1RoundTripCoordinator` |
| C6 | 修：`.gather-embedded-` 残留纳入可回收临时文件（原照片仍在），与备份口径分开计数 | `DeliveryBackupPath`、`MetadataRetentionService` |
| C7 | 修：输出以 `error:` 开头即抛 `C1_SCRIPT_FAILED`，不 fallback | `CaptureOneBridge` |
| C8 | 修：删除 `backupStats` 声明/实现与 `MetadataBackupSummary`/`MetadataBackupStats`（UI 零调用；状态条已由 `syncState` 提供同数据） | `MetadataAPI`、`LiveMetadataAPI`、`MetadataDeliveryService` |
| D2 | 修：manifest 移出 WebDAV 发布白名单 | `ExportView+Delivery` |
| D3 | 修：命中不在当前筛选时先清 facet/4 档再定位，四态都有可见反馈 | `GalleryInspector` |
| D4 | 修：`searchString` 与 `searchCriteria` 严格互逆（五字段 OR） | `GalleryViewModel+Filters` |
| D5 | 修：`searchActive` 收窄为客户端过滤路径；**同时补事件刷新的 criteria 缺口**（否则事件后滤镜消失） | `GalleryViewModel+Derived`、`GalleryViewModel+Events` |
| D6 | 修：校准写入后广播 `settingsChanged` | `CullingInspector` |
| D7 | 修：移出成员走确认门控 + 说明"position 丢失" + 成功 notice | `CollectionView`（新增 2 条 en 词条） |
| D8 | 修：建集合失败用 sheet 内 `actionError`，`loadFailed` 只表示读取失败 | `CollectionSidebar` |
| D9 | 修：参考胶囊只由查看器绘制（overlay 重复胶囊删除） | `ViewerOverlays`、`CullingWorkbenchViewer` |
| E1 | 修：test-catalog ratchet 收紧（2438/273/11280 → 2459/276/11342） | `scripts/check-test-catalog.sh` |
| E2 | 修：plan 文档补注"13 道为 feat 分支验收口径，现行 12 道" | `docs/design/p1-next/plan-2026-10-30.md` |
| E3 | 修：台账补记 2 个收紧键与净增口径 | `docs/reviews/p1-next-wave-ratchet.md` |
| E4 | 修：`addToCollection` 成功后刷新集合菜单 | `GalleryViewModel+Load` |
| E5 | 不改：`performLoad` 只由首次激活/重试调用，补载与事件刷新都不经过它（已写进注释） | `GalleryViewModel+Load` |
| E6 | 修（口径）：明确 zh 表只是 9 条占位、en 是唯一翻译表，中文覆盖率不在门禁范围 | `docs/DEVELOPMENT.md` |
| 错误串上屏 ×2 | 修：走 `l10n.errorText` / `APIErrorPresentation` 漏斗，原文进日志 | `MetadataSyncBar`、`SemanticSearchPanel` |

## 9. 残余波（2026-10-30 第二轮）

上一节列的 6 条残余已全部关闭：

| 残余 | 处置 | 证据 |
|---|---|---|
| P1-2 repo 级下推 + 会话内孤儿回收 | 候选查询加 `EXISTS (delivery_sessions…)`；`orphanRoots(sessionId:)` 只扫本会话目录，**引用集合仍全库**（缩引用会删错别人的备份） | `MetadataRetentionTests`：下推、9 条 s2 抢占下仍删 s1、会话内孤儿回收保留"被 s2 引用"的同目录备份 |
| P1-5 字段级重放 | `client_proof_feedback` 加 `pick_applied_at`/`rating_applied_at`；勾选/评分各记各的，`alreadyImported` 只在"没有待办且可办的字段"时为真 | `ProofFeedbackTests.replaysOnlyPendingField`（首导勾选成功+评分失败 → 二导补评分、勾选不重复）与 `disabledRatingIsNeverPending` |
| A6 补面 | 加 `saved_searches`/`photo_semantics` 的 CASCADE 用例 | `SchemaCurrentTests.deletingSessionCascadesCurationRows` |
| A7 CASCADE 计数 | 触发器 `trg_photo_keywords_usage_after_delete`（O(1) 递减，重算仍由仓储负责） | `SchemaCurrentTests.deletingPhotoKeepsUsageCountHonest` |
| `batchExists` 死代码 | 删除方法；文件头注释改为"判据是字段级时间戳" | 全仓 0 引用 |
| C4/C7/D4 行为用例 | 新增 `C1RoundTripTests`（C7 6 例 + C4 4 例，替身不 spawn 进程）与 `GalleryFilterSearchStringTests`（5 例） | `reloadCount == 1`、`syncStatus == maxSettleRetries+1`、未安装时 preflight 0 次 |

一并处理的两件事：
- **设计系统门禁的正则 bug**：`spacing.literalPadding` 用 `[0-9.]+` 匹配，字符集里的 `.` 让
  `.padding(.horizontal, 12)` 也算"数字 padding"（178/206 是误报）。改成要求紧跟数字后，
  再把 69 个文件 / 279 处可映射字面量换成 `GatherMetrics.Space.*`，baseline 收紧到
  **literalPadding 206 → 5、literalSpacing 261 → 89**。
- **schema 计数**：55 表 / **451 列**（+2 字段级列）/ 86 索引 / 81 外键，指纹
  `5ed1f5f2…07a01`；文档与逐表列数测试同步。

**仍留（明确记录）**
- 校样导入的**冲突**不写 `rating_applied_at`：含冲突的 batch 每次重导都会再报一次冲突
  （`alreadyImported` 为 false）。仓库没有"冲突已告知"列，做成一次性消费要么加列、要么改语义，
  本轮按"成功才记账"保留并在此记账。
- `gather-app/Sources/GatherApp/GatherApp.swift` 仍有 2 处数字 padding：`GatherMetrics` 是
  GatherUI 的 internal 符号，GatherApp 是另一个 target，要用就得先把 token 提为 public。
- 剩余非 token 间距（9/10/14/20/36/40/52/60 等）与 `spacing: 0` 31 处未映射——没有等值 token，
  强行映射会改视觉。
- 未验证项同 §6（C1 真机 TCC、20k 语义内存、`replaceItemAt` 真卷、GUI/视觉/键盘、签名公证、x86_64）。

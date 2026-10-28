# Cut 2 持久化层独立评审（R2）

- 评审对象：未提交的 Cut 2 SchemaV1 / Database / Delivery 重构（只读）
- 评审日期：2026-10-22
- 仓库：/Users/panzeyu2013/Desktop/code/develop/Gather
- 结论：SchemaV1 与 Database 门面的主体是可靠的；**Delivery 的“文件阶段—DB 阶段”之间缺少可比较的版本/指纹守卫**，存在可复现的旧备份覆盖新内容风险（P0）。跨会话确认、writing 租约、手动队列原子性、跨模块删除、手动队列无执行器、冲突裁决绕过门禁各有 P1（共 10 条）。未发现 SQL 注入。
- 证据口径：源码逐行 + 从 `SchemaV1.sql` 在 SQLite 内存库重建后的 pragma 实测 + 定向测试实跑。文中“已确认”指源码/实测直接证明；“疑似”指需要特定并发或数据状态才触发、本次未复现。
- 只读约束：本次只写本报告，未改源码、测试、Package 或脚本。

---

## 0. 范围与方法

### 0.1 阅读/核对范围

- Schema：`Sources/GatherPersistence/Database/SchemaV1.swift`、`Schema.swift`
- Database 门面：`Database.swift`、`DB.swift`、`DatabaseError.swift`、`DeliveryState.swift`、`DeliveryError.swift`
- Delivery：`Repositories/DeliveryRepo.swift`、`DeliveryIntentRepo.swift`、`DeliverySummaryQuery.swift`、`Services/DeliveryCoordinator.swift`
- 接线：`Services/WritebackService.swift`、`MetadataMutationService.swift`、`MetadataService.swift`（写路径段落）、`SessionService.swift`、`AssetRepo.swift`（relink）、`IndexerService.swift`（照片删除）、`WorkspaceStatusService.swift`
- 宿主：`gather-app/Sources/GatherHost/AppRuntime.swift`、`AppComposition.swift`
- 测试：`SchemaV1Tests`、`SchemaV1RowMappingTests`、`DatabaseFacadeTests`、`DeliveryRepoTests`、`DeliveryIntentRepoTests`、`DeliveryCoordinatorTests`、`SessionServiceTests`、`AssetRepoTests`

评审边界：未做真实磁盘的崩溃注入、未做 GUI 手工验收、未在 CI 环境复跑；文件阶段结论来自源码路径与内存 fake 的行为对照，已单独标注置信度。

### 0.2 实测命令与结果

1. 从 `SchemaV1.swift` 抽取 sql 后在 Python sqlite3 内存库执行：
   - `tables=43, columns=373, explicit indexes=69 (8 UNIQUE + 61 普通), foreign_keys=62, user_version=1`
   - FK 动作：`CASCADE=52, SET NULL=7, RESTRICT=3`
   - RESTRICT 明细：`role_bindings.cluster_id`、`person_photos.photo_id`、`person_photos.session_id`
   - SET NULL 明细：`photos.asset_id`、`photos.asset_file_id`、`session_assets.display_file_id`、`asset_analysis.photo_id`、`face_clusters.matched_person_id`、`face_identity_feedback.person_id`、`navigation_groups.lead_photo_id`
2. `swift run --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify`（gather-core）
   - `schema ok: tables=43 user_version=1 foreign_key_violations=0`，exit 0
3. 定向测试（gather-core）：
   - `swift test ... --filter 'SchemaV1Tests|SchemaV1RowMappingTests|DatabaseFacadeTests|DeliveryRepoTests|DeliveryIntentRepoTests|DeliveryCoordinatorTests|SessionServiceTests|AssetRepoTests'`
   - **121 tests / 12 suites passed，exit 0**
4. 全量 core 测试（strict 依赖检查）：**1092 tests / 157 suites passed，exit 0**。
5. 全量 app 默认并行测试（用于核实并行测试是否失败）：
   - `swift test ... --explicit-target-dependency-import-check error`（gather-app，未加 --no-parallel）
   - **581 tests / 66 suites passed，exit 0**；本次**未复现**另一评审线索所称的“默认并行必失败”（详见 P2-7）。

### 0.3 数量口径结论

43 表 / 373 列 / 69 索引 / 62 FK / user_version=1 与源码头注释、`SchemaV1Tests` 的表清单、文档口径一致；69 中 8 个 UNIQUE。**静态抽取未发现 DDL 与代码 INSERT/UPDATE 的列名漂移**（对全仓 Swift 源码抽取 INSERT 列表与 UPDATE SET 列，与 pragma table_info 对账，0 处未知列；不覆盖动态拼接列名，但本仓未发现此类）。

### 0.4 约束语义核对（通过项）

- 3 条 RESTRICT 都是 NOT NULL 列（`role_bindings.cluster_id`、`person_photos.photo_id/session_id`），语义与“不能 SET NULL，只能显式迁移/删除”一致；`SchemaV1Tests:612-727` 逐一验证了拒绝路径。
- `SessionService.deleteSessionDependencies`（141-160）的删除顺序在 SQLite 模拟中通过（先删 role_bindings/person_photos，再删 photos/sessions）；`FaceRepo.deleteClustersBySession`/`removeMemberFromCluster` 也是“先删绑定再删簇”。
- `face_clusters.matched_person_id` 的 SET NULL 不会自动改 status，但生产删除唯一入口 `PersonRepo.applyIdentityTransition(.delete)` 显式把 `status='unbound'`（`PersonRepo.swift:493-506`），合并路径把 feedback/person_photos/embeddings 改挂到目标身份（509-533）；未发现绕过它的生产 DELETE persons。
- 62 FK 与 DDL 的 52/7/3 动作分布、`PRAGMA foreign_key_check` 在空库/测试库均无违规；`Database.open` 的连接级 `foreign_keys=ON` 与自检顺序正确。

---

## 1. P0（必须先修）

### P0-1 cleanup/replay 的文件阶段不校验 revision/指纹，旧备份可覆盖新写入的 XMP

**位置**
- `DeliveryCoordinator.swift:566-658`（cleanup：重读 573 → 指纹 585 → prepare 624 → **await 文件阶段 636** → advance 644 → DB 删除 653）
- `DeliveryCoordinator.swift:1012-1051`（replay：prepared 直接 **performFilePhase 1028-1029**，之后才 advance/DB）
- `DeliveryCoordinator.swift:1106-1123`（restore 覆盖写 1118-1121；无备份时**删除整个 sidecar** 1110-1113）
- `DeliveryCoordinator.swift:309-348`（intent payload 只有 action/delivery_id/revision/backup_path/photo_path，**没有 base_fingerprint**）
- `DeliveryRepo.swift:925-965`（deleteSyncedDelivery 的 revision/status 守卫只在 DB 段，晚于文件段）
- `gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:209-228`（orphan restore：先 restore/removeFile，再 deleteOrphanDelivery；同一缺陷的第二个入口）

**证据**
1. cleanup 在 prepare 之后、restore 之前不再复核 revision/状态：573 的重读发生在 prepare 之前；636 的 `await performFilePhase` 期间新输入可经 `mergeInput` 把 revision+1、status 置 pending（`DeliveryRepo.swift:433-444`），而 restore 不读这些字段。
2. restore 后 `applyCleanupDB` 才做 CAS，得到 `.revisionChanged/.stateChanged` 时走 `finish(error:)`（`DeliveryCoordinator.swift:1156-1189`），此时文件已经被旧备份覆盖；intent 还会被标 applied 并在下次 replayAll 删除（`DeliveryIntentRepo.swift:325-331`），丢失“文件已旧、DB 未删”的事实。
3. replay 的 prepared 分支无条件重做文件（1028-1029），payload 无指纹，无法像 cleanup 那样做外部修改检测（cleanup 的指纹检查在 585-609，replay 完全没有对应逻辑）。`flush`/`retrySync` 会直接触发 replay（`CullingService.swift:1218,1227`；`FaceKwService.swift:1263`；`SimilarityService.swift:718`）。
4. 无备份场景（backup_path 为空）会删除当前 xmp（1110-1113），同样不校验 revision；新输入写出的 sidecar 会被直接 unlink。
5. 第二入口：`LiveMetadataAPI.resolveOrphan` 的 restore 分支（209-228）同样在 restore 之后才用 `deleteOrphanDelivery` 做 revision 守卫；期间该 xmp 被新会话/新输入重新链接时，文件已被旧备份覆盖，delete 返回 false 只被当作“并发改写”忽略（220-224）。

**影响**
- 两条触发路径：①首次 cleanup 的指纹/restore await 窗口内用户继续编辑/写回；②restore 失败后 prepared intent 留存，用户继续编辑，再点 flush/retry 或重启应用。两者都会让旧备份覆盖新 XMP；DB 因 revisionChanged 保留新行，但**文件内容已是旧的**，用户的新关键词/rating/label 或外部编辑被静默丢弃。
- 无备份场景是直接删除新 sidecar，破坏性更大。
- 触发不要求进程崩溃：cleanup 的指纹/恢复是 async，写回只需要落在 await 窗口内。

**建议**
1. 在 intent payload 写入 `base_fingerprint`（及 delivery 的 id/revision/status 快照）；cleanup/replay 的文件阶段前重算指纹，不一致一律不 restore。
2. 文件阶段与 `mergeInput` 共用 per-xmpPath 的文件锁（或把“claim 文件阶段”做成 DB CAS：`UPDATE deliveries SET ... WHERE id=? AND revision=? AND status='synced'`，成功才允许碰文件）；restore 完成后若发现 revision 已变，必须把文件恢复成“新内容”而不是保留旧备份（至少记录冲突并提示）。
3. replay 的 prepared 分支先做 DB claim/revision 校验，再决定是否碰文件；fileDone 只补 DB 的规则保持。
4. 补测试：cleanup 在指纹与 restore 之间插入 mergeInput，断言文件仍是新内容；prepared intent + 新 revision 的 replay 不得覆盖。

**置信度：已确认（源码路径可直达，未被现有测试覆盖）**。

---

## 2. P1

### P1-1 新输入不重置其他会话的 confirmed_at，跨会话确认门禁可被绕过

**位置**
- `DeliveryRepo.swift:412-457`（mergeInput；SQL 433-444 只改 deliveries，不碰 delivery_sessions）
- `DeliveryRepo.swift:840-860`（linkSession；850-854 只重置**当前传入 session** 的 confirmed_at）
- `DeliveryRepo.swift:1024-1042`（confirm：把所有空 confirmed_at 的行写当前时间，然后“无空行”即翻 synced）
- 文档声称“重复链接触发 confirmed_at 重置为 ''（旧 mergePatch 同样重置全部链接）”：`DeliveryRepo.swift:834-835`，与实现不符。

**证据（SQL 级复现）**
构造：delivery `synced, revision=3`，s1/s2 两行 `confirmed_at` 均为旧时间；执行 mergeInput（revision→4, status→pending）+ linkSession(s1)（只把 s1 置空）+ markWriting/markWritten + s1 confirm。实际输出：

```text
confirm s1: confirmedLinks= 1 deliveriesSynced= 1
after: [('s1','2026-03-03'), ('s2','2026-01-01T00:00:00Z')] ('synced', 4)
```

s1 的新输入把交付重新打开后，**s2 从未看到新内容，但它的旧确认仍被当成有效**；s1 confirm 直接把 delivery 翻回 synced。

**影响**
- 违反 draft §5.4“所有关联会话都确认才翻 synced”和 D-025 的跨会话门禁语义。
- 之后 s1 视角的 cleanup 候选（`DeliverySummaryQuery.swift:132-169`：所有 link 非空 + 本会话 module item 全 synced）会命中，`deleteSyncedDelivery` 删掉 delivery_sessions/delivery_items/deliveries（`DeliveryRepo.swift:947-958`），s2 的链接与未消费状态被级联删除。
- UI 的 `otherSessionNotConfirmed` 永远看不到 s2，用户会误以为已全部确认。

**建议**
- `mergeInput` 在同一事务内 `UPDATE delivery_sessions SET confirmed_at='' WHERE delivery_id=`（所有会话一起失效）；`linkSession` 的重置语义保持不变（仅本会话）。
- 修正 834-835 注释；补“共享 sidecar：s1 新输入 → s2 必须重新确认”的回归测试（现有 `confirmWaitsForAllLinkedSessions` 只覆盖首次确认，未覆盖 re-edit）。

**置信度：已确认（SQL 复现 + 源码路径）**。

### P1-2 writing 租约没有恢复路径，崩溃后交付长期卡在 writing

**位置**
- `DeliveryRepo.swift:292-310`（markWriting；leaseOwner 默认 `""`，全仓无调用点传真实 owner）
- `WritebackService.swift:318-341`（`beginDeliveryWrite`：遇到 `.writing` 直接 `return current`，不校验 heartbeat/owner）
- `SchemaV1.swift:637-638`（lease_owner/heartbeat_at 两列）
- `DeliveryCoordinator.swift:999-1087`（replay 只处理 delivery_intents，完全没有 deliveries 的 writing 归位）
- `AppComposition.swift:162-165` 声称“writing 租约的归位由 DeliveryCoordinator.replay()……承担”；实际 replay 不碰 deliveries。

**证据**
- grep 全仓 `deliveries.lease_owner`：只有 Row 映射、markWriting 写入（永远写 `""`）、markWritten/Failed/Conflict/mergeInput 清空；**没有任何读取 lease_owner 做恢复/抢锁的代码**。heartbeat_at 同样只写不读（唯一读点是 JobService 的 analysis_jobs，不是 deliveries）。
- 崩溃窗口：`WritebackService.execute` 先在 724 行 markItem(written)，再在 772-778 行 markWritten；两者之间进程退出 → delivery 停在 writing、item 已是 written。下次 execute 只会处理 pending/failed item（566-569），该路径的空组不会进 writeRevisionByPath，delivery 不会自动收敛（只有再次 preview 把 item 重开为 pending 才会进入下一轮）。
- confirm 门禁把 writing 列为阻断（`DeliverySummaryQuery.swift:94-105` + `DeliveryCoordinator.swift:531-534`），cleanup 候选只收 synced（132-169），finalize 也只收 synced（715），因此没有自动出路。

**影响**
- 崩溃/强退后该 sidecar 在用户重跑一次完整 writeback（preview+execute）之前无法 confirm、无法 cleanup；metadata 手动队列没有对应的 retry writing 入口，因此可能长期卡死。
- “租约”字段是装饰性的，无法防止两个写者同时进入（见 P1-6），也无法判断过期。

**建议**
- 启动 replay 增加 deliveries 归位：把 `status='writing'` 且 heartbeat 超时（或 owner 非本进程）的行改回 `failed`/`pending`，并记录错误；或至少在 open 后把所有 writing 归 pending（开发期可接受）。
- 执行器写真实 leaseOwner（进程+UUID）、定期 heartbeat；`beginDeliveryWrite` 对 writing 校验 owner/heartbeat，过期才接管。
- 补“崩溃在 markItem 与 markWritten 之间”的恢复测试。

**置信度：已确认（代码路径 + 字段消费 grep）**。

### P1-3 MetadataMutationService.enqueue 跨三个事务，部分失败会丢输入/留下幽灵 pending

**位置**
- `MetadataMutationService.swift:134-175`：`openDelivery`（150）→ `mergeItem`（158-165）→ `linkSession`（167），每一步内部各自 `connection.transaction`。
- `MetadataMutationService.swift:241-273`（openDelivery 走 mergeInput，revision+1、status pending、清 lease/error）。
- `MetadataMutationService.swift:179-233`（只有 queueMutation 走 PathSerialChain；`queuePhotoValues` 112-127 直接 enqueue）。
- 混用入口：`CullingService.swift:600,927` 调 queuePhotoValues；`MetadataService.swift:539` 调 queueMutation。

**证据**
- 三个事务之间没有外层事务；openDelivery 的 mergeInput 提交后，mergeItem 若抛错（约束/磁盘/并发）或进程退出，delivery 已经是 revision+1、status=pending、但没有任何 delivery_item。
- 此时该 delivery 对会话可见且 `delivery:pending` 阻断 confirm；在用户对同一 sidecar 再跑一次 preview+execute 之前无法收口，cleanup 只收 synced 也无法清理；用户看到“有未完成写回”但没有可执行项。
- 反之若 mergeItem 成功、linkSession 失败（例如 session 被并发删除，FK 拒绝），item 存在但没有 delivery_sessions 链接，会话/UI/cleanup 都看不到，成为孤儿 pending。
- queuePhotoValues 绕过 PathSerialChain：与 queueMutation 混用时同一 xmp 的“读当前文件→合并→入队”不是全串行；keywords append/remove 的整表替换可能覆盖另一入口刚写的词表。

**影响**
- 用户手动 rating/label/keywords 在中间失败时静默丢失（revision 已推进，无法从旧值恢复），并留下永久阻断态。
- 同路径并发写入的关键词更新可能丢一条（lost update）。

**建议**
- 把 `openDelivery + mergeItem + linkSession` 收进一个 `connection.transaction`（Repo 提供单事务 enqueue API，或在 service 层包一层 write）。
- queuePhotoValues 也走 `chain.run(path:)`，或统一只保留 queueMutation 一个入口。
- 补“mergeItem 抛错后 delivery 不得停在无 item 的 pending”的回归测试。

**置信度：已确认（事务结构）**。

### P1-4 mirrorWriteback/execute 的多步写盘与 DB 推进没有整体原子性，失败只记 errors

**位置**
- `DeliveryCoordinator.swift:861-930`（openDeliveryForWrite → markWriting 871 → 逐项 upsertItem ×2 880-897 → markWritten/markFailed 906-924 → linkSession 926；catch 只 `errors.append` 928-930）
- `WritebackService.swift:607-798`（写盘 679-680、markItem 724、markWritten 772-778 分步；失败只进 errors）

**证据**
- 每个 DB 动作都是独立事务；mirror 在 markWriting 成功后若任一 upsertItem 抛错（如照片已被删除导致 FK 失败），delivery 停在 writing，后续 linkSession 不执行；函数返回 errors，但已提交的部分不回滚。
- 同一个交付在一次用户写回中会被 reopen 多次：preview 的 `reopenDeliveryForInput`（`WritebackService.swift:498-499`）→ execute → mirror 的 `openDeliveryForWrite`（959-967）；revision 一次写回可能 +2 以上（见 P2-3）。
- `markFailed` 在无 written item 时才执行；混合 written+failed 时交付保持 written，失败 item 只靠摘要/门禁暴露（与注释一致），但 mirror 的失败路径可能让交付停在 writing 而不是 written/failed。

**影响**
- 部分失败留下 writing/pending 的交付，叠加 P1-2 后没有自动恢复；重试会重复写盘并继续推 revision。
- 错误只在调用方 errors 数组中可见，没有“交付状态已部分推进”的持久标记；下次启动无法判断该走哪条恢复路径。

**建议**
- 每个 xmp 的 DB 段（markWriting + item 状态 + markWritten/markFailed + linkSession）合并为单事务；文件写盘仍可在事务外，但写盘结果用 intent 记录。
- mirror 不再对刚 execute 过的交付做第二次 revision+1（它只是把生命周期状态投影回来），改为同一事务内 upsert；若必须镜像，先判断 status 与 revision 是否仍是本轮。
- 对 mirror 的 partial failure 明确定义“回滚到上一稳定态”或“保留 intent 供 replay”。

**置信度：已确认（结构），具体触发需并发/异常，未实跑复现**。

### P1-5 user_version=1 不能证明“列形是当前的”，同版本旧库会被当成当前库

**位置**
- `SchemaV1.swift:6-7`：Cut 5 给 similarity_cluster_meta +3 列（370→373），**明确不 bump userVersion、不写迁移**。
- `SchemaV1.swift:18-23`：只有 user_version != 1 才重置。
- `Database.swift:313-324`：`case SchemaV1.userVersion: return .current`。
- `Database.swift:374-392`（assertReady）：只校验 user_version、foreign_keys、foreign_key_check；**不做表/列形校验**。

**证据**
- 任何在 373 列之前创建的 V1 库、或未来任何一次“直接改 V1 不 bump”的库，user_version 都是 1，open 走 `.current`，不进 reset；第一次访问新列时抛 `no such column`，被映射为 `.schema`（`DatabaseError.swift:156-160`），而不是“不兼容库重置”。
- `gather-schema verify` 只验证 DDL 能否一次成型（内存库），不验证磁盘上已有库的列形；因此工具通过不代表本机旧库可打开。
- 这与 `SchemaV1.swift:9-11`“任何 schema 变更都必须改本文件并同步 bump userVersion”的注释自相矛盾（Cut 5 已经违反）。

**影响**
- 开发期本机旧库会以“schema 版本正确但查询失败”的形态出现，排查成本高；如果未来误把这种策略带进发行版，用户库会在升级后运行期报错而不是被安全备份重置。
- 重置策略（db/-wal/-shm 三件套）本身写得正确，但触发条件依赖一个不再可靠的版本号。

**建议**
- 二选一：每次列形变化 bump userVersion（哪怕开发期也 bump）；或在 open 的 assertReady 增加 schema 指纹校验（表数 43 + 关键列存在 + 索引数/外键数），不匹配走 reset。
- 在 `Database.open` 文档中明确“开发期直接改 V1 的代价是本机库必须手动删除/被判定不兼容”，不要让 user_version=1 看起来像完整性证明。

**置信度：已确认（代码与注释直接矛盾）**。

### P1-6 同一 sidecar 的并发写没有串行化，culling 还被豁免于跨模块门禁

**位置**
- `WritebackService.swift:234-248`（assertNoActiveOtherModule；245 行 `typed == .culling` 直接 continue）
- `WritebackService.swift:607-698`（每个 item 读盘 654 → 合并 → 写盘 679；无跨调用锁）
- `WritebackService.swift:318-341`（writing 被复用；markWriting 自迁移允许重复）
- `DeliveryState.swift:47-74`（writing→writing 合法）+ `DeliveryRepo.swift:386-391`（allowedFrom 包含 writing）

**证据**
- 两个并发的 execute（例如 culling 与人脸关键词同时写同一张照片的 sidecar，或两个会话共享 sidecar）都会通过门禁：culling 被显式豁免；同一 xmp 的写者是“读当前属性→合并关键词/rating→写回”，两个写者的 RMW 交错时后写者会覆盖先写者的新增关键词。
- 没有 per-xmp 的 actor/NSLock/文件锁；`DeliveryRepo.markWriting` 的 CAS 对 writing 也成立，不能充当互斥。
- `beginDeliveryWrite` 对 writing 直接复用，等于第二个写者不需要抢锁就能进入。

**影响**
- 用户可见的 XMP 关键词/评分丢失（一个模块刚写入的词被另一个模块的旧快照覆盖），且没有冲突记录；清理/confirm 仍会认为写入成功。

**建议**
- 对 xmpPath 建共享串行执行器（actor 或 lock map），preview/execute/mirror/cleanup/replay 的文件阶段都取同一把锁；或把 writing 做成真正的租约（owner+heartbeat+CAS），第二个写者必须失败/等待。
- 去掉 culling 的全局豁免，或给出“culling 永不与其它模块写同一 sidecar”的不变量并用测试钉住。

**置信度：代码已确认（无互斥）；实际触发需要并发调用，本次未实跑并发复现，标记为“疑似高频”。**

### P1-7 IndexerService 直接 DELETE photos，绕过了 person_photos RESTRICT

**位置**
- `IndexerService.swift:282-287`（缓存清扫：`DELETE FROM photos WHERE id IN (...)`，同一事务里删 session_assets/asset_files/assets）
- `SchemaV1.swift:473-481`（person_photos.photo_id / session_id 为 `ON DELETE RESTRICT`）
- `SessionService.swift:141-160`（唯一显式删 person_photos 的路径）

**证据（SQL 级复现）**
在 SchemaV1 内存库插入 session/photo/person/person_photos 后执行：

```text
indexer delete blocked: FOREIGN KEY constraint failed
```

同一套数据按 SessionService.deleteSessionDependencies 的顺序（先删 person_photos 再删 photos）则成功。全仓只有两处直接 DELETE photos：PhotoRepo.deleteBySession（被 SessionService 保护）与 IndexerService:285。

**影响**
- 生成缓存目录中的照片如果曾被标记身份，缓存清扫事务整体失败 → 索引/扫描 job 失败并反复重试；与 SessionService 的删除语义不一致。
- 触发概率取决于“生成缓存照片是否会被 person_photos 引用”，属低频但可构造。

**建议**
- IndexerService 删照片前显式 `DELETE FROM person_photos WHERE photo_id IN (...)`（或提供 PhotoRepo.deleteCascade 统一入口）；补“缓存照片已标身份仍可清扫”的测试。

**置信度：代码与 SQL 已确认；触发条件为条件性，标记“已确认/低频”。**

### P1-8 模块级 confirm/cleanup 删除的是文件级交付：其他模块的 pending/failed item 会被静默删掉

**位置**
- `DeliverySummaryQuery.swift:139-169`（syncedCandidates 只检查“当前 session + 当前 module”的 item：EXISTS synced 且 NOT EXISTS 非 synced）
- `DeliverySummaryQuery.swift:353-368`（itemCounts 按 module 过滤；确认门禁只数本模块 item）
- `DeliveryRepo.swift:947-951`（deleteSyncedDelivery 删除该 delivery 的**全部** items/links）
- `WritebackService.swift:234-248`（assertNoActiveOtherModule 只拦 written/synced，不拦 pending/failed）

**证据**
1. delivery 是“一个 sidecar 文件”粒度，item 是“(delivery, photo, module)”粒度；一个文件可同时有 culling 与 metadata 两个 item。
2. 用户先 queue 手动 metadata（item=pending，module=.metadata），再执行 culling writeback：culling 的 assertNoActiveOtherModule 只看到 metadata item 是 pending（不是 written/synced），放行；culling 写盘成功后 delivery=written、culling item=written、metadata item 仍 pending。
3. 会话确认 culling：`DeliveryCoordinator.confirm` 的 `summaryQuery.summary(sessionId, module: .culling)` 只统计 culling item（DeliverySummaryQuery:353-368），看不到 metadata pending，门禁通过；`DeliveryRepo.confirm` 把 delivery 翻 synced，只把 written item 翻 synced（1044-1051），metadata pending 保持。
4. 随后 cleanup culling：候选只要求 culling item 全 synced（139-169），于是 `deleteSyncedDelivery` 执行 `DELETE FROM delivery_items WHERE delivery_id=?`（947-948），metadata 的 pending 输入被静默删除，没有任何错误或摘要提示。

**影响**
- 用户已入队但尚未写盘的手动 rating/label/keywords（或其它模块的 failed item）会随着另一个模块的 cleanup/finalize 被删除；属于用户输入丢失，且 UI 不会告警。
- 与 draft §5.4“一个 sidecar 文件是一次原子写入，文件内容没有模块边界”的表述矛盾：确认按文件原子处理，删除却按模块判定。

**建议**
- 删除候选与 confirm 的收口条件改为“该 delivery 的**所有** item（跨 session、跨 module）均为 synced，或不存在 pending/failed/written”；
- 或在 cleanup/finalize 前统计 `SELECT COUNT(*) FROM delivery_items WHERE delivery_id=? AND status IN ('pending','failed')`，非零则 skip 并报 `XMP_CLEANUP_INCOMPLETE_ITEMS`；
- 补“culling synced + metadata pending → cleanup 不得删 metadata item”的回归测试。

**置信度：代码路径已确认；触发需要同文件多模块 item，未实跑复现。**

### P1-9 手动 metadata 队列在产线没有执行器：item 永远 pending，且阻断其它模块 confirm

**位置**
- `MetadataMutationService.swift:149-167`：`queuePhotoValues` / `queueMutation` 的唯一落点是 `deliveryRepo.mergeItem(..., module: .metadata, status: .pending)`（161 行）。
- `MetadataService.swift:539-545`：`setMetadata` 只把 patch 交给 `mutations.queueMutation`；`MetadataService` 只注入 `MetadataMutationPort`（146 行），没有 `WritebackService` 依赖。
- 产线 `execute` 调用点只有：`CullingService.swift:1300`（culling）、`FaceKwService.swift:1234`（face_kw）、`SimilarityService.swift:668`（similarity）、`SimilarityWritebackBridge.swift:38`（similarity）。全仓 Sources 中**没有** `execute(..., module: "metadata")`，也没有任何 job/命令消费 module=.metadata 的 item。
- 对照测试：`MetadataMutationServiceTests.swift:284-334` 手工调用 `writeback.execute(..., module: "metadata")` 才能把项写盘，证明执行器本身可用，但生产没有这条调用。

**证据/影响链**
1. 用户改 rating/label/keywords → `MetadataService.setMetadata` 写 delivery_items(module=.metadata, status=pending)，同时更新 photo_metadata_cache（`MetadataService.swift:547`），UI 显示“已保存”。
2. 这个 item 永远不会被消费：rating/label 只有在用户另行触发 culling 写回时，才可能被 culling 计划从 photo_metadata_cache 顺带写入（CullingService:1261 的口径）；手动 keywords 没有这条旁路（culling 关键词来自决策/计划，不读 metadata item）。
3. 由于 `mergeInput` 已把 delivery 置 pending，`DeliverySummaryQuery.summary` 的 blockers 会返回 `delivery:pending=1`（94-105）；在用户对同一 sidecar 再执行一次 culling/face/sim writeback 之前，这些模块的 confirm（`DeliveryCoordinator.swift:531-534`）都会被阻断。重写只能把 delivery 拉回 written，**metadata item 本身仍无消费者、永远不会落盘**。
4. 叠加 P1-8：culling 若通过其它路径重新写成 written 并 confirm/cleanup，metadata pending item 会被直接删除。

**影响**
- 手动元数据编辑“元数据缓存已更新、对应的 delivery item 永不落盘”；rating/label 可能被 culling 顺带写，keywords 则没有旁路。属于用户可见的静默丢失。
- 会让同一 sidecar 的其它模块 confirm 永久报 XMP_CONFIRM_INCOMPLETE（blockers=delivery:pending），且没有可执行的恢复入口。

**建议**
- 增加 metadata 写回执行入口（命令/job/flush 均可），加载 `listItems(module: .metadata, status: .pending/.failed)` 后调用 `WritebackService.execute(sessionId:module:"metadata")`；或把 rating/label/keywords 合并进下一次 culling/face/sim 的写回计划。
- 在接线前，至少不要让 manual item 把 delivery 置 pending（例如标记为“待写但不阻断”），否则 UI 会永久卡确认。
- 补一条“setMetadata 后存在可执行路径把 pending 变 written”的集成测试（当前只有手工 execute 的单元测试）。

**置信度：已确认（grep 全仓无 module=metadata 的生产 execute；MetadataService 无 writeback 依赖）。**

### P1-10 冲突“全部接受远程”直接 markSynced，绕过跨会话确认门禁

**位置**
- `gather-app/Sources/GatherHost/APIs/LiveMetadataAPI.swift:338-362`（acceptExternalState：conflict → markWriting → markWritten → **markSynced**；三步都只带 revision，不检查 delivery_sessions.confirmed_at）
- `DeliveryRepo.swift:341-351`（markSynced：written → synced 的单条 CAS）
- `DeliveryRepo.swift:1031-1051`（confirm：只有 status=written 才翻 synced；但 itemsSynced 子查询会把**任何已是 synced 的** target delivery 的 written items 一起翻 synced）

**证据**
1. 共享 sidecar s1/s2：delivery=conflict，s1 调 resolve_conflict 全部选 useRemote → `acceptExternalState` 直接把 delivery 标 synced；s2 的 delivery_sessions.confirmed_at 原样（未确认新内容）。
2. 之后 s1 confirm：step 1 只写 s1 的链接；step 2 因 delivery 已是 synced 不改；step 3 的 itemsSynced 子查询 `WHERE d.status='synced' AND d.id IN (targetSQL)` 仍会把该 delivery 的 written items 全部标 synced（1044-1051），即使 s2 的 confirmed_at 为空。
3. 只要 s2 之后（或之前）任意一次 confirm 把自己的链接写非空，cleanup 候选（139-169：所有 link 非空 + 本会话 module item 全 synced）就会命中并删除行；s2 从未对新内容确认。

**影响**
- 与 P1-1 同类的跨会话门禁绕过，但入口是“冲突裁决全部接受远程”，不需要 mergeInput。
- 冲突裁决本应是“把盘上状态固化为新基线”，不应替所有会话确认；当前实现让一个会话的裁决关闭了其它会话的确认义务。

**建议**
- acceptExternalState 只推进到 `written`（或 `pending`），把 synced 留给 DeliveryRepo.confirm 的“所有链接已确认”判定；
- 若要一次性结清所有会话，显式把它们的 confirmed_at 一起写入并在同一事务校验，而不是绕过；
- 补“共享 sidecar s1 接受远程后 s2 未确认 → delivery 不得 synced / cleanup 不得命中”的测试。

**置信度：已确认（代码路径；共享 sidecar 为触发条件）。**


### P2-1 metadataSummary 的 item 计数不按 module/session 收窄
`DeliverySummaryQuery.swift:216-222` 的子查询按 delivery_id 聚合**所有** delivery_items（不分 module/session），随后 227-239 只用 EXISTS 过滤“该交付确有本模块 item”。结果：同一交付上另一个模块（或另一个会话）的 failed/pending item 会把本模块摘要升级为 failed/pending（264-274）。
影响：culling 的 syncStatus 可能因 metadata 的失败项显示 failed；`WorkspaceStatusService.swift:306-315` 的三模块合并也会被跨模块项污染（显示层，不影响 confirm 门禁——门禁走 `DeliverySummaryQuery.summary` 的 module 过滤）。
建议：子查询加 `JOIN photos p ON p.id=di.photo_id AND p.session_id=? AND di.module=?`，与 summary 的口径一致。

### P2-2 SessionService.listSessions 是 2N+1 查询
`SessionService.swift:92-94` 对每个 session 调 `toSessionData`（235-256），后者每次 new 一个 `DeliverySummaryQuery` 并调 `summary`（`DeliverySummaryQuery.swift:119-127` → deliveryCounts + itemCounts 两条聚合 SQL）。N 个会话 = 2N 条聚合查询 + list 本身。
影响：Dashboard/会话列表规模大时明显；属于 N+1，不是正确性问题。
建议：list 路径一次聚合（按 session_id GROUP BY）后在内存拼装，或给 SessionRepo 提供批量 delivery 摘要。

### P2-3 一次写回会多次推进 revision，“输入版本号”语义被污染
preview 对 written/synced/failed/conflict 调 `reopenDeliveryForInput`（`WritebackService.swift:295-313, 498-499`，mergeInput revision+1），mirror 又对刚 execute 的交付调 `openDeliveryForWrite`（`DeliveryCoordinator.swift:959-967`，再 +1），CullingService 在 execute 后无条件镜像（`CullingService.swift:1300-1308, 1438`）。
影响：revision 不再等于“第几次用户输入”，CAS 失败/attempt 诊断和 cleanup payload 的 revision 语义都偏移；并发下更容易出现 revisionChanged 的假跳过。
建议：mirror 只更新 item/链接，不重新 mergeInput；preview 的 reopen 与 execute 的租约使用同一 revision。

### P2-4 大量注释/契约已与实现漂移（会误导后续维护）
- `DeliveryCoordinator.swift:35` 写“未接线：Database.open 启动时调用 replay()”，实际已接在 `AppRuntime.swift:141-166`（start 后调度、shutdown 前 await）。
- `AppComposition.swift:162-165` 声称 replay 负责 writing 租约归位；replay 只处理 intent（见 P1-2）。
- `WorkspaceStatusService.swift:15-17`、`CullingService.swift:947` 仍说手动队列写旧 metadata_outbox；实际 `MetadataMutationService` 已写 deliveries（Cut 2 完成）。
- `DeliveryRepo.swift:834-835` 说重复链接“重置全部链接”，实际只重置当前 session（P1-1）。
- `SchemaV1.swift:35-36` 说“唯一写 'indexed' 的是测试夹具写 sessions.status”，但 `SchemaV1Tests.swift:86-90` 把该写入当作必须失败的 CHECK 用例。
建议：清理这些注释，避免后续把错误前提当设计意图。

### P2-5 Database.open 每次执行 PRAGMA foreign_key_check
`Database.swift:385-388` 在每次 open（含正常冷启动）跑全库外键扫描；表/行数增长后是启动成本，而且它只能发现 FK 违规，不能发现缺列/缺表（P1-5）。
建议：开发期保留；发行前改为按需/采样，或与 schema 指纹校验合并为一次轻量检查。

### P2-6 deliveries 可能留下“无 item 的僵尸交付”
`preview` 会删除不在本次计划内的 pending/failed item（`WritebackService.swift:477-482`），但保留 delivery 行与 link；照片被删时 delivery_items 级联消失而 delivery_sessions 仍在。此类交付：
- summary 仍计入 pending/written（`DeliverySummaryQuery.swift:312-351`），confirm 可能被 `delivery:pending` 永久阻断；
- cleanup/finalize 候选要求“本会话本模块至少一条 synced item”（`DeliverySummaryQuery.swift:151-169`），因此永远不是候选。
建议：增加“无 item 的 delivery”清理/归并规则（例如 deleteItems 后若无 item 且无 synced 状态则删 link/行），或在候选查询中处理零 item 交付。

### P2-7 app 默认并行测试与 CI
- CI `.github/workflows/ci.yml:87` 的 app 测试命令是 `swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`，**没有 --no-parallel**。
- 本次实测默认并行：**581 tests / 66 suites passed，exit 0**，未复现另一评审线索所称的“默认并行必失败”；历史账本确实记录过 appLanguage/全局通知的并行 flake（`docs/refactor-decisions.md:586,640`，并用 `--no-parallel` 收口）。
- 结论：不是“已确认必红”，而是**已知 flake 风险 + CI 未固定串行**。建议 CI 显式加 `--no-parallel`（或隔离 appLanguage/GlobalInfra），否则偶发红会掩盖真实回归。置信度：**疑似/环境相关**。

### P2-8 其他小的正确性/健壮性
- `DBConnection.rawHandle`（`DB.swift:282`）不取 connectionLock；目前只有测试用（`FaceKwMatchBatchTests.swift:79`），若未来用于 backup 会与 close 竞态。
- `DBStatement.columns()` 对零长度 BLOB 返回 `.null`（`DB.swift:547-550`），`Data` 解码会失败；当前无零长度 blob 用例。
- `SessionService.deleteSessions`（121-136）返回 `sessionIds.count`，不校验实际删除数量；与单删的 `sessionNotFound` 语义不一致。
- `Database.async`（219-229）不响应 Task 取消，await 方取消后 continuation 仍会 resume；对后台回放影响小，但调用方不能靠取消止损。
- `DeliveryIntentRepo.finish(error:)`（278-300）从任意相位直接写 `applied`，绕过 `canTransition`；当前调用点合理，但这是“可误用”的出口，建议注释/断言只允许 prepared/fileDone。

### P2-9 cleanup 成功后不删除备份文件（与 finalize/orphan 路径不一致）
- `DeliveryCoordinator.swift:1106-1123` 的 cleanup 文件阶段只 restore，不 removeFile(backupPath)；`applyCleanupDBAndFinish`（1161-1189）与 `deleteSyncedDelivery`（937-964）也都不碰备份文件。
- 对照：`performFinalizeFilePhase`（984-988）会删备份；`LiveMetadataAPI.swift:225-228` 在 orphan 行删除后也删备份；`SidecarXMPProvider.swift:198-199` 的注释明确写“备份文件由内核在事务行删除成功后清理”。
- 影响：每次 cleanup 都在照片目录留下一个 `<xmp>.gather-backup-<uuid>` 全量副本；delivery 行删除后没有任何 DB 引用，无法再被清理。长期使用会累积磁盘占用，并把旧元数据副本留在用户目录。
- 建议：在 `.deleted`/`.alreadyGone` 成功后删除 payload.backupPath（失败只记日志，不影响行删除）；补“cleanup 后备份不存在”的测试。

### P2-10 relink 不迁移 delivery_intents，回放可能操作旧路径
- `AssetRepo.swift:699-734` 只 UPDATE deliveries.xmp_path/photo_path（721-728），不更新 delivery_intents.xmp_path；`SchemaV1.swift:670-681` 刻意无 FK。
- 影响：若 relink 时存在 prepared/fileDone intent，replay 会按旧 xmp_path 查 delivery（alreadyGone）但按 payload.photo_path 执行 restore，可能在旧位置生成一个旧 sidecar 副本；DB 里新路径的 delivery 仍是 synced，需要第二次 cleanup。当前无测试覆盖。
- 建议：relink 事务内同步 UPDATE delivery_intents SET xmp_path=新路径（payload 内 photo_path 也需同步，或 replay 时以 deliveries 行解析），或 relink 前拒绝/回放未完成 intent。
- 置信度：代码已确认；触发需 relink 时有未完成 intent，标记“疑似低频”。

### P2-11 重置路径的唯一性只检查主库，半完成的旧 reset 可能让下一次 open 抛 .io
- `Database.swift:439-448` 的 `uniqueIncompatiblePath` 只检查 `path + .incompatible-<ts>` 是否存在，不检查同名的 -wal/-shm；`resetIncompatibleFiles`（411-428）先移 sidecar 再移主库。
- 若上一次 reset 已把 -shm/-wal 移到 target、主库移动前进程退出，下一次在同一秒重试会选中同一 target，移动 sidecar 时因目标已存在而抛 `.io`；启动被阻断（旧数据未丢），需用户换秒重试。
- 建议：唯一性检查把三个文件（主库/-wal/-shm）都算进去，或失败时自动递增后缀重试。
- 置信度：代码路径已确认，窗口极窄（同秒 + 中途崩溃）。

### P2-12 交付写回的写放大与事务碎片（最优性）
- `DeliveryCoordinator.mirrorWriteback` 对每个 item 先 upsertItem(pending) 再 upsertItem(target)（880-897），每个 xmp 还有 get/openDelivery/markWriting/markWritten/linkSession 各自独立事务（861-930）；一次写回 = 5+2N 个事务/语句组。
- `WritebackService.execute` 对每个 item 也至少一次 markItem + 一次持久化投影（724-738），再加 markWritten（772-778）；与 mirror 叠加后，同一份 XMP 在一次用户动作里被读写两轮。
- 影响：大 session（数百照片 × 多模块）下事务碎片和重复写盘明显；也放大了 P1-4 的部分失败窗口。
- 建议：每交付的 DB 段合并为一个事务；item 的 pending→target 在内存校验迁移后用单条 upsert；mirror 与 execute 合并成一次状态投影（见 P2-3）。

### P2-13 测试缺口（不是代码缺陷，但会让上述回归无法被拦住）
- `SessionServiceTests` 只覆盖 deleteSession 的资产孤儿化（185-228），没有“带 role_bindings/person_photos 的会话删除”集成用例；`SchemaV1Tests:612-727` 只验证 DB 级 RESTRICT 拒绝，不验证 SessionService 的删除顺序能通过。
- `DeliveryRepoTests` 的 mergeInput 用例（643-792）没有 delivery_sessions，因此没有“新输入后 s2 仍为旧 confirmed_at”的断言。
- `DeliveryCoordinatorTests` 的 cleanup 用例（391-418）不检查备份文件是否被清理；也没有“cleanup 的 await 窗口内插入 mergeInput”的测试。
- 并发写（P1-6）、writing 崩溃恢复（P1-2）、多模块 pending item 被删（P1-8）都没有测试。

---

## 4. 已确认 vs 疑似

| 编号 | 结论 | 类别 |
| --- | --- | --- |
| P0-1 | cleanup/replay 文件阶段无 revision/指纹守卫，旧备份可覆盖新内容 | 已确认（源码路径；未写测试复现） |
| P1-1 | 新输入不重置其他会话 confirmed_at，跨会话门禁绕过 | 已确认（SQL 复现） |
| P1-2 | writing 租约无恢复，lease_owner/heartbeat 无消费者 | 已确认（grep + 崩溃窗口） |
| P1-3 | enqueue 三事务，部分失败丢输入/留幽灵 pending | 已确认（结构） |
| P1-4 | mirror/execute 多事务部分失败不回滚 | 已确认（结构）；触发未实跑 |
| P1-5 | user_version=1 不校验列形，旧库运行期报错 | 已确认（代码/注释矛盾） |
| P1-6 | 同一 sidecar 并发写无互斥，culling 豁免 | 代码已确认；实际触发疑似 |
| P1-7 | IndexerService 删 photos 撞 person_photos RESTRICT | 已确认（SQL 模拟）；触发低频 |
| P1-8 | 模块级 cleanup 删除文件级交付，其他模块 pending/failed item 被静默删 | 已确认（代码路径）；触发需多模块 item |
| P1-9 | 手动 metadata 队列无生产执行器，item 永不落盘 | 已确认（grep 全仓 execute 调用点 + MetadataService 依赖） |
| P1-10 | 冲突“全部接受远程”直接 markSynced，绕过跨会话门禁 | 已确认（代码路径；共享 sidecar 触发） |
| P2-1/2/3/5/6/8/9/10 | 摘要口径、N+1、revision、启动开销、零 item 交付、边界健壮性、备份泄漏、relink intent | 已确认（代码）；P2-10 触发低频 |
| P2-11 | reset 目标唯一性只查主库 | 已确认（窄窗口） |
| P2-12 | 交付写回写放大/事务碎片 | 已确认（代码） |
| P2-13 | 测试缺口 | 已确认（测试清单） |
| P2-4 | 注释/契约漂移 | 已确认 |
| P2-7 | app 默认并行必失败 | **未复现**；疑似 flake，CI 未加 --no-parallel 是事实 |

未发现的问题：
- 未发现 SQL 注入：所有用户输入走 `?` 绑定；动态 SQL 片段只来自 enum 字面量/内部常量/占位符计数。
- 未发现 DDL 列名与代码 INSERT/UPDATE 漂移；43/373/69/62 与 8 UNIQUE、52 CASCADE/7 SET NULL/3 RESTRICT 均与文档一致。
- 未发现 SchemaV1 的 delivery 状态机与 CHECK 不一致：deliveries 7 值、items 4 值、module 5 值、intent kind 2/phase 3 均双向一致。
- 旧库重置的 -shm → -wal → 主库顺序、失败显式抛错、同秒去重、最多保留 3 份，均已按 draft §6.2 实现并有 `DatabaseFacadeTests` 覆盖。

---

## 5. 结论与建议顺序

**结论**：SchemaV1 与 Database 门面达到了“单一真相源 + 类型化门面 + 一次成型”的目标，数量和约束口径经独立复核成立；Delivery 的持久化模型（7 态状态机、revision CAS、intent 三相位）方向正确，但**文件系统与 DB 之间还没有一个可比较、可抢占的临界区**。P0-1 是当前唯一会直接破坏用户文件内容的缺陷；P1-1/P1-2/P1-3 会让“已确认/已写回”的状态失真或永久卡死。建议在 Cut 2 收口前至少修 P0-1 + P1-1 + P1-2 + P1-3 + P1-8 + P1-9 + P1-10，并为每条补一个能红过的测试。

**建议顺序**
1. P0-1：intent payload 加 base_fingerprint；cleanup/replay 文件阶段前做 revision+指纹双校验，并与 mergeInput 共用 per-xmp 锁；补 await 窗口测试。
2. P1-1：mergeInput 单事务重置全部 delivery_sessions.confirmed_at；补共享 sidecar re-edit 测试。
3. P1-2/P1-4：deliveries 的 leaseOwner/heartbeat 真正落地 + 启动归位；每交付 DB 段单事务。
4. P1-3：enqueue 单事务 + queuePhotoValues 走 chain。
5. P1-8：cleanup/finalize 候选改为“全部 item 已 synced”；P1-9：接 metadata 写回执行器（或在接线前禁止 manual item 阻断 delivery）；P1-10：acceptExternalState 只到 written；P1-5：schema 指纹或 bump userVersion；P1-7：Indexer 删除顺序。
6. P2-9：cleanup 成功后删备份；P2-10：relink 同步 intents。
7. P2 其余按需清理（注释漂移优先，成本最低、收益最高）。

---

## 附录 A：本次复核命令

```bash
# schema 对象计数（Python sqlite3，执行从 SchemaV1.swift 抽取的 DDL）
tables=43 columns=373 indexes=69 unique=8 foreign_keys=62 user_version=1
CASCADE=52 SET NULL=7 RESTRICT=3

# 工具自检
cd desktop/native/gather-core
swift run --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch gather-schema verify
# -> schema ok: tables=43 user_version=1 foreign_key_violations=0 (exit 0)

# 定向测试
swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
  --filter 'SchemaV1Tests|SchemaV1RowMappingTests|DatabaseFacadeTests|DeliveryRepoTests|DeliveryIntentRepoTests|DeliveryCoordinatorTests|SessionServiceTests|AssetRepoTests'
# -> 121 tests / 12 suites passed (exit 0)

# app 默认并行（未加 --no-parallel）
cd desktop/native/gather-app
swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch \
  --explicit-target-dependency-import-check error
# -> 581 tests / 66 suites passed (exit 0)
```

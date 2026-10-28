# W4 设计：MetadataWriter（元数据写入链路重写）

> 来源：只读设计子代理 `28233c4d`（未改任何文件）。现状基数（实测）：MetadataSyncCoordinator 982 行/24 try?/2 unchecked/4 裸 SQL 站点、WritebackService 790/11/1、MetadataService 637/11/1、MetadataMutationService 240/3/2、CaptureOneSessionState 76（`countOutboxStatuses` 零调用）、PhotoAssetResolver 168/2 裸 SQL。`Services layer`=25，`unchecked Sendable`=8，`batchAsync copies`=4。

## 1. 目标形态
- **单一写者 actor `MetadataWriter`** + 唯一端口协议 `MetadataWriting`（取代 `MetadataSyncPort`/`CullingSyncPort`/`CullingWritebackPort`/`MetadataMutationPort` 四个端口）。
- 新目录 `Sources/GatherCore/Metadata/`：`MetadataWriter` / `MetadataWriting` / `MetadataError`（16+5 码逐字）/ `MetadataMutationPlan` / `MetadataXMPCodec` / `MetadataConflictRules` / `MetadataSessionState` / `MetadataProviderContract`（+`MetadataProviderSet`）/ `MetadataFileSystem`（stat/read/hash 接缝）/ `MetadataTarget`。
- **方法名保持逐字不变**（降低切换改动量），命名收敛留给 W5。
- 删除类：`populateCache`（全列 excluded 覆盖会清空 rating/label/keywords 的「未爆炸的雷」）、`countOutboxStatuses`、`dirtyFieldsForPatch`、`patchToOutboxValues`、`assertMutationSource`、4 个端口、4 个零调用 Store 方法。`Services layer` 25→15。

## 2. 状态收敛：1 持久源 + 1 投影 + 1 外部事实 + 1 内存视图
| 角色 | 载体 | 规则 |
|---|---|---|
| **持久源 P** | `metadata_outbox` 行 + `metadata_outbox_sessions` 边 | 所有状态转换只经 `WritebackStore` CAS 命令；唯一写者 = MetadataWriter |
| **投影 R** | `writeback_items` | 不再是判定依据，只做 UI 投影/重试清单；由 `reconcileWritebackProjection` 单点写 |
| **外部事实 E** | `sessions.reload_acked_at` | 宿主 C1 桥写；writer 只读、只在新写入活动时清除 |
| **内存视图 V** | actor 私有 `ScheduleEntry{ticket:UUID,generation,phase}` + `readyQueue` + `activeWrites` + `mutationTails` | 启动可由 P 完整重建；崩溃只丢 V |

**Store 新增命令**（全部 CAS/单事务）：`markOutboxStatus(expectedRevision:)`（修 P1 stale 覆盖）、`resetOutboxForRetry`、`mergeOutboxPatches(_:)`（批量单事务，1 万照片 1 万事务→1）、`recoverInterruptedOutbox() -> Int`、`outboxEntries(xmpPaths:)`、`reconcileWritebackProjection(...)`、`applyAcceptedRemoteValues(...)`（吃掉 3 段裁决裸 SQL）、`SessionStore.clearReloadAckedAtForXmpPaths`、`PhotoStore.metadataTargets/photoLookups/photoIdsByFilepath`、`MetadataStore.mergeMetadata`（仅非 nil 列覆盖）。

**不变量 I1–I8**：唯一写者；revision 单调（stale 写返回 false 且 DB 不变）；完成即持久（written/synced ⇒ persisted_revision==revision）；attempt_count 只由尝试生命周期维护；备份安全（指纹复核）；视图可重建（start 后 entries 与 Store 集合相等）；reload-ack 单写者；投影不陈旧（getItems 的 xmpStatus 等于 outbox 权威状态）。

## 3. 关键语义修正（20 条结构性 + 52 处 try? 普查）
| # | 问题 | 修正 |
|---|---|---|
| 1 | `markStatus` 无 revision 守卫覆盖并发新编辑 | CAS `expectedRevision`，stale 拒绝 |
| 2 | **启动恢复从未接线**（`coordinator.start()` 0 调用） | 装配根调用 `writer.start()`（`recoverInterruptedOutbox` + 重排） |
| 3 | 5 档退避第 5 档不可达（30s 永不触发） | attempt_count 语义改「已自动重试次数」，`delay=retryDelaysMs[min(n,4)]`，n≥5 停止 |
| 4 | `writeback_items.xmp_status` **双写者** | 单写者 `reconcileWritebackProjection`；preview 插入 pending 例外 |
| 5 | token 身份 `as AnyObject ===` 恒 false → 队列泄漏 + 失败永久传播 | `MutationTicket(UUID)` FIFO，各回合独立结算 |
| 6 | 迟到完成覆盖新 revision | `WriteToken` + generation 守卫 |
| 7 | **EXIF/尺寸 provider 未接线**（FilterEngine 16 个 metadataFields 与 Navigation captured_at 恒空） | `MetadataProviderSet` 必填注入；缺失只允许显式 Disabled 并上报 capability=unsupported |
| 8 | `batchSet` N+1 | 一次 `metadataTargets` + `queuePhotoValuesBatch` 单事务（K=1000/G=100 时事务 ≤5） |
| 10 | 投影 attempt_count 成功路径也 +1 | `updateWritebackStatus` 不再 +1 |
| 12 | 模块隔离双判据 | 单条 Store 门 `hasActiveOtherModule(rules:)` |
| 13/14 | shutdown 无界 20ms 轮询；waitForIdle 轮询+吞错 | `shutdown(timeoutMs:)` 有界；token continuation 等待（假时钟断言 sleep 调用 0） |
| 15 | 3 段裁决裸 SQL + 单张失败被吞 | `applyAcceptedRemoteValues` 单事务整批成败 |
| 16/17 | MetadataService/WritebackService 并发闭包写共享数组（数据竞争） | actor 内 `ConcurrentMap.run` 值返回 + actor 归并 |
| 18 | `batchAsync` 6 份副本 | 统一 `ConcurrentMap.run`（门禁 4→1） |

## 4. 迁移步骤（每步独立编译+测试）
W4-0 前置（SHA256.stream/MetadataFileSystem/事务计数器）→ W4-1 Store CAS 与批量命令 + 测试 → W4-2 支撑文件 `git mv` 入 Metadata/ + 死码删除 → W4-3 actor 读面 → W4-4 actor 写面（去抖/token/退避/start 恢复/shutdown）→ W4-5 写回批次面（单写者投影）→ W4-6 provider 一等注入 → W4-7 性能/并发对拍 → **W4-8 切换提交**（装配 + 删 4 服务与 PhotoAssetResolver + 4 端口 + 旧测试 + baseline/docs）→ W4-9 门禁加固（Metadata/** 禁 SQL/NSLock/unchecked；try?、Data(contentsOf: 归零）。

**旧测试承接**：MetadataSyncCoordinatorTests 6、CullingServiceTests 中 11 个端口用例（随 W2b 迁 CullingRuntimeTests）、WritebackStoreTests 13、WritebackItemsTests 12、MetadataStoreTests 11、PhotoAssetResolverTests 8（→MetadataTargetStoreTests）、MetadataContractTests 20（不动）+ 新增 ≥25（重启恢复/CAS stale/退避序列/token 队列/单写者投影/provider 接线/mergeMetadata 保真/事务预算/有界 shutdown 等）。

## 5. 验收
- 双包 0 error；core ≥948 + 25~35 新增；app 172/19；旧用例无孤儿。
- 门禁：`Services layer` 25→15；`raw SQL outside Store` 保持 0 且 Services 内 7 处 `database.*` 清零；`unchecked Sendable` 8→4；`batchAsync` 4→1；**新增 enforced：`Metadata/**` 0 SQL/0 SQLiteDatabase/0 NSLock/0 unchecked**；新增 tracked（目标 0）：非良性 `try?`、`Data(contentsOf:`。
- 错误码逐字：XMP_* 16、WRITEBACK_* 5、METADATA_*、CULLING_PHOTO_NOT_IN_SESSION、ASSET_MIGRATION_INCOMPLETE。
- 性能：同路径 100 次 schedule → 恰 1 次写；1000 项/100 sidecar 事务增量 ≤3；启动恢复 1000 行 <2s；无整文件读。

## 6. 待裁决（12 项，摘要）
1 方法名保持旧名（建议）；2 provider 接线深度（EXIF 是否有真实实现 / 是否只接尺寸）；3 `writeback_items` 是否加 outbox_revision 列（建议不加）；4 批量 merge 事务粒度（建议 ≤500/事务）；5 重试语义（5 档第 5 档）对照 TS；6 PhotoAssetResolver 由 W4 吸收（建议）；7 MetadataSessionState 权威来源（UI 改造归 W5/R6）；8 CullingService 端口切型时机（与 W2b 串行，二者取一）；9 删 4 个零调用 Store 方法（建议同批）；10 `SQLiteDatabase` 注释里的 unchecked 字样（建议顺手改写使度量 8→3，**主代理批准**）；11 `skipReloadAck` 仅测试注入；12 error 改名时机（W4 先改）。
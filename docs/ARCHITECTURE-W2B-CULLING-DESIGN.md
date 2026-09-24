# W2b 设计：CullingRuntime（替代 Services/CullingService.swift）

> 来源：只读设计子代理 `9c8089b9`（round 5/64，未改任何文件）。状态：**设计定稿，待实施**。
> 现状：`Services/CullingService.swift` 2550 行；Services 目录 25 文件（ratchet 25→0）；Culling 内仍有 8 条 SQL 文本需下沉 Store；本文件 `@unchecked Sendable` 仅 1 处（`CullingHistorySink`）。

## 1. 目标形态（`Sources/GatherCore/Runtime/Culling/`）

| 新文件 | 职责 | 关键类型 |
|---|---|---|
| `Store/CullingQueryStore.swift`（新增，唯一 SQL 所有者） | 分页/计数 SQL 下沉 | `CullingFilterSpec`、`CullingQueryScope`（all/filtered/similarityGroup/similarityLatest）、`CullingPageQuery`、`CullingAssetGroupPage`、`CullingQueryStore` 协议、`SQLiteCullingQueryStore` |
| `CullingQueryBuilder.swift` | 无状态纯函数：校验/scope 编译/组 id 解析/批量去重 | `pageLimitMax=2000`、`batchMax=10000`、`CullingPageRequest`、`CullingPostFilter` |
| `CullingLookupLoader.swift` | 无状态 struct，只经 Store 协议批量装载 | `CullingLookupAnalyses`、`CullingRichLookup`、`CullingGroupIndex.build` |
| `CullingAssembler.swift` | 纯函数：行→DTO、变体折叠、人脸归一化、质量相对排名、过滤、summary/groups | `CullingPhotoRow`（迁入）+ 20 个静态函数 |
| `CullingSessionCache.swift` | **actor**，唯一长生命周期可变状态 | `LookupKey(sessionId,indexSeq,resultId)`、`UpdateKey(sessionId,indexSeq)`、TTL+容量淘汰（按 expiresAt，修原 keys.first 任意淘汰） |
| `CullingRuntime.swift` | **actor**，编排读写，只持 `Dependencies`+cache | 读：list/listPage/groups/summary/history；写：update/batchUpdate/applyHistory/decideGroup/reset；委托：syncStatus/flush/retrySync/finalizeSync/writeback/retryFailedWriteback/confirmSync/cleanup |

**Store 新增方法**：`FaceStore.observationsLite`、`PersonStore.personNamesByPhoto`、`JobStore.technicalQualityRows`、`MetadataStore.ratingLabels`、`CullingStore.applyDecisionStates(expectedRevision:)`（revision 检查下沉为单事务 CAS，消除 TOCTOU）。

## 2. actor 边界与原子性
- 删除 `CullingHistorySink`（`@unchecked Sendable`）→ 收集器改为 actor 方法内 `inout` 值类型 `CullingWriteCollectors`，`unchecked Sendable` 21→20。
- 删除 `CullingUpdateContext` → 私有不可变 `CullingUpdateSnapshot`。
- 真正的数据竞争是 `sessionLookupCache/sessionUpdateCache` 中的**可变 class** 条目（MainActor 写 + `Task.detached` 读）→ 由 `CullingSessionCache` actor + Sendable 值类型条目结构性消除。
- **重入安全规则**：全部 await 预读集中在 `updateSnapshot`，随后进入**无 await 同步临界区** `performUpdate`；revision 由 Store 单事务 CAS 保证；`batchUpdate` 决策行一次事务（中途冲突整批回滚）。
- 缓存失效：键 `(sessionId, indexSeq, similarityResultId)`；`invalidateAnalyses` 由 Quality/Face 分析完成调用；删除 `refreshSessionUpdateContext`（index_seq 即版本）。

## 3. 语义修正清单（须写进测试断言）
1. `loadSessionPhotos` 的 `try?` 静默降级 → 改为抛错（缺照片才 `photoNotInSession`）。
2. 分页：keyset 保持；cursor 只来自组查询；新增「JS 过滤后空页仍返回 nextRowId」防死循环断言。
3. 缓存：TTL → 版本键 + 显式失效；淘汰确定性。
4. revision：CAS；批量单事务。
5. `CullingStoreError.undoNotLatest/redoOutOfOrder/historyStale/historyCorrupt` 在 Runtime 边界映射为 `historyAlreadyUndone/historyNotUndone/historyDiverged/historyNotFound`。
6. `asset_id=''` 归一化统一 `CullingAssembler.groupKey`（SQL 侧 `COALESCE(NULLIF(asset_id,''),id)`）。
7. outbox 读后写保留「提交后一次批量读」。
8. `schedule(xmpPath)` 仅 metadataPatch 非空时调用。

## 4. 死代码（同批删除，不设兼容层）
`getUpdateContext`、`getSessionUpdateContext`（同步占位）、`withChunkedIds`（无调用）、`CullingHistorySink`、`CullingUpdateContext`、`decide/batchDecide`（路由两 case UI 0 调用，同批删）。

## 5. 迁移步骤（每步独立编译+测试）
| 步 | 内容 | 验证 |
|---|---|---|
| 0 | Store 读模型 + 5 个 Store 方法 + Store 测试（纯新增） | `swift test --filter 'CullingQueryStoreTests\|CullingStoreTests'` |
| 1 | QueryBuilder + 测试（纯函数） | `--filter CullingQueryBuilderTests` |
| 2 | Assembler + 测试 | `--filter CullingAssemblerTests` |
| 3 | LookupLoader + 测试（真实库、断言无 try? 吞错） | `--filter CullingLookupLoaderTests` |
| 4 | SessionCache actor + 测试（TTL/容量/键/并发 hammer） | `--filter CullingSessionCacheTests` |
| 5-6 | Runtime 读路径、写路径移植 | `--filter CullingRuntimeTests` + core 全量 |
| 7 | **切换提交**：makeDefault 装配 Runtime；22 个 `culling.*` case 迁 executeAsync；`CullingServiceError`→`CullingError`；**删 CullingService.swift + CullingServiceTests.swift**；QualityService 端口异步化并接线（原闭包从未注入 = 质量完成后缓存永不失效的缺陷）；baseline/docs 同批 | 门禁 + app 全量 + core 全量 |
| 8 | 删 decide/batchDecide 与两路由 case；补性能基准对比；门禁加「Runtime 禁 SQL」规则 | 门禁 + benchmarks |

## 6. 验收标准
- core 全绿且测试数 ≥ 基线；57 个旧 Culling 用例按映射表拆分到 6 个新测试文件（无孤儿）；app 172/19 全绿。
- 门禁：`Services layer (R2)` 25→0；`raw SQL outside Store` 保持 0；**新增 enforced：`Runtime/**` 内禁止 SQL 文本与 `database.(query|run|queryOne|scalarInt)`，`Runtime/Culling/` 禁止出现 `SQLiteDatabase`**；`unchecked Sendable` 21→20 且 Runtime 新文件 0。
- 错误码逐字不变（`CULLING_*`/`WRITEBACK_*`/`CULLING_REVISION_CONFLICT::expected::current`）。
- 新增覆盖：index_seq 失效、并发点击 CAS（同 revision 恰一个冲突）、batch 单事务回滚、try? 已消除、JS/SQL 同一谓词来源。
- 性能对比 R0.4 基线劣化 ≤10%；`update` 命中缓存往返 ≤4；listPage IO 与页大小成正比（不再全量读 session）。

## 7. 待裁决（主代理）
1. `culling.decide`/`culling.batch_decide` 删除（UI 0 调用）——建议删。
2. `CullingView` 同步 `client.execute` 调 async case 已损坏（R1 起）——属 R6 修复范围，W2b 仅保持 router API 形状。
3. 端口 Sendable 债务（`CullingSyncPort`/`CullingWritebackPort`/`MetadataMutationPort`）在 W2e/R4 收缩后再加 `: Sendable`。
# W2c 设计：SimilarityRuntime + DuplicateRuntime + QualityRuntime

> 来源：只读设计子代理 `3e48ee7c`（round 8–9，未改任何文件）。旧实现合计 2,360 行（Similarity 968 / Duplicate 744 / Quality 648）→ 3 个 actor + 10 个纯函数文件 + Store 扩展。

## 0. 共性前提
- **SQL 直连需下沉**：Similarity 8 处、Duplicate 22 处、Quality 6 处 → 全部落既有 `Sources/GatherCore/Store/*.swift`（**不在 Runtime/ 建 Store 子目录**，避免与门禁 `Runtime layer SQL statements` 冲突）。
- **并发原语**：Similarity `controllers+NSLock`；Duplicate `lock + ScanHandle(@unchecked) + BatchCursor(@unchecked)`；Quality `progressLock + var completed + QualityBatchCursor` → 全部由 actor / `Runtime/Support/ConcurrentMap` + `actor IndexCursor` 取代。
- **W2a 前置**：`Runtime/Support/ConcurrentMap.swift`（替换 Duplicate.batchAsync 与 Quality.mapConcurrent 两份拷贝）、`Support/SHA256.stream`（流式，替代 `Data(contentsOf:)`）。
- **反模式禁令**：actor 内不得执行长同步 CPU/阻塞 IO（聚类、SHA256、stat）→ 走 `Task.detached`/runner 闭包。

## 1. 文件拆分与 actor 边界

### Similarity（`Runtime/Similarity/`）
- 文件：`SimilarityError` / `SimilarityValidation`（纯）/ `SimilarityAssembler`（纯）/ `SimilarityHashReuse`（纯）/ `SimilarityClusterPlan`（纯）/ **`SimilarityRuntime` actor**；Store 扩展 `SimilarityStore.hashes/hashCandidates/upsertHashes`、`JobStore.insertAnalysisRun/finishAnalysisRun/latestAnalysisRun`、`PhotoStore.assetFileIdsByPhoto`。
- actor 状态仅 `flights: [String: Flight]`（值类型，取代 controllers+NSLock）；同步前缀完成 validate + flight 注册（TOCTOU 免疫）；await 预读全部集中在解码循环前；同步临界区 = upsertHashes/replaceResult/finishAnalysisRun。
- 语义修正：①generation 守卫（迟到 catch 不得覆写 status）②8 处 `try?` 改 do/catch + log ③reuse 的 TOCTOU 与静态 DB 参数消失 ④校验顺序保持 ⑤邻域档 best-effort 保持且 multiCluster 只调一次 ⑥encode 失败改抛错 ⑦getResult 一致装配 ⑧解码并发窗口配置化。
- 删除：`reuseSimilarityHashes(database:...)`（拆纯函数 + Store）、179 行过时注释。

### Duplicate（`Runtime/Duplicate/`）
- 文件：`DuplicateError` / `DuplicateScanPipeline`（纯）/ `DuplicateAssembler`（纯，含 keep_one 评分）/ **`DuplicateRuntime` actor**；Store 扩展 `DuplicateStore.groups(ids:)`、`membersWithPhoto(groupIds:)`（现 `members*` 不 JOIN photos，缺 filepath/filename，无法装配 DTO）。
- actor 状态仅 `scanFlight: ScanFlight?`（同参数共享、异参数 busy、异常释放，与现状逐字等价）；stat/sha256/聚类全部出 actor。
- 语义修正：①单飞+BatchCursor 结构化 ②`computeVisualHashes` 的 `try?` 改 `(hashes, failures)` ③sha256 流式 ④删 `PRAGMA group_concat_limit=0`（已在 Swift 侧聚合）⑤resolveGroup 打分下沉纯函数 + 单事务 ⑥resolveMember 单事务（删事务外二次重算）⑦列序脆弱性 → 类型化 decode ⑧确定性顺序（成员 = rowid 序、组 = id 序）⑨**`SQLiteDuplicateStore` 必须接线**（原为 R7 删除候选，接线后取消）⑩Store 错误映射文案逐字。

### Quality（`Runtime/Quality/`）
- 文件：`QualityError` / `QualityMetrics`（纯）/ `QualityScorer`（纯，含 rankings）/ **`QualityRuntime` actor**；Store 扩展 `JobStore.upsertQualityResults/cachedQualityResults/latestQualityResults`、`FaceStore.largestFacePerPhoto`。
- actor 无可变字段（`completed` 改 actor 内局部）；并发 runner 出 actor；临界区 = upsertQualityResults 单事务 + 提交后 `invalidation.invalidateQualityLookup`。
- 语义修正：①**rankings O(n²) → O(N+Σm log m)**（对拍 + 访问计数断言 + 性能门禁）②`loadSimilarityGroups` 选错结果行（未排除 precomputed 档）→ 经 `SimilarityStore.latestResult` ③**`invalidateCullingLookup` 从未接线** → `QualityInvalidationPort`（async）并在 makeDefault 注入 ④3 处 `try?` 计数+log ⑤encodeJSON 改 throws ⑥失败行指纹语义保留 ⑦`get` 返回按请求序（**行为变化，待裁决**）⑧缓存命中覆盖 photoId 保留 ⑨assetFileId 缺失不落库 ⑩进度帧形状不变 ⑪取消不写 asset_analysis。

## 2. 共享 Store 方法汇总（一次实现，多波复用）
| Store | 方法 | 使用方 |
|---|---|---|
| JobStore | `insertAnalysisRun/finishAnalysisRun/latestAnalysisRun` | Similarity（W2c）+ FaceKw（W2d） |
| JobStore | `upsertQualityResults/cachedQualityResults/latestQualityResults` | Quality（W2c）；与 W2b `technicalQualityRows` **合并为同一方法族** |
| SimilarityStore | `hashes/hashCandidates/upsertHashes` | Similarity；与 Duplicate visualHashes 同表不同 slice |
| DuplicateStore | `groups(ids:)/membersWithPhoto(groupIds:)` | Duplicate |
| PhotoStore | `assetFileIdsByPhoto(sessionId:)` | Similarity |
| FaceStore | `largestFacePerPhoto` | Quality；与 W2b `observationsLite` 去重（裁决 9） |

## 3. 迁移步骤（每服务 6 步，每步独立编译+测试）
0) W2a 前置 + Store 扩展与测试 → 1) 错误+纯函数+测试 → 2) Assembler/Scorer+测试 → 3) Runtime 读路径 → 4) Runtime 写路径/解析 → 5) 性能对拍 → 6) **切换提交：makeDefault 装配 + 同批删旧服务与旧测试 + baseline/docs**。

## 4. 验收标准
- 双包 0 error；新 Runtime 文件零 `NSLock`、零 `@unchecked Sendable`、零 SQL；core 测试数 ≥ 基线（849/117）；旧 63 用例（Similarity 21+7、Duplicate 21、Quality 14）全部有归属；app 172/19。
- 门禁：`Services layer` −3；`unchecked Sendable` 21→20；`raw SQL outside Store` 保持 0；`batchAsync` 4→3；**新增 enforced：Runtime/** 禁 SQL/禁 `database.*`/禁 `SQLiteDatabase`**；新增 tracked：`Data(contentsOf:` in Runtime = 0、`NSLock` in Runtime = 0。
- 性能（劣化 ≤10%）：Similarity hash 复用往返 ≤ 1+ceil(资产数/400)；Duplicate 二次扫描零 provider 调用、≤4 次 Store 往返、1GB sha256 内存有界；Quality `quality.get` p95 ≤ 旧实现 1/5。

## 5. 待主代理裁决（14 项，摘要）
1 SimilarityResult 落 Protocol；2 Assembler 遇快照外 photoId：抛错 vs 空串；3 错误类型改名（ServiceError→Error）；4 `clusterVersion` 去留（保留）；5 `quality.get` 返回序变化；6 JobStore vs AnalysisStore 归属；7 **Quality→Culling 失效接线需 W2b 先行/同批**；8 precomputeNeighborTiers 成本；9 FaceStore 两个读方法去重；10 进度端口 Sendable 化留 W3；11 **Store 布局（统一 `Sources/GatherCore/Store/`，本设计采用）**；12 resolveGroup 回滚语义；13 路由形状本波不动（W5 统一）；14 W2b/W2c 共享 Store 先后（无冲突）。
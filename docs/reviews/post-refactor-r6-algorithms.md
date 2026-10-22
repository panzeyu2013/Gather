# Cut 5 算法评审（只读）：聚类 / 匹配 / 三阶段

- 评审对象：`desktop/native/gather-core`（GatherAnalysis / GatherDomain / GatherPersistence）与 Cut 5 账本
- 基准 HEAD：`82603e0`（重构在工作区未提交；旧实现经 `git show HEAD:...` 对照）
- 评审日期：2026-10-22
- 约束：只读；未改源码/测试/Package/脚本；唯一写入本文件。
- 结论口径：**已确认** = 代码路径可静态证明或用例已覆盖；**疑似** = 需构造用例/实跑才能定性。

## 1. 范围与方法

| # | 任务重点 | 主要证据 |
|---|---|---|
| 1 | ClusterGraph / HashNeighborhoodGraph / Streaming / DegreeGatedBFS 的划分、组序、种子序、稀疏节点、wave vs stack、streaming > 32768 | `ClusterGraph.swift`；`ClusterGraphTests.swift`；HEAD 版 `ClusterEngine.swift` 的 `waveBfsOverFilteredRows`/`recomputedBfs` 逐段对照 |
| 2 | Similarity 单趟 pipeline、多档并集、canonicalGroups、ClusterStateVersioning、行级 diff/apply、幂等、旧 state 失效 | `SimilarityService.swift`；`SimilarityClusterStateRepo.swift`；`ClusterStateVersioningTests.swift`；`SimilarityIncrementalServiceTests.swift` |
| 3 | FaceMatcher 批量：库/范数/LSH 一次、累加顺序、LSH skip、内存上界、空库/单簇/阈值边界 | `Matcher.swift`；`FaceMatcherBatchTests.swift`；`MatcherReconciliationTests.swift` |
| 4 | Face analyze A/B/C：短事务、锁外 B、C 的 index_seq/feedback/签名、取消/失败中间态、幽灵成员、C2 best-effort、迁移回滚、并发持锁 | `FaceKwService.swift`；`FaceIdentityArchitectureTests.swift`；`FaceIncrementalClusterTests.swift`；`DB.swift` 的 `transaction` 锁语义 |
| 5 | 10k release 19.25s vs 5s、HNSW 删除、LSH 价值、bench 可复现 | `Clusterer.swift`；`VectorIndex.swift`；`GatherCoreBenchmarks/main.swift`；`docs/refactor-progress.md` Cut 5 行；`scripts/reconciliation/` |

方法：
1. 逐函数读实现，并与 HEAD 旧实现（`ClusterEngine.waveBfsOverFilteredRows`、`recomputedBfs`、`IncrementalClusterer.buildState/canonicalize`）做语义对照；旧代码只经 `git show` 读取，未 checkout。
2. 核对 `DBConnection.transaction` 的 `NSRecursiveLock` + SAVEPOINT 语义，判断 A/B/C 的持锁边界。
3. 核对测试实际断言（集合 vs 逐位序、fixture 数、streaming 跨限用例、批量逐位一致用例）与账本声明。
4. 性能只做静态复杂度/路径分析 + 账本数字交叉核对；**未重新构建 release**（只读约束，且仓库内 release bench 二进制为 2026-10-03，早于 `--face-10k`），故 19.25s 未独立复现，见 §5.3。

## 2. 结论摘要

- **P0：0 项**（未发现会丢照片、写坏用户数据、或让聚类结果与声明语义相反的确定性缺陷）。
- **P1：3 项**，其中 2 项在算法范围（增量结果按 minGroupSize 二次过滤，丢掉全量会保留的合法小组；10k 性能目标未达），1 项为父 agent 指定的范围外协同项（CI app 测试缺 `--no-parallel`）。
- **P2：15 项**，集中在语义分叉（增量 vs 全量的组内序）、测试缺口（streaming 只测完全图）、失败面（state 落库降级）、内存/死路径（批量匹配 flat 副本、LSH 匹配路径生产零引用）、证据链（fixture 生成器缺失、bench 路径由构建配置决定）。
- 总体判断：**Cut 5 的“唯一实现 + 单趟 result/state + 行级 diff + 批量匹配 + A/B/C 分段”主方向成立，核心算法语义与旧实现/TS golden 对齐**；剩余风险主要在“增量 result 的小组过滤/空壳簇边界”和“性能目标”，不是大面积正确性回退。

## 3. P1 发现

### P1-1（已确认，可构造反例）增量结果按 minGroupSize 二次过滤，丢掉全量会保留的“合法小组”，导致成组/未成组与全量不一致

**证据**
- 全量：`DegreeGatedBFS.groupsImpl` 对每个合格种子无条件 `result.append(group)`（`Sources/GatherAnalysis/Similarity/ClusterGraph.swift:639-687`）；`ClusterGraphPipeline.run` 原样映射为 `ClusterResult.groups`（`:1094-1098`），不做尺寸过滤。`minGroupSize` 只是**种子/扩张门控**（`degree + 1 < minGroupSize` 不成组/不扩张），不是组大小下限。
- 增量：`IncrementalClusterer.result` 先 `.filter { $0.count >= minGroupSize && ... }`（`Sources/GatherAnalysis/Similarity/IncrementalClusterer.swift:245-246`），把这些组整组降级为 ungrouped。
- 可构造反例（用**同一新算法**在 6-bit 汉明图上穷举得到，非 Swift 实跑）：hash = `0x31, 0x07, 0x2a, 0x1c, 0x12, 0x2b`，threshold=3、minGroupSize=4 → 度数 `[2,2,2,1,4,3]`，全量 groups = `[[4,0,1,2,3],[5]]`（第二组只有 1 个成员，但种子 5 的度数 3 满足门控）；`IncrementalClusterer.result` 会输出 `groups=[[4,0,1,2,3]]`、`ungrouped=[5]`。
- 归因：该 `.filter { $0.count >= minGroupSize }` 在 HEAD 旧 `IncrementalClusterer.result` 中已存在（`git show HEAD:...IncrementalClusterer.swift` 同款），不是 Cut 5 新引入；但 Cut 5 在文件头**新写下了**“划分与全量完全相同”的不变量（`IncrementalClusterer.swift:11-16`），因此这是新契约与旧实现的冲突，应在 Cut 5 收口。
- 机制：节点 5 的邻居先被节点 4 的组吸收，且这些邻居都是稀疏点（不扩张），于是 5 自己成组但组内只剩自己。这是旧 wave/stack BFS 共有的语义，Cut 5 原样保留。
- 现有随机对账（`Tests/GatherCoreTests/Similarity/ClusterGraphTests.swift:439-521`）只做了 3 组参数、24→200 步随机增删，未命中该结构；`expectEquivalent`（`ClusterGraphTests.swift:61-77`）会抓 group 数/ungrouped，但未被触发。

**影响**
1. 违反 `IncrementalClusterer.swift:11-16` 自己写的不变量“划分：照片集合如何成组、谁未成组与 ClusterGraphPipeline.run 完全相同”。
2. 同一会话增量 analyze 与全量 recluster 给出不同结果：该照片在增量下显示 ungrouped，重聚类后又进组；落库 `similarity_result_members`（按 result）与 `similarity_cluster_state`（state 保留该组）互相矛盾。
3. 频率低（需 minGroupSize≥4 且特定稀疏结构），但一旦出现会持续到下一次全量重聚类。

**建议**
- 首选：删除 `IncrementalClusterer.result` 的 `count >= minGroupSize` 过滤（state 已由全量/增量装配产生，不需要二次门控），与全量 result 对齐；若担心旧 state 有脏组，用 state 的算法版本/来源判定，而不是按尺寸猜。
- 备选（若产品要求“组至少 minGroupSize”）：在 `ClusterGraphPipeline.run` 的 result 映射处也过滤，并同步更新 17 例 golden 与 UI 预期；两条路径必须采用**同一条**规则，不能只过滤增量。
- 回归用例直接用上面的 6-bit 反例断言 `IncrementalClusterer.result(...) == ClusterGraphPipeline.run(...).result`；并在 `ClusterGraph.swift` 文件头明确“minGroupSize 是门控参数，不保证组大小”。

### P1-2（已确认，账本自认；性能）10k 人脸 B 阶段 release 19.25s，未达 §6.3 ≤5s；根因是默认门（20k）让 10k 走 O(n²) 精确 DBSCAN，且标量点积达不到 5s 所需吞吐

**证据**
- 精确路径：`Sources/GatherAnalysis/Face/Clusterer.swift:264-361`（`runPass` → `regionQuery`），精确邻域 `exactRegionQuery` 为 `Clusterer.swift:174-186`，每个点对全 `active` 做 512 维点积；每个点只访问一次，总代价 ≈ n²/2 对点 × dim。
- 默认 LSH 门：`Clusterer.swift:109-113`（`ClusterLshOptions.default.minPoints = CosineLshIndex.lshMinPoints`），`Sources/GatherAnalysis/Face/VectorIndex.swift:88` 为 `20_000`；10k < 20k，因此生产 10k 会话恒走精确路径。
- 账本：`docs/refactor-progress.md:32` 与 `:151` 记录 “release 精确 19.25s / 批量匹配 152.8ms（**§6.3 ≤5s 未达**）”“~3.85×”；`:15` 记 “D-158 接受 ≤20s 基线”。
- 量级核算：10k × 10k/2 ≈ 5.0×10⁷ 对点，每对 512 维点积 → ≈2.56×10¹⁰ 次乘加；19.25s ≈ 1.3 G MAC/s ≈ 2.7 GFLOP/s（乘加按 2 flop）。要在 5s 内完成需 ≈5.1 G MAC/s ≈ 10 GFLOP/s 的单核算力，标量 Double 顺序累加不可达。

**影响**
- 10k 照片的人脸分析 B 段固定多 ~19s（不含 A 检测/对齐/嵌入，通常更贵）；Face 的 DBSCAN 有 isCancelled 细粒度检查（`Clusterer.swift:297-299, 323-325`），但单次 regionQuery 仍是 O(n)，取消延迟约为一次全扫描；用户感知为“卡住”。
- 目标未达被 D-158 接受为基线，但**不是算法最优**：同样的 10k 数据，LSH 门若降到 10k 以内可把候选从 10k 降到个位数/几十，但当前 harness 没有 release LSH 数据可证明（见 P2-8）。

**建议（按收益排序）**
1. 用 Accelerate/vDSP（系统框架，无第三方依赖）替换 `rowDotProduct` 的标量 512 维点积（`Clusterer.swift:153-169`），或把 512 维 Float 分成 4 路独立累加；预期 4-8×，单独即可接近/达到 5s。
2. 把 `ClusterLshOptions.default.minPoints` 从 20k 降到可配置（如 5k-10k），并先用 release 构建实测 recall（现有门是 20k，10k 没有 release LSH 证据）。
3. 若走 LSH：先修 `VectorIndex.swift:216` 每查询分配 `[Bool](count: n)` 的 O(n) 清零（复用 scratch/代际戳），否则 10k 查询 × 10k bool 的清零本身就会吃掉收益。
4. 若要保留“精确 = golden 基准”，把 LSH 作为快速路径、精确作为对账开关，而不是把两者绑在构建配置上（见 P2-8）。

### P1-3（范围外协同，父 agent 已确认）CI 的 app 测试没有 `--no-parallel`，与本地“绿灯”口径不一致

**证据**
- `.github/workflows/ci.yml:87`：`swift test --package-path desktop/native/gather-app --explicit-target-dependency-import-check error`，无 `--no-parallel`。
- 账本 6c 验收明确写 “app build+test（strict + `--no-parallel`）” 才得到 581/66（`docs/refactor-progress.md` 6c 行）。
- app 测试存在大量进程级共享状态：`Tests/GatherAppTests/GlobalInfraTests.swift:241-245`（共享 `GatherToastCenter.shared`）、`LibraryViewModelTests.swift:273-276`（NotificationCenter 进程级总线）、`Support/AppLanguageLock.swift:5`（跨套件语言窗口）、`APISimilarityUITests.swift:333`（自述“全量并行跑出的既有竞态”）。

**影响**
- CI 的 app job 可能红/间歇红，且红的原因不是被测代码而是测试隔离；一旦红了，Cut 5 的 core 绿灯无法给出“整仓可交付”的信号。
- 与 6c 的“8 门禁全过”口径冲突：门禁绿只代表本地串行口径。

**建议**
- app job 显式加 `--no-parallel`（或设置测试专用环境变量并在 Package 中读取），core job 保持并行；把这一 flag 写进 `docs/DEVELOPMENT` 的测试命令，避免下次再漂。
- 若坚持并行，需要把上述共享单例改成注入/串行锁，属于独立清理项（不在本报告修复范围）。

## 4. P2 发现

> 每条均给 file:line、证据、影响、建议；“已确认/疑似”见 §5。

### P2-1（已确认，语义分叉）增量结果的组内序是“规范序”，全量结果是“wave 发现序”，同一会话两种路径的成员显示顺序不同

- 证据：全量 `ClusterGraphPipeline.run` 的 `result.groups` 来自 `ClusterWorkspace.groupIDs`，保持 wave 序（`ClusterGraph.swift:1094-1098`，契约见 `:29-33`）；增量 `IncrementalClusterer.result` 对每组做 `[seed] + rest.sorted(by: order)`（`IncrementalClusterer.swift:239-258`），落库成员顺序随之改变。
- 影响：组序/种子/代表图不变（seed 仍是首元素，group_index 仍按 seed 升序），但 `similarity_result_members` 的行序、UI 组内图片顺序会在“增量 analyze”和“全量 recluster”之间抖动；黄金对账若按逐位序会比不过（当前测试只对 state 逐位，result 用 `expectEquivalent` 忽略序，见 `ClusterGraphTests.swift:513-518`）。
- 建议：要么把 `ClusterResult` 契约明确为“组内序未定义，只有 seed 固定”，要么让 `IncrementalClusterer.result` 复算 wave 序（对每个复用簇用一次子图 wave BFS），并在 `SimilarityIncrementalServiceTests` 加逐位序断言。

### P2-2（已确认，测试缺口）streaming >32768 的端到端用例只覆盖“完全图”，稀疏大图的种子/波次语义没有直接 golden

- 证据：`Tests/GatherCoreTests/Similarity/ClusterGraphTests.swift:582-627` 用 `threshold = maxDistance = 64` 构造全连接图，注释自认“为避免 Debug 下 5.4 亿次 pair 距离”；结构化稀疏图只在 n=600 上对账（`:530-580`）。
- 影响：streaming 的 `adoptAll` 提前退出、稀疏节点“随组不扩张”、跨 32768 的组序/seed 语义，缺少“大 n + 稀疏 + 多簇”的直接证据；当前只有“枚举顺序一致”的间接保证。
- 建议：加一个 release/debug 都可控的用例：n=32769、threshold 取 1-2 的小图（用少量锚点+扰动构造稀疏多簇），断言 `components/groups` 与位集路径逐位一致；或把该用例标 `.enabled(if: env)` 只在 CI release 跑。

### P2-3（已确认，健壮性）多档图的 public API 用 `precondition` 拒绝未排序阈值，越界配置直接 trap

- 证据：`ClusterGraph.swift:329-333`（`precondition(!thresholds.isEmpty)`、升序去重）、`:372`（档位下标越界 `precondition`）。内部 `runTiers` 已 `Set(...).sorted()`，但 `MultiThresholdHashGraph`/`MultiThresholdTierGraph` 是 public（`GatherAnalysis` 对外）。
- 影响：任何新调用方传重复/乱序阈值会进程崩溃，而不是抛 `ClusterGraphError`；与“Analysis 层错误应可捕获”的约定不一致。
- 建议：构造器改为 `throws`（或内部 `init` + 公开工厂），`tierGraph(at:)` 返回可选/抛错；保持 `runTiers` 的现有行为。

### P2-4（已确认，失败面）簇状态落库失败时的“降级清空”本身可能抛错，把主结果一起回滚

- 证据：`SimilarityService.swift:1220-1243`：`applyClusterState(...)` 失败 → `try clusterStateRepo.delete(sessionId:)`；`delete` 内是嵌套事务（`SimilarityClusterStateRepo.swift:234-241`），若 delete 也失败，异常冒泡到 `persistClusterOutcome`（`:1197-1216`）→ 整个事务回滚，主结果不落库。注释却写“不因加速设施拖垮主结果”。
- 影响：schema/权限/磁盘满等写失败场景下，本该“结果照常保存、状态下次全量”的降级变成“分析整体失败”。
- 建议：降级 delete 用 `try?`（或先记录，事务外再清），保证主结果提交优先级高于 state；加一个注入失败用例。

### P2-5（已确认，清理/证据链）批量匹配在生产库 >20k 行时仍分配整库 flat 副本，尽管批量路径从不使用 LSH

- 证据：`Matcher.swift:174-191`（`prepareLibraryRows` 在 `count > lshMinPoints` 时无条件 `flat = count*dim`），`Matcher.swift:312-326`（batch 也调 `prepareLibraryRows`，且 `LibrarySnapshot` 会使用 `libraryFlat` 做扫描）；生产唯一调用 `FaceKwService.swift:2189-2194` 的 `match(clusters:)` 不建 LSH。
- 影响：库 20k × 512 × 4B ≈ 41MB 的额外常驻/瞬时副本（100k 行 ≈ 205MB），每次 `matchClustersAgainstLibrary` 新建 `FaceMatcher` 都会再分配一次；批量只读路径本可直接按 `rows[i].embedding` 扫描。
- 建议：给 `prepareLibraryRows` 加 `buildFlat: Bool`（batch 传 false，`loadLibrary` 传 true），或把 flat 构建延迟到 `loadLibrary` 内；在 `FaceMatcherBatchTests` 加“大库 batch 不建 flat”的注入观测（类似 `hasLSHIndex`）。

### P2-6（已确认，死路径/声明）`FaceMatcher.matchAgainstLibrary` 与 Matcher 内 LSH 索引在生产代码零调用，LSH 实际只服务 FaceClusterer 的 n>20k

- 证据：`grep -rn 'matchAgainstLibrary' Sources` 只命中 `Matcher.swift` 自身；调用点均在 `Tests`（`MatcherReconciliationTests`、`FaceMatcherBatchTests`、`FaceMatcherMarginTests`）。生产匹配 `FaceKwService.swift:2112-2200` 只调 `match(clusters:)`（精确批量）。
- 影响：`loadLibrary` 的 LSH 建索引分支（`Matcher.swift:197-205`）生产永不触发；“LSH 价值”实际只剩 `Clusterer.swift:239-243` 的大语料路径。HNSW 删除（`VectorIndex.swift:4-5`）仍有充分理由（0 引用）；但 Matcher 的 LSH 代码与对账测试属于“为历史/基准保留”，应在文档中写明，避免误以为生产匹配走 ANN。
- 建议：要么删 `matchAgainstLibrary`/`loadLibrary` 的 LSH 分支并同步对账测试（保留精确路径），要么在文件头明确“测试/基准保留”；不建议继续扩大该路径。

### P2-7（已确认，非原子）C2 跨库匹配逐簇单条 UPDATE，无事务；中途失败留下部分 matched_person_id/confidence

- 证据：`FaceKwService.swift:2195-2199` `for decision in decisions { try faceRepo.setClusterMatch(...) }`；外层 `reconcileAndMatch`（`:1888-1894`）只 catch + log，不回滚。
- 影响：best-effort 语义下可接受“没匹配上”，但不应出现“前 300 簇已写、后 700 簇没写”的半套状态；UI 会显示部分建议，重跑才会补齐。
- 建议：把本批 `setClusterMatch` 包进一个短事务（写 1000 行级别，持锁时间可控），或先收集再单条 `UPDATE ... CASE`；失败时整批不写，符合“建议是可选增强”的定位。

### P2-8（已确认，证据链）`--face-10k` 的聚类路径由构建配置决定，release 只能测精确、debug 只能测 LSH，且 debug 的 LSH 参数不是生产默认

- 证据：`Sources/GatherCoreBenchmarks/main.swift:366`（`faceClusterUsesExact() { !_isDebugAssertConfiguration() }`）、`:368-377`（`benchFace10k` 按 `exact` 传 `ClusterLshOptions(enabled: !exact, minPoints: 1_000, ...)`），`:285-298`。账本引用的 “debug LSH 12.98s / 15.56s” 是 `-Onone`，与 release 19.25s 不可比（账本自己也写“两种构建的数字不可互比”）。
- 影响：无法用同一 harness 做“release 精确 vs release LSH”的对照，因此“LSH 是否有价值/5s 能否靠 LSH 达标”没有 release 数据；`--face-10k` 不进默认档/CI，19.25s 靠人工 3 跑中位，不可回归。
- 建议：把路径变成显式 flag（`--face-10k --path=lsh|exact`），`minPoints` 用生产默认 20k 与候选 10k 各跑一次 release；harness 内做 3 次 warmup+median 输出，或至少在 CI 的 nightly 跑一次并上传 NDJSON。
- 附带漂移：`Sources/GatherCoreBenchmarks/README.md` 没有登记 `--face-10k`/10k face 基线（表中只有 dhash/embedding/lsh 的 2k/20k/50k 旧数据），与 main.swift 的入口不一致。

### P2-9（已确认，可复现性）cluster fixture 的生成器已不在仓库，golden 只能冻结不能再生

- 证据：`Tests/GatherCoreTests/Reconciliation/ClusterReconciliationTests.swift:3` 指向 `scripts/reconciliation/generate-cluster-fixtures.mjs`；实际 `scripts/reconciliation/` 只有 `generate-vector-fixtures.mjs`。
- 影响：17 例 golden（`cluster-fixtures.json`，Aug 11）无法按注释重建；若未来要扩 fixture 或核对 TS 语义，只能手写期望。
- 建议：恢复生成器（或把“冻结 golden，不再生成”写进 `docs/archive/` 并在测试头注明），避免下一位评审按注释找不到脚本。

### P2-10（已确认，pre-existing）Similarity analyze 落库缺 index_seq 守卫：分析期间导入/删除照片会写入过期划分

- 证据：`SimilarityService.swift:288-291` 只在开始时把 `(photos, indexSeq)` 放进同一读事务；`persistClusterOutcome`（`:1197-1216`）与 `similarityResultRepo.replace`（`SimilarityResultRepo.swift:73-94`）都不复核 `indexSeq`。对照 Face 的 C 阶段有守卫（`FaceKwService.swift:1762-1764`、`:2021-2022`）。
- 影响：分析（10k 时可达数十秒）期间新导入的照片不在结果里，表现为 ungrouped；被删除照片的成员行靠 `JOIN photos` 自然消失。不会写坏数据，但“结果与快照一致”的设计承诺（文件头 §8 注释）没有落地。
- 建议：在 `persistClusterOutcome` 的事务开头复核 `sessionRepo.getIndexSeq`，不一致则抛“工作区已变化，请重跑”（与 Face 同码/同文案）；补一条并发导入用例。

### P2-11（已确认，性能）邻域档预计算在 analyze 内再跑一遍 O(n²)，使主聚类 + 4 档并集 = 2 趟全量距离遍历

- 证据：`SimilarityService.swift:1386-1434`；`multiClusterProvider` 默认 `ClusterGraphPipeline.runTiers`（`:221-227`），档位由图重建（`ClusterGraph.swift:931-966`），主结果已单独 `run` 过一遍。
- 影响：10k/50k 相似度分析在落库后仍要多花一趟 O(n²)（best-effort，失败可忽略），且占用会话槽；对“分析完成”时延是纯附加成本。
- 建议：把主阈值并入同一次 `runTiers`（一次建图同时产出主结果 + 邻域档），或把档位预计算移到后台 job、不占 analyze 的 slot。

### P2-12（已确认，展示）增量新建簇的 label 用“现有行数 + 序号”，可能与幸存簇的 `Person N` 重名

- 证据：`FaceKwService.swift:2006, 2014-2016`（`labelBase = existingRows.count`，`"Person \(labelBase + newClusters.count + 1)"`）；全量路径按 `resolvedClusters` 下标从 1 连续编号（`:1640-1647`）。簇被 merge/removeMember 删除后行数会小于最大编号。
- 影响：UI 出现两个同名 `Person 3`（label 不是唯一键，不破坏数据，但用户会混淆）；不影响绑定（绑定按 cluster id）。
- 建议：label 仍按“最大现有编号 + 1”生成，或直接用 `max(existing labels)` 解析；补一条“删除中间簇后增量新建”的用例。

### P2-13（已确认，pre-existing）任意一条 rejected 反馈会整体关闭该会话的增量聚类，之后每次 analyze 都全量重建（簇 id/绑定迁移抖动）

- 证据：`FaceKwService.swift:1592-1605`：`constraintsPermitIncremental = snapshot.feedback.allSatisfy { guard $0.decision == "confirmed" else { return false } ... }`；只有 `incremental && constraintsPermitIncremental` 才走 `commitIncrementalClusters`，否则落到全量（`:1615-1668`）。该逻辑与 HEAD 旧实现逐行相同（`git show HEAD:...FaceKwService.swift:1336-1349`），非 Cut 5 引入。
- 影响：`removeMember`/拒绝一次建议后（`FaceKwService.swift:1183-1185` 写入 rejected），该会话的增量被关闭（直到反馈被删、照片被删，或被同人重新确认覆盖），每次 analyze 都 `deleteClustersBySession` 重建 → cluster id 变化、UI 选中丢失、绑定靠 overlap 迁移；10k 会话每次多 ~19s。
- 建议：把“rejected 只影响其覆盖的 observation/人物”而不是全局关闭增量（按 correction 的 photoId+bbox 把该 observation 排除出新簇，其余簇照常增量）；至少在文档里写明这一保守语义，并补一条“rejected 后仍走增量”的目标用例。
- 备注：初稿曾怀疑“增量会撤销 rejected”，复核后被这条全局 gate 否决——**该风险不存在**，但代价是增量被整体关闭。

### P2-14（部分已确认/部分疑似）非模型类 analysis signature 变化导致全部 observation 换 id 时，增量路径会留下空壳旧簇；无绑定空壳仅 DB 残留，有绑定空壳才进 UI/断链

- 证据：`migratingModel` 只看 `embeddingSpec`（`FaceKwService.swift:623-625`），改 `detect_confidence`/`preview_max_dimension` 等只会让 `isCacheValid` 失效（`:2408-2419`），不会触发迁移模式；A 阶段对每张照片 `replaceObservationsByPhoto`（`:819-833`）→ 所有旧 observation id 失效。增量 C 把引用旧 id 的成员当幽灵删除（`:1954-1971`、`:2025-2027`），旧簇行保留但成员为 0；新 observation 全部走 `assignIncrementally`，因旧簇质心为空（`Clusterer.swift:429-432` 跳过空簇）而全部成为新簇（`:2007-2017`、`:2049-2051`）。
- 若旧簇有 confirmed feedback（绑定簇），`constraintsPermitIncremental`（`:1592-1604`）通常会因“新 observation 不在 matched 簇里”拒绝增量 → 走全量，风险被挡住；只有当 `matchingObservations` 为空（bbox 漂移 >0.5）时 gate 才放行，此时旧绑定留在空壳簇、新簇未绑定。
- 影响：无绑定的 0 成员旧簇不会出现在 UI——`getClusters` 的 WHERE 只返回“有成员或 role_bindings”的簇（`FaceRepo.swift:782-791`），且 `existingRows` 也不含它们，所以是 DB 残留（等下次全量 `deleteClustersBySession` 清）；有绑定的 0 成员簇会被返回（`FaceRepo.swift:774` 注释自认“孤儿绑定同样返回，size=0”），此时绑定/建议断链、UI 出现空卡片，直到全量重聚类——这一段需要 bbox 漂移 >0.5 才触发，属于**疑似**。
- 建议：增量入口加“本次 replaced observation 比例”判定（例如 >50% 直接全量），或在增量 C 末尾清理“0 成员且无绑定”的簇；补一条“改 detect_confidence 后 analyze”的集成用例（含绑定簇）。

### P2-15（已确认，证据缺口）Cut 5 审计 §6.3 建议“2k/10k 冻结数据集的 groups_json digest 前后一致”（需 owner 确认），仓库没有该证据；现有 golden 只有 17 个微型 fixture

- 证据：`docs/archive/cuts/cut5-algorithm-audit.md:651-661` 的 §6.3 表把“2k/10k 冻结数据集 groups_json digest”列在“目标 = 前后完全相同”，同表“现状 = 无”，并标注“建议指标，需 owner 确认”；`:697` 再次写入 5b 验收。`docs/refactor-progress.md` 的 Cut 5 证据只有 “cluster-fixtures.json 17 例 + 200 次随机 + streaming 各一组用例”，没有 2k/10k 冻结输入/旧输出 digest；5a 的 `ClusterGraphParityTests` 已在 5b-2a 删除且未入 git，无法作为残留证据。
- 影响：wave vs stack 的差异（P2-1）是按结构证明的，但没有真实量级数据的回归网；若旧版曾对某个 10k 会话落过不同组内序，Cut 5 无法用 golden 发现（只会改变 UI 图片顺序，不会报错）。
- 建议：把一次 2k/10k 旧版输出（或在 HEAD 旧实现上生成）冻结为 `cluster-fixtures-2k/10k.json` 的 digest（只存输入 hash 摘要 + 期望 groups_json 摘要），在 `ClusterReconciliationTests` 做一次比对；不必把整份 groups 落库。

## 5. 关键判断与证据细节

### 5.1 划分 / 组序 / 种子序 / 稀疏节点（任务 1）

**已确认与旧 wave BFS 等价**：
- 旧 `waveBfsOverFilteredRows`（HEAD `ClusterEngine.swift`，见 `git show HEAD:...`）与新 `DegreeGatedBFS.groupsImpl`（`ClusterGraph.swift:627-687`）同构：种子升序、`degree + 1 < minGroupSize` 不成组、稀疏节点只被采纳不扩张、组内首元素恒为种子、每波按节点下标升序采纳。
- 新实现的 `adoptAll` 提前退出（`ClusterGraph.swift:650-681`）只在“frontier 已覆盖全部未入组节点”时跳过邻域并集；采纳顺序仍是 frontier 升序，不改变分组/组内序。旧实现此时会在下一波因 `~member` 为空而自然结束，结果相同。
- 旧 `recomputedBfs`（stack）与新 `groupsImpl` 的**划分相同、组内序不同**（DFS 逆序 vs 波次）。Cut 5 选择 wave 作为唯一 result 序，state 用 `canonicalGroups`（`ClusterGraph.swift:518-524`），与旧 `canonicalize`（HEAD `IncrementalClusterer.swift`）逐行一致。
- 补充穷举证据（本次）：对 200,000 个随机 n≤7 的汉明图（bits 3-7、threshold 0-bits、minGroupSize 2-6）分别跑新 wave 与旧 stack 两套 BFS：划分差异 0，组序（seed 序列）差异 0，仅组内成员序差异 82,146 例。即 wave/stack 只在“组内成员顺序”上不同，组数、组序、seed、成员集合完全一致。
- 结论：**wave vs stack 不影响 group_index / 簇 id / 角色绑定**。group_index 由组在 result 数组中的下标决定，而组序在两种 BFS 下都按种子升序；代表图都是 seed；Face 的簇 id 来自 DB 行、与 dHash 无关。**只影响组内成员顺序**（P2-1），进而影响 UI 图片排序。
- 稀疏节点语义：`minGroupSize` 是**种子/扩张门控**，不是组大小的硬下限——可构造“合格种子 + 全部邻居已被别组吸收”的 singleton group（minGroupSize≥4 时）。这是旧 wave/stack 共有的行为，Cut 5 原样保留；如果产品把 minGroupSize 当“组至少这么大”的保证，需要另开产品决策（本报告不判为 Cut 5 回归）。

**streaming > 32768**：
- `StreamingNeighborhoodGraph`（`ClusterGraph.swift:439-463`）只存 degrees、邻接按 `0..<nodeCount` 升序扫描并按 `distance <= threshold` 过滤；与位集图枚举顺序一致，因此 `components/groups` 逐位一致。生产入口在 `ClusterGraph.swift:907-921` 用 `degreesByTier([threshold])` 先算度，语义与位集路径的度数相同。
- 风险不在实现，而在测试覆盖（P2-2）。

### 5.2 单趟 / 多档 / state / diff（任务 2）

- **单趟同源**：`ClusterGraphPipeline.run` 一次建图同时产出 `result` 与 `state`（`ClusterGraph.swift:897-927`）；`decideCluster` 不再二次 `buildState`（`SimilarityService.swift:1132-1160`）。已确认。
- **多档并集**：`MultiThresholdHashGraph` 只建最高档并集行 + 各档度数，`tierGraph(at:)` 逐位二次核验（`ClusterGraph.swift:314-432`）；与旧 `clusterGloballyWithBitsetsMulti`（HEAD `ClusterEngine.swift`）同构。`runTiers` 用 `Set` 排序去重后按调用方原序回填（`:931-966`），并有用例逐档对比单档（`ClusterGraphTests.swift:355-377`）与 TS fixture（`ClusterReconciliationTests.swift:95-109`）。已确认。
- **canonicalGroups**：`[seed] + rest 升序`、组序保持 seed 升序（`ClusterGraph.swift:518-524`），与 state 落库口径一致；`SimilarityClusterSnapshot.state` 从行还原时按 `groupSeed` 归组并把 seed 提到首位（`SimilarityClusterStateRepo.swift:71-94`）。已确认（component_index 由分量在 state 数组中的位置决定；只重编号不改语义，digest 按成员集计算，故不另列缺陷）。
- **版本/签名/digest**：`currentAlgorithmVersion = 1`、`v|t|m|g` 指纹、FNV-1a64 规范文本（`ClusterGraph.swift:718-792`）；`stateIsReusable` 要求版本 + 指纹 + digest + 参数列六者全等（`SimilarityService.swift:1166-1194`）。旧 state（空指纹/空 digest，或版本≠1）一律走全量并覆盖；注意 `algorithm_version` 的 schema 默认是 **1**（`SchemaV1.swift:437`），所以迁移后的旧行主要靠 `input_signature`/`state_digest` 为空串失效，而不是版本号；用例 `SimilarityIncrementalServiceTests.swift:426-464` 已锁定版本/摘要两条失效路径。已确认。
- **行级 diff/apply**：`ClusterStateDiff` 四态分类（`ClusterGraph.swift:815-878`），`apply` 只 upsert `added+changed`、只删 `removed`，SQL 再用 `IS NOT` 做列级 no-op（`SimilarityClusterStateRepo.swift:200-229`）；`repeatedApplyDoesNotRewriteRows` 用触发器证明“零行级写”（`SimilarityIncrementalServiceTests.swift:466-501`）。已确认幂等（meta 版本仍递增，属设计）。
- **增量 vs 全量**：`IncrementalClusterer.update` 只重算受影响分量，装配后 `canonicalize`；200 次随机增删 × 3 参数与全量 state 逐位一致（`ClusterGraphTests.swift:439-521`）。已确认。
- 潜在缺口：`stateIsReusable` 的 digest 对 `component_index` 不敏感（规范文本只含成员/哈希/种子）。这是有意的“行序无关”，但也意味着**只篡改 component_index 的坏行不会被 digest 抓住**；由于 `snapshot.state` 用 index 归组，若 index 被改成“把两个分量混在一起”，组件成员集会变、digest 会变；若只做分量重编号，语义不变、无需失效。结论：可接受，非缺陷。

### 5.3 FaceMatcher 批量（任务 3）

- 库/范数一次：`librarySnapshot` 对实例库缓存 `libraryNorms`（`Matcher.swift:312-326`）；`score` 的 dot 逐项顺序、queryNorm/rowNorm 预计算与 `cosineSimilarity` 的累加顺序相同（`Matcher.swift:330-352` vs `:521-538`）。已确认。
- 批量与逐条逐位一致：`FaceMatcherBatchTests.swift:102-149` 用精确 `==` 对多种 margin/阈值/空簇/zero-vector 做对照。已确认。
- LSH skip：`match(clusters:)` 只调 `bestScoresPerPerson`（`Matcher.swift:406-441`），不碰 `lshIndex`；`batchDoesNotBuildLshIndex...`（`FaceMatcherBatchTests.swift:155-174`）锁定“批量 0 建索引、建过索引后批量仍精确”。已确认。
- 空库/单簇/阈值边界：空库 unknown（`FaceMatcherBatchTests.swift:177-189`）；单簇余弦 1.0、阈值含等号（`:192-211`）；`threshold=1.0+1e-6` 不命中。已确认。
- 内存上界：见 P2-5（批量仍可能分配 flat 副本）。
- 累加顺序边界：批量 `bestScoresPerPerson(queries:snapshot:)` 对每行先做维度 guard 再算分（`Matcher.swift:378-390`），错误触发点与逐条一致；非单位库行用预计算范数，数值与逐条逐位相同（用例覆盖）。已确认。

### 5.4 Face analyze A/B/C（任务 4）

- **A 短事务**：`applyInferenceResult` 每张照片一个 `connection.transaction`（`FaceKwService.swift:819-835`），事务内 replace 观测 + upsert 分析状态；取消/失败时按 `isCacheValid`（`:2408-2419`）跳过已提交照片，checkpoint 成立。已确认。
- **B 锁外**：`readClusterSnapshot` 一个读事务（`:1672-1688`）结束后才调 `clusterProvider`（`:1632-1633`）或 `assignIncrementally`（`:1987-1998`）；`DBConnection.transaction` 全程持 `NSRecursiveLock`（`DB.swift:337-371`），因此 B 确实不持连接锁。已确认。
- **C 守卫**：全量 `commitFullClusters` 与增量 `commitIncrementalClusters` 的事务首行都复核 `indexSeq`，同事务写 `cluster_signature`（`:1762-1764, 2021-2023, 2052`）；`clusterStoredObservations` 的任何异常都会 `clearClusterSignature`（`:1529-1541`），`analyze` 的 catch 对“A 已提交或取消”再清一次（`:957-967`）。已确认。
- **取消/失败中间态**：A 已提交的照片级观测保留（设计如此）；B 失败不改簇；C 的异常整事务回滚（迁移观测/簇/绑定同事务，`:1761-1855`）；`FaceIdentityArchitectureTests.swift:71-174` 覆盖“迁移失败/取消不发布半成品”和“聚类失败保留旧绑定”。已确认。
- **幽灵成员**：增量路径在事务内按成员行 id 删除 `observation_id` 为 NULL/已消失/重复认领的行（`FaceKwService.swift:1954-1971, 2025-2027`），用例 `FaceIncrementalClusterTests.swift:457` 锁定“不产生重复成员”。已确认。
- **C2 best-effort**：`reconcileAndMatch` 把 reconcile 与 match 各自 catch+log（`:1876-1894`），失败不回滚已提交簇；与 5c-2 声明一致。已确认（非原子见 P2-7）。
- **迁移回滚**：`prepared` 在 A 只入内存（`:806-815`），C 事务内写；C 内还按 source stat 复核文件未变（`:1769-1774`），任何失败整事务回滚。已确认。
- **并发/持锁**：同会话 analyze/recluster 由 `controllers` 互斥（`:462-467`），跨会话共享单连接由 `DBConnection` 串行化；B 期间其他会话可读写。已确认。**注意**：C 事务内包含 `deleteClustersBySession`（删全部成员）+ `saveClusters` + 可能的绑定迁移 + `getBindingsBySession`，是 O(簇/成员数) 的 SQL 集合，不是 O(1)；10k 人脸时是该连接上最长的事务。这是“C 短事务”的相对性，未列入 P1（无正确性问题），可作后续优化项。

### 5.5 性能 / HNSW / LSH / bench（任务 5）

- **19.25s 未复现**：仓库内 `desktop/native/gather-core/.build/out/Products/Release/gather-core-benchmarks` 是 2026-10-03 构建，早于 `--face-10k` 加入（源码 2026-10-22）；只读约束下未重建 release。故本报告只做“账本数字 + 代码路径 + 量级”交叉验证，标注 **未独立复现**。
- **HNSW 删除成立**：`VectorIndex.swift:4-5` 注释说明删除原因；`grep -rn 'Hnsw\|HNSW' Sources` 只命中注释/README/bench 注释，0 实现/0 调用。已确认。
- **LSH 价值有限且证据不足**：生产唯一使用点是 `FaceClusterer` 的 `n > 20k`（`Clusterer.swift:239-243`）；10k 会话不触发；`FaceMatcher` 的 LSH 路径生产零调用（P2-6）；`CosineLshIndex.neighbors` 每查询分配 `visited[Bool]`（`VectorIndex.swift:216`），在 20k-50k 时是 O(n) 清零的固定开销。release 下“LSH 能否把 10k 从 19s 拉进 5s”没有数据（P2-8）。
- **bench 可复现性**：数据生成用固定种子 `0xFACE10` / mulberry32（`main.swift:368-377`），NDJSON 输出字段齐全；但 (a) 路径绑定构建配置（P2-8），(b) harness 无 warmup/重复/中位数，账本的“3 跑中位”是人工，(c) 不记录 CPU/OS/构建参数，跨机不可比，(d) `benchFaceMatch` 的库只有 50 行（`main.swift:318-320`），152.8ms 只代表“10k 查询 × 50 库行”，不是生产大库的上界。
- **算法最优性**：在“精确 DBSCAN + 标量 Double 顺序累加”的约束下，10k×512 的 19.25s 已是该实现形态的合理量级；要达 5s 必须换执行形态（SIMD/Accelerate）或换候选生成（LSH/量化），仅靠“删 HNSW/合并 BFS”无法达成。这是本报告对 §6.3 未达的核心判断。

## 6. 已确认 vs 疑似

| 编号 | 结论 | 状态 | 理由 |
|---|---|---|---|
| P1-1 | 增量 result 过滤 minGroupSize，划分与全量不一致 | **已确认** | 代码 + 6-bit 反例（Python 复算新算法）；未在 Swift 实跑 |
| P1-2 | 10k 19.25s 未达 ≤5s | **已确认** | 账本自认 + 代码路径 + 量级核算；具体秒数未独立复现（见 §5.5） |
| P1-3 | CI app 测试缺 `--no-parallel` | **已确认** | ci.yml:87 + 6c 账本口径 + 多套件进程级共享；父 agent 已确认默认并行会失败 |
| P2-1 | 增量/全量组内序不同 | **已确认** | 两处代码直接对比；影响限于显示顺序 |
| P2-2 | streaming 大 n 稀疏覆盖不足 | **已确认**（测试缺口） | 用例注释自认只测完全图 |
| P2-3 | 多档 public API precondition | **已确认** | 代码即证据 |
| P2-4 | state 降级 delete 可能回滚主事务 | **已确认**（路径） | 代码即证据；触发需 DB 写失败，未构造 |
| P2-5 | batch 大库 flat 副本 | **已确认** | 代码即证据；实际峰值受库规模影响 |
| P2-6 | matchAgainstLibrary 生产零引用 | **已确认** | 全仓 grep |
| P2-7 | C2 匹配逐条写非原子 | **已确认** | 代码即证据；属 best-effort 设计边界 |
| P2-8 | face-10k 路径由构建配置决定 | **已确认** | 代码即证据 |
| P2-9 | cluster fixture 生成器缺失 | **已确认** | 文件系统 + 测试注释 |
| P2-10 | Similarity 落库无 index_seq 守卫 | **已确认**（pre-existing） | 代码对比 Face 路径；并发窗口未实跑 |
| P2-11 | 邻域档预计算第二趟 O(n²) | **已确认** | 代码路径 |
| P2-12 | 增量新簇 label 可能重名 | **已确认** | 代码 + 删除簇的路径；UI 影响未目视 |
| P2-13 | 任意 rejected 整体关闭增量 | **已确认**（pre-existing） | 代码 + HEAD 对照；性能/UX 影响未实跑 |
| P2-14 | 观察集整体替换后增量留空壳簇/绑定孤儿化 | **部分已确认 / 绑定部分疑似** | 空壳簇代码路径清楚；无绑定空壳仅 DB 残留，UI 可见/断链需 bbox 漂移 >0.5 |
| P2-15 | 2k/10k 冻结 groups_json digest 证据缺失 | **已确认**（证据缺口） | 归档审计验收项 vs 仓库产物 |
| 备注 | `minGroupSize` 不保证组大小 | 疑似（产品语义待定） | 可构造 singleton group；旧实现同行为，非 Cut 5 回归 |
| 备注 | `component_index` 重编号不被 digest 抓住 | 非缺陷（设计） | 只重编号不改语义；成员集变化会变 digest |

## 7. 结论

1. **Cut 5 的核心承诺基本兑现**：dHash 聚类收敛为 `ClusterGraphPipeline` 唯一实现，result/state 同源，多档共享并集行，state 有版本/指纹/摘要且旧 state 会失效，落库改成行级 diff/apply 并幂等；FaceMatcher 批量“库/范数一次 + 累加顺序不变 + 不建 LSH”有逐位对账用例；Face analyze 的 A/B/C 分段、锁外聚类、C 的 index_seq/签名守卫、幽灵成员清理、迁移回滚均有代码与用例支撑。**未发现 P0 级正确性缺陷。**
2. **两个必须在“完成”口径外记账的算法 P1（另有 CI 口径 P1 见上）**：
   - 增量 result 的 minGroupSize 二次过滤会丢掉全量保留的合法小组，违反“划分与全量完全相同”的不变量——建议删过滤并用 6-bit 反例补测；另需把“任意 rejected 关闭整个增量”的保守语义写进文档（P2-13）。
   - 10k 人脸 19.25s / ≤5s 未达——D-158 接受 ≤20s 是管理决策，但技术上仍有明确路径（vDSP/simd、LSH 门与 visited 分配、release LSH 对照），建议至少先补 release 对照数据再决定是否关闭。
3. **P2 不阻塞交付**，但其中 P2-4（失败面）、P2-5（大库内存）、P2-6/P2-8/P2-9（证据链/死路径）会影响后续维护成本，建议并入清理 backlog。
4. **口径提醒**：本次评审未改任何源码/测试/脚本，未重建 release，未做 GUI 验收；所有“未复现”的性能数字已标注来源（账本）与限制，不写成实测通过。

## 8. 复现与限制

- P1-1 反例：输入 `0x31,0x07,0x2a,0x1c,0x12,0x2b`、threshold=3、minGroupSize=4；分别跑 `ClusterGraphPipeline.run(...).result` 与 `IncrementalClusterer.result(state:outcome.state, ...)` 即可看到 `[[4,0,1,2,3],[5]]` vs `[[4,0,1,2,3]]`。本次未新增 Swift 用例（只读约束），反例由与新 `groupsImpl` 同构的 Python 脚本穷举得到。
- wave vs stack 对比：20 万随机图（n≤7、bits 3-7、threshold 0-bits、minGroupSize 2-6）；结论见 §5.1（划分/组序差异 0，组内序差异 82,146 例）。
- 性能：README 命令为 `cd desktop/native/gather-core && swift build -c release && .build/release/gather-core-benchmarks --face-10k`（实际 scratch 路径可能不同）。本报告未执行：只读约束、会写 `.build`，且现有 release 二进制早于该 flag。19.25s 来源 `docs/refactor-progress.md:32,151`。
- 未做：Swift 实跑 P1-1 反例、release 重建、GUI/人工验收；所有“疑似”项需按各自建议补用例或实测。

## 9. 附：关键文件:行索引

- `Sources/GatherAnalysis/Similarity/ClusterGraph.swift`: 15-40 层次/内存、314-432 多档、439-463 streaming、552-688 DegreeGatedBFS、718-792 版本/签名/digest、815-878 diff、891-966 pipeline、1019-1059 模式分发、1094-1118 映射
- `Sources/GatherAnalysis/Similarity/IncrementalClusterer.swift`: 75-234 update、177-216 装配、239-281 结果/规范序
- `Sources/GatherDomain/Services/SimilarityService.swift`: 252-481 analyze、1072-1161 decideCluster、1166-1194 复用判定、1197-1243 落库/降级、1318-1382 buildStoredResult、1386-1434 档位预计算
- `Sources/GatherPersistence/Database/Repositories/SimilarityClusterStateRepo.swift`: 71-94 快照还原、99-113 六列比对、161-232 apply
- `Sources/GatherAnalysis/Face/Clusterer.swift`: 153-186 点积/精确邻域、208-381 clusterEmbeddings、264-361 DBSCAN、406-524 增量/质心
- `Sources/GatherAnalysis/Face/Matcher.swift`: 174-205 库准备/LSH、312-352 快照/单行分、406-441 批量、446-538 逐查询
- `Sources/GatherAnalysis/Face/VectorIndex.swift`: 88 LSH 门、203-240 neighbors、243-297 verify
- `Sources/GatherDomain/Services/FaceKwService.swift`: 524-968 analyze、1174-1192 removeMember、1515-1669 B/C 入口、1672-1688 读快照、1747-1867 C 全量、1870-1895 C2、1931-2064 C 增量、2112-2200 批量匹配、2333-2340 开关/签名
- `Sources/GatherPersistence/Database/DB.swift`: 245-257 连接锁、337-371 事务/SAVEPOINT
- `Sources/GatherCoreBenchmarks/main.swift`: 96-124 生成器、285-356 face bench、366-377 --face-10k
- `Tests/GatherCoreTests/Similarity/ClusterGraphTests.swift`: 439-521 增量随机、530-627 streaming、355-429 多档/分发
- `Tests/GatherCoreTests/Services/SimilarityIncrementalServiceTests.swift`: 411-523 版本/摘要/幂等
- `Tests/GatherCoreTests/Face/FaceMatcherBatchTests.swift`: 102-261 逐位/边界
- `Tests/GatherCoreTests/Face/FaceIdentityArchitectureTests.swift`: 71-174 迁移/回滚
- `Tests/GatherCoreTests/Reconciliation/ClusterReconciliationTests.swift`: 81-130 fixture/streaming
- `Tests/GatherAppTests` 共享状态：`GlobalInfraTests.swift:241-245`、`LibraryViewModelTests.swift:273-276`、`Support/AppLanguageLock.swift:5`
- `.github/workflows/ci.yml`: 87
- `docs/refactor-progress.md`: 32、140-151（Cut 5 证据与 19.25s）、15（D-158）
# Cut 5 前置只读审计：算法单趟化（聚类 / ANN / 人脸三阶段）

> 任务：Cut 5（算法与收尾）开工前的**只读**审计。交付物仅本文件；
> 未修改任何源码/测试/Package，未做 GUI 或 Preview 目视验收。
>
> 基线：工作树（HEAD `82603e0` + Cut 4 未提交收尾）。行号以**当前工作树**为准，
> Cut 5 内部改动后会整体漂移，引用前请按符号名重新 `grep` 定位。
>
> 权威依据：`docs/reviews/refactor-design-breaking-2026-10-21.md` §6（算法）、
> §9「Cut 5」、§8.7（清理验收）；台账 `docs/cleanup-backlog.md` CL-05/06/13/20、
> `docs/test-audit.md` D8/D10/D13；决策 `docs/refactor-decisions.md` D-105/D-145。
>
> 本次**实测**（2026-10-22，本机）：
> - core：`swift test --disable-sandbox --cache-path .build/shared-cache --scratch-path .build/scratch`
>   → **1057 tests / 149 suites，exit 0**。
> - `gather-core-benchmarks --smoke`（2,000 条，debug 构建）实测 4 项：
>   dHash 聚类 287.19 ms / embedding-DBSCAN(强制 LSH) 711.49 ms /
>   **HNSW build 17,493.9 ms + query 688.8 ms** / LSH build+query 224.38 ms，
>   全程 19,526 ms——**其中 93% 是 HNSW**。
> - 未实测：10,000 条档、人脸 DBSCAN 精确路径规模、真库端到端。见 §8.3。

---

## 0. 结论摘要

### 0.1 关键数字（可复核）

| 项 | 实测 | 设计/台账值 | 差异与处置 |
| --- | --- | --- | --- |
| 相似度聚类实现 | **2 份**（ClusterEngine 753 行 + IncrementalClusterer 750 行 = 1,503 行） | 2 份 | 与台账一致 |
| 度门控 BFS 副本 | **6 份**（详见 §1.2） | 设计 §0.5「4 份」→ 台账「5 份 + 1 回退」 | **实测 6 份**；另有 1 份连通分量 BFS、1 份并查集分量、1 份 DBSCAN 区域生长（不同算法，不合并） |
| 每次全量相似度分析的距离遍历 | **3 趟 O(n²)**（clusterByHash + buildState + 多档位共享趟） | 未给 | 目标 1 趟（§2.3） |
| 人脸聚类每档次的点积对 | **n²**（DBSCAN 逐点 regionQuery，非 n²/2） | 未给 | 10k 脸 = 1.0e8 次 512 维点积（估算 ~17 s/单核，§4.2） |
| 人脸聚类执行的锁环境 | **在 `connection.transaction` 内**（FaceKwService.swift:902-933） | 设计要「锁外聚类」 | **P0**：单连接 + NSRecursiveLock 全程持锁（DB.swift:337-371） |
| FaceMatcher 生产调用 | **1 处**：`bestScoresPerPerson`（FaceKwService.swift:1797） | 设计要「单实例 + 批量 match(queries:)」 | 实例 API `matchAgainstLibrary` 生产 0 调用（仅测试/基准） |
| HNSW | `CosineHnswIndex` 471 行，生产引用 **0** | CL-06 删 | 基准里 93% 时间、build 2000 行要 17.5 s |
| `VectorNeighborIndex` 协议 | **不存在**（全仓仅台账 2 处提及） | 设计要「保留协议」 | **计划漂移**：需新建 |
| `similarity_cluster_meta` 列 | 8 列，**无** algorithm_version/input_signature/state_digest | 设计要求 3 列 | SchemaV1 修订（开发期重置库） |
| 模型加载 single-flight | **已存在**（EmbeddingModel.swift:607-636，锁覆盖加载全程） | 设计列为 Cut 5 待办 | 已完成，可勾销 |
| 可删行数（毛/净） | **毛 ≈ 2,900 / 净 ≈ 2,285**（逐项见 §1.4、§5.6） | §8.7「净删 6,000-8,000」 | Cut 5 只承担其中约 1/3，其余归 Cut 6 |
| 可删/迁移测试 | 删 ≥ 10 条、迁移 13 条、新增 ≥ 8 条 | §8.7「core 994→约 700」 | 该目标已被 Cut 1-4 稀释，Cut 5 口径改为 §6.3 |

### 0.2 三条主结论

1. **"双聚类"不只是两份代码，而是每次全量分析多跑一遍 O(n²)**：`decideCluster`
   先用 `ClusterEngine.clusterByHash` 出结果（SimilarityService.swift:1112），紧接着
   用 `IncrementalClusterer.buildState` 为**同一批输入**再建一遍 `ComponentGraph`
   （:1121）只为落增量状态。两趟的图结构完全相同，第二趟纯属浪费。
2. **人脸侧的瓶颈不是聚类算法而是它执行的锁环境**：DBSCAN + 跨库匹配整段跑在
   `connection.transaction` 里，持有全局连接锁；同一时刻 UI 的任何读（缩略图/画廊/
   状态轮询）都在等这把锁。且 n ≤ 20,000 时 LSH 不启用（`ClusterLshOptions.default`
   minPoints=20,000）→ 精确 O(n²) 点积，10k 脸约 17 s 锁内计算（§4.2）。
3. **基准程序自身就是最大的死代码载体**：2k 冒烟里 HNSW 占 93% 时间，而 HNSW
   生产引用 0；"10k 基准"在当前 harness 里**没有档位**（只有 2k/20k/50k），人脸侧
   只有需要真实照片目录的 `gather-face-benchmarks`。Cut 5 的验收指标必须先补
   harness，否则"达标"无法证伪（§6.2）。

---

## 1. 聚类实现清单

### 1.1 文件 / 行数 / 算法 / 入口

| 文件 | 行数 | 算法 | 生产入口（调用链） |
| --- | ---: | --- | --- |
| `GatherAnalysis/Similarity/ClusterEngine.swift` | 753 | dHash 汉明 ≤ threshold 的**连通分量 + 度门控 BFS**（sequential = 相邻段；global = bitset（n ≤ 32,768）/重算（n > 32,768）） | `SimilarityService.init` 默认 `clusterProvider`（:211-215）/ `multiClusterProvider`（:216-220）；`DuplicateService.init` 默认（:145-149）→ `:424`；`AppComposition.swift:277-281`（duplicates） |
| `GatherAnalysis/Similarity/IncrementalClusterer.swift` | 750 | 同一语义的**增量重放**：diff → 未受影响分量复用 → 受影响分量重算（`ComponentGraph` 位集 / `groupComponent`） | `SimilarityService.decideCluster`（:1082 update、:1121 buildState） |
| `GatherAnalysis/Face/Clusterer.swift` | 533 | **DBSCAN**（eps = 余弦相似度下限、minPts、质量核心点门槛、可选 retry 二遍、n > minPoints 走 LSH 候选） | `FaceKwService.init` 默认 `clusterProvider`（:485-493） |
| `GatherAnalysis/Face/VectorIndex.swift` | 866 | HNSW（471 行，死）+ 角度 LSH（`CosineLshIndex`，生产在用） | LSH：`Clusterer.swift:233-237`、`Matcher.swift:126-129` |
| `GatherAnalysis/Face/Matcher.swift` | 304 | 余弦匹配（精确全扫 / LSH 候选 + 精确复核） | `FaceKwService.swift:1797`（仅静态 `bestScoresPerPerson`） |
| `GatherAnalysis/Face/ClusteringImpact.swift` | 442 | 参数变更影响预估（复用 DBSCAN 语义） | **无生产入口**（仅 `ClusteringImpactTests` 9 条） |
| `GatherAnalysis/Concurrent/{BatchRunner,BatchCursor}.swift` | 139 | 有界并发批处理（`batchAsync`），12 个调用点 | 与人脸解码/哈希复用同一实现；Cut 5 的 pipeline 并发可直接复用 |

> 服务侧体量：`SimilarityService.swift` 1,417 行、`FaceKwService.swift` 2,160 行、
> `DuplicateService.swift` 826 行。Cut 5 只改其中的算法调度段，不改交付/写回段。

### 1.2 度门控 BFS 逐项 file:line（**实测 6 份**）

| # | 位置 | 结构 | 生产可达路径 |
| --- | --- | --- | --- |
| 1 | `ClusterEngine.swift:329` `waveBfsOverFilteredRows`（循环 :373-423） | UInt32 位集 + frontier 波次；邻接行 = 最高档并集 ∩ 本档阈值（`loadTierRow` :353-371 逐位**二次核验**汉明距离） | `clusterByHashMulti` → 多档位预计算（`SimilarityService.precomputeNeighborTiers` :1315） |
| 2 | `ClusterEngine.swift:512` `recomputedBfs`（循环 :539-575） | 显式栈 + `neighbors(of:)` 按需 O(n) 扫描 | n > 32,768 的 global 回退 |
| 3 | `ClusterEngine.swift:587` `waveBfsOverRows`（循环 :615-667） | UInt8 rows → UInt32 视图 + frontier 波次 | `clusterByHash`（n ≤ 32,768）＝**默认相似度/重复分析主路径** |
| 4 | `IncrementalClusterer.swift:330` `groupComponent`（循环 :377-410） | UInt64 位集 + 栈（自建 rows） | `buildState`/update 的分量规模 ≤ 32,768 时 |
| 5 | `IncrementalClusterer.swift:416` `groupComponentScanning`（循环 :445-478） | 度数预扫 + 按需扫描 | 分量 > 32,768 |
| 6 | `IncrementalClusterer.swift:656` `ComponentGraph.groups`（循环 :663-698） | UInt64 位集 + 栈 + `forEachNeighbor` | `buildState`（n ≤ 32,768）＝**每次全量分析的第二趟** |

邻近但**不属于**这 6 份（不要一起合并）：

- `IncrementalClusterer.swift:631` `ComponentGraph.components()`：纯连通分量 BFS（无度门控）。
- `IncrementalClusterer.swift:306` `connectedComponents`：并查集分量（n > 32,768 回退）。
- `Face/Clusterer.swift:314-342`：DBSCAN 种子扩展（密度语义，**与上面全部不同**）。

**同一语义被写 6 遍的实证**：三对互为镜像——
#3 ↔ #6（位集 + 栈/波次，仅容器类型不同）、#2 ↔ #5（按需扫描）、#1 ↔ #3
（唯一差别是"行来源"：并集过滤 vs 直取）。#4 与 #6 完全等价（#4 自建 rows）。

### 1.3 双重聚类（两处，独立）

**(a) 相似度：ClusterEngine ↔ IncrementalClusterer**

- 全量 run 的真实成本 = **3 趟 O(n²)**：
  1. `clusterByHash`（SimilarityService.swift:1112 → ClusterEngine:106-108 bitset 路径）
  2. `buildState`（:1121 → ComponentGraph.init :602-611 再算一遍邻接与度数）
  3. `precomputeNeighborTiers`（:1315 → clusterByHashMulti :165-168，单趟共享 + 4 档 BFS）
- 第 2 趟的唯一用途是"落增量状态"，而状态本身（分量 + 组种子 + 哈希）第 1 趟
  已经有全部输入。
- 台账 `cleanup-backlog.md:56` 记的"回退 `SimilarityService.swift:763`"是**行号漂移**：
  :763 属 `replayPendingDeliveries`。真实回退点是 `decideCluster` 的 catch
  （:1107-1109，增量失败退全量）。

**(b) 人脸：全量 DBSCAN ↔ 增量指派**

- `clusterStoredObservations`（:1425）→ 全量 `clusterProvider`（:1508）；
- `clusterStoredObservationsIncrementally`（:1602）→ `FaceClusterer.assignIncrementally`
  （:1649）→ 内部对未命中集合**再跑一次全量 `clusterEmbeddings`**（Clusterer.swift:469）。
- 两条路径各自持有一份"簇替换/追加"落库逻辑（:1549-1577 vs :1681-1709），
  语义已分叉（全量删簇重建 + 绑定迁移；增量只追加 + 清幽灵成员）。这是 Cut 5
  唯一需要**保留双语义**的地方（用户已绑定的角色不能在增量里被重建），
  但落库入口应统一到 `ClusterStateDiff.apply`。

### 1.4 可删 / 可合并（逐项行数）

| 项 | 位置 | 行数 | 处置 |
| --- | --- | ---: | --- |
| BFS #1/#3（位集波次，两选一） | ClusterEngine.swift:329-430 / 587-673 | 102 + 87 | **合并为 1 份** `DegreeGatedBFS.groups`（行加载策略参数化） |
| BFS #2 | ClusterEngine.swift:512-582 | 71 | 合并为 streaming 变体（唯一保留的第二形态） |
| BFS #4 | IncrementalClusterer.swift:330-412 | 83 | **删**（改用图） |
| BFS #5 | IncrementalClusterer.swift:416-480 | 65 | **删**（并入 streaming） |
| BFS #6 + ComponentGraph | IncrementalClusterer.swift:590-701 | 112 | 合并为 `HashNeighborhoodGraph` |
| 位集构建 ×2 | ClusterEngine.swift:232-251 / 288-313 | 46 | 合并进图构造器 |
| hex 解析 ×2 | ClusterEngine.swift:677-753 / IncrementalClusterer.swift:519-584 | 77 + 66 | 合并为 `HashGraphTable` |
| 并查集分量 | IncrementalClusterer.swift:306-327 | 22 | 删（用 `components(of:)`） |
| 第二趟 buildState 调用 + catch | SimilarityService.swift:1120-1140 | 21 | 删（pipeline 直接产出 state） |
| **相似度小计（仅上列重复段）** | | **752 行**（成对存在、合并后只留一份） | 加上只服务旧路径的壳（同步闭包签名、progress 映射、旧文件头）后毛删 ≈1,135；新增 ClusterGraph/Pipeline ≈ 620 → **净减 ≈ 515 行** |
| HNSW 主体 + 错误枚举 | VectorIndex.swift:53-523 / 795-798 | 471 + 4 | 删 |
| `benchHnsw` + 调用点 | GatherCoreBenchmarks/main.swift:210-242 / 322-324 | 36 | 删 |
| `ClusteringImpact`（源码 + 测试） | Face/ClusteringImpact.swift / ClusteringImpactTests.swift | 442 + 672 | 删（CL-13，需 owner 签字） |
| HNSW 对账测试段 | VectorIndexReconciliationTests.swift:39/44-58/104-126/127-150 | ≈ 55 | 删；套件降为 LSH-only 并改为默认运行 |
| FaceMatcher 旧实例 API 净残留 | Matcher.swift:196-268 | ≈ 30 | 被批量 API 取代 |
| 未接线 quality/alignment helper（疑似） | FaceQuality.swift:30-43,56-66 / Alignment.swift:41-74,200-241 | ≈ 40 | 【疑似】需 owner 判：对齐 API 是 `FaceAligner.align` 的组成部分，删要连带改 Encoder |
| **合计** | | **毛删 ≈ 2,900 / 净减 ≈ 2,285**（分项见 §5.6） | |

---

## 2. 目标 ClusterGraph / ClusterPipeline

### 2.1 输入 / 输出

- **输入**：`[HashEntry]`（photoId + hex；hex 宽度 8 字节为常态，允许更长）、
  `thresholds: [Int]`（0...64，已排序去重）、`minGroupSize`、`mode`（global/sequential）、
  可选的 `previous: ClusterState`（增量）。
- **输出**：`[ClusterResult]`（与 thresholds 同序）+ `ClusterState`（**同一趟产出**，
  不再二次 buildState）+ `ClusterStats`（nodes/edges/pairComparisons，诊断与基准用）
  + 可选 `ClusterStateDiff`（增量）。
- **不变量**（与现实现逐位对齐，靠 golden 锁定）：分量/组按"种子输入序"升序；
  组内首元素 = 种子；增量与全量的划分、组序、代表图一致（IncrementalClusterer.swift:5-15 的 4 条）。

### 2.2 边与阈值

- **边权**：无权重（布尔邻接）。`distance(a,b) = popcount(a ^ b) ≤ threshold`；
  阈值 ≤ 64（`DHash.isValidThreshold`），> 64 的哈希宽度仅影响解析（右对齐零填充）。
- **多档位**：`thresholds` 升序 → 只构造**最高档并集位图**（低档边是其子集），
  每档 BFS 时按当前档逐位核验（现 `loadTierRow` 的做法，:353-371）。理由：
  逐档独立位图在 n=32,768 时每份 134 MB，4 档 = 537 MB 不可接受；核验的额外成本
  O(tiers × E) 远小于 O(tiers × n²)。
- **度门控**：`degree(node) + 1 >= minGroupSize` 才可作种子/扩展点；稀疏节点
  "随组但不扩张"（这是与纯连通分量的唯一语义差别，必须保留）。
- **sequential 模式**：无图，相邻段合并（ClusterEngine.swift:183-217 原样保留）。

### 2.3 增量 vs 全量

| 场景 | 入口 | 复杂度 | 触发条件 |
| --- | --- | --- | --- |
| 全量（单趟） | `ClusterPipeline.run` | 1 × O(n²) 距离 + 每档 1 × BFS | 首次 / 参数变化 / 收敛间隔（`similarity_cluster_convergence_interval` 默认 10） |
| 增量 | `ClusterPipeline.update` | O(Δ·n) 邻域探测 + Σ O(k²) 受影响分量（Δ = 新增/变更数） | 状态参数匹配且 `incrementalUpdates < 收敛间隔`（SimilarityService.swift:1073-1080） |
| 超大规模 | run/update 内部自动切 streaming | O(n²) 时间，O(n) 额外空间 | n > `maxBitsetNodes`（32,768） |

关键改进：`run` 一次遍历同时产出"结果 + ClusterState"，消除 §1.3(a) 的第 2 趟；
`update` 不再为受影响分量重建第二份图（现 `graphCache` 已在做，保留该思路并上提）。

### 2.4 union-find 与 BFS 的分工

- **union-find**：只用于"增量装配"——未受影响分量内部直接 union、新增项按距离 union、
  受影响分量幸存者重算后 union（现 IncrementalClusterer.swift:151-218 的逻辑原样保留）。
- **BFS**：只用于"分量内的度门控分组"与"全量分量枚举"。
- 两趟都不要再各建一份邻接：**图是唯一真相源**（`HashNeighborhoodGraph` 提供
  `components()` 与 `groups(minGroupSize:)`），union-find 只操作节点下标，不碰邻接。

### 2.5 并发模型

- `ClusterPipeline` 是**无状态 enum**（static funcs），输入 `Sendable`，不持锁、不建 actor；
  每次运行创建一个 `ClusterWorkspace`（位集/visited/queued 缓冲），不跨调用共享。
- **聚类 CPU 扫描保持单线程**。理由（写进代码注释，防止后人"顺手并行"）：
  位集写入是 `rows[i] |= bit j` 与 `rows[j] |= bit i` 的双向写，分片并行需要
  per-shard 位图再 OR 合并（内存 ×T）或放弃对称写（比较量 ×2）。在 32,768 节点档
  （134 MB/图）两种代价都不划算，先靠"趟数 3→1"拿收益。
- **并行只保留在 IO/推理侧**：哈希解码（`SimilarityService` 的 `withTaskGroup`，:364-380）、
  人脸解码窗（4）、推理（见 §4.1：当前其实是串行）。
- **取消**：`isCancelled: () -> Bool` 注入，检查点在 pair 扫描每 4,096 行与每个种子/
  BFS 弹出；取消延迟上界 O(4096 × n)。现有实现**没有中途取消点**（`clusterProvider`
  是同步 `throws` 闭包，只能等它返回），是人脸侧"取消后仍要等十几秒"的根因之一。

### 2.6 Swift 签名草案

```swift
// ── GatherAnalysis/Similarity/ClusterGraph.swift ─────────────────────────────

/// 邻接枚举的唯一抽象：dHash 汉明与流式回退都实现它，BFS 只认这个协议。
public protocol NeighborhoodGraph: Sendable {
    var nodeCount: Int { get }
    var ids: [String] { get }
    func degree(of node: Int) -> Int
    /// 就地遍历（升序），不物化邻居数组（BFS 热点）。
    func forEachNeighbor(of node: Int, _ body: (Int) -> Void)
}

/// hex → 固定宽度字节 + UInt64 快路径；合并 ClusterEngine.writeHashBytes 与 ParsedHashes。
public struct HashGraphTable: Sendable {
    public init(hashes: [String]) throws          // 空串/非法 hex → ClusterEngineError.invalidHash
    public let count: Int
    public let width: Int
    @inline(__always) public func distance(_ a: Int, _ b: Int) -> Int
}

/// 位集图：n ≤ maxBitsetNodes 的默认实现（多档位共用最高档并集行）。
public struct HashNeighborhoodGraph: NeighborhoodGraph {
    public init(table: HashGraphTable, threshold: Int)
    public init(table: HashGraphTable, thresholds: [Int])   // 并集行 + 逐档核验
    public func components() -> [[Int]]
    public func groups(minGroupSize: Int) -> [[Int]]
}

/// 超大规模回退：度数预扫 + 按需扫描邻居（O(n) 额外空间）。
public struct StreamingNeighborhoodGraph: NeighborhoodGraph {
    public init(table: HashGraphTable, threshold: Int, degrees: [Int])
}

/// 度门控 BFS：全仓唯一实现（现 6 份的收敛点）。
public enum DegreeGatedBFS {
    /// 分量（局部下标，成员升序、分量按首元素升序）——取代 ComponentGraph.components。
    public static func components(of graph: some NeighborhoodGraph) -> [[Int]]
    /// 分组（种子升序；稀疏节点随组不扩张）——取代 BFS #1/#3/#4/#5/#6。
    public static func groups(of graph: some NeighborhoodGraph, minGroupSize: Int) -> [[Int]]
    internal static func groups(
        of graph: some NeighborhoodGraph, minGroupSize: Int,
        into workspace: inout ClusterWorkspace,
        onAdmitted: (Int) -> Void
    ) -> [[Int]]
}

/// 跨 seed / 分量 / 档位复用的位集 workspace（避免每次 append 新数组）。
public struct ClusterWorkspace {
    public init(nodeCount: Int, rowWords: Int)
    public mutating func reset(nodeCount: Int, rowWords: Int)
}
```

```swift
// ── GatherAnalysis/Similarity/ClusterPipeline.swift ──────────────────────────

public struct ClusterRequest: Sendable, Equatable {
    public var thresholds: [Int]          // 单档 = [t]；多档位预计算用
    public var minGroupSize: Int
    public var mode: HashGroupingMode     // .global / .sequential
    public var maxBitsetNodes: Int        // 默认 ClusterEngine.defaultMaxBitsetEntries
}

public enum ClusterPhase: String, Sendable { case scan, group }

public struct ClusterProgress: Sendable {
    public let phase: ClusterPhase
    public let current: Int
    public let total: Int
}

public struct ClusterStats: Sendable, Equatable {
    public let nodes: Int
    public let edges: Int
    public let pairComparisons: Int       // 基准门禁用：全量必须 ≈ n(n-1)/2，增量必须 < n²/8
}

public struct ClusterOutcome: Sendable {
    public let results: [ClusterResult]   // 与 request.thresholds 同序
    public let state: ClusterState        // 与 results[0] 同源，单趟产出
    public let stats: ClusterStats
}

public struct ClusterUpdate: Sendable {
    public let outcome: ClusterOutcome
    public let summary: IncrementalSummary   // 现 IncrementalClusterer.UpdateSummary 平移
    public let diff: ClusterStateDiff
}

public enum ClusterPipeline {
    public static func run(
        entries: [HashEntry],
        request: ClusterRequest,
        onProgress: ((ClusterProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ClusterOutcome

    public static func update(
        state: ClusterState,
        entries: [HashEntry],
        request: ClusterRequest,
        onProgress: ((ClusterProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ClusterUpdate

    /// sequential 模式无图（保留 HashGroupingMode.sequential 的原始语义）。
    public static func runSequential(
        entries: [HashEntry], threshold: Int, minGroupSize: Int
    ) throws -> ClusterResult
}
```

```swift
// ── GatherProtocol/Protocol/Similarity.swift（或 GatherPersistence 输入类型）──

/// 行级 diff：apply 不再 DELETE 全表（现 SimilarityClusterStateRepo.replace:134-137 是删全表重插）。
public struct ClusterStateDiff: Sendable, Equatable {
    public let upsert: [ClusterStateRow]      // photoId / hash / componentIndex / groupSeed?
    public let deletePhotoIds: [String]
    public let meta: ClusterMetaPatch         // version+1 / incrementalUpdates / algorithmVersion / inputSignature / stateDigest
}

public struct ClusterMetaPatch: Sendable, Equatable {
    public let algorithmVersion: Int          // = ClusterPipeline.algorithmVersion（迁移守卫）
    public let inputSignature: String         // hashes+参数 → digest，变了就不许增量
    public let stateDigest: String            // 结果划分 digest，用于"结果一致性"验收
    public let version: Int
    public let incrementalUpdates: Int
}
```

```swift
// ── 服务侧接线（仅改这三处，其余不动）────────────────────────────────────────
// SimilarityService.decideCluster：删掉 :1120-1140 的第二趟，改用 outcome.state
let outcome = try ClusterPipeline.run(entries: entries, request: request,
                                      onProgress: progress, isCancelled: { signal.aborted })
// DuplicateService._scanDuplicates:424 与 AppComposition:277-281 改为注入
// ClusterPipeline.run（同一实现，参数 minGroupSize=2 / mode=.global）
```

### 2.7 与持久化的关系（**Cut 5 的隐藏依赖**）

- `similarity_cluster_meta` 现只有 8 列（SchemaV1.swift:421-430），**无法区分
  "旧 ClusterEngine 落的 state"与"新 ClusterPipeline 落的 state"**：threshold/
  minGroupSize/mode 全等时 `matches()` 为真（Repo:86-90），5b 上线后会静默复用旧
  算法的分量/组种子 → 混合状态。必须：
  1. SchemaV1 修订：`similarity_cluster_meta` 加 `algorithm_version INTEGER NOT NULL`、
     `input_signature TEXT NOT NULL`、`state_digest TEXT NOT NULL`（开发期直接重置库，
     已有 `<db>.incompatible-<ts>` 通路；同时更新 `check-schema-v1.sh` 与 schema 文档数字）。
  2. `matches()` 增列比对；不匹配即全量 + 覆盖 state。
  3. `apply(diff)` 行级 upsert（`ON CONFLICT(session_id, photo_id) DO UPDATE`）+
     仅删 `deletePhotoIds`，替掉现在的"两表 DELETE 全表再插"（Repo:133-163）。
     收益：10k 照片时 state 写入从 10k 行重插降为 Δ 行。

---

## 3. FaceMatcher 批处理

### 3.1 当前调用点与开销

生产唯一调用链（Matcher.swift:291-304 的注释即承认）：

```
FaceKwService.matchClustersAgainstLibrary(:1763)
  ├─ 循环 cluster（:1783）
  │   ├─ faceRepo.getClusterMembers(clusterId)        ← 每簇 1 次 DB 读（:1784）
  │   ├─ FaceFeedbackRepo.list(sessionId)             ← 每簇 1 次全表读（:1785）★ N+1
  │   └─ for query in cluster.embeddings              ← 每张脸
  │        └─ FaceMatcher.bestScoresPerPerson(:1797)  ← 对 library 全量重扫（:179）
  └─ 中位数聚合 + FaceIdentityPolicy.decide（:1803-1811）
```

三重成本：
1. **N+1 DB**：`getClusterMembers` 与 `FaceFeedbackRepo.list` 在簇循环内（C 簇 → 2C 次查询），
   而 feedback 与 session 无关变化，一次读即可。
2. **逐查询全库重扫**：`bestScoresPerPerson` 对每条 query 遍历 `library`（R 行）算
   `cosineSimilarity`（:271-288）——**每次调用都重算 `magB`**（库行范数）与 `sqrt`。
   总成本 = 成员总数 × R × (3 累加 + 2 sqrt)，其中 2/3 的累加是重复的范数计算。
3. **索引未复用**：`FaceMatcher` 实例从不构造（生产只调 static 函数），所以
   `loadLibrary()` 的 LSH 分支（:112-133，R > 20,000 才启用）在生产里是**死路**；
   连"库平铺缓冲"（`libraryFlat`）都不会建，每次按 `library[j].embedding` 数组套数组访问。

### 3.2 数值一致性约束（改之前必须知道）

- 精确路径余弦是"逐项顺序累加"（Matcher.swift:271-288），与 LSH 路径的 4 维展开
  （VectorIndex.swift:851-866）是**两种浮点顺序**，文档明示不可互换（Matcher.swift:19-21）。
- golden 测试锁了阈值边界：`MatcherReconciliationTests.swift:166-172` 断言
  `threshold == 1.0` 时"恰好相等"即命中、`1.0 + 1e-6` 时不命中。
- **因此**：批量化的合法优化只有"把库行范数预计算一次"（每行仍按同一 `for i in 0..<n`
  顺序累加 → 位级同值）、"库读一次/索引建一次"、"按块扫描改善局部性"。
  **禁止**改累加顺序、禁止用 vDSP/SIMD 重排、禁止把 sqrt 换成 rsqrt。

### 3.3 批量化方案（签名）

```swift
public struct FaceMatchQuery: Sendable {
    public let clusterId: Int64
    public let embeddings: [[Float]]
}

public struct FaceMatchDecision: Sendable, Equatable {
    public let clusterId: Int64
    public let personId: String?      // nil = 未命中
    public let confidence: Double     // 簇内中位数（与现 :1803-1807 同口径）
    public let ambiguous: Bool        // 冠军/亚军差 < margin（:1808-1811 同语义）
}

public final class FaceMatcher {
    public init(library: [LibraryEmbedding], lshMinPoints: Int = CosineLshIndex.lshMinPoints)

    /// 单实例批量：库只归一化/建索引一次；查询按 chunk 扫描（默认 4,096）。
    public func match(
        clusters: [FaceMatchQuery],
        thresholdFor: (String) -> Double,     // persons.match_threshold
        defaultThreshold: Double,             // 0.65
        margin: Double,
        rejected: Set<String> = [],           // 每簇的拒绝集合由调用方一次算好
        chunkSize: Int = 4_096,
        onProgress: ((Int, Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> [FaceMatchDecision]
}
```

配套改 `matchClustersAgainstLibrary`：一次读 members（用现有 `getClusterMembers` 的批量版
或按 session 一次取全部成员行）、一次读 feedback、一次取 `person_embeddings`，
然后一次 `match(clusters:)`。调用方（`clusterStoredObservations` / incrementally）
的签名不变。

### 3.4 内存上界

| 项 | 公式 | 20k 行 × 512 维 | 备注 |
| --- | --- | --- | --- |
| 库平铺 | R × D × 4 B | 41 MB | 一次构建，全程持有 |
| 库行范数 | R × 8 B | 160 KB | 新增（换来 2/3 累加消除） |
| LSH 索引（R > 20k 才建） | 行拷贝 41 MB + 桶表 ≈ 1 MB | 42 MB | 与库平铺可共享（现实现是两份拷贝） |
| 查询块 | chunk × D × 4 B | 8 MB | 4,096 × 512 × 4 |
| 分数表 | 活跃簇数 × 人数 × 8 B | 小 | 逐簇聚合后可释放 |
| **峰值** | | **≈ 90 MB（LSH 路径）/ 49 MB（精确路径）** | 与当前"逐簇重扫"持平或更低 |

### 3.5 验收

- 结果一致性：`MatcherReconciliationTests` + `FaceMarginDecisionTests` 全绿（含 :166-172
  的边界断言），且同一 session 前后 `face_clusters.matched_person_id/match_confidence`
  逐行相等（digest 比对）。
- 性能：`matchClustersAgainstLibrary` 在 5k 脸 / 500 库行的合成集上，DB 查询数从 2C
  降为 ≤ 4（可用 SQL 计数探针断言），耗时降幅 ≥ 50%（见 §6.3）。

---

## 4. 三阶段人脸分析

### 4.1 现状（detect / embed / cluster 都在一个函数里）

| 环节 | 位置 | 事务 / 锁 | 进度 | 取消 |
| --- | --- | --- | --- | --- |
| 快照（photos + index_seq） | FaceKwService.swift:565-568 | 读事务 | — | — |
| 模型解析 + 签名 | :592-608 | 无 | `face.init`（:558） | — |
| 跨会话复用 / stat / 缓存判定 | :629-705 | 逐条读 | `face.cached-*` | 每循环查 signal（:570） |
| 检测 + 嵌入（逐照片） | :839-878（批 `flushBatch` :824-837） | **逐照片 1 个事务**（FaceRepo.replaceObservationsByPhoto:638-665） | `face.detect` 每照片 | 每照片查 signal（:840） |
| 失败判定 / 迁移预备 | :768-810（全编码失败保留旧观测；migrating 时只进 `prepared` 字典） | 无 | — | — |
| **重聚类 + 落库** | **:902-933 单个事务** | **持全局连接锁**（DB.swift:337-371） | `face.cluster` | 只在 :906/:1513 检查，**聚类本身不可中断** |
| 身份桥接 + 跨库匹配 | :1580-1588 / :1713-1721 | 调用方事务内 | — | 无 |

补充事实（易被误读）：
- `face_inference_parallel_workers` 上限 2（:707），但默认 provider 是**单引擎逐图串行**：
  `makeDefaultProvider` 返回的闭包 `for image in images { engine.analyzeBatch([image]) }`
  （:2102-2111），而 `analyzeBatch` 内部也是 `for image`（Inference.swift:82）。⇒ 该设置
  实际只影响"批大小 8"的分批，**没有并行度**。
- 模型加载 single-flight **已实现**（EmbeddingModel.swift:607-636，锁覆盖加载全程），
  设计 §6「模型加载 single-flight」可勾销。
- 进度是"照片计数"，聚类阶段用 (current,total) 但 total 语义与检测阶段不同（同一 phase
  下两套 total），UI 上会看到进度条回跳；相似度侧的 `precomputeNeighborTiers`
  （SimilarityService.swift:1315-1318）在 `similarity.cluster-done` 之后又复用
  `similarity.thresholds` 上报一轮，同一毛病。

### 4.2 长事务的量化代价

- 锁：`Database` 单连接（Database.swift:42）+ `NSRecursiveLock`（DB.swift:250），
  `transaction` 全程持锁（DB.swift:337-371）⇒ 聚类期间**所有** DB 读写排队。
- 计算量：n 张脸 → DBSCAN 逐点 `regionQuery`（Clusterer.swift:264-280）做 **n² 次点积**；
  n ≤ 20,000 时 LSH 不启用（`ClusterLshOptions.default` minPoints = `CosineLshIndex.lshMinPoints`
  = 20,000，Clusterer.swift:111）。
- 估算（单核、Double 逐项累加，512 维）：10k 脸 = 1.0e8 点积 × 512 ≈ 5.1e10 FMA ≈ **17 s**
  （按 1 FMA/cycle、3 GHz）；2k 脸 ≈ 0.7 s。**全部发生在锁内**。
- 结论：Cut 5 的"锁外聚类"不是风格问题，是 UI 卡死的直接原因；也是 10k 基准能不能过的
  关键（§6.3）。

### 4.3 目标阶段边界 + checkpoint

```
Stage A  detect+embed   （短事务 × N，可中断，天然可续跑）
  每照片：DECODE → DETECT → ENCODE → [txn] replaceObservationsByPhoto + upsertAnalysisState
  checkpoint = face_analysis_state（已存在，SchemaV1:299-306）——"哪些照片已算完"的真相源
  进度：face.detect(current,totalPhotos) / face.embed(同上，或合并为一个 phase)
  取消：每照片边界；取消后已提交的照片下次自动跳过（现 isCacheValid 语义不变）

Stage B  cluster       （零事务，纯内存）
  一次读事务取 observations + feedback + 已有簇 → ClusterPipeline/DBSCAN → 内存结果
  进度：face.cluster(processed, total)
  取消：isCancelled 注入到聚类内（新能力，延迟上界见 §2.5）
  失败：不改库，原样返回失败

Stage C  commit        （短事务 × 1~2，可重放）
  txn1：index_seq 守卫 → 删/写簇行 + 成员行 + face_cluster_state 签名
  txn2（best-effort）：personRepo.reconcileSession + 跨库匹配建议（对齐增量路径 :1713-1721）
  进度：face.commit / face.done
```

契约要求：
- **A 与 C 之间允许"库已变"**：C 开头必须重新 `getIndexSeq` 比对（现 :903），不等则
  "工作区已变化，请重新运行"；A 的成果保留（照片级 state 仍有效）。
- **C 必须幂等可重放**：C 用 `ClusterStateDiff` 行级 upsert，不再"删全表再插"
  （人脸侧现为 `deleteClustersBySession` + `saveClusters`，:1550-1551）。
- **progress/cancel 不跨阶段混用 total**：每个 phase 自带 total（修 §4.1 的进度回跳）。
- **对外合同不变**：`analyze(sessionId:detectorPath:encoderPath:eps:minPts:onProgress:)`
  签名、`FaceAnalysisResult(status:detectionFailures:encodingFailures:)`、phase 字符串
  前缀（`face.*`）都不改，ExecutorRegistry.swift:132-149 无需动。

### 4.4 风险点（阶段化本身引入的）

- "A 提交、B 失败" ⇒ 观测已更新但簇还是旧的：这是**更好**的状态（下次 recluster 即可），
  但 UI 会出现"人脸数变了、簇没变"的一帧；需要在 `face.cluster` 失败时把
  `face_cluster_state.cluster_signature` 清空（现签名写入在 :932 同事务；阶段化后要显式
  `DELETE FROM face_cluster_state`，可复用 FaceRepo.swift:589 的失效写法，目前没有公开的
  "清签名"方法，需新增）。
- 三阶段把 `captureManualIdentityFeedback`（:907）从"分析事务"挪到 C 之前：它现在
  在长事务里与聚类同源；挪出去后必须保证"C 之前采一次、C 之内不再变"。

---

## 5. 重复算法 / 死代码

### 5.1 HNSW（**已确认死**，CL-06）

- 位置：`Face/VectorIndex.swift:56-87 HnswConfig`、`:90-100 HnswHits`、`:104-523 CosineHnswIndex`
  （471 行）、`:795-798` 两条专属错误 case。
- 生产引用 **0**：全仓 `grep -w CosineHnswIndex` 只命中自身、`GatherCoreBenchmarks/main.swift:220`、
  `VectorIndexReconciliationTests`（5 条，默认被 `.enabled(if:)` 跳过）。
- 代价证据：2k 冒烟 `buildMs=17493.9`（19,526 ms 总时长的 93%）。
- 处置：删除 + 删 `benchHnsw` + 删对账测试的 HNSW 段；`VectorIndexReconciliationTests`
  降为 LSH-only 并**改为默认运行**（取消 `.enabled(if:)` gate，:39），同时把
  `docs/test-audit.md:195` 的"默认跳过 8 条"改为 3 条（`FaceRealPhotoPipelineTests`）。
- **保留** `CosineLshIndex`（生产：Clusterer.swift:233-237、Matcher.swift:126-129）与
  `VectorIndexError`（LSH 在用），并按设计要求**新建** `VectorNeighborIndex` 协议
  （现在不存在）让 `CosineLshIndex` 与未来的精确扫描实现同一接口。

### 5.2 ClusteringImpact（CL-13，**已确认无生产入口**）

- `Face/ClusteringImpact.swift` 442 行：`FaceClusteringImpact`/`Estimator`/`Parameters`/
  `FaceImpactObservation`/`FaceClusteringImpactError` 的全部引用都在自身文件 +
  `Tests/.../ClusteringImpactTests.swift`（9 条，672 行）。UI 的"重聚类"按钮不走预估。
- 处置：二选一——删（-1,114 行）或接 UI（FaceKeywordingView 的"重算影响预估"）。
  **需要 owner 签字**（产品决策，台账 §4.3 已注明）；本审计建议删，理由：Cut 5 的
  主题是"删旧实现"，把一个 442 行的未接线算法留到 Cut 6 只会拖长死代码寿命。

### 5.3 仅测试的算法符号

| 符号 | 位置 | 生产引用 | 处置 |
| --- | --- | --- | --- |
| `FaceVector` | VectorIndex.swift:39-51 | 0（仅自身） | 删 |
| `LshHits` | VectorIndex.swift:561-577 | 仅 `CosineLshIndex` 内部返回 | 降 internal |
| `FaceAligner.similarityTransform` / `FaceSimilarityTransform.apply` | Alignment.swift:41-74 / 200-241 | 仅测试（`FaceAlignmentTests`） | 【疑似】降 internal 或随对齐测试删；注意 `FaceAligner.align` 仍在生产（Encoder.swift:183） |
| `FaceQuality.sizeScore/rollScore/intersectionOverUnion` | FaceQuality.swift:30-66 | 仅内部 + 测试 | 降 internal（`captureQuality`/`composite` 生产在用） |
| `FaceEmbeddingShapeValidator/Fingerprint/ModelShape` | EmbeddingModel.swift:168-330 | 仅自身 + 测试 | 降 internal |
| `FaceProvider` | Provider.swift:21-40 | `LiveFaceAPI.swift` 3 处 | 保留（不是死代码） |

### 5.4 台账误判（**会误删生产代码，必须在 Cut 5/6 前修正**）

`docs/cleanup-backlog.md` §4.2 死代码表把下列**有生产调用点**的函数标成"仅测试；删"：

| 符号 | 台账结论 | 实测 |
| --- | --- | --- |
| `reuseSimilarityHashes`（:280） | 仅测试；删 | **生产调用** SimilarityService.swift:326（相似度 hash 复用的唯一入口，删了等于每次全量重算 hash） |
| `excludeExactDuplicateHashes`（:289） | 仅测试；删 | **生产调用** DuplicateService.swift:405（精确重复照片剔除） |
| `getClusterThumbnailPath`（:290） | 仅测试；删 | **生产调用** FaceRepo.swift:956/1018（合并簇、删簇时删缩略图） |
| `metricFromPixels`（:282） | 仅测试；降 internal | **生产调用** QualityService.swift:248/277/289 |

处置：Cut 5 不动这 4 个符号；Cut 6 执行清理前必须按"调用点 grep 而非引用计数"重核
台账（建议在台账该表加"调用点"列）。

### 5.5 取消能力缺口（不是死代码，但属"重复实现"的孪生问题）

- `DuplicateService` 调聚类时传 `onProgress: nil`（:424-430）且**无取消钩子**：n 万张的
  重复扫描一旦进聚类就只能等。
- `SimilarityService` 的 `clusterProvider` 是同步闭包，同理（取消只在聚类返回后:430 检查）。
- 唯一的修复点就是 §2.6 的 `isCancelled` 注入——一份实现同时解决三处。

### 5.6 汇总（更新 §1.4 合计）

| 类别 | 净删行数 |
| --- | ---: |
| 相似度双聚类 → ClusterGraph/Pipeline | 515 |
| HNSW + benchHnsw + 对账测试段 | 566 |
| ClusteringImpact（源码 + 测试） | 1,114 |
| 仅测试符号（FaceVector 等，含降级） | 60 |
| FaceMatcher 旧实例 API 净残留 | 30 |
| **合计净减** | **≈ 2,285**（毛删 ≈ 2,900） |

---

## 6. 测试与基准

### 6.1 现有算法测试（静态 `@Test` 计数，本次未逐条运行）

| 文件 | 条数 | 性质 | Cut 5 处置 |
| --- | ---: | --- | --- |
| `Reconciliation/ClusterReconciliationTests.swift` | 3 | golden fixture（`cluster-fixtures.json`）：clusterByHash / Multi / 两路径一致 | **迁**：改成断言 `ClusterPipeline` 输出（fixture 不变） |
| `Reconciliation/ClustererReconciliationTests.swift` | 4 | DBSCAN golden + LSH/精确一致 + 维度错 + 进度 | 保留 |
| `Reconciliation/DHashReconciliationTests.swift` | 1 | dHash golden | 保留 |
| `Reconciliation/MatcherReconciliationTests.swift` | 10 | 匹配 golden（含阈值边界 :166-172） | 保留（§3.2 的守门人） |
| `Reconciliation/VectorIndexReconciliationTests.swift` | 5 | HNSW 1 + LSH 3 + 空/校验 1（默认跳过） | **删 HNSW 段**，套件改默认运行 |
| `Similarity/IncrementalClustererTests.swift` | 10 | 增量↔全量 parity（含 200 次随机操作、2k 性能用例、长哈希） | **迁**到 `ClusterPipeline.update`（最强资产，不可删） |
| `Face/FaceIncrementalClusterTests.swift` | 11 | 增量指派/幽灵成员/签名/开关 | 保留（服务层） |
| `Face/FaceClustererQualityRetryTests.swift` | 10 | DBSCAN 质量门槛/retry | 保留 |
| `Face/FaceClusteringAccuracyTests.swift` | 7 | 合成集 ARI/精度基线（≤64 条/d=24）+ 打印基线表 | 保留；**规模不足以当基准** |
| `Face/FaceMatcherMarginTests.swift` | 9 | margin/歧义语义（精确 vs LSH 双路径） | 保留，补批量 API 用例 |
| `Face/FaceMarginDecisionTests.swift` | 1 | 生产路径 margin 扫描（打印表格） | 保留 |
| `Face/ClusteringImpactTests.swift` | 9 | 被测代码零生产调用 | **删**（随 CL-13） |
| `Services/SimilarityServiceTests.swift` | 30 | 服务行为（含聚类决策、回退） | 保留；改断言点（单趟） |
| `Services/SimilarityIncrementalServiceTests.swift` | 7 | 增量服务路径 | 保留 |
| `Services/DuplicateServiceTests.swift` | 27 | 重复扫描/单飞/决策 | 保留（注入 pipeline 后应无需改） |
| `Services/FaceKeywordingServiceTests.swift` | 51 | 人脸全流程（含跨会话重识别端到端） | 保留；三阶段后需补"阶段中断"用例 |

净效果：删 10 条（ClusteringImpact 9 + HNSW 1）、迁移 13 条（Cluster 3 + Incremental 10）、
新增 ≥ 8 条（单趟等价 / 多档位 / 超 32k 回退 / diff 原子性 / 取消延迟 / 三阶段中断）。
core 目标 **1,055 ± 5**（现 1,057）。

### 6.2 基准现状与缺口

| 项 | 现状 | 缺口 |
| --- | --- | --- |
| `gather-core-benchmarks` | 档位写死 `[2000] / [20000, 50000]`（:309），`--smoke`/`--multi-bench`；覆盖 dHash、embedding DBSCAN、HNSW、LSH | **没有 10k 档**；设计验收写"10k 基准"；HNSW 项要删 |
| `gather-face-benchmarks` | 需真实照片目录；逐照片 encode 计时 + 6 个 eps 的聚类 sweep（:110-120） | 无合成规模档；不可在 CI 跑 |
| 算法测试内的"性能用例" | `IncrementalClustererTests.swift:370`（2k 局部更新 < 10 s） | 只有一个断言，且是弱门限 |
| 本次实测基线（2k，debug） | dHash 287.19 ms / DBSCAN(LSH) 711.49 ms / HNSW 17,493.9 ms / LSH 224.38 ms | 作为新基准的锚点 |

**Cut 5 必须在 5d 补**（否则"达标"无法证伪）：
1. `gather-core-benchmarks` 增 `--sizes 10000`（或 `SCALE=10k`）：dHash 单趟 + 多档位，
   输出 `pairComparisons`/`peakBytes` 两个字段（由 `ClusterStats` 提供）。
2. 新 `--face-cluster 10000`：合成 512 维、50 身份 × 200 样本 + 高斯扰动，跑
   `FaceClusterer.clusterEmbeddings`（精确路径）+ `ClusterPipeline` 等价断言；
   输出聚类耗时与 ARI（合成集 ARI 有解析上限，只作回归门限）。
3. 删 `benchHnsw` 后同口径复跑，记录"基准总时长下降"。

### 6.3 Cut 5 验收指标（建议，需 owner 确认）

| 维度 | 指标 | 现状/基线 | 目标 |
| --- | --- | --- | --- |
| 趟数 | 一次全量相似度分析的距离遍历趟数 | 3（§1.3） | **1**（`ClusterStats.pairComparisons ≈ n(n-1)/2`，可用断言锁死） |
| 时间 | 10k dHash 全量（debug） | 估算 3 × 6.9 s ≈ 20.6 s（按 2k=287 ms 线性外推 n²） | **≤ 7.5 s**（1 趟 + BFS），release ≤ 1.5 s |
| 时间 | 10k 人脸 DBSCAN（精确路径，release 单核） | 估算 ≈ 17 s（§4.2），当前全部在锁内 | **≤ 5 s**，且 **0 s 在锁内**（锁外） |
| 时间 | `FaceMatcher` 500 库行 × 5k 脸 | 未测（N+1 + 逐查询全扫） | DB 查询 ≤ 4 次；耗时 −50% |
| 内存 | 聚类峰值（10k / 32,768） | 位图 12.5 MB / 134 MB（两趟各自分配） | 1 张图 + workspace：≤ 16 MB / ≤ 140 MB，且**不叠加** |
| 一致性 | 6 个 reconciliation fixture + 200 次随机增量 | 现全绿 | 逐组/逐成员**逐位相同**（含组序、种子位） |
| 一致性 | 2k/10k 冻结数据集的 `groups_json` digest | 无 | Cut 5 前后**完全相同**（`state_digest` 机制） |
| 测试 | core | 1,057/149 | 1,055 ± 5，且 0 skip（除 `FaceRealPhotoPipelineTests` 3 条） |
| 门禁 | `check-duplicate-symbols.sh` | 现有 allowlist | 6 份 BFS 归零：`grep -c 'while hasFrontier\|while let current = stack.popLast'` = 2（两种形态各 1） |

---

## 7. 分步计划（5a-5d）

### 5a 抽 ClusterGraph / ClusterPipeline（只增不改，可独立回滚）

- **范围**：新增 `ClusterGraph.swift`（`NeighborhoodGraph` / `HashGraphTable` /
  `HashNeighborhoodGraph` / `StreamingNeighborhoodGraph` / `DegreeGatedBFS` /
  `ClusterWorkspace`）与 `ClusterPipeline.swift`（`run/update/runSequential`）；
  **不改任何调用点**、不删旧实现。
- **第一步（本审计建议的最小切片）**：只落 `HashGraphTable` + `HashNeighborhoodGraph` +
  `DegreeGatedBFS.groups/components`，加一个新测试文件 `ClusterGraphParityTests`：
  ① 6 个 reconciliation fixture 上 `DegreeGatedBFS.groups` 与 `ClusterEngine.clusterByHash`
  逐组（含组序/组内序）相等；② 200 次随机增删下 `components` 与
  `IncrementalClusterer` 的分量逐个相等；③ n=32,769 走 streaming 与位集路径一致。
- **验收**：core 1,057 + 新增 ≥ 8 条全绿；`check-duplicate-symbols.sh` 不新增告警
  （新符号与旧符号同名的部分先在测试里并存）；无生产行为变化（diff 只加文件）。
- **风险**：`waveBfsOverRows`（波次）与 `groupComponent`（栈）的**采纳顺序**在极端图上
  可能不同（frontier 波次是"按位升序批量采纳"，栈是"后进先出"）。parity 测试若在 fixture
  上就红，说明 6 份 BFS **并不等价**——这正是本步要暴露的事实，处理方式是"以生产主路径
  （#3/#6）为准，其余作为 bug 修复"，并在 D-146 记录差异样例。
- **回滚**：删两个新文件即可，零风险。

### 5b 切调用点 + 删旧实现（不能与 5a 分 PR）

- **范围**：`SimilarityService.decideCluster` 改 `ClusterPipeline.run/update`（删第二趟）；
  `DuplicateService`/`AppComposition` 注入 `ClusterPipeline.run`；删 `ClusterEngine` 与
  `IncrementalClusterer`（保留 `ClusterState` DTO 与 `DisjointSet` 逻辑进新文件）；
  SchemaV1 增 `algorithm_version/input_signature/state_digest` + `apply(diff)` 行级 upsert；
  `SimilarityClusterStateRepo.matches` 增列比对。
- **验收**：`ClusterReconciliationTests`（迁移后）+ `IncrementalClustererTests`（迁移后）
  + `SimilarityServiceTests`/`SimilarityIncrementalServiceTests`/`DuplicateServiceTests` 全绿；
  2k/10k 冻结数据集 `groups_json` digest 与 5a 前一致；`grep -w 'ClusterEngine|IncrementalClusterer'`
  在 Sources 中 = 0（除注释/文档）。
- **风险**：① 旧 state 复用（§2.7）——必须先落 `algorithm_version` 且 `matches` 比对，
  否则会混用两种分量；② 簇顺序变化会改 `similarity_results.group_index` 与簇 id，
  UI 侧"选中簇"状态可能错位（similarity 页按 group_index 定位）；③ 增量路径的
  `graphCache` 优化若丢失，重复分析的性能会退化（加断言：update 的 pairComparisons < n²/8）。
- **回滚**：git 历史（唯一需要"新旧同 PR"的步骤，按设计 §8.1 不做开关）。

### 5c FaceMatcher 批量 + 三阶段人脸（服务层）

- **范围**：`FaceMatcher.match(clusters:...)` 批量 API（§3.3）；`matchClustersAgainstLibrary`
  改一次读库 + 一次匹配；`FaceKwService.analyze` 拆 A/B/C 三阶段（§4.3），
  聚类移出事务，`onProgress` phase 各自带 total；补 `isCancelled` 注入。
- **验收**：`FaceKeywordingServiceTests`（51）+ `FaceMatcherMarginTests`（9）+
  `FaceMarginDecisionTests`（1）+ `MatcherReconciliationTests`（10）全绿；
  新增用例：A 成功/B 取消 → 观测已提交、簇未变、`cluster_signature` 为空；
  C 前 index_seq 变化 → 报"工作区已变化"且不留半套簇。
  性能：10k 脸聚类期间并发的读事务延迟（可用测试里的第二个连接/探针断言）≤ 50 ms，
  当前是"等到聚类结束"。
- **风险**：① 聚类中的取消可能落在 A 与 C 之间，产生"观测新、簇旧"的中间态（可接受，
  但 UI 文案要能解释）；② `cluster_signature` 清理遗漏会让下次误判"无需重算"；
  ③ 三阶段把 `captureManualIdentityFeedback` 移出事务后，人工反馈与聚类输入存在
  时间窗（需在 C 之前重读一次 feedback）。

### 5d 基准 / 清理 / 文档

- **范围**：补 10k 档 + face-cluster 合成档（§6.2）；删 HNSW/ClusteringImpact/FaceVector
  等（§5）；`VectorNeighborIndex` 协议落地；更新 `docs/ADR.md`（HNSW 相关）、
  `DEVELOPMENT.md`、`docs/reviews/face-clustering-benchmark.md`（其 §1 已过时：
  说"无对齐/通用 FeaturePrint"，实际已有 `FaceAligner` + SFace）；
  修 `docs/test-audit.md` 的 skip 计数（8→3）与 `cleanup-backlog.md` 的 4 条误判（§5.4）。
- **验收**：§6.3 全表达标；`check-cleanup-ratchet`、`check-duplicate-symbols`、
  `check-no-legacy`、`check-docs` 全绿；基准输出归档到本文件附录（或新
  `docs/cut5-benchmark.md`）。
- **风险**：基准在 debug/CI 上噪声大（本次 2k 单次），需 ≥3 次取中位数并记录机器型号；
  否则"达标"结论不可复现。

---

## 8. 风险与待决

### 8.1 最大 3 风险

1. **簇顺序/身份迁移**：聚类顺序（种子序）决定 `group_index`、簇 id 与"按成员重叠迁移
   角色绑定"的输入（FaceKwService.swift:1552-1575、`migrateBindings` :1843）。6 份 BFS
   若不同序，5b 一上线就会出现"重新分析后角色名跑到别的簇"或"绑定消失"——这是用户可见
   的数据损失感（虽然 DB 只是开发期库，但 UI 体验是真实的）。防线：parity/golden +
   digest 比对 + 迁移前后对同一 DB 跑一次 dry-run。
2. **锁与中间态**：单连接 + 递归锁下，"聚类移出事务"必然引入 A/C 之间的窗口。若
   `index_seq` 守卫、`cluster_signature` 清理、feedback 重读三者任一遗漏，就会留下
   "簇引用已消失观测"的幽灵成员（增量路径已专门处理过，:1618-1647，全量路径没有）。
3. **证据缺口**：10k 档、face 规模档、真库端到端**都没有现成 harness**；HNSW 在 debug
   下 2000 行要 17.5 s，说明"用基准证明达标"这件事本身可能比改代码更贵。若不先补
   harness（5d 提前到 5a 之后），Cut 5 的"单趟/达标"只能靠推理而非实测。

### 8.2 计划漂移（本次实测 vs 设计/台账）

| 项 | 计划/台账 | 实测 | 处置 |
| --- | --- | --- | --- |
| 度门控 BFS | 4（设计）/ 5（台账） | **6** | 以 6 为准；台账 CL-05 需加 #6 |
| 回退路径 | `SimilarityService.swift:763` | `decideCluster` catch :1107-1109；:763 是写回重放 | 台账行号漂移，改 |
| `VectorNeighborIndex` | 设计"保留协议" | **不存在** | 5d 新建 |
| 模型 single-flight | 设计列为待办 | 已实现（EmbeddingModel.swift:607-636） | 勾销 |
| "10k 基准" | 设计验收 | harness 只有 2k/20k/50k | 5d 补档位 |
| 死代码表 4 条 | "仅测试；删" | 均有生产调用（§5.4） | 台账修正，Cut 5/6 不得删 |
| `similarity_cluster_meta` 3 列 | 设计要求 | 现 8 列，无这 3 列 | 5b 前的 schema 修订 |
| core 994→700 | §8.7 | 现 1,057 | 已被 Cut 1-4 稀释，Cut 5 口径改为 1,055±5 |

### 8.3 未实测清单（本审计的边界）

- 10,000 / 20,000 条的 dHash 与 face DBSCAN 真实耗时（只有 2k 实测 + n² 外推）。
- 人脸聚类期间 DB 锁的实际阻塞时长（无并发读探针）。
- 6 份 BFS 是否**逐位等价**（这是 5a 第一件要回答的事，不能在纸上断言）。
- 真库端到端（需要用户工作区；本次未开 GUI）。
- release 构建的绝对数字（本次全部 debug）。

### 8.4 需 owner 决策

1. `ClusteringImpact`：删（-1,114 行）还是接线（UI 预估入口）？建议删。
2. `similarity_cluster_convergence_interval`（默认 10）在单趟后是否还需要？单趟成本降
   3 倍后，改为"永远全量"可能更简单（少一套增量代码 ≈ 再减 400 行）；建议保留但把默认
   调大，5b 后用基准决定。
3. > 32,768 的回退是否保留？（生产会话目前最大照片数未统计；如果实际 < 32k，streaming
   变体可以推迟到 Cut 6。）建议保留（低成本、防 OOM），但只在 5a 的第三个测试里覆盖。

---

## 9. 复现命令

```bash
cd /Users/panzeyu2013/Desktop/code/develop/Gather

# 0) 测试基线（本次实测 1057/149, exit 0）
cd desktop/native/gather-core && swift test --disable-sandbox \
  --cache-path .build/shared-cache --scratch-path .build/scratch

# 1) 基准（本次实测：dHash 287 ms / DBSCAN 711 ms / HNSW 17494 ms / LSH 224 ms）
swift run --disable-sandbox --cache-path .build/shared-cache \
  --scratch-path .build/scratch gather-core-benchmarks --smoke

# 2) 6 份 BFS 定位
grep -n 'func waveBfs\|func recomputedBfs\|func groupComponent\|func groups(\|while hasFrontier' \
  Sources/GatherAnalysis/Similarity/{ClusterEngine,IncrementalClusterer}.swift

# 3) 双聚类 / 第二趟
grep -n 'clusterProvider(\|buildState(\|multiClusterProvider(' \
  Sources/GatherDomain/Services/SimilarityService.swift

# 4) 人脸长事务
grep -n 'connection.transaction' Sources/GatherDomain/Services/FaceKwService.swift

# 5) HNSW 生产引用（应为 0）
grep -rn 'CosineHnswIndex\|HnswConfig' Sources/ | grep -v Face/VectorIndex.swift

# 6) 测试/套件计数
grep -rn '@Test' Tests --include='*.swift' | wc -l     # 1057
grep -rn '@Suite' Tests --include='*.swift' | wc -l    # 98（运行时报告 149，含嵌套/参数化）
```

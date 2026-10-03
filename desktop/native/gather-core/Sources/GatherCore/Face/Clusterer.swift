// desktop/native/gather-core/Sources/GatherCore/Face/Clusterer.swift
// TS 源: desktop/src/main/services/face-kw/face-clusterer.ts（移植）
//
// 【相似度阈值语义（唯一事实，方向冻结，禁止在别处再解释一遍）】
// 参数 eps 是**相似度下限**，不是距离/半径：所有行先归一化为单位向量
// （imported/migrated 观测可能非单位），仅当两行的 cosine 相似度
// （= 单位向量点积）>= similarityThreshold 时才视为邻居。因此：
//   · 阈值越大越严格 —— 越难归为同一人，簇更小更多；
//   · 阈值越小越宽松 —— 越容易归为同一人，簇更大更少。
// 「半径 = 1 - 相似度」是反号刻度：调用方不得把本参数当半径反向换算。
// 默认 defaultSimilarityThreshold = 0.65，值域 similarityThresholdRange = 0...1；
// settings key default_eps、模板 face.eps、IPC 字段 eps 与本参数同义同刻度。
//
// 大语料（n > minPoints 且启用）走 angular-LSH 桶 + 多探针 + 精确复核的 ANN
// 路径（候选经精确余弦重验，precision 与暴力一致）。进度回调单调钳制，BFS
// 展开期间按心跳步长上报，避免调用方超时误判（TS 注释 153-163 行语义保留）。
//
// 【增量 vs 全量（assignIncrementally；ADR-029 未做项补齐）】
// 全量 clusterEmbeddings 每次对全部观测重跑 DBSCAN，服务层旧实现据此删簇重建：
// 用户已绑定的身份/角色会随簇 id 一起被冲掉。增量入口保留已有簇 id 与成员，
// 只处理本次新增/变化的观测：
//   · 每个已有簇先算质心：成员各自 L2 归一化（与全量路径的逐行归一化同语义；
//     全量对每个点都归一化，故此处不能直接用原始幅值求均值）→ 分量均值 →
//     L2 归一化。质心为空、成员维度不一致、或均值方向为零向量 → 跳过该簇
//     （不抛错，只当作"不可挂靠"）；
//   · 新观测 quality >= coreQualityFloor 且与某质心余弦相似度 >= eps → 追加到
//     最相似的簇；与亚军（同样 >= eps 的可行候选）差距 < ambiguityMargin 时
//     "歧义不猜"，转入新簇路径（语义与 matchClustersAgainstLibrary 的
//     face_match_margin 同源：宁可另立新簇，也不塞进可能错误的人）；
//   · 未命中的新观测**只对彼此**跑现有 DBSCAN（质量核心点 + retry 二遍，参数
//     与全量一致），产出 clusterId = nil 的新簇；仍未成簇者留在 noise，与全量
//     一致地不落库。
// 已知偏差（增量 ≠ 全量的具体情形，均为"不重排已有成员"的代价）：
//   1) 错过桥接合并：某张新脸同时靠近簇 A 与簇 B 的成员（互为邻居）时，全量
//      DBSCAN 会把 A、B 连成一个簇；增量只把它挂到最近质心，两簇保持分离。
//   2) 质心判据比"与任一成员相似"更宽松：与质心相似度 >= eps 不蕴含与某成员
//      相似度 >= eps（簇成员只靠链相连、彼此并不都相似时），增量可能多收一张
//      全量会当噪声的脸。
//   3) 低质量新脸（quality < floor）不参与质心判定，只可能在"未命中集合"内部
//      被高质量邻居吸收为边界点；全量里它还能被已有簇吸收——增量会把这种脸
//      留在 noise 或自立新簇。
//   4) 增量不改写已有成员归属，故"旧噪声后来变合格"不会在增量中发生；全量会。
// 收敛保证：增量不制造全量永远不会产生的划分——清晰可分数据上，增量结果再次
// 全量重聚类得到同一成员划分（见 FaceIncrementalClusterTests）。
import Foundation

/// TS: EmbeddingEntry（face-clusterer.ts:8-12）
public struct EmbeddingEntry: Equatable, Sendable {
    public let observationId: Int
    public let photoId: String
    public let embedding: [Float]
    /// 人脸质量分（0...1 语义，越大越可靠）。默认 1.0：既有调用点不传即
    /// 「所有点都合格」，配合默认 coreQualityFloor = 0 与引入 quality 前的行为一致。
    public let quality: Double

    public init(
        observationId: Int, photoId: String, embedding: [Float], quality: Double = 1.0
    ) {
        self.observationId = observationId
        self.photoId = photoId
        self.embedding = embedding
        self.quality = quality
    }
}

/// TS: clusterEmbeddings 返回值 { clusters, noise }（face-clusterer.ts:101）
public struct FaceClusterResult: Equatable, Sendable {
    public let clusters: [[EmbeddingEntry]]
    public let noise: [EmbeddingEntry]

    public init(clusters: [[EmbeddingEntry]], noise: [EmbeddingEntry]) {
        self.clusters = clusters
        self.noise = noise
    }
}

/// 增量聚类的一条产出（FaceClusterer.assignIncrementally 返回值元素）：
/// clusterId 非 nil = 追加到该已有簇；nil = 本次新建、库中尚无对应行的簇。
public struct IncrementalClusterAssignment: Equatable, Sendable {
    /// 已有簇 id；nil 表示新簇（调用方负责建行并取回真实 id）。
    public let clusterId: Int?
    /// 该簇**本次新增**的成员（已有成员的归属不变，不在返回值里；恒非空）。
    public let entries: [EmbeddingEntry]

    public init(clusterId: Int?, entries: [EmbeddingEntry]) {
        self.clusterId = clusterId
        self.entries = entries
    }
}

/// 增量聚类结果：assignments 覆盖全部归簇的新条目（已有簇追加 + 新簇），
/// noise 为未归入任何簇的新条目（语义同 FaceClusterResult.noise，调用方不落库）。
public struct IncrementalClusterResult: Equatable, Sendable {
    public let assignments: [IncrementalClusterAssignment]
    public let noise: [EmbeddingEntry]

    public init(assignments: [IncrementalClusterAssignment], noise: [EmbeddingEntry]) {
        self.assignments = assignments
        self.noise = noise
    }
}

/// TS: ClusterLshOptions + DEFAULT_CLUSTER_LSH_OPTIONS（face-clusterer.ts:24-34）
public struct ClusterLshOptions: Sendable {
    public var enabled: Bool
    public var minPoints: Int
    public var config: LshConfig

    public static let `default` = ClusterLshOptions(
        enabled: true,
        minPoints: CosineLshIndex.lshMinPoints,
        config: LshConfig(unitVectors: true))

    public init(enabled: Bool, minPoints: Int, config: LshConfig) {
        self.enabled = enabled
        self.minPoints = minPoints
        self.config = config
    }
}

public enum FaceClusterer {
    /// 相似度下限默认值（与 settings default_eps 的初始值同刻度，均为 0.6）。
    public static let defaultSimilarityThreshold = 0.65
    /// DBSCAN minPts 默认值（与 settings default_min_samples 的初始值同刻度）。
    public static let defaultMinSamples = 2
    /// 相似度下限合法值域（与 IPC validateFaceClusteringParameters 的 0...1 一致）。
    /// 越界即配置错误：入口拒绝执行，而不是静默夹取到边界。
    public static let similarityThresholdRange: ClosedRange<Double> = 0...1

    /// 逐行归一化为单位向量（TS: normalizeRows，face-clusterer.ts:60-75）。
    /// TS 就地修改 flat（Float32Array）；Swift 返回新数组。
    private static func normalizedFlat(_ source: [Float], n: Int, dim: Int) -> [Float] {
        var flat = source
        for i in 0..<n {
            let offset = i * dim
            var sumSq: Double = 0
            for k in 0..<dim {
                let value = Double(flat[offset + k])
                sumSq += value * value
            }
            let norm = sumSq.squareRoot()
            if norm == 0 { continue }
            let invNorm = 1 / norm
            for k in 0..<dim {
                flat[offset + k] = Float(Double(flat[offset + k]) * invNorm)
            }
        }
        return flat
    }

    /// 两行点积（TS: rowDotProduct，face-clusterer.ts:39-58）：4 展开 + 尾循环，
    /// Float32 存储、Double 累加——与 TS（Float32Array 读出 + JS number 累加）一致。
    private static func rowDotProduct(_ flat: [Float], dim: Int, aOffset: Int, bOffset: Int) -> Double {
        var dot: Double = 0
        var k = 0
        while k + 4 <= dim {
            dot +=
                Double(flat[aOffset + k]) * Double(flat[bOffset + k]) +
                Double(flat[aOffset + k + 1]) * Double(flat[bOffset + k + 1]) +
                Double(flat[aOffset + k + 2]) * Double(flat[bOffset + k + 2]) +
                Double(flat[aOffset + k + 3]) * Double(flat[bOffset + k + 3])
            k += 4
        }
        while k < dim {
            dot += Double(flat[aOffset + k]) * Double(flat[bOffset + k])
            k += 1
        }
        return dot
    }

    /// 精确邻域查询：邻居判据 = 单位向量点积（= cosine 相似度）>= similarityThreshold。
    /// active 为本遍参与聚类的全局点下标（升序）；第一遍 = 0..<n，retry 遍 = 第一遍 noise。
    /// 累加顺序与遍历顺序均不变，故 active 为全量时与改造前逐位一致。
    private static func exactRegionQuery(
        _ flat: [Float], active: [Int], dim: Int, pointIndex: Int, similarityThreshold: Double
    ) -> [Int] {
        var neighbors: [Int] = []
        let pointOffset = pointIndex * dim
        for i in active {
            if i == pointIndex { continue }
            if rowDotProduct(flat, dim: dim, aOffset: pointOffset, bOffset: i * dim) >= similarityThreshold {
                neighbors.append(i)
            }
        }
        return neighbors
    }

    /// TS: clusterEmbeddings（face-clusterer.ts:95-230），语义逐行对齐：
    /// - 维度不一致抛错（TS:115-118）
    /// - n == 0 → 空结果
    /// - LSH 路径启用条件：enabled && n > minPoints（严格大于）
    /// - regionQuery 的 LSH 分支排除自身（hits 里 candidate != pointIndex）
    /// - DBSCAN：minNeighbors = minPts - 1；noise = noiseIndices 过滤未分配者
    /// - 进度：progressStep = max(1, round(n/20))，bfsHeartbeatStep = max(64, round(n/2000))，
    ///   单调钳制（never regress）
    /// - coreQualityFloor（PhotoPrism CLUSTER_CORE 同义，默认 0 = 关闭）：只有
    ///   quality >= floor 的点可作核心点（种子 / BFS 扩展点）；不合格点仍可被高质量
    ///   簇吸收为边界点，但邻域达标也不得单独成簇，未被吸收则留在 noise。
    /// - retryMinSamples（PhotoPrism CLUSTER_CORE_RETRY 同义，默认 nil = 关闭）：
    ///   第一遍结束后仅对 noise 以该 minPts 再聚一遍（质量门槛不放宽），新簇追加到
    ///   既有簇之后且互不合并，仍未成簇者留在 noise。
    /// 外部参数标签 eps 保留（IPC/模板字段名冻结），内部一律以
    /// similarityThreshold 命名与解释：**越大越严格**（见文件头语义）。
    public static func clusterEmbeddings(
        entries: [EmbeddingEntry],
        eps similarityThreshold: Double = defaultSimilarityThreshold,
        minPts: Int = defaultMinSamples,
        coreQualityFloor: Double = 0,
        retryMinSamples: Int? = nil,
        onProgress: ((Int, Int) -> Void)? = nil,
        lshOptions: ClusterLshOptions = .default
    ) throws -> FaceClusterResult {
        guard similarityThreshold.isFinite, similarityThresholdRange.contains(similarityThreshold) else {
            throw ClustererError.similarityThresholdOutOfRange(similarityThreshold)
        }
        let n = entries.count
        if n == 0 {
            return FaceClusterResult(clusters: [], noise: [])
        }

        let dim = entries[0].embedding.count
        var flat = [Float](repeating: 0, count: n * dim)
        for i in 0..<n {
            let source = entries[i].embedding
            guard source.count == dim else {
                throw ClustererError.embeddingDimensionMismatch(
                    expected: dim, received: source.count)
            }
            flat.replaceSubrange(i * dim..<(i + 1) * dim, with: source)
        }
        flat = normalizedFlat(flat, n: n, dim: dim)

        var index: CosineLshIndex?
        if lshOptions.enabled && n > lshOptions.minPoints {
            index = try CosineLshIndex(dim: dim, config: lshOptions.config)
            try index?.build(rows: flat, count: n)
        }

        // CLUSTER_CORE（PhotoPrism 同义）：只有 quality >= coreQualityFloor 的点有
        // 核心点资格（可作种子 / BFS 扩展点），不合格点只能被吸收为边界点；无人吸收
        // 则留在 noise。默认 floor = 0 且默认 quality = 1.0 ⇒ 全部点合格，逐位同旧行为。
        var coreEligible = [Bool](repeating: false, count: n)
        for i in 0..<n {
            coreEligible[i] = entries[i].quality >= coreQualityFloor
        }

        var lastProgress = 0
        func emitProgress(_ current: Int, _ total: Int) {
            let capped = min(current, total)
            if capped < lastProgress { return }
            lastProgress = capped
            onProgress?(capped, total)
        }

        // 单遍 DBSCAN。active 为本遍参与聚类的全局点下标（升序）：第一遍 = 0..<n，
        // retry 第二遍 = 第一遍的 noise。visited/assigned/queued 按全局下标寻址、点积
        // 累加顺序不变 ⇒ active 为全量时与改造前逐位等价。返回全局下标形式的簇与 noise。
        func runPass(active: [Int], minPts: Int) throws -> (clusters: [[Int]], noise: [Int]) {
            let m = active.count
            if m == 0 { return ([], []) }
            var activeMask = [UInt8](repeating: 0, count: n)
            for globalIndex in active { activeMask[globalIndex] = 1 }

            func regionQuery(_ pointIndex: Int) throws -> [Int] {
                guard let index else {
                    return exactRegionQuery(
                        flat, active: active, dim: dim, pointIndex: pointIndex,
                        similarityThreshold: similarityThreshold)
                }
                let hits = try index.neighbors(
                    query: flat, queryOffset: pointIndex * dim, threshold: similarityThreshold)
                var neighbors: [Int] = []
                for h in 0..<hits.count {
                    let candidate = hits.indices[h]
                    if candidate != pointIndex && activeMask[candidate] != 0 {
                        neighbors.append(candidate)
                    }
                }
                return neighbors
            }

            var visited = [UInt8](repeating: 0, count: n)
            var assigned = [UInt8](repeating: 0, count: n)
            var clusters: [[Int]] = []
            var noiseIndices: [Int] = []
            let minNeighbors = minPts - 1
            let progressStep = max(1, Int((Double(m) / 20).rounded()))
            let bfsHeartbeatStep = max(64, Int((Double(m) / 2000).rounded()))

            for position in 0..<m {
                let i = active[position]
                if position % progressStep == 0 {
                    emitProgress(position, m)
                }
                if visited[i] != 0 { continue }
                visited[i] = 1

                let neighbors = try regionQuery(i)
                // 质量门槛：不合格点即使邻域达标也不得单独成簇；按 noise 候选处理并已置
                // visited ⇒ 之后被高质量簇吸收时只作边界点、不再扩展。
                if neighbors.count < minNeighbors || !coreEligible[i] {
                    noiseIndices.append(i)
                    continue
                }

                var cluster: [Int] = [i]
                assigned[i] = 1

                var seeds = neighbors
                var queued = [UInt8](repeating: 0, count: n)
                for seed in neighbors { queued[seed] = 1 }
                var seedIdx = 0

                while seedIdx < seeds.count {
                    let currentIdx = seeds[seedIdx]
                    seedIdx += 1

                    if seedIdx % bfsHeartbeatStep == 0 {
                        emitProgress(position + seedIdx, m)
                    }

                    if assigned[currentIdx] != 0 { continue }

                    if visited[currentIdx] == 0 {
                        visited[currentIdx] = 1
                        let currentNeighbors = try regionQuery(currentIdx)
                        // 扩展点同样必须合格：不合格点只作边界点。
                        if currentNeighbors.count >= minNeighbors && coreEligible[currentIdx] {
                            for candidate in currentNeighbors {
                                if visited[candidate] == 0 && queued[candidate] == 0 {
                                    queued[candidate] = 1
                                    seeds.append(candidate)
                                }
                            }
                        }
                    }

                    if assigned[currentIdx] == 0 {
                        assigned[currentIdx] = 1
                        cluster.append(currentIdx)
                    }
                }

                clusters.append(cluster)
            }
            emitProgress(m, m)

            let noise = noiseIndices.filter { assigned[$0] == 0 }
            return (clusters, noise)
        }

        let firstPass = try runPass(active: Array(0..<n), minPts: minPts)
        var clusterIndices = firstPass.clusters
        var remainingNoise = firstPass.noise

        // CLUSTER_CORE_RETRY（PhotoPrism 同义）：仅对第一遍 noise 以 retryMinSamples 再聚
        // 一遍（质量门槛不放宽），新簇追加在既有簇之后、不与第一遍簇合并；仍未成簇者留
        // 在 noise。nil = 关闭（默认，结果与引入该参数前一致）。
        if let retryMinSamples {
            let retryPass = try runPass(active: remainingNoise, minPts: retryMinSamples)
            clusterIndices.append(contentsOf: retryPass.clusters)
            remainingNoise = retryPass.noise
        }

        let clusters = clusterIndices.map { $0.map { entries[$0] } }
        let noise = remainingNoise.map { entries[$0] }
        return FaceClusterResult(clusters: clusters, noise: noise)
    }

    // ─────────────────────────── 增量入口 ───────────────────────────

    /// 增量聚类（语义边界与已知偏差见文件头「增量 vs 全量」）：
    /// 已有簇保留 id 与成员，只把 newEntries 归入最相似的已有簇质心，未命中的
    /// 新条目**只对彼此**跑与全量同参的 DBSCAN 产出新簇。
    ///
    /// - Parameters:
    ///   - existingClusters: 库里已有簇及其成员（簇 id 任意 Int，仅原样回传）。
    ///     质心 = 成员各自 L2 归一化后取分量均值再 L2 归一化；成员为空、成员维度
    ///     不一致或均值方向为零向量 → 跳过该簇（不抛错）。
    ///   - newEntries: 本次新增/变化的观测。
    ///   - eps: 相似度下限（与 clusterEmbeddings 同刻度：越大约严格）。
    ///   - minPts / coreQualityFloor / retryMinSamples / lshOptions: 未命中集合的
    ///     DBSCAN 参数，与全量路径同义同值。
    ///   - ambiguityMargin: 已有簇归属的"歧义不猜"下限（默认 0 = 关）。冠军与
    ///     亚军（两者都 >= eps 的可行候选）相似度差 < margin 时不归入任一已有簇，
    ///     转入新簇路径——与 matchClustersAgainstLibrary 的 face_match_margin 同源。
    ///   - onProgress: 只转发给未命中集合的 DBSCAN 调用（质心匹配是 O(k·n) 的
    ///     轻量阶段，不单独上报，避免两段 total 交替造成进度回退）。
    /// - Returns: assignments（已有簇追加 + 新簇，均非空）+ noise（未归簇的新条目）。
    ///   **不包含**已有簇的原成员，也不返回空簇。
    /// - Throws: eps 越界（ClustererError.similarityThresholdOutOfRange）；未命中
    ///   集合维度不一致（ClustererError.embeddingDimensionMismatch，同全量语义）。
    public static func assignIncrementally(
        existingClusters: [(clusterId: Int, entries: [EmbeddingEntry])],
        newEntries: [EmbeddingEntry],
        eps similarityThreshold: Double = defaultSimilarityThreshold,
        minPts: Int = defaultMinSamples,
        coreQualityFloor: Double = 0,
        retryMinSamples: Int? = nil,
        ambiguityMargin: Double = 0,
        onProgress: ((Int, Int) -> Void)? = nil,
        lshOptions: ClusterLshOptions = .default
    ) throws -> IncrementalClusterResult {
        guard similarityThreshold.isFinite, similarityThresholdRange.contains(similarityThreshold) else {
            throw ClustererError.similarityThresholdOutOfRange(similarityThreshold)
        }
        // newEntries 为空 = 无操作：不碰已有簇，也不产生新簇/噪声。
        if newEntries.isEmpty {
            return IncrementalClusterResult(assignments: [], noise: [])
        }
        let margin = ambiguityMargin.isFinite ? max(0, ambiguityMargin) : 0

        // 质心：成员各自 L2 归一化（与全量逐行归一化同语义）→ 分量均值 → L2 归一化。
        let centroids = existingClusters.compactMap { cluster -> (clusterId: Int, vector: [Double])? in
            guard let vector = centroid(of: cluster.entries) else { return nil }
            return (cluster.clusterId, vector)
        }

        // 质心匹配：quality >= floor 且存在相似度 >= eps 的候选时取最相似者；
        // 与亚军（同样 >= eps）差距 < margin 时不猜，留给新簇路径。
        // clusterOrder 保证输出顺序 = 传入顺序（首次出现即登记），可复现。
        var assignedByCluster: [Int: [EmbeddingEntry]] = [:]
        var clusterOrder: [Int] = []
        var leftovers: [EmbeddingEntry] = []
        for entry in newEntries {
            guard !centroids.isEmpty, entry.quality >= coreQualityFloor,
                  let unit = normalizedVector(entry.embedding)
            else {
                leftovers.append(entry)
                continue
            }
            var bestIndex = -1
            var bestSimilarity = -Double.infinity
            var runnerUpSimilarity = -Double.infinity
            for (index, centroid) in centroids.enumerated() {
                guard centroid.vector.count == unit.count else { continue }
                let similarity = dot(unit, centroid.vector)
                if similarity > bestSimilarity {
                    runnerUpSimilarity = bestSimilarity
                    bestSimilarity = similarity
                    bestIndex = index
                } else if similarity > runnerUpSimilarity {
                    runnerUpSimilarity = similarity
                }
            }
            guard bestIndex >= 0, bestSimilarity >= similarityThreshold else {
                leftovers.append(entry)
                continue
            }
            if margin > 0, runnerUpSimilarity.isFinite,
               bestSimilarity - runnerUpSimilarity < margin {
                // 近似并列：归入任何一簇都是猜测，转新簇路径（见文件头偏差 1/2）。
                leftovers.append(entry)
                continue
            }
            if assignedByCluster[bestIndex] == nil { clusterOrder.append(bestIndex) }
            assignedByCluster[bestIndex, default: []].append(entry)
        }

        var assignments = clusterOrder.map { index in
            IncrementalClusterAssignment(
                clusterId: centroids[index].clusterId,
                entries: assignedByCluster[index] ?? [])
        }
        var noise: [EmbeddingEntry] = []
        if !leftovers.isEmpty {
            // 未命中集合只对彼此聚类：与全量同参（质量核心点 + retry 二遍），
            // 因此新簇的划分与"从零开始全量"在这些点上是同一套判定。
            let result = try clusterEmbeddings(
                entries: leftovers,
                eps: similarityThreshold,
                minPts: minPts,
                coreQualityFloor: coreQualityFloor,
                retryMinSamples: retryMinSamples,
                onProgress: onProgress,
                lshOptions: lshOptions)
            assignments.append(contentsOf: result.clusters.map {
                IncrementalClusterAssignment(clusterId: nil, entries: $0)
            })
            noise = result.noise
        }
        return IncrementalClusterResult(assignments: assignments, noise: noise)
    }

    /// 已有簇质心：成员各自 L2 归一化 → 分量均值 → L2 归一化。
    /// 成员为空、维度不一致、无可贡献方向的成员（全为零向量）或均值方向为零
    /// 向量 → nil（调用方跳过该簇，绝不抛错——坏数据不应让整次增量失败）。
    private static func centroid(of entries: [EmbeddingEntry]) -> [Double]? {
        guard let dim = entries.first?.embedding.count, dim > 0 else { return nil }
        var mean = [Double](repeating: 0, count: dim)
        var contributing = 0
        for entry in entries {
            guard entry.embedding.count == dim else { return nil }
            // 零向量不贡献方向（全量路径里它同样与任何点都不相邻）。
            guard let unit = normalizedVector(entry.embedding) else { continue }
            contributing += 1
            for k in 0..<dim { mean[k] += unit[k] }
        }
        guard contributing > 0 else { return nil }
        let scale = 1 / Double(contributing)
        for k in 0..<dim { mean[k] *= scale }
        var sumSq = 0.0
        for value in mean { sumSq += value * value }
        let norm = sumSq.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return mean.map { $0 / norm }
    }

    /// L2 归一化（Double 精度）：零向量/非有限范数返回 nil（无法定义方向）。
    private static func normalizedVector(_ embedding: [Float]) -> [Double]? {
        var sumSq = 0.0
        for value in embedding {
            let double = Double(value)
            sumSq += double * double
        }
        let norm = sumSq.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return embedding.map { Double($0) / norm }
    }

    /// 两个等长向量的点积；长度不一致由调用方先过滤。
    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var result = 0.0
        for k in 0..<lhs.count { result += lhs[k] * rhs[k] }
        return result
    }
}

public enum ClustererError: Error, Equatable {
    case embeddingDimensionMismatch(expected: Int, received: Int)
    /// 相似度下限越界（合法域 FaceClusterer.similarityThresholdRange = 0...1）。
    case similarityThresholdOutOfRange(Double)
}

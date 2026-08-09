// desktop/native/gather-core/Sources/GatherCore/Face/Clusterer.swift
// TS 源: desktop/src/main/services/face-kw/face-clusterer.ts（移植）
// DBSCAN 聚类（embedding）：全部行先归一化为单位向量（imported/migrated 观测
// 可能非单位），小语料走 O(n²) 精确区域查询（点积 ≥ eps 即邻居，等价余弦
// 相似度），大语料（n > minPoints 且启用）走 angular-LSH 桶 + 多探针 + 精确
// 复核的 ANN 路径。进度回调单调钳制，BFS 展开期间按心跳步长上报，避免
// 调用方超时误判（TS 注释 153-163 行语义原样保留）。
import Foundation

/// TS: EmbeddingEntry（face-clusterer.ts:8-12）
public struct EmbeddingEntry: Equatable, Sendable {
    public let observationId: Int
    public let photoId: String
    public let embedding: [Float]

    public init(observationId: Int, photoId: String, embedding: [Float]) {
        self.observationId = observationId
        self.photoId = photoId
        self.embedding = embedding
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

    private static func exactRegionQuery(
        _ flat: [Float], n: Int, dim: Int, pointIndex: Int, eps: Double
    ) -> [Int] {
        var neighbors: [Int] = []
        let pointOffset = pointIndex * dim
        for i in 0..<n {
            if i == pointIndex { continue }
            if rowDotProduct(flat, dim: dim, aOffset: pointOffset, bOffset: i * dim) >= eps {
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
    public static func clusterEmbeddings(
        entries: [EmbeddingEntry],
        eps: Double,
        minPts: Int,
        onProgress: ((Int, Int) -> Void)? = nil,
        lshOptions: ClusterLshOptions = .default
    ) throws -> FaceClusterResult {
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

        func regionQuery(_ pointIndex: Int) throws -> [Int] {
            guard let index else {
                return exactRegionQuery(flat, n: n, dim: dim, pointIndex: pointIndex, eps: eps)
            }
            let hits = try index.neighbors(query: flat, queryOffset: pointIndex * dim, threshold: eps)
            var neighbors: [Int] = []
            for h in 0..<hits.count {
                let candidate = hits.indices[h]
                if candidate != pointIndex { neighbors.append(candidate) }
            }
            return neighbors
        }

        var visited = [UInt8](repeating: 0, count: n)
        var assigned = [UInt8](repeating: 0, count: n)
        var clusters: [[EmbeddingEntry]] = []
        var noiseIndices: [Int] = []
        let minNeighbors = minPts - 1
        let progressStep = max(1, Int((Double(n) / 20).rounded()))
        let bfsHeartbeatStep = max(64, Int((Double(n) / 2000).rounded()))
        var lastProgress = 0
        func emitProgress(_ current: Int) {
            let capped = min(current, n)
            if capped < lastProgress { return }
            lastProgress = capped
            onProgress?(capped, n)
        }

        for i in 0..<n {
            if i % progressStep == 0 {
                emitProgress(i)
            }
            if visited[i] != 0 { continue }
            visited[i] = 1

            let neighbors = try regionQuery(i)
            if neighbors.count < minNeighbors {
                noiseIndices.append(i)
                continue
            }

            var cluster: [EmbeddingEntry] = [entries[i]]
            assigned[i] = 1

            var seeds = neighbors
            var queued = [UInt8](repeating: 0, count: n)
            for seed in neighbors { queued[seed] = 1 }
            var seedIdx = 0

            while seedIdx < seeds.count {
                let currentIdx = seeds[seedIdx]
                seedIdx += 1

                if seedIdx % bfsHeartbeatStep == 0 {
                    emitProgress(i + seedIdx)
                }

                if assigned[currentIdx] != 0 { continue }

                if visited[currentIdx] == 0 {
                    visited[currentIdx] = 1
                    let currentNeighbors = try regionQuery(currentIdx)
                    if currentNeighbors.count >= minNeighbors {
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
                    cluster.append(entries[currentIdx])
                }
            }

            clusters.append(cluster)
        }
        emitProgress(n)

        let noise = noiseIndices
            .filter { assigned[$0] == 0 }
            .map { entries[$0] }
        return FaceClusterResult(clusters: clusters, noise: noise)
    }
}

public enum ClustererError: Error, Equatable {
    case embeddingDimensionMismatch(expected: Int, received: Int)
}

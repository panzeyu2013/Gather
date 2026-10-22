// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceClusteringAccuracyTests.swift
// 合成标注集上的**管线级**准确率基线（人脸聚类 FaceClusterer）。
//
// 目的：给「质量门槛 coreQualityFloor / 二遍 retryMinSamples」这些参数选择留一份
// 可复现的前后对照，而不是只有性能基准与召回对账。
//
// ── 方法论边界（必读：禁止把本文件的数字当真实识别精度引用） ──────────────
// 1. 数据来源：全部为**合成 embedding**（自写 PRNG 生成的「身份中心 + 受控噪声」），
//    不经过 Vision FeaturePrint、不含任何真实人脸照片、不依赖任何外部模型。
// 2. 本文件能证明的（且仅此）：
//    (a) 聚类**决策逻辑**（相似度门槛、质量门槛）在可控几何分布上按设计工作，且
//        参数变化带来可测量的 precision/recall 取舍（B 组与对照①②）；
//    (b) 指标实现正确：两种独立 ARI 写法（列联表期望值 / 配对计数）互相一致，并与
//        手算小例精确对齐（见 adjustedRandIndexImplementationsAgree…）；
//    (c) 基线数字本身逐位可复现（同 seed 同结果），可作回归护栏。
// 3. 本文件**不能**证明：真实人脸识别准确率；真实素材上 eps/threshold/margin/
//    coreQualityFloor 的最优取值；跨年龄/光照/遮挡/域偏移下的表现。真实精度依赖
//    FeaturePrint（未来 CoreML 模型）与真实标注素材，必须由真实素材标注集验收。
//    **本基线不得替代 Stretch 门。**
// 4. A 组（干净集）是**生成器自检/健全性检查**：数据按构造满足「类内最小余弦 >
//    eps 且类间最大余弦 < eps」，于是「划分 = 真值」是该前提的代数后果——它验证
//    「前提成立时指标实现与聚类器一致」，**不构成聚类质量证据**，不得被引用为
//    「F1 = 1.0 的性能基线」。有信息量的是 B 组与两个对照（前提不再自动成立）。
// 5. 指标口径：noise 点按**单点簇**计入（不丢弃）。注意：把难样本丢进 noise 本身
//    就会抬高 pairwise F1（noise 越多，跨身份共簇对越少，0.4722 → 0.5000 的
//    代价是 40% 样本进 noise）。因此本文件每条结果**并列 noise 率**，并在 B 组
//    额外给出「限制到共同成簇子集」的同覆盖率比较；只引用 F1 不看 noise 率的
//    结论一律无效。
// 6. 确定性：自写 SplitMix64 PRNG；不使用 Int.random/Double.random/shuffled()；
//    不依赖 Dictionary 遍历顺序（一律按 key 排序后取数）。
// 7. 规模与口径：≤ 66 embeddings / d=24、**单 seed**、样本规模刻意保持小（更大规模
//    落 O(n²) 分支，实测 2k 需数十秒 debug）。**本表的簇数/覆盖率/精度只对「本文件
//    这一次合成的观测集」成立**：真实库若只把部分观测传入，簇数与覆盖率会与全量
//    全面分叉；结论不得外推到真实库、其他 seed 或更大规模。
//
// C 组（相近身份 + margin）已移出本文件：由生产路径驱动的版本见
// FaceMarginDecisionTests.swift（旧版在本文件内复刻 bindByMargin，不测生产决策）。

import Foundation
import Testing

@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

// MARK: - 确定性伪随机数（自写，禁止系统随机）

/// SplitMix64 变体：同一 seed 的流逐位可复现。仅服务于本文件的合成数据，
/// 与生产代码（CosineLshIndex 内部 PRNG）无关。
private struct AccuracyPRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // 固定偏移混淆：避免 seed=0 / 相邻 seed 退化成弱起点。
        self.state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x853C_49E6_748F_EA9B
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 均匀分布（53 位精度）。
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// 标准正态（Box–Muller）：每对消耗两次 unit()，不缓存第二值 ⇒ 无隐藏状态。
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// d 维随机单位方向：各分量独立标准正态后归一化。
    mutating func unitVector(dim: Int) -> [Float] {
        var raw = [Float](repeating: 0, count: dim)
        for k in 0..<dim { raw[k] = Float(gaussian()) }
        return normalizeFloats(raw)
    }
}

// MARK: - 向量工具

private func normalizeFloats(_ vector: [Float]) -> [Float] {
    var sumSquares = 0.0
    for value in vector { sumSquares += Double(value) * Double(value) }
    let norm = sumSquares.squareRoot()
    guard norm > 0 else { return vector }
    return vector.map { Float(Double($0) / norm) }
}

/// 余弦相似度（单位向量下即点积；此处对非单位向量也正确）。
/// 对 FaceMarginDecisionTests.swift（生产路径 margin 用例）同样可见：合成生成器
/// 与本文件的距离口径必须同源，避免两处各写一份浮点累加顺序。
func cosineFloats(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for k in 0..<min(a.count, b.count) {
        dot += Double(a[k]) * Double(b[k])
        normA += Double(a[k]) * Double(a[k])
        normB += Double(b[k]) * Double(b[k])
    }
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA.squareRoot() * normB.squareRoot())
}

/// 生成与 basis（期望为单位向量）正交的随机单位方向：两轮去投影后归一化。
/// 用途：让低质量退化方向与所有身份中心近似正交（|cos| 小于 1e-6），
/// 从而「低质量样本与任何身份都不像」是构造出来的事实，而不是碰运气。
private func orthogonalDirection(basis: [[Float]], prng: inout AccuracyPRNG, dim: Int) -> [Float] {
    var vector = prng.unitVector(dim: dim)
    for _ in 0..<2 {
        for base in basis {
            let projection = Float(cosineFloats(vector, base))
            for k in 0..<dim { vector[k] -= projection * base[k] }
        }
    }
    return normalizeFloats(vector)
}

// MARK: - 合成标注集

/// 一条合成人脸观测：身份标签 + embedding + 质量分（+ 是否高质量，便于对账构造）。
struct SyntheticFaceSample {
    let index: Int
    let identityIndex: Int
    let identityId: String
    let embedding: [Float]
    let quality: Double
    let isHighQuality: Bool
}

struct SyntheticFaceDataset {
    let dim: Int
    let identityIds: [String]
    /// 身份中心（单位向量，与 identityIds 同序）。
    let centers: [[Float]]
    let samples: [SyntheticFaceSample]

    var identityCount: Int { identityIds.count }
    var size: Int { samples.count }
    var highQualityCount: Int { samples.filter(\.isHighQuality).count }
    var lowQualityCount: Int { samples.count - highQualityCount }

    /// 高质量样本的类内最小余弦 / 类间最大余弦：阈值可达性的直接证据。
    /// 只统计高质量样本（低质量样本按构造与身份中心近正交，混进来会掩盖分离度）。
    func highQualitySeparation() -> (minIntra: Double, maxInter: Double) {
        let points = samples.filter(\.isHighQuality)
        var minIntra = Double.infinity
        var maxInter = -Double.infinity
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let score = cosineFloats(points[i].embedding, points[j].embedding)
                if points[i].identityIndex == points[j].identityIndex {
                    minIntra = min(minIntra, score)
                } else {
                    maxInter = max(maxInter, score)
                }
            }
        }
        return (minIntra, maxInter)
    }
}

/// 低质量样本的构造方案（四个来源，分别检验门槛的不同面）。
struct LowQualityPlan {
    /// 每身份从**共享退化方向**生成的样本数（模糊/大侧倾：嵌入退化成同一方向）。
    /// 跨身份互相高度相似 ⇒ floor=0 时它们自己抱团成跨身份簇（precision 损失）。
    var degradedPerIdentity = 0
    /// 每身份从**本人专属退化方向**生成的样本数：只与本人的同类低质量样本相似。
    /// floor=0 时是正确的同人小簇；floor 大于 0 时因不能当核心点落入 noise（召回代价）。
    var privatePosePerIdentity = 0
    /// 对照①：每身份「低质量但方向指向本人」的样本数。embedding =
    /// normalize(本人中心 + correctPoseWeight·本人专属方向 + correctPoseNoise·扰动)。
    /// 与本人高质量簇相似度接近但**低于 eps**（构造前提，测试断言），同身份样本之间
    /// ≥ eps ⇒ floor=0 时自成同人小簇，floor=0.5 时进 noise：门槛的代价是「少成簇」
    /// 而不是「错聚」。
    var correctPosePerIdentity = 0
    var correctPoseWeight = 0.9
    var correctPoseNoise = 0.1
    var quality = 0.25
    /// 样本 = normalize(directionWeight·退化方向 + residualNoise·随机扰动)。
    var directionWeight = 0.9
    var residualNoise = 0.3
}

struct SyntheticDatasetConfig {
    var seed: UInt64
    var dim = 24
    var identityCount = 8
    var highQualityPerIdentity = 8
    /// 高质量样本 = normalize(身份中心 + intraNoise·随机单位方向)。
    var intraNoise = 0.25
    /// 任意两身份中心 |cos| 上限（拒绝采样 + 正交回退，确定性）。
    var maxCenterCosine = 0.35
    /// 指定身份 0/1 的中心余弦（相近身份，用于 margin 测试）；nil = 不使用。
    var closePairCosine: Double?
    var lowQuality = LowQualityPlan()
    var identityPrefix = "id"
}

func makeSyntheticDataset(_ config: SyntheticDatasetConfig) -> SyntheticFaceDataset {
    var prng = AccuracyPRNG(seed: config.seed)
    let dim = config.dim

    // 1) 身份中心：受控类间余弦。
    var centers: [[Float]] = []
    for identity in 0..<config.identityCount {
        if identity == 1, let target = config.closePairCosine {
            // 相近身份：c1 = normalize(cosθ·c0 + sinθ·orth)，cos(c0, c1) = cosθ（可解析）。
            let orth = orthogonalDirection(basis: [centers[0]], prng: &prng, dim: dim)
            let cosTheta = Float(target)
            let sinTheta = Float((1 - target * target).squareRoot())
            var center = [Float](repeating: 0, count: dim)
            for k in 0..<dim { center[k] = cosTheta * centers[0][k] + sinTheta * orth[k] }
            centers.append(normalizeFloats(center))
            continue
        }
        var candidate = prng.unitVector(dim: dim)
        var attempts = 0
        while attempts < 64,
            centers.contains(where: { abs(cosineFloats(candidate, $0)) > config.maxCenterCosine })
        {
            candidate = prng.unitVector(dim: dim)
            attempts += 1
        }
        // 回退保证（概率极低才会走到）：拒绝采样超限时对过近中心做正交化，
        // 使 |cos| ≤ maxCenterCosine 恒成立，而不是静默接受一个过近的中心。
        let tooClose = centers.filter { abs(cosineFloats(candidate, $0)) > config.maxCenterCosine }
        if !tooClose.isEmpty {
            candidate = orthogonalDirection(basis: tooClose, prng: &prng, dim: dim)
        }
        centers.append(candidate)
    }

    // 2) 退化方向（低质量样本用）：与所有身份中心正交（构造性，非碰运气）。
    var degradedDirection: [Float] = []
    if config.lowQuality.degradedPerIdentity > 0 {
        degradedDirection = orthogonalDirection(basis: centers, prng: &prng, dim: dim)
    }
    var poseDirections: [[Float]] = []
    if config.lowQuality.privatePosePerIdentity > 0 || config.lowQuality.correctPosePerIdentity > 0 {
        for _ in 0..<config.identityCount {
            poseDirections.append(
                orthogonalDirection(basis: centers + poseDirections, prng: &prng, dim: dim))
        }
    }

    // 3) 样本：身份优先序（高质量 → 共享退化 → 本人退化 → 本人方向低质量）。
    let identityIds = (0..<config.identityCount).map { "\(config.identityPrefix)\($0)" }
    var samples: [SyntheticFaceSample] = []
    func append(identity: Int, embedding: [Float], quality: Double, isHighQuality: Bool) {
        samples.append(
            SyntheticFaceSample(
                index: samples.count,
                identityIndex: identity,
                identityId: identityIds[identity],
                embedding: embedding,
                quality: quality,
                isHighQuality: isHighQuality))
    }
    for identity in 0..<config.identityCount {
        for _ in 0..<config.highQualityPerIdentity {
            let noise = prng.unitVector(dim: dim)
            var value = [Float](repeating: 0, count: dim)
            for k in 0..<dim {
                value[k] = centers[identity][k] + Float(config.intraNoise) * noise[k]
            }
            append(
                identity: identity, embedding: normalizeFloats(value), quality: 1.0,
                isHighQuality: true)
        }
        for _ in 0..<config.lowQuality.degradedPerIdentity {
            let residual = prng.unitVector(dim: dim)
            var value = [Float](repeating: 0, count: dim)
            for k in 0..<dim {
                value[k] =
                    Float(config.lowQuality.directionWeight) * degradedDirection[k]
                    + Float(config.lowQuality.residualNoise) * residual[k]
            }
            append(
                identity: identity, embedding: normalizeFloats(value),
                quality: config.lowQuality.quality, isHighQuality: false)
        }
        for _ in 0..<config.lowQuality.privatePosePerIdentity {
            let residual = prng.unitVector(dim: dim)
            var value = [Float](repeating: 0, count: dim)
            for k in 0..<dim {
                value[k] =
                    Float(config.lowQuality.directionWeight) * poseDirections[identity][k]
                    + Float(config.lowQuality.residualNoise) * residual[k]
            }
            append(
                identity: identity, embedding: normalizeFloats(value),
                quality: config.lowQuality.quality, isHighQuality: false)
        }
        for _ in 0..<config.lowQuality.correctPosePerIdentity {
            let residual = prng.unitVector(dim: dim)
            var value = [Float](repeating: 0, count: dim)
            for k in 0..<dim {
                value[k] =
                    centers[identity][k]
                    + Float(config.lowQuality.correctPoseWeight) * poseDirections[identity][k]
                    + Float(config.lowQuality.correctPoseNoise) * residual[k]
            }
            append(
                identity: identity, embedding: normalizeFloats(value),
                quality: config.lowQuality.quality, isHighQuality: false)
        }
    }

    return SyntheticFaceDataset(
        dim: dim, identityIds: identityIds, centers: centers, samples: samples)
}

/// 从既有身份中心生成留出查询样本（同一分布、独立 seed ⇒ 与库样本不重叠）。
func makeQuerySamples(
    centers: [[Float]], identityIndices: [Int], perIdentity: Int, noise: Double, seed: UInt64
) -> [(identityIndex: Int, embedding: [Float])] {
    var prng = AccuracyPRNG(seed: seed)
    var queries: [(identityIndex: Int, embedding: [Float])] = []
    for identity in identityIndices {
        let center = centers[identity]
        for _ in 0..<perIdentity {
            let direction = prng.unitVector(dim: center.count)
            var value = [Float](repeating: 0, count: center.count)
            for k in 0..<value.count {
                value[k] = center[k] + Float(noise) * direction[k]
            }
            queries.append((identity, normalizeFloats(value)))
        }
    }
    return queries
}

// MARK: - 指标（自实现，无第三方）

/// 聚类质量指标。全部按「noise 点 = 单点簇」口径计算。
private struct ClusteringMetrics: Equatable {
    let pointCount: Int
    let predictedClusterCount: Int
    let noiseCount: Int
    /// 簇级 precision（纯度）= Σ_C max_g |C∩g| / n（C 遍历预测簇含单点簇，g 为真实身份）。
    let clusterPrecision: Double
    /// 簇级 recall（覆盖，纯度的对称量）= Σ_g max_C |C∩g| / n。
    let clusterRecall: Double
    /// pairwise：TP = 同身份且同簇的点对；FP = 不同身份且同簇；FN = 同身份且不同簇。
    let pairPrecision: Double
    let pairRecall: Double
    let pairF1: Double
    let truePositivePairs: Int
    /// 误聚对数（跨身份同簇点对）= FP。
    let falsePositivePairs: Int
    let falseNegativePairs: Int
    /// 调整兰德指数（Hubert–Arabie 1983，列联表写法；与配对计数写法交叉验证）。
    let adjustedRandIndex: Double

    /// noise 率：丢弃/降级样本越多 F1 越容易虚高，任何 F1 结论必须与本值并读。
    var noiseRate: Double {
        pointCount == 0 ? 0 : Double(noiseCount) / Double(pointCount)
    }

    var summaryLine: String {
        String(
            format:
                "簇数=%d 簇级 P=%.4f R=%.4f | pairwise P=%.4f R=%.4f F1=%.4f | ARI=%.4f | 误聚对=%d (TP=%d FN=%d) | noise=%d(%.1f%%)",
            predictedClusterCount, clusterPrecision, clusterRecall, pairPrecision, pairRecall,
            pairF1, adjustedRandIndex, falsePositivePairs, truePositivePairs, falseNegativePairs,
            noiseCount, noiseRate * 100)
    }
}

private func comb2(_ k: Int) -> Int { k < 2 ? 0 : k * (k - 1) / 2 }

private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
}

/// 预测划分（noise 点 = 单点簇，按传入顺序编号）。
private func predictionLabels(clusters: [[Int]], noise: [Int], count: Int) -> [Int] {
    var prediction = [Int](repeating: -1, count: count)
    var clusterIndex = 0
    for cluster in clusters {
        for point in cluster { prediction[point] = clusterIndex }
        clusterIndex += 1
    }
    for point in noise {
        prediction[point] = clusterIndex
        clusterIndex += 1
    }
    precondition(
        prediction.allSatisfy { $0 >= 0 },
        "聚类结果必须覆盖每个点（noise 点按单点簇处理，不得丢弃）")
    return prediction
}

/// 列联表 n_ij（预测簇 i × 真实身份 j）。
private struct ContingencyTable {
    let pointCount: Int
    /// 预测簇下标 → 真实身份 → n_ij。
    let joint: [Int: [Int: Int]]

    init(trueLabels: [Int], predicted: [Int]) {
        precondition(trueLabels.count == predicted.count)
        pointCount = trueLabels.count
        var table: [Int: [Int: Int]] = [:]
        for point in 0..<pointCount {
            table[predicted[point], default: [:]][trueLabels[point], default: 0] += 1
        }
        joint = table
    }

    /// Σ_ij C(n_ij,2)：两侧同组的对数（ARI 分子里的观测一致量）。
    var sumJointPairs: Int {
        joint.values.reduce(0) { total, byTruth in
            total + byTruth.values.reduce(0) { $0 + comb2($1) }
        }
    }
    /// Σ_j C(b_j,2)：仅预测侧同组的对数。
    var sumPredictedPairs: Int {
        joint.values.reduce(0) { $0 + comb2($1.values.reduce(0, +)) }
    }
    /// Σ_i C(a_i,2)：仅真实侧同组的对数。
    var sumTruthPairs: Int {
        var byTruth: [Int: Int] = [:]
        for row in joint.values {
            for (truth, count) in row { byTruth[truth, default: 0] += count }
        }
        return byTruth.values.reduce(0) { $0 + comb2($1) }
    }
}

/// ARI（Hubert–Arabie 1983）——「列联表 + 期望值」写法：
///   ARI = (Σ_ij C(n_ij,2) − E) / (M − E)
///   E = Σ_i C(a_i,2)·Σ_j C(b_j,2) / C(n,2)（随机划分下的一致对期望）
///   M = (Σ_i C(a_i,2) + Σ_j C(b_j,2)) / 2（一致对的最大值）
///   其中 n_ij = 同属真实身份 i 与预测簇 j 的点数，a_i / b_j 为两侧组大小。
///   分母为 0（两侧都退化成全同或全异）时按惯例取 1。
private func adjustedRandIndexByContingency(trueLabels: [Int], predicted: [Int]) -> Double {
    let table = ContingencyTable(trueLabels: trueLabels, predicted: predicted)
    let totalPairs = comb2(table.pointCount)
    guard totalPairs > 0 else { return 1 }
    let expected =
        Double(table.sumTruthPairs) * Double(table.sumPredictedPairs) / Double(totalPairs)
    let maximum = Double(table.sumTruthPairs + table.sumPredictedPairs) / 2
    let denominator = maximum - expected
    return denominator == 0 ? 1 : (Double(table.sumJointPairs) - expected) / denominator
}

/// ARI——「配对计数」写法（独立于列联表结构：直接遍历所有点对分类）：
///   ARI = [T(a+d) − ((a+b)(a+c) + (b+d)(c+d))] / [T² − ((a+b)(a+c) + (b+d)(c+d))]
///   其中 T = C(n,2)，a = 两侧同组、b = 仅预测同组、c = 仅真值同组、d = 两侧都不同组。
///   与列联表写法在数学上恒等（本文件用手算小例与合成集断言两者逐位接近）。
private func adjustedRandIndexByPairCounting(trueLabels: [Int], predicted: [Int]) -> Double {
    let n = trueLabels.count
    precondition(predicted.count == n)
    var bothSame = 0
    var predictedOnlySame = 0
    var truthOnlySame = 0
    var bothDifferent = 0
    for i in 0..<n {
        for j in (i + 1)..<n {
            let sameTruth = trueLabels[i] == trueLabels[j]
            let samePrediction = predicted[i] == predicted[j]
            switch (sameTruth, samePrediction) {
            case (true, true): bothSame += 1
            case (false, true): predictedOnlySame += 1
            case (true, false): truthOnlySame += 1
            case (false, false): bothDifferent += 1
            }
        }
    }
    let totalPairs = comb2(n)
    guard totalPairs > 0 else { return 1 }
    let samePairs =
        (bothSame + predictedOnlySame) * (bothSame + truthOnlySame)
        + (predictedOnlySame + bothDifferent) * (truthOnlySame + bothDifferent)
    let denominator = totalPairs * totalPairs - samePairs
    guard denominator != 0 else { return 1 }
    return (Double(totalPairs * (bothSame + bothDifferent)) - Double(samePairs))
        / Double(denominator)
}

private func evaluateClusters(
    clusters: [[Int]], noise: [Int], trueLabels: [Int]
) -> ClusteringMetrics {
    let n = trueLabels.count
    let prediction = predictionLabels(clusters: clusters, noise: noise, count: n)
    let clusterCount = Set(prediction).count

    // 预测簇 → 真实身份 → 计数（用于纯度；ARI 由独立函数复算）。
    var clusterTruthCounts: [Int: [Int: Int]] = [:]
    // 真实身份 → 预测簇 → 计数（用于覆盖）。
    var truthClusterCounts: [Int: [Int: Int]] = [:]
    for point in 0..<n {
        clusterTruthCounts[prediction[point], default: [:]][trueLabels[point], default: 0] += 1
        truthClusterCounts[trueLabels[point], default: [:]][prediction[point], default: 0] += 1
    }
    let majoritySum = clusterTruthCounts.values.reduce(0) { $0 + ($1.values.max() ?? 0) }
    let coverageSum = truthClusterCounts.values.reduce(0) { $0 + ($1.values.max() ?? 0) }

    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    for i in 0..<n {
        for j in (i + 1)..<n {
            let sameTruth = trueLabels[i] == trueLabels[j]
            let samePrediction = prediction[i] == prediction[j]
            if sameTruth && samePrediction {
                truePositive += 1
            } else if !sameTruth && samePrediction {
                falsePositive += 1
            } else if sameTruth && !samePrediction {
                falseNegative += 1
            }
        }
    }
    let pairPrecision = ratio(truePositive, truePositive + falsePositive)
    let pairRecall = ratio(truePositive, truePositive + falseNegative)
    let pairF1 =
        pairPrecision + pairRecall > 0
        ? 2 * pairPrecision * pairRecall / (pairPrecision + pairRecall) : 0

    return ClusteringMetrics(
        pointCount: n,
        predictedClusterCount: clusterCount,
        noiseCount: noise.count,
        clusterPrecision: ratio(majoritySum, n),
        clusterRecall: ratio(coverageSum, n),
        pairPrecision: pairPrecision,
        pairRecall: pairRecall,
        pairF1: pairF1,
        truePositivePairs: truePositive,
        falsePositivePairs: falsePositive,
        falseNegativePairs: falseNegative,
        adjustedRandIndex: adjustedRandIndexByContingency(
            trueLabels: trueLabels, predicted: prediction))
}

/// 跑一次生产聚类器，把结果折成点下标（observationId = 合成样本下标）。
private func clusterSynthetic(
    _ dataset: SyntheticFaceDataset,
    eps: Double,
    minPts: Int,
    coreQualityFloor: Double,
    retryMinSamples: Int? = nil
) throws -> (clusters: [[Int]], noise: [Int]) {
    let entries = dataset.samples.map {
        EmbeddingEntry(
            observationId: $0.index,
            photoId: "photo-\($0.index)",
            embedding: $0.embedding,
            quality: $0.quality)
    }
    let result = try FaceClusterer.clusterEmbeddings(
        entries: entries,
        eps: eps,
        minPts: minPts,
        coreQualityFloor: coreQualityFloor,
        retryMinSamples: retryMinSamples)
    return (result.clusters.map { $0.map(\.observationId) }, result.noise.map(\.observationId))
}

/// 把一次聚类结果裁剪到给定点集后重新编号评估（B 组「同覆盖率」比较：只看两侧
/// 共同成簇的点；点下标重映射，真值标签同步裁剪，保证 noise=单点簇口径不变）。
private func evaluateRestricted(
    _ result: (clusters: [[Int]], noise: [Int]), to points: Set<Int>, trueLabels: [Int]
) -> ClusteringMetrics {
    let ordered = points.sorted()
    var remap: [Int: Int] = [:]
    for (newIndex, oldIndex) in ordered.enumerated() { remap[oldIndex] = newIndex }
    let clusters = result.clusters.map { cluster in cluster.compactMap { remap[$0] } }
        .filter { !$0.isEmpty }
    let noise = result.noise.compactMap { remap[$0] }
    return evaluateClusters(
        clusters: clusters, noise: noise, trueLabels: ordered.map { trueLabels[$0] })
}

/// 某点所在预测簇（noise 点返回 nil）。
private func clusterContaining(
    _ point: Int, in prediction: (clusters: [[Int]], noise: [Int])
) -> [Int]? {
    prediction.clusters.first { $0.contains(point) }
}

/// 该点所在簇是否含其它身份的点（跨身份误聚检查；noise 点返回 false）。
private func sharesClusterWithOtherIdentity(
    point: Int, prediction: (clusters: [[Int]], noise: [Int]), labels: [Int]
) -> Bool {
    guard let cluster = clusterContaining(point, in: prediction) else { return false }
    return cluster.contains { labels[$0] != labels[point] }
}

/// 含指定身份点的预测簇个数。
private func clusterCount(
    containingIdentity identity: Int, prediction: (clusters: [[Int]], noise: [Int]), labels: [Int]
) -> Int {
    prediction.clusters.filter { cluster in cluster.contains { labels[$0] == identity } }.count
}

// MARK: - 打印工具（供人工记录基线表）

private func displayWidth(_ text: String) -> Int {
    var width = 0
    for scalar in text.unicodeScalars { width += scalar.value >= 0x1100 ? 2 : 1 }
    return width
}

private func pad(_ text: String, to width: Int) -> String {
    let padding = width - displayWidth(text)
    return padding > 0 ? text + String(repeating: " ", count: padding) : text
}

private func tableRow(_ cells: [String], widths: [Int]) -> String {
    zip(cells, widths).map { pad($0, to: $1) }.joined(separator: " | ")
}

// MARK: - 测试

struct FaceClusteringAccuracyTests {
    // 固定参数（全部为常量，测试间无共享可变状态）。
    private static let cleanConfig = SyntheticDatasetConfig(
        seed: 20_260_928,
        dim: 24,
        identityCount: 8,
        highQualityPerIdentity: 8,
        intraNoise: 0.25,
        maxCenterCosine: 0.35)

    private static let qualityConfig: SyntheticDatasetConfig = {
        var config = SyntheticDatasetConfig(
            seed: 20_260_929,
            dim: 24,
            identityCount: 6,
            highQualityPerIdentity: 6,
            intraNoise: 0.25,
            maxCenterCosine: 0.35)
        config.lowQuality = LowQualityPlan(
            degradedPerIdentity: 2,
            privatePosePerIdentity: 2,
            quality: 0.25,
            directionWeight: 0.9,
            residualNoise: 0.3)
        return config
    }()

    /// 对照①：只有「低质量但方向指向本人」的样本，没有跨身份退化样本。
    private static let correctPoseConfig: SyntheticDatasetConfig = {
        var config = SyntheticDatasetConfig(
            seed: 20_260_933,
            dim: 24,
            identityCount: 6,
            highQualityPerIdentity: 6,
            intraNoise: 0.25,
            maxCenterCosine: 0.35)
        var plan = LowQualityPlan()
        plan.correctPosePerIdentity = 2
        // 1.1 使「低质量 vs 本人高质量」余弦约 0.65（< eps 且留出 >0.15 间隔），
        // 同时仍远高于与其它身份的相似度（约 0.19）⇒ 方向确实是「指向本人」。
        plan.correctPoseWeight = 1.1
        plan.correctPoseNoise = 0.1
        plan.quality = 0.25
        config.lowQuality = plan
        return config
    }()

    private static let closePairCosine = 0.93
    private static let libraryConfig: SyntheticDatasetConfig = {
        var config = SyntheticDatasetConfig(
            seed: 20_260_930,
            dim: 24,
            identityCount: 6,
            highQualityPerIdentity: 4,
            intraNoise: 0.3,
            maxCenterCosine: 0.4)
        config.closePairCosine = closePairCosine
        return config
    }()

    private static let cleanEps = 0.8
    private static let bridgeEps = 0.72

    // MARK: 指标自检

    /// 指标实现正确性（A 组结论的唯一正当依据）：
    /// 1) 两个手算小例给出精确有理数值；
    /// 2) 两种独立 ARI 写法在合成集上与 evaluateClusters 内部值一致。
    @Test func adjustedRandIndexImplementationsAgreeWithHandComputedValues() throws {
        // 手算小例 1：n=6，truth=[0,0,1,1,2,2]，pred=[0,0,0,1,2,2]。
        // 列联表：n_00=2（其余 1/1/2 各 1，单点贡献 0）⇒ Σ_ij C(n_ij,2)=2；
        // Σ_i C(a_i,2)=3×C(2,2)=3；Σ_j C(b_j,2)=C(3,2)+C(2,2)=3+1=4；T=C(6,2)=15。
        // E=3·4/15=0.8，M=(3+4)/2=3.5 ⇒ ARI=(2−0.8)/(3.5−0.8)=4/9。
        let truthOne = [0, 0, 1, 1, 2, 2]
        let predOne = [0, 0, 0, 1, 2, 2]
        #expect(abs(adjustedRandIndexByContingency(trueLabels: truthOne, predicted: predOne) - 4.0 / 9.0) < 1e-12)
        #expect(abs(adjustedRandIndexByPairCounting(trueLabels: truthOne, predicted: predOne) - 4.0 / 9.0) < 1e-12)

        // 手算小例 2：truth=[0,0,1,1]，pred=[0,1,0,1]（与真值交叉）：
        // a=0、b=2、c=2、d=2、T=6 ⇒ ARI=(0−4/6)/(2−4/6)=−0.5（已知负值例）。
        let truthTwo = [0, 0, 1, 1]
        let predTwo = [0, 1, 0, 1]
        #expect(abs(adjustedRandIndexByContingency(trueLabels: truthTwo, predicted: predTwo) - (-0.5)) < 1e-12)
        #expect(abs(adjustedRandIndexByPairCounting(trueLabels: truthTwo, predicted: predTwo) - (-0.5)) < 1e-12)

        // 完整评估器复算手算小例 1（口径一致）：簇 [[0,1,2],[3],[4,5]]。
        let handMetrics = evaluateClusters(
            clusters: [[0, 1, 2], [3], [4, 5]], noise: [], trueLabels: truthOne)
        // 逐对手算：TP=(0,1)、(4,5)；FP=(0,2)、(1,2)；FN=(2,3) ⇒ P=2/4=1/2、R=2/3、F1=4/7。
        #expect(abs(handMetrics.pairPrecision - 1.0 / 2.0) < 1e-12)
        #expect(abs(handMetrics.pairRecall - 2.0 / 3.0) < 1e-12)
        #expect(abs(handMetrics.pairF1 - 4.0 / 7.0) < 1e-12)
        // 簇级 P = (2+1+2)/6；簇级 R = (2+1+2)/6。
        #expect(abs(handMetrics.clusterPrecision - 5.0 / 6.0) < 1e-12)
        #expect(abs(handMetrics.clusterRecall - 5.0 / 6.0) < 1e-12)
        #expect(abs(handMetrics.adjustedRandIndex - 4.0 / 9.0) < 1e-12)

        // 两种写法在真实合成集 + 两个质量门槛下的所有划分上必须一致（含 floor 后噪声划分）。
        for config in [Self.cleanConfig, Self.qualityConfig, Self.correctPoseConfig] {
            let dataset = makeSyntheticDataset(config)
            let labels = dataset.samples.map(\.identityIndex)
            for floor in [0.0, 0.5] {
                let prediction = try clusterSynthetic(
                    dataset, eps: Self.cleanEps, minPts: 2, coreQualityFloor: floor)
                let predicted = predictionLabels(
                    clusters: prediction.clusters, noise: prediction.noise, count: dataset.size)
                let byContingency = adjustedRandIndexByContingency(
                    trueLabels: labels, predicted: predicted)
                let byPairCounting = adjustedRandIndexByPairCounting(
                    trueLabels: labels, predicted: predicted)
                #expect(
                    abs(byContingency - byPairCounting) < 1e-9,
                    "两种等价 ARI 写法必须一致（config seed=\(config.seed) floor=\(floor)）")
                let metrics = evaluateClusters(
                    clusters: prediction.clusters, noise: prediction.noise, trueLabels: labels)
                #expect(abs(metrics.adjustedRandIndex - byContingency) < 1e-12)
            }
        }
    }

    // MARK: A 组

    private struct CleanSetResult {
        let datasetSize: Int
        let identityCount: Int
        let eps: Double
        let minIntraCosine: Double
        let maxInterCosine: Double
        let metrics: ClusteringMetrics
    }

    private static func runCleanSet() throws -> CleanSetResult {
        let dataset = makeSyntheticDataset(cleanConfig)
        let prediction = try clusterSynthetic(
            dataset, eps: cleanEps, minPts: 2, coreQualityFloor: 0)
        let separation = dataset.highQualitySeparation()
        return CleanSetResult(
            datasetSize: dataset.size,
            identityCount: dataset.identityCount,
            eps: cleanEps,
            minIntraCosine: separation.minIntra,
            maxInterCosine: separation.maxInter,
            metrics: evaluateClusters(
                clusters: prediction.clusters, noise: prediction.noise,
                trueLabels: dataset.samples.map(\.identityIndex)))
    }

    // MARK: B 组

    private struct QualityFloorResult {
        let datasetSize: Int
        let identityCount: Int
        let lowQualityCount: Int
        let eps: Double
        let ungated: ClusteringMetrics  // coreQualityFloor = 0
        let gated: ClusteringMetrics  // coreQualityFloor = 0.5
        let retried: ClusteringMetrics  // coreQualityFloor = 0.5 + retryMinSamples = 2
        /// B2 的决策覆盖率（成簇点/全部点）。
        let gatedCoverage: Double
        /// 同覆盖率比较：两侧都裁剪到 B2 成簇点集后的指标。
        let ungatedAtGatedCoverage: ClusteringMetrics
        let gatedAtGatedCoverage: ClusteringMetrics
    }

    private static func runQualityFloor() throws -> QualityFloorResult {
        let dataset = makeSyntheticDataset(qualityConfig)
        let truth = dataset.samples.map(\.identityIndex)
        let eps = cleanEps
        let ungated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0)
        let gated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0.5)
        let retried = try clusterSynthetic(
            dataset, eps: eps, minPts: 2, coreQualityFloor: 0.5, retryMinSamples: 2)
        let gatedClustered = Set(gated.clusters.flatMap { $0 })
        let gatedCoverage = dataset.size == 0 ? 0 : Double(gatedClustered.count) / Double(dataset.size)
        let ungatedAtGatedCoverage = evaluateRestricted(
            ungated, to: gatedClustered, trueLabels: truth)
        let gatedAtGatedCoverage = evaluateRestricted(
            gated, to: gatedClustered, trueLabels: truth)
        return QualityFloorResult(
            datasetSize: dataset.size,
            identityCount: dataset.identityCount,
            lowQualityCount: dataset.lowQualityCount,
            eps: eps,
            ungated: evaluateClusters(
                clusters: ungated.clusters, noise: ungated.noise, trueLabels: truth),
            gated: evaluateClusters(clusters: gated.clusters, noise: gated.noise, trueLabels: truth),
            retried: evaluateClusters(
                clusters: retried.clusters, noise: retried.noise, trueLabels: truth),
            gatedCoverage: gatedCoverage,
            ungatedAtGatedCoverage: ungatedAtGatedCoverage,
            gatedAtGatedCoverage: gatedAtGatedCoverage)
    }

    // MARK: 对照①（低质量但方向正确）

    private struct CorrectPoseResult {
        let datasetSize: Int
        let identityCount: Int
        let lowQualityCount: Int
        let eps: Double
        /// 低质量样本与其本人高质量样本的最大余弦（须 < eps：否则会被吸收，"少成簇"的代价无从测量）。
        let maxSimilarityToOwnHighQuality: Double
        /// 同身份两张低质量样本的最小余弦（须 ≥ eps：floor=0 时它们自成同人小簇）。
        let minSimilarityWithinLowQualityPair: Double
        let ungated: ClusteringMetrics
        let gated: ClusteringMetrics
        let ungatedNoise: Int
        let gatedNoise: Int
        /// 低质量样本中与其它身份同簇的个数（必须为 0）。
        let ungatedCrossIdentity: Int
        let gatedCrossIdentity: Int
    }

    private static func runCorrectPose() throws -> CorrectPoseResult {
        let dataset = makeSyntheticDataset(correctPoseConfig)
        let labels = dataset.samples.map(\.identityIndex)
        let eps = cleanEps
        let lowQualityIndices = dataset.samples.filter { !$0.isHighQuality }.map(\.index)
        let highQualityIndices = Set(dataset.samples.filter(\.isHighQuality).map(\.index))

        var maxToOwnHigh = -Double.infinity
        var minWithinLow = Double.infinity
        for index in lowQualityIndices {
            let sample = dataset.samples[index]
            for other in dataset.samples
            where highQualityIndices.contains(other.index)
                && other.identityIndex == sample.identityIndex
            {
                maxToOwnHigh = max(maxToOwnHigh, cosineFloats(sample.embedding, other.embedding))
            }
            for other in dataset.samples
            where lowQualityIndices.contains(other.index) && other.index > index
                && other.identityIndex == sample.identityIndex
            {
                minWithinLow = min(minWithinLow, cosineFloats(sample.embedding, other.embedding))
            }
        }

        let ungated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0)
        let gated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0.5)
        return CorrectPoseResult(
            datasetSize: dataset.size,
            identityCount: dataset.identityCount,
            lowQualityCount: lowQualityIndices.count,
            eps: eps,
            maxSimilarityToOwnHighQuality: maxToOwnHigh,
            minSimilarityWithinLowQualityPair: minWithinLow,
            ungated: evaluateClusters(
                clusters: ungated.clusters, noise: ungated.noise, trueLabels: labels),
            gated: evaluateClusters(clusters: gated.clusters, noise: gated.noise, trueLabels: labels),
            ungatedNoise: ungated.noise.count,
            gatedNoise: gated.noise.count,
            ungatedCrossIdentity: lowQualityIndices.filter {
                sharesClusterWithOtherIdentity(point: $0, prediction: ungated, labels: labels)
            }.count,
            gatedCrossIdentity: lowQualityIndices.filter {
                sharesClusterWithOtherIdentity(point: $0, prediction: gated, labels: labels)
            }.count)
    }

    // MARK: 对照②（低质量桥接点）

    private struct BridgeDatasetResult {
        let dataset: SyntheticFaceDataset
        let bridgeIndex: Int
        let subclusterA: [Int]
        let subclusterB: [Int]
    }

    /// 同一身份两个高质量子簇 + 1 张低质量桥接点；另有 1 个无关身份（4 张）。
    /// 构造：c0/c1 近似正交、axis ⟂ {c0,c1}；A = normalize(c0 + w·axis + 噪声)、
    /// B = normalize(c0 − w·axis + 噪声)、桥接点 = c0。
    private static func makeBridgeDataset(
        seed: UInt64, dim: Int, subclusterSize: Int, offsetWeight: Double, memberNoise: Double,
        bridgeQuality: Double
    ) -> BridgeDatasetResult {
        var prng = AccuracyPRNG(seed: seed)
        let c0 = prng.unitVector(dim: dim)
        let c1 = orthogonalDirection(basis: [c0], prng: &prng, dim: dim)
        let axis = orthogonalDirection(basis: [c0, c1], prng: &prng, dim: dim)

        func member(of center: [Float], sign: Double) -> [Float] {
            let noise = prng.unitVector(dim: dim)
            var value = [Float](repeating: 0, count: dim)
            for k in 0..<dim {
                value[k] =
                    center[k] + Float(sign * offsetWeight) * axis[k] + Float(memberNoise) * noise[k]
            }
            return normalizeFloats(value)
        }

        let identityIds = ["bridgeA", "bridgeB"]
        var samples: [SyntheticFaceSample] = []
        func append(identity: Int, embedding: [Float], quality: Double, isHighQuality: Bool) {
            samples.append(
                SyntheticFaceSample(
                    index: samples.count, identityIndex: identity, identityId: identityIds[identity],
                    embedding: embedding, quality: quality, isHighQuality: isHighQuality))
        }
        var subclusterA: [Int] = []
        for _ in 0..<subclusterSize {
            subclusterA.append(samples.count)
            append(identity: 0, embedding: member(of: c0, sign: 1), quality: 1, isHighQuality: true)
        }
        var subclusterB: [Int] = []
        for _ in 0..<subclusterSize {
            subclusterB.append(samples.count)
            append(identity: 0, embedding: member(of: c0, sign: -1), quality: 1, isHighQuality: true)
        }
        let bridgeIndex = samples.count
        append(identity: 0, embedding: c0, quality: bridgeQuality, isHighQuality: false)
        for _ in 0..<subclusterSize {
            append(identity: 1, embedding: member(of: c1, sign: 1), quality: 1, isHighQuality: true)
        }
        return BridgeDatasetResult(
            dataset: SyntheticFaceDataset(
                dim: dim, identityIds: identityIds, centers: [c0, c1], samples: samples),
            bridgeIndex: bridgeIndex, subclusterA: subclusterA, subclusterB: subclusterB)
    }

    private struct BridgeResult {
        let datasetSize: Int
        let eps: Double
        let bridgeQuality: Double
        let minBridgeToSideMemberCosine: Double
        let maxAcrossSubclusterCosine: Double
        let ungatedIdentityZeroClusters: Int
        let gatedIdentityZeroClusters: Int
        let ungated: ClusteringMetrics
        let gated: ClusteringMetrics
    }

    private static func runBridge() throws -> BridgeResult {
        let built = makeBridgeDataset(
            seed: 20_260_934, dim: 24, subclusterSize: 4, offsetWeight: 0.8, memberNoise: 0.03,
            bridgeQuality: 0.2)
        let dataset = built.dataset
        let labels = dataset.samples.map(\.identityIndex)
        let bridge = dataset.samples[built.bridgeIndex]
        let eps = bridgeEps

        let sideIndices = built.subclusterA + built.subclusterB
        let minBridge = sideIndices.map {
            cosineFloats(bridge.embedding, dataset.samples[$0].embedding)
        }.min() ?? 0
        var maxAcross = -Double.infinity
        for a in built.subclusterA {
            for b in built.subclusterB {
                maxAcross = max(maxAcross, cosineFloats(dataset.samples[a].embedding, dataset.samples[b].embedding))
            }
        }

        let ungated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0)
        let gated = try clusterSynthetic(dataset, eps: eps, minPts: 2, coreQualityFloor: 0.5)
        return BridgeResult(
            datasetSize: dataset.size,
            eps: eps,
            bridgeQuality: built.dataset.samples[built.bridgeIndex].quality,
            minBridgeToSideMemberCosine: minBridge,
            maxAcrossSubclusterCosine: maxAcross,
            ungatedIdentityZeroClusters: clusterCount(
                containingIdentity: 0, prediction: ungated, labels: labels),
            gatedIdentityZeroClusters: clusterCount(
                containingIdentity: 0, prediction: gated, labels: labels),
            ungated: evaluateClusters(
                clusters: ungated.clusters, noise: ungated.noise, trueLabels: labels),
            gated: evaluateClusters(clusters: gated.clusters, noise: gated.noise, trueLabels: labels))
    }

    // MARK: - A 干净集：生成器自检（不构成证据）

    // A：本组只做两件自检——(1) 生成器满足「类内最小余弦 > eps > 类间最大余弦」这一
    // 分离度前提；(2) 前提成立时聚类器 + 指标实现给出与前提一致的结果（一致性对账）。
    //
    // 为什么不能当性能证据：前提本身直接蕴含「同身份样本必连通、跨身份样本必不连通」，
    // 在 minPts=2 下「划分 = 真值」是代数后果。除 intraNoise 之外没有输入能让这里的
    // F1/ARI 断言失败；这些数字只说明代码没坏，不说明聚类在真实分布上有多准。
    // 有信息量的对照见 B 组 / ①②。
    @Test func cleanSetIsGeneratorSelfCheckOnly() throws {
        let result = try Self.runCleanSet()
        print(
            """
            [A 干净集·生成器自检（不是性能证据）] 规模 \(result.datasetSize) embeddings（\(result.identityCount) 身份 × 8 样本, d=24）
              参数: eps=\(result.eps) minPts=2 coreQualityFloor=0（质量门槛关闭）
              分离度前提: 类内最小余弦=\(String(format: "%.4f", result.minIntraCosine)) 类间最大余弦=\(String(format: "%.4f", result.maxInterCosine)) gap=\(String(format: "%.4f", result.minIntraCosine - result.maxInterCosine))
              \(result.metrics.summaryLine)
              注: 本组仅验证「前提成立 ⇒ 一致结果」，不得引用为 F1/ARI 性能基线。
            """)

        // 前提检查：改坏构造（如 intraNoise 调大）应立即失败。
        #expect(result.minIntraCosine > result.eps + 0.05, "生成器前提：类内最小余弦须高于 eps")
        #expect(result.maxInterCosine < result.eps - 0.05, "生成器前提：类间最大余弦须低于 eps")
        // 一致性对账（由前提 + minPts=2 可推导，非性能断言）。
        #expect(result.metrics.falsePositivePairs == 0, "前提一致：干净集不得有跨身份误聚")
        #expect(result.metrics.pairF1 == 1.0, "前提一致：划分应为真值")
        #expect(result.metrics.adjustedRandIndex == 1.0, "前提一致：修正后的 ARI 应为 1.0")
        #expect(result.metrics.noiseCount == 0, "前提一致：干净集不应有 noise")
    }

    // MARK: - B 质量门槛

    // B：含低质量样本（跨身份共享退化方向 + 本人专属退化方向 + 本人方向正确但低质量）时，
    //    coreQualityFloor=0.5 相对 0 的价值。同节并列 noise 率与同覆盖率比较：
    //    floor=0.5 的 F1 更高，一部分来自「把 24/60 个难样本丢进 noise」；因此下面同时
    //    报告 noise 率，并把两侧裁剪到 B2 成簇点集（同覆盖率 60%）后再比一次 F1。
    // 证伪条件：对照组必须真的出现跨身份误聚（否则本组没测到东西）。
    @Test func coreQualityFloorSuppressesLowQualityFalseMerges() throws {
        let result = try Self.runQualityFloor()
        print(
            """
            [B 含低质量样本] 规模 \(result.datasetSize) embeddings（\(result.identityCount) 身份 × 6 高质量 + 每身份 2 共享退化 + 2 本人退化；低质量共 \(result.lowQualityCount) 条, quality=0.25）
              参数: eps=\(result.eps) minPts=2
              floor=0         : \(result.ungated.summaryLine)
              floor=0.5       : \(result.gated.summaryLine)
              floor=0.5+retry2: \(result.retried.summaryLine)
              同覆盖率比较（两侧都只看 B2 成簇点集, 覆盖率=\(String(format: "%.1f%%", result.gatedCoverage * 100))）:
                floor=0   : \(result.ungatedAtGatedCoverage.summaryLine)
                floor=0.5 : \(result.gatedAtGatedCoverage.summaryLine)
              注 1: ARI 公式已修正为 Σ_ij C(n_ij,2)（列联表联合项）。修正后 floor=0.5 的 ARI 上升，
                    而非旧实现（误用 Σ_j C(b_j,2)）的下降。
              注 2: ARI 对单点噪声簇敏感（noise 按单点簇计入 ⇒ 噪声越多 ARI 越低，即便 precision
                    完美）；故任何 ARI 结论必须与 noise 率并读。
              注 3: B3（floor=0.5+retry=2）与 B2 逐位相同：retryMinSamples=2 与首遍 minPts=2 判据
                    相同、且不合格点在第二遍仍不合格 ⇒ 第二遍无可恢复簇。这是 API 语义的必然结果，
                    仅作回归护栏，不是性能证据。
            """)

        #expect(result.ungated.falsePositivePairs > 0, "对照组必须真的出现跨身份误聚（本组证伪条件）")
        #expect(result.ungated.noiseCount == 0, "对照组低质量点全部入簇——否则误聚无从发生")
        #expect(
            result.gated.falsePositivePairs == 0,
            "floor=0.5 后低质量点不得当核心点 ⇒ 共享退化簇不再形成，跨身份误聚清零")
        #expect(
            result.gated.pairPrecision > result.ungated.pairPrecision,
            "pairwise precision 必须不降（本数据严格上升）")
        let recallDrop = result.ungated.pairRecall - result.gated.pairRecall
        #expect(recallDrop >= 0, "召回不应上升（质量门槛只可能收紧）")
        // 结构性上界：唯一丢失的同人对是 6 个身份 ×（1 对退化 + 1 对侧倾）= 12 对，
        // 12 / (C(10,2)×6) = 12/270 ≈ 0.0444；留 0.05 余量。
        #expect(recallDrop <= 0.05, "召回下降须可控（结构性上界 12/270≈0.0444）")
        #expect(
            result.gated.noiseCount == result.lowQualityCount,
            "低质量点只是不能当核心点，必须保留在 noise 而不是被丢弃")
        #expect(
            result.retried == result.gated,
            "retry=2 与首遍 minPts=2 同判据 ⇒ 第二遍必为空；这里仅断言 API 不变性（回归护栏）")
        // 修正后的 ARI：清除跨身份误聚应体现为上升（旧 buggy 公式给出相反方向）。
        #expect(
            result.gated.adjustedRandIndex > result.ungated.adjustedRandIndex,
            "修正 ARI 后 floor=0.5 应高于 floor=0（跨身份误聚被清除）")
        // 数值护栏（打印表里的 ARI 列原先只打印、无断言，会静默漂移）：钉住本次合成集的
        // 基线值，容差 1e-3，与 printsBaselineTable 的 B1/B2 行同源。
        //   推导：ARI = (Σ_ij C(n_ij,2) − E)/(M − E)，n_ij 由固定布局唯一确定——
        //   B1（floor=0）60 点 / 13 簇 / noise=0 / 60 个跨身份误聚对  → 0.4040
        //   B2（floor=0.5）60 点 / 30 簇 / noise=24（单点簇）        → 0.4587
        #expect(abs(result.ungated.adjustedRandIndex - 0.4040) < 1e-3, "B1 ARI 基线 0.4040")
        #expect(abs(result.gated.adjustedRandIndex - 0.4587) < 1e-3, "B2 ARI 基线 0.4587")
        #expect(result.ungated.adjustedRandIndex < 0.5, "B1 含跨身份误聚，ARI 必须明显低于 0.5")
        // 同覆盖率比较：B1 的 F1 优势不得来自「把点丢进 noise」；裁剪到共同成簇点集后两者应一致。
        #expect(
            abs(result.ungatedAtGatedCoverage.pairF1 - result.gatedAtGatedCoverage.pairF1) < 1e-12,
            "同覆盖率下（只看共同成簇点）两者 F1 应相同：B1 的额外覆盖全部来自跨身份误聚点")
        #expect(result.ungatedAtGatedCoverage.falsePositivePairs == 0)
    }

    // MARK: - 对照① 低质量但方向正确

    // 对照①：质量 < 门槛但向量靠近本人中心（构造前提：与本人高质量簇相似度 < eps、
    // 同身份低质量样本之间 ≥ eps）。断言 floor 提高后这些脸「不被误杀」：
    // 要么被吸收进同人簇、要么留在 noise，但**不得跨身份误聚**；即 floor 的代价是
    // 「少成簇」（noise 率上升、同人召回下降），不是「错聚」。
    @Test func lowQualityCorrectPoseFacesAreNotMergedAcrossIdentitiesWhenFloorRises() throws {
        let result = try Self.runCorrectPose()
        print(
            """
            [① 低质量但方向正确] 规模 \(result.datasetSize) embeddings（\(result.identityCount) 身份 × 6 高质量 + 每身份 2 低质量方向正确；低质量共 \(result.lowQualityCount) 条, quality=0.25）
              参数: eps=\(result.eps) minPts=2
              构造前提: max cos(低质量, 本人高质量)=\(String(format: "%.4f", result.maxSimilarityToOwnHighQuality))（须 < eps，否则会被吸收，代价无从测量）
                        min cos(同身份低质量样本对)=\(String(format: "%.4f", result.minSimilarityWithinLowQualityPair))（须 ≥ eps，floor=0 时自成同人小簇）
              floor=0   : \(result.ungated.summaryLine) | 低质量跨身份误聚=\(result.ungatedCrossIdentity)
              floor=0.5 : \(result.gated.summaryLine) | 低质量跨身份误聚=\(result.gatedCrossIdentity)
              注: floor=0.5 后低质量点进 noise（少成簇）而非错聚；本组数字只对本合成观测集成立。
            """)

        #expect(
            result.maxSimilarityToOwnHighQuality < result.eps - 0.02,
            "构造前提：方向正确的低质量样本与本人高质量簇相似度必须低于 eps")
        #expect(
            result.minSimilarityWithinLowQualityPair >= result.eps + 0.02,
            "构造前提：同身份低质量样本之间必须 ≥ eps（floor=0 时自成小簇）")
        // 核心断言：提高 floor 不得把「方向正确但质量低」的脸错聚到别人身上。
        #expect(result.gatedCrossIdentity == 0, "floor=0.5：低质量样本不得与其它身份同簇")
        #expect(result.ungatedCrossIdentity == 0, "floor=0：低质量样本不得与其它身份同簇")
        #expect(result.gated.falsePositivePairs == 0, "floor=0.5 不得有跨身份误聚")
        #expect(result.ungated.falsePositivePairs == 0, "floor=0 不得有跨身份误聚")
        // 代价口径：门槛提高 ⇒ noise 变多、成簇变少（而不是错聚变少）。
        #expect(result.ungatedNoise == 0, "floor=0 时低质量点自成同人小簇，不入 noise")
        #expect(result.gatedNoise == result.lowQualityCount, "floor=0.5 时这些脸只能留在 noise")
        #expect(result.gated.noiseRate > result.ungated.noiseRate, "noise 率必须上升（这就是代价）")
        #expect(
            result.gated.pairRecall < result.ungated.pairRecall,
            "同人召回必须下降——门槛的代价是少成簇")
    }

    // MARK: - 对照② 低质量桥接点

    // 对照②：同一身份两个高质量子簇（各 4 张）由 1 张低质量脸桥接（构造前提：
    // 桥接点与两侧成员 ≥ eps、两侧成员彼此 < eps）。floor=0 时桥接点是核心点 ⇒ 两侧
    // 连通成 1 簇；floor=0.5 时被降级 ⇒ 两侧分裂，量化真实同人召回的损失（不是构造常数：
    // 取决于桥接点是否被吸收为边界点，由聚类器实际行为决定）。
    @Test func lowQualityBridgeDemotedByFloorSplitsSameIdentitySubclusters() throws {
        let result = try Self.runBridge()
        let lostPairs = result.gated.falseNegativePairs - result.ungated.falseNegativePairs
        print(
            """
            [② 低质量桥接点] 规模 \(result.datasetSize) embeddings（同人 4+4 高质量子簇 + 1 桥接点 quality=\(result.bridgeQuality) + 1 无关身份 × 4）
              参数: eps=\(result.eps) minPts=2
              构造前提: min cos(桥接点, 两侧成员)=\(String(format: "%.4f", result.minBridgeToSideMemberCosine))（须 ≥ eps+0.03）
                        max cos(两侧子簇成员)=\(String(format: "%.4f", result.maxAcrossSubclusterCosine))（须 ≤ eps−0.03）
              floor=0   : 同人簇数=\(result.ungatedIdentityZeroClusters) \(result.ungated.summaryLine)
              floor=0.5 : 同人簇数=\(result.gatedIdentityZeroClusters) \(result.gated.summaryLine)
              桥接点被降级后：同人对多丢 \(lostPairs) 对（pairRecall \(String(format: "%.4f", result.ungated.pairRecall)) → \(String(format: "%.4f", result.gated.pairRecall))），跨身份误聚仍为 \(result.gated.falsePositivePairs)
              注: 这与「丢样本」无关（桥接点仍在 noise/边界，未被丢弃）；代价来自同人链断裂。仅对本合成观测集成立。
            """)

        #expect(
            result.minBridgeToSideMemberCosine >= result.eps + 0.03,
            "构造前提：桥接点必须同时满足两侧 eps")
        #expect(
            result.maxAcrossSubclusterCosine <= result.eps - 0.03,
            "构造前提：两侧子簇不得直接相连（分裂只能由桥接点降级造成）")
        // 实质结论：floor=0 连通成 1 簇；floor=0.5 桥接点降级 ⇒ 同人分裂。
        #expect(result.ungatedIdentityZeroClusters == 1, "floor=0：桥接点是核心点，同人两侧连通成 1 簇")
        #expect(result.gatedIdentityZeroClusters >= 2, "floor=0.5：桥接点被降级，同人两侧分裂")
        #expect(result.ungated.falsePositivePairs == 0, "floor=0 不得有跨身份误聚")
        #expect(result.gated.falsePositivePairs == 0, "floor=0.5 不得有跨身份误聚（分裂不等于错聚）")
        #expect(lostPairs >= 16, "至少丢失两子簇之间的 4×4=16 对同人对（分裂的真实召回代价）")
        #expect(result.gated.pairRecall < result.ungated.pairRecall, "同人召回必须因分裂而下降")
        // 噪声上界（替换旧式 gated + 1 >= ungated：floor=0 时 ungated=0 ⇒ 恒真、无信息量）。
        // floor=0：桥接点是核心点，13 点全部入簇（0 噪声）；降级后至多桥接点自己变噪声，
        // 不得把两侧成员连带挤成噪声——上限 = 单点噪声 / 数据集点数。
        #expect(result.ungated.noiseCount == 0, "floor=0：桥接点是核心点，全部 13 点入簇、无噪声")
        #expect(
            result.gated.noiseCount <= result.ungated.noiseCount + 1,
            "降级桥接点至多自己成为噪声（≤ +1），不得连带其它点")
        #expect(
            result.gated.noiseRate <= 1.0 / Double(result.datasetSize) + 1e-12,
            "gated 噪声率上界 = 单点/13；本夹具桥接点被吸收为边界点 → 实际 0")
    }

    // MARK: - 生成器自检（确定性与受控余弦）

    @Test func generatorIsDeterministicAndRespectsSeparationBounds() {
        let first = makeSyntheticDataset(Self.cleanConfig)
        let second = makeSyntheticDataset(Self.cleanConfig)
        #expect(
            first.samples.count
                == Self.cleanConfig.identityCount * Self.cleanConfig.highQualityPerIdentity)
        #expect(
            first.samples.map(\.embedding) == second.samples.map(\.embedding),
            "同 seed 必须逐位一致")
        var otherConfig = Self.cleanConfig
        otherConfig.seed += 1
        #expect(
            first.samples.map(\.embedding)
                != makeSyntheticDataset(otherConfig).samples.map(\.embedding),
            "不同 seed 必须产生不同数据（否则 PRNG 未生效）")
        for i in 0..<first.identityCount {
            for j in (i + 1)..<first.identityCount {
                #expect(
                    abs(cosineFloats(first.centers[i], first.centers[j]))
                        <= Self.cleanConfig.maxCenterCosine + 1e-6,
                    "类间中心 |cos| 必须受 maxCenterCosine 约束")
            }
        }
        let close = makeSyntheticDataset(Self.libraryConfig)
        #expect(
            abs(cosineFloats(close.centers[0], close.centers[1]) - Self.closePairCosine) < 1e-5,
            "相近身份中心余弦必须等于 closePairCosine")
    }

    // MARK: - 基线表（人工记录用；与上面各组的打印同源）

    @Test func printsBaselineTable() throws {
        let clean = try Self.runCleanSet()
        let quality = try Self.runQualityFloor()
        let correctPose = try Self.runCorrectPose()
        let bridge = try Self.runBridge()

        let widths = [4, 24, 6, 7, 7, 7, 7, 7, 8, 8, 8]
        func clusterCells(_ metrics: ClusteringMetrics) -> [String] {
            [
                String(format: "%.4f", metrics.clusterPrecision),
                String(format: "%.4f", metrics.clusterRecall),
                String(format: "%.4f", metrics.pairPrecision),
                String(format: "%.4f", metrics.pairRecall),
                String(format: "%.4f", metrics.pairF1),
                String(format: "%.4f", metrics.adjustedRandIndex),
                "\(metrics.falsePositivePairs)",
                String(format: "%.1f%%", metrics.noiseRate * 100),
            ]
        }
        var lines: [String] = []
        lines.append("═══ 人脸聚类基线表（合成 embedding 层；单 seed；非真实识别精度；不得替代 Stretch 门）═══")
        lines.append(
            "注: 只对本表这组合成观测集成立——传入部分观测时簇数/覆盖率/精度只对该子集成立，真实库全量会与子集试算分叉；规模 ≤64 条/d=24；noise 越多 F1/ARI 越容易虚高，必须并读 noise 率。")
        lines.append(
            tableRow(
                ["组", "设定", "规模", "簇P", "簇R", "对P", "对R", "对F1", "ARI", "误聚对", "noise率"],
                widths: widths))
        lines.append(
            tableRow(
                ["A", "干净集 floor=0（自检）", "\(clean.datasetSize)"]
                    + clusterCells(clean.metrics),
                widths: widths))
        lines.append(
            tableRow(
                ["B1", "含低质量 floor=0", "\(quality.datasetSize)"]
                    + clusterCells(quality.ungated),
                widths: widths))
        lines.append(
            tableRow(
                ["B2", "含低质量 floor=0.5", "\(quality.datasetSize)"]
                    + clusterCells(quality.gated),
                widths: widths))
        lines.append(
            tableRow(
                ["B3", "floor=0.5+retry=2（≡B2）", "\(quality.datasetSize)"]
                    + clusterCells(quality.retried),
                widths: widths))
        lines.append(
            tableRow(
                ["①1", "方向正确低质量 floor=0", "\(correctPose.datasetSize)"]
                    + clusterCells(correctPose.ungated),
                widths: widths))
        lines.append(
            tableRow(
                ["①2", "方向正确低质量 floor=0.5", "\(correctPose.datasetSize)"]
                    + clusterCells(correctPose.gated),
                widths: widths))
        lines.append(
            tableRow(
                ["②1", "桥接点 floor=0", "\(bridge.datasetSize)"]
                    + clusterCells(bridge.ungated),
                widths: widths))
        lines.append(
            tableRow(
                ["②2", "桥接点 floor=0.5", "\(bridge.datasetSize)"]
                    + clusterCells(bridge.gated),
                widths: widths))
        print(lines.joined(separator: "\n"))

        // 表内数字与各组断言同源（若只改一处会立即暴露）。A 行只是一致性对账。
        #expect(clean.metrics.pairF1 == 1.0)
        #expect(quality.ungated.falsePositivePairs > 0)
        #expect(quality.gated.falsePositivePairs == 0)
        // 打印表的 ARI 列（B1/B2）加数值护栏：只打印不断言的基线会静默漂移。
        #expect(abs(quality.ungated.adjustedRandIndex - 0.4040) < 1e-3, "表中 B1 ARI 基线 0.4040")
        #expect(abs(quality.gated.adjustedRandIndex - 0.4587) < 1e-3, "表中 B2 ARI 基线 0.4587")
        #expect(quality.ungated.adjustedRandIndex < 0.5, "B1 ARI 必须低于 0.5（含误聚）")
        #expect(correctPose.gatedCrossIdentity == 0)
        #expect(bridge.ungatedIdentityZeroClusters == 1)
        #expect(bridge.gatedIdentityZeroClusters >= 2)
    }
}

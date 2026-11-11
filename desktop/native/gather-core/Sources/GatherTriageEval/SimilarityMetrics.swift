// desktop/native/gather-core/Sources/GatherTriageEval/SimilarityMetrics.swift
// Wave3 / task-19：相似/重复评估的纯数学层（pair 二分类 + 阈值曲线 + 聚类级过度合并）。
//
// 口径（与 ROADMAP §六 的四个问题对齐）：
// - pair 级：同一 ground-truth 合并组内的 pair = 正样本；
//   separate 组内与任意跨组 pair = 负样本；predictedMerge = similarity >= threshold。
// - 过度合并率 = FP / (TP + FP)：所有"被判合并"的 pair 里有多少其实不该合并。
// - 聚类级：把 predicted merge 边做并查集，和 ground-truth 分区比较，
//   统计 over-merged truth clusters（多个真组被连成一片）/ under-merged（真组被拆开）/ ARI。
// 纯函数、无 I/O：--self-test 在工具里直接驱动（不需要图片/数据库）。
import Foundation

/// 一对照片的评估样本。`similarity` 统一为"越大越像"（dHash 已换算成 1 - hamming/64）。
struct SimilarityPairSample: Equatable {
    let idA: String
    let idB: String
    let similarity: Double
    let shouldMerge: Bool
    let kind: SimilarityAnnotationClass
    /// 跨组 pair（评价"不同客户但构图相似"这类过度合并的主证据）；分类拆解时不计入。
    var crossGroup: Bool = false
}

struct SimilarityConfusion: Equatable {
    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    var trueNegative = 0

    var predictedPositive: Int { truePositive + falsePositive }
    var actualPositive: Int { truePositive + falseNegative }
}

struct SimilarityOperatingPoint: Equatable {
    let threshold: Double
    let confusion: SimilarityConfusion

    var precision: Double? {
        confusion.predictedPositive == 0
            ? nil
            : Double(confusion.truePositive) / Double(confusion.predictedPositive)
    }

    var recall: Double? {
        confusion.actualPositive == 0
            ? nil
            : Double(confusion.truePositive) / Double(confusion.actualPositive)
    }

    var f1: Double? {
        guard let precision, let recall, precision + recall > 0 else { return nil }
        return 2 * precision * recall / (precision + recall)
    }

    /// 过度合并率：被预测合并的 pair 中真实不该合并的比例（= 1 - precision）。
    var overMergeRate: Double? {
        precision.map { 1 - $0 }
    }
}

struct SimilarityClassBreakdown: Equatable {
    let kind: SimilarityAnnotationClass
    /// 该类别自己的 pair 视图：类内 pair + 任一侧属于该类的跨类 pair（负数来源）。
    let point: SimilarityOperatingPoint

    /// 该类在标注里是否有"应合并"的正样本（只有 merge 组才可能有）。
    /// false 时 recall/FN 无定义（separate 类本来就没有"应合并"），不能当 0 展示。
    var hasPositivePairs: Bool { point.confusion.actualPositive > 0 }

    /// 有没有"被判合并"的样本（决定 precision / 过度合并率是否有定义）。
    var hasPredictedMerges: Bool { point.confusion.predictedPositive > 0 }
}

/// 聚类级结果：groundTruth 分区 vs 预测分区的对比。
struct SimilarityClusterEvaluation: Equatable {
    /// 真组被连成一片的次数（最该盯的"过度合并"用户可见形态）。
    var overMergedTruthClusters = 0
    /// 真组被拆成多片的次数（"漏合并"）。
    var underMergedTruthClusters = 0
    /// 完全一致的真组数。
    var exactTruthClusters = 0
    var adjustedRandIndex: Double = 0
}

enum SimilarityMetrics {
    // MARK: - pair 级

    static func operatingPoint(
        pairs: [SimilarityPairSample], threshold: Double
    ) -> SimilarityOperatingPoint {
        var confusion = SimilarityConfusion()
        for pair in pairs where pair.similarity >= threshold {
            if pair.shouldMerge {
                confusion.truePositive += 1
            } else {
                confusion.falsePositive += 1
            }
        }
        for pair in pairs where pair.similarity < threshold {
            if pair.shouldMerge {
                confusion.falseNegative += 1
            } else {
                confusion.trueNegative += 1
            }
        }
        return SimilarityOperatingPoint(threshold: threshold, confusion: confusion)
    }

    static func curve(
        pairs: [SimilarityPairSample], thresholds: [Double]
    ) -> [SimilarityOperatingPoint] {
        thresholds
            .sorted()
            .map { operatingPoint(pairs: pairs, threshold: $0) }
    }

    /// 推荐工作点：在 precision >= minPrecision 的候选里取 recall 最大者；
    /// 没有候选时退回 F1 最大的点（并让调用方在报告里标注"达不到目标精确率"）。
    static func recommendedPoint(
        curve: [SimilarityOperatingPoint], minPrecision: Double
    ) -> SimilarityOperatingPoint? {
        let qualified = curve.filter { point in
            guard let precision = point.precision, let recall = point.recall else { return false }
            return precision >= minPrecision && recall > 0
        }
        if let best = qualified.max(by: { lhs, rhs in
            let left = lhs.recall ?? 0
            let right = rhs.recall ?? 0
            if left != right { return left < right }
            return (lhs.precision ?? 0) < (rhs.precision ?? 0)
        }) {
            return best
        }
        return curve.max { lhs, rhs in (lhs.f1 ?? -1) < (rhs.f1 ?? -1) }
    }

    /// 按四类拆分的 pair 指标（同一阈值下逐类看 precision/过度合并，回答
    /// "embedding 在连拍上有用、在不同人物上反而更糟吗"）。
    ///
    /// 口径（E1 修复）：每类的 pair 视图 = 类内 pair + **任一侧属于该类的跨类 pair**。
    /// 只用类内 pair 会退化——merge 类（burst）类内全是正样本 → precision 恒 1；
    /// separate 类类内全是负样本 → recall 无定义、precision 恒 0。
    /// 引入跨类 pair 作负样本后：merge 类能算出真实 precision（被误并的跨类对会拉低），
    /// separate 类能算出真实的过度合并率；separate 类仍无"应合并"样本，recall 由
    /// `hasPositivePairs` 标注为无定义（报告显示 n/a，不当 0）。
    static func breakdown(
        pairs: [SimilarityPairSample],
        threshold: Double,
        classByPhoto: [String: SimilarityAnnotationClass]
    ) -> [SimilarityClassBreakdown] {
        var byKind: [SimilarityAnnotationClass: [SimilarityPairSample]] = [:]
        for pair in pairs {
            let leftKind = classByPhoto[pair.idA]
            let rightKind = classByPhoto[pair.idB]
            guard leftKind != nil || rightKind != nil else { continue }
            if let leftKind { byKind[leftKind, default: []].append(pair) }
            // 跨类 pair 同时进入两侧类别的视图（类内 pair 两侧同类，只记一次）。
            if let rightKind, rightKind != leftKind {
                byKind[rightKind, default: []].append(pair)
            }
        }
        return byKind.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            SimilarityClassBreakdown(
                kind: key,
                point: operatingPoint(pairs: byKind[key] ?? [], threshold: threshold))
        }
    }

    // MARK: - 聚类级

    /// 聚类级对比。`truth` = photoID -> ground-truth 组 id（只有 merge 组才共享组 id；
    /// separate 组的照片各自独立，调用方传唯一 id）。`predictedPairs` 是相似度 >= 阈值
    /// 的全部 pair（包含未标注照片时也会连边，与线上聚类一致）。
    static func clusterEvaluation(
        truthGroupByPhoto: [String: String],
        pairs: [SimilarityPairSample],
        threshold: Double
    ) -> SimilarityClusterEvaluation {
        let ids = Array(truthGroupByPhoto.keys)
        if ids.isEmpty { return SimilarityClusterEvaluation() }
        var predicted = UnionFind()
        for id in ids { predicted.add(id) }
        for pair in pairs where pair.similarity >= threshold {
            guard truthGroupByPhoto[pair.idA] != nil, truthGroupByPhoto[pair.idB] != nil else {
                continue
            }
            predicted.union(pair.idA, pair.idB)
        }
        // 预测分区：photo -> representative
        var predictedGroup: [String: String] = [:]
        for id in ids { predictedGroup[id] = predicted.find(id) }
        // 真分区：merge 组共享组 id；separate 组每张独立（调用方已保证唯一 id）。
        var photosByTruth: [String: [String]] = [:]
        for id in ids {
            photosByTruth[truthGroupByPhoto[id] ?? id, default: []].append(id)
        }
        var predictedSetsByTruth: [String: Set<String>] = [:]
        for (truthId, photos) in photosByTruth {
            predictedSetsByTruth[truthId] = Set(photos.compactMap { predictedGroup[$0] })
        }
        // 每个预测分片里落进了哪些真组：>1 就说明这些真组被错误地连成一片。
        var truthClustersByPredicted: [String: Set<String>] = [:]
        for (truthId, predictedSets) in predictedSetsByTruth {
            for rep in predictedSets {
                truthClustersByPredicted[rep, default: []].insert(truthId)
            }
        }
        var overMerged = 0
        var underMerged = 0
        var exact = 0
        for (_, predictedSets) in predictedSetsByTruth {
            let touchesOtherTruth = predictedSets.contains { rep in
                (truthClustersByPredicted[rep]?.count ?? 0) > 1
            }
            let split = predictedSets.count > 1
            if touchesOtherTruth { overMerged += 1 }
            if split { underMerged += 1 }
            if !split && !touchesOtherTruth { exact += 1 }
        }
        let ari = adjustedRandIndex(
            truthGroupByPhoto: truthGroupByPhoto, predictedGroup: predictedGroup)
        return SimilarityClusterEvaluation(
            overMergedTruthClusters: overMerged,
            underMergedTruthClusters: underMerged,
            exactTruthClusters: exact,
            adjustedRandIndex: ari)
    }

    /// ARI（配对计数形式，rand index 的期望校正版）。未标注照片不参与。
    static func adjustedRandIndex(
        truthGroupByPhoto: [String: String], predictedGroup: [String: String]
    ) -> Double {
        let ids = Array(truthGroupByPhoto.keys).sorted()
        guard ids.count >= 2 else { return 1 }
        var truthCounts: [String: Int] = [:]
        var predictedCounts: [String: Int] = [:]
        var jointCounts: [String: Int] = [:]
        for id in ids {
            let truth = truthGroupByPhoto[id] ?? id
            let predicted = predictedGroup[id] ?? id
            truthCounts[truth, default: 0] += 1
            predictedCounts[predicted, default: 0] += 1
            jointCounts[truth + "\u{1F}" + predicted, default: 0] += 1
        }
        func choose2(_ n: Int) -> Double { n < 2 ? 0 : Double(n * (n - 1)) / 2 }
        let index: Double = jointCounts.values.reduce(0) { $0 + choose2($1) }
        let sumTruth: Double = truthCounts.values.reduce(0) { $0 + choose2($1) }
        let sumPredicted: Double = predictedCounts.values.reduce(0) { $0 + choose2($1) }
        let total = choose2(ids.count)
        let expected = total == 0 ? 0 : sumTruth * sumPredicted / total
        let maximum = (sumTruth + sumPredicted) / 2
        guard maximum != expected else { return 1 }
        return (index - expected) / (maximum - expected)
    }

    // MARK: - 自检（--self-test 用；不依赖图片/数据库）

    struct SelfTestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { "self-test failed: \(message)" }
    }

    static func selfTest() throws {
        // 合成 4 个真组：g1 merge(3 张) / g2 merge(2 张) /
        // g3 separate(2 张，故意高相似) / g4 separate(2 张，低相似)。
        func pair(_ lhs: String, _ rhs: String, _ similarity: Double,
                  _ shouldMerge: Bool, _ kind: SimilarityAnnotationClass) -> SimilarityPairSample {
            SimilarityPairSample(
                idA: lhs, idB: rhs, similarity: similarity, shouldMerge: shouldMerge, kind: kind)
        }
        var pairs: [SimilarityPairSample] = []
        pairs.append(pair("a1", "a2", 0.98, true, .burst))
        pairs.append(pair("a1", "a3", 0.96, true, .burst))
        pairs.append(pair("a2", "a3", 0.95, true, .burst))
        pairs.append(pair("b1", "b2", 0.93, true, .burst))
        pairs.append(pair("c1", "c2", 0.99, false, .sameSceneDifferentPeople))
        pairs.append(pair("d1", "d2", 0.50, false, .sameSceneDifferentTime))
        pairs.append(pair("a1", "b1", 0.40, false, .burst))
        pairs.append(pair("a1", "c1", 0.30, false, .burst))

        let point = operatingPoint(pairs: pairs, threshold: 0.9)
        try expect(point.confusion.truePositive == 4, "TP 应为 4，实际 \(point.confusion.truePositive)")
        try expect(point.confusion.falsePositive == 1, "FP 应为 1，实际 \(point.confusion.falsePositive)")
        try expect(point.confusion.falseNegative == 0, "FN 应为 0，实际 \(point.confusion.falseNegative)")
        try expect(point.confusion.trueNegative == 3, "TN 应为 3，实际 \(point.confusion.trueNegative)")
        try expect(abs((point.precision ?? 0) - 0.8) < 1e-9, "precision 应为 0.8")
        try expect(abs((point.recall ?? 0) - 1.0) < 1e-9, "recall 应为 1.0")
        try expect(abs((point.overMergeRate ?? 0) - 0.2) < 1e-9, "过度合并率应为 0.2")

        let curve = self_curve(pairs: pairs)
        try expect(curve.count == 3, "曲线点数不对：\(curve.count)")
        try expect(curve.first?.threshold == 0.5, "曲线应按阈值升序")
        // 逐点口径（回归护栏；c1c2=0.99 是 FP，任何 <=0.99 的阈值下都会被判合并）：
        //   0.50 → TP4 FP2 FN0 TN2，P=0.6667，R=1.0
        //   0.90 → TP4 FP1 FN0 TN3，P=0.8，   R=1.0
        //   0.97 → TP1 FP1 FN3 TN3，P=0.5，   R=0.25
        let loosePoint = operatingPoint(pairs: pairs, threshold: 0.5)
        try expect(
            loosePoint.confusion.truePositive == 4
                && loosePoint.confusion.falsePositive == 2
                && loosePoint.confusion.trueNegative == 2,
            "0.50 阈值混淆矩阵不对：\(loosePoint.confusion)")
        let strictHeat = operatingPoint(pairs: pairs, threshold: 0.97)
        try expect(
            strictHeat.confusion.truePositive == 1
                && strictHeat.confusion.falsePositive == 1
                && strictHeat.confusion.falseNegative == 3,
            "0.97 阈值混淆矩阵不对：\(strictHeat.confusion)")
        try expect(
            abs((strictHeat.precision ?? 0) - 0.5) < 1e-9,
            "0.97 的 precision 应为 0.5（FP=c1c2 仍在）：\(String(describing: strictHeat.precision))")
        // 本用例**没有**任何点达到 P>=0.95（0.97 处 FP 仍在）→ 期望回退 F1 最大点 0.90：
        //   0.50 F1=0.8，0.90 F1=0.8889，0.97 F1=0.3333。
        let recommended = recommendedPoint(curve: curve, minPrecision: 0.95)
        try expect(
            recommended?.threshold == 0.9,
            "无达标点时应回退 F1 最大（0.90），实际 \(String(describing: recommended?.threshold))")
        try expect((recommended?.precision ?? 1) < 0.95, "该用例应走 fallback（没有达标点）")

        // 达标路径单独验证：3 个正样本 + 1 个 0.90 负样本（低于所有曲线阈值，不干扰）。
        //   0.95 → TP3 FP0 FN0 TN1：P=1 R=1
        //   0.97 → TP2 FP0 FN1 TN1：P=1 R=0.6667
        // 目标 P>=0.95 时两点都达标 → 必须取 recall 更大的 0.95（不是最高阈值）。
        let cleanPairs: [SimilarityPairSample] = [
            SimilarityPairSample(
                idA: "x1", idB: "x2", similarity: 0.99, shouldMerge: true, kind: .burst),
            SimilarityPairSample(
                idA: "x2", idB: "x3", similarity: 0.98, shouldMerge: true, kind: .burst),
            SimilarityPairSample(
                idA: "x1", idB: "x3", similarity: 0.96, shouldMerge: true, kind: .burst),
            SimilarityPairSample(
                idA: "y1", idB: "y2", similarity: 0.90, shouldMerge: false,
                kind: .sameSceneDifferentPeople),
        ]
        let cleanCurve = Self.curve(pairs: cleanPairs, thresholds: [0.95, 0.97])
        let qualified = recommendedPoint(curve: cleanCurve, minPrecision: 0.95)
        try expect(
            qualified?.threshold == 0.95,
            "达标点应取 recall 最大的 0.95，实际 \(String(describing: qualified?.threshold))")
        try expect(abs((qualified?.precision ?? 0) - 1.0) < 1e-9, "0.95 的 precision 应为 1.0")
        try expect(abs((qualified?.recall ?? 0) - 1.0) < 1e-9, "0.95 的 recall 应为 1.0")

        // 聚类级理想情形：当真值把 c1/c2 也算作一组（阈值 0.9 时恰好全对）→ ARI=1。
        let idealTruth: [String: String] = [
            "a1": "g1", "a2": "g1", "a3": "g1",
            "b1": "g2", "b2": "g2",
            "c1": "g3", "c2": "g3",
            "d1": "d1", "d2": "d2",
        ]
        let ideal = clusterEvaluation(
            truthGroupByPhoto: idealTruth, pairs: pairs, threshold: 0.9)
        try expect(ideal.overMergedTruthClusters == 0,
                   "理想分区不应过度合并，实际 \(ideal.overMergedTruthClusters)")
        try expect(ideal.underMergedTruthClusters == 0,
                   "理想分区不应漏合并，实际 \(ideal.underMergedTruthClusters)")
        try expect(abs(ideal.adjustedRandIndex - 1.0) < 1e-9,
                   "理想分区 ARI 应为 1.0，实际 \(ideal.adjustedRandIndex)")

        // 过度合并形态：真值认为 c1/c2 必须分开，但 c 对相似度 0.99 → 阈值 0.9 时被并掉。
        let overTruth: [String: String] = [
            "a1": "g1", "a2": "g1", "a3": "g1",
            "b1": "g2", "b2": "g2",
            "c1": "c1", "c2": "c2",
            "d1": "d1", "d2": "d2",
        ]
        let over = clusterEvaluation(
            truthGroupByPhoto: overTruth, pairs: pairs, threshold: 0.9)
        try expect(over.overMergedTruthClusters == 2,
                   "c1/c2 两个真组应被计为过度合并，实际 \(over.overMergedTruthClusters)")
        try expect(over.adjustedRandIndex < 0.99, "过度合并应拉低 ARI")

        // 高阈值形态：0.995 时 a/b 组都拆开（漏合并），c 对未被并（过度合并消失）。
        let strict = clusterEvaluation(
            truthGroupByPhoto: overTruth, pairs: pairs, threshold: 0.995)
        try expect(strict.underMergedTruthClusters >= 1,
                   "高阈值应出现漏合并，实际 \(strict.underMergedTruthClusters)")
        try expect(strict.overMergedTruthClusters == 0, "高阈值不应过度合并")

        // E1 回归：分类视图必须含跨类负样本，否则 merge 类 precision 恒 1 / separate 类恒 0。
        // 合成：burst 内一对应合并（0.95）；burst × separate 的跨类对 0.93 = 误并；
        // separate 类内一对 0.96 = 该类的过度合并。阈值 0.9 时全部被判合并。
        let classPairs: [SimilarityPairSample] = [
            SimilarityPairSample(
                idA: "m1", idB: "m2", similarity: 0.95, shouldMerge: true, kind: .burst),
            SimilarityPairSample(
                idA: "m1", idB: "s1", similarity: 0.93, shouldMerge: false,
                kind: .burst, crossGroup: true),
            SimilarityPairSample(
                idA: "s1", idB: "s2", similarity: 0.96, shouldMerge: false,
                kind: .sameSceneDifferentPeople),
        ]
        let classByPhoto: [String: SimilarityAnnotationClass] = [
            "m1": .burst, "m2": .burst,
            "s1": .sameSceneDifferentPeople, "s2": .sameSceneDifferentPeople,
        ]
        let classView = breakdown(
            pairs: classPairs, threshold: 0.9, classByPhoto: classByPhoto)
        let burstView = classView.first { $0.kind == .burst }
        try expect(burstView?.point.confusion.truePositive == 1, "burst 类 TP 应为 1")
        try expect(
            burstView?.point.confusion.falsePositive == 1,
            "burst 类必须把跨类误并计入 precision 分母（否则 precision 恒 1）")
        try expect(
            abs((burstView?.point.precision ?? 0) - 0.5) < 1e-9,
            "burst precision 应为 0.5（1 TP / (1 TP + 1 跨类 FP)），实际 "
                + String(describing: burstView?.point.precision))
        try expect(burstView?.hasPositivePairs == true, "burst 类应有正样本")
        let peopleView = classView.first { $0.kind == .sameSceneDifferentPeople }
        try expect(
            peopleView?.hasPositivePairs == false,
            "separate 类没有任何\"应合并\"样本 → recall 无定义")
        try expect(
            peopleView?.point.confusion.falsePositive == 2,
            "separate 类视图应含类内 FP + 跨类 FP，实际 "
                + String(describing: peopleView?.point.confusion.falsePositive))
        try expect(
            abs((peopleView?.point.overMergeRate ?? -1) - 1.0) < 1e-9,
            "separate 类过度合并率应为 1.0（2 个预测合并全部是错并）")
    }

    private static func self_curve(pairs: [SimilarityPairSample]) -> [SimilarityOperatingPoint] {
        curve(pairs: pairs, thresholds: [0.5, 0.9, 0.97])
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw SelfTestFailure(message: message) }
    }
}

/// 极简并查集（路径减半 + 按秩合并），聚类级评估用。
private struct UnionFind {
    private var parent: [String: String] = [:]
    private var rank: [String: Int] = [:]

    mutating func add(_ id: String) {
        if parent[id] == nil {
            parent[id] = id
            rank[id] = 0
        }
    }

    mutating func find(_ id: String) -> String {
        var current = id
        while let next = parent[current], next != current {
            if let grand = parent[next] { parent[current] = grand }
            current = next
        }
        return current
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        let leftRoot = find(lhs)
        let rightRoot = find(rhs)
        guard leftRoot != rightRoot else { return }
        let leftRank = rank[leftRoot] ?? 0
        let rightRank = rank[rightRoot] ?? 0
        if leftRank < rightRank {
            parent[leftRoot] = rightRoot
        } else if leftRank > rightRank {
            parent[rightRoot] = leftRoot
        } else {
            parent[rightRoot] = leftRoot
            rank[leftRoot] = leftRank + 1
        }
    }
}

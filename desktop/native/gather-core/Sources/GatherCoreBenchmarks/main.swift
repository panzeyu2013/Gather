// desktop/native/gather-core/Sources/GatherCoreBenchmarks/main.swift
// Similarity 基准（计划 2.3 验收：2 万/5 万通过）。
// 覆盖三类算法负载：dHash 聚类（ClusterGraphPipeline）、embedding 聚类
// （FaceClusterer，LSH 路径）、LSH 建索引+查询 recall。
// Cut 5 / 5b-2a：HNSW 基准已删（CosineHnswIndex 删除，CL-06）。
// Cut 5 / 5d-2：新增 `--face-10k` 合成人脸档（50 身份 × 200 样本 × 512 维）：
// 无检测/对齐/嵌入模型（A 阶段不可测），只测 B 聚类（FaceClusterer/DBSCAN）与
// FaceMatcher 批量匹配，输出耗时与内存粗估（审计 §6.2）。
// 数据全部确定性生成（固定种子，不入库），输出 NDJSON 行（对齐
// scripts/application-scale-benchmark.mjs 的 stdout JSON 行风格）。
// 用法：
//   .build/debug/gather-core-benchmarks            # 2 万/5 万两档全量
//   .build/debug/gather-core-benchmarks --smoke    # 2 千冒烟档
//   .build/debug/gather-core-benchmarks --multi-bench  # 多档位单趟 A/B（§4.2 性能证据）
//   .build/debug/gather-core-benchmarks --quality      # 合成聚类质量基线（P/R/F1/noise；含阈值断言）
//   .build/debug/gather-core-benchmarks --margin       # margin 扫描（生产 FaceIdentityPolicy；含边界断言）
//   .build/debug/gather-core-benchmarks --incremental  # 2 万张 + 100 张新增的增量复用/耗时门
//
// 阈值断言（Cut 5 后续）：--quality / --margin / --incremental 与 --smoke 的
// LSH 召回在 print 之后逐项判定，退化直接 exit 1；nightly.yml 依赖这个退出码，
// 不再只把 NDJSON 上传留待人工比对。
//   .build/debug/gather-core-benchmarks --face-10k     # 10k 合成人脸（显式档；debug 走 LSH，
//                                                      #   -c release 走生产默认的精确 DBSCAN）
import Foundation
import GatherAnalysis
import GatherProtocol

// ── 确定性 PRNG（与对账生成器同款 mulberry32）──
struct BenchmarkRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ (t ^ (t >> 7)) &* (t | 61)
        return Double((t ^ (t >> 14)) >> 0) / 4294967296.0
    }

    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12)
        return sqrt(-2 * log(u)) * cos(2 * Double.pi * next())
    }
}

// ── 输出 ──
struct MetricRow: Encodable {
    let benchmark: String
    let phase: String
    let size: Int
    let durationMs: Double
    let throughputPerSec: Double
    let metric: String
}

private let encoder = JSONEncoder()
private let start = DispatchTime.now()

func emit(_ row: MetricRow) {
    encoder.outputFormatting = [.sortedKeys]
    var data: Data
    do { data = try encoder.encode(row) } catch { return }
    print(String(data: data, encoding: .utf8) ?? "{}")
}

func elapsedMs(_ since: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
}

// ── 阈值断言（夜间门禁）──
// 统计门从默认单测迁出后不能只「打印」：下限写进可执行文件，退化直接非零
// 退出（nightly 变红），否则删掉的 ARI/召回/精确率断言等于无人守。
// 阈值只依赖确定性数据与固定种子，与机器无关；耗时只设宽松上限，避免把
// CI 负载波动误判成回归。
/// 断言只走返回值（不共享可变状态）：各 benchmark 函数把自己违反的条目作为
/// 字符串数组返回，入口汇总后判定，避免在 0 依赖的基准目标里引入锁盒子。
func check(
    _ condition: Bool, _ message: @autoclosure () -> String, into failures: inout [String]
) {
    guard !condition else { return }
    failures.append(message())
}

func reportChecks(_ phase: String, _ failures: [String]) -> Never {
    guard failures.isEmpty else {
        for failure in failures {
            print("benchmark=\(phase) check=FAIL reason=\(failure)")
        }
        exit(1)
    }
    print("benchmark=\(phase) check=PASS")
    exit(0)
}

// ── 数据生成 ──
/// dHash 条目：50 簇，每簇中心 64 位随机 hash，成员 = 中心扰动 1-6 bit。
func makeHashEntries(count: Int, seed: UInt32) -> [HashEntry] {
    var rand = BenchmarkRandom(seed: seed)
    let clusterCount = 50
    var centers: [UInt64] = []
    for _ in 0..<clusterCount {
        let center = (0..<64).reduce(UInt64(0)) { acc, _ in
            (acc << 1) | UInt64(rand.next() < 0.5 ? 1 : 0)
        }
        centers.append(center)
    }
    var entries: [HashEntry] = []
    entries.reserveCapacity(count)
    for i in 0..<count {
        let cluster = i % clusterCount
        var value = centers[cluster]
        let flips = Int(rand.next() * 6) + 1
        for _ in 0..<flips {
            value ^= UInt64(1) << UInt64(Int(rand.next() * 64))
        }
        let hash = String(format: "%016llx", value)
        entries.append(HashEntry(photoId: "p\(i)", hash: hash))
    }
    return entries
}

/// embedding：`clusters` 个正交簇中心（Gram-Schmidt）+ 高斯扰动，维度由参数决定。
/// 扰动按维度缩放：σ=0.005 下 512 维簇内余弦 ≈0.987（>eps 0.9），跨簇 ≈0；
/// 默认 50 簇/128 维与既有 embedding 档一致（10k 人脸档用 50 簇/512 维）。
func makeEmbeddings(
    count: Int, dim: Int, seed: UInt32, perturb: Double = 0.005, clusters: Int = 50
) -> [EmbeddingEntry] {
    var rand = BenchmarkRandom(seed: seed)
    let clusterCount = clusters

    var bases: [[Double]] = []
    for _ in 0..<clusterCount {
        var v = (0..<dim).map { _ in rand.gaussian() }
        for b in bases {
            let dot = zip(v, b).reduce(0.0) { $0 + $1.0 * $1.1 }
            for d in 0..<dim { v[d] -= dot * b[d] }
        }
        let norm = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 { for d in 0..<dim { v[d] /= norm } }
        bases.append(v)
    }

    var entries: [EmbeddingEntry] = []
    entries.reserveCapacity(count)
    for i in 0..<count {
        let cluster = i % clusterCount
        let base = bases[cluster]
        let e = base.map { Float($0 + rand.gaussian() * perturb) }
        entries.append(
            EmbeddingEntry(observationId: i + 1, photoId: "p\(i)", embedding: e))
    }
    return entries
}

// ── 基准项 ──
func benchDHashCluster(size: Int, seed: UInt32) throws {
    let since = DispatchTime.now()
    let entries = makeHashEntries(count: size, seed: seed)
    let gen = elapsedMs(since)

    let sinceRun = DispatchTime.now()
    let result = try ClusterGraphPipeline.run(
        entries: entries, threshold: 8, minGroupSize: 3).result
    let runMs = elapsedMs(sinceRun)

    emit(MetricRow(
        benchmark: "similarity", phase: "dhash-cluster", size: size,
        durationMs: runMs,
        throughputPerSec: Double(size) / (runMs / 1000),
        metric: "genMs=\(String(format: "%.1f", gen)) groups=\(result.groups.count) ungrouped=\(result.ungrouped.count)"))
}


/// §4.2 P1 性能证据：多档位 bitset 路径的单趟共享 vs 逐档独立。
/// 同一批条目、同一组阈值分别跑 A/B：A = 每档一次 run（每档一趟 O(n²)），
/// B = runTiers（一次 pair 遍历 + 每档一次 wave BFS，共享最高档并集位图）。
/// 结果逐位比对，不一致直接以非零退出（基准兼作等价性门禁）。
func benchDHashClusterMulti(size: Int, seed: UInt32) throws {
    let entries = makeHashEntries(count: size, seed: seed)
    let thresholds = [4, 8, 12, 16, 20]

    let sincePerTier = DispatchTime.now()
    let perTier = try thresholds.map { tier in
        try ClusterGraphPipeline.run(
            entries: entries, threshold: tier, minGroupSize: 3).result
    }
    let perTierMs = elapsedMs(sincePerTier)

    let sinceShared = DispatchTime.now()
    let shared = try ClusterGraphPipeline.runTiers(
        entries: entries, thresholds: thresholds, minGroupSize: 3)
    let sharedMs = elapsedMs(sinceShared)

    let identical = zip(perTier, shared).allSatisfy { a, b in
        a.groups == b.groups && a.ungrouped == b.ungrouped
    }

    emit(MetricRow(
        benchmark: "similarity", phase: "dhash-cluster-multi", size: size,
        durationMs: sharedMs,
        throughputPerSec: Double(size) / max(sharedMs / 1000, 1e-9),
        metric: "perTierMs=\(String(format: "%.1f", perTierMs)) sharedMs=\(String(format: "%.1f", sharedMs)) speedup=\(String(format: "%.2f", perTierMs / max(sharedMs, 1e-9))) tiers=\(thresholds.count) identical=\(identical)"))

    if !identical {
        print("benchmark=similarity error=multi-tier-result-mismatch")
        exit(1)
    }
}

func benchEmbeddingCluster(size: Int, seed: UInt32, lshMinPoints: Int) throws {
    let since = DispatchTime.now()
    let entries = makeEmbeddings(count: size, dim: 128, seed: seed)
    let gen = elapsedMs(since)

    let sinceRun = DispatchTime.now()
    let options = ClusterLshOptions(
        enabled: true, minPoints: lshMinPoints, config: LshConfig(unitVectors: true))
    let result = try FaceClusterer.clusterEmbeddings(
        entries: entries, eps: 0.9, minPts: 5, lshOptions: options)
    let runMs = elapsedMs(sinceRun)

    let groups = result.clusters.count
    let noise = result.noise.count

    emit(MetricRow(
        benchmark: "similarity", phase: "embedding-cluster", size: size,
        durationMs: runMs,
        throughputPerSec: Double(size) / (runMs / 1000),
        metric: "genMs=\(String(format: "%.1f", gen)) groups=\(groups) noise=\(noise) lshMinPoints=\(lshMinPoints)"))
}

// ── 质量基线（从单测迁出）──
// 合成“身份中心 + 高质量样本 + 共享退化低质量样本”，输出 pairwise P/R/F1 与
// noise 率。默认测试只验证行为；这里的数字用于夜间基线，不进入 PR 门禁。

func normalizedFloats(_ values: [Double]) -> [Float] {
    let norm = values.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
    guard norm > 0 else { return values.map(Float.init) }
    return values.map { Float($0 / norm) }
}

func randomUnitVector(dim: Int, rand: inout BenchmarkRandom) -> [Double] {
    let raw = (0..<dim).map { _ in rand.gaussian() }
    let norm = raw.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? raw.map { $0 / norm } : raw
}

func makeQualityEntries(
    identities: Int, perIdentity: Int, dim: Int, seed: UInt32
) -> (entries: [EmbeddingEntry], labels: [Int]) {
    var rand = BenchmarkRandom(seed: seed)
    var bases: [[Double]] = []
    for _ in 0..<identities {
        var v = (0..<dim).map { _ in rand.gaussian() }
        for b in bases {
            let dot = zip(v, b).reduce(0.0) { $0 + $1.0 * $1.1 }
            for d in 0..<dim { v[d] -= dot * b[d] }
        }
        let norm = v.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for d in 0..<dim { v[d] /= norm } }
        bases.append(v)
    }

    // 与所有身份中心近正交的共享退化方向：低质量样本互相抱团、与本人不像。
    var degraded = (0..<dim).map { _ in rand.gaussian() }
    for _ in 0..<2 {
        for b in bases {
            let dot = zip(degraded, b).reduce(0.0) { $0 + $1.0 * $1.1 }
            for d in 0..<dim { degraded[d] -= dot * b[d] }
        }
    }
    let degradedNorm = degraded.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
    if degradedNorm > 0 { for d in 0..<dim { degraded[d] /= degradedNorm } }

    var entries: [EmbeddingEntry] = []
    var labels: [Int] = []
    var index = 0
    for identity in 0..<identities {
        for sample in 0..<perIdentity {
            let isLowQuality = sample % 5 == 4
            let noise = randomUnitVector(dim: dim, rand: &rand)
            let raw: [Double]
            if isLowQuality {
                raw = zip(degraded, noise).map { $0 + $1 * 0.3 }
            } else {
                raw = zip(bases[identity], noise).map { $0 + $1 * 0.25 }
            }
            entries.append(
                EmbeddingEntry(
                    observationId: index + 1,
                    photoId: "q\(index)",
                    embedding: normalizedFloats(raw),
                    quality: isLowQuality ? 0.2 : 1.0))
            labels.append(identity)
            index += 1
        }
    }
    return (entries, labels)
}

func comb2(_ k: Int) -> Int { k < 2 ? 0 : k * (k - 1) / 2 }

/// ARI（Hubert–Arabie）：与默认套件删除的统计实现同口径，仅用于夜间基线。
func adjustedRandIndex(labels: [Int], predicted: [Int]) -> Double {
    precondition(labels.count == predicted.count)
    let count = labels.count
    var joint: [Int: [Int: Int]] = [:]
    for index in 0..<count {
        joint[predicted[index], default: [:]][labels[index], default: 0] += 1
    }
    let totalPairs = comb2(count)
    let sumJointPairs = joint.values.reduce(0) { total, row in
        total + row.values.reduce(0) { $0 + comb2($1) }
    }
    let sumPredictedPairs = joint.values.reduce(0) { $0 + comb2($1.values.reduce(0, +)) }
    var truthCounts: [Int: Int] = [:]
    for row in joint.values {
        for (truth, value) in row { truthCounts[truth, default: 0] += value }
    }
    let sumTruthPairs = truthCounts.values.reduce(0) { $0 + comb2($1) }
    let expected = totalPairs > 0
        ? Double(sumTruthPairs) * Double(sumPredictedPairs) / Double(totalPairs) : 0
    let maximum = Double(sumTruthPairs + sumPredictedPairs) / 2
    return maximum - expected == 0
        ? 1 : (Double(sumJointPairs) - expected) / (maximum - expected)
}

/// 手算小例自检：ARI 公式回归时 --quality 直接非零退出，而不是只在夜间打印错误数字。
func validateQualityMetrics() {
    let hand = adjustedRandIndex(
        labels: [0, 0, 1, 1, 2, 2], predicted: [0, 0, 0, 1, 2, 2])
    guard abs(hand - 4.0 / 9.0) < 1e-12 else {
        print("benchmark=face-quality error=ari-hand-computed-mismatch value=\(hand)")
        exit(1)
    }
    let negative = adjustedRandIndex(
        labels: [0, 0, 1, 1], predicted: [0, 1, 0, 1])
    guard abs(negative + 0.5) < 1e-12 else {
        print("benchmark=face-quality error=ari-negative-case-mismatch value=\(negative)")
        exit(1)
    }
}

/// 合成聚类质量指标；`unassigned` 是完整性校验（>0 = 聚类器丢点，P/R/F1/ARI 不可信）。
struct QualityMetrics {
    let precision: Double
    let recall: Double
    let f1: Double
    let ari: Double
    let noiseRate: Double
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let unassigned: Int
    let clusters: Int
}

func clusterQualityMetric(
    entries: [EmbeddingEntry], labels: [Int], result: FaceClusterResult
) -> QualityMetrics {
    let count = entries.count
    var predicted = [Int](repeating: -1, count: count)
    var nextCluster = 0
    for cluster in result.clusters {
        for entry in cluster { predicted[entry.observationId - 1] = nextCluster }
        nextCluster += 1
    }
    for entry in result.noise {
        predicted[entry.observationId - 1] = nextCluster
        nextCluster += 1
    }
    // 丢点检测必须在「noise 逐点成簇」之前按覆盖率算：赋值后每个下标都有值，
    // 再 filter(<0) 恒为空，等于没有校验。
    let assignedCount = result.clusters.reduce(0) { $0 + $1.count } + result.noise.count
    let unassigned = max(count - assignedCount, 0)

    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    for i in 0..<count {
        for j in (i + 1)..<count {
            let sameTruth = labels[i] == labels[j]
            let samePrediction = predicted[i] == predicted[j]
            if sameTruth && samePrediction { truePositive += 1 }
            else if !sameTruth && samePrediction { falsePositive += 1 }
            else if sameTruth && !samePrediction { falseNegative += 1 }
        }
    }
    let precision = truePositive + falsePositive > 0
        ? Double(truePositive) / Double(truePositive + falsePositive) : 0
    let recall = truePositive + falseNegative > 0
        ? Double(truePositive) / Double(truePositive + falseNegative) : 0
    let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
    let noiseRate = Double(result.noise.count) / Double(max(count, 1))
    let ari = adjustedRandIndex(labels: labels, predicted: predicted)

    return QualityMetrics(
        precision: precision, recall: recall, f1: f1, ari: ari, noiseRate: noiseRate,
        truePositive: truePositive, falsePositive: falsePositive, falseNegative: falseNegative,
        unassigned: unassigned, clusters: result.clusters.count)
}

func formatQuality(_ q: QualityMetrics) -> String {
    String(
        format:
            "p=%.4f r=%.4f f1=%.4f ari=%.4f tp=%d fp=%d fn=%d noise=%.4f clusters=%d unassigned=%d",
        q.precision, q.recall, q.f1, q.ari, q.truePositive, q.falsePositive, q.falseNegative,
        q.noiseRate, q.clusters, q.unassigned)
}

func benchQualityCluster() throws -> [String] {
    validateQualityMetrics()
    var failures: [String] = []
    let dataset = makeQualityEntries(identities: 6, perIdentity: 60, dim: 24, seed: 0xFACE)
    // 阈值 = 当前确定性数据的实测值再留余量；这些下限是默认套件删掉的
    // 统计门的等价物（floor=0.5 必须彻底消除跨身份误合并，floor=0 允许噪声
    // 簇但 ARI/召回不得塌方，任何 floor 都不允许丢点）。
    for floor in [0.0, 0.5] {
        let since = DispatchTime.now()
        let result = try FaceClusterer.clusterEmbeddings(
            entries: dataset.entries, eps: 0.8, minPts: 2,
            coreQualityFloor: floor)
        let duration = elapsedMs(since)
        let metrics = clusterQualityMetric(
            entries: dataset.entries, labels: dataset.labels, result: result)
        check(
            metrics.unassigned == 0,
            "floor=\(floor): \(metrics.unassigned) 个点未被分配（聚类器丢点）", into: &failures)
        if floor > 0 {
            check(
                metrics.falsePositive == 0,
                "floor=\(floor): 跨身份误合并 fp=\(metrics.falsePositive)", into: &failures)
            check(
                metrics.precision >= 0.999,
                "floor=\(floor): precision \(metrics.precision) < 0.999", into: &failures)
            check(
                metrics.ari >= 0.70, "floor=\(floor): ari \(metrics.ari) < 0.70",
                into: &failures)
            check(
                metrics.noiseRate >= 0.15,
                "floor=\(floor): 低质量样本未隔离 noise=\(metrics.noiseRate)", into: &failures)
        } else {
            check(metrics.ari >= 0.60, "floor=0: ari \(metrics.ari) < 0.60", into: &failures)
            check(metrics.recall >= 0.60, "floor=0: recall \(metrics.recall) < 0.60", into: &failures)
            check(metrics.clusters <= 8, "floor=0: clusters \(metrics.clusters) > 8", into: &failures)
        }
        emit(MetricRow(
            benchmark: "face-quality", phase: "cluster-quality",
            size: dataset.entries.count, durationMs: duration,
            throughputPerSec: Double(dataset.entries.count) / max(duration / 1000, 1e-9),
            metric:
                "seed=\(0xFACE) dim=24 identities=6 perIdentity=60 floor=\(floor) eps=0.8 minPts=2 "
                + formatQuality(metrics)))
    }
    return failures
}

// ── margin 扫描（从默认单测迁出）──
// 直接调用生产判定 FaceIdentityPolicy.decide，跑 0 / gap 边界 / 0.01 / 更大 margin；
// 质量曲线用于夜间基线，不进入 PR 门禁。
func benchMarginSweep() -> [String] {
    var failures: [String] = []
    let thresholds = ["P0": 0.6, "P1": 0.6]
    let scores = ["P0": 0.8, "P1": 0.7955]
    let margins: [Double] = [0, 0.0045, 0.0046, 0.005, 0.01, 0.02, 0.04, 0.06, 0.10]
    for margin in margins {
        let since = DispatchTime.now()
        let decision = FaceIdentityPolicy.decide(
            scores: scores, thresholds: thresholds, defaultThreshold: 0.65, margin: margin)
        let duration = elapsedMs(since)
        let label: String
        switch decision {
        case .accepted(let personId, let score):
            label = "accepted:\(personId):\(String(format: "%.4f", score))"
        case .ambiguous:
            label = "ambiguous"
        case .unknown:
            label = "unknown"
        }
        emit(MetricRow(
            benchmark: "face-quality", phase: "margin-sweep", size: 2,
            durationMs: duration,
            throughputPerSec: 0,
            metric: "margin=\(String(format: "%.4f", margin)) gap=0.0045 decision=\(label)"))
        // 边界语义固定：gap == margin 仍接受（严格小于才 ambiguous），
        // 越过 gap 之后必须转 ambiguous，margin 再大不得反转。
        if margin <= 0.0045 {
            check(
                label == "accepted:P0:0.8000",
                "margin=\(margin): 期望 accepted，实际 \(label)", into: &failures)
        } else {
            check(
                label == "ambiguous", "margin=\(margin): 期望 ambiguous，实际 \(label)",
                into: &failures)
        }
    }
    return failures
}

func benchLsh(
    size: Int, seed: UInt32, queries: Int, dim: Int, expectRecall: Bool
) throws -> [String] {
    var failures: [String] = []
    var rand = BenchmarkRandom(seed: seed)
    // 200 个小簇 + 0.30 单位噪声：簇内余弦约 1/1.09 ≈ 0.92（高于 eps=0.85，
    // 保证每个查询都有足够的精确近邻可测召回），同时把 LSH 配成 2 表/probe=1，
    // 使 exactRecall 有机会 < 1（纯随机向量在 128 维几乎互不相邻，测不出召回）。
    let clusterCount = min(200, size)
    let bases = (0..<clusterCount).map { _ in randomUnitVector(dim: dim, rand: &rand) }
    let rows = (0..<size).map { index -> [Float] in
        let base = bases[index % clusterCount]
        let noise = randomUnitVector(dim: dim, rand: &rand)
        return normalizedFloats(zip(base, noise).map { $0 + $1 * 0.30 })
    }
    // 查询 = 索引内随机行（带真实行号，用于自召回判定）。
    let queryRows: [(row: [Float], index: Int)] = (0..<queries).map { _ in
        let index = Int(rand.next() * Double(size))
        return (rows[index], index)
    }

    let sinceBuild = DispatchTime.now()
    let index = try CosineLshIndex(
        dim: dim, config: LshConfig(bits: 16, tables: 2, probeRadius: 1, seed: seed, unitVectors: true))
    var flat: [Float] = []
    flat.reserveCapacity(size * dim)
    for row in rows { flat.append(contentsOf: row) }
    try index.build(rows: flat, count: size)
    let buildMs = elapsedMs(sinceBuild)

    let sinceQuery = DispatchTime.now()
    var hits = 0
    var totalCandidates = 0
    for (q, expectedIndex) in queryRows {
        let candidates = try index.neighbors(query: q, threshold: 0.85)
        totalCandidates += candidates.count
        // 精确重验取最佳（与 FaceMatcher/Clusterer 语义一致）。
        var best = -Double.infinity
        var bestIndex = -1
        for h in 0..<candidates.count {
            let ci = candidates.indices[h]
            let dot = zip(rows[ci], q).reduce(0.0) { acc, pair in
                acc + Double(pair.0) * Double(pair.1)
            }
            if dot > best { best = dot; bestIndex = ci }
        }
        if bestIndex == expectedIndex { hits += 1 }
    }
    // 质量基线：抽少量查询做 exact neighbor 扫描，输出 LSH 召回；不进入 PR 门禁。
    let recallSample = min(queries, size >= 20_000 ? 5 : 20)
    var exactRecallHits = 0
    var exactNeighborTotal = 0
    for queryIndex in 0..<recallSample {
        let q = queryRows[queryIndex].row
        let expectedIndex = queryRows[queryIndex].index
        var exact = Set<Int>()
        for rowIndex in 0..<size where rowIndex != expectedIndex {
            let dot = zip(rows[rowIndex], q).reduce(0.0) { acc, pair in
                acc + Double(pair.0) * Double(pair.1)
            }
            if dot >= 0.85 { exact.insert(rowIndex) }
        }
        let candidates = try index.neighbors(query: q, threshold: 0.85)
        exactRecallHits += exact.intersection(Set(candidates.indices)).count
        exactNeighborTotal += exact.count
    }
    // 无真实近邻时输出 0（而不是 1），避免数据构造错误被误读成完美召回。
    let exactRecall = exactNeighborTotal > 0
        ? Double(exactRecallHits) / Double(exactNeighborTotal) : 0
    let queryMs = elapsedMs(sinceQuery)

    emit(MetricRow(
        benchmark: "similarity", phase: "lsh", size: size,
        durationMs: buildMs + queryMs,
        throughputPerSec: Double(size) / (buildMs / 1000),
        metric: "buildMs=\(String(format: "%.1f", buildMs)) queryMs=\(String(format: "%.1f", queryMs)) selfRecallAt085=\(String(format: "%.4f", Double(hits) / Double(queries))) exactRecallAt085=\(String(format: "%.4f", exactRecall)) exactPairs=\(exactNeighborTotal) exactSample=\(recallSample) avgCandidates=\(String(format: "%.1f", Double(totalCandidates) / Double(queries)))"))

    // 召回下限：小档（--smoke / nightly）断言精确召回与自召回，否则「LSH 退回
    // 空候选」这类退化只会让数字变小而不会失败。大档只做接线非空断言，
    // 避免把 20k/50k 的采样波动当回归。
    check(totalCandidates > 0, "lsh size=\(size): 候选集为空（索引接线错误）", into: &failures)
    if expectRecall {
        check(
            exactNeighborTotal >= 100,
            "lsh size=\(size): 精确近邻只有 \(exactNeighborTotal) 对（数据构造失效）", into: &failures)
        check(
            exactRecall >= 0.45,
            "lsh size=\(size): exactRecall@0.85 \(exactRecall) < 0.45", into: &failures)
        check(
            hits == queries,
            "lsh size=\(size): selfRecall@0.85 \(hits)/\(queries) < 1.0", into: &failures)
    }
    return failures
}

// ── 增量聚类性能/复用门（从默认单测迁出）──
// 语义等价于被删的「2 万张 + 新增 100 张」用例：新增只挂到已有分量上，
// 因此只有被触及的 1 个分量需要重算，其余分量直接复用；耗时上限宽松
// （10s），实际远低于全量重算。
func benchIncrementalCluster(size: Int, added: Int, seed: UInt32) throws -> [String] {
    var failures: [String] = []
    let threshold = 8
    let minGroupSize = 3
    let sinceGen = DispatchTime.now()
    let entries = makeHashEntries(count: size, seed: seed)
    let genMs = elapsedMs(sinceGen)

    let sinceFull = DispatchTime.now()
    let full = try ClusterGraphPipeline.run(
        entries: entries, threshold: threshold, minGroupSize: minGroupSize)
    let fullMs = elapsedMs(sinceFull)
    guard let state = full.state else {
        print("benchmark=similarity error=incremental-missing-state")
        exit(1)
    }

    // 新增条目与第 0 条同 hash（距离 0），只会并入第 0 条所在分量。
    let anchor = entries[0].hash
    var grown = entries
    grown.reserveCapacity(size + added)
    for index in 0..<added {
        grown.append(HashEntry(photoId: "incr-\(index)", hash: anchor))
    }

    let sinceUpdate = DispatchTime.now()
    let outcome = try IncrementalClusterer.update(
        state: state, entries: grown, minGroupSize: minGroupSize, threshold: threshold)
    let updateMs = elapsedMs(sinceUpdate)
    let result = IncrementalClusterer.result(
        state: outcome.state, entries: grown, minGroupSize: minGroupSize)

    emit(MetricRow(
        benchmark: "similarity", phase: "incremental", size: grown.count,
        durationMs: updateMs,
        throughputPerSec: Double(added) / max(updateMs / 1000, 1e-9),
        metric: "genMs=\(String(format: "%.1f", genMs)) fullMs=\(String(format: "%.1f", fullMs)) updateMs=\(String(format: "%.1f", updateMs)) added=\(outcome.summary.addedCount) recomputed=\(outcome.summary.recomputedComponentCount) reused=\(outcome.summary.reusedComponentCount) groups=\(result.groups.count) threshold=\(threshold) minGroupSize=\(minGroupSize)"))

    check(
        outcome.summary.addedCount == added,
        "incremental: added=\(outcome.summary.addedCount) != \(added)", into: &failures)
    check(
        outcome.summary.recomputedComponentCount == 1,
        "incremental: recomputed=\(outcome.summary.recomputedComponentCount)（只有被触及的 1 个分量该重算）",
        into: &failures)
    check(
        outcome.summary.reusedComponentCount >= 1,
        "incremental: reused=\(outcome.summary.reusedComponentCount)（未被触及的分量必须复用）",
        into: &failures)
    check(
        result.groups.count == full.result.groups.count,
        "incremental: 组数 \(result.groups.count) != 全量 \(full.result.groups.count)",
        into: &failures)
    // 新增必须真的并入组：只比组数时「把新增丢进 ungrouped」也会绿。
    let grouped = Set(result.groups.flatMap { $0 })
    let leaked = (0..<added).map { "incr-\($0)" }.filter { !grouped.contains($0) }
    check(
        leaked.isEmpty,
        "incremental: \(leaked.count)/\(added) 条新增未进组（如 \(leaked.prefix(3))）",
        into: &failures)
    let anchorGroup = result.groups.first { $0.contains(entries[0].photoId) }
    check(
        (anchorGroup?.count ?? 0) >= added,
        "incremental: anchor 组只有 \(anchorGroup?.count ?? 0) 条（应 >= 新增 \(added)）",
        into: &failures)
    check(
        result.ungrouped.isEmpty,
        "incremental: ungrouped 非空（\(result.ungrouped.count) 条）", into: &failures)
    check(
        updateMs < 10_000,
        "incremental: 新增 \(added) 张耗时 \(updateMs)ms >= 10000ms", into: &failures)
    return failures
}

// ── 10k 合成人脸档（Cut 5 / 5d-2）──
// 范围：审计 §6.2 item 2 的 B（聚类）与匹配两段。检测/对齐/嵌入需要模型资产，
// bench 无模型，A 段不测（报告里明确写 "no-model"）。
// 数据：50 身份 × 200 样本 × 512 维，单位中心 + 高斯扰动（确定性种子）。
// 聚类路径按构建配置选择并在 metric 里显式标注 path：
//   · release（-c release）：生产在 10k 档的默认路径 = 精确 DBSCAN（默认 LSH 门是
//     20k），10k² × 512 ≈ 5×10¹⁰ 次乘加在此配置可跑（实测约 19s）；
//   · debug（-Onone）：同一精确扫描不可行（分钟级），改跑 LSH 候选路径
//     （bits 12 / tables 2 / probeRadius 0），用于快速回归与内存粗估。
// 两种构建的数字不可互比；metric 的 path=/build= 字段即口径。

/// 合成人脸档的内存粗估（MB）：entries + DBSCAN 平铺 + LSH 行副本 + 桶表 +
/// 匹配库平铺。只计本进程持有的大数组，不含 allocator 碎片/临时数组。
func faceMemoryEstimateMB(
    size: Int, dim: Int, libraryRows: Int, lshTables: Int, lshBits: Int,
    includeLSH: Bool = true, includeFlat: Bool = true
) -> (total: Double, detail: String) {
    let bytesPerMB = 1_048_576.0
    let vectorBytes = Double(size * dim * 4)
    let flatBytes = includeFlat ? vectorBytes : 0
    let lshRowsBytes = includeLSH ? vectorBytes : 0
    let lshTableBytes = includeLSH
        ? Double(lshTables) * (Double((1 << lshBits) + 1) * 8 + Double(size) * 8)
        : 0
    let matcherBytes = Double(libraryRows * dim * 4)
    let total = (vectorBytes + flatBytes + lshRowsBytes + lshTableBytes + matcherBytes) / bytesPerMB
    let detail = String(
        format: "entries=%.1fMB flat=%.1fMB lshRows=%.1fMB tables=%.2fMB matcherFlat=%.1fMB",
        vectorBytes / bytesPerMB, flatBytes / bytesPerMB, lshRowsBytes / bytesPerMB,
        lshTableBytes / bytesPerMB, matcherBytes / bytesPerMB)
    return (total, detail)
}

func benchFaceCluster(entries: [EmbeddingEntry], dim: Int, seed: UInt32, exact: Bool) throws {
    let size = entries.count
    // 512 维下 LSH 的成本主要在"每表 16→12 位 × 每行 512 维"的投影点积；
    // 50 个紧簇（簇内余弦 ≈0.987）用 12 位 × 2 表即可，桶内候选 ~2.4 行/表。
    let bits = 12, tables = 2, probeRadius = 0
    let options = ClusterLshOptions(
        enabled: !exact,
        minPoints: 1_000,
        config: LshConfig(
            bits: bits, tables: tables, probeRadius: probeRadius, seed: seed, unitVectors: true))
    let sinceRun = DispatchTime.now()
    let result = try FaceClusterer.clusterEmbeddings(
        entries: entries, eps: 0.9, minPts: 5, lshOptions: options)
    let runMs = elapsedMs(sinceRun)

    let estimate = exact
        ? faceMemoryEstimateMB(
            size: size, dim: dim, libraryRows: 0, lshTables: 0, lshBits: 0, includeLSH: false)
        : faceMemoryEstimateMB(
            size: size, dim: dim, libraryRows: 0, lshTables: tables, lshBits: bits)
    let groups = result.clusters.count
    let largest = result.clusters.map(\.count).max() ?? 0
    emit(MetricRow(
        benchmark: "face", phase: "face-cluster-10k", size: size,
        durationMs: runMs,
        throughputPerSec: Double(size) / max(runMs / 1000, 1e-9),
        metric: "dim=\(dim) identities=50 path=\(exact ? "exact" : "lsh") build=\(faceBuildName()) bits=\(exact ? 0 : bits) tables=\(exact ? 0 : tables) probeRadius=\(exact ? 0 : probeRadius) eps=0.9 minPts=5 groups=\(groups) largest=\(largest) noise=\(result.noise.count) estPeakMB=\(String(format: "%.1f", estimate.total)) estDetail=\(estimate.detail)"))
}

func benchFaceMatch(entries: [EmbeddingEntry], identities: Int, dim: Int) throws {
    let size = entries.count
    // 库 = 每身份 1 条样本（50 行）；簇 = 每 10 张脸一簇（1,000 簇），
    // 与生产 matchClustersAgainstLibrary 的"人物级中位数"聚合同形。
    let library = (0..<identities).map {
        LibraryEmbedding(personId: "P\($0)", embedding: entries[$0].embedding)
    }
    // 生成器按 i % identities 分身份（样本 s 的下标 = identity + s * identities），
    // 因此同人样本必须按身份取样，不能取连续下标（否则每簇 10 个不同人，
    // 人物级中位数被稀释成 0 → 全部 unknown）。
    let samplesPerIdentity = size / identities
    var clusters: [FaceMatchCluster] = []
    clusters.reserveCapacity((size + 9) / 10)
    var clusterId: Int64 = 1
    for identity in 0..<identities {
        for start in stride(from: 0, to: samplesPerIdentity, by: 10) {
            let end = min(start + 10, samplesPerIdentity)
            let embeddings = (start..<end).map {
                entries[identity + $0 * identities].embedding
            }
            clusters.append(FaceMatchCluster(clusterId: clusterId, embeddings: embeddings))
            clusterId += 1
        }
    }

    let matcher = FaceMatcher(library: library)
    let sinceRun = DispatchTime.now()
    let decisions = try matcher.match(
        clusters: clusters, defaultThreshold: 0.65, margin: 0.01)
    let runMs = elapsedMs(sinceRun)

    let accepted = decisions.filter { $0.personId != nil }.count
    let ambiguous = decisions.filter(\.isAmbiguous).count
    let unknown = decisions.filter(\.isUnknown).count
    let estimate = faceMemoryEstimateMB(
        size: size, dim: dim, libraryRows: library.count, lshTables: 0, lshBits: 0,
        includeLSH: false, includeFlat: false)
    emit(MetricRow(
        benchmark: "face", phase: "face-match-10k", size: size,
        durationMs: runMs,
        throughputPerSec: Double(size) / max(runMs / 1000, 1e-9),
        metric: "dim=\(dim) clusters=\(clusters.count) libraryRows=\(library.count) matched=\(accepted) ambiguous=\(ambiguous) unknown=\(unknown) lsh=off estPeakMB=\(String(format: "%.1f", estimate.total)) estDetail=\(estimate.detail)"))
}

/// 构建配置与聚类路径：release 才跑精确 10k DBSCAN（-Onone 下的 O(n²) 精确扫描
/// 是分钟级，debug 改跑 LSH 候选）。两函数避免在字符串插值里直接写常量条件
/// （-Onone 也会对 `_isDebugAssertConfiguration()` 做常量折叠并告警不可达分支）。
@inline(never)
func benchmarkIsDebugBuild() -> Bool { _isDebugAssertConfiguration() }

func faceBuildName() -> String { benchmarkIsDebugBuild() ? "debug" : "release" }

func faceClusterUsesExact() -> Bool { !benchmarkIsDebugBuild() }

func benchFace10k(size: Int, dim: Int, identities: Int, seed: UInt32) throws {
    let sinceGen = DispatchTime.now()
    let entries = makeEmbeddings(
        count: size, dim: dim, seed: seed, perturb: 0.005, clusters: identities)
    let genMs = elapsedMs(sinceGen)
    let exact = faceClusterUsesExact()
    print("benchmark=face phase=generate size=\(size) dim=\(dim) genMs=\(String(format: "%.1f", genMs)) build=\(faceBuildName()) clusterPath=\(exact ? "exact" : "lsh") aStage=skipped(no-model)")
    try benchFaceCluster(entries: entries, dim: dim, seed: seed, exact: exact)
    try benchFaceMatch(entries: entries, identities: identities, dim: dim)
}

// ── 入口 ──
// margin 扫描：从默认单测迁出的生产判定曲线；夜间跑。
if CommandLine.arguments.contains("--margin") {
    let failures = benchMarginSweep()
    print("benchmark=face-quality phase=margin-sweep doneMs=\(Int(elapsedMs(start)))")
    reportChecks("face-quality", failures)
}

// 质量基线：从默认单测迁出的合成聚类 P/R/F1/noise；夜间跑。
if CommandLine.arguments.contains("--quality") {
    let failures: [String]
    do {
        failures = try benchQualityCluster()
    } catch {
        print("benchmark=face-quality error=\(error)")
        exit(1)
    }
    print("benchmark=face-quality doneMs=\(Int(elapsedMs(start)))")
    reportChecks("face-quality", failures)
}

// 增量聚类档（性能 + 复用门）：从默认单测迁出，夜间保留 2 万张规模。
if CommandLine.arguments.contains("--incremental") {
    let failures: [String]
    do {
        failures = try benchIncrementalCluster(size: 20_000, added: 100, seed: 0xD4A5)
    } catch {
        print("benchmark=similarity error=\(error)")
        exit(1)
    }
    print("benchmark=similarity phase=incremental doneMs=\(Int(elapsedMs(start)))")
    reportChecks("similarity", failures)
}

// 10k 合成人脸显式档（Cut 5 / 5d-2）：不进默认档/冒烟档，避免日常基准变慢。
if CommandLine.arguments.contains("--face-10k") {
    do {
        try benchFace10k(size: 10_000, dim: 512, identities: 50, seed: 0xFACE10)
    } catch {
        print("benchmark=face error=\(error)")
        exit(1)
    }
    print("benchmark=face doneMs=\(Int(elapsedMs(start)))")
    exit(0)
}

// 多档位单趟基准（§4.2 P1 性能证据）：只跑该阶段并以非零码报告结果不一致。
if CommandLine.arguments.contains("--multi-bench") {
    do {
        for size in [2_000, 20_000] {
            try benchDHashClusterMulti(size: size, seed: 0xD4A5)
        }
    } catch {
        print("benchmark=similarity error=\(error)")
        exit(1)
    }
    print("benchmark=similarity phase=dhash-cluster-multi doneMs=\(Int(elapsedMs(start)))")
    exit(0)
}

let smoke = CommandLine.arguments.contains("--smoke")
let sizes: [Int] = smoke ? [2_000] : [20_000, 50_000]
let queries = smoke ? 20 : 100

print("benchmark=similarity sizes=\(sizes) queries=\(queries) startMs=\(Int(elapsedMs(start)))")

var similarityFailures: [String] = []
do {
    for size in sizes {
        try benchDHashCluster(size: size, seed: 0xD4A5)
    }
    for size in sizes {
        // 2 万档强制 LSH（minPoints=1000），5 万档走默认门（20_000，自动 LSH）。
        try benchEmbeddingCluster(size: size, seed: 0xB1E2, lshMinPoints: smoke ? 100 : 1_000)
    }
    for size in sizes {
        similarityFailures += try benchLsh(
            size: size, seed: 0x15EED, queries: queries, dim: 128, expectRecall: smoke)
    }
} catch {
    print("benchmark=similarity error=\(error)")
    exit(1)
}

print("benchmark=similarity doneMs=\(Int(elapsedMs(start)))")
reportChecks("similarity", similarityFailures)

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
//   .build/debug/gather-core-benchmarks --face-10k     # 10k 合成人脸（显式档；debug 走 LSH，
//                                                      #   -c release 走生产默认的精确 DBSCAN）
import Foundation
import GatherAnalysis

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

func benchLsh(size: Int, seed: UInt32, queries: Int, dim: Int) throws {
    var rand = BenchmarkRandom(seed: seed)
    let rows = (0..<size).map { _ -> [Float] in
        let raw = (0..<dim).map { _ in rand.gaussian() }
        let norm = raw.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        return raw.map { Float(norm > 0 ? $0 / norm : 0) }
    }
    // 查询 = 索引内随机行（带真实行号，用于自召回判定）。
    let queryRows: [(row: [Float], index: Int)] = (0..<queries).map { _ in
        let index = Int(rand.next() * Double(size))
        return (rows[index], index)
    }

    let sinceBuild = DispatchTime.now()
    let index = try CosineLshIndex(
        dim: dim, config: LshConfig(bits: 16, tables: 6, probeRadius: 2, seed: seed, unitVectors: true))
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
    let queryMs = elapsedMs(sinceQuery)

    emit(MetricRow(
        benchmark: "similarity", phase: "lsh", size: size,
        durationMs: buildMs + queryMs,
        throughputPerSec: Double(size) / (buildMs / 1000),
        metric: "buildMs=\(String(format: "%.1f", buildMs)) queryMs=\(String(format: "%.1f", queryMs)) selfRecallAt085=\(String(format: "%.4f", Double(hits) / Double(queries))) avgCandidates=\(String(format: "%.1f", Double(totalCandidates) / Double(queries)))"))
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

do {
    for size in sizes {
        try benchDHashCluster(size: size, seed: 0xD4A5)
    }
    for size in sizes {
        // 2 万档强制 LSH（minPoints=1000），5 万档走默认门（20_000，自动 LSH）。
        try benchEmbeddingCluster(size: size, seed: 0xB1E2, lshMinPoints: smoke ? 100 : 1_000)
    }
    for size in sizes {
        try benchLsh(size: size, seed: 0x15EED, queries: queries, dim: 128)
    }
} catch {
    print("benchmark=similarity error=\(error)")
    exit(1)
}

print("benchmark=similarity doneMs=\(Int(elapsedMs(start)))")

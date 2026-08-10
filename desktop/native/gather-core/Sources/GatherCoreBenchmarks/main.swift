// desktop/native/gather-core/Sources/GatherCoreBenchmarks/main.swift
// Similarity 基准（计划 2.3 验收：2 万/5 万通过）。
// 覆盖四类算法负载：dHash 聚类（ClusterEngine）、embedding 聚类
// （FaceClusterer，LSH 路径）、HNSW 建索引+查询 recall、LSH 建索引+查询 recall。
// 数据全部确定性生成（固定种子，不入库），输出 NDJSON 行（对齐
// scripts/application-scale-benchmark.mjs 的 stdout JSON 行风格）。
// 用法：
//   .build/debug/gather-core-benchmarks            # 2 万/5 万两档全量
//   .build/debug/gather-core-benchmarks --smoke    # 2 千冒烟档
import Foundation
import GatherCore

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

/// embedding：50 正交簇中心（Gram-Schmidt）+ 高斯扰动，128 维。
/// 扰动按维度缩放：σ=0.005 下 128 维行距离 ≈0.057，归一化后簇内点积 ≈0.998（>eps 0.9）。
func makeEmbeddings(count: Int, dim: Int, seed: UInt32, perturb: Double = 0.005) -> [EmbeddingEntry] {
    var rand = BenchmarkRandom(seed: seed)
    let clusterCount = 50

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

/// 暴力 topK（参照实现，余弦降序）。
func bruteForceTopK(
    _ rows: [[Float]], query: [Float], k: Int
) -> [Int] {
    let scores = rows.enumerated().map { index, row -> (Int, Double) in
        let dot = zip(row, query).reduce(0.0) { acc, pair in
            acc + Double(pair.0) * Double(pair.1)
        }
        return (index, dot)
    }
    let sorted = scores.sorted { a, b in
        a.1 > b.1 || (a.1 == b.1 && a.0 < b.0)
    }
    return sorted.prefix(k).map { $0.0 }
}

// ── 基准项 ──
func benchDHashCluster(size: Int, seed: UInt32) throws {
    let since = DispatchTime.now()
    let entries = makeHashEntries(count: size, seed: seed)
    let gen = elapsedMs(since)

    let sinceRun = DispatchTime.now()
    let result = try ClusterEngine.clusterByHash(
        entries: entries, threshold: 8, minGroupSize: 3, mode: .global)
    let runMs = elapsedMs(sinceRun)

    emit(MetricRow(
        benchmark: "similarity", phase: "dhash-cluster", size: size,
        durationMs: runMs,
        throughputPerSec: Double(size) / (runMs / 1000),
        metric: "genMs=\(String(format: "%.1f", gen)) groups=\(result.groups.count) ungrouped=\(result.ungrouped.count)"))
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

func benchHnsw(size: Int, seed: UInt32, queries: Int, dim: Int) throws {
    var rand = BenchmarkRandom(seed: seed)
    let rows = (0..<size).map { _ -> [Float] in
        let raw = (0..<dim).map { _ in rand.gaussian() }
        let norm = raw.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        return raw.map { Float(norm > 0 ? $0 / norm : 0) }
    }
    let queryRows = (0..<queries).map { _ in rows[Int(rand.next() * Double(size))] }

    let sinceBuild = DispatchTime.now()
    let index = try CosineHnswIndex(config: HnswConfig(dim: dim))
    for row in rows {
        _ = try index.insert(row)
    }
    let buildMs = elapsedMs(sinceBuild)

    let sinceQuery = DispatchTime.now()
    var hits = 0
    for q in queryRows {
        let top = try index.searchTopK(query: q, k: 10)
        let expected = bruteForceTopK(rows, query: q, k: 10)
        let topSet = Set(top.indices)
        let hit = expected.prefix(1).contains { topSet.contains($0) }
        if hit { hits += 1 }
    }
    let queryMs = elapsedMs(sinceQuery)

    emit(MetricRow(
        benchmark: "similarity", phase: "hnsw", size: size,
        durationMs: buildMs + queryMs,
        throughputPerSec: Double(size) / (buildMs / 1000),
        metric: "buildMs=\(String(format: "%.1f", buildMs)) queryMs=\(String(format: "%.1f", queryMs)) recallAt1=\(String(format: "%.4f", Double(hits) / Double(queries))) queries=\(queries)"))
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

// ── 入口 ──
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
        try benchHnsw(size: size, seed: 0xC0A1, queries: queries, dim: 128)
    }
    for size in sizes {
        try benchLsh(size: size, seed: 0x15EED, queries: queries, dim: 128)
    }
} catch {
    print("benchmark=similarity error=\(error)")
    exit(1)
}

print("benchmark=similarity doneMs=\(Int(elapsedMs(start)))")

// desktop/native/gather-core/Sources/GatherAnalysis/Face/VectorIndex.swift
// 余弦向量 ANN 索引（Phase 2 任务 2.3「向量移植」）。
//
// Cut 5 / 5b-2a：HNSW（CosineHnswIndex 471 行 + HnswConfig/HnswHits +
// FaceVector）整段删除——生产引用 0，且在 2k 冒烟基准里占 93% 时间（CL-06）。
// 本文件只剩角度 LSH（生产在用：Clusterer.swift 的候选生成、Matcher.swift
// 的候选复核），TS 参照实现 desktop/src/main/services/face-kw/lsh-index.ts
// （114-345），各函数行号见注释。
//
// 语义要点（与 TS 逐位一致）：
//   - 余弦即原始点积：行/查询必须是单位向量，由调用方保证归一化。
//   - 数值语义：向量按 Float 存储（等价 Float32Array），点积按 TS 逐项顺序
//     累加（每 4 维一组展开，同 lsh-index.ts:99-110），乘积与累加全程 Double
//     （等价 TS 的 Float32Array 读值 + JS number 双精度运算）。IEEE-754 双精度
//     算术跨语言确定，故同输入下结果与 TS 位级一致。
//   - 随机性：LSH 超平面（lsh-index.ts:150-157）来自固定种子 mulberry32
//     （lsh-index.ts:62-71），Swift 按 UInt32 逐位复刻，同种子产出同哈希。
//     超平面经 Box-Muller 高斯（lsh-index.ts:73-78），其中 cos/log 为 libm
//     函数，跨平台存在 1 ulp 级差异的理论风险——只会影响哈希边界行的桶归属，
//     对召回门限无实质影响（VectorIndexReconciliationTests 的 LSH 断言按召回比对）。
//   - 评分写回 hits 时收敛到 Float（等价 TS 的 Float32Array 存储语义，
//     verifyCandidates：lsh-index.ts:340-342）。
//   - 偏差：
//     - TS 的 LshHits 是指向索引自有 scratch 数组的视图（下次调用前有效）；
//       Swift 每次调用返回新数组（值语义，无失效窗口）。
//     - TS build(rows) 借用调用方缓冲（`this.rows = rows`，lsh-index.ts:183）；
//       Swift 按值复制（行为等价，调用方可随时释放原数组）。
//     - TS 校验失败抛字符串消息；Swift 抛类型化 VectorIndexError。

import Foundation

// MARK: - Angular LSH

/// LSH 配置（TS lsh-index.ts:21-46，默认值同 DEFAULT_LSH_CONFIG）。
public struct LshConfig: Equatable, Sendable {
    /// 每表哈希位数；每表桶数为 2^bits。
    public var bits: Int
    /// 独立哈希表数量。
    public var tables: Int
    /// 多探针半径：同时探测距查询桶 `probeRadius` 次汉明翻转内的桶。
    public var probeRadius: Int
    /// 超平面生成的确定性种子。
    public var seed: UInt32
    /// 为 true 时已索引行是单位向量（聚类管线已归一化），精确校验直接
    /// 比原始点积；为 false 时计算完整余弦（含幅值），与历史 person-matcher
    /// 语义一致（TS lsh-index.ts:31-37）。
    public var unitVectors: Bool

    public static let `default` = LshConfig()

    public init(
        bits: Int = 16,
        tables: Int = 6,
        probeRadius: Int = 2,
        seed: UInt32 = 0xF4CE0B5E,
        unitVectors: Bool = false
    ) {
        self.bits = bits
        self.tables = tables
        self.probeRadius = probeRadius
        self.seed = seed
        self.unitVectors = unitVectors
    }
}

/// LSH 候选结果（TS lsh-index.ts:54-60）。Swift 为每次调用新数组（值语义），
/// 无 TS 的 scratch 失效窗口。
public struct LshHits: Equatable, Sendable {
    public let count: Int
    /// 候选行下标（指向已建索引的扁平数组）。
    public let indices: [Int]
    /// 与 indices 对齐的精确余弦（或单位向量点积）。
    public let scores: [Float]

    public init(count: Int, indices: [Int], scores: [Float]) {
        self.count = count
        self.indices = indices
        self.scores = scores
    }
}

/// Angular LSH（随机投影 / SimHash）索引（TS CosineLshIndex，lsh-index.ts:114-286）。
/// 向量按其在随机高斯超平面上的投影符号哈希；每张表独立超平面集，多探针
/// 恢复余弦阈值低至 ~0.6 的召回。候选一律经精确余弦复核，假阳性不可能
/// 泄漏进结果——LSH 只会*收缩*候选集（TS lsh-index.ts:9-12）。
public final class CosineLshIndex {
    /// 超过此行数走 ANN 路径而非 O(n^2) 全扫描（TS lsh-index.ts:49 LSH_MIN_POINTS）。
    public static let lshMinPoints = 20_000

    public let config: LshConfig
    public let dim: Int

    private var planes: [[Float]] = []
    private let probeMasks: [UInt32]

    private var count = 0
    private var rows: [Float] = []
    /// 每表：buckets+1 前缀和（桶 b 的区间 [starts[b], starts[b+1])）。
    private var starts: [[Int]] = []
    /// 每表：按桶排布的成员行号。
    private var members: [[Int]] = []

    // TS:132-157（校验同 TS；每表种子 = seed ^ imul(t+1, 0x9e3779b9)）
    public init(dim: Int, config: LshConfig = .default) throws {
        guard dim > 0 else {
            throw VectorIndexError.invalidDimension(dim)
        }
        guard (6...22).contains(config.bits) else {
            throw VectorIndexError.invalidBits(config.bits)
        }
        guard config.tables >= 1 else {
            throw VectorIndexError.invalidTables(config.tables)
        }
        guard (0...2).contains(config.probeRadius) else {
            throw VectorIndexError.invalidProbeRadius(config.probeRadius)
        }
        self.dim = dim
        self.config = config
        self.probeMasks = Self.buildProbeMasks(bits: config.bits, radius: config.probeRadius)

        for t in 0..<config.tables {
            var rand = Mulberry32(seed: config.seed ^ (UInt32(t + 1) &* 0x9E3779B9))
            var plane = [Float](repeating: 0, count: config.bits * dim)
            for i in 0..<plane.count {
                plane[i] = Float(gaussian(&rand))
            }
            planes.append(plane)
        }
    }

    public var size: Int { count }

    // TS:81-90（probeRadius <= 2；全 0 + 单比特 + 双比特掩码）
    private static func buildProbeMasks(bits: Int, radius: Int) -> [UInt32] {
        var masks: [UInt32] = [0]
        for i in 0..<bits { masks.append(UInt32(1) << UInt32(i)) }
        if radius >= 2 {
            for i in 0..<bits {
                for j in (i + 1)..<bits {
                    masks.append((UInt32(1) << UInt32(i)) | (UInt32(1) << UInt32(j)))
                }
            }
        }
        return masks
    }

    // TS:163-173
    private func hashRow(_ plane: [Float], row: [Float], rowOffset: Int) -> UInt32 {
        var hash: UInt32 = 0
        for k in 0..<config.bits {
            let base = k * dim
            let dot = vectorDot(plane, base, row, rowOffset, dim)
            if dot >= 0 { hash |= UInt32(1) << UInt32(k) }
        }
        return hash
    }

    /// 对行主序扁平数组的每行哈希并建桶表（TS lsh-index.ts:176-219）。
    public func build(rows: [Float], count: Int) throws {
        guard rows.count == count * dim else {
            throw VectorIndexError.buildShapeMismatch(
                rows: rows.count,
                expected: count * dim)
        }
        self.count = count
        self.rows = rows
        let buckets = 1 << config.bits
        self.starts = []
        self.members = []
        for t in 0..<config.tables {
            let plane = planes[t]
            var hashes = [UInt32](repeating: 0, count: count)
            for i in 0..<count {
                hashes[i] = hashRow(plane, row: rows, rowOffset: i * dim)
            }

            var counts = [Int](repeating: 0, count: buckets)
            for i in 0..<count { counts[Int(hashes[i])] += 1 }

            var tableStarts = [Int](repeating: 0, count: buckets + 1)
            var acc = 0
            for b in 0..<buckets {
                tableStarts[b] = acc
                acc += counts[b]
            }
            tableStarts[buckets] = acc

            var tableMembers = [Int](repeating: 0, count: count)
            var cursor = tableStarts
            for i in 0..<count {
                let bucket = Int(hashes[i])
                tableMembers[cursor[bucket]] = i
                cursor[bucket] += 1
            }
            starts.append(tableStarts)
            members.append(tableMembers)
        }
    }

    /// 返回与查询行精确余弦（或单位向量点积）>= `threshold` 的全部行，
    /// 跨全部表的所有探测桶去重（TS lsh-index.ts:229-285）。查询可位于
    /// 索引内部（聚类）或独立缓冲（匹配）；queryOffset 为浮点偏移。
    public func neighbors(query: [Float], queryOffset: Int = 0, threshold: Double) throws -> LshHits {
        if count == 0 {
            return LshHits(count: 0, indices: [], scores: [])
        }
        guard query.count - queryOffset >= dim else {
            throw VectorIndexError.queryShapeMismatch(
                expected: dim,
                received: query.count - queryOffset)
        }
        guard !rows.isEmpty else {
            throw VectorIndexError.indexNotBuilt
        }

        var visited = [Bool](repeating: false, count: count)
        var candidates: [Int] = []
        candidates.reserveCapacity(count)
        for t in 0..<config.tables {
            let hash = hashRow(planes[t], row: query, rowOffset: queryOffset)
            let tableStarts = starts[t]
            let tableMembers = members[t]
            for mask in probeMasks {
                let bucket = Int(hash ^ mask)
                let from = tableStarts[bucket]
                let to = tableStarts[bucket + 1]
                for p in from..<to {
                    let candidate = tableMembers[p]
                    if visited[candidate] { continue }
                    visited[candidate] = true
                    candidates.append(candidate)
                }
            }
        }
        // 候选去重后按行号升序（TS:270 `candidates.subarray(...).sort()`，
        // Uint32Array 默认数值排序）。
        candidates.sort()

        return verifyCandidates(query: query, queryOffset: queryOffset, candidates: candidates, threshold: threshold)
    }

    // TS:291-344（verifyCandidates；分数收敛到 Float）
    private func verifyCandidates(
        query: [Float],
        queryOffset: Int,
        candidates: [Int],
        threshold: Double
    ) -> LshHits {
        var hitIndices: [Int] = []
        var hitScores: [Float] = []
        hitIndices.reserveCapacity(candidates.count)
        hitScores.reserveCapacity(candidates.count)
        for candidate in candidates {
            let rowOffset = candidate * dim
            let score: Double
            if config.unitVectors {
                score = vectorDot(query, queryOffset, rows, rowOffset, dim)
                if score < threshold { continue }
            } else {
                // 检索数学的唯一实现：直接在连续缓冲上按偏移展开，避免每个候选分配
                // FaceVector 数组（性能关键路径）。语义与已删除的 FaceVector 工具方法
                // 不同：长度固定 `dim`（不截断）、零幅值候选 `continue` 跳过。
                var dot = 0.0
                var magQ = 0.0
                var magR = 0.0
                var k = 0
                while k + 4 <= dim {
                    let q0 = Double(query[queryOffset + k])
                    let q1 = Double(query[queryOffset + k + 1])
                    let q2 = Double(query[queryOffset + k + 2])
                    let q3 = Double(query[queryOffset + k + 3])
                    let r0 = Double(rows[rowOffset + k])
                    let r1 = Double(rows[rowOffset + k + 1])
                    let r2 = Double(rows[rowOffset + k + 2])
                    let r3 = Double(rows[rowOffset + k + 3])
                    dot += q0 * r0 + q1 * r1 + q2 * r2 + q3 * r3
                    magQ += q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3
                    magR += r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3
                    k += 4
                }
                while k < dim {
                    let q = Double(query[queryOffset + k])
                    let r = Double(rows[rowOffset + k])
                    dot += q * r
                    magQ += q * q
                    magR += r * r
                    k += 1
                }
                if magQ == 0 || magR == 0 { continue }
                score = dot / (sqrt(magQ) * sqrt(magR))
                if score < threshold { continue }
            }
            hitIndices.append(candidate)
            hitScores.append(Float(score))
        }
        return LshHits(count: hitIndices.count, indices: hitIndices, scores: hitScores)
    }
}

// MARK: - 错误

public enum VectorIndexError: Error, Equatable {
    case invalidDimension(Int)
    case invalidBits(Int)
    case invalidTables(Int)
    case invalidProbeRadius(Int)
    case queryShapeMismatch(expected: Int, received: Int)
    case buildShapeMismatch(rows: Int, expected: Int)
    case indexNotBuilt
}

// MARK: - 共享底层（文件私有）

/// 堆候选（id + 余弦距离）。
private struct Candidate {
    var id: Int
    var dist: Double
}

/// mulberry32 固定种子 PRNG（TS lsh-index.ts:62-71）。
///
/// TS 的 `>>>`（无符号右移）、`Math.imul`（低 32 位乘积）与 `^`/`|`（按位）
/// 在 UInt32 上逐位等价：
///   - `t >>> s` ≡ UInt32 的 `>>`（零填充）；
///   - `Math.imul(x, y)` 的低 32 位 ≡ UInt32 的 `&*`（回绕乘法）；
///   - `x ^ y` / `x | y` 对负数（ToInt32 表示）与 UInt32 位模式一致；
///   - `t + imul`（JS double 加法，幅值 < 2^32 精确）≡ UInt32 `&+`（模 2^32）。
/// 故本实现与 TS 输出逐位一致。
private struct Mulberry32 {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t = t ^ (t &+ ((t ^ (t >> 7)) &* (t | 61)))
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

// TS lsh-index.ts:73-78（Box-Muller；u==0 时重抽）
private func gaussian(_ rand: inout Mulberry32) -> Double {
    var u = 0.0
    repeat { u = rand.next() } while u == 0
    let v = rand.next()
    return sqrt(-2 * log(u)) * cos(2 * .pi * v)
}

/// 点积（TS lsh-index.ts:92-112）：Float32
/// 值读入、Double 乘积与累加，每 4 维一组展开，运算顺序与 TS 逐项一致。
private func vectorDot(_ a: [Float], _ aOffset: Int, _ b: [Float], _ bOffset: Int, _ dim: Int) -> Double {
    var dot = 0.0
    var k = 0
    while k + 4 <= dim {
        dot += Double(a[aOffset + k]) * Double(b[bOffset + k])
             + Double(a[aOffset + k + 1]) * Double(b[bOffset + k + 1])
             + Double(a[aOffset + k + 2]) * Double(b[bOffset + k + 2])
             + Double(a[aOffset + k + 3]) * Double(b[bOffset + k + 3])
        k += 4
    }
    while k < dim {
        dot += Double(a[aOffset + k]) * Double(b[bOffset + k])
        k += 1
    }
    return dot
}

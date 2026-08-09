// desktop/native/gather-core/Sources/GatherCore/Face/VectorIndex.swift
// 余弦向量 ANN 索引移植（Phase 2 任务 2.3「向量移植」）。
//
// TS 源（各函数行号见注释）：
//   desktop/src/main/services/face-kw/hnsw-index.ts —— CosineHnswIndex（91-534）
//   desktop/src/main/services/face-kw/lsh-index.ts  —— CosineLshIndex（114-345）
//
// 语义要点（与 TS 逐位一致）：
//   - HNSW 的“余弦”即原始点积：行/查询必须是单位向量（TS 注释
//     hnsw-index.ts:17-19），由调用方保证归一化（face-clusterer 在喂给
//     LSH 前做归一化）。
//   - 数值语义：向量按 Float 存储（等价 Float32Array 存储），点积按 TS
//     逐项顺序累加（每 4 维一组展开，同 hnsw-index.ts:78-87 /
//     lsh-index.ts:99-110），乘积与累加全程 Double（等价 TS 的
//     Float32Array 读值 + JS number 双精度运算）。IEEE-754 双精度算术
//     跨语言确定，故同输入下结果与 TS 位级一致。
//   - 随机性：TS 不使用 Math.random；HNSW 层级分配（hnsw-index.ts:460-466）
//     与 LSH 超平面（lsh-index.ts:150-157）全部来自固定种子 mulberry32
//     （hnsw-index.ts:58-67 / lsh-index.ts:62-71），Swift 按 UInt32 逐位
//     复刻（见 Mulberry32 注释），同种子产出同图/同哈希。LSH 超平面经
//     Box-Muller 高斯（lsh-index.ts:73-78），其中 cos/log 为 libm 函数，
//     跨平台存在 1 ulp 级差异的理论风险——只会影响哈希边界行的桶归属，
//     对召回门限无实质影响（VectorIndexReconciliationTests 的 LSH 断言
//     按召回比对，见该文件说明）。
//   - 评分写回 hits 时收敛到 Float（等价 TS 的 Float32Array 存储语义，
//     toHits：hnsw-index.ts:223-231；verifyCandidates：lsh-index.ts:340-342）。
//   - 偏差：
//     - TS 的 HnswHits/LshHits 是指向索引自有 scratch 数组的视图（下次
//       调用前有效）；Swift 每次调用返回新数组（值语义，无失效窗口）。
//     - TS build(rows) 借用调用方缓冲（`this.rows = rows`，lsh-index.ts:183）；
//       Swift 按值复制（行为等价，调用方可随时释放原数组）。
//     - TS 校验失败抛字符串消息；Swift 抛类型化 VectorIndexError。

import Foundation

// MARK: - 基础类型

/// 一条人脸嵌入向量（Float32 语义，等价 TS 的 Float32Array 行）。
public struct FaceVector: Equatable, Sendable {
    public var values: [Float]

    public init(values: [Float]) {
        self.values = values
    }

    /// 点积（TS hnsw-index.ts:69-89 同序累加：Float32 值读入、Double 累加）。
    public func dot(_ other: FaceVector) -> Double {
        let n = min(values.count, other.values.count)
        var dot = 0.0
        var k = 0
        while k + 4 <= n {
            dot += Double(values[k]) * Double(other.values[k])
                 + Double(values[k + 1]) * Double(other.values[k + 1])
                 + Double(values[k + 2]) * Double(other.values[k + 2])
                 + Double(values[k + 3]) * Double(other.values[k + 3])
            k += 4
        }
        while k < n {
            dot += Double(values[k]) * Double(other.values[k])
            k += 1
        }
        return dot
    }

    /// 余弦相似度（TS lsh-index.ts:307-338 非单位向量路径：
    /// dot / (sqrt(magQ) * sqrt(magR))，同序计算）。单位向量时与点积一致。
    /// 任一向量零幅值时返回 0（对应 TS verifyCandidates 跳过零向量行）。
    public func cosineSimilarity(to other: FaceVector) -> Double {
        let n = min(values.count, other.values.count)
        var dot = 0.0
        var magQ = 0.0
        var magR = 0.0
        var k = 0
        while k + 4 <= n {
            let q0 = Double(values[k])
            let q1 = Double(values[k + 1])
            let q2 = Double(values[k + 2])
            let q3 = Double(values[k + 3])
            let r0 = Double(other.values[k])
            let r1 = Double(other.values[k + 1])
            let r2 = Double(other.values[k + 2])
            let r3 = Double(other.values[k + 3])
            dot += q0 * r0 + q1 * r1 + q2 * r2 + q3 * r3
            magQ += q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3
            magR += r0 * r0 + r1 * r1 + r2 * r2 + r3 * r3
            k += 4
        }
        while k < n {
            let q = Double(values[k])
            let r = Double(other.values[k])
            dot += q * r
            magQ += q * q
            magR += r * r
            k += 1
        }
        if magQ == 0 || magR == 0 { return 0 }
        return dot / (sqrt(magQ) * sqrt(magR))
    }
}

// MARK: - HNSW

/// HNSW 配置（TS hnsw-index.ts:24-50，默认值同 DEFAULT_HNSW_CONFIG）。
public struct HnswConfig: Equatable, Sendable {
    /// 向量维度；必须与每条插入行一致。
    public var dim: Int
    /// 非底层每层邻居数。
    public var m: Int
    /// 底层邻居数上限（>= m）。
    public var mMax0: Int
    /// 插入期候选池大小。
    public var efConstruction: Int
    /// 查询期候选池大小。
    public var efSearch: Int
    /// 层级分配的确定性种子。
    public var seed: UInt32

    public static let `default` = HnswConfig()

    public init(
        dim: Int = 512,
        m: Int = 16,
        mMax0: Int = 64,
        efConstruction: Int = 32,
        efSearch: Int = 32,
        seed: UInt32 = 0x5eEDCAFE
    ) {
        self.dim = dim
        self.m = m
        self.mMax0 = mMax0
        self.efConstruction = efConstruction
        self.efSearch = efSearch
        self.seed = seed
    }
}

/// HNSW 搜索结果（TS hnsw-index.ts:52-56：count + Uint32Array + Float32Array）。
public struct HnswHits: Equatable, Sendable {
    public let count: Int
    public let indices: [Int]
    public let scores: [Float]

    public init(count: Int, indices: [Int], scores: [Float]) {
        self.count = count
        self.indices = indices
        self.scores = scores
    }
}

/// 增量余弦 ANN 索引（TS CosineHnswIndex，hnsw-index.ts:91-534）。
/// 图结构逐步维护，插入只触碰邻域、永不整库重建。
public final class CosineHnswIndex {
    public let config: HnswConfig

    private let dim: Int
    private var vectors: [Float]
    private var capacity: Int
    private var count = 0
    private var levels: [UInt8]
    /// [node][level] -> 邻居 id 列表（level 可能超过节点自身层级时为空，
    /// 对应 TS 的 `neighbors[id][level] ?? []`）。
    private var neighbors: [[[Int]]] = []
    private var maxLevel = 0
    private var entryPoint = -1
    private let mL: Double
    private var rand: Mulberry32

    // TS:104-124（校验信息同 TS；种子原样传入 mulberry32）
    public init(config: HnswConfig = .default) throws {
        guard config.dim > 0 else {
            throw VectorIndexError.invalidDimension(config.dim)
        }
        guard config.m >= 1, config.mMax0 >= config.m else {
            throw VectorIndexError.invalidNeighborCounts(m: config.m, mMax0: config.mMax0)
        }
        guard config.efConstruction >= config.m, config.efSearch >= 1 else {
            throw VectorIndexError.invalidEF(efConstruction: config.efConstruction, efSearch: config.efSearch)
        }
        self.config = config
        self.dim = config.dim
        self.capacity = 1024
        self.vectors = [Float](repeating: 0, count: self.capacity * self.dim)
        self.levels = [UInt8](repeating: 0, count: self.capacity)
        self.mL = 1 / log(Double(config.m))
        self.rand = Mulberry32(seed: config.seed)
    }

    public var size: Int { count }

    /// 对账测试专用（@testable）：导出各节点层级，fixture 校验 PRNG 确定性。
    internal var debugLevels: [Int] {
        (0..<count).map { Int(levels[$0]) }
    }

    /// 插入一行（复制进索引）并返回其 id（TS hnsw-index.ts:134-189）。
    @discardableResult
    public func insert(_ vector: [Float]) throws -> Int {
        guard vector.count == dim else {
            throw VectorIndexError.dimensionMismatch(expected: dim, received: vector.count)
        }
        if count == capacity { growCapacity() }
        let id = count
        vectors.replaceSubrange(id * dim..<(id + 1) * dim, with: vector)
        count += 1

        let level = randomLevel()
        levels[id] = UInt8(level)
        var nodeNeighbors: [[Int]] = []
        for _ in 0...level { nodeNeighbors.append([]) }
        neighbors.append(nodeNeighbors)

        if entryPoint == -1 {
            entryPoint = id
            maxLevel = level
            return id
        }

        // 自顶层下探至 level+1，然后逐层向下链接（TS:157-183）。
        var ep = entryPoint
        var epDist = vectorDot(vectors, ep * dim, vectors, id * dim, dim)
        if level < maxLevel {
            for l in stride(from: maxLevel, to: level, by: -1) {
                ep = greedyStep(ep: ep, targetId: id, level: l)
                epDist = vectorDot(vectors, ep * dim, vectors, id * dim, dim)
            }
        }
        for l in stride(from: min(level, maxLevel), through: 0, by: -1) {
            let targetOffset = id * dim
            var visited = Set<Int>()
            let candidates = searchLayerFrom(
                vectors, targetOffset,
                entryPoints: [Candidate(id: ep, dist: epDist)],
                ef: config.efConstruction,
                level: l,
                visited: &visited)
            let limit = l == 0 ? config.mMax0 : config.m
            for candidateId in selectNeighbors(candidates, limit: limit) where candidateId != id {
                linkBoth(candidateId, id, level: l)
            }
        }
        if level > maxLevel {
            maxLevel = level
            entryPoint = id
        }
        return id
    }

    /// 返回与查询行精确余弦 >= `threshold` 的全部行，按得分降序
    /// （TS hnsw-index.ts:196-209）。查询可位于索引内部（聚类）或
    /// 独立缓冲（匹配）。
    public func searchByThreshold(query: [Float], queryOffset: Int = 0, threshold: Double) throws -> HnswHits {
        let scratch = try searchScratch(query: query, queryOffset: queryOffset, ef: config.efSearch)
        var hits: [Candidate] = []
        for s in scratch where s.dist >= threshold {
            hits.append(s)
        }
        return toHits(hits)
    }

    /// 返回 k 个最近行（按精确余弦），不受阈值限制（TS hnsw-index.ts:214-221）。
    public func searchTopK(query: [Float], queryOffset: Int = 0, k: Int) throws -> HnswHits {
        let scratch = try searchScratch(query: query, queryOffset: queryOffset, ef: max(k, config.efSearch))
        var hits: [Candidate] = []
        for s in scratch where hits.count < k {
            hits.append(s)
        }
        return toHits(hits)
    }

    // TS:223-231（分数收敛到 Float，等价 Float32Array 存储）
    private func toHits(_ hits: [Candidate]) -> HnswHits {
        var indices: [Int] = []
        var scores: [Float] = []
        indices.reserveCapacity(hits.count)
        scores.reserveCapacity(hits.count)
        for hit in hits {
            indices.append(hit.id)
            scores.append(Float(hit.dist))
        }
        return HnswHits(count: hits.count, indices: indices, scores: scores)
    }

    // TS:237-256（共享搜索管线：贪心下探 + 有界候选堆）
    private func searchScratch(query: [Float], queryOffset: Int, ef: Int) throws -> [Candidate] {
        if entryPoint == -1 { return [] }
        guard query.count - queryOffset >= dim else {
            throw VectorIndexError.queryShapeMismatch(
                expected: dim,
                received: query.count - queryOffset)
        }
        var visited = Set<Int>()
        var ep = entryPoint
        if maxLevel > 0 {
            for l in stride(from: maxLevel, to: 0, by: -1) {
                ep = greedyStepFrom(ep: ep, level: l, query: query, queryOffset: queryOffset)
            }
        }
        let epDist = vectorDot(query, queryOffset, vectors, ep * dim, dim)
        return searchLayerFrom(
            query, queryOffset,
            entryPoints: [Candidate(id: ep, dist: epDist)],
            ef: ef,
            level: 0,
            visited: &visited)
    }

    // TS:258-275
    private func greedyStep(ep: Int, targetId: Int, level: Int) -> Int {
        let targetOffset = targetId * dim
        var current = ep
        var bestDist = vectorDot(vectors, current * dim, vectors, targetOffset, dim)
        var changed = true
        while changed {
            changed = false
            for neighbor in neighbors(of: current, at: level) {
                let dist = vectorDot(vectors, neighbor * dim, vectors, targetOffset, dim)
                if dist > bestDist {
                    bestDist = dist
                    current = neighbor
                    changed = true
                }
            }
        }
        return current
    }

    // TS:277-293
    private func greedyStepFrom(ep: Int, level: Int, query: [Float], queryOffset: Int) -> Int {
        var current = ep
        var bestDist = vectorDot(query, queryOffset, vectors, current * dim, dim)
        var changed = true
        while changed {
            changed = false
            for neighbor in neighbors(of: current, at: level) {
                let dist = vectorDot(query, queryOffset, vectors, neighbor * dim, dim)
                if dist > bestDist {
                    bestDist = dist
                    current = neighbor
                    changed = true
                }
            }
        }
        return current
    }

    // TS:302-371。candidates 为按余弦取大的最大堆（最近者先出），results
    // 为按余弦取小的最小堆（最远者堆顶，超过 ef 截断）；"dist" 即余弦点积，
    // 越大越近。
    private func searchLayerFrom(
        _ query: [Float],
        _ qOffset: Int,
        entryPoints: [Candidate],
        ef: Int,
        level: Int,
        visited: inout Set<Int>
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var results: [Candidate] = []

        for ep in entryPoints {
            visited.insert(ep.id)
            candidates.append(ep)
            siftMaxUp(&candidates, candidates.count - 1)
            results.append(ep)
            siftMinUp(&results, results.count - 1)
        }

        while !candidates.isEmpty {
            let candidate = popMax(&candidates)
            // 最远结果是最小堆根；最佳剩余候选比它更差即无法再改进（TS:352-354）。
            if candidate.dist < results[0].dist { break }

            for neighbor in neighbors(of: candidate.id, at: level) {
                if visited.contains(neighbor) { continue }
                visited.insert(neighbor)
                let dist = vectorDot(query, qOffset, vectors, neighbor * dim, dim)
                if results.count < ef || dist > results[0].dist {
                    pushMax(&candidates, Candidate(id: neighbor, dist: dist))
                    pushMin(&results, Candidate(id: neighbor, dist: dist))
                    if results.count > ef { popMin(&results) }
                }
            }
        }
        // 最近 `ef` 行，按余弦降序返回（TS:368-370 稳定排序；Swift 侧以
        // 原堆序下标为并列决胜键复刻稳定语义，见注释）。
        return results.enumerated()
            .sorted {
                $0.element.dist == $1.element.dist
                    ? $0.offset < $1.offset
                    : $0.element.dist > $1.element.dist
            }
            .map(\.element)
    }

    // TS:380-407（多样性：与已选邻居太近的候选跳过；缓存距离表）
    private func selectNeighbors(_ candidates: [Candidate], limit: Int) -> [Int] {
        if candidates.count <= limit {
            return candidates.map(\.id)
        }
        var selected: [Int] = []
        for candidate in candidates {
            if selected.count >= limit { break }
            var diverse = true
            let candidateOffset = candidate.id * dim
            for s in selected {
                let sOffset = s * dim
                let toSelected = vectorDot(vectors, sOffset, vectors, candidateOffset, dim)
                if toSelected > candidate.dist {
                    diverse = false
                    break
                }
            }
            if diverse { selected.append(candidate.id) }
        }
        for candidate in candidates where selected.count < limit && !selected.contains(candidate.id) {
            selected.append(candidate.id)
        }
        return selected
    }

    // TS:414-418
    private func linkBoth(_ a: Int, _ b: Int, level: Int) {
        let cap = level == 0 ? config.mMax0 : config.m
        linkOneWay(from: a, to: b, level: level, cap: cap)
        linkOneWay(from: b, to: a, level: level, cap: cap)
    }

    // TS:420-425（from 的层级必然 >= level，与 TS 相同的不变式）
    private func linkOneWay(from: Int, to: Int, level: Int, cap: Int) {
        neighbors[from][level].append(to)
        if neighbors[from][level].count > cap {
            var list = neighbors[from][level]
            pruneNeighbors(from: from, list: &list, cap: cap)
            neighbors[from][level] = list
        }
    }

    // TS:427-458（先按到 from 的距离排序，再多样性筛选；复刻 TS 稳定排序）
    private func pruneNeighbors(from: Int, list: inout [Int], cap: Int) {
        let fromOffset = from * dim
        let ranked = list
            .map { Candidate(id: $0, dist: vectorDot(vectors, fromOffset, vectors, $0 * dim, dim)) }
            .enumerated()
            .sorted {
                $0.element.dist == $1.element.dist
                    ? $0.offset < $1.offset
                    : $0.element.dist > $1.element.dist
            }
            .map(\.element)
        var selected: [Int] = []
        for candidate in ranked {
            if selected.count >= cap { break }
            var diverse = true
            let candidateOffset = candidate.id * dim
            for s in selected {
                let sOffset = s * dim
                let toSelected = vectorDot(vectors, sOffset, vectors, candidateOffset, dim)
                if toSelected > candidate.dist {
                    diverse = false
                    break
                }
            }
            if diverse { selected.append(candidate.id) }
        }
        for candidate in ranked where selected.count < cap && !selected.contains(candidate.id) {
            selected.append(candidate.id)
        }
        list = selected
    }

    // TS:460-466。层级分布 P(level >= k) = exp(-k * ln M)，以几何分布实现。
    // 注意 rand() 先于 level < 16 求值（与 TS 短路顺序一致，保持 PRNG 流同步）。
    private func randomLevel() -> Int {
        var level = 0
        while rand.next() < exp(-1 / mL) && level < 16 {
            level += 1
        }
        return level
    }

    // TS:468-477
    private func growCapacity() {
        let next = capacity * 2
        var grownVectors = [Float](repeating: 0, count: next * dim)
        grownVectors.replaceSubrange(0..<vectors.count, with: vectors)
        vectors = grownVectors
        var grownLevels = [UInt8](repeating: 0, count: next)
        grownLevels.replaceSubrange(0..<levels.count, with: levels)
        levels = grownLevels
        capacity = next
    }

    /// 节点在指定层级的邻居列表；节点层级不足时为空
    /// （对应 TS `neighbors[id][level] ?? []`，hnsw-index.ts:265/283/356）。
    private func neighbors(of node: Int, at level: Int) -> [Int] {
        let nodeLevels = neighbors[node]
        guard level < nodeLevels.count else { return [] }
        return nodeLevels[level]
    }

    // TS:480-489（候选最大堆：最大余弦先出）
    private func siftMaxUp(_ heap: inout [Candidate], _ index: Int) {
        var index = index
        while index > 0 {
            let parent = (index - 1) >> 1
            if heap[parent].dist >= heap[index].dist { break }
            heap.swapAt(parent, index)
            index = parent
        }
    }

    // TS:491-505
    private func siftMaxDown(_ heap: inout [Candidate], _ index: Int) {
        var index = index
        let n = heap.count
        while true {
            let left = index * 2 + 1
            if left >= n { break }
            let right = left + 1
            var best = left
            if right < n && heap[right].dist > heap[left].dist { best = right }
            if heap[index].dist >= heap[best].dist { break }
            heap.swapAt(best, index)
            index = best
        }
    }

    // TS:508-517（结果最小堆：最远/最差余弦在堆顶）
    private func siftMinUp(_ heap: inout [Candidate], _ index: Int) {
        var index = index
        while index > 0 {
            let parent = (index - 1) >> 1
            if heap[parent].dist <= heap[index].dist { break }
            heap.swapAt(parent, index)
            index = parent
        }
    }

    // TS:519-533
    private func siftMinDown(_ heap: inout [Candidate], _ index: Int) {
        var index = index
        let n = heap.count
        while true {
            let left = index * 2 + 1
            if left >= n { break }
            let right = left + 1
            var worst = left
            if right < n && heap[right].dist < heap[left].dist { worst = right }
            if heap[index].dist <= heap[worst].dist { break }
            heap.swapAt(worst, index)
            index = worst
        }
    }

    // TS:327-335（popCandidate）
    @discardableResult
    private func popMax(_ heap: inout [Candidate]) -> Candidate {
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            siftMaxDown(&heap, 0)
        }
        return top
    }

    // TS:336-348（pushResult / popResult）
    private func pushMin(_ heap: inout [Candidate], _ candidate: Candidate) {
        heap.append(candidate)
        siftMinUp(&heap, heap.count - 1)
    }

    @discardableResult
    private func popMin(_ heap: inout [Candidate]) -> Candidate {
        let worst = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            siftMinDown(&heap, 0)
        }
        return worst
    }

    private func pushMax(_ heap: inout [Candidate], _ candidate: Candidate) {
        heap.append(candidate)
        siftMaxUp(&heap, heap.count - 1)
    }
}

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
    case invalidNeighborCounts(m: Int, mMax0: Int)
    case invalidEF(efConstruction: Int, efSearch: Int)
    case invalidBits(Int)
    case invalidTables(Int)
    case invalidProbeRadius(Int)
    case dimensionMismatch(expected: Int, received: Int)
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

/// mulberry32 固定种子 PRNG（TS hnsw-index.ts:58-67 / lsh-index.ts:62-71）。
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

/// 点积（TS hnsw-index.ts:69-89 / lsh-index.ts:92-112，同一实现）：Float32
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

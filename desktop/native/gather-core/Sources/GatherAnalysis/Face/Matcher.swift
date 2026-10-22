// desktop/native/gather-core/Sources/GatherAnalysis/Face/Matcher.swift
// 人脸 → 人物库匹配器移植（Phase 2 任务 2.3「face-matcher 移植」）。
//
// TS 源：
//   desktop/src/main/services/face-kw/face-matcher.ts（类实现 25-125 行，
//   精确路径 cosineSimilarity 127-142 行）
//
// 语义要点（与 TS 逐位一致）：
//   - 库大小 <= lshMinPoints（默认 CosineLshIndex.lshMinPoints = 20_000，
//     lsh-index.ts:49）走全量精确扫描（face-matcher.ts:103-121）；> 阈值走
//     CosineLshIndex 桶候选 + 精确余弦重验（face-matcher.ts:78-101）。LSH
//     只会收缩候选集（候选一律经精确余弦复核），故 precision 与暴力一致，
//     召回门限见 face-clusterer-lsh.test.ts（>= 0.95）。
//   - LSH 路径余弦由 CosineLshIndex 内部 verifyCandidates 计算：默认配置
//     unitVectors=false（lsh-index.ts:31-37，历史 person-matcher 语义），得分
//     收敛到 Float（等价 Float32Array 存储语义）；匹配择优为严格大于
//     （score > bestScore，face-matcher.ts:89），并列取先出现者。阈值含等号
//     （lsh-index.ts:338 `score < threshold` 剔除）。
//   - 精确路径的余弦按 face-matcher.ts:127-142 逐项顺序累加（非 4 维展开，
//     与 LSH 路径 verifyCandidates 的展开循环是两种浮点顺序）——Swift 侧
//     同样分别实现，与 TS 同序，避免阈值边界位级翻转风险。
//   - MATCH_MARGIN（本次新增，PhotoPrism 同义）：best >= threshold 且
//     best - second >= margin 才匹配；best >= threshold 但差距不足则记入
//     ambiguous（歧义不猜，既不匹配也不算未命中）。second 只在「达阈候选」中求：
//     精确路径取 score >= threshold 的行，LSH 路径取 neighbors(threshold:) 的命中
//     （只返回 >= 阈值的候选）——两路径判定一致。margin <= 0 时完全跳过 second
//     （默认 0 ⇒ 与旧行为逐位一致，并列仍取先出现者）。
//   - 空库：全部查询进 unmatched（face-matcher.ts:71-76）。
//   - 数据源解耦：TS 构造注入 PersonRepository、首次匹配经 getAllEmbeddings()
//     惰性取数（face-matcher.ts:36-55）；Swift 版本由调用方直接喂入嵌入数组
//     （init(library:)），对接 PersonRepo 的方式见文件末尾「数据源对接」。
//   - 偏差：
//     - TS 库行来自 DB blob（Buffer → Float32Array 视图，face-matcher.ts:41）；
//       Swift 为 [Float] 值语义。
//     - TS 对 LSH 分支库内各行维度不一致时 flat.set 越界静默截断/错位
//       （face-matcher.ts:47-49）；Swift 显式抛 MatcherError（文档化改进）。
//     - TS 校验失败抛字符串消息；Swift 抛类型化 MatcherError。
//   - Cut 5 / 5c-1 批量 API：`match(clusters:library:thresholds:defaultThreshold:margin:)`
//     一次准备库快照与行范数（实例路径复用首次准备的平铺缓冲），逐查询仍按库行
//     顺序、逐项累加 ⇒ 与 bestScoresPerPerson 逐位一致；为保证这一点，批量路径
//     **不**做 LSH 候选收缩（候选子集可能漏掉某人的最佳行）。
//     每簇成员/feedback 的读取与 rejected 集合由调用方（FaceKwService）一次批量算好。
//   - Cut 5 / 5d-2：批量 API **不再**为实例库建 LSH（旧实现借 loadLibrary 顺带建索引，
//     纯浪费内存/建索引时间）；LSH 只服务实例级逐查询 API `matchAgainstLibrary`。
//     `lshMinPoints` 参数保留：> 阈值时才为批量路径准备平铺缓冲（候选收缩仍不用），
//     并为 `matchAgainstLibrary` 保留同一 LSH 门。

import Foundation
import GatherProtocol

// MARK: - 基础类型

/// 库中一条人脸嵌入（TS face-matcher.ts:4-7 LibraryEmbedding）。
public struct LibraryEmbedding: Equatable, Sendable {
    public let personId: String
    public let embedding: [Float]

    public init(personId: String, embedding: [Float]) {
        self.personId = personId
        self.embedding = embedding
    }
}

/// 一次匹配结果（TS face-matcher.ts:9-12 PersonMatch）。
public struct PersonMatch: Equatable, Sendable {
    public let personId: String
    public let confidence: Double

    public init(personId: String, confidence: Double) {
        self.personId = personId
        self.confidence = confidence
    }
}

/// matchAgainstLibrary 的返回（TS face-matcher.ts:63-66：
/// { matched: Map<number, PersonMatch>, unmatched: number[] }）。
/// matched 的键是查询下标；ambiguous 为本次新增的歧义查询下标（按查询顺序）。
public struct FaceMatchResult: Equatable, Sendable {
    public let matched: [Int: PersonMatch]
    public let unmatched: [Int]
    /// best >= threshold 但 best - second < margin 的查询下标（歧义不猜）。
    /// 默认空数组：既有的 matched/unmatched 二元调用点零改动。
    public let ambiguous: [Int]

    public init(matched: [Int: PersonMatch], unmatched: [Int], ambiguous: [Int] = []) {
        self.matched = matched
        self.unmatched = unmatched
        self.ambiguous = ambiguous
    }
}

// MARK: - 批量匹配类型（Cut 5 / 5c-1）

/// 批量匹配的一簇输入：簇 id、该簇的查询向量、该簇被人工拒绝的人物集合。
/// 拒绝集合/成员/feedback 由调用方**一次**读完并算好（见
/// FaceKwService.matchClustersAgainstLibrary）——批量 API 不回读 DB，这是消除
/// 「每簇 2 次查询」N+1 的边界。
public struct FaceMatchCluster: Sendable, Equatable {
    public let clusterId: Int64
    public let embeddings: [[Float]]
    /// 该簇被 rejected 的人物（成员 bbox 与反馈 bbox 重叠 ≥ 0.5 才计入；
    /// 与旧逐簇路径的 rejected 过滤同义）。
    public let excludedPersonIds: Set<String>

    public init(clusterId: Int64, embeddings: [[Float]], excludedPersonIds: Set<String> = []) {
        self.clusterId = clusterId
        self.embeddings = embeddings
        self.excludedPersonIds = excludedPersonIds
    }
}

/// 批量匹配的一簇决策。直接复用 `FaceIdentityPolicy.Decision` 三态（accepted /
/// ambiguous / unknown），不在 Matcher 侧再造一套判定规则；聚合口径（人物级
/// 样本分中位数）在 `match(clusters:...)` 内。簇顺序与输入一致。
public struct FaceMatchDecision: Sendable, Equatable {
    public let clusterId: Int64
    public let decision: FaceIdentityPolicy.Decision

    public init(clusterId: Int64, decision: FaceIdentityPolicy.Decision) {
        self.clusterId = clusterId
        self.decision = decision
    }

    public var personId: String? {
        guard case let .accepted(personId, _) = decision else { return nil }
        return personId
    }

    public var confidence: Double? {
        guard case let .accepted(_, score) = decision else { return nil }
        return score
    }

    public var isAmbiguous: Bool { decision == .ambiguous }
    public var isUnknown: Bool { decision == .unknown }
}

public enum MatcherError: Error, Equatable {
    /// 向量长度不匹配（TS 字符串消息 "Vector length mismatch: X vs Y"，
    /// face-matcher.ts:82/129；expected=库维度/库行维度，received=查询维度）。
    case vectorLengthMismatch(expected: Int, received: Int)
}

// MARK: - FaceMatcher

/// 人脸 → 人物库匹配器（TS face-matcher.ts:25-125）。实例级逐查询 API
/// `matchAgainstLibrary` 在库 <= lshMinPoints 时全量精确扫描；超过时共享
/// CosineLshIndex：跨表多探针桶并集候选 + 精确余弦重验，precision 与暴力一致
/// （LSH 只会收缩候选集）。批量 API `match(clusters:...)` 恒走精确扫描，从不建
/// LSH——它的候选收缩会漏掉人物最佳行，且对账要求逐位一致（Cut 5 / 5d-2）。
public final class FaceMatcher {
    private let libraryEmbeddings: [LibraryEmbedding]
    public let lshMinPoints: Int

    private var libraryFlat: [Float]?
    private var lshIndex: CosineLshIndex?
    private var libraryDim = 0
    /// 行维度已校验（> lshMinPoints 时平铺缓冲也已就绪）。批量路径只要求这一状态，
    /// 不要求 LSH；`matchAgainstLibrary` 再按需补建索引。
    private var libraryRowsPrepared = false
    /// 实例库的行范数平方（magB）缓存：批量路径只按库行顺序累加一次，与
    /// cosineSimilarity 的 magB 累加顺序相同（同序 ⇒ 位级同值）。
    private var libraryNorms: [Double]?

    /// 注入式构造：调用方喂入完整库（等价 TS 构造注入 PersonRepository 后
    /// loadLibrary() 惰性取数的结果）。
    public init(library: [LibraryEmbedding], lshMinPoints: Int = CosineLshIndex.lshMinPoints) {
        self.libraryEmbeddings = library
        self.lshMinPoints = lshMinPoints
    }

    /// 行维度校验 +（超过 lshMinPoints 时）一次性平铺缓冲。**不建 LSH**：批量路径
    /// 也复用它（平铺改善扫描局部性，但与候选收缩无关）。
    private func prepareLibraryRows() throws {
        if libraryRowsPrepared { return }
        if libraryEmbeddings.count > lshMinPoints {
            libraryDim = libraryEmbeddings[0].embedding.count
            var flat = [Float](repeating: 0, count: libraryEmbeddings.count * libraryDim)
            for i in 0..<libraryEmbeddings.count {
                let row = libraryEmbeddings[i].embedding
                guard row.count == libraryDim else {
                    // 偏差（文档化改进）：TS flat.set 越界时静默截断/错位
                    //（face-matcher.ts:47-49）；Swift 显式失败。
                    throw MatcherError.vectorLengthMismatch(expected: libraryDim, received: row.count)
                }
                flat.replaceSubrange(i * libraryDim..<(i + 1) * libraryDim, with: row)
            }
            libraryFlat = flat
        }
        libraryRowsPrepared = true
    }

    // TS face-matcher.ts:36-55（loadLibrary）：惰性加载库并按规模决定路径。
    // Swift 侧库数据由构造注入，此处只做首次建索引（索引随实例生命周期存在，
    // 重建需重新构造实例，语义与 TS 一致）。**唯一**建 LSH 的入口是实例级
    // `matchAgainstLibrary`；批量 API 只调 prepareLibraryRows（Cut 5 / 5d-2）。
    private func loadLibrary() throws -> [LibraryEmbedding] {
        try prepareLibraryRows()
        if lshIndex == nil, libraryEmbeddings.count > lshMinPoints, let flat = libraryFlat {
            let index = try CosineLshIndex(dim: libraryDim)
            try index.build(rows: flat, count: libraryEmbeddings.count)
            lshIndex = index
        }
        return libraryEmbeddings
    }

    /// 测试/诊断用：实例是否已建 LSH 索引。批量 API 必须保持 false；只有
    /// `matchAgainstLibrary`（且库 > lshMinPoints）会把它置 true。
    var hasLSHIndex: Bool { lshIndex != nil }

    // 择优折叠：best 的选取与旧实现完全相同（起点 0.0、严格大于、并列取先出现者），
    // 同时记录次优达阈候选 secondScore（无则 nil）。candidateFloor 是「可计为歧义竞争者
    // 的最低分」：精确路径传 threshold（达阈才算竞争者），LSH 路径传 -infinity
    // （hits 已被 neighbors(threshold:) 按阈值过滤，命中即候选）。
    private struct Ranking {
        var bestIndex = -1
        var bestScore = 0.0
        var secondScore: Double?

        mutating func consider(index: Int, score: Double, candidateFloor: Double) {
            if score > bestScore {
                if bestIndex >= 0 && bestScore >= candidateFloor {
                    secondScore = max(secondScore ?? -Double.infinity, bestScore)
                }
                bestScore = score
                bestIndex = index
            } else if score >= candidateFloor {
                secondScore = max(secondScore ?? -Double.infinity, score)
            }
        }
    }

    // 决定一个查询的去向：margin > 0 且存在与 best 差距 < margin 的达阈竞争者 →
    // ambiguous（不猜）；否则 matched。margin <= 0 时短路、完全不看 secondScore ⇒
    // 与引入 margin 前的匹配结果逐位一致。
    private static func recordOutcome(
        queryIndex: Int,
        bestPersonId: String,
        ranking: Ranking,
        margin: Double,
        matched: inout [Int: PersonMatch],
        ambiguous: inout [Int]
    ) {
        if margin > 0, let second = ranking.secondScore, ranking.bestScore - second < margin {
            ambiguous.append(queryIndex)
        } else {
            matched[queryIndex] = PersonMatch(personId: bestPersonId, confidence: ranking.bestScore)
        }
    }

    /// 按人物聚合的最佳相似度（人物 id → 该人全部样本中的最高分）。
    /// 用途：歧义 margin 需要"人物级亚军"——`matchAgainstLibrary` 每个查询只返回
    /// 单一最佳**行**，而库里同一人常有多条样本，无法据此判断亚军人物。
    /// 余弦语义与精确扫描路径一致（逐项顺序累加，非 4 维展开）。
    public static func bestScoresPerPerson(
        query: [Float],
        library: [LibraryEmbedding]
    ) throws -> [String: Double] {
        var best: [String: Double] = [:]
        for row in library {
            let score = try cosineSimilarity(query, row.embedding)
            if score > (best[row.personId] ?? -.infinity) {
                best[row.personId] = score
            }
        }
        return best
    }

    // MARK: - 批量 API（Cut 5 / 5c-1：库一次、范数一次；5d-2：不建 LSH）

    /// 批量扫描的库快照。范数在构造时按行、按同一 `for i in 0..<n` 顺序累加一次。
    /// `flat` 只在库 > lshMinPoints（prepareLibraryRows 已建平铺缓冲）时非空；两种
    /// 来源的行序与数值完全相同，逐行回退到 `rows[j].embedding`。
    private struct LibrarySnapshot {
        let rows: [LibraryEmbedding]
        let flat: [Float]?
        let dim: Int
        let counts: [Int]
        let norms: [Double]

        init(rows: [LibraryEmbedding], flat: [Float]?, norms: [Double]) {
            self.rows = rows
            self.counts = rows.map { $0.embedding.count }
            let dim = rows.first?.embedding.count ?? 0
            let uniform = rows.allSatisfy { $0.embedding.count == dim }
            self.dim = dim
            self.flat = uniform && dim > 0 && flat?.count == rows.count * dim ? flat : nil
            self.norms = norms
        }
    }

    /// 行范数平方：与 cosineSimilarity 的 magB 同一累加顺序（逐项、Double）。
    private static func rowNorms(_ library: [LibraryEmbedding]) -> [Double] {
        var norms = [Double](repeating: 0, count: library.count)
        for rowIndex in 0..<library.count {
            let row = library[rowIndex].embedding
            var magnitude = 0.0
            for i in 0..<row.count {
                let value = Double(row[i])
                magnitude += value * value
            }
            norms[rowIndex] = magnitude
        }
        return norms
    }

    /// 解析本次批量的库快照。
    /// - `library == nil`：用实例库，`prepareLibraryRows()` 只做首次行校验/平铺
    ///   （> lshMinPoints 时；**不建 LSH**），范数首次算完后缓存在实例上。即使实例
    ///   之前因 `matchAgainstLibrary` 建过索引，批量也从不使用该索引。
    /// - 显式传入：用该快照，范数在本次调用内预计算一次（不建平铺、不建 LSH）。
    private func librarySnapshot(_ library: [LibraryEmbedding]?) throws -> LibrarySnapshot {
        guard let library else {
            try prepareLibraryRows()
            let rows = libraryEmbeddings
            let norms: [Double]
            if let cached = libraryNorms {
                norms = cached
            } else {
                norms = Self.rowNorms(rows)
                libraryNorms = norms
            }
            return LibrarySnapshot(rows: rows, flat: libraryFlat, norms: norms)
        }
        return LibrarySnapshot(rows: library, flat: nil, norms: Self.rowNorms(library))
    }

    /// 单行得分：dot 逐项顺序累加（与 cosineSimilarity 同序），范数用预计算值。
    /// queryNorm/rowNorm 任一为 0 → 0（face-matcher.ts:140 的同一短路）。
    private static func score(
        query: [Float],
        queryNorm: Double,
        rowIndex: Int,
        snapshot: LibrarySnapshot
    ) -> Double {
        let count = snapshot.counts[rowIndex]
        var dot = 0.0
        if let flat = snapshot.flat {
            let base = rowIndex * snapshot.dim
            for i in 0..<count {
                dot += Double(query[i]) * Double(flat[base + i])
            }
        } else {
            let embedding = snapshot.rows[rowIndex].embedding
            for i in 0..<count {
                dot += Double(query[i]) * Double(embedding[i])
            }
        }
        let rowNorm = snapshot.norms[rowIndex]
        if queryNorm == 0 || rowNorm == 0 { return 0 }
        return dot / (sqrt(queryNorm) * sqrt(rowNorm))
    }

    /// 批量逐查询 per-person 最佳分。与逐条调用
    /// `bestScoresPerPerson(query:library:)` **逐位相同**：同一库行顺序、同一
    /// 逐项累加顺序、同一零向量短路、同一维度错误触发点；区别只是库范数只算一次。
    public func bestScoresPerPerson(
        queries: [[Float]],
        library: [LibraryEmbedding]? = nil
    ) throws -> [[String: Double]] {
        let snapshot = try librarySnapshot(library)
        return try bestScoresPerPerson(queries: queries, snapshot: snapshot)
    }

    private func bestScoresPerPerson(
        queries: [[Float]],
        snapshot: LibrarySnapshot
    ) throws -> [[String: Double]] {
        var results: [[String: Double]] = []
        results.reserveCapacity(queries.count)
        for query in queries {
            var queryNorm = 0.0
            for i in 0..<query.count {
                let value = Double(query[i])
                queryNorm += value * value
            }
            var best: [String: Double] = [:]
            for rowIndex in 0..<snapshot.rows.count {
                guard snapshot.counts[rowIndex] == query.count else {
                    // 与 bestScoresPerPerson 的 guard 同参数、同一触发点（行序）。
                    throw MatcherError.vectorLengthMismatch(
                        expected: snapshot.counts[rowIndex], received: query.count)
                }
                let score = Self.score(
                    query: query, queryNorm: queryNorm, rowIndex: rowIndex, snapshot: snapshot)
                let personId = snapshot.rows[rowIndex].personId
                if score > (best[personId] ?? -Double.infinity) {
                    best[personId] = score
                }
            }
            results.append(best)
        }
        return results
    }

    /// 批量匹配（Cut 5 / 5c-1）：一次准备库快照/范数（实例路径只做行校验/平铺，
    /// **不建 LSH**），簇循环内不再触碰库或 DB。每簇聚合口径与旧
    /// `FaceKwService.matchClustersAgainstLibrary` 逐簇路径完全相同：
    /// 人物级样本分 → 中位数 → `FaceIdentityPolicy.decide`（thresholds =
    /// persons.match_threshold，缺省 defaultThreshold，margin 同义）。
    ///
    /// 数值一致性：每个查询的候选累加顺序与 `bestScoresPerPerson(query:library:)`
    /// 完全相同 ⇒ 结果逐位一致（MatcherReconciliationTests / FaceMatcherBatchTests
    /// 守门）。因此批量路径**不**用 LSH 收缩候选：候选子集可能漏掉某人的最佳行，
    /// 无法与对账基准位级对齐（LSH 仍服务实例级逐查询 API `matchAgainstLibrary`）。
    public func match(
        clusters: [FaceMatchCluster],
        library: [LibraryEmbedding]? = nil,
        thresholds: [String: Double] = [:],
        defaultThreshold: Double = 0.65,
        margin: Double = 0
    ) throws -> [FaceMatchDecision] {
        guard !clusters.isEmpty else { return [] }
        let snapshot = try librarySnapshot(library)
        var decisions: [FaceMatchDecision] = []
        decisions.reserveCapacity(clusters.count)
        for cluster in clusters {
            var scores: [String: [Double]] = [:]
            for best in try bestScoresPerPerson(queries: cluster.embeddings, snapshot: snapshot) {
                for (personId, score) in best where !cluster.excludedPersonIds.contains(personId) {
                    scores[personId, default: []].append(score)
                }
            }
            // 与旧路径同一中位数（逐人样本分升序；偶数取中间两数均值）。
            let aggregate = scores.mapValues { values -> Double in
                let sorted = values.sorted()
                let middle = sorted.count / 2
                return sorted.count % 2 == 0
                    ? (sorted[middle - 1] + sorted[middle]) / 2
                    : sorted[middle]
            }
            decisions.append(FaceMatchDecision(
                clusterId: cluster.clusterId,
                decision: FaceIdentityPolicy.decide(
                    scores: aggregate,
                    thresholds: thresholds,
                    defaultThreshold: defaultThreshold,
                    margin: margin)))
        }
        return decisions
    }

    // TS face-matcher.ts:63-124（matchAgainstLibrary：查询批对库匹配）。
    // margin（PhotoPrism MATCH_MARGIN 同义）：best >= threshold 且 best - second >= margin
    // 才匹配；best >= threshold 但差距不足 → ambiguous；否则 unmatched。
    public func matchAgainstLibrary(
        _ embeddings: [[Float]],
        threshold: Double,
        margin: Double = 0
    ) throws -> FaceMatchResult {
        let library = try loadLibrary()
        var matched: [Int: PersonMatch] = [:]
        var unmatched: [Int] = []
        var ambiguous: [Int] = []

        // 空库：全部查询进 unmatched（face-matcher.ts:71-76）
        if library.isEmpty {
            for i in 0..<embeddings.count { unmatched.append(i) }
            return FaceMatchResult(matched: matched, unmatched: unmatched)
        }

        if let lshIndex, libraryFlat != nil {
            // LSH 路径（face-matcher.ts:78-101）：桶并集候选已按阈值过滤，
            // 择优 score > bestScore、并列取先出现者；第二高分只在命中中求
            // （neighbors(threshold:) 只返回 >= 阈值的候选）。
            for i in 0..<embeddings.count {
                let inputEmb = embeddings[i]
                guard inputEmb.count == libraryDim else {
                    throw MatcherError.vectorLengthMismatch(expected: libraryDim, received: inputEmb.count)
                }
                let hits = try lshIndex.neighbors(query: inputEmb, queryOffset: 0, threshold: threshold)
                var ranking = Ranking()
                for h in 0..<hits.count {
                    ranking.consider(
                        index: hits.indices[h],
                        score: Double(hits.scores[h]),
                        candidateFloor: -Double.infinity)
                }
                if ranking.bestIndex >= 0 {
                    Self.recordOutcome(
                        queryIndex: i,
                        bestPersonId: library[ranking.bestIndex].personId,
                        ranking: ranking,
                        margin: margin,
                        matched: &matched,
                        ambiguous: &ambiguous)
                } else {
                    unmatched.append(i)
                }
            }
            return FaceMatchResult(matched: matched, unmatched: unmatched, ambiguous: ambiguous)
        }

        // 精确扫描路径（face-matcher.ts:103-121）；次优候选取 score >= threshold 的行，
        // 与 LSH 路径的「达阈命中」同语义。
        for i in 0..<embeddings.count {
            let inputEmb = embeddings[i]
            var ranking = Ranking()
            for j in 0..<library.count {
                let score = try Self.cosineSimilarity(inputEmb, library[j].embedding)
                ranking.consider(index: j, score: score, candidateFloor: threshold)
            }
            if ranking.bestIndex >= 0, ranking.bestScore >= threshold,
                !library[ranking.bestIndex].personId.isEmpty
            {
                Self.recordOutcome(
                    queryIndex: i,
                    bestPersonId: library[ranking.bestIndex].personId,
                    ranking: ranking,
                    margin: margin,
                    matched: &matched,
                    ambiguous: &ambiguous)
            } else {
                unmatched.append(i)
            }
        }
        return FaceMatchResult(matched: matched, unmatched: unmatched, ambiguous: ambiguous)
    }

    // TS face-matcher.ts:127-142（cosineSimilarity：逐项顺序累加，非 4 维展开）
    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) throws -> Double {
        guard a.count == b.count else {
            throw MatcherError.vectorLengthMismatch(expected: b.count, received: a.count)
        }
        let n = a.count
        var dot = 0.0
        var magA = 0.0
        var magB = 0.0
        for i in 0..<n {
            let ai = Double(a[i])
            let bi = Double(b[i])
            dot += ai * bi
            magA += ai * ai
            magB += bi * bi
        }
        if magA == 0 || magB == 0 { return 0 }
        return dot / (sqrt(magA) * sqrt(magB))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 生产调用点（唯一一处，勿在别处再造一条匹配链）
// ─────────────────────────────────────────────────────────────────────────────
//   FaceKwService.matchClustersAgainstLibrary(sessionId:clusters:)（Cut 5 / 5c-1 起批量）
//     · 库来源 personRepo.getAllEmbeddings() → LibraryEmbedding（小端 Float32 blob），
//       每次调用读一次、交一个 FaceMatcher 实例
//     · 簇成员 / feedback 各一次批量读（getClusters(includeMembers:) + FaceFeedbackRepo.list），
//       rejected 集合在簇循环外算好，随 FaceMatchCluster 传入
//     · 查询向量 = 新簇成员的 face_observations.embedding（clusterStoredObservations
//       内存中的 entries，与 FaceRepo.getClusterMemberEmbeddings 同口径）
//     · 合格线 = 该人物 persons.match_threshold（缺省 0.65），取最高分写
//       face_clusters.matched_person_id / match_confidence
//   向量写入口：FaceKwService.bindCluster → FaceRepo.getClusterMemberEmbeddings
//   → PersonRepo.saveEmbeddings；观察被删除时 FaceRepo 同事务清掉对应向量，
//   保证库与观察同生命周期（不会匹配到已删除的人脸）。
//   FaceMatcher 设计为不可变库快照：一次匹配建一个实例（TS loadLibrary 惰性
//   建索引语义），无需 invalidateCache 重喂。

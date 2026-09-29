// desktop/native/gather-core/Sources/GatherCore/Face/Matcher.swift
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

import Foundation

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

public enum MatcherError: Error, Equatable {
    /// 向量长度不匹配（TS 字符串消息 "Vector length mismatch: X vs Y"，
    /// face-matcher.ts:82/129；expected=库维度/库行维度，received=查询维度）。
    case vectorLengthMismatch(expected: Int, received: Int)
}

// MARK: - FaceMatcher

/// 人脸 → 人物库匹配器（TS face-matcher.ts:25-125）。库 <= lshMinPoints 时
/// 全量精确扫描；超过时共享 CosineLshIndex：跨表多探针桶并集候选 + 精确余弦
/// 重验，precision 与暴力一致（LSH 只会收缩候选集）。
public final class FaceMatcher {
    private let libraryEmbeddings: [LibraryEmbedding]
    public let lshMinPoints: Int

    private var libraryFlat: [Float]?
    private var lshIndex: CosineLshIndex?
    private var libraryDim = 0
    private var loaded = false

    /// 注入式构造：调用方喂入完整库（等价 TS 构造注入 PersonRepository 后
    /// loadLibrary() 惰性取数的结果）。
    public init(library: [LibraryEmbedding], lshMinPoints: Int = CosineLshIndex.lshMinPoints) {
        self.libraryEmbeddings = library
        self.lshMinPoints = lshMinPoints
    }

    // TS face-matcher.ts:36-55（loadLibrary）：惰性加载库并按规模决定路径。
    // Swift 侧库数据由构造注入，此处只做首次建索引（索引随实例生命周期存在，
    // 重建需重新构造实例，语义与 TS 一致）。
    private func loadLibrary() throws -> [LibraryEmbedding] {
        if loaded { return libraryEmbeddings }
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
            let index = try CosineLshIndex(dim: libraryDim)
            try index.build(rows: flat, count: libraryEmbeddings.count)
            libraryFlat = flat
            lshIndex = index
        }
        loaded = true
        return libraryEmbeddings
    }

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
//   FaceKwService.matchClustersAgainstLibrary(sessionId:clusters:)
//     · 库来源 personRepo.getAllEmbeddings() → LibraryEmbedding（小端 Float32 blob）
//     · 查询向量 = 新簇成员的 face_observations.embedding（clusterStoredObservations
//       内存中的 entries，与 FaceRepo.getClusterMemberEmbeddings 同口径）
//     · 合格线 = 该人物 persons.match_threshold（缺省 0.65），取最高分写
//       face_clusters.matched_person_id / match_confidence
//   向量写入口：FaceKwService.bindCluster → FaceRepo.getClusterMemberEmbeddings
//   → PersonRepo.saveEmbeddings；观察被删除时 FaceRepo 同事务清掉对应向量，
//   保证库与观察同生命周期（不会匹配到已删除的人脸）。
//   FaceMatcher 设计为不可变库快照：一次匹配建一个实例（TS loadLibrary 惰性
//   建索引语义），无需 invalidateCache 重喂。

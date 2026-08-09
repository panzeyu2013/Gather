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
/// matched 的键是查询下标。
public struct FaceMatchResult: Equatable, Sendable {
    public let matched: [Int: PersonMatch]
    public let unmatched: [Int]

    public init(matched: [Int: PersonMatch], unmatched: [Int]) {
        self.matched = matched
        self.unmatched = unmatched
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
    // Swift 侧库数据由构造注入，此处只做首次建索引（索引可经 invalidateCache
    // 释放重建，语义与 TS 一致）。
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

    // TS face-matcher.ts:57-61（invalidateCache：释放库/索引缓存）
    public func invalidateCache() {
        loaded = false
        libraryFlat = nil
        lshIndex = nil
        libraryDim = 0
    }

    /// 对账测试专用（@testable）：本次加载是否走了 LSH 分支。
    internal var debugUsedLsh: Bool { lshIndex != nil }

    // TS face-matcher.ts:63-124（matchAgainstLibrary：查询批对库匹配）
    public func matchAgainstLibrary(
        _ embeddings: [[Float]],
        threshold: Double
    ) throws -> FaceMatchResult {
        let library = try loadLibrary()
        var matched: [Int: PersonMatch] = [:]
        var unmatched: [Int] = []

        // 空库：全部查询进 unmatched（face-matcher.ts:71-76）
        if library.isEmpty {
            for i in 0..<embeddings.count { unmatched.append(i) }
            return FaceMatchResult(matched: matched, unmatched: unmatched)
        }

        if let lshIndex, libraryFlat != nil {
            // LSH 路径（face-matcher.ts:78-101）：桶并集候选已按阈值过滤，
            // 择优 score > bestScore、并列取先出现者
            for i in 0..<embeddings.count {
                let inputEmb = embeddings[i]
                guard inputEmb.count == libraryDim else {
                    throw MatcherError.vectorLengthMismatch(expected: libraryDim, received: inputEmb.count)
                }
                let hits = try lshIndex.neighbors(query: inputEmb, queryOffset: 0, threshold: threshold)
                var bestIndex = -1
                var bestScore = 0.0
                for h in 0..<hits.count {
                    let score = Double(hits.scores[h])
                    if score > bestScore {
                        bestScore = score
                        bestIndex = hits.indices[h]
                    }
                }
                if bestIndex >= 0 {
                    matched[i] = PersonMatch(personId: library[bestIndex].personId, confidence: bestScore)
                } else {
                    unmatched.append(i)
                }
            }
            return FaceMatchResult(matched: matched, unmatched: unmatched)
        }

        // 精确扫描路径（face-matcher.ts:103-121）
        for i in 0..<embeddings.count {
            let inputEmb = embeddings[i]
            var bestPersonId = ""
            var bestScore = 0.0
            for j in 0..<library.count {
                let score = try Self.cosineSimilarity(inputEmb, library[j].embedding)
                if score > bestScore {
                    bestScore = score
                    bestPersonId = library[j].personId
                }
            }
            if bestScore >= threshold && !bestPersonId.isEmpty {
                matched[i] = PersonMatch(personId: bestPersonId, confidence: bestScore)
            } else {
                unmatched.append(i)
            }
        }
        return FaceMatchResult(matched: matched, unmatched: unmatched)
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
// 数据源对接（与 PersonRepo.swift）
// ─────────────────────────────────────────────────────────────────────────────
// TS 侧 FaceMatcher 构造注入 PersonRepository，matchAgainstLibrary 首次调用经
// loadLibrary() 惰性读 personRepo.getAllEmbeddings()（face-matcher.ts:36-55），
// 每行 { person_id, embedding(blob) } 解出 Float32Array。Swift 侧 FaceMatcher
// 不依赖 PersonRepo：调用方先取数再喂入，即
//
//   let refs = try personRepo.getAllEmbeddings()          // [PersonEmbeddingRef]
//   let library = refs.map {
//       LibraryEmbedding(personId: $0.personId, embedding: float32Array(from: $0.embedding))
//   }
//   let matcher = FaceMatcher(library: library)           // lshMinPoints 默认 20_000
//   let result = try matcher.matchAgainstLibrary(queries, threshold: t)
//
// 其中 float32Array 把 blob Data 按小端 Float32 读出（float32Data 的逆操作，
// PersonRepo.swift:576-579）。TS 的 loadLibrary 缓存语义由 Swift 侧惰性建索引
// 对应：invalidateCache() 后下次匹配重建索引。PersonRepo 有 getEmbeddingsByPerson
// 等增量接口，调用方可在数据变更后重建 FaceMatcher 或 invalidateCache + 重喂
// 新库（本类设计为不可变库快照，与 TS 的私有缓存字段语义一致）。

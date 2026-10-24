// desktop/native/gather-core/Tests/GatherCoreTests/Reconciliation/MatcherReconciliationTests.swift
// face-matcher 对账测试（Phase 2 任务 2.3「face-matcher 移植」）。
// fixture 是冻结的 TS 参照（生成器已随旧栈删除），本测试加载同一 JSON
// 逐 case 比对：
//   - matched：personId 精确相等、confidence 容差 1e-4、条数一致；
//   - unmatched 下标数组精确相等；
//   - LSH 召回：对每个 case 逐查询与暴力精确最佳比对，召回 >= 0.95
//     （benchmark 只打印候选/耗时，不测 FaceMatcher 实例级 LSH，召回门留在这里）。
// 另附边界单元测试：空库、阈值边界（含等号）、零向量、维度不匹配。

import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct MatcherReconciliationTests {

    // MARK: fixture

    private struct Fixture: Decodable {
        let seed: Int
        let cases: [MatchCase]

        struct MatchCase: Decodable {
            let name: String
            let lshMinPoints: Int
            let threshold: Double
            let library: [LibraryRow]
            let queries: [[Float]]
            let expected: Expected
        }

        struct LibraryRow: Decodable {
            let personId: String
            let embedding: [Float]
        }

        struct Expected: Decodable {
            let matched: [String: MatchValue]
            let unmatched: [Int]
        }

        struct MatchValue: Decodable {
            let personId: String
            let confidence: Double
        }
    }

    private static func loadFixture() throws -> Fixture {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("matcher-fixtures.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    }

    private static func makeMatcher(_ c: Fixture.MatchCase) -> FaceMatcher {
        FaceMatcher(
            library: c.library.map { LibraryEmbedding(personId: $0.personId, embedding: $0.embedding) },
            lshMinPoints: c.lshMinPoints)
    }

    // MARK: 对账

    @Test func matchResultsMatchFixture() throws {
        let fixture = try Self.loadFixture()
        #expect(!fixture.cases.isEmpty, "fixture 不应为空")
        for c in fixture.cases {
            let matcher = Self.makeMatcher(c)
            let result = try matcher.matchAgainstLibrary(c.queries, threshold: c.threshold)
            #expect(result.unmatched == c.expected.unmatched, "case \(c.name): unmatched 与 TS 不一致")
            #expect(
                result.matched.count == c.expected.matched.count,
                "case \(c.name): matched 条数不一致（Swift=\(result.matched.count), TS=\(c.expected.matched.count)）")
            for (key, expected) in c.expected.matched {
                guard let queryIndex = Int(key) else {
                    Issue.record("case \(c.name): 非法查询下标 key=\(key)")
                    continue
                }
                let actual = result.matched[queryIndex]
                #expect(actual != nil, "case \(c.name): query \(queryIndex) 缺失匹配")
                if let actual {
                    #expect(actual.personId == expected.personId, "case \(c.name): query \(queryIndex) personId 不一致")
                    let deviation = abs(actual.confidence - expected.confidence)
                    #expect(deviation < 1e-4, "case \(c.name): query \(queryIndex) confidence 偏差 \(deviation) >= 1e-4")
                }
            }
        }
    }

    // 同一 fixture 内 test-basis 双路径逐查询一致（precision 恒等）
    @Test func bothPathsAgreeOnBasisCase() throws {
        let fixture = try Self.loadFixture()
        let lshCase = try #require(fixture.cases.first { $0.name == "test-basis-lsh" })
        let exactCase = try #require(fixture.cases.first { $0.name == "test-basis-exact" })
        let lsh = try Self.makeMatcher(lshCase).matchAgainstLibrary(lshCase.queries, threshold: lshCase.threshold)
        let exact = try Self.makeMatcher(exactCase).matchAgainstLibrary(exactCase.queries, threshold: exactCase.threshold)
        #expect(exact.matched.count == lsh.matched.count, "两路径 matched 条数不一致")
        for (queryIndex, match) in lsh.matched {
            let brute = exact.matched[queryIndex]
            #expect(brute?.personId == match.personId, "query \(queryIndex): 两路径 personId 不一致")
            if let brute {
                #expect(abs(brute.confidence - match.confidence) < 1e-4, "query \(queryIndex): 两路径置信度偏差过大")
            }
        }
        #expect(exact.unmatched == lsh.unmatched, "两路径 unmatched 不一致")
    }

    // LSH 召回门：LSH 只允许收缩候选集，但不得把真实最邻近的人丢掉。
    @Test func lshRecallAgainstBruteForceMeetsBaseline() throws {
        let fixture = try Self.loadFixture()
        var expectedTotal = 0
        var recalled = 0
        var checkedCases = 0
        for c in fixture.cases {
            let matcher = Self.makeMatcher(c)
            let result = try matcher.matchAgainstLibrary(c.queries, threshold: c.threshold)
            for (queryIndex, query) in c.queries.enumerated() {
                // 维度必须一致：FaceMatcher 对不符维度抛错，这里不能让 cosine
                // 静默截断成「看起来一致」。
                if let row = c.library.first, row.embedding.count != query.count {
                    Issue.record("case \(c.name) query \(queryIndex): 维度 \(query.count) != 库维度 \(row.embedding.count)")
                    continue
                }
                var best = -Double.infinity
                var bestPerson: String?
                for row in c.library {
                    let score = Self.cosine(query, row.embedding)
                    if score > best {
                        best = score
                        bestPerson = row.personId
                    }
                }
                guard best >= c.threshold else { continue }
                expectedTotal += 1
                if result.matched[queryIndex]?.personId == bestPerson { recalled += 1 }
            }
            checkedCases += 1
        }
        #expect(checkedCases > 0, "fixture 不应为空")
        #expect(expectedTotal > 0, "fixture 没有超过阈值的查询，召回率无意义")
        let recall = Double(recalled) / Double(expectedTotal)
        #expect(recall >= 0.95, "LSH 召回 \(recall) < 0.95（\(recalled)/\(expectedTotal)）")
    }

    /// 单位向量余弦，与 FaceMatcher 的精确重验同口径（零向量返回 0）。
    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in 0..<min(a.count, b.count) {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: 边界单元测试

    // face-matcher.ts:71-76（空库全部 unmatched）
    @Test func emptyLibraryReturnsAllUnmatched() throws {
        let matcher = FaceMatcher(library: [])
        let result = try matcher.matchAgainstLibrary(
            [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]],
            threshold: 0.5)
        #expect(result.matched.isEmpty)
        #expect(result.unmatched == [0, 1])
    }

    // face-matcher.ts:116（bestScore >= threshold 才命中；正交查询余弦 0）
    @Test func belowThresholdRemainsUnmatched() throws {
        let matcher = FaceMatcher(library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])])
        let result = try matcher.matchAgainstLibrary([[0, 1, 0, 0]], threshold: 0.9)
        #expect(result.matched.isEmpty)
        #expect(result.unmatched == [0])
    }

    // 阈值含等号：余弦恰 1.0 时 threshold=1.0 必须命中、略高必须未命中
    @Test func thresholdBoundaryIsInclusive() throws {
        let matcher = FaceMatcher(library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])])
        let at = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 1.0)
        #expect(at.matched[0]?.personId == "p1")
        #expect(abs((at.matched[0]?.confidence ?? 0) - 1.0) < 1e-9)
        let above = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 1.0 + 1e-6)
        #expect(above.matched.isEmpty)
        #expect(above.unmatched == [0])
    }

    // LSH 路径阈值含等号（lsh-index.ts:338 `score < threshold` 剔除）
    @Test func lshPathThresholdBoundaryIsInclusive() throws {
        let matcher = FaceMatcher(
            library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])],
            lshMinPoints: 0)
        let result = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 1.0)
        #expect(result.matched[0]?.personId == "p1")
        #expect(abs((result.matched[0]?.confidence ?? 0) - 1.0) < 1e-9)
    }

    // 零向量：余弦为 0（face-matcher.ts:140 提前返回 0），阈值 > 0 不可能命中
    @Test func zeroVectorIsUnmatched() throws {
        let matcher = FaceMatcher(library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])])
        let result = try matcher.matchAgainstLibrary([[0, 0, 0, 0]], threshold: 0.1)
        #expect(result.matched.isEmpty)
        #expect(result.unmatched == [0])
    }

    // 维度不匹配：精确路径 face-matcher.ts:129、LSH 路径 face-matcher.ts:82
    @Test func rejectsVectorLengthMismatch() throws {
        let exact = FaceMatcher(library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])])
        #expect(throws: MatcherError.vectorLengthMismatch(expected: 4, received: 3)) {
            _ = try exact.matchAgainstLibrary([[0.5, 0.5, 0.5]], threshold: 0.9)
        }
        let lsh = FaceMatcher(
            library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])],
            lshMinPoints: 0)
        #expect(throws: MatcherError.vectorLengthMismatch(expected: 4, received: 5)) {
            _ = try lsh.matchAgainstLibrary([[1, 0, 0, 0, 0]], threshold: 0.9)
        }
    }

    // 非单位查询（5 倍幅值）在精确路径下余弦仍正确（face-matcher.ts:70-77 测试场景）
    @Test func exactPathNonUnitQueryScoresCorrectly() throws {
        let matcher = FaceMatcher(library: [LibraryEmbedding(personId: "p1", embedding: [1, 0, 0, 0])])
        let result = try matcher.matchAgainstLibrary([[5, 0, 0, 0]], threshold: 0.99)
        #expect(result.matched[0]?.personId == "p1")
        #expect(abs((result.matched[0]?.confidence ?? 0) - 1.0) < 1e-9)
    }
}

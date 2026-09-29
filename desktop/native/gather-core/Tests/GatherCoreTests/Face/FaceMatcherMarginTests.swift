// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceMatcherMarginTests.swift
// MATCH_MARGIN（PhotoPrism 同义）行为测试：歧义不猜 + margin=0 回归护栏。
// 精确路径与 LSH 路径的判定必须一致；数值边界用可精确表示的余弦（1.0 / 0.5）。

import Testing
@testable import GatherCore

struct FaceMatcherMarginTests {
    // q=[1,0,0,0] 对 A=[1,0,0,0] 余弦恰 1.0、对 B=[0.5,0.5,0.5,0.5] 恰 0.5
    //（Float 0.5 精确、四维幅值恰为 1，逐项累加顺序下无舍入），差值恰 0.5。
    private static let nearTieLibrary = [
        LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
        LibraryEmbedding(personId: "B", embedding: [0.5, 0.5, 0.5, 0.5]),
    ]

    // 3. margin=0（默认）：与旧行为逐位一致 —— 仍取 best 且并列取先出现者。
    @Test func marginZeroKeepsLegacyMatchOnNearTie() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let result = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.4)
        #expect(result.matched[0]?.personId == "A")
        #expect(abs((result.matched[0]?.confidence ?? 0) - 1.0) < 1e-12)
        #expect(result.ambiguous.isEmpty)
        #expect(result.unmatched.isEmpty)

        // 显式传 margin: 0 与省略参数结果完全相同。
        let explicitZero = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.4, margin: 0)
        #expect(explicitZero == result)
    }

    // 3. margin 大于 best-second 差值 → 记入 ambiguous（不匹配、也不算未命中）。
    @Test func marginLargerThanGapMarksAmbiguous() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let result = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.4, margin: 0.6)
        #expect(result.matched.isEmpty)
        #expect(result.ambiguous == [0])
        #expect(result.unmatched.isEmpty)
    }

    // 4. 数值边界：margin 恰好等于差值（>= 语义）→ 仍匹配；大一丝 → 歧义。
    @Test func marginEqualToGapStillMatches() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let at = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.4, margin: 0.5)
        #expect(at.matched[0]?.personId == "A")
        #expect(at.ambiguous.isEmpty)
        #expect(at.unmatched.isEmpty)

        let above = try matcher.matchAgainstLibrary(
            [[1, 0, 0, 0]], threshold: 0.4, margin: 0.5 + 1e-9)
        #expect(above.matched.isEmpty)
        #expect(above.ambiguous == [0])
        #expect(above.unmatched.isEmpty)
    }

    // 3. 真实的「第二人仅略差」：B 的余弦 ~0.99015（差 ~0.00985），margin 夹在差值两侧。
    @Test func nearTieSecondPersonSlightlyWorse() throws {
        let library = [
            LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
            LibraryEmbedding(personId: "B", embedding: [0.99, 0.14, 0, 0]),
        ]
        let matcher = FaceMatcher(library: library)
        let matched = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.9, margin: 0.005)
        #expect(matched.matched[0]?.personId == "A")
        #expect(matched.ambiguous.isEmpty)

        let ambiguous = try matcher.matchAgainstLibrary(
            [[1, 0, 0, 0]], threshold: 0.9, margin: 0.02)
        #expect(ambiguous.matched.isEmpty)
        #expect(ambiguous.ambiguous == [0])
        #expect(ambiguous.unmatched.isEmpty)
    }

    // 3/4. 次优候选只在「达阈候选」中求（与 LSH 的 neighbors(threshold:) 同语义）：
    // 第二个人的 0.5 < threshold 0.9 不算竞争者，margin 再大也照常匹配。
    @Test func belowThresholdRunnerUpDoesNotCreateAmbiguity() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let result = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.9, margin: 0.8)
        #expect(result.matched[0]?.personId == "A")
        #expect(result.ambiguous.isEmpty)
        #expect(result.unmatched.isEmpty)
    }

    // 3. 批量：matched / ambiguous / unmatched 三态互斥且下标按查询顺序。
    @Test func batchPartitionsIntoMatchedAmbiguousUnmatched() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let queries: [[Float]] = [
            [1, 0, 0, 0],           // best=A 1.0，次优 B 0.5 → 差 0.5 < 0.6 → 歧义
            [0.5, 0.5, 0.5, 0.5],   // best=B 1.0，次优 A 0.5 → 歧义
            [0, 1, 0, 0],           // best=B 0.5；A 的 0.0 < threshold → 无竞争者 → 匹配 B
            [-1, 0, 0, 0],          // 全负分 → 未命中
        ]

        let gated = try matcher.matchAgainstLibrary(queries, threshold: 0.4, margin: 0.6)
        #expect(Set(gated.matched.keys) == [2])
        #expect(gated.matched[2]?.personId == "B")
        #expect(gated.ambiguous == [0, 1], "歧义下标按查询顺序")
        #expect(gated.unmatched == [3])
        #expect(gated.matched.count + gated.ambiguous.count + gated.unmatched.count == queries.count)

        // margin=0（默认）逐位回到旧的两态：matched / unmatched，ambiguous 恒空。
        let legacy = try matcher.matchAgainstLibrary(queries, threshold: 0.4)
        #expect(Set(legacy.matched.keys) == [0, 1, 2])
        #expect(legacy.matched[0]?.personId == "A")
        #expect(legacy.matched[1]?.personId == "B")
        #expect(legacy.matched[2]?.personId == "B")
        #expect(legacy.unmatched == [3])
        #expect(legacy.ambiguous.isEmpty)
    }

    // 3. LSH 路径（library.count > lshMinPoints）执行同一判定，且与精确路径一致。
    @Test func lshPathAppliesSameMarginRule() throws {
        // 并列：同一张脸对两个不同的人都是 1.0。LSH 候选取自同一桶，必含两者。
        let library = [
            LibraryEmbedding(personId: "A", embedding: [1, 0, 0, 0]),
            LibraryEmbedding(personId: "B", embedding: [1, 0, 0, 0]),
        ]
        let lsh = FaceMatcher(library: library, lshMinPoints: 0)  // 2 > 0 → LSH 路径
        let exact = FaceMatcher(library: library)  // 2 <= 20000 → 精确扫描路径
        let queries: [[Float]] = [[1, 0, 0, 0]]

        let lshZero = try lsh.matchAgainstLibrary(queries, threshold: 0.9, margin: 0)
        #expect(lshZero.matched[0]?.personId == "A", "并列取先出现者（旧行为）")
        #expect(lshZero.ambiguous.isEmpty)
        #expect(lshZero.unmatched.isEmpty)

        let lshMargin = try lsh.matchAgainstLibrary(queries, threshold: 0.9, margin: 1e-9)
        #expect(lshMargin.matched.isEmpty)
        #expect(lshMargin.ambiguous == [0])
        #expect(lshMargin.unmatched.isEmpty)

        let exactMargin = try exact.matchAgainstLibrary(queries, threshold: 0.9, margin: 1e-9)
        #expect(exactMargin.matched == lshMargin.matched)
        #expect(exactMargin.ambiguous == lshMargin.ambiguous)
        #expect(exactMargin.unmatched == lshMargin.unmatched)

        let exactZero = try exact.matchAgainstLibrary(queries, threshold: 0.9, margin: 0)
        #expect(exactZero.matched == lshZero.matched)
        #expect(exactZero.ambiguous.isEmpty)
    }

    // margin <= 0 一律等价于关闭歧义判定（不引入新行为）。
    @Test func negativeMarginBehavesLikeZero() throws {
        let matcher = FaceMatcher(library: Self.nearTieLibrary)
        let result = try matcher.matchAgainstLibrary([[1, 0, 0, 0]], threshold: 0.4, margin: -1.0)
        #expect(result.matched[0]?.personId == "A")
        #expect(result.ambiguous.isEmpty)
        #expect(result.unmatched.isEmpty)
    }

    // 既有二元 init（matched/unmatched）零改动：ambiguous 默认空数组。
    @Test func ambiguousDefaultsToEmptyForLegacyInit() {
        let result = FaceMatchResult(matched: [:], unmatched: [1, 2])
        #expect(result.ambiguous.isEmpty)
        #expect(result.unmatched == [1, 2])
    }
}

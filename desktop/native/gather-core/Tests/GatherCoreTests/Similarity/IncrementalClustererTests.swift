// desktop/native/gather-core/Tests/GatherCoreTests/Similarity/IncrementalClustererTests.swift
// 增量聚类（ROADMAP 1.3/1.6）：与 ClusterGraphPipeline 全量单趟重聚类的等价性对账。
// Cut 5 / 5b-2a：原 oracle = ClusterEngine.clusterByHash + IncrementalClusterer.buildState
// （均删除）；现在全量参照是唯一实现的 ClusterGraphPipeline.run（fixture golden 见
// ClusterReconciliationTests / ClusterGraphTests）。
// 对账口径（不变量）：划分、组顺序（种子升序）、代表图（组内首元素 = 种子）、
// 未成组集合逐位一致；组内其余成员顺序为规范序（增量）与 BFS 发现序（全量），
// 不在对账口径内。

import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

// MARK: - 确定性随机（SplitMix64，测试可复现）

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }

    mutating func randomHash() -> UInt64 { next() }

    mutating func mutate(_ value: UInt64, maxBits: Int) -> UInt64 {
        var result = value
        let flips = 1 + int(max(1, maxBits))
        for _ in 0..<flips { result ^= UInt64(1) << UInt64(int(64)) }
        return result
    }
}

private func hex(_ value: UInt64) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}

private func entries(_ pairs: [(String, UInt64)]) -> [HashEntry] {
    pairs.map { HashEntry(photoId: $0.0, hash: hex($0.1)) }
}

/// 对账断言：增量结果与全量引擎结果在划分/组顺序/代表图/未成组集合上一致。
private func expectEquivalent(
    _ actual: ClusterResult,
    _ expected: ClusterResult,
    _ context: String = ""
) {
    #expect(actual.groups.count == expected.groups.count, "组数不一致 \(context)")
    for (actualGroup, expectedGroup) in zip(actual.groups, expected.groups) {
        #expect(actualGroup.first == expectedGroup.first, "代表图/组顺序不一致 \(context)")
        #expect(Set(actualGroup) == Set(expectedGroup), "划分不一致 \(context)")
    }
    #expect(actual.ungrouped == expected.ungrouped, "未成组集合不一致 \(context)")
}

private func fullResult(
    _ list: [HashEntry],
    threshold: Int,
    minGroupSize: Int
) throws -> ClusterResult {
    try ClusterGraphPipeline.run(
        entries: list, threshold: threshold, minGroupSize: minGroupSize
    ).result
}

/// 全量状态（增量装配的初始状态）：唯一实现单趟产出的同源 state。
private func fullState(
    entries: [HashEntry],
    minGroupSize: Int,
    threshold: Int
) throws -> ClusterState {
    let outcome = try ClusterGraphPipeline.run(
        entries: entries, threshold: threshold, minGroupSize: minGroupSize)
    return try #require(outcome.state, "global 全量必须产出 state")
}

// MARK: - 基本增量行为

@Suite("IncrementalClusterer 增量更新")
struct IncrementalClustererUpdateTests {
    @Test("新增桥接照片合并两个既有簇")
    func bridgingAdditionMergesGroups() throws {
        // 两个 3 张的簇：base 与 base ^ 0xFF（最小跨簇距离 6 > 阈值 4）。
        let base: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
        let far = base ^ 0b11111111
        var list = entries([
            ("a1", base),
            ("a2", base ^ 0b1),
            ("a3", base ^ 0b11),
            ("b1", far),
            ("b2", far ^ 0b1),
            ("b3", far ^ 0b11),
        ])
        let initial = try fullState(entries: list, minGroupSize: 2, threshold: 4)
        var result = IncrementalClusterer.result(state: initial, entries: list, minGroupSize: 2)
        #expect(result.groups.count == 2)
        #expect(result.ungrouped.isEmpty)

        // 桥接照片：与 base 距离 4、与 far 距离 4 → 两簇合并为一组 7 张。
        list.append(HashEntry(photoId: "bridge", hash: hex(base ^ 0b1111)))
        let outcome = try IncrementalClusterer.update(
            state: initial, entries: list, minGroupSize: 2, threshold: 4
        )
        #expect(outcome.summary.addedCount == 1)
        #expect(outcome.summary.removedCount == 0)
        result = IncrementalClusterer.result(state: outcome.state, entries: list, minGroupSize: 2)
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0]) == Set(["a1", "a2", "a3", "b1", "b2", "b3", "bridge"]))
        expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: 2), "桥接合并")
    }

    @Test("移除桥接照片后分量拆分")
    func removalSplitsComponent() throws {
        let base: UInt64 = 0x1234_5678_9ABC_DEF0
        let far = base ^ 0b11111111
        var list = entries([
            ("a1", base), ("a2", base ^ 0b1), ("a3", base ^ 0b11),
            ("b1", far), ("b2", far ^ 0b1), ("b3", far ^ 0b11),
            ("bridge", base ^ 0b1111),
        ])
        let initial = try fullState(entries: list, minGroupSize: 2, threshold: 4)
        #expect(IncrementalClusterer.result(state: initial, entries: list, minGroupSize: 2).groups.count == 1)

        list.removeAll { $0.photoId == "bridge" }
        let outcome = try IncrementalClusterer.update(
            state: initial, entries: list, minGroupSize: 2, threshold: 4
        )
        #expect(outcome.summary.removedCount == 1)
        #expect(outcome.summary.addedCount == 0)
        let result = IncrementalClusterer.result(state: outcome.state, entries: list, minGroupSize: 2)
        #expect(result.groups.count == 2)
        expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: 2), "移除桥接")
    }

    @Test("哈希变化按移除 + 新增处理并保持全量一致")
    func hashChangeBehavesAsRemoveAndAdd() throws {
        let base: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        var list = entries([
            ("a1", base), ("a2", base ^ 0b1), ("a3", base ^ 0b11),
            ("b1", base ^ 0b111111), ("b2", base ^ 0b111111 ^ 0b1),
        ])
        let initial = try fullState(entries: list, minGroupSize: 2, threshold: 4)

        // a3 换成完全不同的哈希 → 原簇只剩 2 张，新哈希与 b 组相连。
        list[2] = HashEntry(photoId: "a3", hash: hex(base ^ 0b111111 ^ 0b11))
        let outcome = try IncrementalClusterer.update(
            state: initial, entries: list, minGroupSize: 2, threshold: 4
        )
        #expect(outcome.summary.changedCount == 1)
        #expect(outcome.summary.addedCount == 0)
        let result = IncrementalClusterer.result(state: outcome.state, entries: list, minGroupSize: 2)
        expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: 2), "哈希变化")
    }

    @Test("次阈值对在第三张到来后成组（分量可增长为簇）")
    func subThresholdPairBecomesGroup() throws {
        let base: UInt64 = 0x00FF_00FF_00FF_00FF
        var list = entries([("p1", base), ("p2", base ^ 0b1)])
        let initial = try fullState(entries: list, minGroupSize: 3, threshold: 4)
        #expect(IncrementalClusterer.result(state: initial, entries: list, minGroupSize: 3).groups.isEmpty)
        #expect(initial.components.count == 1)

        list.append(HashEntry(photoId: "p3", hash: hex(base ^ 0b11)))
        let outcome = try IncrementalClusterer.update(
            state: initial, entries: list, minGroupSize: 3, threshold: 4
        )
        let result = IncrementalClusterer.result(state: outcome.state, entries: list, minGroupSize: 3)
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0]) == Set(["p1", "p2", "p3"]))
        expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: 3), "次阈值增长")
    }

    @Test("度门控语义与全量一致（minGroupSize >= 4 的链与星形）")
    func degreeGateMatchesEngine() throws {
        // 4 张链：max degree = 2，degree + 1 < 4 → 全量不成组，增量也不得成组。
        let chainBase: UInt64 = 0xFFFF_0000_FFFF_0000
        var list = entries([
            ("c0", chainBase), ("c1", chainBase ^ 0b1),
            ("c2", chainBase ^ 0b11), ("c3", chainBase ^ 0b111),
        ])
        for minGroupSize in [2, 3, 4, 5] {
            let state = try fullState(entries: list, minGroupSize: minGroupSize, threshold: 4)
            let result = IncrementalClusterer.result(state: state, entries: list, minGroupSize: minGroupSize)
            expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: minGroupSize), "链 min=\(minGroupSize)")
        }

        // 星形：中心与 4 个叶相连（degree 4）→ minGroupSize = 5 时成组。
        let center: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        list = entries([
            ("s0", center),
            ("s1", center ^ 0b1), ("s2", center ^ 0b10),
            ("s3", center ^ 0b100), ("s4", center ^ 0b1000),
        ])
        let starState = try fullState(entries: list, minGroupSize: 5, threshold: 4)
        let starResult = IncrementalClusterer.result(state: starState, entries: list, minGroupSize: 5)
        #expect(starResult.groups.count == 1)
        expectEquivalent(starResult, try fullResult(list, threshold: 4, minGroupSize: 5), "星形")
    }

    @Test("无变化更新为幂等，且不重算任何分量")
    func noChangeUpdateIsIdentity() throws {
        let list = entries([("p1", 0x1), ("p2", 0x3), ("p3", 0x30), ("p4", 0x33)])
        let state = try fullState(entries: list, minGroupSize: 2, threshold: 2)
        let outcome = try IncrementalClusterer.update(state: state, entries: list, minGroupSize: 2, threshold: 2)
        #expect(outcome.summary.addedCount == 0)
        #expect(outcome.summary.removedCount == 0)
        #expect(outcome.summary.changedCount == 0)
        #expect(outcome.summary.reusedComponentCount == state.components.count)
        #expect(outcome.summary.recomputedComponentCount == 0)
        #expect(outcome.state == state)
    }

    @Test("非法哈希抛 ClusterGraphError")
    func invalidHashThrows() throws {
        #expect(throws: ClusterGraphError.self) {
            _ = try fullState(
                entries: [HashEntry(photoId: "x", hash: "")], minGroupSize: 2, threshold: 4
            )
        }
        #expect(throws: ClusterGraphError.self) {
            _ = try fullState(
                entries: [HashEntry(photoId: "x", hash: "zz")], minGroupSize: 2, threshold: 4
            )
        }
    }

    @Test("非 8 字节哈希（长哈希）同样与全量一致")
    func nonEightByteHashes() throws {
        // 20 个 hex 字符（10 字节）→ 走逐字节距离路径。
        let list = [
            HashEntry(photoId: "l1", hash: "00000000000000000001"),
            HashEntry(photoId: "l2", hash: "00000000000000000003"),
            HashEntry(photoId: "l3", hash: "0000000000000000000f"),
            HashEntry(photoId: "l4", hash: "ffffffffffffffffffff"),
        ]
        let state = try fullState(entries: list, minGroupSize: 2, threshold: 4)
        let result = IncrementalClusterer.result(state: state, entries: list, minGroupSize: 2)
        expectEquivalent(result, try fullResult(list, threshold: 4, minGroupSize: 2), "长哈希")
    }
}

// MARK: - 1.6 增量 vs 全量对账矩阵

/// 对账矩阵参数（阈值档 × 组大小档 × 随机种子）。
struct MatrixConfig: Sendable {
    let seed: UInt64
    let threshold: Int
    let minGroupSize: Int
}

@Suite("IncrementalClusterer 随机增删改/重命名对账矩阵")
struct IncrementalClustererReconciliationTests {
    private static let matrixSteps =
        Int(ProcessInfo.processInfo.environment["GATHER_TEST_MATRIX_STEPS"] ?? "") ?? 50
    /// 随机操作序列（新增/移除/改哈希/重命名）下，每一步的增量结果都必须与
    /// 全量重聚类等价（默认 50 步；200 步完整矩阵留给夜间）。
    @Test("随机操作逐步与全量重聚类一致（默认 50 步，可用 GATHER_TEST_MATRIX_STEPS 放大）", arguments: [
        MatrixConfig(seed: 1, threshold: 4, minGroupSize: 2),
        MatrixConfig(seed: 2, threshold: 8, minGroupSize: 2),
        MatrixConfig(seed: 3, threshold: 6, minGroupSize: 3),
        MatrixConfig(seed: 4, threshold: 5, minGroupSize: 4),
        MatrixConfig(seed: 5, threshold: 0, minGroupSize: 2),
    ])
    func randomOperationMatrix(config: MatrixConfig) throws {
        var random = SeededRandom(seed: config.seed)
        let threshold = config.threshold
        let minGroupSize = config.minGroupSize

        // 初始 24 张：一半为随机基底的邻域（成组），一半独立随机。
        var list: [HashEntry] = []
        var nextId = 0
        func newId() -> String {
            nextId += 1
            return "p\(nextId)"
        }
        for _ in 0..<12 {
            let base = random.randomHash()
            list.append(HashEntry(photoId: newId(), hash: hex(base)))
            list.append(HashEntry(photoId: newId(), hash: hex(random.mutate(base, maxBits: max(1, threshold)))))
        }
        for _ in 0..<12 {
            list.append(HashEntry(photoId: newId(), hash: hex(random.randomHash())))
        }

        var state = try fullState(
            entries: list, minGroupSize: minGroupSize, threshold: threshold
        )
        expectEquivalent(
            IncrementalClusterer.result(state: state, entries: list, minGroupSize: minGroupSize),
            try fullResult(list, threshold: threshold, minGroupSize: minGroupSize),
            "初始状态"
        )

        var operationCounts = [0, 0, 0, 0, 0]  // add/remove/hash/rename/noop
        for step in 0..<Self.matrixSteps {
            switch random.int(10) {
            case 0, 1, 2:
                operationCounts[0] += 1
                // 新增：60% 邻域（挂到已有照片附近），40% 独立随机。
                if list.isEmpty || random.int(10) < 4 {
                    list.append(HashEntry(photoId: newId(), hash: hex(random.randomHash())))
                } else {
                    let anchor = list[random.int(list.count)].hash
                    let anchorValue = UInt64(anchor, radix: 16) ?? 0
                    list.append(HashEntry(
                        photoId: newId(),
                        hash: hex(random.mutate(anchorValue, maxBits: max(1, threshold)))
                    ))
                }
            case 3, 4:
                operationCounts[1] += 1
                // 移除。
                if !list.isEmpty {
                    let index = random.int(list.count)
                    list.remove(at: index)
                }
            case 5, 6:
                operationCounts[2] += 1
                // 改哈希（内容变化）。
                if !list.isEmpty {
                    let index = random.int(list.count)
                    let value = UInt64(list[index].hash, radix: 16) ?? 0
                    list[index] = HashEntry(
                        photoId: list[index].photoId,
                        hash: hex(random.mutate(value, maxBits: max(1, threshold + 2)))
                    )
                }
            case 7, 8:
                operationCounts[3] += 1
                // 重命名：只换 photoId，哈希与顺序不变，聚类输入不受影响。
                if !list.isEmpty {
                    let index = random.int(list.count)
                    list[index] = HashEntry(photoId: newId(), hash: list[index].hash)
                }
            default:
                operationCounts[4] += 1
                // 无操作：验证幂等路径。
                break
            }

            let outcome = try IncrementalClusterer.update(
                state: state, entries: list, minGroupSize: minGroupSize, threshold: threshold
            )
            state = outcome.state
            let incremental = IncrementalClusterer.result(
                state: state, entries: list, minGroupSize: minGroupSize
            )
            expectEquivalent(
                incremental,
                try fullResult(list, threshold: threshold, minGroupSize: minGroupSize),
                "seed=\(config.seed) step=\(step) n=\(list.count)"
            )
            // 状态自身也要与全量构建一致（供下次增量复用）。
            let rebuilt = try fullState(
                entries: list, minGroupSize: minGroupSize, threshold: threshold
            )
            #expect(state.components == rebuilt.components, "分量不一致 seed=\(config.seed) step=\(step)")
            #expect(state.groups == rebuilt.groups, "簇不一致 seed=\(config.seed) step=\(step)")
        }
        #expect(
            operationCounts.allSatisfy { $0 > 0 },
            "默认/夜间步数必须覆盖 add/remove/hash/rename/noop：\(operationCounts)")
    }
}

// MARK: - 增量复用语义（性能门已迁到 benchmark）

@Suite("IncrementalClusterer 增量复用语义")
struct IncrementalClustererReuseTests {
    /// 性能验收（2 万张新增 100 张 < 10s）由 gather-core-benchmarks 负责；
    /// 单测只验证“未受影响的分量被复用、被触及的分量才重算”这一功能不变量。
    @Test("新增照片只重算被触及的分量，其余分量直接复用")
    func updateRecomputesOnlyTouchedComponents() throws {
        var list: [HashEntry] = []
        for clusterIndex in 0..<2 {
            let clusterBase = UInt64(clusterIndex) &* 0x9E37_79B9_7F4A_7C15
            for member in 0..<8 {
                list.append(HashEntry(
                    photoId: "c\(clusterIndex)-\(member)",
                    hash: hex(clusterBase ^ UInt64(member % 4))))
            }
        }
        let state = try fullState(entries: list, minGroupSize: 2, threshold: 8)
        #expect(state.components.count == 2)

        // 两张新照片都挂到第 0 个分量：只有它需要重算。
        let touchedBase = UInt64(0) &* 0x9E37_79B9_7F4A_7C15
        for index in 0..<2 {
            list.append(HashEntry(
                photoId: "new-\(index)",
                hash: hex(touchedBase ^ UInt64(index % 4))))
        }

        let outcome = try IncrementalClusterer.update(
            state: state, entries: list, minGroupSize: 2, threshold: 8)
        #expect(outcome.summary.recomputedComponentCount == 1, "只重算被新照片触及的分量")
        #expect(outcome.summary.reusedComponentCount == 1, "另一个分量直接复用")
        let result = IncrementalClusterer.result(
            state: outcome.state, entries: list, minGroupSize: 2)
        #expect(result.groups.count == 2)
        #expect(result.groups.contains { $0.count == 10 }, "被触及的簇包含两张新照片")
    }
}


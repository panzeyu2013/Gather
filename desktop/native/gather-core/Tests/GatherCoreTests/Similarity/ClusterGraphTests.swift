// desktop/native/gather-core/Tests/GatherCoreTests/Similarity/ClusterGraphTests.swift
// Cut 5：ClusterGraph / ClusterGraphPipeline 的 golden 与不变量门禁。
//
// 5b-2a 删除了旧 ClusterEngine 与 IncrementalClusterer.buildState/ComponentGraph，
// 原来的 "parity vs 旧实现" 用例（ClusterGraphParityTests）失去参照，改为：
//   1. 外部 golden：Reconciliation/Fixtures/cluster-fixtures.json 的 17 个用例
//      （15 global + 2 sequential）逐组/逐成员/组序与唯一实现逐位一致；
//   2. 内部一致性：单趟 result 与 state 同源（state.groups 为规范序、分量覆盖全集）、
//      多档并集行 == 逐档单跑、streaming 图 == 位集图、模式分发 == 对应入口；
//   3. 增量装配：IncrementalClusterer.update 的 state 与全量 run 的 state 逐位一致
//      （默认 50 次随机增删 x 3 组参数；200 步完整矩阵留给手动全量档）。

import Foundation
import Testing
@testable import GatherAnalysis
import GatherProtocol

// MARK: - 确定性随机（SplitMix64，测试可复现）

private struct ClusterGraphRandom {
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

    mutating func mutate(_ value: UInt64, maxBits: Int) -> UInt64 {
        var result = value
        let flips = 1 + int(max(1, maxBits))
        for _ in 0..<flips { result ^= UInt64(1) << UInt64(int(64)) }
        return result
    }
}

// MARK: - 测试辅助

private func graphHex(_ value: UInt64) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}

private func graphEntries(_ pairs: [(String, UInt64)]) -> [HashEntry] {
    pairs.map { pair in HashEntry(photoId: pair.0, hash: graphHex(pair.1)) }
}

private func graphEntries(hex pairs: [(String, String)]) -> [HashEntry] {
    pairs.map { pair in HashEntry(photoId: pair.0, hash: pair.1) }
}

/// 划分/种子序/未成组集合等价（组内其余成员的顺序不在口径内）。
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

/// 用位集图跑一遍分量 + 分组，返回 workspace。
private func makeWorkspace(
    entries: [HashEntry],
    threshold: Int,
    minGroupSize: Int
) throws -> ClusterWorkspace {
    let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
    let graph = HashNeighborhoodGraph(table: table, threshold: threshold)
    var workspace = ClusterWorkspace(nodeCount: table.count)
    _ = DegreeGatedBFS.components(of: graph, into: &workspace)
    _ = DegreeGatedBFS.groups(of: graph, minGroupSize: minGroupSize, into: &workspace)
    return workspace
}

// MARK: - fixture

private struct ClusterGraphFixture: Decodable {
    struct Entry: Decodable {
        let photoId: String
        let hash: String
    }

    struct Expected: Decodable {
        let groups: [[String]]
        let ungrouped: [String]
    }

    struct Case: Decodable {
        let name: String
        let mode: String
        let threshold: Int
        let minGroupSize: Int
        let entries: [Entry]
        let expected: Expected
    }

    let cases: [Case]
}

private func loadClusterGraphFixture() throws -> ClusterGraphFixture {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Similarity
        .deletingLastPathComponent() // GatherCoreTests
        .appendingPathComponent("Reconciliation")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("cluster-fixtures.json")
    return try JSONDecoder().decode(ClusterGraphFixture.self, from: Data(contentsOf: url))
}

private func fixtureEntries(_ testCase: ClusterGraphFixture.Case) -> [HashEntry] {
    testCase.entries.map { value in HashEntry(photoId: value.photoId, hash: value.hash) }
}

private func fixtureMode(_ testCase: ClusterGraphFixture.Case) -> HashGroupingMode {
    testCase.mode == "sequential" ? .sequential : .global
}

// MARK: - fixture golden

@Suite("ClusterGraph fixture golden")
struct ClusterGraphFixtureGoldenTests {
    /// 审计口径写“6 个 fixture”，仓库实际是 17 个 case（15 global + 2 sequential）。
    /// 这里覆盖全部 17 例（global 走单趟图、sequential 走相邻段）。
    @Test("17 个 fixture 用例逐组/逐成员/组序与唯一实现一致（golden）")
    func fixtureGolden() throws {
        let fixture = try loadClusterGraphFixture()
        let globalCases = fixture.cases.filter { testCase in testCase.mode == "global" }
        #expect(fixture.cases.count == 17, "fixture 实际 17 例（审计写 6 为漏计，记 plan drift）")
        #expect(globalCases.count == 15, "其中 15 个 global（2 个 sequential 不走图）")

        for testCase in fixture.cases {
            let result = try ClusterGraphPipeline.run(
                entries: fixtureEntries(testCase),
                threshold: testCase.threshold,
                minGroupSize: testCase.minGroupSize,
                mode: fixtureMode(testCase)
            ).result
            #expect(result.groups == testCase.expected.groups, "case \(testCase.name): groups（组序/组内序）")
            #expect(result.ungrouped == testCase.expected.ungrouped, "case \(testCase.name): ungrouped")
        }
    }

    /// 单趟 state 与 result 同源：组集合一致、组内规范序（[seed] + 输入序升序）、
    /// 分量是全集的一个划分、每个组都落在某个分量内。
    @Test("单趟 state 不变量：同源分组、规范序、分量划分")
    func fixtureStateInvariants() throws {
        let fixture = try loadClusterGraphFixture()
        for testCase in fixture.cases where testCase.mode == "global" {
            let entries = fixtureEntries(testCase)
            let ids = entries.map { entry in entry.photoId }
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            let outcome = try ClusterGraphPipeline.run(
                entries: entries,
                threshold: testCase.threshold,
                minGroupSize: testCase.minGroupSize
            )
            let state = try #require(outcome.state, "global 单趟必须产出 state")

            // hashes 快照 = 输入。
            #expect(state.hashes == Dictionary(
                uniqueKeysWithValues: entries.map { ($0.photoId, $0.hash) }),
                "case \(testCase.name): hashes 快照")

            // 分量是全集的一个划分（每个 id 恰好出现一次）。
            let componentMembers = state.components.flatMap { $0 }
            #expect(componentMembers.count == ids.count, "case \(testCase.name): 分量成员总数")
            #expect(Set(componentMembers) == Set(ids), "case \(testCase.name): 分量覆盖全集")

            // 组集合与 result 一致，且每组落在单个分量内。
            #expect(
                Set(state.groups.flatMap { $0 }) == Set(outcome.result.groups.flatMap { $0 }),
                "case \(testCase.name): state/result 组集合")
            for group in state.groups {
                #expect(
                    state.components.contains { component in
                        Set(group).isSubset(of: Set(component))
                    },
                    "case \(testCase.name): 组必须落在单个分量内")
                let rest = Array(group.dropFirst()).compactMap { order[$0] }
                #expect(rest == rest.sorted(), "case \(testCase.name): 组内规范序")
            }
        }
    }

    /// 组内序 golden：4 节点图（0-1、0-2、0-3、1-2，threshold 1）上
    /// wave 发现序 = [n0, n2, n3, n1]，落库规范序 = [n0, n1, n2, n3]。
    @Test("wave 组内序与落库规范序 golden")
    func waveOrderGolden() throws {
        let entries = graphEntries(hex: [
            ("n0", "0000000000000000"),
            ("n1", "0000000000000005"),
            ("n2", "0000000000000001"),
            ("n3", "0000000000000002"),
        ])
        let ids = entries.map { entry in entry.photoId }

        let outcome = try ClusterGraphPipeline.run(
            entries: entries, threshold: 1, minGroupSize: 2)
        #expect(outcome.result.groups == [["n0", "n2", "n3", "n1"]], "wave 发现序")
        #expect(outcome.result.ungrouped.isEmpty)
        let state = try #require(outcome.state)
        #expect(state.groups == [["n0", "n1", "n2", "n3"]], "落库规范序")
        #expect(state.components == [ids])

        let workspace = try makeWorkspace(entries: entries, threshold: 1, minGroupSize: 2)
        #expect(workspace.groups == [[0, 2, 3, 1]])
        #expect(workspace.canonicalGroups() == [[0, 1, 2, 3]])
        #expect(workspace.groupIDs(ids) == outcome.result.groups)
    }

    @Test("ClusterWorkspace 保组序/组内序，components 与 groups 可独立写入")
    func workspacePreservesOrder() throws {
        let entries = graphEntries(hex: [
            ("n0", "0000000000000000"),
            ("n1", "0000000000000005"),
            ("n2", "0000000000000001"),
            ("n3", "0000000000000002"),
        ])
        let ids = entries.map { entry in entry.photoId }
        let workspace = try makeWorkspace(entries: entries, threshold: 1, minGroupSize: 2)

        #expect(workspace.components == [[0, 1, 2, 3]])
        #expect(workspace.groups == [[0, 2, 3, 1]])
        #expect(workspace.componentIDs(ids) == [["n0", "n1", "n2", "n3"]])
        #expect(workspace.groupIDs(ids) == [["n0", "n2", "n3", "n1"]])
        #expect(workspace.canonicalGroups() == [[0, 1, 2, 3]])
        #expect(workspace.groupedNodeCount == 4)
        #expect(workspace.ungroupedNodes.isEmpty)
    }

    /// 度门控 golden：4 张链（最大度 2）在 minGroupSize >= 4 时不成组；
    /// 星形（中心度 4）在 minGroupSize = 5 时成组。稀疏节点可随组但不扩张。
    @Test("度门控 golden：链（min>=4 不成组）/星形（min=5 成组）")
    func degreeGatingGolden() throws {
        let chainBase: UInt64 = 0xFFFF_0000_FFFF_0000
        let chain = graphEntries([
            ("c0", chainBase),
            ("c1", chainBase ^ 0b1),
            ("c2", chainBase ^ 0b11),
            ("c3", chainBase ^ 0b111),
        ])
        let chainIds = chain.map { entry in entry.photoId }
        for minGroupSize in [2, 3] {
            let result = try ClusterGraphPipeline.run(
                entries: chain, threshold: 1, minGroupSize: minGroupSize).result
            #expect(result.groups.count == 1, "chain min=\(minGroupSize)")
            #expect(result.ungrouped.isEmpty, "chain min=\(minGroupSize)")
            if minGroupSize == 2 {
                // 种子 = c0（degree 1），wave 逐波向后推进。
                #expect(result.groups[0] == ["c0", "c1", "c2", "c3"], "chain min=2 顺序")
            } else {
                // 种子 = c1（degree 2）；c0/c3 度数不足只能随组。
                #expect(result.groups[0] == ["c1", "c0", "c2", "c3"], "chain min=3 顺序")
            }
        }
        for minGroupSize in [4, 5] {
            let result = try ClusterGraphPipeline.run(
                entries: chain, threshold: 1, minGroupSize: minGroupSize).result
            #expect(result.groups.isEmpty, "chain min=\(minGroupSize) 不得成组")
            #expect(result.ungrouped == chainIds, "chain min=\(minGroupSize) 全部未成组")
        }

        let center: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        let star = graphEntries([
            ("s0", center),
            ("s1", center ^ 0b1),
            ("s2", center ^ 0b10),
            ("s3", center ^ 0b100),
            ("s4", center ^ 0b1000),
        ])
        let starResult = try ClusterGraphPipeline.run(
            entries: star, threshold: 1, minGroupSize: 5).result
        #expect(starResult.groups.count == 1)
        #expect(starResult.groups[0].first == "s0", "代表图 = 中心")
        #expect(Set(starResult.groups[0]) == Set(star.map { entry in entry.photoId }))
        #expect(starResult.ungrouped.isEmpty)
    }

    @Test("HashGraphTable：右对齐零填充、8/10 字节距离、非法 hex")
    func hashTableParsingAndDistance() throws {
        let table = try HashGraphTable(hashes: [
            "1",
            "0001",
            "0000000000000001",
            "00000000000000000001",
            "ffffffffffffffff",
            "00000000000000000000",
        ])
        #expect(table.count == 6)
        #expect(table.width == 10)
        #expect(table.maxDistance == 80)

        // 前四个是同一个值（右对齐零填充）。
        #expect(table.distance(0, 1) == 0)
        #expect(table.distance(0, 2) == 0)
        #expect(table.distance(0, 3) == 0)
        #expect(table.distance(1, 2) == 0)
        // 8 字节全 1 右对齐到 10 字节：与值 1 相差 63 位。
        #expect(table.distance(0, 4) == 63)
        #expect(table.distance(4, 0) == 63)
        // 20 个 0 与值 1 相差 1 位。
        #expect(table.distance(0, 5) == 1)
        #expect(!table.isNeighbor(0, 0, threshold: 0))
        #expect(table.isNeighbor(0, 1, threshold: 0))
        #expect(table.isNeighbor(0, 4, threshold: 63))
        #expect(!table.isNeighbor(0, 4, threshold: 62))

        #expect(throws: ClusterGraphError.invalidHash("")) {
            _ = try HashGraphTable(hashes: [""])
        }
        #expect(throws: ClusterGraphError.invalidHash("z")) {
            _ = try HashGraphTable(hashes: ["zz"])
        }
    }

    /// 非 8 字节 / 奇数字符 hex 的 golden：l1/l2/l3/l6 同簇，l4/l5 孤立。
    @Test("非 8 字节 / 奇数字符 hex：分组 golden")
    func longHashGolden() throws {
        let entries = graphEntries(hex: [
            ("l1", "00000000000000000001"),
            ("l2", "00000000000000000003"),
            ("l3", "0000000000000000000f"),
            ("l4", "ffffffffffffffffffff"),
            ("l5", "fff"),
            ("l6", "0000000000000001"),
        ])
        let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
        #expect(table.width == 10)
        let result = try ClusterGraphPipeline.run(
            entries: entries, threshold: 4, minGroupSize: 2).result
        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0]) == Set(["l1", "l2", "l3", "l6"]))
        #expect(result.ungrouped == ["l4", "l5"])
    }
}

// MARK: - 多档 / 模式分发

@Suite("ClusterGraphPipeline 多档与模式分发")
struct ClusterGraphPipelineEntryPointTests {
    /// 多档并集行（runTiers）每档结果 == 单档 run 的 result（同实现、同序）。
    @Test("runTiers 每档与单档 run 逐位一致（fixture 全 case）")
    func multiTierMatchesSingleTier() throws {
        let fixture = try loadClusterGraphFixture()
        for testCase in fixture.cases where testCase.mode == "global" {
            let entries = fixtureEntries(testCase)
            let threshold = testCase.threshold
            let tiers = [max(0, threshold - 4), threshold, threshold + 4]
            let actual = try ClusterGraphPipeline.runTiers(
                entries: entries,
                thresholds: tiers,
                minGroupSize: testCase.minGroupSize
            )
            #expect(actual.count == tiers.count)
            for (index, tier) in tiers.enumerated() {
                let single = try ClusterGraphPipeline.run(
                    entries: entries,
                    threshold: tier,
                    minGroupSize: testCase.minGroupSize
                ).result
                #expect(actual[index] == single, "case \(testCase.name) tier \(tier)")
            }
        }
    }

    /// 模式分发：run(mode:) == global run / sequential runSequential（state 语义不同），
    /// runTiers(mode:) == runTiers / runSequentialTiers。
    @Test("global/sequential 分发与 sequential golden")
    func modeDispatchAndSequentialGolden() throws {
        let entries = graphEntries([
            ("b1", 0),
            ("b2", 1),
            ("b3", 3),
            ("b4", 7),
            ("o1", 0xFFFF_FFFF_FFFF_0000),
        ])
        let ids = entries.map { entry in entry.photoId }

        let global = try ClusterGraphPipeline.run(
            entries: entries, threshold: 1, minGroupSize: 2, mode: .global)
        #expect(global.state != nil, "global 必须产出 state")
        #expect(global.result.groups.count == 1)
        #expect(global.result.groups[0] == ["b1", "b2", "b3", "b4"])
        #expect(global.result.ungrouped == ["o1"])

        let sequential = try ClusterGraphPipeline.run(
            entries: entries, threshold: 1, minGroupSize: 2, mode: .sequential)
        #expect(sequential.state == nil, "sequential 无增量状态")
        #expect(sequential.result.groups == [["b1", "b2", "b3", "b4"]])
        #expect(sequential.result.ungrouped == ["o1"])
        #expect(
            sequential.result == (try ClusterGraphPipeline.runSequential(
                entries: entries, threshold: 1, minGroupSize: 2)),
            "分发 == runSequential")
        #expect(
            global.result.groups.map { Set($0) } == sequential.result.groups.map { Set($0) },
            "两种模式在本语料上划分一致")

        let tiers = [1, 4]
        let tierResults = try ClusterGraphPipeline.runTiers(
            entries: entries, thresholds: tiers, minGroupSize: 2, mode: .sequential)
        let expected = try tiers.map { tier in
            try ClusterGraphPipeline.runSequential(
                entries: entries, threshold: tier, minGroupSize: 2)
        }
        #expect(tierResults == expected, "多档 sequential == 逐档 runSequential")
        #expect(
            try ClusterGraphPipeline.runTiers(
                entries: entries, thresholds: tiers, minGroupSize: 2, mode: .global)
                == tiers.map { tier in
                    try ClusterGraphPipeline.run(
                        entries: entries, threshold: tier, minGroupSize: 2).result
                },
            "多档 global == 逐档 run")
        #expect(Set(ids) == Set(global.result.groups.flatMap { $0 } + global.result.ungrouped))
    }
}

// MARK: - 增量装配 vs 全量

@Suite("ClusterGraph 增量装配与全量一致")
struct ClusterGraphIncrementalAssemblyTests {
    private static let matrixSteps =
        Int(ProcessInfo.processInfo.environment["GATHER_TEST_MATRIX_STEPS"] ?? "") ?? 50
    /// 50 次随机新增/移除（每次操作后重算全图），逐项断言：
    /// - IncrementalClusterer.update 的 state.components/groups == 全量 run 的 state；
    /// - 由 state 复原的 result 与全量 result 划分/种子序/未成组一致。
    /// 200 步完整矩阵留给手动全量档；默认套件用 50 步覆盖全部操作类型。
    @Test("随机增删：增量 state 与全量 state 逐位一致（默认 50 步，可用 GATHER_TEST_MATRIX_STEPS 放大）")
    func randomAddRemoveMatchesFullRun() throws {
        let configs: [(seed: UInt64, threshold: Int, minGroupSize: Int)] = [
            (seed: 11, threshold: 4, minGroupSize: 2),
            (seed: 12, threshold: 8, minGroupSize: 2),
            (seed: 13, threshold: 6, minGroupSize: 3),
        ]

        for config in configs {
            var random = ClusterGraphRandom(seed: config.seed)
            var list: [HashEntry] = []
            var nextId = 0
            func newId() -> String {
                nextId += 1
                return "p\(nextId)"
            }

            // 初始 24 张：一半是随机基底的邻域（成组），一半独立随机。
            for _ in 0..<12 {
                let base = random.next()
                list.append(HashEntry(photoId: newId(), hash: graphHex(base)))
                list.append(HashEntry(
                    photoId: newId(),
                    hash: graphHex(random.mutate(base, maxBits: max(1, config.threshold)))
                ))
            }
            for _ in 0..<12 {
                list.append(HashEntry(photoId: newId(), hash: graphHex(random.next())))
            }

            var state = try #require(try ClusterGraphPipeline.run(
                entries: list,
                threshold: config.threshold,
                minGroupSize: config.minGroupSize
            ).state)

            for step in 0..<Self.matrixSteps {
                switch random.int(3) {
                case 0, 1:
                    if list.isEmpty || random.int(10) < 4 {
                        list.append(HashEntry(photoId: newId(), hash: graphHex(random.next())))
                    } else {
                        let anchor = list[random.int(list.count)].hash
                        let anchorValue = UInt64(anchor, radix: 16) ?? 0
                        list.append(HashEntry(
                            photoId: newId(),
                            hash: graphHex(random.mutate(
                                anchorValue,
                                maxBits: max(1, config.threshold)
                            ))
                        ))
                    }
                default:
                    if !list.isEmpty {
                        list.remove(at: random.int(list.count))
                    }
                }

                state = try IncrementalClusterer.update(
                    state: state,
                    entries: list,
                    minGroupSize: config.minGroupSize,
                    threshold: config.threshold
                ).state

                let full = try ClusterGraphPipeline.run(
                    entries: list,
                    threshold: config.threshold,
                    minGroupSize: config.minGroupSize
                )
                let fullState = try #require(full.state)
                let context = "seed=\(config.seed) step=\(step) n=\(list.count)"
                #expect(state.components == fullState.components, "components 不一致 \(context)")
                #expect(state.groups == fullState.groups, "groups 不一致 \(context)")
                expectEquivalent(
                    IncrementalClusterer.result(
                        state: state, entries: list, minGroupSize: config.minGroupSize),
                    full.result,
                    context
                )
            }
        }
    }
}

// MARK: - streaming vs 位集

@Suite("ClusterGraph streaming 一致")
struct ClusterGraphStreamingTests {
    /// 结构化随机图（含相同哈希、邻域簇、长尾孤立点）上，streaming 与位集
    /// 两条路径的分量/分组逐位一致（含组序/组内序）。
    @Test("结构化随机图：streaming 与位集图的 components/groups 逐位一致")
    func streamingMatchesBitset() throws {
        let configs: [(seed: UInt64, threshold: Int, minGroupSize: Int, nodeCount: Int)] = [
            (seed: 21, threshold: 2, minGroupSize: 2, nodeCount: 600),
            (seed: 22, threshold: 6, minGroupSize: 3, nodeCount: 600),
            (seed: 23, threshold: 0, minGroupSize: 2, nodeCount: 300),
        ]

        for config in configs {
            var random = ClusterGraphRandom(seed: config.seed)
            var hashes: [String] = []
            hashes.reserveCapacity(config.nodeCount)
            for _ in 0..<config.nodeCount {
                if !hashes.isEmpty && random.int(10) < 6 {
                    let anchor = hashes[random.int(hashes.count)]
                    let value = UInt64(anchor, radix: 16) ?? 0
                    hashes.append(graphHex(random.mutate(
                        value,
                        maxBits: max(1, config.threshold)
                    )))
                } else {
                    hashes.append(graphHex(random.next()))
                }
            }

            let table = try HashGraphTable(hashes: hashes)
            let full = HashNeighborhoodGraph(table: table, threshold: config.threshold)
            let streaming = StreamingNeighborhoodGraph(
                table: table,
                threshold: config.threshold,
                degrees: full.degreeSequence
            )

            let fullComponents = DegreeGatedBFS.components(of: full)
            let streamingComponents = DegreeGatedBFS.components(of: streaming)
            #expect(
                fullComponents == streamingComponents,
                "components seed=\(config.seed) n=\(config.nodeCount)"
            )

            let fullGroups = DegreeGatedBFS.groups(of: full, minGroupSize: config.minGroupSize)
            let streamingGroups = DegreeGatedBFS.groups(
                of: streaming,
                minGroupSize: config.minGroupSize
            )
            #expect(
                fullGroups == streamingGroups,
                "groups seed=\(config.seed) n=\(config.nodeCount)"
            )
        }
    }

    /// 位集上限可注入后，用 n=33 / maxBitsetEntries=32 覆盖“超过上限切 streaming”
    /// 的生产分支；真实 32,769 节点的内存/耗时需要专项评估，不再占用默认套件。
    @Test("跨位集上限时 streaming 分支与位集分支结果一致")
    func streamingParityAboveBitsetLimit() throws {
        #expect(ClusterGraphPipeline.defaultMaxBitsetEntries == 32_768)
        let nodeCount = 33
        var hashes: [String] = []
        hashes.reserveCapacity(nodeCount)
        for index in 0..<nodeCount {
            hashes.append(graphHex(UInt64(index) &* 0x9E37_79B9_7F4A_7C15))
        }
        let entries = hashes.enumerated().map { index, hash in
            HashEntry(photoId: "n\(index)", hash: hash)
        }

        let table = try HashGraphTable(hashes: hashes)
        #expect(table.count == nodeCount)
        #expect(table.maxDistance == 64)

        // threshold=64 构造全连接；只比较分支选择与最终分组，不做 32k 规模对账。
        let streaming = try ClusterGraphPipeline.run(
            entries: entries, threshold: table.maxDistance, minGroupSize: 2,
            maxBitsetEntries: 32)
        let bitset = try ClusterGraphPipeline.run(
            entries: entries, threshold: table.maxDistance, minGroupSize: 2,
            maxBitsetEntries: nodeCount)
        #expect(streaming.usedStreaming, "33 > 32 必须走 streaming 回退")
        #expect(!bitset.usedStreaming, "33 <= 33 必须走位集路径")
        #expect(streaming.result == bitset.result)
        #expect(streaming.result.groups.count == 1)
        #expect(streaming.result.groups.first?.count == nodeCount)
        #expect(streaming.result.ungrouped.isEmpty)

        // runTiers 的注入路径也要与单档一致；这里同样用 33>32 触发 streaming。
        let streamingTiers = try ClusterGraphPipeline.runTiers(
            entries: entries, thresholds: [table.maxDistance], minGroupSize: 2,
            maxBitsetEntries: 32)
        let bitsetTiers = try ClusterGraphPipeline.runTiers(
            entries: entries, thresholds: [table.maxDistance], minGroupSize: 2,
            maxBitsetEntries: nodeCount)
        #expect(streamingTiers == bitsetTiers)
        #expect(streamingTiers.first?.groups.count == 1)
    }
}

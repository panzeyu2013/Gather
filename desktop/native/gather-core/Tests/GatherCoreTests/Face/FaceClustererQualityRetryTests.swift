// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceClustererQualityRetryTests.swift
// CLUSTER_CORE（coreQualityFloor）与 CLUSTER_CORE_RETRY（retryMinSamples）行为测试。
// 全部用行为证据：簇/噪声成员集合、种子归属、进度回调，而非仅断言编译。

import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherAnalysis

struct FaceClustererQualityRetryTests {
    private static func entry(
        _ id: Int, quality: Double = 1.0, _ embedding: [Float]
    ) -> EmbeddingEntry {
        EmbeddingEntry(
            observationId: id, photoId: "p\(id)", embedding: embedding, quality: quality)
    }

    // 既有调用点不传 quality 时默认 1.0（全部点合格），与引入 quality 前一致。
    @Test func embeddingEntryDefaultsToFullQuality() {
        let entry = EmbeddingEntry(observationId: 7, photoId: "p", embedding: [1, 0, 0, 0])
        #expect(entry.quality == 1.0)
        #expect(
            entry
                == EmbeddingEntry(
                    observationId: 7, photoId: "p", embedding: [1, 0, 0, 0], quality: 1.0))
    }

    // 1a. 2 个高质量 + 1 个低质量互相相似：低质量点被高质量簇吸收（进簇），
    // 且不得当种子（floor=0 时它列首并成为种子；floor=0.5 时种子只能是合格点）。
    @Test func coreQualityFloorKeepsLowQualityAsBorderPoint() throws {
        let entries = [
            Self.entry(1, quality: 0.2, [1, 0, 0, 0]),  // 低质量且列首
            Self.entry(2, quality: 1.0, [1, 0, 0, 0]),
            Self.entry(3, quality: 1.0, [1, 0, 0, 0]),
        ]

        // 基线（floor=0，默认）：低质量点照旧当种子 → 单一簇，成员相同。
        let legacy = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        #expect(legacy.clusters.count == 1)
        #expect(Set(legacy.clusters[0].map(\.observationId)) == [1, 2, 3])
        #expect(legacy.noise.isEmpty)

        // floor=0.5：低质量点仍被吸收进簇，但种子换成了合格点（id 2）。
        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(gated.clusters.count == 1)
        #expect(Set(gated.clusters[0].map(\.observationId)) == [1, 2, 3], "低质量点必须进簇")
        #expect(gated.noise.isEmpty)
        #expect(gated.clusters[0].first?.observationId == 2, "低质量点不得当种子")
        #expect((gated.clusters[0].first?.quality ?? 0) >= 0.5)
    }

    // 1b. 低质量点的邻域本身达标（互为邻居）也不得单独成簇；质量门槛含等号。
    @Test func lowQualityDensePairCannotFormOwnCluster() throws {
        let entries = [
            Self.entry(1, quality: 0.3, [1, 0, 0, 0]),
            Self.entry(2, quality: 0.3, [1, 0, 0, 0]),
        ]

        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(gated.clusters.isEmpty, "全部不合格时不得有任何簇")
        #expect(Set(gated.noise.map(\.observationId)) == [1, 2])

        // 对照：无门槛时同样的邻域会成簇 —— 证明上面失败的不是邻域条件。
        let legacy = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        #expect(legacy.clusters.count == 1)
        #expect(Set(legacy.clusters[0].map(\.observationId)) == [1, 2])
        #expect(legacy.noise.isEmpty)

        // quality == floor 仍算合格（>= 语义）。
        let atFloor = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.3)
        #expect(atFloor.clusters.count == 1)
        #expect(Set(atFloor.clusters[0].map(\.observationId)) == [1, 2])
        #expect(atFloor.noise.isEmpty)
    }

    // 1c. LSH 路径（n > lshOptions.minPoints）执行同一质量门槛。
    @Test func coreQualityFloorAlsoHoldsOnLshPath() throws {
        let entries = [
            Self.entry(1, quality: 0.2, [1, 0, 0, 0]),
            Self.entry(2, quality: 1.0, [1, 0, 0, 0]),
            Self.entry(3, quality: 1.0, [1, 0, 0, 0]),
        ]
        let lshOptions = ClusterLshOptions(
            enabled: true, minPoints: 0,
            config: LshConfig(bits: 10, tables: 8, probeRadius: 2, seed: 42, unitVectors: true))
        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.5, lshOptions: lshOptions)
        #expect(gated.clusters.count == 1)
        #expect(Set(gated.clusters[0].map(\.observationId)) == [1, 2, 3])
        #expect(gated.noise.isEmpty)
        #expect(gated.clusters[0].first?.observationId == 2)
    }

    // 2a. retry：第一遍 noise 在第二遍形成新簇，追加在既有簇之后且不合并。
    @Test func retrySecondPassClustersNoiseWithoutMerging() throws {
        // minPts=3：id 1..3 互相相似成 3 点簇；id 4..5 只互为邻居（1 < minNeighbors=2）
        // → 第一遍 noise。retry minPts=2 仅对 noise 再聚 → {4,5} 成新簇。
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [1, 0, 0, 0]),
            Self.entry(3, [1, 0, 0, 0]),
            Self.entry(4, [0, 1, 0, 0]),
            Self.entry(5, [0, 1, 0, 0]),
        ]

        let legacy = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: nil)
        #expect(legacy.clusters.count == 1)
        #expect(Set(legacy.clusters[0].map(\.observationId)) == [1, 2, 3])
        #expect(Set(legacy.noise.map(\.observationId)) == [4, 5])

        let retried = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: 2)
        #expect(retried.clusters.count == 2)
        #expect(Set(retried.clusters[0].map(\.observationId)) == [1, 2, 3], "第一遍簇保持原样")
        #expect(Set(retried.clusters[1].map(\.observationId)) == [4, 5], "retry 新簇追加在末尾")
        #expect(retried.noise.isEmpty)
        #expect(retried.clusters[1].allSatisfy { $0.observationId >= 4 }, "retry 簇不含第一遍成员")

        // retryMinSamples=1 同样只作用于 noise（数值边界）。
        let retryOne = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: 1)
        #expect(retryOne.clusters.count == 2)
        #expect(Set(retryOne.clusters[1].map(\.observationId)) == [4, 5])
    }

    // 2b. retryMinSamples = nil 与省略该参数逐位一致（新旧行为不变性）。
    @Test func retryNilMatchesDefaultCall() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [1, 0, 0, 0]),
            Self.entry(3, [1, 0, 0, 0]),
            Self.entry(4, [0, 1, 0, 0]),
            Self.entry(5, [0, 1, 0, 0]),
        ]
        let omitted = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 3)
        let explicitNil = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: nil)
        #expect(omitted == explicitNil)
        #expect(omitted.clusters.count == 1)
        #expect(Set(omitted.noise.map(\.observationId)) == [4, 5])
    }

    // 2c. 空 noise：retry 无可聚之物，结果与不 retry 完全一致（数值边界）。
    @Test func retryWithEmptyNoiseAddsNothing() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [1, 0, 0, 0]),
        ]
        let plain = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        let retried = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, retryMinSamples: 1)
        #expect(retried == plain)
        #expect(retried.clusters.count == 1)
        #expect(retried.noise.isEmpty)
    }

    // 2d. 单点 noise：minPts=1 可成单点簇；minPts=2 时邻域 0 < 1，仍留在 noise。
    @Test func retrySinglePointNoiseBoundary() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [1, 0, 0, 0]),
            Self.entry(3, [1, 0, 0, 0]),
            Self.entry(4, [0, 0, 1, 0]),  // 与 1..3 正交 → 第一遍 noise
        ]

        let retryOne = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: 1)
        #expect(retryOne.clusters.count == 2)
        #expect(Set(retryOne.clusters[0].map(\.observationId)) == [1, 2, 3])
        #expect(retryOne.clusters[1].map(\.observationId) == [4], "minPts=1 时孤立点成单点簇")
        #expect(retryOne.noise.isEmpty)

        let retryTwo = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: 2)
        #expect(retryTwo.clusters.count == 1)
        #expect(retryTwo.noise.map(\.observationId) == [4], "邻域不足时仍留在 noise")
    }

    // 2e. retry 遍不放宽质量门槛：低质量 noise 点即使邻域达标也不得在第二遍成簇。
    @Test func retryKeepsQualityFloor() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [1, 0, 0, 0]),
            Self.entry(3, [1, 0, 0, 0]),
            Self.entry(4, quality: 0.1, [0, 1, 0, 0]),
            Self.entry(5, quality: 0.1, [0, 1, 0, 0]),
        ]
        let result = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, coreQualityFloor: 0.5, retryMinSamples: 2)
        #expect(result.clusters.count == 1)
        #expect(Set(result.clusters[0].map(\.observationId)) == [1, 2, 3])
        #expect(Set(result.noise.map(\.observationId)) == [4, 5], "retry 遍仍执行质量门槛")
    }

    // 3b. 进度回调语义不变：单调不回退、total 恒为全体条目数、结束时到达总数。
    @Test func progressStaysMonotoneWithRetry() throws {
        var entries: [EmbeddingEntry] = []
        for i in 0..<20 { entries.append(Self.entry(i + 1, [1, 0, 0, 0])) }
        entries.append(Self.entry(21, [0, 1, 0, 0]))  // 孤立点 → 第一遍 noise
        var progress: [(current: Int, total: Int)] = []
        _ = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 3, retryMinSamples: 2,
            onProgress: { progress.append(($0, $1)) })

        #expect(!progress.isEmpty)
        #expect(progress.allSatisfy { $0.total == 21 }, "total 恒为全体条目数")
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.current <= $1.current })
        #expect(progress.last?.current == 21, "结束时进度到达总数")
    }

    // MARK: - 质量门槛的确定性行为证据
    //
    // 以下三条替代原先 FaceClusteringAccuracyTests 的统计基线：全部用 6~8 条手写
    // embedding，只断言“哪些点进了同一个簇 / 哪些点进了 noise”，不计算 F1/ARI。

    // 共享退化方向的低质量点：floor=0 时跨身份抱团；floor=0.5 时不能当核心点。
    @Test func sharedDegradedFacesDoNotMergeAcrossIdentitiesWhenFloorIsSet() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [0.99, 0.1, 0, 0]),
            Self.entry(3, [0, 1, 0, 0]),
            Self.entry(4, [0.1, 0.99, 0, 0]),
            Self.entry(5, quality: 0.2, [0, 0, 1, 0]),
            Self.entry(6, quality: 0.2, [0, 0, 1, 0]),
        ]

        // 5/6 分别属于身份 A/B；共享退化方向让它们在 floor=0 时同簇。
        let identityByObservation: [Int: Int] = [1: 0, 2: 0, 3: 1, 4: 1, 5: 0, 6: 1]
        let ungated = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        #expect(ungated.clusters.count == 3, "floor=0：两个身份 + 共享退化方向共 3 簇")
        let degradedClusterIdentities = ungated.clusters.first { cluster in
            cluster.contains { $0.observationId == 5 }
        }.map { cluster in
            Set(cluster.map { identityByObservation[$0.observationId] ?? -1 })
        } ?? []
        #expect(
            degradedClusterIdentities == [0, 1],
            "floor=0：共享退化方向会把身份 A/B 的低质量点合并到同一簇（证伪条件）")

        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(gated.clusters.count == 2, "floor=0.5：两个高质量身份各自成簇")
        #expect(Set(gated.noise.map(\.observationId)) == [5, 6], "低质量点只能留在 noise")
        #expect(
            gated.clusters.allSatisfy { cluster in
                Set(cluster.map { identityByObservation[$0.observationId] ?? -1 }).count == 1
            },
            "floor=0.5：低质量点不得组成跨身份簇")
    }

    // 方向正确但质量低的点：floor=0 时形成同人小簇；floor=0.5 时进 noise，
    // 但不得被塞进另一个身份。
    @Test func qualityFloorMakesCorrectPoseLowQualityFacesNoiseWithoutCrossIdentityMerge() throws {
        let entries = [
            Self.entry(1, [1, 0, 0, 0]),
            Self.entry(2, [0.99, 0.1, 0, 0]),
            Self.entry(3, [0, 1, 0, 0]),
            Self.entry(4, [0.1, 0.99, 0, 0]),
            Self.entry(5, quality: 0.2, [0.6, 0, 0.8, 0]),
            Self.entry(6, quality: 0.2, [0.55, 0, 0.835, 0]),
            Self.entry(7, quality: 0.2, [0, 0.6, 0.8, 0]),
            Self.entry(8, quality: 0.2, [0, 0.55, 0.835, 0]),
        ]
        func identity(_ id: Int) -> Int {
            switch id {
            case 1, 2, 5, 6: return 0
            default: return 1
            }
        }

        let ungated = try FaceClusterer.clusterEmbeddings(entries: entries, eps: 0.9, minPts: 2)
        #expect(ungated.clusters.count == 4, "floor=0：两个高质量簇 + 两个同人低质量小簇")
        #expect(
            ungated.clusters.first { $0.contains { $0.observationId == 5 } }?
                .map(\.observationId).sorted() == [5, 6],
            "同人低质量点自成小簇")
        #expect(
            ungated.clusters.first { $0.contains { $0.observationId == 7 } }?
                .map(\.observationId).sorted() == [7, 8],
            "同人低质量点自成小簇")
        #expect(
            ungated.clusters.allSatisfy { cluster in
                Set(cluster.map { identity($0.observationId) }).count == 1
            },
            "floor=0：任何簇都不得跨身份")

        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.9, minPts: 2, coreQualityFloor: 0.5)
        #expect(gated.clusters.count == 2, "floor=0.5：只保留两个高质量簇")
        #expect(Set(gated.noise.map(\.observationId)) == [5, 6, 7, 8], "低质量点全部进 noise")
        #expect(
            gated.clusters.allSatisfy { cluster in
                Set(cluster.map { identity($0.observationId) }).count == 1
            },
            "floor=0.5：门槛的代价是少成簇，不是错聚")
    }

    // 低质量桥接点：floor=0 时连接同人两个高质量子簇；floor=0.5 时桥接点降级，
    // 同人分裂成两簇，但仍不得跨身份。
    @Test func lowQualityBridgeSplitsSameIdentitySubclustersWhenFloorIsSet() throws {
        let entries = [
            Self.entry(1, [0.7809, 0, 0.6247, 0]),
            Self.entry(2, [0.7809, 0, 0.6247, 0]),
            Self.entry(3, [0.7809, 0, -0.6247, 0]),
            Self.entry(4, [0.7809, 0, -0.6247, 0]),
            Self.entry(5, quality: 0.2, [1, 0, 0, 0]),
            Self.entry(6, [0, 1, 0, 0]),
            Self.entry(7, [0, 0.99, 0.1, 0]),
        ]
        func sameIdentityClusters(_ result: FaceClusterResult) -> Int {
            result.clusters.filter { cluster in
                !Set(cluster.map(\.observationId)).isDisjoint(with: [1, 2, 3, 4])
            }.count
        }
        func noCrossIdentity(_ result: FaceClusterResult) -> Bool {
            result.clusters.allSatisfy { cluster in
                let ids = Set(cluster.map(\.observationId))
                return ids.isDisjoint(with: [1, 2, 3, 4, 5]) || ids.isDisjoint(with: [6, 7])
            }
        }

        let ungated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.75, minPts: 2)
        #expect(sameIdentityClusters(ungated) == 1, "floor=0：桥接点把同人两侧连成 1 簇")
        #expect(noCrossIdentity(ungated), "floor=0：桥接点不得连接另一个身份")

        let gated = try FaceClusterer.clusterEmbeddings(
            entries: entries, eps: 0.75, minPts: 2, coreQualityFloor: 0.5)
        #expect(sameIdentityClusters(gated) == 2, "floor=0.5：桥接点降级，同人恰好分裂成 2 簇")
        #expect(noCrossIdentity(gated), "floor=0.5：分裂不等于错聚")
        #expect(
            gated.noise.count <= ungated.noise.count + 1,
            "降级桥接点至多自己成为噪声，不得连带其它点")
    }
}

// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityClusterPlanTests.swift
// W2c 步骤 1：SimilarityClusterPlan 纯函数测试（无数据库：快照值直接构造）。
//
// 语义对照旧 Services/SimilarityIncrementalServiceTests.swift（W2c 完成后随之
// 删除）的增量决策 7 用例（算法层 IncrementalClusterer 有独立测试，本文件只锁
// 服务层决策）：
// - incrementalPathSkipsFullClustering → firstAnalysisIsFullThenIncremental
// - removalGoesThroughIncremental → decisionDependsOnlyOnSnapshotAndParams
// - hashChangeGoesThroughIncremental → decisionDependsOnlyOnSnapshotAndParams
// - convergenceIntervalTriggersFullRecluster → fullAtConvergenceInterval
// - thresholdChangeForcesFullRecluster → fullOnParameterFingerprintMismatch
// - sequentialModeClearsState → sequentialAlwaysTakesTheFullPath
// - stateMatchesStoredResult → versionsContinueAcrossReclusters
// 加上邻域档（旧 precomputeNeighborTiers 的档位部分）与收敛间隔整数化边界。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 最小夹具（不触碰数据库）

private func makeSnapshot(
    threshold: Int = 10,
    minGroupSize: Int = 2,
    groupingMode: String = "global",
    memberCount: Int = 4,
    version: Int = 1,
    incrementalUpdates: Int = 0
) -> SimilarityClusterSnapshotRecord {
    SimilarityClusterSnapshotRecord(
        meta: SimilarityClusterMetaRecord(
            sessionId: "session",
            paramThreshold: threshold,
            paramMinGroupSize: minGroupSize,
            groupingMode: groupingMode,
            memberCount: memberCount,
            version: version,
            incrementalUpdates: incrementalUpdates,
            updatedAt: "2026-01-01T00:00:00.000Z"
        ),
        rows: []
    )
}

@Suite("SimilarityClusterPlan")
struct SimilarityClusterPlanTests {

    // MARK: 邻域阈值档（旧 precomputeNeighborTiers 档位部分）

    @Test("neighborTiers clamps steps to 0...30 and preserves the step order")
    func neighborTiersClampAndOrder() {
        #expect(SimilarityClusterPlan.neighborTierSteps == [8, 4, -4, -8])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 10) == [18, 14, 6, 2])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 25) == [30, 29, 21, 17])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 5) == [13, 9, 1, 0])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 1) == [9, 5, 0])
    }

    @Test("neighborTiers drops duplicates produced by clamping")
    func neighborTiersDeduplicates() {
        // 上界 clamp：+8/+4 都撞上已保存的 30。
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 30) == [26, 22])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 64) == [30])
        // 下界 clamp：-4/-8 都回落到已保存的 0。
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 0) == [8, 4])
        #expect(SimilarityClusterPlan.neighborTiers(threshold: 2) == [10, 6, 0])
    }

    @Test("neighborTiers never returns out-of-range or duplicate tiers")
    func neighborTiersAlwaysValid() {
        for threshold in 0...64 {
            let tiers = SimilarityClusterPlan.neighborTiers(threshold: threshold)
            #expect(tiers.allSatisfy { (0...30).contains($0) })
            #expect(Set(tiers).count == tiers.count)
            #expect(!tiers.contains(threshold))
        }
    }

    // MARK: 收敛间隔整数化

    @Test("convergenceInterval keeps integers, truncates fractions, clamps to at least 1")
    func convergenceIntervalResolution() {
        #expect(SimilarityClusterPlan.convergenceInterval(10) == 10)
        #expect(SimilarityClusterPlan.convergenceInterval(2.7) == 2)
        #expect(SimilarityClusterPlan.convergenceInterval(1) == 1)
        #expect(SimilarityClusterPlan.convergenceInterval(0) == 1)
        #expect(SimilarityClusterPlan.convergenceInterval(-3) == 1)
        // 旧实现 Int(NaN) 直接陷阱；防御性退化到 1（不崩溃）。
        #expect(SimilarityClusterPlan.convergenceInterval(.nan) == 1)
        #expect(SimilarityClusterPlan.convergenceInterval(.infinity) == 1)
        #expect(SimilarityClusterPlan.convergenceInterval(-.infinity) == 1)
        #expect(SimilarityClusterPlan.convergenceInterval(1e300) == 1)
    }

    // MARK: 决策（旧 7 用例的服务层语义）

    @Test("first analysis is full, then a matching state takes the incremental path")
    func firstAnalysisIsFullThenIncremental() {
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: nil, threshold: 10, minGroupSize: 2,
                groupingMode: .global, convergenceInterval: 10
            ) == .full(version: 1)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 1, incrementalUpdates: 0),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 10
            ) == .incremental(version: 2, incrementalUpdates: 1)
        )
        // 设置源重载（Double 原始值）等价。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 2, incrementalUpdates: 1),
                threshold: 10, minGroupSize: 2, groupingMode: .global,
                convergenceIntervalSetting: 10
            ) == .incremental(version: 3, incrementalUpdates: 2)
        )
    }

    @Test("decision depends only on snapshot and params (add/remove/hash-change stay incremental)")
    func decisionDependsOnlyOnSnapshotAndParams() {
        // 旧 removalGoesThroughIncremental / hashChangeGoesThroughIncremental：
        // 增删照片与哈希变化只改 entries，不改状态指纹 → 仍走增量。
        let snapshot = makeSnapshot(version: 1, incrementalUpdates: 0)
        let first = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 10
        )
        let second = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 10
        )
        #expect(first == .incremental(version: 2, incrementalUpdates: 1))
        #expect(first == second)
    }

    @Test("full at the convergence interval and every run keeps version continuity")
    func fullAtConvergenceInterval() {
        // 旧 convergenceIntervalTriggersFullRecluster（间隔 2）：第 3 次增量到期。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 1, incrementalUpdates: 0),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 2
            ) == .incremental(version: 2, incrementalUpdates: 1)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 2, incrementalUpdates: 1),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 2
            ) == .incremental(version: 3, incrementalUpdates: 2)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 3, incrementalUpdates: 2),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 2
            ) == .full(version: 4)
        )
        // 间隔 0 / 负数被 clamp 到 1：只有 u=0 走增量。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 1, incrementalUpdates: 0),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 0
            ) == .incremental(version: 2, incrementalUpdates: 1)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(version: 1, incrementalUpdates: 1),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 0
            ) == .full(version: 2)
        )
    }

    @Test("full on any parameter fingerprint mismatch, including switching back")
    func fullOnParameterFingerprintMismatch() {
        // 旧 thresholdChangeForcesFullRecluster：阈值变化 → 全量（版本 +1）。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(threshold: 10, version: 1),
                threshold: 4, minGroupSize: 2, groupingMode: .global, convergenceInterval: 10
            ) == .full(version: 2)
        )
        // 变回原阈值也不会复用 4 的状态（状态参数指纹已改写）。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(threshold: 4, version: 2),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 10
            ) == .full(version: 3)
        )
        // 组大小 / 分组模式不匹配同样全量。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(minGroupSize: 2, version: 1),
                threshold: 10, minGroupSize: 3, groupingMode: .global, convergenceInterval: 10
            ) == .full(version: 2)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(groupingMode: "sequential", version: 1),
                threshold: 10, minGroupSize: 2, groupingMode: .global, convergenceInterval: 10
            ) == .full(version: 2)
        )
    }

    @Test("sequential always takes the full path and never reuses incremental state")
    func sequentialAlwaysTakesTheFullPath() {
        // 旧 sequentialModeClearsState：sequential 无增量设施（前缀 run 语义）。
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: makeSnapshot(groupingMode: "global", version: 1),
                threshold: 10, minGroupSize: 2, groupingMode: .sequential, convergenceInterval: 10
            ) == .full(version: 2)
        )
        #expect(
            SimilarityClusterPlan.decision(
                snapshot: nil, threshold: 10, minGroupSize: 2,
                groupingMode: .sequential, convergenceInterval: 10
            ) == .full(version: 1)
        )
    }

    @Test("versions continue across mixed incremental and full runs")
    func versionsContinueAcrossReclusters() {
        // 旧 stateMatchesStoredResult 的版本连续性：v1 全量 → 增量 v2/v3 →
        // 到期全量 v4 → 参数变化全量 v5，版本号只增不减。
        var version = SimilarityClusterPlan.decision(
            snapshot: nil, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 2
        )
        #expect(version == .full(version: 1))

        var snapshot = makeSnapshot(version: 1, incrementalUpdates: 0)
        version = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 2
        )
        #expect(version == .incremental(version: 2, incrementalUpdates: 1))

        snapshot = makeSnapshot(version: 2, incrementalUpdates: 1)
        version = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 2
        )
        #expect(version == .incremental(version: 3, incrementalUpdates: 2))

        snapshot = makeSnapshot(version: 3, incrementalUpdates: 2)
        version = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 10, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 2
        )
        #expect(version == .full(version: 4))

        snapshot = makeSnapshot(version: 4, incrementalUpdates: 0)
        version = SimilarityClusterPlan.decision(
            snapshot: snapshot, threshold: 6, minGroupSize: 2,
            groupingMode: .global, convergenceInterval: 2
        )
        #expect(version == .full(version: 5))
    }
}

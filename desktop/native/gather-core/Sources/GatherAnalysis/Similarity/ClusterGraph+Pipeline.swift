// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph+Pipeline.swift
// 自 ClusterGraph.swift（Cut 5）纯移动：ClusterGraphPipeline（单档 / 多档 / sequential
// 入口与模式分发）；方法体、进度上报、映射逻辑逐字未改。

import Foundation
import GatherProtocol

/// Cut 5：单趟聚类（一次 HashNeighborhoodGraph / 多档并集行 + BFS）。
///
/// - 结果：DegreeGatedBFS.groups 的 wave 组内序（golden 锁定）；
/// - 状态：canonicalGroups() 的规范序（与 ClusterState 落库口径一致）；
/// - 趟数：旧路径对同一批输入做两次 O(n²) 邻接构建（clusterByHash + buildState），
///   本实现只做一次——result 与 state 同源。
///
/// 超过 defaultMaxBitsetEntries 时自动切 streaming 图：度数预扫一遍 + BFS 按需扫描
/// 邻接，额外空间 O(n)。
///
/// global = 阈值图分量 + 度门控分组；sequential = 相邻条目连续段（无图、无 state）。
public enum ClusterGraphPipeline {
    /// 位集上限（原 ClusterEngine.defaultMaxBitsetEntries，5b-2a 迁入）。
    /// n <= 该值时用对称位集邻接；超过则用 StreamingNeighborhoodGraph。
    public static let defaultMaxBitsetEntries = 32_768

    /// 单档位全量：一次图构建同时产出 ClusterResult 与 ClusterState。
    public static func run(
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ClusterGraphOutcome {
        let ids = entries.map { entry in entry.photoId }
        let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
        var workspace = ClusterWorkspace(nodeCount: entries.count)

        if entries.count <= defaultMaxBitsetEntries {
            let graph = HashNeighborhoodGraph(
                table: table, threshold: threshold, onProgress: onProgress)
            _ = DegreeGatedBFS.components(of: graph, into: &workspace)
            _ = DegreeGatedBFS.groups(
                of: graph, minGroupSize: minGroupSize, into: &workspace)
        } else {
            let degrees = table.degreesByTier(
                thresholds: [threshold], onProgress: onProgress)[0]
            let graph = StreamingNeighborhoodGraph(
                table: table, threshold: threshold, degrees: degrees)
            _ = DegreeGatedBFS.components(of: graph, into: &workspace)
            _ = DegreeGatedBFS.groups(
                of: graph, minGroupSize: minGroupSize, into: &workspace)
        }

        return ClusterGraphOutcome(
            result: result(from: workspace, ids: ids),
            state: state(from: workspace, entries: entries)
        )
    }

    /// 多档位全量：一次共享并集位图（或一遍度数预扫）+ 每档一次 BFS。
    /// 返回值与调用方 thresholds 同序（允许未排序 / 重复）。
    public static func runTiers(
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [ClusterResult] {
        guard !thresholds.isEmpty else { return [] }
        let empty = thresholds.map { _ in ClusterResult(groups: [], ungrouped: []) }
        guard !entries.isEmpty else { return empty }

        let ids = entries.map { entry in entry.photoId }
        let unique = Array(Set(thresholds)).sorted()
        let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
        var byThreshold: [Int: ClusterResult] = [:]

        if entries.count <= defaultMaxBitsetEntries {
            let graph = MultiThresholdHashGraph(
                table: table, thresholds: unique, onProgress: onProgress)
            for (index, tier) in unique.enumerated() {
                let groups = DegreeGatedBFS.groups(
                    of: graph.tierGraph(at: index), minGroupSize: minGroupSize)
                byThreshold[tier] = result(from: groups, ids: ids)
            }
        } else {
            let degreesByTier = table.degreesByTier(
                thresholds: unique, onProgress: onProgress)
            for (index, tier) in unique.enumerated() {
                let graph = StreamingNeighborhoodGraph(
                    table: table, threshold: tier, degrees: degreesByTier[index])
                let groups = DegreeGatedBFS.groups(of: graph, minGroupSize: minGroupSize)
                byThreshold[tier] = result(from: groups, ids: ids)
            }
        }

        return thresholds.map { tier in byThreshold[tier]! }
    }

    // MARK: - sequential 模式（相邻条目连续段，无图）

    /// sequential 全量：相邻条目距离 <= threshold 的连续段（原 clusterSequentially）。
    /// 无图、无增量状态（调用方据 state == nil 清空 state）。
    public static func runSequential(
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ClusterResult {
        guard !entries.isEmpty else { return ClusterResult(groups: [], ungrouped: []) }
        let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
        return sequentialResult(
            ids: entries.map { entry in entry.photoId },
            table: table,
            threshold: threshold,
            minGroupSize: minGroupSize,
            onProgress: onProgress
        )
    }

    /// sequential 多档：每档一趟相邻段扫描，返回值与 thresholds 同序。
    public static func runSequentialTiers(
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [ClusterResult] {
        guard !thresholds.isEmpty else { return [] }
        let empty = thresholds.map { _ in ClusterResult(groups: [], ungrouped: []) }
        guard !entries.isEmpty else { return empty }
        let ids = entries.map { entry in entry.photoId }
        let table = try HashGraphTable(hashes: entries.map { entry in entry.hash })
        let total = thresholds.count * entries.count
        var completed = 0
        return thresholds.map { threshold in
            let result = sequentialResult(
                ids: ids, table: table, threshold: threshold, minGroupSize: minGroupSize
            ) { current, _ in
                onProgress?(min(completed + current, total), total)
            }
            completed += entries.count
            return result
        }
    }

    // MARK: - 模式分发（服务侧统一注入点）

    /// global -> run（单趟图，result + state）；sequential -> runSequential（state = nil）。
    /// DuplicateService / AppComposition 的默认 provider 与 SimilarityService 的
    /// clusterProvider 都只调这一个入口，避免两处各写一份 switch。
    public static func run(
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        mode: HashGroupingMode,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ClusterGraphOutcome {
        switch mode {
        case .global:
            return try run(
                entries: entries, threshold: threshold,
                minGroupSize: minGroupSize, onProgress: onProgress)
        case .sequential:
            return ClusterGraphOutcome(
                result: try runSequential(
                    entries: entries, threshold: threshold,
                    minGroupSize: minGroupSize, onProgress: onProgress),
                state: nil
            )
        }
    }

    /// 多档模式分发：global -> runTiers（多档并集行），sequential -> runSequentialTiers。
    public static func runTiers(
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        mode: HashGroupingMode,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [ClusterResult] {
        switch mode {
        case .global:
            return try runTiers(
                entries: entries, thresholds: thresholds,
                minGroupSize: minGroupSize, onProgress: onProgress)
        case .sequential:
            return try runSequentialTiers(
                entries: entries, thresholds: thresholds,
                minGroupSize: minGroupSize, onProgress: onProgress)
        }
    }

    /// 相邻段扫描（全仓唯一实现；进度每 1024 条 + 结束时上报，与旧 sequential 一致）。
    private static func sequentialResult(
        ids: [String],
        table: HashGraphTable,
        threshold: Int,
        minGroupSize: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> ClusterResult {
        var groups: [[String]] = []
        var ungrouped: [String] = []
        var run: [String] = [ids[0]]

        func flush() {
            if run.count >= minGroupSize { groups.append(run) }
            else { ungrouped.append(contentsOf: run) }
        }

        for index in 1..<ids.count {
            if index % 1024 == 0 { onProgress?(index, ids.count) }
            if table.distance(index - 1, index) <= threshold {
                run.append(ids[index])
            } else {
                flush()
                run = [ids[index]]
            }
        }
        flush()
        onProgress?(ids.count, ids.count)
        return ClusterResult(groups: groups, ungrouped: ungrouped)
    }

    // MARK: 映射

    private static func result(from workspace: ClusterWorkspace, ids: [String]) -> ClusterResult {
        ClusterResult(
            groups: workspace.groupIDs(ids),
            ungrouped: workspace.ungroupedNodes.map { node in ids[node] }
        )
    }

    private static func result(from groups: [[Int]], ids: [String]) -> ClusterResult {
        let groupIDs = groups.map { group in group.map { node in ids[node] } }
        let grouped = Set(groupIDs.flatMap { $0 })
        let ungrouped = ids.filter { id in !grouped.contains(id) }
        return ClusterResult(groups: groupIDs, ungrouped: ungrouped)
    }

    private static func state(from workspace: ClusterWorkspace, entries: [HashEntry]) -> ClusterState {
        let ids = entries.map { entry in entry.photoId }
        var hashes: [String: String] = [:]
        hashes.reserveCapacity(entries.count)
        for entry in entries { hashes[entry.photoId] = entry.hash }
        return ClusterState(
            components: workspace.componentIDs(ids),
            groups: workspace.canonicalGroups().map { group in group.map { node in ids[node] } },
            hashes: hashes
        )
    }
}

// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/IncrementalClusterer.swift
// 增量聚类设施（ROADMAP 1.3）：把"新增/变更/移除照片后全量重聚类"改为邻域局部更新，
// 并保留可落库的簇状态（分量 + 已判定成组的簇 + 哈希快照）供下次复用。
//
// Cut 5 / 5b-2a：旧的全量构建（buildState）与其私有图结构（ParsedHashes /
// ComponentGraph / groupComponent / groupComponentScanning / connectedComponents）
// 整段删除——全量状态的唯一来源是 ClusterGraphPipeline.run 的单趟 outcome.state。
// 本文件只剩"增量装配"：diff -> 未受影响分量复用 -> 受影响分量交给
// ClusterGraphPipeline.run 重算 -> 并查集装配 -> 规范序落库。
//
// 语义对齐（不变量，由 IncrementalClustererTests 锁定）：
// - 划分：照片集合如何成组、谁未成组与 ClusterGraphPipeline.run 完全相同；
// - 组顺序：按种子（度门控 BFS 的起点）在输入序中的位置升序；
// - 代表图：组内首元素为种子，增量与全量相同；
// - 组内其余成员顺序为规范序（输入序升序），全量 result 为 wave 发现序，
//   不承诺逐位相同。
//
// 度门控语义（为什么不能简单用连通分量）：DegreeGatedBFS 只从
// degree + 1 >= minGroupSize 的节点向外扩展，因此 minGroupSize >= 4 时一条
// "桥接节点度数不足"的链可以把一个连通分量拆成多个簇；增量对受影响分量直接
// 调用 ClusterGraphPipeline.run（同一实现），保证与全量一致。
//
// 复杂度：
// - update（增量）：O(|added| x n) 邻域探测 + 受分量 O(k^2)（k 为受影响分量规模，
//   只有被增删改触及的分量才重算），未受影响分量直接复用旧簇。
import Foundation
import GatherProtocol

public enum IncrementalClusterer {
    /// 图缓存键：分量成员（当前输入序下标，升序）。
    typealias GraphKey = [Int]

    /// 增量更新摘要（诊断/测试观测点）。
    public struct UpdateSummary: Equatable, Sendable {
        public let addedCount: Int
        public let removedCount: Int
        public let changedCount: Int
        /// 重新计算了簇的分量数（受增删改波及）。
        public let recomputedComponentCount: Int
        /// 直接复用旧簇的分量数。
        public let reusedComponentCount: Int

        public init(
            addedCount: Int,
            removedCount: Int,
            changedCount: Int,
            recomputedComponentCount: Int,
            reusedComponentCount: Int
        ) {
            self.addedCount = addedCount
            self.removedCount = removedCount
            self.changedCount = changedCount
            self.recomputedComponentCount = recomputedComponentCount
            self.reusedComponentCount = reusedComponentCount
        }
    }

    public struct UpdateOutcome: Equatable, Sendable {
        public let state: ClusterState
        public let summary: UpdateSummary

        public init(state: ClusterState, summary: UpdateSummary) {
            self.state = state
            self.summary = summary
        }
    }

    // MARK: - 增量更新

    /// 邻域局部更新：以 state.hashes 与新条目集的 diff 判定新增 / 哈希变化 / 移除，
    /// 只重算被触及的分量，其余分量直接复用旧簇。
    ///
    /// 注意：调用方需保证 state 与该次聚类参数（threshold、minGroupSize、global 模式）
    /// 匹配，否则应先走 ClusterGraphPipeline.run（SimilarityService 负责该判定）。
    public static func update(
        state: ClusterState,
        entries: [HashEntry],
        minGroupSize: Int,
        threshold: Int
    ) throws -> UpdateOutcome {
        let table = try HashGraphTable(hashes: entries.map(\.hash))
        let ids = entries.map(\.photoId)
        let order = indexMap(ids)

        // ── diff：新增 / 移除 / 哈希变化 ──
        var addedIds: [String] = []
        var changedIds: [String] = []
        for (index, id) in ids.enumerated() {
            if let old = state.hashes[id] {
                if old != entries[index].hash { changedIds.append(id) }
            } else {
                addedIds.append(id)
            }
        }
        let removedIds = state.hashes.keys.filter { order[$0] == nil }
        // 旧状态中"失效"的 id：被移除或哈希变化（其旧分量的结构已改变，必须重算）。
        let staleIds = Set(removedIds).union(changedIds)

        // ── 旧分量分类 ──
        var affectedOldComponents = Set<Int>()
        var untouchedOldComponents: [Int: [String]] = [:] // 分量序号 -> 成员（保持旧序）
        for (componentIndex, component) in state.components.enumerated() {
            if component.contains(where: { staleIds.contains($0) }) {
                affectedOldComponents.insert(componentIndex)
            } else {
                untouchedOldComponents[componentIndex] = component
            }
        }

        // ── 并查集：未受影响分量内部直接合并；受影响分量与新增项按距离重新连边 ──
        var dsu = DisjointSet(count: table.count)
        for component in untouchedOldComponents.values {
            let indices = component.compactMap { order[$0] }
            for index in indices.dropFirst() {
                if let first = indices.first { dsu.union(first, index) }
            }
        }

        let oldComponentOfId: [String: Int] = {
            var map: [String: Int] = [:]
            for (componentIndex, component) in state.components.enumerated() {
                for id in component { map[id] = componentIndex }
            }
            return map
        }()

        // 新增项（含哈希变化的照片）：与全部现有条目做邻域探测。
        // 邻居所在的分量若原本"未受影响"，会因新增边改变结构，须改判为重算。
        for id in changedIds {
            if let oldComponent = oldComponentOfId[id] {
                affectedOldComponents.insert(oldComponent)
                untouchedOldComponents.removeValue(forKey: oldComponent)
            }
        }
        // 邻域探测集合 = 新增 + 哈希变化（变化照片按"移除旧边 + 新增新边"处理）。
        let incrementalIndices = (addedIds + changedIds).compactMap { order[$0] }.sorted()
        if !incrementalIndices.isEmpty {
            for index in incrementalIndices {
                for other in 0..<table.count where other != index {
                    if table.distance(index, other) <= threshold {
                        dsu.union(index, other)
                        if let oldComponent = oldComponentOfId[ids[other]],
                           untouchedOldComponents[oldComponent] != nil {
                            affectedOldComponents.insert(oldComponent)
                            untouchedOldComponents.removeValue(forKey: oldComponent)
                        }
                    }
                }
            }
        }

        // 受影响旧分量的幸存成员：用 ClusterGraphPipeline 单趟重算（连通分量 + 度门控分组），
        // 装配阶段同一分量直接复用其 wave 序分组，避免二次 O(k^2)。
        var groupCache: [GraphKey: [[String]]] = [:]
        for componentIndex in affectedOldComponents {
            let survivors = state.components[componentIndex]
                .filter { order[$0] != nil && !staleIds.contains($0) }
                .compactMap { order[$0] }
                .sorted()
            guard !survivors.isEmpty else { continue }
            let clustered = try ClusterGraphPipeline.run(
                entries: survivors.map { entries[$0] },
                threshold: threshold,
                minGroupSize: minGroupSize
            )
            if let components = clustered.state?.components {
                for component in components {
                    let indices = component.compactMap { order[$0] }
                    for index in indices.dropFirst() {
                        if let first = indices.first { dsu.union(first, index) }
                    }
                }
            }
            groupCache[survivors] = clustered.result.groups
        }

        // ── 组装新分量：未受影响分量原样复用，其余按并查集根分组 ──
        let componentIndices = dsu.componentIndices()
        // 未受影响分量的成员集合（用于判定"整分量可复用旧簇"）。
        let reusedMemberSets: Set<[Int]> = Set(untouchedOldComponents.values.map {
            $0.compactMap { order[$0] }.sorted()
        })
        var components: [[String]] = []
        var groups: [[String]] = []
        var recomputedComponents = 0
        var reusedComponents = 0
        // 旧簇按分量归并，供复用路径取用。
        var oldGroupsByComponent: [Int: [[String]]] = [:]
        for group in state.groups {
            guard let seed = group.first, let componentIndex = oldComponentOfId[seed] else { continue }
            oldGroupsByComponent[componentIndex, default: []].append(group)
        }

        for memberIndices in componentIndices {
            let memberIds = memberIndices.map { ids[$0] }
            components.append(memberIds)
            let key = memberIndices.sorted()
            if reusedMemberSets.contains(key) {
                // 整分量未受影响：直接复用旧簇（成员 id 不变）。
                let componentIndex = memberIds.compactMap { oldComponentOfId[$0] }.first ?? -1
                groups.append(contentsOf: oldGroupsByComponent[componentIndex] ?? [])
                reusedComponents += 1
            } else if let cachedGroups = groupCache.removeValue(forKey: key) {
                // 受影响分量未被新增边合并/拆分：复用幸存阶段算好的 wave 序分组。
                groups.append(contentsOf: cachedGroups)
                recomputedComponents += 1
            } else {
                let clustered = try ClusterGraphPipeline.run(
                    entries: memberIndices.map { entries[$0] },
                    threshold: threshold,
                    minGroupSize: minGroupSize
                )
                groups.append(contentsOf: clustered.result.groups)
                recomputedComponents += 1
            }
        }

        var hashMap: [String: String] = [:]
        hashMap.reserveCapacity(entries.count)
        for entry in entries { hashMap[entry.photoId] = entry.hash }

        let canonical = canonicalize(components: components, groups: groups, order: order)
        let summary = UpdateSummary(
            addedCount: addedIds.count,
            removedCount: removedIds.count,
            changedCount: changedIds.count,
            recomputedComponentCount: recomputedComponents,
            reusedComponentCount: reusedComponents
        )
        return UpdateOutcome(
            state: ClusterState(components: canonical.components, groups: canonical.groups, hashes: hashMap),
            summary: summary
        )
    }

    // MARK: - 结果转换

    /// 由状态 + 当前条目生成 ClusterResult（组顺序 = 种子输入序，未成组 = 输入序）。
    public static func result(
        state: ClusterState,
        entries: [HashEntry],
        minGroupSize: Int
    ) -> ClusterResult {
        let order = indexMap(entries.map(\.photoId))
        let groups = state.groups
            .filter { $0.count >= minGroupSize && order[$0[0]] != nil }
            .map { group -> [String] in
                guard let seed = group.first else { return group }
                let rest = group.dropFirst()
                    .filter { order[$0] != nil }
                    .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                return [seed] + rest
            }
            .sorted { (order[$0[0]] ?? 0) < (order[$1[0]] ?? 0) }
        let grouped = Set(groups.flatMap { $0 })
        let ungrouped = entries.map(\.photoId).filter { !grouped.contains($0) }
        return ClusterResult(groups: groups, ungrouped: ungrouped)
    }

    // MARK: - 规范序

    /// 规范序：分量内/组内按输入序升序（组保持种子在首位），分量/组按首成员输入序升序。
    private static func canonicalize(
        components: [[String]],
        groups: [[String]],
        order: [String: Int]
    ) -> (components: [[String]], groups: [[String]]) {
        let sortedComponents = components
            .map { $0.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) } }
            .filter { !$0.isEmpty }
            .sorted { (order[$0[0]] ?? 0) < (order[$1[0]] ?? 0) }
        let sortedGroups = groups
            .filter { !$0.isEmpty }
            .map { group -> [String] in
                guard let seed = group.first else { return group }
                let rest = group.dropFirst().sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
                return [seed] + rest
            }
            .sorted { (order[$0[0]] ?? 0) < (order[$1[0]] ?? 0) }
        return (sortedComponents, sortedGroups)
    }

    private static func indexMap(_ ids: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() where map[id] == nil {
            map[id] = index
        }
        return map
    }
}

// MARK: - 并查集

private struct DisjointSet {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = [Int](repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        var root = value
        while parent[root] != root { root = parent[root] }
        var current = value
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        if rootA == rootB { return }
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
    }

    /// 全部分量（根 → 成员，成员升序；分量按首成员升序）。
    mutating func componentIndices() -> [[Int]] {
        var buckets: [Int: [Int]] = [:]
        for index in 0..<parent.count {
            buckets[find(index), default: []].append(index)
        }
        return buckets.values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }
}

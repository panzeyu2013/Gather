// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph+DegreeGatedBFS.swift
// 自 ClusterGraph.swift（Cut 5）纯移动：DegreeGatedBFS（分量 / 度门控分组唯一实现），
// 算法与提前退出逐字未改；private impl 仅在本类型内使用，未放宽访问级。

import Foundation
import GatherProtocol

// MARK: - 度门控 BFS

/// 全仓唯一的分量 / 度门控分组实现。算法与生产主路径（波次 BFS）逐位一致：
/// 种子升序、每波按下标升序采纳、稀疏节点随组不扩张、组内首元素为种子。
public enum DegreeGatedBFS {
    /// 连通分量：成员升序，分量按首成员升序。
    public static func components<Graph: NeighborhoodGraph>(of graph: Graph) -> [[Int]] {
        componentsImpl(of: graph)
    }

    /// 连通分量并写入 workspace.components（workspace.groups 不变）。
    public static func components<Graph: NeighborhoodGraph>(
        of graph: Graph,
        into workspace: inout ClusterWorkspace
    ) -> [[Int]] {
        let result = componentsImpl(of: graph)
        workspace.beginComponents(nodeCount: graph.nodeCount)
        workspace.setComponents(result)
        return result
    }

    /// 度门控分组：组内首元素为种子，其余按波次发现序（每波升序）。
    public static func groups<Graph: NeighborhoodGraph>(
        of graph: Graph,
        minGroupSize: Int
    ) -> [[Int]] {
        groupsImpl(of: graph, minGroupSize: minGroupSize)
    }

    /// 分组并写入 workspace.groups（workspace.components 不变）。
    public static func groups<Graph: NeighborhoodGraph>(
        of graph: Graph,
        minGroupSize: Int,
        into workspace: inout ClusterWorkspace
    ) -> [[Int]] {
        let result = groupsImpl(of: graph, minGroupSize: minGroupSize)
        workspace.beginGroups(nodeCount: graph.nodeCount)
        workspace.setGroups(result)
        return result
    }

    // MARK: 实现

    private static func componentsImpl<Graph: NeighborhoodGraph>(of graph: Graph) -> [[Int]] {
        let count = graph.nodeCount
        guard count > 0 else { return [] }

        var visited = [Bool](repeating: false, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count)
        var result: [[Int]] = []
        var visitedCount = 0

        for start in 0..<count where !visited[start] {
            visited[start] = true
            visitedCount += 1
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var members: [Int] = [start]

            while let current = queue.popLast() {
                // 全部节点都已入分量：本分量已完整（队列中剩余节点均属本分量），
                // 无需再枚举邻域。对稠密图把 O(n^2) 的邻接枚举降为一次扫描。
                if visitedCount == count { break }
                graph.forEachNeighbor(of: current) { neighbor in
                    guard !visited[neighbor] else { return }
                    visited[neighbor] = true
                    visitedCount += 1
                    queue.append(neighbor)
                    members.append(neighbor)
                }
            }

            members.sort()
            result.append(members)
        }
        return result
    }

    private static func groupsImpl<Graph: NeighborhoodGraph>(
        of graph: Graph,
        minGroupSize: Int
    ) -> [[Int]] {
        let count = graph.nodeCount
        guard count > 0 else { return [] }

        var inGroup = [Bool](repeating: false, count: count)
        var nextMark = [Bool](repeating: false, count: count)
        var groupedCount = 0
        var result: [[Int]] = []

        for seed in 0..<count {
            if inGroup[seed] { continue }
            if graph.degree(of: seed) + 1 < minGroupSize { continue }

            var group: [Int] = [seed]
            inGroup[seed] = true
            groupedCount += 1

            var frontier: [Int] = []
            graph.forEachNeighbor(of: seed) { neighbor in frontier.append(neighbor) }

            while !frontier.isEmpty {
                // 若本波 frontier 已覆盖全部未入组节点，采纳后即整组完成，
                // 无需再对每个稠密节点做邻域并集（稠密图的关键提前退出）。
                var frontierUngrouped = 0
                for node in frontier where !inGroup[node] { frontierUngrouped += 1 }
                let adoptAll = frontierUngrouped == count - groupedCount

                var next: [Int] = []
                next.reserveCapacity(frontier.count)

                for node in frontier {
                    if inGroup[node] { continue }
                    inGroup[node] = true
                    groupedCount += 1
                    group.append(node)

                    if adoptAll { continue }
                    if graph.degree(of: node) + 1 < minGroupSize { continue }

                    graph.forEachNeighbor(of: node) { neighbor in
                        guard !inGroup[neighbor] && !nextMark[neighbor] else { return }
                        nextMark[neighbor] = true
                        next.append(neighbor)
                    }
                }

                if !next.isEmpty {
                    for node in next { nextMark[node] = false }
                    next.sort()
                }
                frontier = adoptAll ? [] : next
            }

            result.append(group)
            if groupedCount == count { break }
        }
        return result
    }
}

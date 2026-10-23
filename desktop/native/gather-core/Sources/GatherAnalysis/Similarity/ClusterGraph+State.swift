// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph+State.swift
// 自 ClusterGraph.swift（Cut 5）纯移动：ClusterWorkspace（有序结果容器）+
// ClusterGraphOutcome + 状态版本 / 指纹 / 行级 diff；类型与成员逐字未改。

import Foundation
import GatherProtocol

// MARK: - 有序结果容器

/// 一次聚类的有序结果容器：组件/分组均为节点下标，原样保留 BFS 产生的
/// 组序与组内序（不做任何排序）；`componentIDs` / `groupIDs` 按下标映射为
/// 调用方 id（输入序），`canonicalGroups()` 给出落库口径的规范序。
public struct ClusterWorkspace: Sendable, Equatable {
    public private(set) var nodeCount: Int
    public private(set) var components: [[Int]]
    public private(set) var groups: [[Int]]

    public init(nodeCount: Int = 0) {
        self.nodeCount = nodeCount
        self.components = []
        self.groups = []
    }

    /// 复用容器：清空结果并按新规模重置。
    public mutating func reset(nodeCount: Int) {
        self.nodeCount = nodeCount
        self.components = []
        self.groups = []
    }

    /// 已入组节点数（= 所有组大小之和）。
    public var groupedNodeCount: Int {
        groups.reduce(0) { total, group in total + group.count }
    }

    /// 未入组节点（输入序升序）。
    public var ungroupedNodes: [Int] {
        var grouped = [Bool](repeating: false, count: nodeCount)
        for group in groups {
            for node in group where node >= 0 && node < nodeCount {
                grouped[node] = true
            }
        }
        return (0..<nodeCount).filter { node in !grouped[node] }
    }

    /// 分量映射为 id（保持分量序 / 成员序）。
    public func componentIDs(_ ids: [String]) -> [[String]] {
        precondition(ids.count == nodeCount, "ids 数量必须与 nodeCount 一致")
        return components.map { component in component.map { node in ids[node] } }
    }

    /// 分组映射为 id（保持组序 / 组内序）。
    public func groupIDs(_ ids: [String]) -> [[String]] {
        precondition(ids.count == nodeCount, "ids 数量必须与 nodeCount 一致")
        return groups.map { group in group.map { node in ids[node] } }
    }

    /// 规范序：[seed] + 组内其余成员按输入序升序（与 ClusterState 落库口径一致）。
    /// 组序不变（BFS 的种子序）。不修改 workspace 自身。
    public func canonicalGroups() -> [[Int]] {
        groups.map { group in
            guard let seed = group.first else { return group }
            let rest = group.dropFirst().sorted()
            return [seed] + rest
        }
    }

    internal mutating func beginComponents(nodeCount: Int) {
        prepare(nodeCount: nodeCount)
        components = []
    }

    internal mutating func beginGroups(nodeCount: Int) {
        prepare(nodeCount: nodeCount)
        groups = []
    }

    internal mutating func setComponents(_ value: [[Int]]) { components = value }
    internal mutating func setGroups(_ value: [[Int]]) { groups = value }

    private mutating func prepare(nodeCount: Int) {
        if self.nodeCount != nodeCount {
            self.nodeCount = nodeCount
            components = []
            groups = []
        }
    }
}

// MARK: - 单趟流水线（结果 + 状态同源）

/// 一次图构建的产物：result 为 wave 发现序，state 为落库口径
/// （组内 [seed] + 输入序升序、组序/分量序按首成员升序）。
/// state 为 nil 只出现在 sequential 模式（无图、无增量状态），
/// 此时调用方应清空增量状态（无同源状态可用）。
public struct ClusterGraphOutcome: Sendable, Equatable {
    public let result: ClusterResult
    public let state: ClusterState?

    public init(result: ClusterResult, state: ClusterState?) {
        self.result = result
        self.state = state
    }
}

// MARK: - 状态版本 / 指纹 / 摘要 / 行级 diff（Cut 5 / 5b-2b）

/// 可落库簇状态的版本与指纹。
///
/// - currentAlgorithmVersion：状态语义版本，写入 similarity_cluster_meta.algorithm_version。
///   分量/分组/组内序语义变化（含聚类实现切换）时必须递增；读取侧版本不符即视为
///   旧 state 失效，必须全量重建并覆盖，不得增量复用。
/// - inputSignature：参数指纹（算法版本 + 阈值 + 组大小 + 模式），可读、确定性；
///   同一参数永远得到同一字符串，不同参数必不同（分隔符 + 显式键名）。
/// - stateDigest：状态内容摘要（规范序：分量内/组内排序、分量/组排序、哈希按 id 排序），
///   与输入序、行序无关；用于识别被外部改坏或跨版本残留的状态行。
///   FNV-1a 64 不是加密哈希——它只承担“能否复用”的一致性判定，不承担防篡改。
public enum ClusterStateVersioning {
    /// 当前状态语义版本（similarity_cluster_meta.algorithm_version）。
    public static let currentAlgorithmVersion = 1

    /// 参数指纹：v<算法版本>|t=<阈值>|m=<组大小>|g=<分组模式>。
    public static func inputSignature(
        threshold: Int,
        minGroupSize: Int,
        groupingMode: String
    ) -> String {
        "v\(currentAlgorithmVersion)|t=\(threshold)|m=\(minGroupSize)|g=\(groupingMode)"
    }

    /// 状态内容摘要（规范序，与行序/输入序无关；FNV-1a 64 十六进制）。
    public static func stateDigest(_ state: ClusterState) -> String {
        fingerprint(canonicalText(state))
    }

    /// 规范序分量：成员按 photoId 升序，分量按首成员升序（忽略空分量）。
    private static func canonicalComponents(_ state: ClusterState) -> [[String]] {
        state.components
            .map { component in component.sorted() }
            .filter { component in !component.isEmpty }
            .sorted { left, right in left[0] < right[0] }
    }

    /// 规范序分组：保持种子（首元素）不变、其余成员按 photoId 升序，组按种子升序。
    private static func canonicalGroups(_ state: ClusterState) -> [[String]] {
        state.groups
            .filter { group in !group.isEmpty }
            .map { group -> [String] in
                guard let seed = group.first else { return group }
                return [seed] + group.dropFirst().sorted()
            }
            .sorted { left, right in left[0] < right[0] }
    }

    /// 无歧义的规范文本：长度前缀编码，避免分隔符出现在 id 中造成摘要碰撞。
    private static func canonicalText(_ state: ClusterState) -> String {
        var text = ""
        for component in canonicalComponents(state) {
            text += "c"
            for photoId in component { appendField(photoId, to: &text) }
            text += ";"
        }
        for group in canonicalGroups(state) {
            text += "g"
            for photoId in group { appendField(photoId, to: &text) }
            text += ";"
        }
        for (photoId, hash) in state.hashes.sorted(by: { left, right in left.key < right.key }) {
            text += "h"
            appendField(photoId, to: &text)
            appendField(hash, to: &text)
            text += ";"
        }
        return text
    }

    private static func appendField(_ value: String, to text: inout String) {
        text += String(value.utf8.count)
        text += ":"
        text += value
    }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let raw = String(hash, radix: 16)
        return "fnv1a64:" + String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}

/// similarity_cluster_state 的一行业务列（session_id 由写入方统一补）。
public struct ClusterStateEntry: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let componentIndex: Int
    public let groupSeed: String?

    public init(photoId: String, hashHex: String, componentIndex: Int, groupSeed: String?) {
        self.photoId = photoId
        self.hashHex = hashHex
        self.componentIndex = componentIndex
        self.groupSeed = groupSeed
    }
}

/// 两次状态的列级 diff（Cut 5 / 5b-2b）：apply 只写 upserts + removed，
/// 内容完全相同的行不产生 SQL——替代旧的“两表 DELETE 全表再插”。
///
/// - added / changed 保持目标状态的规范序（分量序 + 成员序）；
/// - removed 按 photoId 升序（与 SQL 执行顺序无关，便于测试与日志复现）；
/// - old == nil 时全部行都算 added（首次全量，无需额外分支）。
public struct ClusterStateDiff: Equatable, Sendable {
    public let added: [ClusterStateEntry]
    public let changed: [ClusterStateEntry]
    public let removed: [String]
    public let unchangedCount: Int

    /// 需要 upsert 的行（新增 + 变更）；未变行永不进入。
    public var upserts: [ClusterStateEntry] { added + changed }

    /// 没有任何行级变更（meta 仍可能因版本号推进而写入）。
    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }

    public init(old: ClusterState?, new: ClusterState) {
        let newEntries = Self.entries(of: new)
        var oldById: [String: ClusterStateEntry] = [:]
        if let old {
            oldById.reserveCapacity(old.hashes.count)
            for entry in Self.entries(of: old) { oldById[entry.photoId] = entry }
        }

        var added: [ClusterStateEntry] = []
        var changed: [ClusterStateEntry] = []
        var unchanged = 0
        for entry in newEntries {
            guard let previous = oldById.removeValue(forKey: entry.photoId) else {
                added.append(entry)
                continue
            }
            if previous == entry {
                unchanged += 1
            } else {
                changed.append(entry)
            }
        }

        self.added = added
        self.changed = changed
        self.removed = oldById.keys.sorted()
        self.unchangedCount = unchanged
    }

    /// 状态 → 行（分量写入序即规范序；组种子取每组首元素）。
    private static func entries(of state: ClusterState) -> [ClusterStateEntry] {
        var seedOf: [String: String] = [:]
        seedOf.reserveCapacity(state.hashes.count)
        for group in state.groups {
            guard let seed = group.first else { continue }
            for photoId in group { seedOf[photoId] = seed }
        }
        var entries: [ClusterStateEntry] = []
        entries.reserveCapacity(state.hashes.count)
        for (componentIndex, component) in state.components.enumerated() {
            for photoId in component {
                entries.append(ClusterStateEntry(
                    photoId: photoId,
                    hashHex: state.hashes[photoId] ?? "",
                    componentIndex: componentIndex,
                    groupSeed: seedOf[photoId]
                ))
            }
        }
        return entries
    }
}

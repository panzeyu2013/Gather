// desktop/native/gather-core/Sources/GatherCore/Similarity/IncrementalClusterer.swift
// 增量聚类设施（ROADMAP 1.3）：把"新增/变更/移除照片后全量重聚类"改为邻域局部更新，
// 并保留可落库的簇状态（分量 + 已判定成组的簇 + 哈希快照）供下次复用。
//
// 语义对齐（不变量，由 1.6 对账矩阵门禁）：增量结果与 ClusterEngine.clusterByHash
// 的全量结果在"划分 / 组顺序 / 代表图"上一致：
// - 划分：照片集合如何成组、谁未成组完全相同；
// - 组顺序：按种子（度门控 BFS 的起点）在输入序中的位置升序——与引擎 seed 升序一致；
// - 代表图：组内首元素为种子（ClusterEngine 的 group[0]），增量与全量相同；
// - 组内其余成员顺序为规范序（输入序升序），全量引擎为 BFS 发现序，不承诺逐位相同。
//
// 度门控语义（为什么不能简单用连通分量）：ClusterEngine 的 BFS 只从
// degree + 1 >= minGroupSize 的节点向外扩展（recomputedBfs / waveBfsOverRows），
// 因此 minGroupSize >= 4 时一条"桥接节点度数不足"的链可以把一个连通分量拆成
// 多个簇；这里逐分量复刻同一规则，保证与引擎一致。
//
// 复杂度：
// - buildState（首次/参数变化/定期全局收敛）：O(n²) 距离比较，与引擎全量同阶；
// - update（增量）：O(|added| × n) 邻域探测 + Σ O(k²)（k 为受影响分量规模，
//   只有被增删改触及的分量才重算），未受影响分量直接复用旧簇。
import Foundation

/// 可落库的增量聚类状态。
/// - components：全图连通分量（含未成组的次阈值分量），规范序：分量内按输入序
///   升序、分量间按首成员输入序升序；
/// - groups：引擎语义下已成组的簇，每组首元素为种子，组间按种子输入序升序；
/// - hashes：photoId → hash 快照，用于 diff（新增 / 哈希变化 / 移除）。
public struct ClusterState: Equatable, Sendable {
    public let components: [[String]]
    public let groups: [[String]]
    public let hashes: [String: String]

    public init(components: [[String]], groups: [[String]], hashes: [String: String]) {
        self.components = components
        self.groups = groups
        self.hashes = hashes
    }
}

public enum IncrementalClusterer {
    /// 位集图缓存键：分量成员（当前输入序下标，升序）。
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

    // MARK: - 全量构建

    /// 全量构建簇状态：只在首次分析、参数（阈值/组大小/模式）变化或定期全局收敛时执行。
    public static func buildState(
        entries: [HashEntry],
        minGroupSize: Int,
        threshold: Int
    ) throws -> ClusterState {
        let parsed = try ParsedHashes(hashes: entries.map(\.hash))
        let order = indexMap(entries.map(\.photoId))
        let allIndices = Array(0..<parsed.count)
        var components: [[String]] = []
        var groups: [[String]] = []
        if allIndices.count <= ClusterEngine.defaultMaxBitsetEntries {
            // 单趟位集图：连通分量与度门控分组共用同一份邻接表/度数，
            // 与 ClusterEngine 的 bitset 路径同阶（避免二次 O(n²) 扫描）。
            let graph = ComponentGraph(parsed: parsed, indices: allIndices, threshold: threshold)
            for component in graph.components() {
                components.append(component.map { entries[graph.globalIndices[$0]].photoId })
            }
            for group in graph.groups(minGroupSize: minGroupSize) {
                groups.append(group.map { entries[graph.globalIndices[$0]].photoId })
            }
        } else {
            // 超大规模（> 32768）：位集内存不可接受，退回并查集分量 + 分量内省内存分组。
            for indexList in try connectedComponents(parsed: parsed, indices: allIndices, threshold: threshold) {
                components.append(indexList.map { entries[$0].photoId })
            }
            for component in components {
                let memberIndices = component.compactMap { order[$0] }
                let grouped = groupComponent(
                    parsed: parsed, members: memberIndices, minGroupSize: minGroupSize, threshold: threshold
                )
                for group in grouped {
                    // groupComponent 返回分量内局部下标，需经 memberIndices 映射回全局下标。
                    groups.append(group.map { entries[memberIndices[$0]].photoId })
                }
            }
        }
        var hashMap: [String: String] = [:]
        hashMap.reserveCapacity(entries.count)
        for entry in entries { hashMap[entry.photoId] = entry.hash }
        let canonical = canonicalize(components: components, groups: groups, order: order)
        return ClusterState(components: canonical.components, groups: canonical.groups, hashes: hashMap)
    }

    // MARK: - 增量更新

    /// 邻域局部更新：以 state.hashes 与新条目集的 diff 判定新增 / 哈希变化 / 移除，
    /// 只重算被触及的分量，其余分量直接复用旧簇。
    ///
    /// 注意：调用方需保证 state 与该次聚类参数（threshold、minGroupSize、global 模式）
    /// 匹配，否则应先走 buildState（SimilarityService 负责该判定）。
    public static func update(
        state: ClusterState,
        entries: [HashEntry],
        minGroupSize: Int,
        threshold: Int
    ) throws -> UpdateOutcome {
        let parsed = try ParsedHashes(hashes: entries.map(\.hash))
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
        var untouchedOldComponents: [Int: [String]] = [:] // 分量序号 → 成员（保持旧序）
        for (componentIndex, component) in state.components.enumerated() {
            if component.contains(where: { staleIds.contains($0) }) {
                affectedOldComponents.insert(componentIndex)
            } else {
                untouchedOldComponents[componentIndex] = component
            }
        }

        // ── 并查集：未受影响分量内部直接合并；受影响分量与新增项按距离重新连边 ──
        var dsu = DisjointSet(count: parsed.count)
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
                for other in 0..<parsed.count where other != index {
                    if parsed.distance(index, other) <= threshold {
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

        // 受影响旧分量的幸存成员：分量内两两比较重新发现连通性（可能被拆分）。
        // 单趟位集图在此算好后缓存；装配阶段同一分量直接复用，避免二次 O(k²)。
        var graphCache: [GraphKey: ComponentGraph] = [:]
        for componentIndex in affectedOldComponents {
            let survivors = state.components[componentIndex]
                .filter { order[$0] != nil && !staleIds.contains($0) }
                .compactMap { order[$0] }
                .sorted()
            guard !survivors.isEmpty else { continue }
            if survivors.count <= ClusterEngine.defaultMaxBitsetEntries {
                let graph = ComponentGraph(parsed: parsed, indices: survivors, threshold: threshold)
                for piece in graph.components() {
                    for index in piece.dropFirst() {
                        if let first = piece.first { dsu.union(survivors[first], survivors[index]) }
                    }
                }
                graphCache[survivors] = graph
            } else {
                let local = try connectedComponents(parsed: parsed, indices: survivors, threshold: threshold)
                for piece in local {
                    for index in piece.dropFirst() {
                        if let first = piece.first { dsu.union(first, index) }
                    }
                }
            }
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
            } else if let graph = graphCache.removeValue(forKey: key) {
                // 受影响分量未被新增边合并/拆分：复用幸存阶段算好的图直接分组。
                for group in graph.groups(minGroupSize: minGroupSize) {
                    groups.append(group.map { ids[graph.globalIndices[$0]] })
                }
                recomputedComponents += 1
            } else {
                let grouped = groupComponent(
                    parsed: parsed, members: memberIndices, minGroupSize: minGroupSize, threshold: threshold
                )
                for group in grouped { groups.append(group.map { ids[memberIndices[$0]] }) }
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

    // MARK: - 分量与分组

    /// 给定节点集合内的连通分量（按最小输入序升序，成员按输入序升序）。
    private static func connectedComponents(
        parsed: ParsedHashes,
        indices: [Int],
        threshold: Int
    ) throws -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        var local = DisjointSet(count: indices.count)
        for a in 0..<indices.count {
            for b in (a + 1)..<indices.count {
                if parsed.distance(indices[a], indices[b]) <= threshold {
                    local.union(a, b)
                }
            }
        }
        var buckets: [Int: [Int]] = [:]
        for (localIndex, globalIndex) in indices.enumerated() {
            buckets[local.find(localIndex), default: []].append(globalIndex)
        }
        return buckets.values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    /// 复刻 ClusterEngine.recomputedBfs 的度门控 BFS（分量为单位，返回值按种子升序）。
    private static func groupComponent(
        parsed: ParsedHashes,
        members: [Int],
        minGroupSize: Int,
        threshold: Int
    ) -> [[Int]] {
        let count = members.count
        if count == 0 || count < minGroupSize { return [] }
        if count > ClusterEngine.defaultMaxBitsetEntries {
            return groupComponentScanning(
                parsed: parsed, members: members, minGroupSize: minGroupSize, threshold: threshold
            )
        }
        let rowWords = (count + 63) / 64
        var rows = [UInt64](repeating: 0, count: count * rowWords)
        var degrees = [Int](repeating: 0, count: count)
        for a in 0..<count {
            for b in (a + 1)..<count {
                if parsed.distance(members[a], members[b]) <= threshold {
                    rows[a * rowWords + (b >> 6)] |= UInt64(1) << UInt64(b & 63)
                    rows[b * rowWords + (a >> 6)] |= UInt64(1) << UInt64(a & 63)
                    degrees[a] += 1
                    degrees[b] += 1
                }
            }
        }

        var visited = [Bool](repeating: false, count: count)
        var clustered = [Bool](repeating: false, count: count)
        var queued = [Bool](repeating: false, count: count)
        var groups: [[Int]] = []
        var stack: [Int] = []

        func neighbors(of index: Int) -> [Int] {
            var result: [Int] = []
            let base = index * rowWords
            for word in 0..<rowWords {
                var bits = rows[base + word]
                while bits != 0 {
                    let bit = bits.trailingZeroBitCount
                    result.append(word * 64 + bit)
                    bits &= bits - 1
                }
            }
            return result
        }

        for i in 0..<count {
            if visited[i] { continue }
            visited[i] = true
            if degrees[i] + 1 < minGroupSize { continue }

            var group = [i]
            clustered[i] = true
            stack.removeAll(keepingCapacity: true)
            for neighbor in neighbors(of: i) {
                queued[neighbor] = true
                stack.append(neighbor)
            }
            while let current = stack.popLast() {
                if visited[current] {
                    if !clustered[current] {
                        group.append(current)
                        clustered[current] = true
                    }
                    continue
                }
                visited[current] = true
                if degrees[current] + 1 >= minGroupSize {
                    for neighbor in neighbors(of: current) where !clustered[neighbor] && !queued[neighbor] {
                        queued[neighbor] = true
                        stack.append(neighbor)
                    }
                }
                if !clustered[current] {
                    group.append(current)
                    clustered[current] = true
                }
            }
            groups.append(group)
        }
        return groups
    }

    /// 超大规模分量（> 32768）的省内存回退：度数 + 按需扫描邻居的度门控 BFS
    /// （语义同 ClusterEngine.recomputedBfs，额外空间 O(k)）。
    private static func groupComponentScanning(
        parsed: ParsedHashes,
        members: [Int],
        minGroupSize: Int,
        threshold: Int
    ) -> [[Int]] {
        let count = members.count
        var degrees = [Int](repeating: 0, count: count)
        for a in 0..<count {
            for b in (a + 1)..<count {
                if parsed.distance(members[a], members[b]) <= threshold {
                    degrees[a] += 1
                    degrees[b] += 1
                }
            }
        }
        func neighbors(of index: Int) -> [Int] {
            var result: [Int] = []
            for j in 0..<count where j != index {
                if parsed.distance(members[index], members[j]) <= threshold { result.append(j) }
            }
            return result
        }

        var visited = [Bool](repeating: false, count: count)
        var clustered = [Bool](repeating: false, count: count)
        var queued = [Bool](repeating: false, count: count)
        var groups: [[Int]] = []
        var stack: [Int] = []
        for i in 0..<count {
            if visited[i] { continue }
            visited[i] = true
            if degrees[i] + 1 < minGroupSize { continue }

            var group = [i]
            clustered[i] = true
            stack.removeAll(keepingCapacity: true)
            for neighbor in neighbors(of: i) {
                queued[neighbor] = true
                stack.append(neighbor)
            }
            while let current = stack.popLast() {
                if visited[current] {
                    if !clustered[current] {
                        group.append(current)
                        clustered[current] = true
                    }
                    continue
                }
                visited[current] = true
                if degrees[current] + 1 >= minGroupSize {
                    for neighbor in neighbors(of: current) where !clustered[neighbor] && !queued[neighbor] {
                        queued[neighbor] = true
                        stack.append(neighbor)
                    }
                }
                if !clustered[current] {
                    group.append(current)
                    clustered[current] = true
                }
            }
            groups.append(group)
        }
        return groups
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

// MARK: - 解析后的哈希（与 ClusterEngine 的字节布局一致）

/// 哈希 hex → 固定宽度字节（右对齐零填充，语义同 ClusterEngine.writeHashBytes）；
/// 宽度为 8 字节（dHash 常态）时另存 UInt64 快路径。
private struct ParsedHashes {
    let count: Int
    let width: Int
    let words: [UInt64]
    let bytes: [UInt8]

    init(hashes: [String]) throws {
        var maxByteCount = 8
        for hash in hashes {
            let byteCount = max(1, (hash.count + 1) / 2)
            if byteCount > maxByteCount { maxByteCount = byteCount }
        }
        let width = maxByteCount
        var data = [UInt8](repeating: 0, count: hashes.count * width)
        var wordList: [UInt64] = []
        if width == 8 { wordList.reserveCapacity(hashes.count) }
        for (index, hash) in hashes.enumerated() {
            if hash.isEmpty { throw ClusterEngineError.invalidHash(hash) }
            var chars = Array(hash.utf8)
            if chars.count % 2 != 0 { chars.insert(48, at: 0) } // '0'
            let pairs = chars.count / 2
            let base = index * width
            for byte in 0..<width {
                let pairIndex = byte - (width - pairs)
                guard pairIndex >= 0 else { continue }
                let hi = try ParsedHashes.hexValue(chars[2 * pairIndex])
                let lo = try ParsedHashes.hexValue(chars[2 * pairIndex + 1])
                data[base + byte] = (hi << 4) | lo
            }
            if width == 8 {
                var word: UInt64 = 0
                for byte in 0..<8 {
                    word = (word << 8) | UInt64(data[base + byte])
                }
                wordList.append(word)
            }
        }
        self.count = hashes.count
        self.width = width
        self.words = wordList
        self.bytes = data
    }

    @inline(__always)
    func distance(_ a: Int, _ b: Int) -> Int {
        if width == 8 {
            return (words[a] ^ words[b]).nonzeroBitCount
        }
        var distance = 0
        let offsetA = a * width
        let offsetB = b * width
        for byte in 0..<width {
            distance += (bytes[offsetA + byte] ^ bytes[offsetB + byte]).nonzeroBitCount
        }
        return distance
    }

    private static func hexValue(_ c: UInt8) throws -> UInt8 {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: throw ClusterEngineError.invalidHash(String(UnicodeScalar(c)))
        }
    }
}

// MARK: - 单趟位集图（分量与度门控分组共用）

/// 一批节点的邻接位集与度数（局部下标 0..<k，globalIndices 映射回调用方下标）。
/// 内存与引擎的 bitset 路径同阶（k² / 8 字节），仅在 k <= 32768 时使用。
private struct ComponentGraph {
    let globalIndices: [Int]
    let rowWords: Int
    let rows: [UInt64]
    let degrees: [Int]

    init(parsed: ParsedHashes, indices: [Int], threshold: Int) {
        globalIndices = indices
        let count = indices.count
        rowWords = (count + 63) / 64
        var rows = [UInt64](repeating: 0, count: count * rowWords)
        var degrees = [Int](repeating: 0, count: count)
        for a in 0..<count {
            for b in (a + 1)..<count {
                if parsed.distance(indices[a], indices[b]) <= threshold {
                    rows[a * rowWords + (b >> 6)] |= UInt64(1) << UInt64(b & 63)
                    rows[b * rowWords + (a >> 6)] |= UInt64(1) << UInt64(a & 63)
                    degrees[a] += 1
                    degrees[b] += 1
                }
            }
        }
        self.rows = rows
        self.degrees = degrees
    }

    /// 就地遍历邻居（升序），避免逐节点物化大数组（BFS 热点）。
    @inline(__always)
    func forEachNeighbor(of index: Int, _ body: (Int) -> Void) {
        let base = index * rowWords
        for word in 0..<rowWords {
            var bits = rows[base + word]
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                body(word * 64 + bit)
                bits &= bits - 1
            }
        }
    }

    /// 全部连通分量（局部下标；分量内升序、分量间按首元素升序）。
    func components() -> [[Int]] {
        var visited = [Bool](repeating: false, count: globalIndices.count)
        var result: [[Int]] = []
        var queue: [Int] = []
        for start in 0..<globalIndices.count {
            if visited[start] { continue }
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var members = [start]
            while let current = queue.popLast() {
                forEachNeighbor(of: current) { neighbor in
                    if !visited[neighbor] {
                        visited[neighbor] = true
                        queue.append(neighbor)
                        members.append(neighbor)
                    }
                }
            }
            result.append(members.sorted())
        }
        return result.sorted { $0[0] < $1[0] }
    }

    /// 度门控分组：复刻 ClusterEngine.recomputedBfs / waveBfsOverRows 的种子与扩展规则。
    func groups(minGroupSize: Int) -> [[Int]] {
        let count = globalIndices.count
        var visited = [Bool](repeating: false, count: count)
        var clustered = [Bool](repeating: false, count: count)
        var queued = [Bool](repeating: false, count: count)
        var groups: [[Int]] = []
        var stack: [Int] = []
        for i in 0..<count {
            if visited[i] { continue }
            visited[i] = true
            if degrees[i] + 1 < minGroupSize { continue }

            var group = [i]
            clustered[i] = true
            stack.removeAll(keepingCapacity: true)
            forEachNeighbor(of: i) { neighbor in
                queued[neighbor] = true
                stack.append(neighbor)
            }
            while let current = stack.popLast() {
                if visited[current] {
                    if !clustered[current] {
                        group.append(current)
                        clustered[current] = true
                    }
                    continue
                }
                visited[current] = true
                if degrees[current] + 1 >= minGroupSize {
                    forEachNeighbor(of: current) { neighbor in
                        if !clustered[neighbor] && !queued[neighbor] {
                            queued[neighbor] = true
                            stack.append(neighbor)
                        }
                    }
                }
                if !clustered[current] {
                    group.append(current)
                    clustered[current] = true
                }
            }
            groups.append(group)
        }
        return groups
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

// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph.swift
// Cut 5：dHash 聚类的**唯一实现**（5a 建图 / 5b-1 单趟流水线 / 5b-2a 删旧实现）。
//
// 旧 ClusterEngine（753 行）与 IncrementalClusterer 内部的 ParsedHashes /
// ComponentGraph / groupComponent(Scanning) / connectedComponents / buildState
// 已在 5b-2a 整段删除：全仓原本 6 份度门控 BFS 收敛到这里的两形态
// （components = popLast 栈、groups = frontier 波次），聚类实现只剩本文件 +
// IncrementalClusterer.decide（增量装配）。
//
// 层次：
//   HashEntry / HashGroupingMode / ClusterResult  输入输出 DTO（随引擎迁入）
//   ClusterGraphError                             invalidHash（原 ClusterEngineError）
//   HashGraphTable             hex -> 定宽大端字节 + UInt64 快路径（距离/阈值判定）
//   NeighborhoodGraph          邻接枚举协议（位集图与 streaming 图共用）
//   HashNeighborhoodGraph      n <= defaultMaxBitsetEntries 的位集邻接（单档生产主路径）
//   MultiThresholdHashGraph    多档共享最高档并集行 + 逐档距离核验（预计算档位）
//   StreamingNeighborhoodGraph n > defaultMaxBitsetEntries 的省内存回退（度数 + 按需扫描）
//   DegreeGatedBFS             全仓唯一的分量/度门控分组实现（两形态）
//   ClusterWorkspace           有序结果容器（组序 / 组内序原样保留，可映射 id）
//   ClusterGraphPipeline       单档/多档 + global/sequential 入口（result 与 state 同源）
//   ClusterStateVersioning     状态语义版本 / 参数指纹 / 内容摘要（5b-2b）
//   ClusterStateEntry/Diff     similarity_cluster_state 的行级 diff（5b-2b）
//
// 语义（golden：Reconciliation/Fixtures/cluster-fixtures.json + ClusterGraphTests）：
// - 边：distance(a, b) = popcount(a XOR b) <= threshold，无权重；
// - 分量：连通分量，成员按节点下标升序，分量按首成员升序；
// - 分组：种子按节点下标升序；degree + 1 < minGroupSize 的种子不成组，
//   稀疏节点可以“随组”但不向外扩张；组内首元素恒为种子。
// - 组内序 = 波次（wave）BFS 的发现序：每波按节点下标升序批量采纳，下一波是
//   本波采纳的稠密节点邻域并集（去重后升序）。这正是生产主路径 #3 的顺序；
//   旧的栈式 BFS（#2/#4/#5/#6 的原始顺序）是 DFS 逆序，二者划分相同但组内序
//   不同。ClusterWorkspace.canonicalGroups() 提供 [seed] + 升序成员的规范序，
//   与落库的 ClusterState 口径一致（#6 经 canonicalize 后的可见顺序）。
//
// 并发：全部为不可变值类型 / 无状态 static func；单次 BFS 的临时数组不跨调用
// 共享。位集写入是双向的，聚类 CPU 扫描保持单线程（与 5a 审计 §2.5 一致）。
//
// 内存：HashNeighborhoodGraph 为 count * ceil(count/64) * 8 字节；n = 32,769 时
// 约 134 MB。超过 defaultMaxBitsetEntries 时调用方改用 StreamingNeighborhoodGraph，
// 其额外空间为 O(n)（degrees + 结果），邻接按需扫描。

import Foundation
import GatherProtocol

// MARK: - 输入 / 输出 DTO（Cut 5 / 5b-2a：随 ClusterEngine 删除迁入本文件）

/// 一条待聚类条目：照片 id + dHash hex。
public struct HashEntry: Equatable, Sendable {
    public let photoId: String
    public let hash: String

    public init(photoId: String, hash: String) {
        self.photoId = photoId
        self.hash = hash
    }
}

/// 分组模式：global = 阈值图的连通分量（度门控），sequential = 相邻条目连续段。
public enum HashGroupingMode: Sendable {
    case sequential
    case global
}

/// 一次聚类的输出：成组照片（组序 = 种子输入序）+ 未成组照片（输入序）。
public struct ClusterResult: Equatable, Sendable {
    public let groups: [[String]]
    public let ungrouped: [String]

    public init(groups: [[String]], ungrouped: [String]) {
        self.groups = groups
        self.ungrouped = ungrouped
    }
}

// MARK: - 错误

/// 聚类图输入错误（原 ClusterEngineError，5b-2a 随引擎删除迁入）：空串 / 非 hex 字符。
public enum ClusterGraphError: Error, Equatable, Sendable {
    case invalidHash(String)
}

// MARK: - 哈希表

/// hex 哈希的定宽字节表：所有哈希右对齐零填充到同一宽度（最小 8 字节，
/// 与 dHash 的 64 位常态一致），宽度为 8 时另存 UInt64 快路径。
public struct HashGraphTable: Sendable {
    /// 节点数（= 输入哈希数）。
    public let count: Int
    /// 每行字节宽度；最小 8（短哈希按零填充到 8 字节）。
    public let width: Int

    private let bytes: [UInt8]
    private let words: [UInt64]

    /// 理论上界：width 字节的最大汉明距离。threshold >= maxDistance 时任意两点相邻。
    public var maxDistance: Int { width * 8 }

    public init(hashes: [String]) throws {
        var width = 8
        for hash in hashes {
            let byteCount = max(1, (hash.utf8.count + 1) / 2)
            if byteCount > width { width = byteCount }
        }

        var bytes = [UInt8](repeating: 0, count: hashes.count * width)
        var words: [UInt64] = []
        if width == 8 { words.reserveCapacity(hashes.count) }

        for (index, hash) in hashes.enumerated() {
            if hash.isEmpty { throw ClusterGraphError.invalidHash(hash) }
            var chars = Array(hash.utf8)
            if chars.count % 2 != 0 { chars.insert(48, at: 0) } // '0'
            let pairs = chars.count / 2
            let base = index * width
            // 与 BigInt 大端展开一致：hex 的字节对落在数组高端，低位（低索引）补 0。
            for byte in 0..<width {
                let pairIndex = byte - (width - pairs)
                guard pairIndex >= 0 else { continue }
                let hi = try Self.hexValue(chars[2 * pairIndex])
                let lo = try Self.hexValue(chars[2 * pairIndex + 1])
                bytes[base + byte] = (hi << 4) | lo
            }
            if width == 8 {
                var word: UInt64 = 0
                for byte in 0..<8 {
                    word = (word << 8) | UInt64(bytes[base + byte])
                }
                words.append(word)
            }
        }

        self.count = hashes.count
        self.width = width
        self.bytes = bytes
        self.words = words
    }

    /// 两个节点下标的汉明距离。前提：0 <= a, b < count。
    @inline(__always)
    public func distance(_ a: Int, _ b: Int) -> Int {
        if width == 8 {
            return (words[a] ^ words[b]).nonzeroBitCount
        }
        var distance = 0
        var offsetA = a * width
        var offsetB = b * width
        for _ in 0..<width {
            distance += Int((bytes[offsetA] ^ bytes[offsetB]).nonzeroBitCount)
            offsetA += 1
            offsetB += 1
        }
        return distance
    }

    /// 是否在阈值内相邻（自身不与自身相邻，与邻接位集的构造一致）。
    @inline(__always)
    public func isNeighbor(_ a: Int, _ b: Int, threshold: Int) -> Bool {
        a != b && distance(a, b) <= threshold
    }

    /// 多档位度数预扫：一次 O(n²) 距离遍历同时得到每个档位的节点度。
    /// streaming 图（n > defaultMaxBitsetEntries）没有邻接位集可复用，必须先拿度数；
    /// 与旧引擎的多档度数预扫同阶，供 DegreeGatedBFS 的种子/扩张门控使用。
    /// 返回顺序与 thresholds 一致（允许未排序/重复）。
    public func degreesByTier(
        thresholds: [Int],
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> [[Int]] {
        var result = thresholds.map { _ in [Int](repeating: 0, count: count) }
        guard !thresholds.isEmpty, count > 1 else { return result }
        let step = max(512, Int(Double(count) * 0.02))
        for a in 0..<count {
            if (a + 1) % step == 0 || a + 1 == count {
                onProgress?(a + 1, count)
            }
            for b in (a + 1)..<count {
                let distance = self.distance(a, b)
                for tierIndex in 0..<thresholds.count where distance <= thresholds[tierIndex] {
                    result[tierIndex][a] += 1
                    result[tierIndex][b] += 1
                }
            }
        }
        return result
    }

    private static func hexValue(_ value: UInt8) throws -> UInt8 {
        switch value {
        case 48...57: return value - 48            // '0'-'9'
        case 97...102: return value - 87           // 'a'-'f'
        case 65...70: return value - 55            // 'A'-'F'
        default:
            throw ClusterGraphError.invalidHash(String(UnicodeScalar(value)))
        }
    }
}

// MARK: - 邻接枚举协议

/// BFS 只依赖这三个操作；位集图与 streaming 图都实现它。
/// `forEachNeighbor` 必须按节点下标升序、不重复、不含自身，且不物化邻居数组。
public protocol NeighborhoodGraph: Sendable {
    var nodeCount: Int { get }
    func degree(of node: Int) -> Int
    func forEachNeighbor(of node: Int, _ body: (Int) -> Void)
}

// MARK: - 位集图

/// n <= defaultMaxBitsetEntries（默认 32,768）的默认实现：对称位集邻接 + 度数。
public struct HashNeighborhoodGraph: NeighborhoodGraph, Sendable {
    public let nodeCount: Int
    public let threshold: Int

    private let rowWords: Int
    private let rows: [UInt64]
    private let degrees: [Int]

    /// 节点度数序列（升序下标）。供 StreamingNeighborhoodGraph 的调用方复用，
    /// 避免为同一批输入再做一趟 O(n^2) 的度数预扫。
    public var degreeSequence: [Int] { degrees }

    /// - Parameter onProgress: 逐行扫描进度（当前行 / 总行数）；仅用于 UI/诊断，
    ///   不影响分组结果。5b-1 起由 SimilarityService 的聚类相位直接透传。
    public init(
        table: HashGraphTable,
        threshold: Int,
        onProgress: ((Int, Int) -> Void)? = nil
    ) {
        let count = table.count
        self.nodeCount = count
        self.threshold = threshold
        let rowWords = (count + 63) >> 6
        self.rowWords = rowWords

        var rows = [UInt64](repeating: 0, count: count * rowWords)
        var degrees = [Int](repeating: 0, count: count)
        let step = max(512, Int(Double(count) * 0.02))

        if count > 0 {
            if threshold >= table.maxDistance {
                // 快路径：阈值不小于理论最大距离 => 任意两点相邻。逐行填满后清掉
                // 自身位，并屏蔽最后一字中超出 count 的位（否则邻接枚举会越界）。
                let remainder = count & 63
                let tailMask: UInt64 = remainder == 0
                    ? ~UInt64(0)
                    : (UInt64(1) << UInt64(remainder)) - 1
                for node in 0..<count {
                    if (node + 1) % step == 0 || node + 1 == count {
                        onProgress?(node + 1, count)
                    }
                    let base = node * rowWords
                    for word in 0..<rowWords { rows[base + word] = ~UInt64(0) }
                    rows[base + rowWords - 1] &= tailMask
                    rows[base + (node >> 6)] &= ~(UInt64(1) << UInt64(node & 63))
                    degrees[node] = count - 1
                }
            } else if threshold >= 0 {
                for a in 0..<count {
                    if (a + 1) % step == 0 || a + 1 == count {
                        onProgress?(a + 1, count)
                    }
                    let rowBase = a * rowWords
                    for b in (a + 1)..<count {
                        guard table.distance(a, b) <= threshold else { continue }
                        rows[rowBase + (b >> 6)] |= UInt64(1) << UInt64(b & 63)
                        rows[b * rowWords + (a >> 6)] |= UInt64(1) << UInt64(a & 63)
                        degrees[a] += 1
                        degrees[b] += 1
                    }
                }
            }
            // threshold < 0：空图（度数保持 0）。
        }

        self.rows = rows
        self.degrees = degrees
    }

    public func degree(of node: Int) -> Int { degrees[node] }

    @inline(__always)
    public func forEachNeighbor(of node: Int, _ body: (Int) -> Void) {
        let base = node * rowWords
        for word in 0..<rowWords {
            var bits = rows[base + word]
            while bits != 0 {
                body((word << 6) + bits.trailingZeroBitCount)
                bits &= bits - 1
            }
        }
    }

    /// 连通分量（升序成员、按首成员升序）。语义同 DegreeGatedBFS.components。
    public func components() -> [[Int]] {
        DegreeGatedBFS.components(of: self)
    }

    /// 度门控分组。语义同 DegreeGatedBFS.groups。
    public func groups(minGroupSize: Int) -> [[Int]] {
        DegreeGatedBFS.groups(of: self, minGroupSize: minGroupSize)
    }
}

// MARK: - 多档位并集位图

/// 多档位共享邻接的位集图（5b-1 的“多档并集行”）：只构造**最高档并集位图**
/// （低档边是其子集），每个档位用 tierGraph(at:) 得到一张按当前阈值逐位
/// 二次核验的只读视图。峰值内存与单档位图同阶，避免 4 档各 134 MB。
///
/// - 一次 O(n²) 距离遍历同时累加各档度数，并写入最高档并集行；
/// - 档位视图枚举升序（与 waveBfsOverFilteredRows 的位序一致），因此每档
///   的 DegreeGatedBFS.groups 与逐档独立位图逐位相同（由 parity 测试锁定）。
public struct MultiThresholdHashGraph: Sendable {
    public let nodeCount: Int
    /// 升序去重后的档位（构造前提）。
    public let thresholds: [Int]

    private let table: HashGraphTable
    private let rowWords: Int
    private let unionRows: [UInt64]
    private let degreesByTier: [[Int]]

    public init(
        table: HashGraphTable,
        thresholds: [Int],
        onProgress: ((Int, Int) -> Void)? = nil
    ) {
        precondition(!thresholds.isEmpty, "多档位图至少需要一个阈值")
        precondition(
            zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 },
            "thresholds 必须升序去重"
        )
        let count = table.count
        self.nodeCount = count
        self.thresholds = thresholds
        self.table = table
        let rowWords = (count + 63) >> 6
        self.rowWords = rowWords

        let maxTier = thresholds.last ?? 0
        var unionRows = [UInt64](repeating: 0, count: count * rowWords)
        var degreesByTier = thresholds.map { _ in [Int](repeating: 0, count: count) }
        let step = max(512, Int(Double(count) * 0.02))

        if count > 0 {
            for a in 0..<count {
                if (a + 1) % step == 0 || a + 1 == count {
                    onProgress?(a + 1, count)
                }
                let rowBase = a * rowWords
                for b in (a + 1)..<count {
                    let distance = table.distance(a, b)
                    for tierIndex in 0..<thresholds.count where distance <= thresholds[tierIndex] {
                        degreesByTier[tierIndex][a] += 1
                        degreesByTier[tierIndex][b] += 1
                    }
                    if distance <= maxTier {
                        unionRows[rowBase + (b >> 6)] |= UInt64(1) << UInt64(b & 63)
                        unionRows[b * rowWords + (a >> 6)] |= UInt64(1) << UInt64(a & 63)
                    }
                }
            }
        }

        self.unionRows = unionRows
        self.degreesByTier = degreesByTier
    }

    /// 第 index 档的邻接视图（升序枚举并集行中距离 <= thresholds[index] 的位）。
    public func tierGraph(at index: Int) -> MultiThresholdTierGraph {
        precondition(index >= 0 && index < thresholds.count, "档位下标越界")
        return MultiThresholdTierGraph(
            nodeCount: nodeCount,
            threshold: thresholds[index],
            table: table,
            rowWords: rowWords,
            rows: unionRows,
            degrees: degreesByTier[index]
        )
    }

    /// 第 index 档的度门控分组（与单档位图语义一致）。
    public func groups(at index: Int, minGroupSize: Int) -> [[Int]] {
        DegreeGatedBFS.groups(of: tierGraph(at: index), minGroupSize: minGroupSize)
    }
}

/// 多档位并集图上的单档视图：邻接 = 并集行 ∩ 当前阈值（逐位二次核验）。
public struct MultiThresholdTierGraph: NeighborhoodGraph, Sendable {
    public let nodeCount: Int
    public let threshold: Int

    private let table: HashGraphTable
    private let rowWords: Int
    private let rows: [UInt64]
    private let degrees: [Int]

    init(
        nodeCount: Int,
        threshold: Int,
        table: HashGraphTable,
        rowWords: Int,
        rows: [UInt64],
        degrees: [Int]
    ) {
        self.nodeCount = nodeCount
        self.threshold = threshold
        self.table = table
        self.rowWords = rowWords
        self.rows = rows
        self.degrees = degrees
    }

    public func degree(of node: Int) -> Int { degrees[node] }

    @inline(__always)
    public func forEachNeighbor(of node: Int, _ body: (Int) -> Void) {
        guard threshold >= 0 else { return }
        let base = node * rowWords
        for word in 0..<rowWords {
            var bits = rows[base + word]
            while bits != 0 {
                let other = (word << 6) + bits.trailingZeroBitCount
                if table.distance(node, other) <= threshold {
                    body(other)
                }
                bits &= bits - 1
            }
        }
    }
}

// MARK: - Streaming 图

/// n > defaultMaxBitsetEntries 的省内存回退：只存 degrees，邻接按需 O(n) 扫描。
/// 额外空间 O(n)；一次邻接枚举 O(n) 次距离比较，整体 O(n^2) 时间。
/// `degrees` 必须由调用方按同一 threshold 预先算好（生产路径在度数预扫中顺带得到）。
public struct StreamingNeighborhoodGraph: NeighborhoodGraph, Sendable {
    public let nodeCount: Int
    public let threshold: Int

    private let table: HashGraphTable
    private let degrees: [Int]

    public init(table: HashGraphTable, threshold: Int, degrees: [Int]) {
        precondition(degrees.count == table.count, "degrees 数量必须与哈希表节点数一致")
        self.table = table
        self.nodeCount = table.count
        self.threshold = threshold
        self.degrees = degrees
    }

    public func degree(of node: Int) -> Int { degrees[node] }

    @inline(__always)
    public func forEachNeighbor(of node: Int, _ body: (Int) -> Void) {
        guard threshold >= 0 else { return }
        for other in 0..<nodeCount where other != node {
            if table.distance(node, other) <= threshold { body(other) }
        }
    }
}

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

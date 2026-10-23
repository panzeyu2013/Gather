// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph+Neighborhood.swift
// 自 ClusterGraph.swift（Cut 5）纯移动：邻接枚举协议 + 位集 / 多档并集 / streaming 图，
// 类型与成员逐字未改，未放宽访问级。

import Foundation
import GatherProtocol

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

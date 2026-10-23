// desktop/native/gather-core/Sources/GatherAnalysis/Similarity/ClusterGraph+HashTable.swift
// 自 ClusterGraph.swift（Cut 5）纯移动：哈希表段逐字未改；private 存储随类型整体
// 迁入本文件，无跨文件引用，未放宽访问级。

import Foundation
import GatherProtocol

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

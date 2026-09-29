// desktop/native/gather-core/Sources/GatherCore/Similarity/ClusterEngine.swift
// dHash 聚类引擎移植（Phase 1 任务 1.5「对账测试框架」第二批）。
//
// TS 源：desktop/src/main/services/similarity/cluster-engine.ts
//   clusterByHash / clusterByHashMulti 及其全部辅助函数（各函数行号见注释）。
//
// 聚类判定标准：两条哈希之间的汉明距离（逐位 XOR 的 popcount）≤ threshold
// 即视为同簇连边；global 模式 = 该阈值图的连通分量（wave BFS / 重算 BFS，
// 密集节点扩张、稀疏节点随组但不扩张），sequential 模式 = 相邻条目距离
// ≤ threshold 的连续段。三条路径与 TS 完全一致：
//   - sequential：clusterSequentially（cluster-engine.ts:240-275）
//   - 小输入 bitset：clusterGloballyWithBitsets + waveBfsOverRows（283-322 / 501-579）
//   - 大输入重算：clusterGloballyRecomputed + recomputedBfs（327-361 / 420-495）
//   - 多阈值：clusterByHashMulti + clusterGloballyWithBitsetsMulti（单趟共享距离
//     遍历，§4.2 P1 性能修复）/ clusterGloballyRecomputedMulti（166-236 / 367-411）
//
// 移植说明：
//   - TS 用 BigInt(`0x${hash}`) 解析 hex 再按大端展开为字节；Swift 直接按大端
//     从 hex 串解析字节对（支持奇数字符数/大写字母，语义与 BigInt 一致）；
//     空串/非法 hex 在 TS 侧 BigInt 抛 SyntaxError，Swift 侧抛 invalidHash。
//   - popcount 查表（8/16 位）与 TS 相同；Uint16/Uint32 视图
//     按小端打包，逐位 XOR/OR 运算与分组方式无关（同 TS 注释 cluster-engine.ts:71-72）。
//   - onProgress 进度回调按 TS 原样保留（不影响分组结果）。

import Foundation

public struct HashEntry: Equatable, Sendable {
    public let photoId: String
    public let hash: String

    public init(photoId: String, hash: String) {
        self.photoId = photoId
        self.hash = hash
    }
}

public enum HashGroupingMode: Sendable {
    case sequential
    case global
}

public struct ClusterResult: Equatable, Sendable {
    public let groups: [[String]]
    public let ungrouped: [String]

    public init(groups: [[String]], ungrouped: [String]) {
        self.groups = groups
        self.ungrouped = ungrouped
    }
}

public enum ClusterEngineError: Error, Equatable {
    case invalidHash(String)
}

public enum ClusterEngine {
    // TS:12
    public static let defaultMaxBitsetEntries = 32768

    // TS:14-24
    private static let popcountTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for value in 1..<256 {
            table[value] = table[value >> 1] + UInt8(value & 1)
        }
        return table
    }()

    // TS:28-34
    private static let popcountTable16: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65536)
        for value in 1..<65536 {
            table[value] = table[value >> 1] + UInt16(value & 1)
        }
        return table
    }()

    // TS:99-147
    public static func clusterByHash(
        entries: [HashEntry],
        threshold: Int,
        minGroupSize: Int,
        mode: HashGroupingMode = .global,
        onProgress: ((Int, Int) -> Void)? = nil,
        maxBitsetEntries: Int = ClusterEngine.defaultMaxBitsetEntries
    ) throws -> ClusterResult {
        let count = entries.count
        var bytesPerHash = 8
        for i in 0..<count {
            let byteCount = hashByteCount(entries[i].hash)
            if byteCount > bytesPerHash { bytesPerHash = byteCount }
        }
        var data = [UInt8](repeating: 0, count: count * bytesPerHash)
        var ids = [String](repeating: "", count: count)
        for i in 0..<count {
            try writeHashBytes(&data, offset: i * bytesPerHash, hash: entries[i].hash, byteCount: bytesPerHash)
            ids[i] = entries[i].photoId
        }
        switch mode {
        case .sequential:
            return clusterSequentially(
                ids: ids, data: data, threshold: threshold, minGroupSize: minGroupSize,
                bytesPerHash: bytesPerHash, onProgress: onProgress)
        case .global:
            if count <= maxBitsetEntries {
                return clusterGloballyWithBitsets(
                    ids: ids, data: data, threshold: threshold, minGroupSize: minGroupSize,
                    bytesPerHash: bytesPerHash, onProgress: onProgress)
            }
            return clusterGloballyRecomputed(
                ids: ids, data: data, threshold: threshold, minGroupSize: minGroupSize,
                bytesPerHash: bytesPerHash, onProgress: onProgress)
        }
    }

    // TS:166-236
    public static func clusterByHashMulti(
        entries: [HashEntry],
        thresholds: [Int],
        minGroupSize: Int,
        mode: HashGroupingMode = .global,
        onProgress: ((Int, Int) -> Void)? = nil,
        maxBitsetEntries: Int = ClusterEngine.defaultMaxBitsetEntries
    ) throws -> [ClusterResult] {
        let unique = Array(Set(thresholds)).sorted()
        let count = entries.count
        let empty = thresholds.map { _ in ClusterResult(groups: [], ungrouped: []) }
        if count == 0 || unique.isEmpty { return empty }
        let perTierUnits = count
        let totalUnits = count * (unique.count + 1)

        // bitset 路径的进度按 0..2n 上报，钳制为单调序列（同 TS 注释 186-193 行）。
        var lastProgress = 0
        let progressForTier: (Int, Int) -> Void = { tierIndex, tierCurrent in
            let mapped = count + tierIndex * perTierUnits + min(tierCurrent, perTierUnits)
            if mapped > lastProgress { lastProgress = mapped }
            onProgress?(lastProgress, totalUnits)
        }

        var bytesPerHash = 8
        for i in 0..<count {
            let byteCount = hashByteCount(entries[i].hash)
            if byteCount > bytesPerHash { bytesPerHash = byteCount }
        }
        var data = [UInt8](repeating: 0, count: count * bytesPerHash)
        var ids = [String](repeating: "", count: count)
        for i in 0..<count {
            try writeHashBytes(&data, offset: i * bytesPerHash, hash: entries[i].hash, byteCount: bytesPerHash)
            ids[i] = entries[i].photoId
        }

        switch mode {
        case .sequential:
            return thresholds.enumerated().map { tierIndex, tier in
                let result = clusterSequentially(
                    ids: ids, data: data, threshold: tier, minGroupSize: minGroupSize,
                    bytesPerHash: bytesPerHash, onProgress: { current, _ in progressForTier(tierIndex, current) })
                    progressForTier(tierIndex, perTierUnits)
                    return result
                }
        case .global:
            if count <= maxBitsetEntries {
                // §4.2 P1 性能修复：全部档位共享一趟 pair 距离遍历（见
                // clusterGloballyWithBitsetsMulti），不再逐档调用单档 bitset 路径。
                let results = clusterGloballyWithBitsetsMulti(
                    ids: ids, data: data, thresholds: unique, minGroupSize: minGroupSize,
                    bytesPerHash: bytesPerHash, onProgress: onProgress,
                    progressForTier: progressForTier)
                // 映射回调用方阈值顺序（含重复阈值），同 TS:233-235
                let byTier = Dictionary(uniqueKeysWithValues: zip(unique, results))
                return thresholds.map { byTier[$0]! }
            }
            let results = clusterGloballyRecomputedMulti(
                ids: ids, data: data, thresholds: unique, minGroupSize: minGroupSize,
                bytesPerHash: bytesPerHash, onProgress: onProgress, totalUnits: totalUnits)
            // 映射回调用方阈值顺序（含重复阈值），同 TS:233-235
            let byTier = Dictionary(uniqueKeysWithValues: zip(unique, results).map { ($0, $1) })
            return thresholds.map { byTier[$0]! }
        }
    }

    // TS:240-275
    private static func clusterSequentially(
        ids: [String],
        data: [UInt8],
        threshold: Int,
        minGroupSize: Int,
        bytesPerHash: Int,
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        if ids.isEmpty { return ClusterResult(groups: [], ungrouped: []) }
        var groups: [[String]] = []
        var ungrouped: [String] = []
        var run: [String] = [ids[0]]

        func flush() {
            if run.count >= minGroupSize { groups.append(run) }
            else { ungrouped.append(contentsOf: run) }
        }

        for index in 1..<ids.count {
            if index % 1024 == 0 {
                onProgress?(index, ids.count)
            }
            let previousOffset = (index - 1) * bytesPerHash
            let currentOffset = index * bytesPerHash
            if hammingDistanceAt(data, offsetA: previousOffset, offsetB: currentOffset, byteCount: bytesPerHash) <= threshold {
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

    // TS:283-322
    private static func clusterGloballyWithBitsets(
        ids: [String],
        data: [UInt8],
        threshold: Int,
        minGroupSize: Int,
        bytesPerHash: Int,
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        let count = ids.count
        if count == 0 { return ClusterResult(groups: [], ungrouped: []) }

        // 对齐 32-bit 词（同 TS:297）
        let rowBytes = (((count + 7) >> 3) + 3) & ~3
        var rows = [UInt8](repeating: 0, count: count * rowBytes)
        var regionSizes = [Int](repeating: 0, count: count)
        let step = max(512, Int(Double(count) * 0.02))

        for i in 0..<count {
            if (i + 1) % step == 0 || i + 1 == count {
                onProgress?(i + 1, count)
            }
            let offsetA = i * bytesPerHash
            let rowBase = i * rowBytes
            for j in (i + 1)..<count {
                if hammingDistanceAt(data, offsetA: offsetA, offsetB: j * bytesPerHash, byteCount: bytesPerHash) <= threshold {
                    rows[rowBase + (j >> 3)] |= UInt8(1 << (j & 7))
                    rows[j * rowBytes + (i >> 3)] |= UInt8(1 << (i & 7))
                    regionSizes[i] += 1
                    regionSizes[j] += 1
                }
            }
        }

        let grouped = waveBfsOverRows(
            ids: ids, rows: rows, rowBytes: rowBytes, regionSizes: regionSizes,
            minGroupSize: minGroupSize, count: count, onProgress: onProgress)
        // 最终进度值（同 TS:320）
        onProgress?(count, count)
        return grouped
    }

    // §4.2 P1 性能修复：多档位共享一趟距离遍历的 bitset 路径。
    //
    // 旧实现逐档调用 clusterGloballyWithBitsets：主档 + 4 档各跑一趟 O(n²) 距离
    // 遍历（n ≤ maxBitsetEntries 时 ADR-027 的增量收益被端到端吃掉）。现在：
    //   1) 一次 pair 遍历，每个 pair 只算一次汉明距离；
    //   2) 按距离同时累加各档的节点度（regionSizes，稠密/稀疏门控用）；
    //   3) 最高档的边写入一张并集 bitset（低档边集是其子集）。
    // 随后每档只做一次 wave BFS：邻接行取自并集 bitset，再按当前档阈值逐位二次
    // 核验（并集行 ⊇ 档位行），得到的有效邻接与逐档独立 bitset 完全一致，分组
    // 结果逐位相同（对账 fixture 门禁覆盖）。峰值内存与旧单档路径同阶：同时只
    // 保留一张 count ≤ maxBitsetEntries 的位图。
    private static func clusterGloballyWithBitsetsMulti(
        ids: [String],
        data: [UInt8],
        thresholds: [Int],
        minGroupSize: Int,
        bytesPerHash: Int,
        onProgress: ((Int, Int) -> Void)?,
        progressForTier: @escaping (Int, Int) -> Void
    ) -> [ClusterResult] {
        let count = ids.count
        let tiers = thresholds.count
        if count == 0 || tiers == 0 {
            return thresholds.map { _ in ClusterResult(groups: [], ungrouped: []) }
        }
        let maxTier = thresholds.max() ?? 0

        // 对齐 32-bit 词（同 TS:297）
        let rowBytes = (((count + 7) >> 3) + 3) & ~3
        let rowWords = rowBytes >> 2
        var rowView = [UInt32](repeating: 0, count: count * rowWords)
        var regionSizesByTier = thresholds.map { _ in [Int](repeating: 0, count: count) }
        let step = max(512, Int(Double(count) * 0.02))

        for i in 0..<count {
            if (i + 1) % step == 0 || i + 1 == count {
                onProgress?(i + 1, count)
            }
            let offsetA = i * bytesPerHash
            let rowBase = i * rowWords
            for j in (i + 1)..<count {
                let distance = hammingDistanceAt(
                    data, offsetA: offsetA, offsetB: j * bytesPerHash, byteCount: bytesPerHash)
                for tierIndex in 0..<tiers where distance <= thresholds[tierIndex] {
                    regionSizesByTier[tierIndex][i] += 1
                    regionSizesByTier[tierIndex][j] += 1
                }
                if distance <= maxTier {
                    rowView[rowBase + (j >> 5)] |= UInt32(1) << UInt32(j & 31)
                    rowView[j * rowWords + (i >> 5)] |= UInt32(1) << UInt32(i & 31)
                }
            }
        }

        return thresholds.enumerated().map { tierIndex, tier in
            let grouped = waveBfsOverFilteredRows(
                ids: ids, rowView: rowView, rowWords: rowWords,
                data: data, bytesPerHash: bytesPerHash, threshold: tier,
                regionSizes: regionSizesByTier[tierIndex], minGroupSize: minGroupSize,
                count: count,
                onProgress: { current, _ in progressForTier(tierIndex, current) })
            progressForTier(tierIndex, count)
            return grouped
        }
    }

    // TS:501-579 的档位过滤变体：邻接行 = 最高档并集 bitset ∩ 当前档阈值。
    // 位枚举顺序（节点号升序）与 waveBfsOverRows 完全一致，分组顺序不变。
    private static func waveBfsOverFilteredRows(
        ids: [String],
        rowView: [UInt32],
        rowWords: Int,
        data: [UInt8],
        bytesPerHash: Int,
        threshold: Int,
        regionSizes: [Int],
        minGroupSize: Int,
        count: Int,
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        var inGroup = [Bool](repeating: false, count: count)
        var groups: [[String]] = []
        var ungrouped: [String] = []
        var assigned = 0

        var member = [UInt32](repeating: 0, count: rowWords)
        var frontier = [UInt32](repeating: 0, count: rowWords)
        var next = [UInt32](repeating: 0, count: rowWords)
        var rowScratch = [UInt32](repeating: 0, count: rowWords)

        /// 并集行 → 当前档有效行：并集是 maxTier 超集，逐位核验汉明距离后清除
        /// 超阈位。位序按节点号升序（trailingZeroBitCount 迭代）。
        func loadTierRow(_ node: Int, into target: inout [UInt32]) {
            let rowBase = node * rowWords
            for word in 0..<rowWords { target[word] = rowView[rowBase + word] }
            let offsetA = node * bytesPerHash
            for word in 0..<rowWords {
                var bits = target[word]
                while bits != 0 {
                    let bit = UInt32(bits.trailingZeroBitCount)
                    let other = (word << 5) | Int(bit)
                    if other >= count || hammingDistanceAt(
                        data, offsetA: offsetA, offsetB: other * bytesPerHash,
                        byteCount: bytesPerHash
                    ) > threshold {
                        target[word] &= ~(UInt32(1) << bit)
                    }
                    bits &= bits - 1
                }
            }
        }

        for seed in 0..<count {
            if inGroup[seed] { continue }
            if regionSizes[seed] + 1 < minGroupSize { continue }

            var group = [ids[seed]]
            inGroup[seed] = true
            member = [UInt32](repeating: 0, count: rowWords)
            next = [UInt32](repeating: 0, count: rowWords)
            member[seed >> 5] |= 1 << UInt32(seed & 31)
            // 初始 frontier = seed 行 ∩ 当前档（TS:536）
            loadTierRow(seed, into: &frontier)

            var hasFrontier = true
            while hasFrontier {
                next = [UInt32](repeating: 0, count: rowWords)
                // 采纳每个 frontier 节点，密集节点的行 OR 进下一 frontier；
                // 稀疏节点随组但不扩张（同 TS:542-562）
                for word in 0..<rowWords {
                    var bits = frontier[word]
                    var bit = 0
                    while bits != 0 {
                        if bits & 1 != 0 {
                            let node = word * 32 + bit
                            if !inGroup[node] {
                                inGroup[node] = true
                                member[node >> 5] |= 1 << UInt32(node & 31)
                                group.append(ids[node])
                                assigned += 1
                                if regionSizes[node] + 1 >= minGroupSize {
                                    loadTierRow(node, into: &rowScratch)
                                    for w in 0..<rowWords {
                                        next[w] |= rowScratch[w]
                                    }
                                }
                            }
                        }
                        bits >>= 1
                        bit += 1
                    }
                }
                // 下一 frontier：本波发现的、尚未入组的邻居（同 TS:565-570）
                hasFrontier = false
                for word in 0..<rowWords {
                    let nextWord = next[word] & ~member[word]
                    frontier[word] = nextWord
                    if nextWord != 0 { hasFrontier = true }
                }
            }
            groups.append(group)
            onProgress?(assigned, count)
        }

        for i in 0..<count where !inGroup[i] {
            ungrouped.append(ids[i])
        }
        onProgress?(count, count)
        return ClusterResult(groups: groups, ungrouped: ungrouped)
    }

    // TS:327-361
    private static func clusterGloballyRecomputed(
        ids: [String],
        data: [UInt8],
        threshold: Int,
        minGroupSize: Int,
        bytesPerHash: Int,
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        let count = ids.count
        if count == 0 { return ClusterResult(groups: [], ungrouped: []) }

        var regionSizes = [Int](repeating: 0, count: count)
        let step = max(512, Int(Double(count) * 0.02))

        for i in 0..<count {
            if (i + 1) % step == 0 || i + 1 == count {
                onProgress?(i + 1, count * 2)
            }
            let offsetA = i * bytesPerHash
            for j in (i + 1)..<count {
                if hammingDistanceAt(data, offsetA: offsetA, offsetB: j * bytesPerHash, byteCount: bytesPerHash) <= threshold {
                    regionSizes[i] += 1
                    regionSizes[j] += 1
                }
            }
        }

        let grouped = recomputedBfs(
            ids: ids, data: data, threshold: threshold, minGroupSize: minGroupSize,
            bytesPerHash: bytesPerHash, regionSizes: regionSizes,
            onProgress: { current, _ in onProgress?(count + current, count * 2) })
        onProgress?(count * 2, count * 2)
        return grouped
    }

    // TS:367-411
    private static func clusterGloballyRecomputedMulti(
        ids: [String],
        data: [UInt8],
        thresholds: [Int],
        minGroupSize: Int,
        bytesPerHash: Int,
        onProgress: ((Int, Int) -> Void)?,
        totalUnits: Int?
    ) -> [ClusterResult] {
        let count = ids.count
        let tiers = thresholds.count
        let units = totalUnits ?? count * (tiers + 1)
        if count == 0 { return thresholds.map { _ in ClusterResult(groups: [], ungrouped: []) } }

        var regionSizesByTier = thresholds.map { _ in [Int](repeating: 0, count: count) }
        let step = max(512, Int(Double(count) * 0.02))

        for i in 0..<count {
            if (i + 1) % step == 0 || i + 1 == count {
                onProgress?(i + 1, units)
            }
            let offsetA = i * bytesPerHash
            for j in (i + 1)..<count {
                let distance = hammingDistanceAt(data, offsetA: offsetA, offsetB: j * bytesPerHash, byteCount: bytesPerHash)
                for tierIndex in 0..<tiers where distance <= thresholds[tierIndex] {
                    regionSizesByTier[tierIndex][i] += 1
                    regionSizesByTier[tierIndex][j] += 1
                }
            }
        }

        var results: [ClusterResult] = []
        for tierIndex in 0..<tiers {
            results.append(recomputedBfs(
                ids: ids, data: data, threshold: thresholds[tierIndex], minGroupSize: minGroupSize,
                bytesPerHash: bytesPerHash, regionSizes: regionSizesByTier[tierIndex],
                onProgress: { current, _ in onProgress?(count + tierIndex * count + min(current, count), units) }))
            onProgress?(count + (tierIndex + 1) * count, units)
        }
        return results
    }

    // TS:420-495
    private static func recomputedBfs(
        ids: [String],
        data: [UInt8],
        threshold: Int,
        minGroupSize: Int,
        bytesPerHash: Int,
        regionSizes: [Int],
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        let count = ids.count
        func neighbors(of index: Int) -> [Int] {
            var result: [Int] = []
            let offsetA = index * bytesPerHash
            for j in 0..<count where j != index {
                if hammingDistanceAt(data, offsetA: offsetA, offsetB: j * bytesPerHash, byteCount: bytesPerHash) <= threshold {
                    result.append(j)
                }
            }
            return result
        }

        var visited = [Bool](repeating: false, count: count)
        var clustered = [Bool](repeating: false, count: count)
        var queued = [Bool](repeating: false, count: count)
        var groups: [[String]] = []
        var seedStack: [Int] = []

        for i in 0..<count {
            if visited[i] { continue }
            visited[i] = true
            if regionSizes[i] + 1 < minGroupSize { continue }

            var group = [ids[i]]
            clustered[i] = true
            seedStack.removeAll(keepingCapacity: true)
            for neighbor in neighbors(of: i) {
                queued[neighbor] = true
                seedStack.append(neighbor)
            }
            while let current = seedStack.popLast() {
                if visited[current] {
                    if !clustered[current] {
                        group.append(ids[current])
                        clustered[current] = true
                    }
                    continue
                }
                visited[current] = true
                if regionSizes[current] + 1 >= minGroupSize {
                    for neighbor in neighbors(of: current) {
                        if !clustered[neighbor] && !queued[neighbor] {
                            queued[neighbor] = true
                            seedStack.append(neighbor)
                        }
                    }
                }
                if !clustered[current] {
                    group.append(ids[current])
                    clustered[current] = true
                }
            }
            groups.append(group)
            onProgress?(i + 1, count)
        }

        var ungrouped: [String] = []
        for i in 0..<count where !clustered[i] {
            ungrouped.append(ids[i])
        }
        return ClusterResult(groups: groups, ungrouped: ungrouped)
    }

    // TS:501-579（wave BFS：32 位词视图等价 TS 的 Uint32Array 视图，逐位运算与
    // 分组方式无关；frontier 采用词内从低位到高位枚举，与 TS 字节序枚举的
    // 节点顺序一致——均按节点号升序）
    private static func waveBfsOverRows(
        ids: [String],
        rows: [UInt8],
        rowBytes: Int,
        regionSizes: [Int],
        minGroupSize: Int,
        count: Int,
        onProgress: ((Int, Int) -> Void)?
    ) -> ClusterResult {
        let rowWords = rowBytes >> 2
        // TS: new Uint32Array(rows.buffer) —— 小端打包
        var rowView = [UInt32](repeating: 0, count: rows.count / 4)
        for i in stride(from: 0, to: rows.count, by: 4) {
            rowView[i / 4] = UInt32(rows[i])
                | (UInt32(rows[i + 1]) << 8)
                | (UInt32(rows[i + 2]) << 16)
                | (UInt32(rows[i + 3]) << 24)
        }

        var inGroup = [Bool](repeating: false, count: count)
        var groups: [[String]] = []
        var ungrouped: [String] = []
        var assigned = 0

        var member = [UInt32](repeating: 0, count: rowWords)
        var frontier = [UInt32](repeating: 0, count: rowWords)
        var next = [UInt32](repeating: 0, count: rowWords)

        for seed in 0..<count {
            if inGroup[seed] { continue }
            if regionSizes[seed] + 1 < minGroupSize { continue }

            var group = [ids[seed]]
            inGroup[seed] = true
            member = [UInt32](repeating: 0, count: rowWords)
            frontier = [UInt32](repeating: 0, count: rowWords)
            next = [UInt32](repeating: 0, count: rowWords)
            member[seed >> 5] |= 1 << UInt32(seed & 31)
            // 初始 frontier = seed 行（TS:536）
            let seedRowStart = seed * rowWords
            frontier = Array(rowView[seedRowStart..<(seedRowStart + rowWords)])

            var hasFrontier = true
            while hasFrontier {
                next = [UInt32](repeating: 0, count: rowWords)
                // 采纳每个 frontier 节点，密集节点的行 OR 进下一 frontier；
                // 稀疏节点随组但不扩张（同 TS:542-562）
                for word in 0..<rowWords {
                    var bits = frontier[word]
                    var bit = 0
                    while bits != 0 {
                        if bits & 1 != 0 {
                            let node = word * 32 + bit
                            if !inGroup[node] {
                                inGroup[node] = true
                                member[node >> 5] |= 1 << UInt32(node & 31)
                                group.append(ids[node])
                                assigned += 1
                                if regionSizes[node] + 1 >= minGroupSize {
                                    let rowBase = node * rowWords
                                    for w in 0..<rowWords {
                                        next[w] |= rowView[rowBase + w]
                                    }
                                }
                            }
                        }
                        bits >>= 1
                        bit += 1
                    }
                }
                // 下一 frontier：本波发现的、尚未入组的邻居（同 TS:565-570）
                hasFrontier = false
                for word in 0..<rowWords {
                    let nextWord = next[word] & ~member[word]
                    frontier[word] = nextWord
                    if nextWord != 0 { hasFrontier = true }
                }
            }
            groups.append(group)
            onProgress?(assigned, count)
        }

        for i in 0..<count where !inGroup[i] {
            ungrouped.append(ids[i])
        }
        return ClusterResult(groups: groups, ungrouped: ungrouped)
    }

    // TS:54-65（BigInt 大端展开；Swift 按大端直接解析 hex 字节对，
    // 奇数字符数在 TS 侧由 BigInt 补 0，这里等价前置 '0'）
    private static func writeHashBytes(
        _ data: inout [UInt8],
        offset: Int,
        hash: String,
        byteCount: Int
    ) throws {
        if hash.isEmpty {
            // TS: BigInt("0x") 抛 SyntaxError
            throw ClusterEngineError.invalidHash(hash)
        }
        var chars = Array(hash.utf8)
        if chars.count % 2 != 0 {
            chars.insert(48, at: 0) // '0'
        }
        let bytePairs = chars.count / 2
        // TS 从 value 的低字节开始写（data[byteCount-1] = LSB）：哈希的字节
        // 对落在数组低端（高索引），高位（低索引）补 0 —— 短哈希因此与其
        // 零填充的长哈希逐字节一致（零填充语义，同 TS:51-53 注释）。
        for byte in 0..<byteCount {
            let pairIndex = byte - (byteCount - bytePairs)
            if pairIndex >= 0 {
                let hi = try hexDigitValue(chars[2 * pairIndex])
                let lo = try hexDigitValue(chars[2 * pairIndex + 1])
                data[offset + byte] = (hi << 4) | lo
            } else {
                data[offset + byte] = 0
            }
        }
    }

    // TS:67-69
    private static func hashByteCount(_ hash: String) -> Int {
        return max(1, (hash.count + 1) / 2)
    }

    // TS:73-97。8 字节布局走 16-bit 查表（4 次查表，同 TS 的 Uint16 视图）；
    // 其余字节数走 8-bit 查表。Uint16 分组按小端打包，逐位 XOR 与分组无关。
    private static func hammingDistanceAt(
        _ data: [UInt8],
        offsetA: Int,
        offsetB: Int,
        byteCount: Int
    ) -> Int {
        if byteCount == 8 {
            let table16 = popcountTable16
            let wordA = offsetA >> 1
            let wordB = offsetB >> 1
            let d0 = Int(table16[Int(word16LE(data, wordA) ^ word16LE(data, wordB))])
            let d1 = Int(table16[Int(word16LE(data, wordA + 1) ^ word16LE(data, wordB + 1))])
            let d2 = Int(table16[Int(word16LE(data, wordA + 2) ^ word16LE(data, wordB + 2))])
            let d3 = Int(table16[Int(word16LE(data, wordA + 3) ^ word16LE(data, wordB + 3))])
            return d0 + d1 + d2 + d3
        }
        let table = popcountTable
        var distance = 0
        for byte in 0..<byteCount {
            let value = data[offsetA + byte] ^ data[offsetB + byte]
            distance += Int(table[Int(value)])
        }
        return distance
    }

    private static func word16LE(_ data: [UInt8], _ word: Int) -> UInt16 {
        let base = word << 1
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func hexDigitValue(_ c: UInt8) throws -> UInt8 {
        switch c {
        case 48...57: return c - 48            // '0'-'9'
        case 97...102: return c - 87           // 'a'-'f'
        case 65...70: return c - 55            // 'A'-'F'
        default:
            throw ClusterEngineError.invalidHash(String(UnicodeScalar(c)))
        }
    }
}

// desktop/native/gather-core/Sources/GatherApplication/Services/Semantic/SemanticIndex.swift
// P1 下一波 / §3.11.5：图像语义（Vision 标签 + feature print）的索引与检索。
//
// 能力面（全部本地、零模型资产）：
// - 采集：VNGenerateImageFeaturePrintRequest（维度随系统，~2048）+ VNClassifyImageRequest
//   top-N 标签；ModelReviewService 的 1280 解码上顺手做，边际成本低；
// - 存储：photo_semantics（Float16 压缩 ~4KB/张，默认只在 semantic_index_enabled=1 时建）；
// - 检索：图搜图 = 余弦 top-N；文搜 = **标签文本匹配**（不做 CLIP 文本编码：无模型资产）。
//
// 降级：Vision 不可用 → .unavailable，调用方跳过并记 semantic_unavailable，绝不阻断初审。
import Foundation
import CoreGraphics
import GatherProtocol
import GatherPersistence

#if canImport(Vision)
import Vision
#endif

// MARK: - 标签

/// 一个 Vision 分类标签（英文原串 + 置信度）。UI 自行做本地化映射。
public struct SemanticLabel: Codable, Equatable, Sendable, Comparable {
    public let label: String
    public let confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }

    /// 稳定排序：置信度降序、同名升序（同一批标签两次编码结果一致）。
    public static func < (lhs: SemanticLabel, rhs: SemanticLabel) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        return lhs.label < rhs.label
    }

    /// 归一化标签（小写、下划线换空格）——标签匹配与 Jaccard 都用它。
    public var normalizedKey: String {
        label.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}

/// 一次采集结果（存 photo_semantics 的最小单元）。
public struct SemanticObservation: Equatable, Sendable {
    public let labels: [SemanticLabel]
    public let feature: [Float]

    public init(labels: [SemanticLabel], feature: [Float]) {
        self.labels = labels
        self.feature = feature
    }
}

public enum SemanticFailure: Error, Equatable, CustomStringConvertible, Sendable {
    /// 系统无 Vision（或当前构建禁用）：跳过，不阻断。
    case unsupported
    case requestFailed(String)

    public var description: String {
        switch self {
        case .unsupported: return "semantic_unavailable"
        case .requestFailed(let reason): return "semantic_unavailable: \(reason)"
        }
    }
}

// MARK: - 向量编解码（Float16）

/// feature print 的 Float16 压缩存取。
///
/// 为什么 Float16：~2048 维 × 4B = 8KB/张，20k 张 160MB；Float16 减半（~80MB），
/// 而余弦相似度的判别力几乎不受影响（观测值量级 ±10，Float16 相对误差 ~1e-3）。
public enum SemanticFeatureCodec {
    /// Float32 → IEEE-754 half 位模式（round-to-nearest-even）。
    ///
    /// 为什么手写：x86_64 macOS 没有 `Float16`（`_Float16` 被标为 unavailable），
    /// 但 universal 包的 Intel slice 必须能编译。手写实现与 arm64 原生往返逐位一致
    /// （由 `halfCodecMatchesNative` 在 arm64 上对 65536 个位模式全量校验）。
    static func halfBits(from value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        let mantissa = bits & 0x007F_FFFF
        if exponent == 0xFF {
            return sign | 0x7C00 | (mantissa == 0 ? 0 : 0x0200)
        }
        let halfExponent = exponent - 127 + 15
        if halfExponent >= 0x1F { return sign | 0x7C00 }
        if halfExponent <= 0 {
            if halfExponent < -10 { return sign }
            let extended = mantissa | 0x0080_0000
            let shift = UInt32(14 - halfExponent)
            var half = UInt16(truncatingIfNeeded: extended >> shift)
            let roundBit = UInt32(1) << (shift - 1)
            if (extended & roundBit) != 0,
               ((extended & (roundBit - 1)) != 0 || (half & 1) == 1) {
                half &+= 1
            }
            return sign | half
        }
        var half = sign | UInt16(halfExponent << 10)
            | UInt16(truncatingIfNeeded: mantissa >> 13)
        let roundBit = UInt32(1) << 12
        if (mantissa & roundBit) != 0,
           ((mantissa & (roundBit - 1)) != 0 || (half & 1) == 1) {
            half &+= 1
        }
        return half
    }

    /// IEEE-754 half 位模式 → Float32（保留符号/指数/尾数；NaN 仍为 NaN）。
    static func float(fromHalf bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1F)
        let fraction = UInt32(bits & 0x03FF)
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            var unbiased = -14
            var normalized = fraction
            while normalized & 0x0400 == 0 {
                normalized <<= 1
                unbiased -= 1
            }
            normalized &= 0x03FF
            let exponentBits = UInt32(unbiased + 127) << 23
            return Float(bitPattern: sign | exponentBits | (normalized << 13))
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (fraction << 13))
        }
        // exponent 是 1...30 的 UInt32；减 15 可能下溢，先转 Int 再回 UInt32。
        let exponentBits = UInt32(Int(exponent) - 15 + 127) << 23
        return Float(bitPattern: sign | exponentBits | (fraction << 13))
    }

    /// Float32 向量 → 小端 Float16 BLOB。
    public static func encode(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            let bits = halfBits(from: value)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    /// 小端 Float16 BLOB → Float32 向量（长度不符/空数据返回 []）。
    public static func decode(_ data: Data?, dimension: Int) -> [Float] {
        guard let data, !data.isEmpty else { return [] }
        let expected = data.count / 2
        guard expected > 0 else { return [] }
        // dimension 只是提示：老行可能没写；以 BLOB 长度为准（不允许半个元素）。
        if dimension > 0, dimension != expected { return [] }
        var values = [Float]()
        values.reserveCapacity(expected)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let low = UInt16(data[index])
            let high = UInt16(data[data.index(after: index)])
            let bits = low | (high << 8)
            values.append(float(fromHalf: bits))
            index = data.index(index, offsetBy: 2)
        }
        return values
    }
}

// MARK: - 检索结果

public enum SemanticSearchMethod: String, Equatable, Sendable {
    case featurePrint
    case labels
}

public struct SemanticSearchHit: Equatable, Sendable {
    public let photoId: String
    /// 余弦（图搜图）；标签匹配置 nil（不要用 Jaccard 冒充相似度）。
    public let similarity: Double?
    public let labels: [SemanticLabel]
    public let matchedLabels: [String]

    public init(
        photoId: String,
        similarity: Double?,
        labels: [SemanticLabel],
        matchedLabels: [String]
    ) {
        self.photoId = photoId
        self.similarity = similarity
        self.labels = labels
        self.matchedLabels = matchedLabels
    }
}

public struct SemanticSearchOutcome: Equatable, Sendable {
    public let sessionId: String
    public let method: SemanticSearchMethod
    public let hits: [SemanticSearchHit]
    /// 参与比较的行数（诊断/进度用）。
    public let scanned: Int
    /// 维度不符被跳过的行数（模型升级/损坏行；不抛错）。
    public let skipped: Int
    /// 无法检索的原因（"语义索引未建立"等）：hits 为空时给 UI 显示，不抛错。
    public let unavailableReason: String?

    public init(
        sessionId: String,
        method: SemanticSearchMethod,
        hits: [SemanticSearchHit],
        scanned: Int,
        skipped: Int,
        unavailableReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.method = method
        self.hits = hits
        self.scanned = scanned
        self.skipped = skipped
        self.unavailableReason = unavailableReason
    }
}

/// 场景分组结果（NavigationService 的 scene 组扩展；group_type 仍是 'scene'）。
public struct SemanticSceneGroup: Equatable, Sendable {
    public let photoIds: [String]
    /// 组内共享标签（前 3 个，用于 explanation："同场景：婚礼/室内"）。
    public let labels: [String]
    public let basis: Basis

    public enum Basis: String, Equatable, Sendable {
        case labels
        case embedding
    }

    public init(photoIds: [String], labels: [String], basis: Basis) {
        self.photoIds = photoIds
        self.labels = labels
        self.basis = basis
    }
}

/// 解码后的语义行（避免检索时重复解码 BLOB）。
public struct SemanticVector: Equatable, Sendable {
    public let photoId: String
    public let labels: [SemanticLabel]
    public let vector: [Float]
    public let modelVersion: String

    public init(photoId: String, labels: [SemanticLabel], vector: [Float], modelVersion: String) {
        self.photoId = photoId
        self.labels = labels
        self.vector = vector
        self.modelVersion = modelVersion
    }

    public var labelKeys: Set<String> {
        Set(labels.map(\.normalizedKey))
    }
}

// MARK: - 索引

/// 余弦 / 标签匹配的索引与阈值判定。纯计算 + 一次读库，不写任何表。
public final class SemanticIndex {
    /// 场景分组：标签 Jaccard 下限 / embedding 余弦下限（plan §3.11.5）。
    public static let defaultLabelJaccard = 0.5
    public static let defaultCosine = 0.92
    /// 图搜图的默认下限：同图不同尺寸通常 > 0.95，跨图多在 0.6 以下。
    public static let defaultMinSimilarity = 0.92
    /// 场景分组单次参与的最大行数（贪心 O(n²)；20k 全扫会卡主线程）。
    public static let maxClusterRows = 2_000
    /// 检索单次最多比较的行数（B7）。
    ///
    /// 原检索路径用 `loadRows(sessionId:limit: 0)`（全会话无上限）：20k 张 × 2048 维
    /// Float16 会在一次检索里同时展开成 ~160MB+ 的 [Float]，而且每次检索重算。现在
    /// 改成分块流式比较（见 scanChunkRows）+ 只保留 top-K 候选，内存与"命中数"成正比
    /// 而不是与"会话张数"成正比；超过上限的会话按 photoId 顺序只比较前 maxScanRows 行。
    public static let maxScanRows = 20_000
    /// 单批解码的行数上限（2048 维 × 512 ≈ 4MB 向量 + 2MB BLOB）。
    public static let scanChunkRows = 512

    private let store: any PhotoSemanticsStore

    public init(store: any PhotoSemanticsStore) {
        self.store = store
    }

    // MARK: 读

    /// 会话内全部向量（可限制行数；limit <= 0 = 不限）。
    public func vectors(sessionId: String, limit: Int = 0) throws -> (vectors: [SemanticVector], skipped: Int) {
        try decode(store.loadRows(sessionId: sessionId, limit: limit))
    }

    /// 指定照片的向量（图搜图的查询侧）。
    public func vector(photoId: String) throws -> SemanticVector? {
        guard let row = try store.load(photoId: photoId) else { return nil }
        let labels = Self.decodeLabels(row.labelsJson)
        let vector = SemanticFeatureCodec.decode(row.feature, dimension: row.featureDim)
        guard !vector.isEmpty else { return nil }
        return SemanticVector(
            photoId: row.photoId, labels: labels, vector: vector, modelVersion: row.modelVersion)
    }

    // MARK: 图搜图

    /// 与给定照片相似的照片（余弦降序）。查询照片自身不进入结果。
    public func similar(
        to photoId: String,
        sessionId: String,
        limit: Int = 50,
        minSimilarity: Double = SemanticIndex.defaultMinSimilarity
    ) throws -> SemanticSearchOutcome {
        guard limit > 0 else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .featurePrint, hits: [], scanned: 0, skipped: 0,
                unavailableReason: "limit must be positive")
        }
        guard let query = try vector(photoId: photoId) else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .featurePrint, hits: [], scanned: 0, skipped: 0,
                unavailableReason: "semantic_unavailable: 当前照片没有语义向量")
        }
        // B7：分块扫描 + 有界 top-K（结果与"全量解码 → 排序 → prefix(limit)"一致）。
        var hits: [SemanticSearchHit] = []
        let scan = try scanVectors(
            sessionId: sessionId,
            limit: Self.maxScanRows,
            preferredDimension: query.vector.count
        ) { row in
            guard row.photoId != photoId else { return }
            let similarity = Self.cosine(query.vector, row.vector)
            guard similarity >= minSimilarity else { return }
            Self.insertBounded(
                SemanticSearchHit(
                    photoId: row.photoId, similarity: similarity,
                    labels: row.labels, matchedLabels: []),
                into: &hits,
                capacity: limit,
                rankedBefore: Self.similarityRankedBefore)
        }
        return SemanticSearchOutcome(
            sessionId: sessionId, method: .featurePrint, hits: hits,
            scanned: scan.scanned, skipped: scan.skipped)
    }

    // MARK: 多选种子（图搜图·集合版）

    /// 以**多张选中照片的平均向量**做相似检索（Wave2 / task-14）。
    ///
    /// 为什么平均而不是逐张并集：单张构图抖动会把"同一场景但换了机位"的照片排除，
    /// 平均向量把这几张的共同内容拉到中心，语义更接近"找这类照片"。
    /// 与单张版共用同一套分块扫描/有界 top-K，只是查询向量不同。
    public func similar(
        to photoIds: [String],
        sessionId: String,
        limit: Int = 50,
        minSimilarity: Double = SemanticIndex.defaultMinSimilarity
    ) throws -> SemanticSearchOutcome {
        guard limit > 0 else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .featurePrint, hits: [], scanned: 0, skipped: 0,
                unavailableReason: "limit must be positive")
        }
        let seeds = Array(Set(photoIds.filter { !$0.isEmpty })).sorted()
        guard !seeds.isEmpty else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .featurePrint, hits: [], scanned: 0, skipped: 0,
                unavailableReason: "semantic_unavailable: 没有可用的种子照片")
        }
        var vectors: [[Float]] = []
        var seedSkipped = 0
        for photoId in seeds {
            guard let vector = try vector(photoId: photoId)?.vector, !vector.isEmpty else {
                seedSkipped += 1
                continue
            }
            // 只平均同维向量：系统升级后 2048 vs 1024 混排会让余弦恒 -1。
            if let first = vectors.first, first.count != vector.count {
                seedSkipped += 1
                continue
            }
            vectors.append(vector)
        }
        guard let query = Self.averageVector(vectors) else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .featurePrint, hits: [], scanned: 0,
                skipped: seedSkipped,
                unavailableReason: "semantic_unavailable: 选中照片没有语义向量")
        }
        let seedIds = Set(seeds)
        var hits: [SemanticSearchHit] = []
        let scan = try scanVectors(
            sessionId: sessionId,
            limit: Self.maxScanRows,
            preferredDimension: query.count
        ) { row in
            guard !seedIds.contains(row.photoId) else { return }
            let similarity = Self.cosine(query, row.vector)
            guard similarity >= minSimilarity else { return }
            Self.insertBounded(
                SemanticSearchHit(
                    photoId: row.photoId, similarity: similarity,
                    labels: row.labels, matchedLabels: []),
                into: &hits,
                capacity: limit,
                rankedBefore: Self.similarityRankedBefore)
        }
        return SemanticSearchOutcome(
            sessionId: sessionId, method: .featurePrint, hits: hits,
            scanned: scan.scanned, skipped: scan.skipped + seedSkipped)
    }

    /// 等权平均向量：**先 L2 归一化再平均**（cosine 的尺度不变性只保证尺度不变，
    /// 不保证等权——直接平均会让范数大的种子主导方向）。
    ///
    /// - 空输入 / 全部零向量 → nil；
    /// - 维度不一致：只取第一个有效向量的维度那一批（其余跳过，与旧行为一致）；
    /// - 返回值为"单位向量的均值"（未再做一次归一化：调用方只用它算 cosine，
    ///   幅度不影响结果，但保留幅度便于未来做距离型指标）。
    public static func averageVector(_ vectors: [[Float]]) -> [Float]? {
        var sum: [Float]?
        var used = 0
        for vector in vectors {
            guard !vector.isEmpty else { continue }
            if let existing = sum, existing.count != vector.count { continue }
            let norm = Self.l2Norm(vector)
            guard norm > 0 else { continue }
            if sum == nil { sum = [Float](repeating: 0, count: vector.count) }
            guard var total = sum, total.count == vector.count else { continue }
            for index in vector.indices { total[index] += vector[index] / norm }
            sum = total
            used += 1
        }
        guard let total = sum, used > 0 else { return nil }
        let divisor = Float(used)
        return total.map { $0 / divisor }
    }

    /// L2 范数（cosine 归一化用）。
    static func l2Norm(_ vector: [Float]) -> Float {
        var squares: Float = 0
        for value in vector { squares += value * value }
        return squares.squareRoot()
    }

    // MARK: 标签匹配（文搜）

    /// 标签文本匹配：查询词命中任一标签（前缀/包含，大小写不敏感）→ Jaccard 排序。
    /// 不做 CLIP 文本编码（无模型资产）：标签与查询参数都是英文原串。
    /// 中文显示/中文输入→英文映射在 UI（GatherUI/SemanticSearch/SemanticLabelCatalog），
    /// 不进入本层、不写盘（关键词路径仍是 AI|场景|<英文>，可逆）。
    public func search(
        sessionId: String,
        labels query: [String],
        limit: Int = 100,
        minJaccard: Double = 0
    ) throws -> SemanticSearchOutcome {
        let keys = Set(query.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !keys.isEmpty else {
            return SemanticSearchOutcome(
                sessionId: sessionId, method: .labels, hits: [], scanned: 0, skipped: 0,
                unavailableReason: "INVALID_PARAM: labels must not be empty")
        }
        // B7：分块扫描 + 有界 top-K（排序键与旧实现相同：命中标签数降序 + photoId）。
        let capacity = max(0, limit)
        var hits: [SemanticSearchHit] = []
        let scan = try scanVectors(
            sessionId: sessionId,
            limit: Self.maxScanRows,
            preferredDimension: 0
        ) { row in
            let matched = row.labels.filter { label in
                let key = label.normalizedKey
                return keys.contains { query in key.contains(query) }
            }
            guard !matched.isEmpty else { return }
            let rowKeys = row.labelKeys
            let jaccard = Self.jaccard(keys, rowKeys)
            guard jaccard >= minJaccard else { return }
            Self.insertBounded(
                SemanticSearchHit(
                    photoId: row.photoId, similarity: nil, labels: row.labels,
                    matchedLabels: matched.map(\.label)),
                into: &hits,
                capacity: capacity,
                rankedBefore: Self.labelsRankedBefore)
        }
        return SemanticSearchOutcome(
            sessionId: sessionId, method: .labels, hits: hits,
            scanned: scan.scanned, skipped: scan.skipped)
    }

    // MARK: 场景分组

    /// 会话内场景分组（标签 Jaccard ≥ threshold 或余弦 ≥ cosine）。
    /// 只返回 ≥ 2 张的组；组内按相似度并入 leader，最多 maxClusterRows 行参与。
    public func sceneGroups(
        sessionId: String,
        labelJaccard: Double = SemanticIndex.defaultLabelJaccard,
        cosine: Double = SemanticIndex.defaultCosine,
        maxRows: Int = SemanticIndex.maxClusterRows
    ) throws -> [SemanticSceneGroup] {
        let limit = maxRows > 0 ? maxRows : Self.maxClusterRows
        let decoded = try decode(store.loadRows(sessionId: sessionId, limit: limit))
        return Self.cluster(
            decoded.vectors, labelJaccard: labelJaccard, cosineThreshold: cosine)
    }

    /// 纯函数：贪心分组（便于测试，无 I/O）。
    public static func cluster(
        _ rows: [SemanticVector],
        labelJaccard: Double = SemanticIndex.defaultLabelJaccard,
        cosineThreshold: Double = SemanticIndex.defaultCosine
    ) -> [SemanticSceneGroup] {
        var groups: [(seed: SemanticVector, members: [SemanticVector], basis: SemanticSceneGroup.Basis)] = []
        for row in rows {
            var placed = false
            for index in groups.indices {
                let seed = groups[index].seed
                if jaccard(seed.labelKeys, row.labelKeys) >= labelJaccard {
                    groups[index].members.append(row)
                    placed = true
                    break
                }
                if cosine(seed.vector, row.vector) >= cosineThreshold {
                    groups[index].members.append(row)
                    groups[index].basis = .embedding
                    placed = true
                    break
                }
            }
            if !placed {
                groups.append((seed: row, members: [row], basis: .labels))
            }
        }
        return groups
            .filter { $0.members.count >= 2 }
            .map { group in
                SemanticSceneGroup(
                    photoIds: group.members.map(\.photoId).sorted(),
                    labels: sharedLabels(of: group.members),
                    basis: group.basis)
            }
            .sorted { lhs, rhs in
                if lhs.photoIds.count != rhs.photoIds.count {
                    return lhs.photoIds.count > rhs.photoIds.count
                }
                return (lhs.photoIds.first ?? "") < (rhs.photoIds.first ?? "")
            }
    }

    /// 组内出现次数最多的前 3 个标签（explanation 用）。
    static func sharedLabels(of members: [SemanticVector]) -> [String] {
        var counts: [String: Int] = [:]
        for member in members {
            for key in member.labelKeys { counts[key, default: 0] += 1 }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(3)
            .map(\.key)
    }

    // MARK: 数学

    /// 余弦相似度：长度不一致/零向量返回 -1（调用方按"不可比"处理，不当作 0）。
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return -1 }
        return Double(dot / (sqrt(leftNorm) * sqrt(rightNorm)))
    }

    /// Jaccard 相似度（空集 = 0，不是 1：两张都没有标签不该算"完全同场景"）。
    public static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    // MARK: 标签 JSON

    public static func encodeLabels(_ labels: [SemanticLabel]) -> String {
        let sorted = labels.sorted()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(sorted)
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return "[]"
        }
    }

    public static func decodeLabels(_ json: String) -> [SemanticLabel] {
        guard !json.isEmpty else { return [] }
        do {
            let decoded = try JSONDecoder().decode([SemanticLabel].self, from: Data(json.utf8))
            return decoded.sorted()
        } catch {
            return []
        }
    }

    // MARK: 内部

    /// 分块扫描会话向量（B7：不把全会话同时展开进内存）。
    ///
    /// - Parameters:
    ///   - limit: 最多比较的行数（<= 0 = 不设上限，仅供内部调用点使用）。
    ///   - preferredDimension: > 0 时只接受该维度的向量（图搜图：与查询向量不同维的
    ///     行本来就会得到余弦 -1）；0 = 以第一个可解码行的维度为基准（旧 decode 的语义）。
    ///   - body: 逐条回调（按 photoId 升序，稳定顺序，便于复现）。
    /// - Returns: scanned = 参与比较的行数；skipped = 维度不符/解码失败的行数。
    private func scanVectors(
        sessionId: String,
        limit: Int,
        preferredDimension: Int,
        body: (SemanticVector) -> Void
    ) throws -> (scanned: Int, skipped: Int) {
        // 先只取 id 集合（不读 BLOB），再按块读 BLOB：峰值内存 = 一个块。
        let ids = try store.indexedPhotoIds(sessionId: sessionId).sorted()
        let bounded = limit > 0 && ids.count > limit ? Array(ids.prefix(limit)) : ids
        let chunkSize = max(1, Self.scanChunkRows)
        var expectedDim = max(0, preferredDimension)
        var scanned = 0
        var skipped = 0
        var offset = 0
        while offset < bounded.count {
            let end = min(offset + chunkSize, bounded.count)
            let chunk = Array(bounded[offset..<end])
            offset = end
            // loadRows(sessionId:photoIds:) 内部再按 800 分块做 IN 查询。
            for row in try store.loadRows(sessionId: sessionId, photoIds: chunk) {
                let vector = SemanticFeatureCodec.decode(row.feature, dimension: row.featureDim)
                guard !vector.isEmpty else { skipped += 1; continue }
                // 同一会话内只比较同维向量：系统升级后 2048 vs 1024 混排会让余弦恒 -1。
                if expectedDim == 0 { expectedDim = vector.count }
                guard vector.count == expectedDim else { skipped += 1; continue }
                scanned += 1
                body(SemanticVector(
                    photoId: row.photoId,
                    labels: Self.decodeLabels(row.labelsJson),
                    vector: vector,
                    modelVersion: row.modelVersion))
            }
        }
        return (scanned, skipped)
    }

    /// 有界 top-K：内存里只保留 capacity 条。
    ///
    /// 与"全量收集 → 排序 → prefix(capacity)"等价：比较器是全序（同分由 photoId
    /// 决定），扫描顺序不影响谁能进前 K。
    private static func insertBounded(
        _ hit: SemanticSearchHit,
        into hits: inout [SemanticSearchHit],
        capacity: Int,
        rankedBefore: (SemanticSearchHit, SemanticSearchHit) -> Bool
    ) {
        guard capacity > 0 else { return }
        let index = hits.firstIndex { rankedBefore(hit, $0) } ?? hits.count
        hits.insert(hit, at: index)
        if hits.count > capacity { hits.removeLast() }
    }

    /// 图搜图排序：余弦降序、photoId 升序。
    static func similarityRankedBefore(
        _ lhs: SemanticSearchHit, _ rhs: SemanticSearchHit
    ) -> Bool {
        let left = lhs.similarity ?? 0
        let right = rhs.similarity ?? 0
        if left != right { return left > right }
        return lhs.photoId < rhs.photoId
    }

    /// 文搜排序：命中标签数降序、photoId 升序。
    static func labelsRankedBefore(
        _ lhs: SemanticSearchHit, _ rhs: SemanticSearchHit
    ) -> Bool {
        if lhs.matchedLabels.count != rhs.matchedLabels.count {
            return lhs.matchedLabels.count > rhs.matchedLabels.count
        }
        return lhs.photoId < rhs.photoId
    }

    private func decode(
        _ rows: [PhotoSemanticsRow]
    ) throws -> (vectors: [SemanticVector], skipped: Int) {
        var vectors: [SemanticVector] = []
        vectors.reserveCapacity(rows.count)
        var skipped = 0
        var expectedDim = 0
        for row in rows {
            let vector = SemanticFeatureCodec.decode(row.feature, dimension: row.featureDim)
            guard !vector.isEmpty else { skipped += 1; continue }
            // 同一会话内只比较同维向量：系统升级后 2048 vs 1024 混排会让余弦恒 -1。
            if expectedDim == 0 { expectedDim = vector.count }
            guard vector.count == expectedDim else { skipped += 1; continue }
            vectors.append(SemanticVector(
                photoId: row.photoId,
                labels: Self.decodeLabels(row.labelsJson),
                vector: vector,
                modelVersion: row.modelVersion))
        }
        return (vectors, skipped)
    }
}

// MARK: - 采集（Vision）

/// feature print + 分类标签的采集器。失败一律 .failure(.unsupported/.requestFailed)，
/// 调用方跳过并记 semantic_unavailable，绝不阻断 model.review。
public enum ImageSemanticsExtractor {
    /// 写入 photo_semantics.model_version 的值：feature print/标签语义变化时升这里。
    public static let modelVersion = "vision.fp1"
    /// 标签上限（plan §3.11.5 top-8）。
    public static let maxLabels = 8
    /// 低于该置信度的标签丢弃（Vision 会给一长串 ~0.01 的噪声标签）。
    public static let minLabelConfidence = 0.05

    public static var isSupported: Bool {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }

    public static func observe(
        _ image: CGImage,
        maxLabels: Int = ImageSemanticsExtractor.maxLabels
    ) -> Result<SemanticObservation, SemanticFailure> {
        #if canImport(Vision)
        let handler = VNImageRequestHandler(cgImage: image)
        let featureRequest = VNGenerateImageFeaturePrintRequest()
        let classifyRequest = VNClassifyImageRequest()
        do {
            try handler.perform([featureRequest, classifyRequest])
        } catch {
            return .failure(.requestFailed(String(describing: error)))
        }
        var feature: [Float] = []
        if let observation = featureRequest.results?.first {
            feature = decodeFeaturePrint(observation)
        }
        var labels: [SemanticLabel] = []
        if let classifications = classifyRequest.results {
            labels = classifications
                .filter { $0.confidence >= Float(minLabelConfidence) }
                .sorted { $0.confidence > $1.confidence }
                .prefix(max(0, maxLabels))
                .map { SemanticLabel(label: $0.identifier, confidence: Double($0.confidence)) }
        }
        // 两条请求都空 = 这个系统没有任何语义能力：按不可用上报，避免写空行。
        guard !feature.isEmpty || !labels.isEmpty else {
            return .failure(.unsupported)
        }
        return .success(SemanticObservation(labels: labels, feature: feature))
        #else
        _ = image
        _ = maxLabels
        return .failure(.unsupported)
        #endif
    }

    #if canImport(Vision)
    /// VNFeaturePrintObservation.data → [Float]（按 elementType 解 4/8 字节元素）。
    static func decodeFeaturePrint(_ observation: VNFeaturePrintObservation) -> [Float] {
        let data = observation.data
        let count = observation.elementCount
        guard count > 0, !data.isEmpty else { return [] }
        switch observation.elementType {
        case .float:
            guard data.count == count * MemoryLayout<Float>.size else { return [] }
            var values = [Float]()
            values.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for index in 0..<count {
                    values.append(raw.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self))
                }
            }
            return values
        case .double:
            guard data.count == count * MemoryLayout<Double>.size else { return [] }
            var values = [Float]()
            values.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for index in 0..<count {
                    let value = raw.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Double>.size, as: Double.self)
                    values.append(Float(value))
                }
            }
            return values
        default:
            return []
        }
    }
    #endif
}

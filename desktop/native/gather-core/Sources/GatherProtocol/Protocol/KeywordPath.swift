// desktop/native/gather-core/Sources/GatherProtocol/Protocol/KeywordPath.swift
// P1 下一波：层级关键词的纯值（"A|B|C"）与编解码。
//
// 约定：
// - 序列化用 Lightroom 的 "|" 分隔；段去空白、丢空段；整体 NFC 归一化；
// - 平铺词 = 单段路径；
// - 比较/去重用 foldedKey（NFC + caseInsensitive + widthInsensitive），但写盘保留原拼写。

import Foundation

public struct KeywordPath: Hashable, Codable, Sendable, Comparable {
    public let segments: [String]

    public init?(segments: [String]) {
        let normalized = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.precomposedStringWithCanonicalMapping }
        guard !normalized.isEmpty else { return nil }
        self.segments = normalized
    }

    public init?(_ raw: String) {
        self.init(segments: raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init))
    }

    public var serialized: String { segments.joined(separator: "|") }
    public var leaf: String { segments.last ?? "" }
    public var ancestors: [String] { Array(segments.dropLast()) }
    public var isHierarchical: Bool { segments.count > 1 }
    public var parent: KeywordPath? {
        segments.count > 1 ? KeywordPath(segments: Array(segments.dropLast())) : nil
    }

    /// 去重/匹配键：大小写、宽度、NFC 全归一。
    public var foldedKey: String {
        serialized.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    public static func < (lhs: KeywordPath, rhs: KeywordPath) -> Bool {
        lhs.serialized.localizedStandardCompare(rhs.serialized) == .orderedAscending
    }

    /// 计划 §3.6.2 的入口名（与 `init?(_:)` 同义）：非法段丢弃而非整词丢弃。
    ///
    /// 例：`"A||B"` → `["A","B"]`；`" | "` → nil（没有任何非空段）。
    public static func parse(_ raw: String) -> KeywordPath? {
        KeywordPath(raw)
    }

    /// facet 顶级桶名（无层级时就是自身）。与 FacetQuery 的 SQL 表达式同义。
    public var topSegment: String {
        segments.first ?? ""
    }

    public var depth: Int {
        segments.count
    }

    /// self 是否以 `ancestor` 为前缀（含自身）。用于 facet 下钻的 Swift 侧判定。
    public func isDescendant(of ancestor: KeywordPath) -> Bool {
        guard segments.count >= ancestor.segments.count else { return false }
        let head = Array(segments.prefix(ancestor.segments.count))
        return KeywordPath(segments: head)?.foldedKey == ancestor.foldedKey
    }
}

public enum KeywordCodec {
    /// 把盘上两套列表合并成有序路径：层级优先，平铺去重追加。
    ///
    /// **叶子并回路径**（§3.6.2 "同路径以层级为准，叶子重复不重复计数"）：
    /// leaf 风格下 dc:subject 里写的是每条层级路径的叶子，那段叶子在 dc 里只是
    /// 同一路径的展开，读回时必须并回路径，不能再当成一个独立的平铺关键词。
    /// 否则往返不相等（写 ["A|B"] 读回 ["A|B","B"]），keyword facet 还会为每条
    /// 层级路径凭空多出一个顶层桶。path 风格下 dc 里本来就是路径，不受影响。
    public static func merge(flat: [String], hierarchical: [String]) -> [KeywordPath] {
        var seen = Set<String>()
        var result: [KeywordPath] = []
        var entries: [(path: KeywordPath, fromHierarchical: Bool)] = []
        var hierarchicalLeafKeys = Set<String>()
        for raw in hierarchical {
            guard let path = KeywordPath(raw) else { continue }
            entries.append((path, true))
            guard path.isHierarchical,
                  let leaf = KeywordPath(segments: [path.leaf]) else { continue }
            hierarchicalLeafKeys.insert(leaf.foldedKey)
        }
        for raw in flat {
            guard let path = KeywordPath(raw) else { continue }
            entries.append((path, false))
        }
        for entry in entries {
            if !entry.fromHierarchical, !entry.path.isHierarchical,
               hierarchicalLeafKeys.contains(entry.path.foldedKey) {
                continue
            }
            guard seen.insert(entry.path.foldedKey).inserted else { continue }
            result.append(entry.path)
        }
        return result
    }

    /// dc:subject 的写盘列表：leaf = 只写叶子（去重）；path = 写完整路径。
    public static func dcSubject(
        for paths: [KeywordPath],
        style: KeywordDCSubjectStyle
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let value = style == .path ? path.serialized : path.leaf
            let key = value.folding(options: [.caseInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// lr:hierarchicalSubject：只写含层级的路径（平铺词写进去会被当成一级路径）。
    public static func hierarchicalSubject(for paths: [KeywordPath]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where path.isHierarchical {
            guard seen.insert(path.foldedKey).inserted else { continue }
            result.append(path.serialized)
        }
        return result
    }

    /// wire 列表（`[String]`）→ 路径列表：非法项丢弃、按 foldedKey 去重、保序。
    ///
    /// 这是 `MetadataWriteAttributes.keywords` / `dc:subject` 的唯一解码入口：
    /// 写盘与读回都用它，避免"写进去的 A|B 读回来成了 A、B 两个词"。
    public static func parse(_ values: [String]) -> [KeywordPath] {
        var seen = Set<String>()
        var result: [KeywordPath] = []
        for raw in values {
            guard let path = KeywordPath(raw), seen.insert(path.foldedKey).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// wire 列表规范化：NFC + trim + 丢空段 + 去重（**只改拼写形式，不丢语义**）。
    /// 空列表返回空数组（调用方按 nil/[] 的既有三态语义处理）。
    public static func normalized(_ values: [String]) -> [String] {
        parse(values).map(\.serialized)
    }

    /// 写盘用的一对列表（dc:subject / lr:hierarchicalSubject）——写侧与写后校验
    /// 必须共用同一份编码，否则校验会把"合法的叶子展开"判成写失败。
    public static func encoded(
        _ values: [String],
        style: KeywordDCSubjectStyle
    ) -> (dc: [String], hierarchical: [String]) {
        let paths = parse(values)
        return (dcSubject(for: paths, style: style), hierarchicalSubject(for: paths))
    }

    /// 下钻桶：前缀的直接子段（prefix == nil 时取顶级段），去重保序。
    ///
    /// 与 FacetQuery 的 SQL 分支同义（首段 / `substr` 取下一段），
    /// 两者的一致性由 KeywordFacetTests 的对照用例守住。
    public static func childBuckets(of paths: [KeywordPath], under prefix: KeywordPath?) -> [String] {
        let base = prefix?.segments.count ?? 0
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            guard path.segments.count > base else { continue }
            if let prefix, !path.isDescendant(of: prefix) { continue }
            let bucket = path.segments[base]
            let key = KeywordPath(segments: [bucket])?.foldedKey ?? bucket
            guard seen.insert(key).inserted else { continue }
            result.append(bucket)
        }
        return result
    }
}

public enum KeywordDCSubjectStyle: String, Codable, CaseIterable, Sendable {
    case leaf
    case path
}

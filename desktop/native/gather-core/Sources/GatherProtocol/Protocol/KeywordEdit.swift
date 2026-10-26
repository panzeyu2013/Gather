// desktop/native/gather-core/Sources/GatherProtocol/Protocol/KeywordEdit.swift
// P0 / K0：关键词归一化、去重、生成词保护与 delta 计划（纯值 + 纯函数）。
//
// 语义冻结见 docs/design/p0/k0-keywords.md §3：
//   - NFC + trim + 空白折叠，长度 ≤256，拒绝 NUL/控制字符；
//   - 比较用 case/width-insensitive fold，落盘保留首次拼写；
//   - 生成词（face/similarity/culling/template）阻止删除；
//   - 层级词 A|B 原样作为一个词，不展开父级。
import Foundation

public enum KeywordNormalizer {
    /// NFC + 去首尾空白 + 内部空白折叠；空/超长/控制字符返回 nil。
    public static func normalize(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let nfc = raw.precomposedStringWithCanonicalMapping
        let collapsed = nfc.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= 256 else { return nil }
        for scalar in collapsed.unicodeScalars {
            if scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x7F {
                return nil
            }
        }
        return collapsed
    }

    /// 仅用于比较的大小写/宽度不敏感形式；不改变落盘拼写。
    public static func fold(_ value: String) -> String {
        let base = normalize(value) ?? value
        return base.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// 只按 fold 去重，**不归一化、不丢弃**任何值。
    /// 用于“盘上既有词表”：执行器必须原样保留外部写入的拼写（含 >256 字符、
    /// 连续空格、非 NFC 等形式），否则“加一个词”会静默改写/删除未触碰的词。
    public static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = fold(value)
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// 归一化并按 fold 去重，保留首次出现的拼写与顺序。
    /// 仅用于用户输入/新写入值；不得用于盘上既有词表。
    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let normalized = normalize(value) else { continue }
            guard seen.insert(fold(normalized)).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}

public struct KeywordRemovalBlock: Equatable, Sendable {
    public var keyword: String
    public var sources: [MetadataMutationSource]

    public init(keyword: String, sources: [MetadataMutationSource]) {
        self.keyword = keyword
        self.sources = sources
    }
}

public struct KeywordPlan: Equatable, Sendable {
    public var before: [String]
    public var after: [String]
    public var added: [String]
    public var removed: [String]
    public var blocked: [KeywordRemovalBlock]

    public var changed: Bool { before != after }

    public init(
        before: [String],
        after: [String],
        added: [String],
        removed: [String],
        blocked: [KeywordRemovalBlock]
    ) {
        self.before = before
        self.after = after
        self.added = added
        self.removed = removed
        self.blocked = blocked
    }
}

public enum KeywordPlanner {
    /// existing/added/removed 均允许重复/大小写混写；owned 的 key 为 fold(keyword)。
    public static func plan(
        existing: [String],
        added: [String],
        removed: [String],
        owned: [String: Set<MetadataMutationSource>]
    ) -> KeywordPlan {
        // 盘上既有词逐项原样保留（连大小写/重复变体都不折叠）；fold 只用于比较。
        // 否则 ["Cat","cat"] + 加一个词会把 "cat" 静默删掉，违反“未触碰的词不得改写”。
        let before = existing.filter { !$0.isEmpty }
        let add = KeywordNormalizer.unique(added)
        let remove = KeywordNormalizer.unique(removed)

        var blocked: [KeywordRemovalBlock] = []
        var removable = Set<String>()
        for keyword in remove {
            let key = KeywordNormalizer.fold(keyword)
            if let sources = owned[key], !sources.isEmpty {
                blocked.append(KeywordRemovalBlock(
                    keyword: keyword,
                    sources: sources.sorted { $0.rawValue < $1.rawValue }
                ))
            } else {
                removable.insert(key)
            }
        }

        var after = before.filter { !removable.contains(KeywordNormalizer.fold($0)) }
        var present = Set(after.map { KeywordNormalizer.fold($0) })
        var actuallyAdded: [String] = []
        for keyword in add {
            let key = KeywordNormalizer.fold(keyword)
            if present.insert(key).inserted {
                after.append(keyword)
                actuallyAdded.append(keyword)
            }
        }

        let afterKeys = Set(after.map { KeywordNormalizer.fold($0) })
        let actuallyRemoved = before.filter {
            removable.contains(KeywordNormalizer.fold($0))
                && !afterKeys.contains(KeywordNormalizer.fold($0))
        }

        return KeywordPlan(
            before: before,
            after: after,
            added: actuallyAdded,
            removed: actuallyRemoved,
            blocked: blocked
        )
    }

    /// 执行器用：在文件锁内按盘上现状重新合并（不做生成词保护）。
    public static func apply(existing: [String], added: [String], removed: [String]) -> [String] {
        plan(existing: existing, added: added, removed: removed, owned: [:]).after
    }
}

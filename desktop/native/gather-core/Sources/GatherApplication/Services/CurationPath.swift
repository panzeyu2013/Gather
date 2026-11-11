// desktop/native/gather-core/Sources/GatherApplication/Services/CurationPath.swift
// Wave2 收尾（task-27）：集合的「命名路径约定」——纯逻辑，无 SQL、无状态。
//
// ## 约定
// 集合名用 `A/B/C` 表示层级：分隔符 `/`，每段去首尾空白后非空，总长 ≤ 200
// （与 CurationNaming.maxLength 一致），单段 ≤ 80；拒绝连续分隔符/首尾分隔符
// （即空段）、控制字符、跨平台保留字符 `\ : * ? " < > |`、以及 `.`/`..`。
//
// ## 这不是数据库父子关系（重要，勿混淆）
// collections 表**仍是扁平表**：只有 (id, session_id, name, sort_order, …)，
// 没有 parent_id，也没有级联移动/删除语义。本文件只解析名字里的"/"给 UI 分组；
// 真正的 schema 层级（parent_id + 迁移 + 级联策略）需要一次 user_version 迁移，
// 另行决策（见 docs/README.md「集合层级」一节与 ROADMAP 的迁移决策门）。
//
// ## 与 UI 的分工
// 本类型是**规则的唯一权威**（create/rename 都过它）。GatherUI 不能 import
// Application（layering 门禁），因此侧栏的输入前置校验在
// `GatherUI/Curation/CollectionTree.swift` 里按同一份规则实现了一份最小副本；
// 服务端仍会再校验一次，UI 的副本只负责"少一次往返的红字"。
import Foundation

public struct CurationPath: Equatable, Hashable, Sendable {
    public static let separator: Character = "/"
    /// 单段上限：留出父路径后仍可读（总长另受 CurationNaming.maxLength 限制）。
    public static let maxSegmentLength = 80
    /// 跨平台保留字符（集合名不是文件名，但路径约定会出现在导出/脚本里，保持可移植）。
    public static let reservedCharacters: Set<Character> = [
        "\\", ":", "*", "?", "\"", "<", ">", "|",
    ]

    public let segments: [String]

    /// 逐段校验后构造。
    public init(segments: [String]) throws {
        guard !segments.isEmpty else {
            throw CurationError.invalidName("collection path must not be empty")
        }
        var validated: [String] = []
        validated.reserveCapacity(segments.count)
        for raw in segments {
            validated.append(try Self.validateSegment(raw))
        }
        let joined = validated.joined(separator: String(Self.separator))
        guard joined.count <= CurationNaming.maxLength else {
            throw CurationError.invalidName(
                "collection path must be at most \(CurationNaming.maxLength) characters")
        }
        self.segments = validated
    }

    /// 严格解析用户输入（新建/重命名入口）。首尾空白会被裁掉；
    /// 中间出现空段（`//`、开头/结尾 `/`）按非法拒绝，不做静默折叠。
    public static func parse(_ raw: String) throws -> CurationPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CurationError.invalidName("collection name must not be empty")
        }
        let parts = trimmed.split(
            separator: separator, omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw CurationError.invalidName(
                "collection path must not contain empty segments (check leading, trailing or doubled \"/\")")
        }
        return try CurationPath(segments: parts)
    }

    /// 宽容解析**已存在的**集合名（历史数据可能含旧规则允许、新规则拒绝的字符）。
    /// 只用于读取现状（改名/移动时的当前路径），绝不用于校验用户输入。
    public static func parseLenient(_ raw: String) -> CurationPath {
        let parts = raw
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return CurationPath(lenientSegments: [raw])
        }
        return CurationPath(lenientSegments: parts)
    }

    /// 内部构造（宽容）：调用方必须是 parseLenient（读既有名），
    /// 用独立 label 与 public 的严格 init 区分，避免被误用成绕过校验的入口。
    init(lenientSegments: [String]) {
        self.segments = lenientSegments
    }

    public var fullName: String {
        segments.joined(separator: String(Self.separator))
    }

    public var leaf: String {
        segments.last ?? ""
    }

    public var depth: Int {
        segments.count
    }

    /// 父路径（顶层集合为 nil）。
    public var parent: CurationPath? {
        guard segments.count > 1 else { return nil }
        return CurationPath(lenientSegments: Array(segments.dropLast()))
    }

    /// 是否为本路径的祖先（严格上位，不含相等）。
    public func isAncestor(of other: CurationPath) -> Bool {
        guard other.segments.count > segments.count else { return false }
        return Array(other.segments.prefix(segments.count)) == segments
    }

    /// 在末尾追加一段（新建子集合用）。
    public func appending(_ leafRaw: String) throws -> CurationPath {
        try CurationPath(segments: segments + [leafRaw])
    }

    /// 换最后一段（同父改名）。
    public func replacingLeaf(with newLeafRaw: String) throws -> CurationPath {
        guard !segments.isEmpty else {
            throw CurationError.invalidName("collection path must not be empty")
        }
        return try CurationPath(segments: Array(segments.dropLast()) + [newLeafRaw])
    }

    /// 换父（移动）：parent 为 nil = 移到顶层。
    public func moving(under parent: CurationPath?) throws -> CurationPath {
        let head = parent?.segments ?? []
        return try CurationPath(segments: head + [leaf])
    }

    /// 单段校验（新建子集合/改叶子时也复用）。
    public static func validateSegment(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CurationError.invalidName("collection path segment must not be empty")
        }
        guard !trimmed.contains(separator) else {
            throw CurationError.invalidName("collection path segment must not contain \"/\"")
        }
        guard trimmed != "." && trimmed != ".." else {
            throw CurationError.invalidName("collection path segment must not be \".\" or \"..\"")
        }
        guard trimmed.count <= maxSegmentLength else {
            throw CurationError.invalidName(
                "collection path segment must be at most \(maxSegmentLength) characters")
        }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw CurationError.invalidName(
                    "collection path must not contain control characters")
            }
            if reservedCharacters.contains(Character(String(scalar))) {
                throw CurationError.invalidName(
                    "collection path must not contain reserved characters")
            }
        }
        return trimmed
    }
}

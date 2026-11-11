// desktop/native/gather-app/Sources/GatherUI/Curation/CollectionTree.swift
// Wave2 收尾（task-27）：集合侧栏的「命名路径 → 树」组装 + 输入前置校验。
//
// ## 分层与权威
// 规则权威在 Application（CurationPath，create/rename 都会再校验一次）。GatherUI
// 不能 import Application（layering 门禁），所以这里按同一份规则实现了**最小副本**：
// 只为了让侧栏少一次往返就能给出红字。若两边规则漂移，以服务端为准（会拒绝）。
//
// ## 层级只是命名约定
// collections 表仍是扁平表（无 parent_id）。本文件把扁平列表按名字里的 "/" 组装成
// 展示用树：**父节点可以没有对应的集合记录**（隐式分组节点，collection == nil），
// 它只负责分组、不可选中。真正的 schema 层级（parent_id + user_version 迁移）另行决策，
// 见 docs/README.md「集合层级」一节。
import Foundation
import GatherProtocol

// MARK: - 输入前置校验（服务端 CurationPath 的最小副本）

enum CollectionPathInputIssue: Equatable {
    case empty
    case emptySegment
    case tooLong
    case segmentTooLong
    case reservedCharacter
    case dotSegment

    /// 上屏文案（中文即 key；en 表见 Localizable.strings）。
    var messageKey: String {
        switch self {
        case .empty: return "集合路径不能为空"
        case .emptySegment: return "集合路径不能包含空段（检查开头、结尾或连续的分隔符）"
        case .tooLong: return "集合路径过长（最多 200 个字符）"
        case .segmentTooLong: return "单层集合名过长（最多 80 个字符）"
        case .reservedCharacter: return "集合名不能包含保留字符（反斜杠、冒号、星号、问号、引号、尖括号、竖线）"
        case .dotSegment: return "集合名不能是单点或双点"
        }
    }
}

enum CollectionPathInput {
    static let maxLength = 200
    static let maxSegmentLength = 80
    /// 与服务端 CurationPath.reservedCharacters 同一集合（转义写法见测试）。
    static let reservedCharacters: Set<Character> = [
        "\\", ":", "*", "?", "\"", "<", ">", "|",
    ]

    /// 规范化后的全路径（每段去首尾空白、以分隔符连接）；非法返回 nil。
    /// 注意：不做"折叠空段"之类的补救——与 CurationPath.parse 的严格口径一致。
    static func normalizedPath(_ raw: String) -> String? {
        guard validate(raw) == nil, let parts = split(raw) else { return nil }
        return parts.joined(separator: "/")
    }

    /// 校验；合法返回 nil，非法返回具体原因。
    static func validate(_ raw: String) -> CollectionPathInputIssue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let parts = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return .emptySegment
        }
        var normalized: [String] = []
        for part in parts {
            let segment = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment != "." && segment != ".." else { return .dotSegment }
            guard segment.count <= maxSegmentLength else { return .segmentTooLong }
            for scalar in segment.unicodeScalars {
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    return .reservedCharacter
                }
                if reservedCharacters.contains(Character(String(scalar))) {
                    return .reservedCharacter
                }
            }
            normalized.append(segment)
        }
        guard normalized.joined(separator: "/").count <= maxLength else { return .tooLong }
        return nil
    }

    /// 宽容拆分（只给"已存在的集合名"用；历史名可能不符合新规则）。
    static func split(_ raw: String) -> [String]? {
        let parts = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }
}

// MARK: - 树

/// 展示用树节点。path 是稳定的全路径（折叠状态以它为 key，可跨会话持久化）。
struct CollectionTreeNode: Identifiable, Equatable {
    let path: String
    let displayName: String
    /// nil = 隐式分组节点（只有子集合，没有落库的集合记录）。
    let collection: CollectionSummary?
    var children: [CollectionTreeNode]

    var id: String { path }
    var isGroup: Bool { collection == nil }
    var itemCount: Int { collection?.itemCount ?? 0 }
}

enum CollectionTree {
    /// 把扁平集合列表按命名路径组装成树。
    ///
    /// 排序契约（可测）：同层按 displayName 做 caseInsensitive + numeric 比较，
    /// 相等时按原始字符串兜底——保证同名不同大小写（服务端允许）也有确定顺序。
    static func build(_ collections: [CollectionSummary]) -> [CollectionTreeNode] {
        // path -> 该路径上的集合记录（同名重复时取第一个，保持确定性）。
        var collectionByPath: [String: CollectionSummary] = [:]
        // parentPath（空串 = 根） -> 子路径集合
        var childrenByParent: [String: Set<String>] = [:]
        for collection in collections {
            guard let segments = CollectionPathInput.split(collection.name) else { continue }
            for depth in 1...segments.count {
                let path = segments.prefix(depth).joined(separator: "/")
                let parentPath = depth == 1
                    ? ""
                    : segments.prefix(depth - 1).joined(separator: "/")
                childrenByParent[parentPath, default: []].insert(path)
                if depth == segments.count, collectionByPath[path] == nil {
                    collectionByPath[path] = collection
                }
            }
        }
        return assemble(
            parentPath: "",
            childrenByParent: childrenByParent,
            collectionByPath: collectionByPath
        )
    }

    private static func assemble(
        parentPath: String,
        childrenByParent: [String: Set<String>],
        collectionByPath: [String: CollectionSummary]
    ) -> [CollectionTreeNode] {
        let childPaths = Array(childrenByParent[parentPath] ?? []).sorted(by: orderedBefore)
        return childPaths.map { path in
            let segments = path.split(separator: "/").map(String.init)
            return CollectionTreeNode(
                path: path,
                displayName: segments.last ?? path,
                collection: collectionByPath[path],
                children: assemble(
                    parentPath: path,
                    childrenByParent: childrenByParent,
                    collectionByPath: collectionByPath
                )
            )
        }
    }

    /// 同层排序：大小写不敏感 + 数字感知；完全相等时按原始字符串兜底。
    ///
    /// 固定 en_US_POSIX locale：SortOrder 不受系统区域设置影响，
    /// 同一批集合在任何机器/任何语言下顺序一致（也是可测的前提）。
    static func orderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        // 先小写再比较：en_US_POSIX 的排序是"大写优先"（"B" < "a"），
        // 与"大小写不敏感"的用户预期相反；lowercased 保证 A/a 同权重且跨机器稳定。
        let comparison = lhs.lowercased().compare(
            rhs.lowercased(),
            options: [.numeric, .widthInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
        if comparison == .orderedSame { return lhs < rhs }
        return comparison == .orderedAscending
    }
}

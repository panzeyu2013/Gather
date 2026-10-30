// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/KeywordRepo.swift
// P1 下一波 §3.6.1/§3.6.5：关键词库（keywords / keyword_synonyms / photo_keywords）。
//
// 契约：
// - 路径即层级（"A|B|C"），没有 parent_id；改名 = 事务内更新 path/parent_path +
//   photo_keywords/keyword_synonyms 前缀改写（不做递归 CTE）。
// - photo_keywords 按 photo_id（facet 与网格同口径）；usage_count 只是排序权重，
//   **不是**展示计数（展示计数必须按 COALESCE(asset_id, id) 去重，见 FacetQuery）。
// - 词库改名/合并不写盘：XMP 由后续显式"写入 XMP"批量重写。
// 外键细节：keyword_synonyms.keyword_path REFERENCES keywords(path) 没有
// ON UPDATE 动作 → 直接改父键会立刻违反 FK。改名/合并因此在事务内先
// PRAGMA defer_foreign_keys = ON，并且按"读旧 → 删旧 → 插新 → 回写子行"的顺序做，
// 不依赖 ON UPDATE CASCADE（DDL 不归本文件，且索引 SQL 参与形状指纹）。
import Foundation
import GatherProtocol

/// keywords 表行。
public struct KeywordRow: Equatable, Sendable {
    public let id: Int64
    public let path: String
    public let name: String
    public let parentPath: String?
    public let usageCount: Int
    public let createdAt: String

    public init(
        id: Int64, path: String, name: String, parentPath: String?,
        usageCount: Int, createdAt: String
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.usageCount = usageCount
        self.createdAt = createdAt
    }

    public var keywordPath: KeywordPath? { KeywordPath(path) }
}

/// 改名/合并的结果（事务提交后的计数，供 UI 显示"影响了 N 张照片"）。
public struct KeywordMutationResult: Equatable, Sendable {
    /// 实际被改写路径的关键词节点数（含子孙）。
    public let nodes: Int
    /// 被改写的 photo_keywords 行数。
    public let members: Int
    /// 被改写的同义词条数。
    public let synonyms: Int

    public init(nodes: Int, members: Int, synonyms: Int) {
        self.nodes = nodes
        self.members = members
        self.synonyms = synonyms
    }

    public static let empty = KeywordMutationResult(nodes: 0, members: 0, synonyms: 0)
}

public enum KeywordRepoError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case hasMembers(path: String, count: Int)
    case hasChildren(path: String, count: Int)
    case notLeaf(String)
    case targetExists(String)

    public var description: String {
        switch self {
        case .notFound(let path):
            "KEYWORD_NOT_FOUND: \(path)"
        case .hasMembers(let path, let count):
            "KEYWORD_HAS_MEMBERS: \(path) count=\(count)"
        case .hasChildren(let path, let count):
            "KEYWORD_HAS_CHILDREN: \(path) count=\(count)"
        case .notLeaf(let path):
            "KEYWORD_NOT_LEAF: \(path)"
        case .targetExists(let path):
            "KEYWORD_TARGET_EXISTS: \(path)"
        }
    }
}

/// 路径前缀范围（SQL 下钻的唯一实现）。
///
/// 只写 LIKE \(prefix)% 在默认（大小写不敏感）LIKE 下走不了索引，还会把
/// "pathology" 当成 "path" 的子孙；这里用 [path|, path|\u{10FFFF}) 的**范围**
/// 比较：走 idx_photo_keywords_path / idx_keywords_parent 的 B-tree range scan。
public enum KeywordPathSQL {
    /// 子孙下界：path + "|"。
    public static func subtreeLowerBound(_ path: String) -> String { path + "|" }
    /// 子孙上界（不含）：path + "|" + U+10FFFF。
    public static func subtreeUpperBound(_ path: String) -> String { path + "|\u{10FFFF}" }

    /// 子树谓词（含自身）：返回 (sql, params)。alias 是 photo_keywords / keywords 的别名。
    public static func subtreePredicate(column: String, path: String) -> (sql: String, params: [DBValue]) {
        (
            "(\(column) = ? OR (\(column) >= ? AND \(column) < ?))",
            [.text(path), .text(subtreeLowerBound(path)), .text(subtreeUpperBound(path))]
        )
    }
}

public final class KeywordRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 读

    public func keyword(path: String) throws -> KeywordRow? {
        try connection.prepare("""
            SELECT id, path, name, parent_path, usage_count, created_at
            FROM keywords WHERE path = ?
            """).get([.text(path)]).map(Self.row)
    }

    /// 全部关键词（按 path 排序；词库树 / 自动补全用）。
    public func all() throws -> [KeywordRow] {
        try connection.prepare("""
            SELECT id, path, name, parent_path, usage_count, created_at
            FROM keywords ORDER BY path
            """).query().map(Self.row)
    }

    /// 直接子级（parentPath == nil 时取顶级）。
    public func children(parentPath: String?) throws -> [KeywordRow] {
        if let parentPath {
            return try connection.prepare("""
                SELECT id, path, name, parent_path, usage_count, created_at
                FROM keywords WHERE parent_path = ? ORDER BY path
                """).query([.text(parentPath)]).map(Self.row)
        }
        return try connection.prepare("""
            SELECT id, path, name, parent_path, usage_count, created_at
            FROM keywords WHERE parent_path IS NULL ORDER BY path
            """).query().map(Self.row)
    }

    public func count() throws -> Int {
        Int(try connection.prepare("SELECT COUNT(*) AS n FROM keywords").get()?[0].intValue ?? 0)
    }

    /// 前缀匹配（自动补全）：path 或叶子以 needle 开头，按 usage_count 降序。
    public func prefixMatches(_ needle: String, limit: Int) throws -> [KeywordRow] {
        let escaped = escapeLike(needle)
        return try connection.prepare("""
            SELECT id, path, name, parent_path, usage_count, created_at
            FROM keywords
            WHERE path LIKE ? || '%' ESCAPE '\\' OR name LIKE ? || '%' ESCAPE '\\'
            ORDER BY usage_count DESC, path ASC
            LIMIT ?
            """).query([.text(escaped), .text(escaped), .int(Int64(max(1, limit)))]).map(Self.row)
    }

    // MARK: - 写（词库）

    /// 确保一组路径存在（新建/合并时补行）。已存在的不改拼写。
    @discardableResult
    public func ensure(paths: [KeywordPath]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let now = nowISOString()
        let statement = try connection.prepare("""
            INSERT OR IGNORE INTO keywords (path, name, parent_path, usage_count, created_at)
            VALUES (?, ?, ?, 0, ?)
            """)
        var inserted = 0
        try connection.transaction {
            for path in paths {
                let changes = try statement.run([
                    .text(path.serialized),
                    .text(path.leaf),
                    optDB(path.parent?.serialized),
                    .text(now),
                ])
                if changes > 0 { inserted += 1 }
            }
        }
        return inserted
    }

    /// 改名（含子孙前缀级联，单事务）。返回被影响的节点/成员/同义词计数。
    public func rename(from: KeywordPath, to: KeywordPath) throws -> KeywordMutationResult {
        guard from.serialized != to.serialized else { return .empty }
        return try connection.transaction {
            _ = try connection.exec("PRAGMA defer_foreign_keys = ON")
            let oldPath = from.serialized
            let newPath = to.serialized
            let (rangeSQL, rangeParams) = KeywordPathSQL.subtreePredicate(
                column: "path", path: oldPath)
            let rows = try connection.prepare("""
                SELECT path, usage_count, created_at FROM keywords WHERE \(rangeSQL)
                """).query(rangeParams)
            guard !rows.isEmpty else { throw KeywordRepoError.notFound(oldPath) }
            if try keyword(path: newPath) != nil {
                // 目标已存在：改名会撞 UNIQUE(path)，也不该静默吞并（用 merge）。
                throw KeywordRepoError.targetExists(newPath)
            }
            let mappings: [(old: String, new: String, usage: Int64, createdAt: String)] = rows.map { row in
                let old = row[0].textValue ?? ""
                let suffix = String(old.dropFirst(oldPath.count))
                return (
                    old,
                    newPath + suffix,
                    row[1].intValue ?? 0,
                    row[2].textValue ?? nowISOString())
            }

            // 1) 先取出同义词，再删旧行（keyword_synonyms 的 FK 靠 defer 兜住）。
            let synonymRows = try connection.prepare("""
                SELECT keyword_path, synonym FROM keyword_synonyms
                WHERE \(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: oldPath).sql)
                """).query(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: oldPath).params)
            let synonyms: [(old: String, new: String, synonym: String)] = synonymRows.map { row in
                let old = row[0].textValue ?? ""
                let suffix = String(old.dropFirst(oldPath.count))
                return (old, newPath + suffix, row[1].textValue ?? "")
            }
            _ = try connection.prepare("""
                DELETE FROM keyword_synonyms
                WHERE \(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: oldPath).sql)
                """).run(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: oldPath).params)
            _ = try connection.prepare("""
                DELETE FROM keywords WHERE \(rangeSQL)
                """).run(rangeParams)

            // 2) 插新行（parent_path/name 由新路径重新推导）。
            let insertKeyword = try connection.prepare("""
                INSERT INTO keywords (path, name, parent_path, usage_count, created_at)
                VALUES (?, ?, ?, ?, ?)
                """)
            for mapping in mappings {
                guard let path = KeywordPath(mapping.new) else { continue }
                _ = try insertKeyword.run([
                    .text(path.serialized),
                    .text(path.leaf),
                    optDB(path.parent?.serialized),
                    .int(mapping.usage),
                    .text(mapping.createdAt),
                ])
            }
            // 3) 同义词回写。
            let insertSynonym = try connection.prepare(
                "INSERT OR IGNORE INTO keyword_synonyms (keyword_path, synonym) VALUES (?, ?)")
            for synonym in synonyms {
                _ = try insertSynonym.run([.text(synonym.new), .text(synonym.synonym)])
            }
            // 4) 照片索引前缀改写（photo_keywords 没有 FK，纯文本更新）。
            // 用 length(?) 让 SQLite 自己算字符数：Swift 的 String.count 是
            // Character 数、SQLite substr 是 code point 数，组合字符时会错位。
            let membersPredicate = KeywordPathSQL.subtreePredicate(
                column: "keyword_path", path: oldPath)
            let updatedMembers = try connection.prepare("""
                UPDATE photo_keywords SET keyword_path = ? || substr(keyword_path, length(?) + 1)
                WHERE \(membersPredicate.sql)
                """).run(
                    [.text(newPath), .text(oldPath)] + membersPredicate.params)
            return KeywordMutationResult(
                nodes: mappings.count, members: updatedMembers, synonyms: synonyms.count)
        }
    }

    /// 合并：source 的成员/同义词并入 target，然后删掉 source 节点。
    /// 只允许叶子节点（有子孙时要求先改名/先合并子孙，避免"孤儿父级"）。
    public func merge(from sourcePath: KeywordPath, into targetPath: KeywordPath) throws -> KeywordMutationResult {
        guard sourcePath.serialized != targetPath.serialized else { return .empty }
        return try connection.transaction {
            _ = try connection.exec("PRAGMA defer_foreign_keys = ON")
            let source = sourcePath.serialized
            let target = targetPath.serialized
            guard try keyword(path: source) != nil else { throw KeywordRepoError.notFound(source) }
            let childCount = try children(parentPath: source).count
            guard childCount == 0 else { throw KeywordRepoError.notLeaf(source) }
            try ensure(paths: [targetPath])
            let now = nowISOString()
            let members = try connection.prepare("""
                INSERT OR IGNORE INTO photo_keywords (photo_id, keyword_path, source, updated_at)
                SELECT photo_id, ?, source, ? FROM photo_keywords WHERE keyword_path = ?
                """).run([.text(target), .text(now), .text(source)])
            let synonyms = try connection.prepare("""
                INSERT OR IGNORE INTO keyword_synonyms (keyword_path, synonym)
                SELECT ?, synonym FROM keyword_synonyms WHERE keyword_path = ?
                """).run([.text(target), .text(source)])
            _ = try connection.prepare("DELETE FROM photo_keywords WHERE keyword_path = ?")
                .run([.text(source)])
            _ = try connection.prepare("DELETE FROM keyword_synonyms WHERE keyword_path = ?")
                .run([.text(source)])
            _ = try connection.prepare("DELETE FROM keywords WHERE path = ?").run([.text(source)])
            return KeywordMutationResult(
                nodes: 1,
                members: Int(members),
                synonyms: Int(synonyms))
        }
    }

    /// 删除节点（cascade=false 时要求无成员、无子级；cascade=true 连同子孙一起删）。
    public func delete(path: KeywordPath, cascade: Bool = false) throws -> KeywordMutationResult {
        try connection.transaction {
            let serialized = path.serialized
            guard try keyword(path: serialized) != nil else {
                throw KeywordRepoError.notFound(serialized)
            }
            if !cascade {
                let members = try memberCount(path: serialized, includeDescendants: false)
                guard members == 0 else {
                    throw KeywordRepoError.hasMembers(path: serialized, count: members)
                }
                let kids = try children(parentPath: serialized).count
                guard kids == 0 else {
                    throw KeywordRepoError.hasChildren(path: serialized, count: kids)
                }
            }
            let nodes = try connection.prepare("""
                SELECT COUNT(*) AS n FROM keywords WHERE \(KeywordPathSQL.subtreePredicate(column: "path", path: serialized).sql)
                """).get(KeywordPathSQL.subtreePredicate(column: "path", path: serialized).params)?[0]
                .intValue ?? 0
            let members = try connection.prepare("""
                DELETE FROM photo_keywords
                WHERE \(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: serialized).sql)
                """).run(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: serialized).params)
            let synonyms = try connection.prepare("""
                DELETE FROM keyword_synonyms
                WHERE \(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: serialized).sql)
                """).run(KeywordPathSQL.subtreePredicate(column: "keyword_path", path: serialized).params)
            _ = try connection.prepare("""
                DELETE FROM keywords WHERE \(KeywordPathSQL.subtreePredicate(column: "path", path: serialized).sql)
                """).run(KeywordPathSQL.subtreePredicate(column: "path", path: serialized).params)
            return KeywordMutationResult(
                nodes: Int(nodes), members: members, synonyms: synonyms)
        }
    }

    // MARK: - 同义词

    /// 覆盖式设置同义词（fold 去重；空数组 = 清空）。
    public func setSynonyms(path: KeywordPath, synonyms: [String]) throws -> Int {
        try connection.transaction {
            let serialized = path.serialized
            try ensure(paths: [path])
            _ = try connection.prepare("DELETE FROM keyword_synonyms WHERE keyword_path = ?")
                .run([.text(serialized)])
            let statement = try connection.prepare(
                "INSERT OR IGNORE INTO keyword_synonyms (keyword_path, synonym) VALUES (?, ?)")
            var inserted = 0
            var seen = Set<String>()
            for synonym in synonyms {
                guard let normalized = KeywordNormalizer.normalize(synonym) else { continue }
                let key = KeywordNormalizer.fold(normalized)
                guard seen.insert(key).inserted else { continue }
                inserted += try statement.run([.text(serialized), .text(normalized)])
            }
            return inserted
        }
    }

    public func synonyms(path: String) throws -> [String] {
        try connection.prepare(
            "SELECT synonym FROM keyword_synonyms WHERE keyword_path = ? ORDER BY synonym")
            .query([.text(path)]).compactMap { $0[0].textValue }
    }

    /// 全部同义词（词库同义词展开/自动补全用；一次查询，不分批）。
    public func allSynonyms() throws -> [(keywordPath: String, synonym: String)] {
        try connection.prepare(
            "SELECT keyword_path, synonym FROM keyword_synonyms ORDER BY keyword_path, synonym")
            .query().compactMap { row in
                guard let path = row[0].textValue, let synonym = row[1].textValue else { return nil }
                return (path, synonym)
            }
    }

    /// 同义词反查：synonym 命中（fold 相等）时返回其所属关键词路径。
    public func keywordPaths(synonym: String) throws -> [String] {
        let folded = KeywordNormalizer.fold(synonym)
        return try allSynonyms()
            .filter { KeywordNormalizer.fold($0.synonym) == folded }
            .map(\.keywordPath)
    }

    // MARK: - photo_keywords（增量索引）

    public func photoKeywordPaths(photoId: String) throws -> [String] {
        try connection.prepare(
            "SELECT keyword_path FROM photo_keywords WHERE photo_id = ? ORDER BY keyword_path")
            .query([.text(photoId)]).compactMap { $0[0].textValue }
    }

    /// 用一个照片的目标集合做 diff（增删），返回 (插入, 删除) 的路径。
    @discardableResult
    public func replacePhotoKeywords(
        photoId: String,
        paths: [KeywordPath],
        source: String
    ) throws -> (inserted: [String], removed: [String]) {
        let desired = paths.map(\.serialized)
        return try connection.transaction {
            let current = Set(try photoKeywordPaths(photoId: photoId))
            let wanted = Set(desired)
            let removed = current.subtracting(wanted)
            let inserted = wanted.subtracting(current)
            let now = nowISOString()
            if !inserted.isEmpty {
                let statement = try connection.prepare("""
                    INSERT OR REPLACE INTO photo_keywords (photo_id, keyword_path, source, updated_at)
                    VALUES (?, ?, ?, ?)
                    """)
                for path in inserted.sorted() {
                    _ = try statement.run([
                        .text(photoId), .text(path), .text(source), .text(now),
                    ])
                }
            }
            if !removed.isEmpty {
                let statement = try connection.prepare(
                    "DELETE FROM photo_keywords WHERE photo_id = ? AND keyword_path = ?")
                for path in removed.sorted() {
                    _ = try statement.run([.text(photoId), .text(path)])
                }
            }
            // usage_count 只是排序权重：只重算受影响的路径（改动集合通常很小）。
            let recompute = try connection.prepare(
                "UPDATE keywords SET usage_count = (SELECT COUNT(*) FROM photo_keywords pk WHERE pk.keyword_path = keywords.path) WHERE path = ?")
            for path in inserted.union(removed) {
                _ = try recompute.run([.text(path)])
            }
            return (inserted.sorted(), removed.sorted())
        }
    }

    public func deletePhotoKeywords(photoId: String) throws -> Int {
        try connection.prepare("DELETE FROM photo_keywords WHERE photo_id = ?").run([.text(photoId)])
    }

    /// 某路径的成员数（includeDescendants=true 时按子树统计）。
    public func memberCount(path: String, includeDescendants: Bool) throws -> Int {
        if includeDescendants {
            let predicate = KeywordPathSQL.subtreePredicate(column: "keyword_path", path: path)
            return Int(try connection.prepare(
                "SELECT COUNT(*) AS n FROM photo_keywords WHERE \(predicate.sql)")
                .get(predicate.params)?[0].intValue ?? 0)
        }
        return Int(try connection.prepare(
            "SELECT COUNT(*) AS n FROM photo_keywords WHERE keyword_path = ?")
            .get([.text(path)])?[0].intValue ?? 0)
    }

    /// 每个路径的成员数（按**逻辑资产**去重，与网格/facet 同口径）。
    public func assetCounts(sessionId: String?) throws -> [String: Int] {
        var sql = """
            SELECT pk.keyword_path AS path,
                   COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id)) AS n
            FROM photo_keywords pk JOIN photos p ON p.id = pk.photo_id
            WHERE \(PhotoVisibility.visiblePredicate(alias: "p"))
            """
        var params: [DBValue] = []
        if let sessionId {
            sql += " AND p.session_id = ?"
            params.append(.text(sessionId))
        }
        sql += " GROUP BY pk.keyword_path"
        var result: [String: Int] = [:]
        for row in try connection.prepare(sql).query(params) {
            guard let path = row[0].textValue else { continue }
            result[path] = Int(row[1].intValue ?? 0)
        }
        return result
    }

    // MARK: - 回填（photo_metadata_cache → photo_keywords）

    /// 回填游标批次：photo_id 升序、只取尚未进 photo_keywords 的照片。
    /// 幂等：以 photo_keywords 是否存在判断（重复调用不会重复写）。
    public func pendingBackfillBatch(after photoId: String?, limit: Int) throws -> [
        (photoId: String, sessionId: String, keywordsJSON: String)
    ] {
        var sql = """
            SELECT c.photo_id, c.session_id, c.keywords
            FROM photo_metadata_cache c
            WHERE EXISTS (
              SELECT 1 FROM json_each(c.keywords) WHERE value IS NOT NULL AND value <> '')
            """
        var params: [DBValue] = []
        if let photoId {
            sql += " AND c.photo_id > ?"
            params.append(.text(photoId))
        }
        sql += """
             AND NOT EXISTS (SELECT 1 FROM photo_keywords pk WHERE pk.photo_id = c.photo_id)
            ORDER BY c.photo_id
            LIMIT ?
            """
        params.append(.int(Int64(max(1, limit))))
        return try connection.prepare(sql).query(params).compactMap { row in
            guard let id = row[0].textValue, let session = row[1].textValue else { return nil }
            return (id, session, row[2].textValue ?? "[]")
        }
    }

    // MARK: - 行映射

    private static func row(_ row: DBRow) -> KeywordRow {
        KeywordRow(
            id: row[0].intValue ?? 0,
            path: row[1].textValue ?? "",
            name: row[2].textValue ?? "",
            parentPath: row[3].textValue,
            usageCount: Int(row[4].intValue ?? 0),
            createdAt: row[5].textValue ?? "")
    }
}

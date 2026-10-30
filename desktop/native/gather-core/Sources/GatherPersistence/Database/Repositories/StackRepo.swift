// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/StackRepo.swift
// P1 下一波 §3.8.2：照片堆栈 photo_stacks / photo_stack_members。
//
// 语义（与设计一致）：
// 1. **折叠只影响展示**：本仓储只回答"哪些照片属于同一个堆栈 / 封面是谁"，
//    绝不改写 photos.status、culling_decisions、评分或交付行——折叠不得改变
//    任何决策语义（网格把成员折成一张 + n 徽标只是视觉行为）。
// 2. **封面 SET NULL**：photo_stacks.cover_photo_id 是 ON DELETE SET NULL 外键；
//    成员被移出堆栈时（不是删照片）由本仓储显式把封面置 NULL——与数据库对
//    "照片被删"的行为保持一致，读侧永远按 displayCoverPhotoId（显式封面 →
//    首个成员）兜底，不会出现"封面指向非成员"。
// 3. **一照一堆栈**：photo_stack_members 的主键只保证 (stack, photo) 唯一，
//    同一张照片理论上可进两个堆栈。折叠视图要求唯一性，故 createStack 前由
//    CurationService 调 detachPhotos 把目标照片从既有堆栈里摘掉（仓储提供该
//    能力但不替调用方决定语义）。
//
// 事务边界：create / add / remove 自带事务；读不开事务。
import Foundation
import GatherProtocol

/// photo_stacks 行（member_count 由子查询填充）。
public struct StackRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let name: String
    public let coverPhotoId: String?
    public let memberCount: Int
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        sessionId: String,
        name: String,
        coverPhotoId: String?,
        memberCount: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.coverPhotoId = coverPhotoId
        self.memberCount = memberCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// photo_stack_members 行（position 升序 = 堆内顺序）。
public struct StackMemberRow: Equatable, Sendable {
    public let stackId: String
    public let photoId: String
    public let position: Int

    public init(stackId: String, photoId: String, position: Int) {
        self.stackId = stackId
        self.photoId = photoId
        self.position = position
    }
}

public struct StackRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    private static let columns = """
        s.id, s.session_id, s.name, s.cover_photo_id,
        (SELECT COUNT(*) FROM photo_stack_members m WHERE m.stack_id = s.id),
        s.created_at, s.updated_at
        """

    // MARK: - 读

    public func list(sessionId: String) throws -> [StackRow] {
        let rows = try connection.prepare("""
            SELECT \(Self.columns)
            FROM photo_stacks s
            WHERE s.session_id = ?
            ORDER BY s.created_at, s.id
            """).query([.text(sessionId)])
        return rows.compactMap(Self.mapRow)
    }

    public func get(id: String) throws -> StackRow? {
        try connection.prepare("""
            SELECT \(Self.columns) FROM photo_stacks s WHERE s.id = ?
            """).get([.text(id)]).flatMap(Self.mapRow)
    }

    public func sessionId(of id: String) throws -> String? {
        try connection.prepare("SELECT session_id FROM photo_stacks WHERE id = ?")
            .get([.text(id)])?[0].textValue
    }

    public func members(stackId: String) throws -> [StackMemberRow] {
        let rows = try connection.prepare("""
            SELECT stack_id, photo_id, position
            FROM photo_stack_members
            WHERE stack_id = ?
            ORDER BY position, photo_id
            """).query([.text(stackId)])
        return rows.map { row in
            StackMemberRow(
                stackId: row[0].textValue ?? "",
                photoId: row[1].textValue ?? "",
                position: Int(row[2].intValue ?? 0)
            )
        }
    }

    /// 会话的折叠视图：每个堆栈一条，成员按 position 升序（两次查询，无 N+1）。
    public func folds(sessionId: String) throws -> [StackFold] {
        let stackRows = try list(sessionId: sessionId)
        guard !stackRows.isEmpty else { return [] }
        let memberRows = try connection.prepare("""
            SELECT m.stack_id, m.photo_id
            FROM photo_stack_members m
            JOIN photo_stacks s ON s.id = m.stack_id
            WHERE s.session_id = ?
            ORDER BY m.stack_id, m.position, m.photo_id
            """).query([.text(sessionId)])
        var membersByStack: [String: [String]] = [:]
        for row in memberRows {
            guard let stackId = row[0].textValue, let photoId = row[1].textValue else { continue }
            membersByStack[stackId, default: []].append(photoId)
        }
        return stackRows.map { row in
            StackFold(
                stackId: row.id,
                name: row.name,
                coverPhotoId: row.coverPhotoId,
                photoIds: membersByStack[row.id] ?? []
            )
        }
    }

    /// 这批照片当前所属的堆栈（photoId → stackId）；一照一堆栈时用于迁移。
    public func stackIdsByPhoto(photoIds: [String]) throws -> [String: String] {
        let unique = Self.unique(photoIds)
        guard !unique.isEmpty else { return [:] }
        var map: [String: String] = [:]
        for chunk in unique.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT photo_id, stack_id FROM photo_stack_members
                WHERE photo_id IN (\(placeholders))
                ORDER BY photo_id, position
                """).query(chunk.map(DBValue.text))
            for row in rows {
                guard let photoId = row[0].textValue, let stackId = row[1].textValue else {
                    continue
                }
                // 一个照片只认第一个堆栈（正常数据下不会有第二个）。
                if map[photoId] == nil { map[photoId] = stackId }
            }
        }
        return map
    }

    // MARK: - 写

    /// 建堆栈 + 成员（同一事务）。coverPhotoId 为 nil 时取首个成员。
    ///
    /// 空 photoIds 是参数错误（服务层拒绝），这里再兜一层：不建空堆栈。
    @discardableResult
    public func create(
        sessionId: String,
        name: String,
        coverPhotoId: String?,
        photoIds: [String]
    ) throws -> StackRow {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else {
            throw DBError.message("堆栈必须至少包含一张照片")
        }
        let id = newUUIDString()
        let now = nowISOString()
        let cover = coverPhotoId ?? ordered.first
        return try connection.transaction {
            _ = try connection.prepare("""
                INSERT INTO photo_stacks
                    (id, session_id, name, cover_photo_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """).run([
                    .text(id), .text(sessionId), .text(name),
                    cover.map(DBValue.text) ?? .null, .text(now), .text(now),
                ])
            let insert = try connection.prepare("""
                INSERT OR IGNORE INTO photo_stack_members (stack_id, photo_id, position)
                VALUES (?, ?, ?)
                """)
            for (index, photoId) in ordered.enumerated() {
                _ = try insert.run([
                    .text(id), .text(photoId), .int(Int64(CollectionPositions.step * (index + 1))),
                ])
            }
            guard let row = try get(id: id) else {
                throw DBError.message("新建堆栈后读不到该行（写入未提交或 id 冲突）")
            }
            return row
        }
    }

    /// 改名 / 设封面 / 清封面。返回 false = 堆栈不存在。
    @discardableResult
    public func update(
        id: String,
        name: String?,
        coverPhotoId: String?,
        clearCover: Bool
    ) throws -> Bool {
        var sets: [String] = []
        var values: [DBValue?] = []
        if let name {
            sets.append("name = ?")
            values.append(.text(name))
        }
        if clearCover {
            sets.append("cover_photo_id = NULL")
        } else if let coverPhotoId {
            sets.append("cover_photo_id = ?")
            values.append(.text(coverPhotoId))
        }
        guard !sets.isEmpty else { return try get(id: id) != nil }
        sets.append("updated_at = ?")
        values.append(.text(nowISOString()))
        values.append(.text(id))
        let sql = "UPDATE photo_stacks SET " + sets.joined(separator: ", ") + " WHERE id = ?"
        return try connection.prepare(sql).run(values) > 0
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        // 成员由 ON DELETE CASCADE 清理。
        try connection.prepare("DELETE FROM photo_stacks WHERE id = ?").run([.text(id)]) > 0
    }

    /// 追加成员（尾部，position = 末位 + 1024）。返回新增条数。
    @discardableResult
    public func addMembers(stackId: String, photoIds: [String]) throws -> Int {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            let maxRow = try connection.prepare(
                "SELECT MAX(position) FROM photo_stack_members WHERE stack_id = ?"
            ).get([.text(stackId)])
            var cursor = maxRow?[0].intValue.map(Int.init)
            let insert = try connection.prepare("""
                INSERT OR IGNORE INTO photo_stack_members (stack_id, photo_id, position)
                VALUES (?, ?, ?)
                """)
            var inserted = 0
            for photoId in ordered {
                let position = CollectionPositions.appendPosition(last: cursor)
                let changed = try insert.run([
                    .text(stackId), .text(photoId), .int(Int64(position)),
                ])
                if changed > 0 {
                    inserted += 1
                    cursor = position
                }
            }
            if inserted > 0 { try touch(id: stackId) }
            return inserted
        }
    }

    /// 移除成员；封面若因此不再是成员则置 NULL（与 FK 的 SET NULL 同语义）。
    @discardableResult
    public func removeMembers(stackId: String, photoIds: [String]) throws -> Int {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            var removed = 0
            for chunk in ordered.chunked(by: 400) where !chunk.isEmpty {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                removed += try connection.prepare("""
                    DELETE FROM photo_stack_members
                    WHERE stack_id = ? AND photo_id IN (\(placeholders))
                    """).run([.text(stackId)] + chunk.map(DBValue.text))
            }
            if removed > 0 {
                try clearCoverIfNotMember(stackId: stackId)
                try touch(id: stackId)
            }
            return removed
        }
    }

    /// 把照片从它所在的任何堆栈里摘掉（一照一堆栈的收敛动作）。
    @discardableResult
    public func detachPhotos(photoIds: [String]) throws -> Int {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            var affectedStacks = Set<String>()
            var removed = 0
            for chunk in ordered.chunked(by: 400) where !chunk.isEmpty {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let rows = try connection.prepare("""
                    SELECT DISTINCT stack_id FROM photo_stack_members
                    WHERE photo_id IN (\(placeholders))
                    """).query(chunk.map(DBValue.text))
                affectedStacks.formUnion(rows.compactMap { $0[0].textValue })
                removed += try connection.prepare(
                    "DELETE FROM photo_stack_members WHERE photo_id IN (\(placeholders))"
                ).run(chunk.map(DBValue.text))
            }
            for stackId in affectedStacks {
                try clearCoverIfNotMember(stackId: stackId)
                // 空堆栈（成员全被摘走）直接删除，避免留下看不见的壳。
                let remaining = try connection.prepare(
                    "SELECT 1 FROM photo_stack_members WHERE stack_id = ? LIMIT 1"
                ).get([.text(stackId)])
                if remaining == nil {
                    _ = try connection.prepare("DELETE FROM photo_stacks WHERE id = ?")
                        .run([.text(stackId)])
                } else {
                    try touch(id: stackId)
                }
            }
            return removed
        }
    }

    /// 封面不再是成员 → 置 NULL（读侧回落到首个成员）。
    public func clearCoverIfNotMember(stackId: String) throws {
        _ = try connection.prepare("""
            UPDATE photo_stacks
            SET cover_photo_id = NULL
            WHERE id = ?
              AND cover_photo_id IS NOT NULL
              AND NOT EXISTS (
                SELECT 1 FROM photo_stack_members m
                WHERE m.stack_id = photo_stacks.id AND m.photo_id = photo_stacks.cover_photo_id
              )
            """).run([.text(stackId)])
    }

    public func touch(id: String) throws {
        _ = try connection.prepare("UPDATE photo_stacks SET updated_at = ? WHERE id = ?")
            .run([.text(nowISOString()), .text(id)])
    }

    // MARK: - 内部

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func mapRow(_ row: DBRow) -> StackRow? {
        guard row.count >= 7 else { return nil }
        return StackRow(
            id: row[0].textValue ?? "",
            sessionId: row[1].textValue ?? "",
            name: row[2].textValue ?? "",
            coverPhotoId: row[3].textValue,
            memberCount: Int(row[4].intValue ?? 0),
            createdAt: row[5].textValue ?? "",
            updatedAt: row[6].textValue ?? ""
        )
    }
}

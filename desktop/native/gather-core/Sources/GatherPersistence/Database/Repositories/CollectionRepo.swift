// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CollectionRepo.swift
// P1 下一波 §3.8.1：手动集合 collections / collection_items 的读写。
//
// 排序契约（本文件存在的理由）：
// 1. **拖拽单行写**：成员 position 用步长 1024 插入；拖到两张之间只 UPDATE 被拖的
//    那一行（position = 前后中点），不重写全表。
// 2. **间隙耗尽 / 冲突**：相邻 position 差 < 2 时（连续拖拽会二分到 0），在**同一
//    事务内**重排为 step 网格（1024, 2048, …）再写那一行——仍是"事务内重排"，
//    只是网格留出了后续单行写的空间。
// 3. **显式重排**（用户拖出确定顺序 / API reorderItems）：位置写 1..n，一次事务。
//
// 为什么是 struct 而不是 final class：仓储只持有不可变的 DBConnection（自身
// @unchecked Sendable），没有可变状态，结构体自动满足 Sendable——不新增
// @unchecked Sendable 预算（cleanup ratchet 计数）。
//
// 事务边界：写路径自带事务（append / remove / reorder / move 的 compaction），
// 读路径不开事务。调用方（CurationService）不再二次包事务。
import Foundation

/// collections 行（item_count 由子查询填充）。
public struct CollectionRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let name: String
    public let sortOrder: Int
    public let itemCount: Int
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        sessionId: String,
        name: String,
        sortOrder: Int,
        itemCount: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.sortOrder = sortOrder
        self.itemCount = itemCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// collection_items 行（JOIN photos 取展示字段）。
public struct CollectionItemRow: Equatable, Sendable {
    public let photoId: String
    public let position: Int
    public let filepath: String
    public let filename: String

    public init(photoId: String, position: Int, filepath: String, filename: String) {
        self.photoId = photoId
        self.position = position
        self.filepath = filepath
        self.filename = filename
    }
}

/// position 纯数学（无 IO，金样可测）。
public enum CollectionPositions {
    /// 插入步长（§3.8.1）。
    public static let step = 1024

    /// 尾部追加：末位 + step；空集合从 step 开始（溢出时回落 step，下一轮走重排）。
    public static func appendPosition(last: Int?) -> Int {
        guard let last else { return step }
        let (sum, overflow) = last.addingReportingOverflow(step)
        return overflow ? step : sum
    }

    /// 前后中点；返回 nil = 没有可用间隙，调用方必须重排。
    ///
    /// - 前后都 nil：空集合 → step。
    /// - 只给 next（移到最前）：next >= 2 → next/2，否则无间隙。
    /// - 只给 previous（移到最后）：previous + step。
    /// - 都有：gap >= 2 → previous + gap/2，否则无间隙（相邻/相同 position）。
    public static func midpoint(previous: Int?, next: Int?) -> Int? {
        switch (previous, next) {
        case (nil, nil):
            return step
        case (nil, let next?):
            return next >= 2 ? next / 2 : nil
        case (let previous?, nil):
            let (sum, overflow) = previous.addingReportingOverflow(step)
            return overflow ? nil : sum
        case (let previous?, let next?):
            guard next > previous, next - previous >= 2 else { return nil }
            return previous + (next - previous) / 2
        }
    }

    /// 重排网格：step, 2*step, …（拖拽 fallback 用，留出后续单行写的空间）。
    public static func spacedGrid(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0..<count).map { step * ($0 + 1) }
    }

    /// 显式顺序：1..n（reorderItems 契约：位置写 1..n）。
    public static func sequential(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(1...count)
    }

    /// 把 photoId 插到锚点之间后的完整顺序（兜底路径用，纯函数）。
    public static func movedOrder(
        _ ordered: [String],
        photoId: String,
        previousPhotoId: String?,
        nextPhotoId: String?
    ) -> [String] {
        var working = ordered.filter { $0 != photoId }
        if let nextPhotoId, let index = working.firstIndex(of: nextPhotoId) {
            working.insert(photoId, at: index)
        } else if let previousPhotoId, let index = working.firstIndex(of: previousPhotoId) {
            working.insert(photoId, at: index + 1)
        } else {
            working.insert(photoId, at: 0)
        }
        return working
    }
}

public struct CollectionRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 列清单（item_count 由相关子查询填充；禁 SELECT *）。
    private static let columns = """
        c.id, c.session_id, c.name, c.sort_order,
        (SELECT COUNT(*) FROM collection_items ci WHERE ci.collection_id = c.id),
        c.created_at, c.updated_at
        """

    // MARK: - 集合读

    public func list(sessionId: String) throws -> [CollectionRow] {
        let rows = try connection.prepare("""
            SELECT \(Self.columns)
            FROM collections c
            WHERE c.session_id = ?
            ORDER BY c.sort_order, c.name, c.id
            """).query([.text(sessionId)])
        return rows.compactMap(Self.mapRow)
    }

    public func get(id: String) throws -> CollectionRow? {
        try connection.prepare("""
            SELECT \(Self.columns) FROM collections c WHERE c.id = ?
            """).get([.text(id)]).flatMap(Self.mapRow)
    }

    /// 集合所属会话（不存在 → nil；用于跨会话越权校验与 ALBUM_NOT_FOUND）。
    public func sessionId(of id: String) throws -> String? {
        try connection.prepare("SELECT session_id FROM collections WHERE id = ?")
            .get([.text(id)])?[0].textValue
    }

    public func exists(id: String) throws -> Bool {
        try connection.prepare("SELECT 1 FROM collections WHERE id = ?")
            .get([.text(id)]) != nil
    }

    /// 同名（同会话）唯一索引的预检：实现层给友好错误，不靠 SQLite 报错文本。
    public func nameExists(sessionId: String, name: String, excluding id: String? = nil) throws -> Bool {
        if let id {
            return try connection.prepare(
                "SELECT 1 FROM collections WHERE session_id = ? AND name = ? AND id <> ?"
            ).get([.text(sessionId), .text(name), .text(id)]) != nil
        }
        return try connection.prepare(
            "SELECT 1 FROM collections WHERE session_id = ? AND name = ?"
        ).get([.text(sessionId), .text(name)]) != nil
    }

    /// 下一个可用的 sort_order（同会话尾部，空会话 0）。
    public func nextSortOrder(sessionId: String) throws -> Int {
        let row = try connection.prepare(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM collections WHERE session_id = ?"
        ).get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    // MARK: - 集合写

    @discardableResult
    public func create(sessionId: String, name: String, sortOrder: Int) throws -> CollectionRow {
        let id = newUUIDString()
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO collections (id, session_id, name, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """).run([
                .text(id), .text(sessionId), .text(name), .int(Int64(sortOrder)),
                .text(now), .text(now),
            ])
        guard let row = try get(id: id) else {
            throw DBError.message("新建集合后读不到该行（写入未提交或 id 冲突）")
        }
        return row
    }

    public func rename(id: String, name: String) throws -> Bool {
        let updated = try connection.prepare(
            "UPDATE collections SET name = ?, updated_at = ? WHERE id = ?"
        ).run([.text(name), .text(nowISOString()), .text(id)])
        return updated > 0
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        try connection.prepare("DELETE FROM collections WHERE id = ?").run([.text(id)]) > 0
    }

    public func touch(id: String) throws {
        _ = try connection.prepare("UPDATE collections SET updated_at = ? WHERE id = ?")
            .run([.text(nowISOString()), .text(id)])
    }

    // MARK: - 成员读

    public func items(collectionId: String) throws -> [CollectionItemRow] {
        let rows = try connection.prepare("""
            SELECT ci.photo_id, ci.position, p.filepath, p.filename
            FROM collection_items ci
            JOIN photos p ON p.id = ci.photo_id
            WHERE ci.collection_id = ?
            ORDER BY ci.position, ci.photo_id
            """).query([.text(collectionId)])
        return rows.map { row in
            CollectionItemRow(
                photoId: row[0].textValue ?? "",
                position: Int(row[1].intValue ?? 0),
                filepath: row[2].textValue ?? "",
                filename: row[3].textValue ?? ""
            )
        }
    }

    public func memberPhotoIds(collectionId: String) throws -> [String] {
        try connection.prepare("""
            SELECT photo_id FROM collection_items
            WHERE collection_id = ? ORDER BY position, photo_id
            """).query([.text(collectionId)]).compactMap { $0[0].textValue }
    }

    public func lastPosition(collectionId: String) throws -> Int? {
        let row = try connection.prepare(
            "SELECT MAX(position) FROM collection_items WHERE collection_id = ?"
        ).get([.text(collectionId)])
        return row?[0].intValue.map(Int.init)
    }

    /// 会话内存在的照片 id 子集（成员写入前预检）。
    ///
    /// 为什么不靠 FK 报错：SQLite 的外键错误只有文本（"FOREIGN KEY constraint
    /// failed"），API 层无法据此给出 PHOTO_NOT_FOUND，而字符串匹配错误信息是
    /// 本仓明令禁止的做法（check-coded-errors 的同类问题）。分块 IN 避免变量上限。
    public func sessionExists(_ id: String) throws -> Bool {
        try connection.prepare("SELECT 1 FROM sessions WHERE id = ?")
            .get([.text(id)]) != nil
    }

    /// 会话内存在的照片 id 子集（成员写入前预检；分块 IN 避免变量上限）。
    public func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String> {
        let unique = Self.unique(photoIds)
        guard !unique.isEmpty else { return [] }
        var found = Set<String>()
        for offset in stride(from: 0, to: unique.count, by: 400) {
            let chunk = Array(unique[offset..<Swift.min(offset + 400, unique.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT id FROM photos
                WHERE session_id = ? AND id IN (\(placeholders))
                """).query([.text(sessionId)] + chunk.map(DBValue.text))
            for row in rows {
                if let id = row[0].textValue { found.insert(id) }
            }
        }
        return found
    }

    /// 该照片是否已在集合里（拖拽/去重判断）。
    public func contains(collectionId: String, photoId: String) throws -> Bool {
        try connection.prepare(
            "SELECT 1 FROM collection_items WHERE collection_id = ? AND photo_id = ?"
        ).get([.text(collectionId), .text(photoId)]) != nil
    }

    // MARK: - 成员写

    /// 尾部追加（按输入顺序、去重、跳过已在集合内的）；返回新增条数。
    ///
    /// 事务内逐行 INSERT（position = 上一个 + 1024）：每行一次写入，不重写既有行。
    @discardableResult
    public func appendItems(collectionId: String, photoIds: [String]) throws -> Int {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            var cursor = try lastPosition(collectionId: collectionId)
            let insert = try connection.prepare("""
                INSERT OR IGNORE INTO collection_items
                    (collection_id, photo_id, position, added_at)
                VALUES (?, ?, ?, ?)
                """)
            let now = nowISOString()
            var inserted = 0
            for photoId in ordered {
                let position = CollectionPositions.appendPosition(last: cursor)
                let changed = try insert.run([
                    .text(collectionId), .text(photoId), .int(Int64(position)), .text(now),
                ])
                if changed > 0 {
                    inserted += 1
                    cursor = position
                }
            }
            if inserted > 0 { try touch(id: collectionId) }
            return inserted
        }
    }

    /// 移除成员；返回删除条数。
    @discardableResult
    public func removeItems(collectionId: String, photoIds: [String]) throws -> Int {
        let ordered = Self.unique(photoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            let placeholders = ordered.map { _ in "?" }.joined(separator: ", ")
            let removed = try connection.prepare("""
                DELETE FROM collection_items
                WHERE collection_id = ? AND photo_id IN (\(placeholders))
                """).run([.text(collectionId)] + ordered.map(DBValue.text))
            if removed > 0 { try touch(id: collectionId) }
            return removed
        }
    }

    /// 显式重排：photoIds 即目标顺序，位置写 1..n（事务内一次完成）。
    ///
    /// 只改这些成员的 position；不在列表里的成员保持原 position。
    @discardableResult
    public func reorderItems(collectionId: String, orderedPhotoIds: [String]) throws -> Int {
        let ordered = Self.unique(orderedPhotoIds)
        guard !ordered.isEmpty else { return 0 }
        return try connection.transaction {
            let update = try connection.prepare(
                "UPDATE collection_items SET position = ? WHERE collection_id = ? AND photo_id = ?"
            )
            var written = 0
            for (index, photoId) in ordered.enumerated() {
                written += try update.run([
                    .int(Int64(index + 1)), .text(collectionId), .text(photoId),
                ])
            }
            if written > 0 { try touch(id: collectionId) }
            return written
        }
    }

    /// 单行拖拽。返回 false = 集合/照片/参照照片不匹配（调用方转 ALBUM_NOT_FOUND /
    /// PHOTO_NOT_FOUND 语义错误）；true = 已落盘。
    ///
    /// 写入次数：正常 1 行 UPDATE；间隙耗尽时 1 次事务内重排（n 行）+ 1 行 UPDATE。
    @discardableResult
    public func moveItem(
        collectionId: String,
        photoId: String,
        afterPhotoId: String?,
        beforePhotoId: String?
    ) throws -> Bool {
        let members = try items(collectionId: collectionId)
        guard members.contains(where: { $0.photoId == photoId }) else { return false }
        let ordered = members.map(\.photoId)
        guard let anchor = try resolvedAnchor(
            ordered: ordered,
            photoId: photoId,
            afterPhotoId: afterPhotoId,
            beforePhotoId: beforePhotoId
        ) else { return false }
        let positionById = Dictionary(
            uniqueKeysWithValues: members.map { ($0.photoId, $0.position) }
        )
        let previous = anchor.previousPhotoId.flatMap { positionById[$0] }
        let next = anchor.nextPhotoId.flatMap { positionById[$0] }

        if let midpoint = CollectionPositions.midpoint(previous: previous, next: next) {
            return try connection.transaction {
                try writePosition(collectionId: collectionId, photoId: photoId, position: midpoint)
            }
        }

        // 间隙耗尽：事务内重排为 step 网格，然后只写被拖的那一行。
        return try connection.transaction {
            let compacted = try compactPositions(collectionId: collectionId, ordered: ordered)
            let compactPrevious = anchor.previousPhotoId.flatMap { compacted[$0] }
            let compactNext = anchor.nextPhotoId.flatMap { compacted[$0] }
            if let reposition = CollectionPositions.midpoint(
                previous: compactPrevious, next: compactNext
            ) {
                return try writePosition(
                    collectionId: collectionId, photoId: photoId, position: reposition
                )
            }
            // 网格也撑不开（理论上不可达：相邻网格必差 1024）→ 整段写 1..n。
            let finalOrder = CollectionPositions.movedOrder(
                ordered,
                photoId: photoId,
                previousPhotoId: anchor.previousPhotoId,
                nextPhotoId: anchor.nextPhotoId
            )
            let update = try connection.prepare(
                "UPDATE collection_items SET position = ? WHERE collection_id = ? AND photo_id = ?"
            )
            for (index, memberId) in finalOrder.enumerated() {
                _ = try update.run([.int(Int64(index + 1)), .text(collectionId), .text(memberId)])
            }
            try touch(id: collectionId)
            return true
        }
    }

    // MARK: - 内部

    /// 拖拽锚点：被拖行在"移除自己后"的前后邻居（nil = 头/尾）。
    private struct Anchor {
        let previousPhotoId: String?
        let nextPhotoId: String?
    }

    private func resolvedAnchor(
        ordered: [String],
        photoId: String,
        afterPhotoId: String?,
        beforePhotoId: String?
    ) throws -> Anchor? {
        guard let current = ordered.firstIndex(of: photoId) else { return nil }
        var working = ordered
        working.remove(at: current)
        if let beforePhotoId {
            guard let index = working.firstIndex(of: beforePhotoId) else { return nil }
            return Anchor(
                previousPhotoId: index > 0 ? working[index - 1] : nil,
                nextPhotoId: working[index]
            )
        }
        if let afterPhotoId {
            guard let index = working.firstIndex(of: afterPhotoId) else { return nil }
            return Anchor(
                previousPhotoId: working[index],
                nextPhotoId: index + 1 < working.count ? working[index + 1] : nil
            )
        }
        // 移到最前。
        return Anchor(previousPhotoId: nil, nextPhotoId: working.first)
    }

    /// 事务内重排为 step 网格；返回 photoId → 新 position。
    private func compactPositions(collectionId: String, ordered: [String]) throws -> [String: Int] {
        let grid = CollectionPositions.spacedGrid(count: ordered.count)
        let update = try connection.prepare(
            "UPDATE collection_items SET position = ? WHERE collection_id = ? AND photo_id = ?"
        )
        var map: [String: Int] = [:]
        map.reserveCapacity(ordered.count)
        for (index, memberId) in ordered.enumerated() {
            _ = try update.run([.int(Int64(grid[index])), .text(collectionId), .text(memberId)])
            map[memberId] = grid[index]
        }
        return map
    }

    /// 单行 position 写入（调用方已在事务内）。
    private func writePosition(collectionId: String, photoId: String, position: Int) throws -> Bool {
        let updated = try connection.prepare(
            "UPDATE collection_items SET position = ? WHERE collection_id = ? AND photo_id = ?"
        ).run([.int(Int64(position)), .text(collectionId), .text(photoId)])
        if updated > 0 { try touch(id: collectionId) }
        return updated > 0
    }

    /// 批内去重（保持首次出现顺序，丢弃空 id）。
    public static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func mapRow(_ row: DBRow) -> CollectionRow? {
        guard row.count >= 7 else { return nil }
        return CollectionRow(
            id: row[0].textValue ?? "",
            sessionId: row[1].textValue ?? "",
            name: row[2].textValue ?? "",
            sortOrder: Int(row[3].intValue ?? 0),
            itemCount: Int(row[4].intValue ?? 0),
            createdAt: row[5].textValue ?? "",
            updatedAt: row[6].textValue ?? ""
        )
    }
}

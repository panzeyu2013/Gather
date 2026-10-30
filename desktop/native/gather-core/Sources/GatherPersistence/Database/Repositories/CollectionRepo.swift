// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CollectionRepo.swift
// P1 下一波 §3.8.1：手动集合 collections / collection_items 的读写。
//
// 排序契约（本文件存在的理由）：
// 1. **拖拽单行写**：成员 position 用步长 1024 插入；拖到两张之间只 UPDATE 被拖的
//    那一行（position = 前后中点），不重写全表。
// 2. **间隙耗尽 / 冲突**：相邻 position 差 < 2 时（连续拖拽会二分到 0），在**同一
//    事务内**重排为 step 网格（1024, 2048, …）再写那一行——仍是"事务内重排"，
//    只是网格留出了后续单行写的空间。
// 3. **显式重排**（用户拖出确定顺序 / API reorderItems）：位置写 1..n，一次事务；
//    未列出的成员续接 n+1..（A9：原实现让它们保留旧 position，与 1..n 并列）。
//
// 为什么是 struct 而不是 final class：仓储只持有不可变的 DBConnection（自身
// @unchecked Sendable），没有可变状态，结构体自动满足 Sendable——不新增
// @unchecked Sendable 预算（cleanup ratchet 计数）。
//
// 事务边界：写路径自带事务（append / remove / reorder / move 的 compaction），
// 读路径不开事务。调用方（CurationService）不再二次包事务。
// A9：moveItem 的成员快照读并入同一事务（原实现在事务外读 items）。
//
// 可见性（P1-8）：用户可见读面（items / item_count 子查询）带 PhotoVisibility 谓词，
// 已移出工作区（archived_at 非空）的照片不再出现在集合成员与计数里；按显式 id 的
// 操作（contains / removeItems / 排序压缩）不过滤——否则集合里"看不见的成员行"
// 会永远删不掉，压缩也会漏行撞位。
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
    ///
    /// P1-8：item_count 只数**仍在工作区**的成员（PhotoVisibility，与 keyword facet /
    /// 网格同一口径）。原实现数 collection_items 的全部行，淘汰移出（filepath 指向
    /// _rejects）的照片仍计入徽标 —— 集合里可见 0 张却显示"3 张"，或徽标数大于网格行数。
    private static let columns = """
        c.id, c.session_id, c.name, c.sort_order,
        (SELECT COUNT(*) FROM collection_items ci
           JOIN photos p ON p.id = ci.photo_id
          WHERE ci.collection_id = c.id AND \(PhotoVisibility.visiblePredicate(alias: "p"))),
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

    /// 建集合。sortOrder 传 nil = 落在本会话尾部。
    ///
    /// A9：sortOrder 缺省时**在同一事务内**取尾部序号再 INSERT。原实现由调用方先
    /// nextSortOrder 再 create（两条独立语句），两个并发建集合会拿到同一个 sort_order
    /// —— 排序并列后 ORDER BY sort_order 只靠 name/id 兜底，用户看到顺序与创建顺序不符。
    @discardableResult
    public func create(
        sessionId: String,
        name: String,
        sortOrder: Int? = nil
    ) throws -> CollectionRow {
        let id = newUUIDString()
        let now = nowISOString()
        return try connection.transaction {
            let resolved: Int
            if let sortOrder {
                resolved = sortOrder
            } else {
                resolved = try nextSortOrder(sessionId: sessionId)
            }
            _ = try connection.prepare("""
                INSERT INTO collections (id, session_id, name, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """).run([
                    .text(id), .text(sessionId), .text(name), .int(Int64(resolved)),
                    .text(now), .text(now),
                ])
            guard let row = try get(id: id) else {
                throw DBError.message("新建集合后读不到该行（写入未提交或 id 冲突）")
            }
            return row
        }
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

    /// 集合成员（**用户可见读面**）。
    ///
    /// P1-8：与 item_count / keyword facet 同口径排除已移出工作区的照片 —— 否则
    /// 淘汰移出后集合网格仍列出该行，点开是 _rejects 里的路径。写路径（moveItem 的
    /// 排序压缩、removeItems/contains）不用本方法，改读全量成员快照。
    public func items(collectionId: String) throws -> [CollectionItemRow] {
        let rows = try connection.prepare("""
            SELECT ci.photo_id, ci.position, p.filepath, p.filename
            FROM collection_items ci
            JOIN photos p ON p.id = ci.photo_id
            WHERE ci.collection_id = ?
              AND \(PhotoVisibility.visiblePredicate(alias: "p"))
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
            var removed = 0
            for chunk in ordered.chunked(by: 400) where !chunk.isEmpty {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                removed += try connection.prepare("""
                    DELETE FROM collection_items
                    WHERE collection_id = ? AND photo_id IN (\(placeholders))
                    """).run([.text(collectionId)] + chunk.map(DBValue.text))
            }
            if removed > 0 { try touch(id: collectionId) }
            return removed
        }
    }

    /// 显式重排：photoIds 即目标顺序，位置写 1..n（事务内一次完成）。
    ///
    /// A9：未列出的成员**续接 n+1..**（并保持它们之间的既有相对顺序）。原实现让
    /// 未列出成员保留旧 position，于是与新写的 1..n 并列——并列后 ORDER BY position
    /// 只靠 photo_id 兜底，用户拖出的顺序在下一轮读取里"随机"变化。
    /// 返回值仍是**被列出且写中**的行数：调用方用它判断集合/成员是否有效，不能被
    /// 续接写入放大。
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
            // 一行都没写中 = 入参 id 都不属于该集合：保持原行为（返回 0 让调用方报
            // notFound），并且不要顺手改动未列出成员的 position。
            if written > 0 {
                try extendUnlistedPositions(
                    collectionId: collectionId, listed: ordered, update: update)
                try touch(id: collectionId)
            }
            return written
        }
    }

    /// 把未列出的成员续接到 listed.count + 1 起。
    ///
    /// 复用 reorderItems 已准备好的 statement，只在确实写中至少一行时执行；
    /// 读取用 memberPhotoIds（不 JOIN photos），已移出工作区的成员同样要续接——
    /// 它们仍是成员行，position 撞车同样会让可见顺序不稳定。
    private func extendUnlistedPositions(
        collectionId: String,
        listed: [String],
        update: DBStatement
    ) throws {
        let listedSet = Set(listed)
        let remaining = try memberPhotoIds(collectionId: collectionId)
            .filter { !listedSet.contains($0) }
        for (offset, photoId) in remaining.enumerated() {
            _ = try update.run([
                .int(Int64(listed.count + offset + 1)), .text(collectionId), .text(photoId),
            ])
        }
    }

    /// 单行拖拽。返回 false = 集合/照片/参照照片不匹配（调用方转 ALBUM_NOT_FOUND /
    /// PHOTO_NOT_FOUND 语义错误）；true = 已落盘。
    ///
    /// 写入次数：正常 1 行 UPDATE；间隙耗尽时 1 次事务内重排（n 行）+ 1 行 UPDATE。
    ///
    /// A9：成员快照与写入**必须同一事务**。原实现在事务外读 items 算锚点/中点，另一处
    /// append/remove/reorder 可在读写之间改变成员集与 position，落库位置就是按陈旧
    /// 快照算出来的（可能越过锚点或被后面的 append 顶开）。
    /// 快照走 memberSnapshots（**不过滤**已移出工作区的成员）：压缩网格必须覆盖全部
    /// 成员行，否则被移出的成员保留旧 position 会与网格撞位。
    @discardableResult
    public func moveItem(
        collectionId: String,
        photoId: String,
        afterPhotoId: String?,
        beforePhotoId: String?
    ) throws -> Bool {
        try connection.transaction {
            let members = try memberSnapshots(collectionId: collectionId)
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
                return try writePosition(
                    collectionId: collectionId, photoId: photoId, position: midpoint)
            }

            // 间隙耗尽：事务内重排为 step 网格，然后只写被拖的那一行。
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

    /// 全量成员快照（photoId + position，**不过滤**已移出工作区的照片）。
    ///
    /// 排序压缩（moveItem / reorderItems 的续接）必须看到每一行：漏掉的行会保留旧
    /// position 并与新网格撞位。用户可见读面用 items()（带 PhotoVisibility 谓词）。
    private func memberSnapshots(collectionId: String) throws -> [(photoId: String, position: Int)] {
        try connection.prepare("""
            SELECT photo_id, position FROM collection_items
            WHERE collection_id = ?
            ORDER BY position, photo_id
            """).query([.text(collectionId)]).map { row in
            (photoId: row[0].textValue ?? "", position: Int(row[1].intValue ?? 0))
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

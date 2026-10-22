// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DuplicateRepo.swift
// WP3b-3：duplicate_groups / duplicate_group_members / photos.status 写路径下沉。
//
// SQL 文本从 GatherApplication/Services/DuplicateService.swift 原样搬入：
//   - 扫描读：photos 投影、按 checksum 聚合、similarity_hashes JOIN photos；
//   - 重建事务（组/成员 DELETE + INSERT、决策读取）；
//   - resolveGroup / resolveMember 的 UPDATE；
//   - photos.status 的三个写者（markDiscarded / restoreOrphanedRemoved /
//     recomputePhotoStatuses）——"丢弃"的下游后果仍唯一落在 photos.status。
// 事务仍由调用方经 TransactionRunner 开启；本类不自行开事务（与旧实现一致）。
import Foundation

public final class DuplicateRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 扫描读

    /// 会话内的 photos 投影（checksum 复用判定）。
    public func getScanPhotos(sessionId: String) throws -> [DuplicateScanPhoto] {
        try connection.prepare("""
            SELECT id, filepath, checksum, checksum_file_size, checksum_file_mtime_ms
            FROM photos WHERE session_id IN (?)
            """).query([.text(sessionId)]).map { row in
                DuplicateScanPhoto(
                    id: row[0].textValue ?? "",
                    filepath: row[1].textValue ?? "",
                    checksum: row[2].textValue ?? "",
                    checksumFileSize: row[3].intValue ?? 0,
                    checksumFileMtimeMs: row[4].doubleValue ?? 0
                )
            }
    }

    /// 精确重复聚合：按 checksum 分组，仅保留成员数 > 1 的组。
    public func getExactGroups(sessionId: String) throws -> [DuplicateExactGroup] {
        try connection.prepare("""
            SELECT checksum, COUNT(*) as cnt, GROUP_CONCAT(id) as photo_ids
            FROM photos
            WHERE session_id IN (?) AND checksum != ''
            GROUP BY checksum
            HAVING COUNT(*) > 1
            """).query([.text(sessionId)]).map { row in
                DuplicateExactGroup(
                    checksum: row[0].textValue ?? "",
                    photoIds: (row[2].textValue ?? "").split(separator: ",").map(String.init)
                )
            }
    }

    /// 视觉聚类输入：similarity_hashes JOIN photos，按 photo_id 排序
    /// （组代表 hash 取组内首个成员，顺序是契约）。
    public func getOrderedVisualHashes(sessionId: String) throws -> [DuplicateVisualHashRow] {
        try connection.prepare("""
            SELECT sh.photo_id, sh.hash_hex
            FROM similarity_hashes sh
            JOIN photos p ON p.id = sh.photo_id
            WHERE p.session_id IN (?)
            ORDER BY sh.photo_id
            """).query([.text(sessionId)]).map { row in
                DuplicateVisualHashRow(
                    photoId: row[0].textValue ?? "",
                    hashHex: row[1].textValue ?? ""
                )
            }
    }

    /// TS: PRAGMA group_concat_limit = 0 —— GROUP_CONCAT 默认上限 1000；
    /// 大组必须完整拼接（读取已提升到事务外，同旧实现）。
    public func enableUnlimitedGroupConcat() throws {
        _ = try connection.exec("PRAGMA group_concat_limit = 0")
    }

    // MARK: - 扫描写

    /// checksum 回写（逐照片；语句只准备一次）。
    public func updateChecksums(_ rows: [DuplicateChecksumWrite]) throws {
        guard !rows.isEmpty else { return }
        let statement = try connection.prepare("""
            UPDATE photos
            SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
            WHERE id = ?
            """)
        for row in rows {
            _ = try statement.run([
                .text(row.checksum), .int(row.fileSize), .real(row.fileMtimeMs), .text(row.photoId),
            ])
        }
    }

    // MARK: - 重建事务（调用方开启事务）

    /// 读取该会话既有决策：photo_id → (is_kept, resolution)。会话隔离。
    public func getMemberDecisions(sessionId: String) throws -> [String: DuplicateMemberDecision] {
        let rows = try connection.prepare("""
            SELECT photo_id, is_kept, resolution
            FROM duplicate_group_members
            WHERE session_id IN (?)
            ORDER BY id
            """).query([.text(sessionId)])
        var decisions: [String: DuplicateMemberDecision] = [:]
        for row in rows {
            guard let photoId = row[0].textValue else { continue }
            decisions[photoId] = DuplicateMemberDecision(
                isKept: (row[1].intValue ?? 1) != 0,
                resolution: row[2].textValue
            )
        }
        return decisions
    }

    /// 重扫前清空该会话的成员/组行（先成员后组，与旧实现顺序一致）。
    public func deleteGroupsAndMembers(sessionId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM duplicate_group_members WHERE session_id IN (?)"
        ).run([.text(sessionId)])
        _ = try connection.prepare(
            "DELETE FROM duplicate_groups WHERE session_id IN (?)"
        ).run([.text(sessionId)])
    }

    /// 插入组行，按输入序返回自增 id（语句只准备一次）。
    public func insertGroups(_ groups: [DuplicateGroupInsert]) throws -> [Int] {
        guard !groups.isEmpty else { return [] }
        let statement = try connection.prepare(
            "INSERT INTO duplicate_groups (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at) VALUES (?, ?, ?, ?, ?, NULL, ?)"
        )
        var ids: [Int] = []
        ids.reserveCapacity(groups.count)
        for group in groups {
            _ = try statement.run([
                .text(group.sessionId), .text(group.groupType),
                group.checksum.map { DBValue.text($0) } ?? .null,
                group.hashHex.map { DBValue.text($0) } ?? .null,
                .int(Int64(group.memberCount)), .text(group.createdAt),
            ])
            ids.append(Int(connection.lastInsertRowid))
        }
        return ids
    }

    /// 插入成员行（语句只准备一次；顺序 = 调用方输入序）。
    public func insertMembers(_ members: [DuplicateMemberInsert]) throws {
        guard !members.isEmpty else { return }
        let statement = try connection.prepare(
            "INSERT INTO duplicate_group_members (group_id, photo_id, session_id, is_kept, file_size, file_mtime, resolution) VALUES (?, ?, ?, ?, ?, ?, ?)"
        )
        for member in members {
            _ = try statement.run([
                .int(Int64(member.groupId)), .text(member.photoId), .text(member.sessionId),
                .int(member.isKept ? 1 : 0),
                member.fileSize.map { DBValue.int($0) } ?? .null,
                member.fileMtime.map { DBValue.text($0) } ?? .null,
                member.resolution.map { DBValue.text($0) } ?? .null,
            ])
        }
    }

    /// 组级 resolution 批量写（仅成员全部已决且派生成功时调用）。
    public func setGroupResolutions(_ rows: [DuplicateGroupResolutionWrite]) throws {
        guard !rows.isEmpty else { return }
        let statement = try connection.prepare(
            "UPDATE duplicate_groups SET resolution = ? WHERE id = ?"
        )
        for row in rows {
            _ = try statement.run([.text(row.resolution), .int(Int64(row.groupId))])
        }
    }

    // MARK: - resolve 命令

    /// keep_all：全部成员保留并写同一 resolution（语句只准备一次）。
    public func setMembersKeptAll(_ memberIds: [Int], resolution: String) throws {
        guard !memberIds.isEmpty else { return }
        let statement = try connection.prepare(
            "UPDATE duplicate_group_members SET is_kept = 1, resolution = ? WHERE id = ?"
        )
        for memberId in memberIds {
            _ = try statement.run([.text(resolution), .int(Int64(memberId))])
        }
    }

    /// keep_one：按打分结果写保留位与 resolution（语句只准备一次）。
    public func setMemberKept(_ rows: [DuplicateMemberKeptWrite], resolution: String) throws {
        guard !rows.isEmpty else { return }
        let statement = try connection.prepare(
            "UPDATE duplicate_group_members SET is_kept = ?, resolution = ? WHERE id = ?"
        )
        for row in rows {
            _ = try statement.run([
                .int(row.isKept ? 1 : 0), .text(resolution), .int(Int64(row.memberId)),
            ])
        }
    }

    /// resolveMember：resolution 只在未定（NULL）时写（COALESCE 语义）。
    public func setMemberResolutionIfUnset(memberId: Int, isKept: Bool, resolution: String) throws {
        _ = try connection.prepare("""
            UPDATE duplicate_group_members
            SET is_kept = ?, resolution = COALESCE(resolution, ?)
            WHERE id = ?
            """).run([
                .int(isKept ? 1 : 0), .text(resolution), .int(Int64(memberId)),
            ])
    }

    /// resolveMember 的读回（UPDATE 之后取 photo_id；nil = 成员不存在）。
    public func getMemberPhotoId(memberId: Int) throws -> String? {
        try connection.prepare(
            "SELECT photo_id FROM duplicate_group_members WHERE id = ?"
        ).get([.int(Int64(memberId))])?[0].textValue
    }

    // MARK: - photos.status 三写者

    /// 决策落库（'removed' 的唯一写入点之一）：携带 is_kept=0 决策的成员照片
    /// 置为 'removed' = 排除出导出；未决/保留成员不触碰。
    public func markDiscarded(_ photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        let seen = Set(photoIds)
        let placeholders = seen.map { _ in "?" }.joined(separator: ",")
        _ = try connection.prepare("""
            UPDATE photos
            SET status = 'removed'
            WHERE id IN (\(placeholders))
              AND EXISTS (
                SELECT 1 FROM duplicate_group_members dgm
                WHERE dgm.photo_id = photos.id AND dgm.is_kept = 0
              )
            """).run(seen.map { .text($0) })
    }

    /// 组消失后的丢弃残影复位：仅当照片已无任何 is_kept=0 成员时，把本模块
    /// 写入的 'removed' 复位 'ready'；其他模块的 status（pending/missing）不动。
    public func restoreOrphanedRemoved(_ ids: [String]) throws {
        if ids.isEmpty { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        _ = try connection.prepare("""
            UPDATE photos
            SET status = 'ready'
            WHERE id IN (\(placeholders))
              AND status = 'removed'
              AND NOT EXISTS (
                SELECT 1 FROM duplicate_group_members dgm
                WHERE dgm.photo_id = photos.id AND dgm.is_kept = 0
              )
            """).run(ids.map { .text($0) })
    }

    /// recomputePhotoStatuses（TS 语义保留）—— 任一 is_kept=0 成员 → 'removed'
    /// （导出排除的唯一落库载体），否则 'ready'。本方法是 photos.status
    /// 'removed' 的唯一写者。
    public func recomputePhotoStatuses(_ photoIds: [String]) throws {
        if photoIds.isEmpty { return }
        var seen = Set<String>()
        let uniqueIds = photoIds.filter { seen.insert($0).inserted }
        let placeholders = uniqueIds.map { _ in "?" }.joined(separator: ",")
        _ = try connection.prepare("""
            UPDATE photos
            SET status = CASE
              WHEN EXISTS (
                SELECT 1
                FROM duplicate_group_members dgm
                WHERE dgm.photo_id = photos.id
                  AND dgm.is_kept = 0
              ) THEN 'removed'
              ELSE 'ready'
            END
            WHERE id IN (\(placeholders))
            """).run(uniqueIds.map { .text($0) })
    }
}

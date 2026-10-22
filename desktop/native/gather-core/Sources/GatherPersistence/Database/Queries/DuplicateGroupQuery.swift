// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/DuplicateGroupQuery.swift
// WP3b-3：duplicate_groups / duplicate_group_members 读模型下沉。
//
// 4 处 SELECT * 原样保留（SQL 文本与列序 = 旧 DuplicateService）：
//   1. getGroups(sessionId:)   SELECT * FROM duplicate_groups ... ORDER BY group_type, id
//   2. getGroups(ids:)         SELECT * FROM duplicate_groups ... ORDER BY id
//   3. getMembers(groupId:)    SELECT * FROM duplicate_group_members WHERE group_id = ?
//      （resolveGroup 的 keep_one 平局规则依赖自然行序，故不加 ORDER BY——与旧实现逐字一致）
//   4. getMembers(groupIds:)   SELECT dgm.*, p.filepath, p.filename ... ORDER BY dgm.id
// 任何列序调整都必须同步 DuplicateGroupRow / DuplicateMemberRow 的位置解码与
// docs/select-star baseline（Sources 6）。
import Foundation

public final class DuplicateGroupQuery {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// TS: getGroups —— duplicate.groups 命令；按 group_type, id 排序。
    public func getGroups(sessionId: String) throws -> [DuplicateGroupRow] {
        try connection.prepare("""
            SELECT * FROM duplicate_groups
            WHERE session_id = ?
            ORDER BY group_type, id
            """).query([.text(sessionId)]).map { DuplicateGroupRow(row: $0) }
    }

    /// TS: buildResult —— 按组 id 读取分组（按 id 排序）。
    public func getGroups(ids: [Int]) throws -> [DuplicateGroupRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try connection.prepare(
            "SELECT * FROM duplicate_groups WHERE id IN (\(placeholders)) ORDER BY id"
        ).query(ids.map { .int(Int64($0)) }).map { DuplicateGroupRow(row: $0) }
    }

    /// resolveGroup 的成员读取（SELECT *，无 ORDER BY，与旧实现逐字一致）。
    public func getMembers(groupId: Int) throws -> [DuplicateMemberRow] {
        try connection.prepare(
            "SELECT * FROM duplicate_group_members WHERE group_id = ?"
        ).query([.int(Int64(groupId))]).map { DuplicateMemberRow(row: $0) }
    }

    /// TS: duplicate_group_members JOIN photos（filepath/filename）按 dgm.id 排序。
    public func getMembers(groupIds: [Int]) throws -> [Int: [DuplicateGroupMemberDetail]] {
        guard !groupIds.isEmpty else { return [:] }
        let placeholders = groupIds.map { _ in "?" }.joined(separator: ",")
        let rows = try connection.prepare("""
            SELECT dgm.*, p.filepath, p.filename
            FROM duplicate_group_members dgm
            JOIN photos p ON p.id = dgm.photo_id
            WHERE dgm.group_id IN (\(placeholders))
            ORDER BY dgm.id
            """).query(groupIds.map { .int(Int64($0)) })
        var memberMap: [Int: [DuplicateGroupMemberDetail]] = [:]
        for row in rows {
            let detail = DuplicateGroupMemberDetail(row: row)
            memberMap[detail.member.groupId, default: []].append(detail)
        }
        return memberMap
    }

    /// 组级 resolution 派生用的成员状态（is_kept, resolution）。
    public func getMemberStates(groupId: Int) throws -> [DuplicateMemberState] {
        try connection.prepare(
            "SELECT is_kept, resolution FROM duplicate_group_members WHERE group_id = ? ORDER BY id"
        ).query([.int(Int64(groupId))]).map { row in
            DuplicateMemberState(
                isKept: (row[0].intValue ?? 1) != 0,
                resolution: row[1].textValue
            )
        }
    }
}

// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/LibraryPackageStore.swift
// Wave3（task-24）：可移植目录包的库侧读写原子。
//
// 边界：本文件只做 SQL（导出投影 + 导入去重查询 + 显式 id 的照片行写入）；
// 包的文件格式、冲突策略、路径重绑定与报告都由 GatherApplication 的
// LibraryPackageService 负责（Application 不得持 SQL —— services_prepare 预算 = 0）。
//
// 不改 schema：导出/导入全部落在既有 photos / photo_metadata_cache /
// culling_decisions / collections / collection_items 上。
import Foundation
import GatherProtocol

/// 导出投影行（photos + photo_metadata_cache + culling_decisions）。
public struct LibraryPackageExportRow: Equatable, Sendable {
    public let photoId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let status: String
    public let fileSize: Int64
    public let fileMtimeMs: Double
    /// 已淘汰移出的照片（archived_at 非空）——默认不进包。
    public let archivedAt: String?
    public let rating: Int?
    public let label: String?
    public let decision: String?
    public let keywordsJSON: String
    public let descriptiveJSON: String

    public init(
        photoId: String,
        filepath: String,
        filename: String,
        checksum: String,
        status: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        archivedAt: String?,
        rating: Int?,
        label: String?,
        decision: String?,
        keywordsJSON: String,
        descriptiveJSON: String
    ) {
        self.photoId = photoId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.status = status
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
        self.archivedAt = archivedAt
        self.rating = rating
        self.label = label
        self.decision = decision
        self.keywordsJSON = keywordsJSON
        self.descriptiveJSON = descriptiveJSON
    }
}

/// 库内已存在的同内容照片（checksum 去重用）。
public struct LibraryPackageChecksumOwner: Equatable, Sendable {
    public let checksum: String
    public let photoId: String
    public let sessionId: String
    public let filepath: String

    public init(checksum: String, photoId: String, sessionId: String, filepath: String) {
        self.checksum = checksum
        self.photoId = photoId
        self.sessionId = sessionId
        self.filepath = filepath
    }
}

public struct LibraryPackageStore: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 导出读

    /// 工作区照片的导出投影（默认排除已移出工作区的照片）。
    ///
    /// rating/label 的唯一真相源是 photo_metadata_cache（culling_decisions 的
    /// rating/color_label 是镜像列，读取它会与真实值漂移——见 CullingDecisionRepo 文件头）。
    public func exportRows(
        sessionId: String, includeArchived: Bool
    ) throws -> [LibraryPackageExportRow] {
        let archivedClause = includeArchived
            ? ""
            : "AND \(PhotoVisibility.visiblePredicate(alias: "p"))"
        let rows = try connection.prepare("""
            SELECT p.id, p.filepath, p.filename, p.checksum, p.status,
                   p.checksum_file_size, p.checksum_file_mtime_ms, p.archived_at,
                   pmc.rating, pmc.label, pmc.keywords, pmc.iptc_json, cd.decision
              FROM photos p
              LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
              LEFT JOIN culling_decisions cd
                     ON cd.photo_id = p.id AND cd.session_id = p.session_id
             WHERE p.session_id = ? \(archivedClause)
             ORDER BY p.rowid
            """).query([.text(sessionId)])
        return rows.map { row in
            LibraryPackageExportRow(
                photoId: row[0].textValue ?? "",
                filepath: row[1].textValue ?? "",
                filename: row[2].textValue ?? "",
                checksum: row[3].textValue ?? "",
                status: row[4].textValue ?? "",
                fileSize: row[5].intValue ?? 0,
                fileMtimeMs: row[6].doubleValue ?? 0,
                archivedAt: row[7].textValue,
                rating: row[8].intValue.map(Int.init),
                label: row[9].textValue,
                decision: row[12].textValue,
                keywordsJSON: row[10].textValue ?? "[]",
                descriptiveJSON: row[11].textValue ?? "{}"
            )
        }
    }

    /// 归档（已移出工作区）张数：导出报告用（includeArchived=false 时告知用户少了多少）。
    public func archivedCount(sessionId: String) throws -> Int {
        let row = try connection.prepare(
            "SELECT COUNT(*) FROM photos WHERE session_id = ? AND "
                + PhotoVisibility.archivedPredicate(alias: "")
        ).get([.text(sessionId)])
        return Int(row?[0].intValue ?? 0)
    }

    // MARK: - 导入去重查询

    /// 库内已存在的 photoId（分块 IN，避免 SQLite 变量上限）。
    public func existingPhotoIDs(_ photoIds: [String]) throws -> Set<String> {
        let unique = Self.unique(photoIds)
        guard !unique.isEmpty else { return [] }
        var found = Set<String>()
        for chunk in unique.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare(
                "SELECT id FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map(DBValue.text))
            for row in rows {
                if let id = row[0].textValue { found.insert(id) }
            }
        }
        return found
    }

    /// 某照片行所属会话（keepImported 回绑时，photo_metadata_cache/决策必须
    /// 写回**原会话**，否则按 session_id join 的读面会与该行对不上）。
    public func sessionIdOfPhoto(_ photoId: String) throws -> String? {
        try connection.prepare(
            "SELECT session_id FROM photos WHERE id = ?"
        ).get([.text(photoId)])?[0].textValue
    }

    /// 库内已存在的校验和（空 checksum 不参与）。
    public func checksumOwners(_ checksums: [String]) throws -> [LibraryPackageChecksumOwner] {
        let unique = Self.unique(checksums.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return [] }
        var owners: [LibraryPackageChecksumOwner] = []
        for chunk in unique.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT checksum, id, session_id, filepath FROM photos
                 WHERE checksum IN (\(placeholders))
                 ORDER BY rowid
                """).query(chunk.map(DBValue.text))
            for row in rows {
                owners.append(LibraryPackageChecksumOwner(
                    checksum: row[0].textValue ?? "",
                    photoId: row[1].textValue ?? "",
                    sessionId: row[2].textValue ?? "",
                    filepath: row[3].textValue ?? ""
                ))
            }
        }
        return owners
    }

    // MARK: - 导入写

    /// 用**显式 photoId** 写入一条照片行（包内 id 在目标库里空闲时保留，便于集合成员直接映射）。
    ///
    /// 返回 false = id 已存在（调用方按冲突策略处理），不覆盖任何现有行。
    @discardableResult
    public func insertImportedPhoto(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        status: String
    ) throws -> Bool {
        let now = nowISOString()
        let changes = try connection.prepare("""
            INSERT INTO photos
              (id, session_id, filepath, filename, checksum,
               checksum_file_size, checksum_file_mtime_ms, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """).run([
                .text(id), .text(sessionId), .text(filepath), .text(filename),
                .text(checksum), .int(fileSize), .real(fileMtimeMs),
                .text(status), .text(now), .text(now),
            ])
        return changes > 0
    }

    /// keepImported：把同一 photoId 的本地行改写成包里的路径/校验和（保留 id 与集合成员关系）。
    @discardableResult
    public func rebindImportedPhoto(
        photoId: String,
        filepath: String,
        filename: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double
    ) throws -> Bool {
        let changes = try connection.prepare("""
            UPDATE photos
               SET filepath = ?, filename = ?, checksum = ?,
                   checksum_file_size = ?, checksum_file_mtime_ms = ?, updated_at = ?
             WHERE id = ?
            """).run([
                .text(filepath), .text(filename), .text(checksum),
                .int(fileSize), .real(fileMtimeMs), .text(nowISOString()),
                .text(photoId),
            ])
        return changes > 0
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
// MARK: - 外部 sidecar 迁移的读投影（Wave3 / task-24）

/// 迁移候选（photos + photo_metadata_cache 的本地现值）。
public struct ExternalMigrationCandidateRow: Equatable, Sendable {
    public let photoId: String
    public let filepath: String
    public let rating: Int64
    public let label: String?
    public let keywordsJSON: String

    public init(
        photoId: String, filepath: String, rating: Int64, label: String?, keywordsJSON: String
    ) {
        self.photoId = photoId
        self.filepath = filepath
        self.rating = rating
        self.label = label
        self.keywordsJSON = keywordsJSON
    }
}

public extension LibraryPackageStore {
    /// 某工作区照片的迁移候选（本地 rating/label/keywords 现值；一次读全，供异步读 XMP）。
    func migrationCandidates(sessionId: String) throws -> [ExternalMigrationCandidateRow] {
        let rows = try connection.prepare("""
            SELECT p.id, p.filepath, COALESCE(pmc.rating, 0), pmc.label, COALESCE(pmc.keywords, '[]')
              FROM photos p
              LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
             WHERE p.session_id = ? AND \(PhotoVisibility.visiblePredicate(alias: "p"))
             ORDER BY p.rowid
            """).query([.text(sessionId)])
        return rows.map { row in
            ExternalMigrationCandidateRow(
                photoId: row[0].textValue ?? "",
                filepath: row[1].textValue ?? "",
                rating: row[2].intValue ?? 0,
                label: row[3].textValue,
                keywordsJSON: row[4].textValue ?? "[]"
            )
        }
    }
}

// MARK: - Wave5（Batch3 / task-20）：组织资产导出投影（显式列，不 SELECT *）

/// 人物-照片绑定导出行（person_photos JOIN persons；只取可移植列）。
public struct LibraryPackagePersonBindingRow: Equatable, Sendable {
    public let photoId: String
    public let personId: String
    public let personName: String
    public let confidence: Double

    public init(photoId: String, personId: String, personName: String, confidence: Double) {
        self.photoId = photoId
        self.personId = personId
        self.personName = personName
        self.confidence = confidence
    }
}

/// 重复组导出行（duplicate_groups 显式列 0-7）。
public struct LibraryPackageDuplicateGroupRow: Equatable, Sendable {
    public let id: Int64
    public let groupType: String
    public let checksum: String?
    public let hashHex: String?
    public let resolution: String?

    public init(id: Int64, groupType: String, checksum: String?, hashHex: String?, resolution: String?) {
        self.id = id
        self.groupType = groupType
        self.checksum = checksum
        self.hashHex = hashHex
        self.resolution = resolution
    }
}

/// 重复组成员导出行（duplicate_group_members 显式列 0-7 的可移植子集）。
public struct LibraryPackageDuplicateMemberRow: Equatable, Sendable {
    public let groupId: Int64
    public let photoId: String
    public let isKept: Bool
    public let resolution: String?

    public init(groupId: Int64, photoId: String, isKept: Bool, resolution: String?) {
        self.groupId = groupId
        self.photoId = photoId
        self.isKept = isKept
        self.resolution = resolution
    }
}

public extension LibraryPackageStore {
    /// 某工作区的人物-照片绑定（person_photos 显式列 + persons.name）。
    ///
    /// 只返回仍在工作区（PhotoVisibility）的照片绑定：已淘汰/移出的照片不进包。
    func personBindingRows(sessionId: String) throws -> [LibraryPackagePersonBindingRow] {
        let rows = try connection.prepare("""
            SELECT pp.photo_id, pp.person_id, COALESCE(pr.name, ''), pp.confidence
              FROM person_photos pp
              JOIN persons pr ON pr.id = pp.person_id
              JOIN photos p ON p.id = pp.photo_id AND \(PhotoVisibility.visiblePredicate(alias: "p"))
             WHERE pp.session_id = ?
             ORDER BY pp.person_id, pp.photo_id
            """).query([.text(sessionId)])
        return rows.map { row in
            LibraryPackagePersonBindingRow(
                photoId: row[0].textValue ?? "",
                personId: row[1].textValue ?? "",
                personName: row[2].textValue ?? "",
                confidence: row[3].doubleValue ?? 0
            )
        }
    }

    /// 某工作区的重复组（duplicate_groups 显式列：id/session_id/group_type/checksum/hash_hex/member_count/resolution/created_at）。
    func duplicateGroupRows(sessionId: String) throws -> [LibraryPackageDuplicateGroupRow] {
        let rows = try connection.prepare("""
            SELECT id, session_id, group_type, checksum, hash_hex, member_count, resolution, created_at
              FROM duplicate_groups
             WHERE session_id = ?
             ORDER BY id
            """).query([.text(sessionId)])
        return rows.map { row in
            LibraryPackageDuplicateGroupRow(
                id: row[0].intValue ?? 0,
                groupType: row[2].textValue ?? "",
                checksum: row[3].textValue,
                hashHex: row[4].textValue,
                resolution: row[6].textValue
            )
        }
    }

    /// 重复组成员（duplicate_group_members 显式列 + photos 可见性过滤）。
    /// 列：id(0), group_id(1), photo_id(2), session_id(3), is_kept(4), file_size(5),
    /// file_mtime(6), resolution(7)。
    func duplicateGroupMemberRows(sessionId: String) throws -> [LibraryPackageDuplicateMemberRow] {
        let rows = try connection.prepare("""
            SELECT dm.id, dm.group_id, dm.photo_id, dm.session_id, dm.is_kept,
                   dm.file_size, dm.file_mtime, dm.resolution
              FROM duplicate_group_members dm
              JOIN duplicate_groups dg ON dg.id = dm.group_id
              JOIN photos p ON p.id = dm.photo_id AND \(PhotoVisibility.visiblePredicate(alias: "p"))
             WHERE dg.session_id = ?
             ORDER BY dm.group_id, dm.id
            """).query([.text(sessionId)])
        return rows.map { row in
            LibraryPackageDuplicateMemberRow(
                groupId: row[1].intValue ?? 0,
                photoId: row[2].textValue ?? "",
                isKept: (row[4].intValue ?? 0) != 0,
                resolution: row[7].textValue
            )
        }
    }
}

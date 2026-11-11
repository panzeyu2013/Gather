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
        let archivedClause = includeArchived ? "" : "AND p.archived_at IS NULL"
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
            "SELECT COUNT(*) FROM photos WHERE session_id = ? AND archived_at IS NOT NULL"
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
             WHERE p.session_id = ? AND p.archived_at IS NULL
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

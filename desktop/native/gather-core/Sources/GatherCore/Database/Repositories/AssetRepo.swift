// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/AssetRepo.swift
// TS 源: desktop/src/main/db/repositories/asset.repo.ts
// 偏差：TS 侧 node:path/node:fs 语义用 TSPath/tsStat/tsExists 复刻；预编译语句不再
// 在构造期 hoist，改为方法内 prepare（DB 层无自动缓存，语义等价、测试可读性优先）。

import Foundation

/// asset_files 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct AssetFileRow {
    public let id: String
    public let volumeId: String
    public let fileIdentity: String
    public let normalizedPath: String
    public let filename: String
    public let fileExtension: String
    public let mediaType: String
    public let fileSize: Int64
    public let fileMtimeMs: Double
    public let checksum: String
    public let onlineStatus: String
    public let lastSeenAt: String
    public let createdAt: String
    public let updatedAt: String

    public init(row: DBRow) {
        id = row[0].textValue ?? ""
        volumeId = row[1].textValue ?? ""
        fileIdentity = row[2].textValue ?? ""
        normalizedPath = row[3].textValue ?? ""
        filename = row[4].textValue ?? ""
        fileExtension = row[5].textValue ?? ""
        mediaType = row[6].textValue ?? ""
        fileSize = row[7].intValue ?? 0
        fileMtimeMs = row[8].doubleValue ?? 0
        checksum = row[9].textValue ?? ""
        onlineStatus = row[10].textValue ?? ""
        lastSeenAt = row[11].textValue ?? ""
        createdAt = row[12].textValue ?? ""
        updatedAt = row[13].textValue ?? ""
    }
}

/// 轻量引用（SELECT id, normalized_path）。
public struct AssetFileRefRow {
    public let id: String
    public let normalizedPath: String
}

/// 回填扫描的照片行（SELECT rowid AS migration_rowid, *）。
public struct PhotoBackfillRow {
    public let migrationRowid: Int64
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let status: String

    public init(row: DBRow) {
        migrationRowid = row[0].intValue ?? 0
        id = row[1].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        filepath = row[3].textValue ?? ""
        filename = row[4].textValue ?? ""
        checksum = row[5].textValue ?? ""
        status = row[8].textValue ?? ""
    }
}

/// asset_backfill_state 的 last_photo_rowid 投影。
public struct BackfillStateRow {
    public let lastPhotoRowid: Int64
}

/// 链接候选行（listCandidates 的 SELECT 列清单）。
public struct LinkCandidateRow {
    public let id: String
    public let leftFileId: String
    public let rightFileId: String
    public let confidence: Double
    public let evidenceJSON: String
    public let status: String
    public let leftPath: String
    public let rightPath: String
}

/// reconcileRawJpegLinks 的 SELECT 列清单。
public struct ReconcileCandidateRow {
    public let id: String
    public let leftFileId: String
    public let rightFileId: String
    public let status: String
    public let leftDate: String?
    public let rightDate: String?
    public let leftCamera: String?
    public let rightCamera: String?
    public let leftCandidateCount: Int64
    public let rightCandidateCount: Int64
}

/// listVolumes 的 SELECT 列清单。
public struct AssetFileVolumeRow {
    public let volumeId: String
    public let normalizedPath: String
    public let onlineStatus: String
}

/// session_assets 行（mergeFileAssets 的 SELECT 列清单）。
public struct SessionAssetRow {
    public let sessionId: String
    public let displayFileId: String?
    public let importOrder: Int64
    public let addedAt: String
}

/// sidecar_metadata_state 投影。
public struct SidecarStateRow {
    public let rating: Int64?
    public let label: String?
    public let keywords: String
    public let fingerprint: String
}

/// 候选轻量行（getCandidate）。
public struct CandidateLiteRow {
    public let leftFileId: String
    public let rightFileId: String
    public let status: String
}

/// createRawJpegCandidates 的文件行（extension 为 Swift 关键字，命名改为 fileExtension）。
public struct RawJpegFileRow {
    public let id: String
    public let filename: String
    public let normalizedPath: String
    public let fileExtension: String
}

/// backfillSession 的结果。
public struct BackfillResult {
    public let migrated: Int64
    public let offline: Int64
    public let candidates: Int64
}

/// relinkMovedFile 的结果。
public struct RelinkMovedFileResult {
    public let fileId: String
    public let photoIds: [String]
}

/// 资产仓库（TS AssetRepository）。
public final class AssetRepo {
    private let connection: DBConnection
    private var metadataRelocationSink: ((String) -> Void)?

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func setMetadataRelocationSink(_ sink: @escaping (String) -> Void) {
        metadataRelocationSink = sink
    }

    // ─────────────────────────── 回填 ───────────────────────────

    public func backfillSession(_ sessionId: String) throws -> BackfillResult {
        var migrated: Int64 = 0
        var offline: Int64 = 0
        let total = Int64((try connection.prepare(
            "SELECT COUNT(*) AS count FROM photos WHERE session_id = ?"
        ).get([.text(sessionId)])?[0].intValue) ?? 0)
        let state = try connection.prepare(
            "SELECT last_photo_rowid FROM asset_backfill_state WHERE session_id = ?"
        ).get([.text(sessionId)])
        var cursor = state?[0].intValue ?? 0
        _ = try connection.prepare("""
            INSERT INTO asset_backfill_state (
              session_id, last_photo_rowid, total_photos, status, updated_at
            ) VALUES (?, ?, ?, 'running', ?)
            ON CONFLICT(session_id) DO UPDATE SET
              total_photos = excluded.total_photos,
              status = 'running',
              updated_at = excluded.updated_at
          """).run([.text(sessionId), .int(cursor), .int(total), .text(nowISOString())])

        do {
            while true {
                let photos = try connection.prepare("""
                    SELECT rowid AS migration_rowid, *
                    FROM photos
                    WHERE session_id = ? AND rowid > ?
                      AND (asset_id IS NULL OR asset_file_id IS NULL)
                    ORDER BY rowid
                    LIMIT 250
                  """).query([.text(sessionId), .int(cursor)]).map { PhotoBackfillRow(row: $0) }
                if photos.isEmpty && cursor > 0 {
                    let remaining = Int64((try connection.prepare("""
                        SELECT COUNT(*) AS count
                        FROM photos
                        WHERE session_id = ? AND (asset_id IS NULL OR asset_file_id IS NULL)
                      """).get([.text(sessionId)])?[0].intValue) ?? 0)
                    if remaining > 0 {
                        cursor = 0
                        continue
                    }
                }
                if photos.isEmpty { break }
                var batchMigrated: Int64 = 0
                var batchOffline: Int64 = 0
                try connection.transaction {
                    for photo in photos {
                        let result = try ensurePhoto(sessionId: sessionId, photo: photo)
                        batchMigrated += result.migrated
                        batchOffline += result.offline
                        cursor = photo.migrationRowid
                    }
                    _ = try connection.prepare("""
                        UPDATE asset_backfill_state
                        SET last_photo_rowid = ?, migrated_photos = migrated_photos + ?,
                            offline_files = offline_files + ?, updated_at = ?
                        WHERE session_id = ?
                      """).run([
                        .int(cursor), .int(batchMigrated), .int(batchOffline),
                        .text(nowISOString()), .text(sessionId),
                    ])
                }
                migrated += batchMigrated
                offline += batchOffline
            }
        } catch {
            _ = try? connection.prepare(
                "UPDATE asset_backfill_state SET status = 'failed', updated_at = ? WHERE session_id = ?"
            ).run([.text(nowISOString()), .text(sessionId)])
            throw error
        }
        let candidates = try createRawJpegCandidates(sessionId)
        _ = try connection.prepare("""
            UPDATE asset_backfill_state
            SET candidate_links = candidate_links + ?, status = 'completed', updated_at = ?
            WHERE session_id = ?
          """).run([.int(candidates), .text(nowISOString()), .text(sessionId)])
        return BackfillResult(migrated: migrated, offline: offline, candidates: candidates)
    }

    // ─────────────────────────── 候选 ───────────────────────────

    public func listCandidates(sessionId: String? = nil) throws -> [AssetLinkCandidateData] {
        let sessionClause = sessionId.map { _ in
            """
            AND EXISTS (
                SELECT 1
                FROM asset_members am
                JOIN session_assets sa ON sa.asset_id = am.asset_id
                WHERE am.file_id IN (c.left_file_id, c.right_file_id)
                  AND sa.session_id = ?
              )
            """
        } ?? ""
        let values: [DBValue?] = sessionId.map { [.text($0)] } ?? []
        let rows = try connection.prepare("""
            SELECT c.id, c.left_file_id, c.right_file_id, c.confidence,
              c.evidence_json, c.status, lf.normalized_path AS left_path,
              rf.normalized_path AS right_path
            FROM asset_link_candidates c
            JOIN asset_files lf ON lf.id = c.left_file_id
            JOIN asset_files rf ON rf.id = c.right_file_id
            WHERE c.relation_type = 'raw_jpeg' \(sessionClause)
            ORDER BY
              CASE c.status WHEN 'pending' THEN 0 WHEN 'accepted' THEN 1 ELSE 2 END,
              c.updated_at DESC
          """).query(values)
        return rows.map { row in
            let candidate = LinkCandidateRow(
                id: row[0].textValue ?? "",
                leftFileId: row[1].textValue ?? "",
                rightFileId: row[2].textValue ?? "",
                confidence: row[3].doubleValue ?? 0,
                evidenceJSON: row[4].textValue ?? "{}",
                status: row[5].textValue ?? "",
                leftPath: row[6].textValue ?? "",
                rightPath: row[7].textValue ?? ""
            )
            let parsed = (try? JSONValue.parse(candidate.evidenceJSON)) ?? JSONValue.object([:])
            let evidence: [String: JSONValue] = {
                if case .object(let dict) = parsed { return dict }
                return [:]
            }()
            return AssetLinkCandidateData(
                id: candidate.id,
                leftFileId: candidate.leftFileId,
                rightFileId: candidate.rightFileId,
                leftPath: candidate.leftPath,
                rightPath: candidate.rightPath,
                confidence: candidate.confidence,
                status: AssetLinkCandidateStatus(rawValue: candidate.status) ?? .pending,
                evidence: evidence
            )
        }
    }

    public func listVolumes() throws -> [AssetVolumeData] {
        let rows = try connection.prepare("""
            SELECT volume_id, normalized_path, online_status
            FROM asset_files ORDER BY volume_id, normalized_path
          """).query().map { row in
            AssetFileVolumeRow(
                volumeId: row[0].textValue ?? "",
                normalizedPath: row[1].textValue ?? "",
                onlineStatus: row[2].textValue ?? ""
            )
        }
        var volumes: [String: AssetVolumeData] = [:]
        for row in rows {
            let root: String
            if row.normalizedPath.hasPrefix("/Volumes/") {
                let components = row.normalizedPath.split(separator: "/")
                root = "/" + components.prefix(2).joined(separator: "/")
            } else {
                root = TSPath.root(row.normalizedPath)
            }
            var volume = volumes[row.volumeId] ?? AssetVolumeData(
                volumeId: row.volumeId,
                roots: [],
                onlineFiles: 0,
                offlineFiles: 0
            )
            if !volume.roots.contains(root) { volume.roots.append(root) }
            if row.onlineStatus == "online" { volume.onlineFiles += 1 }
            else { volume.offlineFiles += 1 }
            volumes[row.volumeId] = volume
        }
        return Array(volumes.values)
    }

    // ─────────────────────────── 重链接 ───────────────────────────

    public func relinkRoot(oldRoot: String, newRoot: String) throws -> Int {
        let resolvedOld = TSPath.resolve(oldRoot)
        let resolvedNew = TSPath.resolve(newRoot)
        let escaped = resolvedOld.map { ch -> String in
            if ch == "\\" || ch == "%" || ch == "_" { return "\\\(ch)" }
            return String(ch)
        }.joined()
        let rows = try connection.prepare("""
            SELECT id, normalized_path FROM asset_files
            WHERE normalized_path = ? OR normalized_path LIKE ? ESCAPE '\\'
          """).query([.text(resolvedOld), .text("\(escaped)\(TSPath.separator)%")])

        var changes: [(id: String, oldPath: String, newPath: String, volumeId: String, fileIdentity: String)] = []
        for row in rows {
            let id = row[0].textValue ?? ""
            let normalizedPath = row[1].textValue ?? ""
            let relativePath = TSPath.relative(resolvedOld, to: normalizedPath)
            if relativePath.hasPrefix("..") || TSPath.isAbsolute(relativePath) { continue }
            let newPath = TSPath.join([resolvedNew, relativePath])
            guard let info = tsStat(newPath), info.isFile else { continue }
            changes.append((
                id: id,
                oldPath: normalizedPath,
                newPath: newPath,
                volumeId: "dev:\(info.dev)",
                fileIdentity: String(info.ino)
            ))
        }

        let timestamp = nowISOString()
        var relocatedOutboxPaths: [String] = []
        try connection.transaction {
            let affectedSessions: [String]
            if changes.isEmpty {
                affectedSessions = []
            } else {
                let placeholders = changes.map { _ in "?" }.joined(separator: ",")
                let rows = try connection.prepare("""
                    SELECT DISTINCT session_id
                    FROM photos
                    WHERE asset_file_id IN (\(placeholders))
                  """).query(changes.map { .text($0.id) })
                affectedSessions = rows.compactMap { $0[0].textValue }
            }
            for change in changes {
                if let relocated = try relocateMetadataState(
                    oldPhotoPath: change.oldPath,
                    newPhotoPath: change.newPath,
                    timestamp: timestamp
                ) {
                    relocatedOutboxPaths.append(relocated)
                }
                _ = try connection.prepare("""
                    UPDATE asset_files
                    SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?,
                        online_status = 'online', last_seen_at = ?, updated_at = ?
                    WHERE id = ?
                  """).run([
                    .text(change.volumeId), .text(change.fileIdentity), .text(change.newPath),
                    .text(TSPath.basename(change.newPath)), .text(timestamp), .text(timestamp),
                    .text(change.id),
                ])
                _ = try connection.prepare("""
                    UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                    WHERE asset_file_id = ?
                  """).run([
                    .text(change.newPath), .text(TSPath.basename(change.newPath)),
                    .text(timestamp), .text(change.id),
                ])
                try relocateSidecarBinding(
                    oldPhotoPath: change.oldPath,
                    newPhotoPath: change.newPath,
                    timestamp: timestamp
                )
            }
            for sessionId in affectedSessions {
                let session = try connection.prepare("SELECT source_path FROM sessions WHERE id = ?")
                    .get([.text(sessionId)])
                let sourcePath = session?[0].textValue ?? ""
                if !sourcePath.isEmpty {
                    let resolvedSourcePath = TSPath.resolve(sourcePath)
                    let relativeSourcePath = TSPath.relative(resolvedOld, to: resolvedSourcePath)
                    if relativeSourcePath == "" ||
                        (!relativeSourcePath.hasPrefix("..") && !TSPath.isAbsolute(relativeSourcePath)) {
                        _ = try connection.prepare(
                            "UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?"
                        ).run([
                            .text(TSPath.join([resolvedNew, relativeSourcePath])),
                            .text(timestamp), .text(sessionId),
                        ])
                    }
                }
                _ = try connection.prepare("DELETE FROM similarity_results WHERE session_id = ?")
                    .run([.text(sessionId)])
                _ = try connection.prepare(
                    "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'"
                ).run([.text(sessionId)])
                _ = try connection.prepare(
                    "UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?"
                ).run([.text(timestamp), .text(sessionId)])
            }
        }
        relocatedOutboxPaths.forEach { metadataRelocationSink?($0) }
        return changes.count
    }

    public func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String = ""
    ) throws -> RelinkMovedFileResult? {
        let resolvedPath = TSPath.resolve(newPath)
        guard let info = tsStat(resolvedPath) else { return nil }
        let volumeId = "dev:\(info.dev)"

        let identityMatch: AssetFileRefRow?
        if !fileIdentity.isEmpty {
            identityMatch = try connection.prepare("""
                SELECT id, normalized_path FROM asset_files
                WHERE volume_id = ? AND file_identity = ? AND normalized_path <> ?
                LIMIT 1
              """).get([.text(volumeId), .text(fileIdentity), .text(resolvedPath)]).map { row in
                AssetFileRefRow(id: row[0].textValue ?? "", normalizedPath: row[1].textValue ?? "")
            }
        } else {
            identityMatch = nil
        }
        if checksum.isEmpty && identityMatch == nil { return nil }

        var checksumMatches: [AssetFileRefRow] = []
        if !checksum.isEmpty {
            let rows = try connection.prepare("""
                SELECT id, normalized_path
                FROM asset_files
                WHERE checksum = ? AND file_size = ? AND normalized_path <> ?
                ORDER BY id
              """).query([.text(checksum), .int(fileSize), .text(resolvedPath)])
            checksumMatches = rows
                .map { AssetFileRefRow(id: $0[0].textValue ?? "", normalizedPath: $0[1].textValue ?? "") }
                .filter { !tsExists($0.normalizedPath) }
            if checksumMatches.count > 2 { checksumMatches = Array(checksumMatches.prefix(2)) }
        }
        guard let match = identityMatch ?? (checksumMatches.count == 1 ? checksumMatches[0] : nil) else {
            return nil
        }
        let photoIds = try connection.prepare(
            "SELECT id FROM photos WHERE asset_file_id = ? ORDER BY id"
        ).query([.text(match.id)]).compactMap { $0[0].textValue }

        let timestamp = nowISOString()
        var relocatedOutboxPath: String?
        try connection.transaction {
            relocatedOutboxPath = try relocateMetadataState(
                oldPhotoPath: match.normalizedPath,
                newPhotoPath: resolvedPath,
                timestamp: timestamp
            )
            _ = try connection.prepare("""
                UPDATE asset_files
                SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?, extension = ?,
                    file_size = ?, file_mtime_ms = ?, online_status = 'online',
                    last_seen_at = ?, updated_at = ?
                WHERE id = ?
              """).run([
                .text(volumeId), .text(fileIdentity), .text(resolvedPath),
                .text(TSPath.basename(resolvedPath)), .text(TSPath.extname(resolvedPath).lowercased()),
                .int(fileSize), .real(fileMtimeMs), .text(timestamp), .text(timestamp),
                .text(match.id),
            ])
            _ = try connection.prepare("""
                UPDATE photos
                SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                WHERE asset_file_id = ?
              """).run([
                .text(resolvedPath), .text(TSPath.basename(resolvedPath)), .text(timestamp),
                .text(match.id),
            ])
            try relocateSidecarBinding(
                oldPhotoPath: match.normalizedPath,
                newPhotoPath: resolvedPath,
                timestamp: timestamp
            )
        }
        if let relocatedOutboxPath { metadataRelocationSink?(relocatedOutboxPath) }
        return RelinkMovedFileResult(fileId: match.id, photoIds: photoIds)
    }

    public func acceptCandidate(_ candidateId: String) throws {
        guard let candidate = try getCandidate(candidateId) else {
            throw DBError.message("ASSET_LINK_CANDIDATE_NOT_FOUND")
        }
        try connection.transaction {
            try mergeFileAssets(primaryFileId: candidate.leftFileId, secondaryFileId: candidate.rightFileId)
            _ = try connection.prepare("""
                UPDATE asset_link_candidates
                SET status = 'accepted', updated_at = ?
                WHERE id = ?
              """).run([.text(nowISOString()), .text(candidateId)])
        }
    }

    public func rejectCandidate(_ candidateId: String) throws {
        guard let candidate = try getCandidate(candidateId) else {
            throw DBError.message("ASSET_LINK_CANDIDATE_NOT_FOUND")
        }
        try connection.transaction {
            if candidate.status == "accepted" {
                try splitFileAsset(candidate.rightFileId)
            }
            _ = try connection.prepare("""
                UPDATE asset_link_candidates
                SET status = 'rejected', updated_at = ?
                WHERE id = ?
              """).run([.text(nowISOString()), .text(candidateId)])
        }
    }

    public func reconcileRawJpegLinks(_ sessionId: String) throws -> Int64 {
        let candidates = try connection.prepare("""
            SELECT c.id, c.left_file_id, c.right_file_id, c.status,
              lpmc.date_taken AS left_date, rpmc.date_taken AS right_date,
              lpmc.camera_model AS left_camera, rpmc.camera_model AS right_camera,
              (
                SELECT COUNT(*) FROM asset_link_candidates related
                WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
                  AND (related.left_file_id = c.left_file_id OR related.right_file_id = c.left_file_id)
              ) AS left_candidate_count,
              (
                SELECT COUNT(*) FROM asset_link_candidates related
                WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
                  AND (related.left_file_id = c.right_file_id OR related.right_file_id = c.right_file_id)
              ) AS right_candidate_count
            FROM asset_link_candidates c
            JOIN asset_files lf ON lf.id = c.left_file_id
            JOIN asset_files rf ON rf.id = c.right_file_id
            LEFT JOIN photos lp ON lp.asset_file_id = lf.id AND lp.session_id = ?
            LEFT JOIN photos rp ON rp.asset_file_id = rf.id AND rp.session_id = ?
            LEFT JOIN photo_metadata_cache lpmc ON lpmc.photo_id = lp.id
            LEFT JOIN photo_metadata_cache rpmc ON rpmc.photo_id = rp.id
            WHERE c.relation_type = 'raw_jpeg' AND c.status = 'pending'
            GROUP BY c.id
          """).query([.text(sessionId), .text(sessionId)]).map { row in
            ReconcileCandidateRow(
                id: row[0].textValue ?? "",
                leftFileId: row[1].textValue ?? "",
                rightFileId: row[2].textValue ?? "",
                status: row[3].textValue ?? "",
                leftDate: row[4].textValue,
                rightDate: row[5].textValue,
                leftCamera: row[6].textValue,
                rightCamera: row[7].textValue,
                leftCandidateCount: row[8].intValue ?? 0,
                rightCandidateCount: row[9].intValue ?? 0
            )
        }

        var merged: Int64 = 0
        try connection.transaction {
            for candidate in candidates {
                let leftTime = candidate.leftDate.flatMap { tsDateParse($0) } ?? .nan
                let rightTime = candidate.rightDate.flatMap { tsDateParse($0) } ?? .nan
                let leftCamera = candidate.leftCamera?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rightCamera = candidate.rightCamera?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fullyEvidenced =
                    leftTime.isFinite &&
                    rightTime.isFinite &&
                    abs(leftTime - rightTime) <= 2_000 &&
                    !leftCamera.isEmpty && !rightCamera.isEmpty &&
                    leftCamera.compare(rightCamera, options: .caseInsensitive) == .orderedSame &&
                    candidate.leftCandidateCount == 1 &&
                    candidate.rightCandidateCount == 1
                if !fullyEvidenced { continue }
                try mergeFileAssets(primaryFileId: candidate.leftFileId, secondaryFileId: candidate.rightFileId)
                let evidence = JSONValue.object([
                    "sameDirectory": JSONValue.bool(true),
                    "sameBasename": JSONValue.bool(true),
                    "captureTimeDeltaMs": JSONValue.int(Int64(abs(leftTime - rightTime))),
                    "cameraModel": JSONValue.string(leftCamera),
                    "automatic": JSONValue.bool(true),
                    "reversible": JSONValue.bool(true),
                ])
                _ = try connection.prepare("""
                    UPDATE asset_link_candidates
                    SET confidence = 1, evidence_json = ?, status = 'accepted', updated_at = ?
                    WHERE id = ? AND status = 'pending'
                  """).run([
                    .text(try JSONValue.stringify(evidence)),
                    .text(nowISOString()),
                    .text(candidate.id),
                ])
                merged += 1
            }
            if merged > 0 {
                _ = try connection.prepare("""
                    UPDATE asset_backfill_state
                    SET automatic_merges = automatic_merges + ?, updated_at = ?
                    WHERE session_id = ?
                  """).run([.int(merged), .text(nowISOString()), .text(sessionId)])
            }
        }
        return merged
    }

    // ─────────────────────────── 私有：状态迁移 ───────────────────────────

    private func getCandidate(_ candidateId: String) throws -> CandidateLiteRow? {
        guard let row = try connection.prepare("""
            SELECT left_file_id, right_file_id, status
            FROM asset_link_candidates WHERE id = ?
          """).get([.text(candidateId)]) else { return nil }
        return CandidateLiteRow(
            leftFileId: row[0].textValue ?? "",
            rightFileId: row[1].textValue ?? "",
            status: row[2].textValue ?? ""
        )
    }

    /// 把 metadata_outbox / writeback_items / metadata_keyword_origins 从旧照片路径迁到新路径。
    private func relocateMetadataState(
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws -> String? {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        if oldXmp == newXmp { return nil }
        let oldOutbox = try connection.prepare("SELECT status FROM metadata_outbox WHERE xmp_path = ?")
            .get([.text(oldXmp)])
        if oldOutbox?[0].textValue == "writing" {
            throw DBError.message("ASSET_RELINK_XMP_BUSY")
        }
        if let oldOutbox {
            let targetExists = try connection.prepare("SELECT 1 FROM metadata_outbox WHERE xmp_path = ?")
                .get([.text(newXmp)])
            if targetExists != nil {
                throw DBError.message("ASSET_RELINK_OUTBOX_CONFLICT")
            }
            _ = try connection.prepare("""
                INSERT INTO metadata_outbox (
                  xmp_path, owner_session_id, created_by_session_id, photo_path,
                  patch_json, dirty_fields, revision, persisted_revision,
                  base_fingerprint, base_values_json, backup_path, status,
                  attempt_count, error_message, updated_at
                )
                SELECT ?, owner_session_id, created_by_session_id, ?,
                  patch_json, dirty_fields, revision, persisted_revision,
                  base_fingerprint, base_values_json, backup_path,
                  CASE WHEN status IN ('pending', 'failed') THEN 'pending' ELSE status END,
                  CASE WHEN status IN ('pending', 'failed') THEN 0 ELSE attempt_count END,
                  CASE WHEN status IN ('pending', 'failed') THEN '' ELSE error_message END,
                  ?
                FROM metadata_outbox WHERE xmp_path = ?
              """).run([.text(newXmp), .text(newPhotoPath), .text(timestamp), .text(oldXmp)])
            _ = try connection.prepare("""
                INSERT INTO metadata_outbox_sessions
                  (xmp_path, session_id, confirmed_at, linked_at)
                SELECT ?, session_id, confirmed_at, linked_at
                FROM metadata_outbox_sessions WHERE xmp_path = ?
              """).run([.text(newXmp), .text(oldXmp)])
            _ = try connection.prepare(
                "UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?"
            ).run([.text(newPhotoPath), .text(newXmp), .text(oldXmp)])
            try relocateKeywordOrigins(oldXmp: oldXmp, newXmp: newXmp, timestamp: timestamp)
            _ = try connection.prepare("DELETE FROM metadata_keyword_origins WHERE xmp_path = ?")
                .run([.text(oldXmp)])
            _ = try connection.prepare("DELETE FROM metadata_outbox WHERE xmp_path = ?")
                .run([.text(oldXmp)])
            return newXmp
        } else {
            _ = try connection.prepare(
                "UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?"
            ).run([.text(newPhotoPath), .text(newXmp), .text(oldXmp)])
            try relocateKeywordOrigins(oldXmp: oldXmp, newXmp: newXmp, timestamp: timestamp)
            _ = try connection.prepare("DELETE FROM metadata_keyword_origins WHERE xmp_path = ?")
                .run([.text(oldXmp)])
            return nil
        }
    }

    private func relocateKeywordOrigins(oldXmp: String, newXmp: String, timestamp: String) throws {
        _ = try connection.prepare("""
            INSERT INTO metadata_keyword_origins (
              xmp_path, source, keyword, active, created_at, updated_at
            )
            SELECT ?, source, keyword, active, created_at, ?
            FROM metadata_keyword_origins WHERE xmp_path = ?
            ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
              active = MAX(active, excluded.active),
              updated_at = excluded.updated_at
          """).run([.text(newXmp), .text(timestamp), .text(oldXmp)])
    }

    private func relocateSidecarBinding(oldPhotoPath: String, newPhotoPath: String, timestamp: String) throws {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        let normalizedOld = TSPath.normalize(oldXmp)
        let normalizedNew = TSPath.normalize(newXmp)
        if normalizedOld == normalizedNew { return }
        guard let oldBinding = try connection.prepare(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?"
        ).get([.text(normalizedOld)]) else { return }
        let targetBinding = try connection.prepare(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?"
        ).get([.text(normalizedNew)])
        let oldBindingId = oldBinding[0].textValue ?? ""
        if targetBinding == nil {
            _ = try connection.prepare("""
                UPDATE sidecar_bindings
                SET xmp_path = ?, normalized_xmp_path = ?, updated_at = ?
                WHERE id = ?
              """).run([.text(newXmp), .text(normalizedNew), .text(timestamp), .text(oldBindingId)])
            return
        }
        let targetBindingId = targetBinding?[0].textValue ?? ""

        let oldState = try connection.prepare("""
            SELECT rating, label, keywords, fingerprint
            FROM sidecar_metadata_state WHERE sidecar_binding_id = ?
          """).get([.text(oldBindingId)]).map { SidecarStateRow(
            rating: $0[0].intValue,
            label: $0[1].textValue,
            keywords: $0[2].textValue ?? "",
            fingerprint: $0[3].textValue ?? ""
        ) }
        let targetState = try connection.prepare("""
            SELECT rating, label, keywords, fingerprint
            FROM sidecar_metadata_state WHERE sidecar_binding_id = ?
          """).get([.text(targetBindingId)]).map { SidecarStateRow(
            rating: $0[0].intValue,
            label: $0[1].textValue,
            keywords: $0[2].textValue ?? "",
            fingerprint: $0[3].textValue ?? ""
        ) }
        if let oldState, let targetState,
           oldState.rating != targetState.rating ||
           oldState.label != targetState.label ||
           oldState.keywords != targetState.keywords ||
           oldState.fingerprint != targetState.fingerprint {
            throw DBError.message("ASSET_RELINK_XMP_CONFLICT")
        }
        if let oldState, targetState == nil {
            _ = try connection.prepare("""
                INSERT INTO sidecar_metadata_state (
                  sidecar_binding_id, rating, label, keywords, fingerprint, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
              """).run([
                .text(targetBindingId),
                optDB(oldState.rating),
                optDB(oldState.label),
                .text(oldState.keywords),
                .text(oldState.fingerprint),
                .text(timestamp),
            ])
        }
        _ = try connection.prepare("""
            INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id)
            SELECT ?, file_id FROM sidecar_binding_files WHERE sidecar_binding_id = ?
          """).run([.text(targetBindingId), .text(oldBindingId)])
        _ = try connection.prepare("DELETE FROM sidecar_bindings WHERE id = ?").run([.text(oldBindingId)])
    }

    // ─────────────────────────── 私有：RAW/JPEG 候选 ───────────────────────────

    private func createRawJpegCandidates(_ sessionId: String) throws -> Int64 {
        let files = try connection.prepare("""
            SELECT DISTINCT af.id, af.filename, af.normalized_path, af.extension
            FROM asset_files af
            JOIN asset_members am ON am.file_id = af.id
            JOIN session_assets sa ON sa.asset_id = am.asset_id
            WHERE sa.session_id = ? AND af.extension IN ('.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw', '.jpg', '.jpeg')
          """).query([.text(sessionId)]).map { row in
            RawJpegFileRow(
                id: row[0].textValue ?? "",
                filename: row[1].textValue ?? "",
                normalizedPath: row[2].textValue ?? "",
                fileExtension: row[3].textValue ?? ""
            )
        }
        var seen = Set<String>()
        let fileIds = files.compactMap { file -> String? in
            guard !seen.contains(file.id) else { return nil }
            seen.insert(file.id)
            return file.id
        }
        var existingPairs = Set<String>()
        for chunk in fileIds.chunked(by: 500) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var values: [DBValue?] = chunk.map { .text($0) }
            values.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT left_file_id, right_file_id FROM asset_link_candidates
                WHERE left_file_id IN (\(placeholders)) OR right_file_id IN (\(placeholders))
              """).query(values)
            for row in rows {
                let left = row[0].textValue ?? ""
                let right = row[1].textValue ?? ""
                existingPairs.insert("\(left)\u{0}\(right)")
                existingPairs.insert("\(right)\u{0}\(left)")
            }
        }
        var candidatesByStem: [String: (raws: [RawJpegFileRow], jpegs: [RawJpegFileRow])] = [:]
        for file in files {
            let directory = TSPath.dirname(file.normalizedPath).lowercased()
            // TS: path.basename(file.filename, file.extension).toLowerCase()
            let stem = TSPath.stem(file.filename).lowercased()
            let key = "\(directory)\u{0}\(stem)"
            var group = candidatesByStem[key] ?? (raws: [], jpegs: [])
            if mediaType(file.fileExtension) == "raw" {
                group.raws.append(file)
            } else if [".jpg", ".jpeg"].contains(file.fileExtension) {
                group.jpegs.append(file)
            }
            candidatesByStem[key] = group
        }
        var created: Int64 = 0
        for (groupKey, group) in candidatesByStem {
            for raw in group.raws {
                for jpeg in group.jpegs {
                    if existingPairs.contains("\(raw.id)\u{0}\(jpeg.id)") { continue }
                    let timestamp = nowISOString()
                    let unambiguous = group.raws.count == 1 && group.jpegs.count == 1
                    let candidateId = newUUIDString()
                    let evidence = JSONValue.object([
                        "basename": JSONValue.string(String(groupKey.suffix(from: groupKey.index(groupKey.firstIndex(of: "\u{0}")!, offsetBy: 1)))),
                        "sameDirectory": JSONValue.bool(true),
                        "sameSession": JSONValue.bool(true),
                        "unambiguous": .bool(unambiguous),
                        "requiresManualConfirmation": JSONValue.bool(true),
                    ])
                    _ = try connection.prepare("""
                        INSERT INTO asset_link_candidates (id, left_file_id, right_file_id, relation_type, confidence, evidence_json, status, created_at, updated_at)
                        VALUES (?, ?, ?, 'raw_jpeg', ?, ?, ?, ?, ?)
                      """).run([
                        .text(candidateId),
                        .text(raw.id),
                        .text(jpeg.id),
                        .real(unambiguous ? 0.85 : 0.7),
                        .text(try JSONValue.stringify(evidence)),
                        .text("pending"),
                        .text(timestamp),
                        .text(timestamp),
                    ])
                    created += 1
                }
            }
        }
        return created
    }

    // ─────────────────────────── 私有：合并/拆分 ───────────────────────────

    /// 合并两个文件的资产（TS 内层 transaction 在 better-sqlite3 中为 savepoint；
    /// Swift DB 层不支持嵌套事务，故本方法扁平化，调用方（acceptCandidate/
    /// reconcileRawJpegLinks）保证外层事务）。
    private func mergeFileAssets(primaryFileId: String, secondaryFileId: String) throws {
        let primary = try connection.prepare(
            "SELECT asset_id FROM asset_members WHERE file_id = ?"
        ).get([.text(primaryFileId)])?[0].textValue
        let secondary = try connection.prepare(
            "SELECT asset_id FROM asset_members WHERE file_id = ?"
        ).get([.text(secondaryFileId)])?[0].textValue
        guard let primary, let secondary, primary != secondary else { return }

        let timestamp = nowISOString()
        let secondarySessions = try connection.prepare(
            "SELECT session_id, display_file_id, import_order, added_at FROM session_assets WHERE asset_id = ?"
        ).query([.text(secondary)]).map { row in
            SessionAssetRow(
                sessionId: row[0].textValue ?? "",
                displayFileId: row[1].textValue,
                importOrder: row[2].intValue ?? 0,
                addedAt: row[3].textValue ?? ""
            )
        }
        _ = try connection.prepare(
            "UPDATE asset_members SET asset_id = ?, is_primary = 0, binding_source = ? WHERE asset_id = ?"
        ).run([.text(primary), .text("auto_raw_jpeg"), .text(secondary)])
        for membership in secondarySessions {
            _ = try connection.prepare("""
                INSERT INTO session_assets
                  (session_id, asset_id, display_file_id, import_order, added_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id, asset_id) DO UPDATE SET
                  import_order = MIN(import_order, excluded.import_order)
              """).run([
                .text(membership.sessionId),
                .text(primary),
                .text(membership.displayFileId ?? secondaryFileId),
                .int(membership.importOrder),
                .text(membership.addedAt),
            ])
        }
        _ = try connection.prepare("UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_id = ?")
            .run([.text(primary), .text(timestamp), .text(secondary)])
        _ = try connection.prepare("DELETE FROM session_assets WHERE asset_id = ?").run([.text(secondary)])
        _ = try connection.prepare("DELETE FROM assets WHERE id = ?").run([.text(secondary)])
    }

    private func splitFileAsset(_ fileId: String) throws {
        guard let membership = try connection.prepare(
            "SELECT asset_id FROM asset_members WHERE file_id = ?"
        ).get([.text(fileId)])?[0].textValue else {
            throw DBError.message("ASSET_FILE_NOT_LINKED")
        }
        let siblingCount = Int64((try connection.prepare(
            "SELECT COUNT(*) AS count FROM asset_members WHERE asset_id = ?"
        ).get([.text(membership)])?[0].intValue) ?? 0)
        if siblingCount <= 1 { return }

        let timestamp = nowISOString()
        let assetId = newUUIDString()
        _ = try connection.prepare(
            "INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
        ).run([.text(assetId), .text(""), .text("active"), .text(timestamp), .text(timestamp)])
        _ = try connection.prepare("""
            UPDATE asset_members
            SET asset_id = ?, is_primary = 1, binding_source = 'manual_split'
            WHERE file_id = ?
          """).run([.text(assetId), .text(fileId)])

        let sessions = try connection.prepare(
            "SELECT DISTINCT session_id FROM photos WHERE asset_file_id = ?"
        ).query([.text(fileId)]).compactMap { $0[0].textValue }
        _ = try connection.prepare("UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_file_id = ?")
            .run([.text(assetId), .text(timestamp), .text(fileId)])
        for sessionId in sessions {
            _ = try connection.prepare("""
                INSERT OR IGNORE INTO session_assets
                  (session_id, asset_id, display_file_id, import_order, added_at)
                VALUES (?, ?, ?, 0, ?)
              """).run([.text(sessionId), .text(assetId), .text(fileId), .text(timestamp)])
            _ = try connection.prepare("""
                DELETE FROM session_assets
                WHERE session_id = ? AND asset_id = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM photos
                    WHERE session_id = ? AND asset_id = ?
                  )
              """).run([.text(sessionId), .text(membership), .text(sessionId), .text(membership)])
        }
    }

    // ─────────────────────────── 私有：单照片 ───────────────────────────

    private func ensurePhoto(sessionId: String, photo: PhotoBackfillRow) throws -> (migrated: Int64, offline: Int64) {
        let absolute = TSPath.resolve(photo.filepath)
        let normalizedPath = TSPath.normalize(absolute)
        let extensionWithDot = TSPath.extname(absolute).lowercased()
        var fileSize: Int64 = 0
        var mtimeMs: Double = 0
        var deviceId: Int64?
        var fileIdentity = ""
        var onlineStatus = "online"
        if let info = tsStat(absolute) {
            fileSize = info.size
            mtimeMs = info.mtimeMs
            deviceId = info.dev
            fileIdentity = String(info.ino)
        } else {
            onlineStatus = "offline"
        }
        let timestamp = nowISOString()
        let volumeId: String
        if let deviceId {
            volumeId = "dev:\(deviceId)"
        } else if let rootStat = tsStat(TSPath.root(absolute)) {
            volumeId = "dev:\(rootStat.dev)"
        } else {
            volumeId = "path:\(TSPath.root(absolute))"
        }

        var file: AssetFileRefRow?
        if !fileIdentity.isEmpty {
            file = try connection.prepare("""
                SELECT * FROM asset_files
                WHERE volume_id = ? AND file_identity = ?
                ORDER BY updated_at DESC LIMIT 1
              """).get([.text(volumeId), .text(fileIdentity)]).map {
                AssetFileRefRow(id: $0[0].textValue ?? "", normalizedPath: $0[3].textValue ?? "")
            }
        }
        if file == nil {
            file = try connection.prepare(
                "SELECT * FROM asset_files WHERE normalized_path = ? ORDER BY updated_at DESC LIMIT 1"
            ).get([.text(normalizedPath)]).map {
                AssetFileRefRow(id: $0[0].textValue ?? "", normalizedPath: $0[3].textValue ?? "")
            }
        }
        if let file {
            let previousPath = file.normalizedPath
            _ = try connection.prepare("""
                UPDATE asset_files
                SET volume_id = ?, file_identity = CASE WHEN ? != '' THEN ? ELSE file_identity END,
                    normalized_path = ?, filename = ?, extension = ?,
                    file_size = ?, file_mtime_ms = ?,
                    checksum = CASE WHEN ? != '' THEN ? ELSE checksum END, online_status = ?,
                    last_seen_at = ?, updated_at = ?
                WHERE id = ?
              """).run([
                .text(volumeId),
                .text(fileIdentity), .text(fileIdentity),
                .text(normalizedPath),
                .text(TSPath.basename(absolute)),
                .text(extensionWithDot),
                .int(fileSize),
                .real(mtimeMs),
                .text(photo.checksum), .text(photo.checksum),
                .text(onlineStatus),
                .text(timestamp),
                .text(timestamp),
                .text(file.id),
            ])
            if !previousPath.isEmpty && previousPath != normalizedPath && !tsExists(previousPath) {
                _ = try connection.prepare("""
                    UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                    WHERE asset_file_id = ?
                  """).run([
                    .text(normalizedPath), .text(TSPath.basename(normalizedPath)),
                    .text(timestamp), .text(file.id),
                ])
            }
        } else {
            let fileId = newUUIDString()
            _ = try connection.prepare("""
                INSERT INTO asset_files (
                  id, volume_id, file_identity, normalized_path, filename, extension, media_type,
                  file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """).run([
                .text(fileId), .text(volumeId), .text(fileIdentity), .text(normalizedPath),
                .text(TSPath.basename(absolute)), .text(extensionWithDot),
                .text(mediaType(extensionWithDot)),
                .int(fileSize), .real(mtimeMs), .text(photo.checksum), .text(onlineStatus),
                .text(timestamp), .text(timestamp), .text(timestamp),
            ])
            file = AssetFileRefRow(id: fileId, normalizedPath: normalizedPath)
        }

        let fileId = file!.id
        var membership = try connection.prepare(
            "SELECT asset_id FROM asset_members WHERE file_id = ?"
        ).get([.text(fileId)])?[0].textValue
        if membership == nil {
            let assetId = newUUIDString()
            _ = try connection.prepare(
                "INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
            ).run([
                .text(assetId), .text(""),
                .text(onlineStatus == "online" ? "active" : "offline_unverified"),
                .text(timestamp), .text(timestamp),
            ])
            _ = try connection.prepare(
                "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES (?, ?, ?, 1, ?)"
            ).run([.text(assetId), .text(fileId), .text(memberRole(extensionWithDot)), .text("backfill")])
            membership = assetId
        }

        let importOrder: Int64
        if photo.migrationRowid != 0 {
            importOrder = photo.migrationRowid
        } else {
            importOrder = Int64((try connection.prepare("SELECT rowid FROM photos WHERE id = ?")
                .get([.text(photo.id)])?[0].intValue) ?? 0)
        }
        _ = try connection.prepare("""
            INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, asset_id) DO UPDATE SET display_file_id = excluded.display_file_id
          """).run([
            .text(sessionId), .text(membership ?? ""), .text(fileId),
            .int(importOrder), .text(timestamp),
        ])
        _ = try connection.prepare("UPDATE assets SET status = ?, updated_at = ? WHERE id = ?")
            .run([
                .text(onlineStatus == "online" ? "active" : "offline_unverified"),
                .text(timestamp), .text(membership ?? ""),
            ])
        _ = try connection.prepare("UPDATE photos SET asset_id = ?, asset_file_id = ? WHERE id = ?")
            .run([.text(membership ?? ""), .text(fileId), .text(photo.id)])

        let sidecarPath = TSPath.xmpSidecarPath(absolute)
        let bindingId = newUUIDString()
        _ = try connection.prepare("""
            INSERT INTO sidecar_bindings (id, xmp_path, normalized_xmp_path, binding_rule, created_at, updated_at)
            VALUES (?, ?, ?, 'same_basename', ?, ?)
            ON CONFLICT(normalized_xmp_path) DO UPDATE SET updated_at = excluded.updated_at
          """).run([
            .text(bindingId), .text(sidecarPath), .text(TSPath.normalize(sidecarPath)),
            .text(timestamp), .text(timestamp),
        ])
        let binding = try connection.prepare(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?"
        ).get([.text(TSPath.normalize(sidecarPath))])
        _ = try connection.prepare(
            "INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id) VALUES (?, ?)"
        ).run([.text(binding?[0].textValue ?? ""), .text(fileId)])

        return (migrated: 1, offline: onlineStatus == "online" ? 0 : 1)
    }

    // ─────────────────────────── 私有：扩展名分类 ───────────────────────────

    private func mediaType(_ extensionWithDot: String) -> String {
        if [".jpg", ".jpeg", ".heic", ".heif", ".png", ".webp"].contains(extensionWithDot) { return "image" }
        if [".nef", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw"].contains(extensionWithDot) { return "raw" }
        if [".tif", ".tiff", ".psd"].contains(extensionWithDot) { return "image" }
        return "unknown"
    }

    private func memberRole(_ extensionWithDot: String) -> String {
        if mediaType(extensionWithDot) == "raw" { return "raw" }
        if [".jpg", ".jpeg", ".heic", ".heif"].contains(extensionWithDot) { return "camera_jpeg" }
        if [".tif", ".tiff"].contains(extensionWithDot) { return "rendered_tiff" }
        return "unknown"
    }
}

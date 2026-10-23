// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo+Scan.swift
// 源：AssetRepo.swift（HEAD c4aa5b5）；纯拆分（scan/import），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 AssetRepo.swift 头部记账。

import Foundation
import GatherProtocol

extension AssetRepo {

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

    // ─────────────────────────── 私有：RAW/JPEG 候选 ───────────────────────────

    private func createRawJpegCandidates(_ sessionId: String) throws -> Int64 {
        let files = try connection.prepare("""
            SELECT DISTINCT af.id, af.filename, af.normalized_path, af.extension
            FROM asset_files af
            JOIN asset_members am ON am.file_id = af.id
            JOIN session_assets sa ON sa.asset_id = am.asset_id
            WHERE sa.session_id = ?
              AND af.extension IN (\(Self.sqlExtensionList(Self.rawExtensions.union(Self.rawPairingExtensions))))
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
        var candidatesByStem: [String: (raws: [RawJpegFileRow], counterparts: [RawJpegFileRow])] = [:]
        for file in files {
            let directory = TSPath.dirname(file.normalizedPath).lowercased()
            // TS: path.basename(file.filename, file.extension).toLowerCase()
            let stem = TSPath.stem(file.filename).lowercased()
            let key = "\(directory)\u{0}\(stem)"
            var group = candidatesByStem[key] ?? (raws: [], counterparts: [])
            if Self.rawExtensions.contains(file.fileExtension) {
                group.raws.append(file)
            } else if Self.rawPairingExtensions.contains(file.fileExtension) {
                group.counterparts.append(file)
            }
            candidatesByStem[key] = group
        }
        var created: Int64 = 0
        for (groupKey, group) in candidatesByStem {
            for raw in group.raws {
                for jpeg in group.counterparts {
                    if existingPairs.contains("\(raw.id)\u{0}\(jpeg.id)") { continue }
                    let timestamp = nowISOString()
                    let unambiguous = group.raws.count == 1 && group.counterparts.count == 1
                    let candidateId = newUUIDString()
                    let evidence = JSONValue.object([
                        "basename": JSONValue.string(String(groupKey.suffix(from: groupKey.index(groupKey.firstIndex(of: "\u{0}")!, offsetBy: 1)))),
                        "sameDirectory": JSONValue.bool(true),
                        "sameSession": JSONValue.bool(true),
                        "unambiguous": .bool(unambiguous),
                        "requiresManualConfirmation": JSONValue.bool(true),
                        // 配对侧的实际角色：RAW+HEIC / RAW+TIFF 与 RAW+JPEG 语义不同，
                        // 手动确认时需要看到到底是哪一对。
                        "leftRole": JSONValue.string(memberRole(raw.fileExtension)),
                        "rightRole": JSONValue.string(memberRole(jpeg.fileExtension)),
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
            // asset_files：14 列（TableColumns.assetFiles；内联读取 0=id / 3=normalized_path）
            file = try connection.prepare("""
                SELECT \(TableColumns.sql(TableColumns.assetFiles)) FROM asset_files
                WHERE volume_id = ? AND file_identity = ?
                ORDER BY updated_at DESC LIMIT 1
              """).get([.text(volumeId), .text(fileIdentity)]).map {
                AssetFileRefRow(id: $0[0].textValue ?? "", normalizedPath: $0[3].textValue ?? "")
            }
        }
        if file == nil {
            // asset_files：14 列（TableColumns.assetFiles；内联读取 0=id / 3=normalized_path）
            file = try connection.prepare(
                "SELECT \(TableColumns.sql(TableColumns.assetFiles)) FROM asset_files WHERE normalized_path = ? ORDER BY updated_at DESC LIMIT 1"
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
                try retargetPhotosPath(assetFileId: file.id, path: normalizedPath, timestamp: timestamp)
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
            // V1 assets 已删除 capture_fingerprint（指纹由 asset_members/files 派生）。
            _ = try connection.prepare(
                "INSERT INTO assets (id, status, created_at, updated_at) VALUES (?, ?, ?, ?)"
            ).run([
                .text(assetId),
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

    /// Set → SQL IN 列表（排序保证 SQL 文本稳定，便于语句缓存）。
    private static func sqlExtensionList(_ values: Set<String>) -> String {
        values.sorted().map { "'\($0)'" }.joined(separator: ", ")
    }

    private func mediaType(_ extensionWithDot: String) -> String {
        if Self.bitmapExtensions.contains(extensionWithDot) { return "image" }
        if Self.rawExtensions.contains(extensionWithDot) { return "raw" }
        if Self.renderedExtensions.contains(extensionWithDot) { return "image" }
        return "unknown"
    }

    private func memberRole(_ extensionWithDot: String) -> String {
        if Self.rawExtensions.contains(extensionWithDot) { return "raw" }
        if [".jpg", ".jpeg", ".heic", ".heif"].contains(extensionWithDot) { return "camera_jpeg" }
        if [".tif", ".tiff"].contains(extensionWithDot) { return "rendered_tiff" }
        return "unknown"
    }
}

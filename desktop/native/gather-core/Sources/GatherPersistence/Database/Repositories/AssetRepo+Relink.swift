// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo+Relink.swift
// 源：AssetRepo.swift（HEAD c4aa5b5）；纯拆分（relink/别名），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 AssetRepo.swift 头部记账。

import Foundation
import GatherProtocol

extension AssetRepo {

    // ─────────────────────────── 重链接 ───────────────────────────

    /// 重新关联目录：把 oldRoot 下**已验证身份**的文件改指到 newRoot 的同名相对路径。
    ///
    /// 与旧实现的区别（旧实现不校验任何证据就改写路径 —— 用户选错目录就会把整库
    /// 指向另一批同名文件；且 (volume_id, normalized_path) 与
    /// (volume_id, file_identity) 都是唯一索引，撞索引还会在事务中途失败）：
    /// 1. oldRoot == newRoot、或两者互相嵌套 → 显式报错，不做任何改写；
    /// 2. 每个候选文件必须通过身份校验才改写，证据按强度排序：
    ///    (dev, ino) 同一物理文件 → 通过；size 且 mtime 一致 → 通过；
    ///    size 一致且已存 checksum → 现算 sha256 比对通过；
    ///    其余（新位置缺失、未通过校验、新位置已被另一行占用）一律跳过并保持原状；
    /// 3. 一个都没通过 → 抛错（"0" 不再等同于"成功但什么都没做"）；
    /// 4. 只有验证通过的文件所属会话才会被作废相似度/导航分组并 +index_seq。
    public func relinkRoot(oldRoot: String, newRoot: String) throws -> Int {
        let resolvedOld = ScanPath.canonical(oldRoot)
        let resolvedNew = ScanPath.canonical(newRoot)
        guard resolvedOld != resolvedNew else {
            throw PersistenceError(code: .ASSET_RELINK_SAME_ROOT)
        }
        guard !ScanPath.isWithin(candidate: resolvedNew, root: resolvedOld),
              !ScanPath.isWithin(candidate: resolvedOld, root: resolvedNew)
        else {
            throw PersistenceError(code: .ASSET_RELINK_NESTED_ROOT)
        }

        // 历史行可能存 /private/var 或 /var 两种拼写：两种前缀都捞出候选，
        // 再用 ScanPath.relative 做权威判定。
        let spelledOld = (resolvedOld.hasPrefix("/var/") || resolvedOld.hasPrefix("/tmp/"))
            ? "/private" + resolvedOld
            : resolvedOld
        func escapeLike(_ value: String) -> String {
            value.map { ch -> String in
                if ch == "\\" || ch == "%" || ch == "_" { return "\\\(ch)" }
                return String(ch)
            }.joined()
        }
        let rows = try connection.prepare("""
            SELECT id, volume_id, file_identity, normalized_path, file_size, file_mtime_ms, checksum
            FROM asset_files
            WHERE normalized_path = ? OR normalized_path = ?
               OR normalized_path LIKE ? ESCAPE '\\' OR normalized_path LIKE ? ESCAPE '\\'
          """).query([
            .text(resolvedOld), .text(spelledOld),
            .text("\(escapeLike(resolvedOld))\(TSPath.separator)%"),
            .text("\(escapeLike(spelledOld))\(TSPath.separator)%"),
        ])

        var changes: [(id: String, oldPath: String, newPath: String, volumeId: String, fileIdentity: String)] = []
        var scanned = 0
        for row in rows {
            let id = row[0].textValue ?? ""
            let storedVolumeId = row[1].textValue ?? ""
            let storedIdentity = row[2].textValue ?? ""
            let normalizedPath = row[3].textValue ?? ""
            let storedSize = row[4].intValue ?? 0
            let storedMtime = row[5].doubleValue ?? 0
            let storedChecksum = row[6].textValue ?? ""
            guard let relativePath = ScanPath.relative(path: normalizedPath, root: resolvedOld) else {
                continue
            }
            scanned += 1
            let newPath = relativePath.isEmpty
                ? resolvedNew
                : TSPath.join([resolvedNew, relativePath])
            guard let info = tsStat(newPath), info.isFile else { continue }

            let volumeId = "dev:\(info.dev)"
            let fileIdentity = String(info.ino)
            let identityMatches = !storedIdentity.isEmpty &&
                storedVolumeId == volumeId &&
                storedIdentity == fileIdentity
            let sizeMatches = storedSize > 0 && storedSize == info.size
            let mtimeMatches = storedMtime > 0 && abs(storedMtime - info.mtimeMs) <= 1
            var verified = identityMatches || (sizeMatches && mtimeMatches)
            if !verified, sizeMatches, !storedChecksum.isEmpty {
                // Cut 3a / E-02：哈希工具已下沉到 Persistence（FileHasher）；
                // 原调 Domain 层 IndexerService 的哈希方法会形成反向依赖。
                verified = (try? FileHasher.sha256File(newPath)) == storedChecksum
            }
            guard verified else { continue }
            // 新位置不能被另一行占用（两个唯一索引都会拒绝）。
            let occupied = try connection.prepare("""
                SELECT 1 FROM asset_files
                WHERE id <> ? AND (normalized_path = ? OR (volume_id = ? AND file_identity = ?))
                LIMIT 1
              """).get([
                .text(id), .text(newPath), .text(volumeId), .text(fileIdentity),
            ])
            guard occupied == nil else { continue }

            changes.append((
                id: id,
                oldPath: normalizedPath,
                newPath: newPath,
                volumeId: volumeId,
                fileIdentity: fileIdentity
            ))
        }
        guard scanned > 0 else {
            throw PersistenceError(code: .ASSET_RELINK_NO_FILES_REGISTERED)
        }
        guard !changes.isEmpty else {
            throw PersistenceError(code: .ASSET_RELINK_NO_VERIFIED_FILE)
        }

        let timestamp = nowISOString()
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
                _ = try relocateMetadataState(
                    oldPhotoPath: change.oldPath,
                    newPhotoPath: change.newPath,
                    timestamp: timestamp
                )
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
                try retargetPhotosPath(assetFileId: change.id, path: change.newPath, timestamp: timestamp)
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
            }.flatMap { row in
                // 旧路径仍存在 = 同 inode 的硬链接/未移动文件；relink 会把两张
                // 在册照片并到同一 asset。只接受"旧位置已消失"的移动。
                tsExists(row.normalizedPath) ? nil : row
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
        try connection.transaction {
            _ = try relocateMetadataState(
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
            try retargetPhotosPath(assetFileId: match.id, path: resolvedPath, timestamp: timestamp)
            try relocateSidecarBinding(
                oldPhotoPath: match.normalizedPath,
                newPhotoPath: resolvedPath,
                timestamp: timestamp
            )
        }
        return RelinkMovedFileResult(fileId: match.id, photoIds: photoIds)
    }

    public func acceptCandidate(_ candidateId: String) throws {
        guard let candidate = try getCandidate(candidateId) else {
            throw PersistenceError(code: .ASSET_LINK_CANDIDATE_NOT_FOUND)
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
            throw PersistenceError(code: .ASSET_LINK_CANDIDATE_NOT_FOUND)
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

    /// 淘汰/手动移动后的路径迁移：photos.filepath + deliveries/intents +
    /// keyword origins + sidecar bindings + asset_files 必须在**同一事务**里完成。
    /// 调用方负责移动文件；本方法失败时文件由调用方回滚。
    public func relocatePhotoPathsAfterMove(
        photoId: String,
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws {
        try connection.transaction {
            _ = try PhotoRepo(connection: connection).updateFilepath(
                photoId: photoId, filepath: newPhotoPath)
            _ = try relocateMetadataState(
                oldPhotoPath: oldPhotoPath, newPhotoPath: newPhotoPath, timestamp: timestamp)
            try relocateSidecarBinding(
                oldPhotoPath: oldPhotoPath, newPhotoPath: newPhotoPath, timestamp: timestamp)
            let oldNormalized = TSPath.normalize(oldPhotoPath)
            let newNormalized = TSPath.normalize(newPhotoPath)
            let targetExists = try connection.prepare(
                "SELECT 1 FROM asset_files WHERE normalized_path = ? LIMIT 1"
            ).get([.text(newNormalized)]) != nil
            if !targetExists {
                _ = try connection.prepare("""
                    UPDATE asset_files SET normalized_path = ?, updated_at = ?
                    WHERE normalized_path = ?
                  """).run([
                    .text(newNormalized), .text(timestamp), .text(oldNormalized),
                  ])
            }
        }
    }

    /// 把 deliveries / metadata_keyword_origins 从旧照片路径迁到新路径。
    ///
    /// 交付模型：deliveries.xmp_path 是主键，行内 photo_path 是写回时的照片快照；
    /// 迁移用同一行的 UPDATE（保留 id/revision/租约/基线），delivery_items 与
    /// delivery_sessions 都按 delivery_id 关联，因此无需改路径。
    ///
    /// S5c-2b-3b-2b-3：旧 metadata_outbox / writeback_items 分支已随旧同步栈删除，
    /// 迁移不再有「复制 outbox 行 + 改 writeback_items」这一层。
    /// 冲突语义沿用旧版本：writing → ASSET_RELINK_XMP_BUSY；目标 XMP 已有交付行
    /// → ASSET_RELINK_OUTBOX_CONFLICT（同一事务内抛错即整体回滚）。
    private func relocateMetadataState(
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws -> String? {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        if oldXmp == newXmp { return nil }
        let movedDelivery = try DeliveryRepo(connection: connection).relocatePaths(
            oldXmpPath: oldXmp,
            newXmpPath: newXmp,
            oldPhotoPath: oldPhotoPath,
            newPhotoPath: newPhotoPath,
            timestamp: timestamp)
        try relocateKeywordOrigins(oldXmp: oldXmp, newXmp: newXmp, timestamp: timestamp)
        _ = try connection.prepare("DELETE FROM metadata_keyword_origins WHERE xmp_path = ?")
            .run([.text(oldXmp)])
        return movedDelivery ? newXmp : nil
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
            throw PersistenceError(code: .ASSET_RELINK_XMP_CONFLICT)
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

    // ─────────────────────────── 私有：合并/拆分 ───────────────────────────

    /// 合并两个文件的资产。调用方（acceptCandidate / reconcileRawJpegLinks）已持有
    /// 外层事务，故本方法扁平化、不另开 savepoint；原子性由外层事务保证。
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
            throw PersistenceError(code: .ASSET_FILE_NOT_LINKED)
        }
        let siblingCount = Int64((try connection.prepare(
            "SELECT COUNT(*) AS count FROM asset_members WHERE asset_id = ?"
        ).get([.text(membership)])?[0].intValue) ?? 0)
        if siblingCount <= 1 { return }

        let timestamp = nowISOString()
        let assetId = newUUIDString()
        // V1 assets 已删除 capture_fingerprint（指纹由 asset_members/files 派生）。
        _ = try connection.prepare(
            "INSERT INTO assets (id, status, created_at, updated_at) VALUES (?, ?, ?, ?)"
        ).run([.text(assetId), .text("active"), .text(timestamp), .text(timestamp)])
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
}

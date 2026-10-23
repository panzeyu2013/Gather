// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/AssetRepo+Query.swift
// 源：AssetRepo.swift（HEAD c4aa5b5）；纯拆分（query/row mapping），SQL 逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 AssetRepo.swift 头部记账。

import Foundation
import GatherProtocol

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

extension AssetRepo {

    // ─────────────────────────── 候选 ───────────────────────────

    /// 批量照片的 asset_members 角色映射（photo.id → member_role；未关联为 "unknown"）。
    /// 供 photo 列表分页按逻辑资产分组挑选 raw/camera_jpeg 代表（TS photo.ipc.ts
    /// assemblePhotos 的两次小查询之一，原在宿主路由内联 SQL，下沉回 Repo）。
    public func memberRoles(sessionId: String, photoIds: [String]) throws -> [String: String] {
        guard !photoIds.isEmpty else { return [:] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT p.id AS photo_id, am.member_role
            FROM photos p
            LEFT JOIN asset_members am ON am.file_id = p.asset_file_id
            WHERE p.session_id = ? AND p.id IN (\(placeholders))
        """).query([.text(sessionId)] + photoIds.map(DBValue.text))
        var roles: [String: String] = [:]
        for row in rows {
            guard let photoId = row[0].textValue else { continue }
            roles[photoId] = row[1].textValue ?? "unknown"
        }
        return roles
    }

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
}

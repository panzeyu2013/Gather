// desktop/native/gather-core/Sources/GatherCore/Services/PhotoAssetResolver.swift
// TS 源: desktop/src/main/services/assets/photo-asset-resolver.ts（Phase 3.2 移植）
// 照片 → 资产解析：按 asset_read_mode（dual/asset/legacy）决定解析到资产文件
// 还是遗留路径；dual 模式下资产就绪但路径与遗留不一致时输出 shadow-read 警告。
import Foundation

/// TS: ResolvedPhotoAsset。
public struct ResolvedPhotoAsset: Equatable, Sendable {
    public let photoId: String
    public let sessionId: String
    public let assetId: String
    public let assetFileId: String
    public let filepath: String
    public let xmpPath: String
    public let source: String // 'legacy' | 'asset'

    public init(
        photoId: String,
        sessionId: String,
        assetId: String,
        assetFileId: String,
        filepath: String,
        xmpPath: String,
        source: String
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.assetId = assetId
        self.assetFileId = assetFileId
        self.filepath = filepath
        self.xmpPath = xmpPath
        self.source = source
    }
}

public final class PhotoAssetResolver {
    /// TS: resolveMany 的分块大小（SQLite 参数上限 999 以内，同其他批量读）。
    private static let chunkSize = 800

    private let database: SQLiteDatabase
    /// TS: SettingsService.get(key, defaultValue)。
    private let getSetting: (String, String) -> String

    public init(
        database: SQLiteDatabase,
        getSetting: @escaping (String, String) -> String = { _, defaultValue in defaultValue }
    ) {
        self.database = database
        self.getSetting = getSetting
    }

    /// 单照片解析；照片不属于会话抛 CULLING_PHOTO_NOT_IN_SESSION，
    /// 资产模式迁移不完整抛 ASSET_MIGRATION_INCOMPLETE。
    public func resolve(sessionId: String, photoId: String) async throws -> ResolvedPhotoAsset {
        guard let row = try await queryOne(sessionId: sessionId, photoId: photoId) else {
            throw PhotoAssetResolverError.photoNotInSession
        }
        let mode = getSetting("asset_read_mode", "dual")
        guard let resolved = buildResolved(row: row, mode: mode) else {
            throw PhotoAssetResolverError.migrationIncomplete
        }
        return resolved
    }

    /// 批量解析：一次 IN 查询替代每照片 5 路 JOIN；未知照片或
    /// asset 模式迁移不完整的行直接缺席，调用方按单照片抛错语义自行兜底。
    public func resolveMany(sessionId: String, photoIds: [String]) async throws -> [String: ResolvedPhotoAsset] {
        var resolved: [String: ResolvedPhotoAsset] = [:]
        if photoIds.isEmpty { return resolved }
        let mode = getSetting("asset_read_mode", "dual")
        var seen = Set<String>()
        for chunkStart in stride(from: 0, to: photoIds.count, by: Self.chunkSize) {
            let chunk = Array(photoIds[chunkStart..<min(chunkStart + Self.chunkSize, photoIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query("""
                SELECT p.id AS photo_id, p.session_id, p.filepath AS legacy_path,
                  p.asset_id, p.asset_file_id, af.normalized_path AS asset_path,
                  sb.xmp_path
                FROM photos p
                LEFT JOIN asset_files af ON af.id = p.asset_file_id
                LEFT JOIN sidecar_binding_files sbf ON sbf.file_id = af.id
                LEFT JOIN sidecar_bindings sb ON sb.id = sbf.sidecar_binding_id AND sb.status = 'active'
                WHERE p.id IN (\(placeholders)) AND p.session_id = ?
                ORDER BY p.id, sb.updated_at DESC
              """, chunk.map { .text($0) } + [.text(sessionId)])
            for row in rows {
                guard let photoId = row["photo_id"]?.textValue, !seen.contains(photoId) else { continue }
                seen.insert(photoId)
                guard let asset = buildResolved(row: row, mode: mode) else { continue }
                resolved[photoId] = asset
            }
        }
        return resolved
    }

    private func queryOne(sessionId: String, photoId: String) async throws -> SQLiteRow? {
        try await database.queryOne("""
            SELECT p.id AS photo_id, p.session_id, p.filepath AS legacy_path,
              p.asset_id, p.asset_file_id, af.normalized_path AS asset_path,
              sb.xmp_path
            FROM photos p
            LEFT JOIN asset_files af ON af.id = p.asset_file_id
            LEFT JOIN sidecar_binding_files sbf ON sbf.file_id = af.id
            LEFT JOIN sidecar_bindings sb ON sb.id = sbf.sidecar_binding_id AND sb.status = 'active'
            WHERE p.id = ? AND p.session_id = ?
            ORDER BY sb.updated_at DESC LIMIT 1
          """, [.text(photoId), .text(sessionId)])
    }

    /// TS: buildResolved。
    private func buildResolved(row: SQLiteRow, mode: String) -> ResolvedPhotoAsset? {
        guard let photoId = row["photo_id"]?.textValue else { return nil }
        let sessionId = row["session_id"]?.textValue ?? ""
        let legacyPath = row["legacy_path"]?.textValue ?? ""
        let assetId = row["asset_id"]?.textValue
        let assetFileId = row["asset_file_id"]?.textValue
        let assetPath = row["asset_path"]?.textValue
        let xmpPath = row["xmp_path"]?.textValue

        let assetReady = assetId != nil && assetFileId != nil && assetPath != nil
        let assetXmpPath = xmpPath ?? (assetPath.map(TSPath.xmpSidecarPath) ?? nil)
        let legacyXmpPath = TSPath.xmpSidecarPath(legacyPath)
        if mode == "dual" && assetReady,
           assetPath != legacyPath || assetXmpPath != legacyXmpPath {
            GatherLogger.log(
                "Asset shadow-read mismatch photoId=\(photoId) pathMismatch=\(assetPath != legacyPath)"
                    + " sidecarMismatch=\(assetXmpPath != legacyXmpPath)"
                    + " legacyPathDigest=\(Self.pathDigest(legacyPath))"
                    + " assetPathDigest=\(Self.pathDigest(assetPath))",
                level: .warn
            )
        }
        if mode == "asset" && !assetReady {
            return nil
        }
        let useAsset = mode == "asset" && assetReady
        return ResolvedPhotoAsset(
            photoId: photoId,
            sessionId: sessionId,
            assetId: assetId ?? photoId,
            assetFileId: assetFileId ?? photoId,
            filepath: useAsset ? assetPath! : legacyPath,
            xmpPath: useAsset ? assetXmpPath! : legacyXmpPath,
            source: useAsset ? "asset" : "legacy"
        )
    }

    /// TS: pathDigest —— sha256(value ?? '').hex 前 12 字符。
    private static func pathDigest(_ value: String?) -> String {
        let digest = SHA256.hash(Data((value ?? "").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).lowercased()
    }
}

public enum PhotoAssetResolverError: Error, Equatable {
    case photoNotInSession
    case migrationIncomplete
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension PhotoAssetResolverError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .photoNotInSession: .CULLING_PHOTO_NOT_IN_SESSION
        case .migrationIncomplete: .ASSET_MIGRATION_INCOMPLETE
        }
    }
}

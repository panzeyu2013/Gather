// desktop/native/gather-core/Sources/GatherCore/Services/NavigationService.swift
// TS 源: desktop/src/main/services/navigation/navigation.service.ts（Phase 3.6 移植）
//
// 行为契约（与 TS 逐条对应，红线见 NATIVE-DEVELOPMENT-ANALYSIS.md §3.6）：
//   - analyze：校验参数（NAV_BURST_GAP_INVALID/NAV_SCENE_GAP_INVALID）→
//     captureRows（重查询一次，复用）→ 指纹缓存（非 dryRun 且指纹相同直接
//     返回缓存组）→ burst/scene 两组 → withLead → persistAutomatic → list
//   - 分组边界：gap 无效/超阈值、相机不同（空值视为同机）、burst 需文件名
//     序号连续（差 1..3，无数字视为连续）+ 汉明距离 ≤14；scene 需同目录 +
//     汉明距离 ≤24；组 ≥2 张才生成
//   - 指纹 = sha256([burst, scene, rows 六元组(含 sorted warnings)])，任何
//     lead 要素变化都会使缓存失效
//   - list：组 <2 张 flatMap 过滤；按 group_type, created_at, id 排序
//   - split：splitIndex 越界抛 NAV_SPLIT_OUT_OF_GROUP；两个新 manual 组
//   - merge：≥2 组（NAV_MERGE_MIN_TWO）、全部存在（NAV_GROUP_NOT_FOUND）、
//     同类型（NAV_MERGE_TYPE_MISMATCH）；按 captureRows 顺序排序合并且重算 lead
//   - withLead：hasQuality 时 qualityScore + rating*0.08 - 闭眼惩罚(0.25) 降序；
//     否则 rating 降序；explanation 三态
//   - persistAutomatic：manual 成员从自动组剔除（per type）
// 与 TS 的差异：
//   - crypto.createHash('sha256') → GatherCore SHA256（ImageCache.swift 纯
//     Swift 实现，FIPS 180-4，Linux 兼容）
//   - path.basename/dirname → URL 处理；Date.parse → ISO8601DateFormatter
//   - 无 worker：captureRows 单次查询 + IN chunk 800 一致
//
// W2d 小步①：不访问持久层的纯逻辑（参数校验/分组/lead/split-merge 规则/质量解析/
// 指纹/纯辅助）已下沉到 Runtime/Navigation/NavigationAssembler.swift；本文件只保留
// 查询与持久化装配，行为逐字不变。
import Foundation

// MARK: - 错误

/// 导航错误（description 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
public enum NavigationError: Error, CustomStringConvertible {
    case burstGapInvalid
    case sceneGapInvalid
    case groupNotFound
    case splitOutOfGroup
    case mergeMinTwo
    case mergeTypeMismatch

    public var description: String {
        switch self {
        case .burstGapInvalid: return "NAV_BURST_GAP_INVALID"
        case .sceneGapInvalid: return "NAV_SCENE_GAP_INVALID"
        case .groupNotFound: return "NAV_GROUP_NOT_FOUND"
        case .splitOutOfGroup: return "NAV_SPLIT_OUT_OF_GROUP"
        case .mergeMinTwo: return "NAV_MERGE_MIN_TWO"
        case .mergeTypeMismatch: return "NAV_MERGE_TYPE_MISMATCH"
        }
    }
}

// MARK: - 服务

public final class NavigationService {
    /// TS: IN chunk 800（quality 查询）。
    private static let qualityChunkSize = 800

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: API

    /// TS: analyze(sessionId, burstGapSeconds=2, sceneGapSeconds=1800, dryRun=false)。
    public func analyze(
        sessionId: String,
        burstGapSeconds: Double = 2,
        sceneGapSeconds: Double = 1_800,
        dryRun: Bool = false
    ) async throws -> [NavigationGroup] {
        try NavigationAssembler.validateNavigationParameters(burstGapSeconds: burstGapSeconds, sceneGapSeconds: sceneGapSeconds)
        let rows = try await captureRows(sessionId: sessionId)
        let capturedAt = Dictionary(rows.map { ($0.id, $0.capturedAt) }, uniquingKeysWith: { first, _ in first })
        let fingerprint = NavigationAssembler.fingerprintHash(burst: burstGapSeconds, scene: sceneGapSeconds, rows: rows)

        if !dryRun {
            let cached = try await list(sessionId: sessionId, capturedAt: capturedAt)
            let cachedFingerprint = try await Self.cachedFingerprint(database: database, sessionId: sessionId)
            if !cached.isEmpty && cachedFingerprint == fingerprint {
                return cached
            }
        }

        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = (
            NavigationAssembler.group(rows: rows, type: .burst, gapSeconds: burstGapSeconds)
                + NavigationAssembler.group(rows: rows, type: .scene, gapSeconds: sceneGapSeconds)
        ).map { NavigationAssembler.withLead(group: $0, byId: byId) }

        if !dryRun {
            try await persistAutomatic(sessionId: sessionId, groups: groups, fingerprint: fingerprint)
            return try await list(sessionId: sessionId, capturedAt: capturedAt)
        }
        return groups
    }

    /// TS: list(sessionId, capturedAt?) —— 组 <2 张被过滤。
    public func list(sessionId: String, capturedAt: [String: String]? = nil) async throws -> [NavigationGroup] {
        let rows = try await database.query("""
            SELECT id, group_type, photo_ids_json, lead_photo_id, explanation, source
            FROM navigation_groups WHERE session_id = ?
            ORDER BY group_type, created_at, id
        """, [.text(sessionId)])

        let capturedByPhoto: [String: String]
        if let capturedAt {
            capturedByPhoto = capturedAt
        } else {
            capturedByPhoto = await Dictionary(
                (try captureRows(sessionId: sessionId)).map { ($0.id, $0.capturedAt) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return rows.compactMap { row -> NavigationGroup? in
            guard let photoIdsRaw = row.values[row.columnOrder[2]]?.textValue,
                  let photoIds = NavigationAssembler.parsePhotoIds(photoIdsRaw),
                  photoIds.count >= 2
            else { return nil }
            return NavigationGroup(
                id: row.values[row.columnOrder[0]]?.textValue ?? "",
                type: NavigationGroupType(rawValue: row.values[row.columnOrder[1]]?.textValue ?? "") ?? .burst,
                photoIds: photoIds,
                startAt: capturedByPhoto[photoIds[0]] ?? "",
                endAt: capturedByPhoto[photoIds[photoIds.count - 1]] ?? "",
                leadPhotoId: row.values[row.columnOrder[3]]?.textValue,
                explanation: row.values[row.columnOrder[4]]?.textValue ?? "",
                source: NavigationGroupSource(rawValue: row.values[row.columnOrder[5]]?.textValue ?? "") ?? .automatic
            )
        }
    }

    /// TS: split(sessionId, groupId, beforePhotoId)。
    public func split(sessionId: String, groupId: String, beforePhotoId: String) async throws -> [NavigationGroup] {
        let groups = try await list(sessionId: sessionId)
        guard let group = groups.first(where: { $0.id == groupId }) else {
            throw NavigationError.groupNotFound
        }
        let splitIndex = try NavigationAssembler.splitIndex(group: group, beforePhotoId: beforePhotoId)
        let rows = try await captureRows(sessionId: sessionId)
        let replacements = NavigationAssembler.splitReplacements(group: group, splitIndex: splitIndex, rows: rows)

        try await database.transaction { db in
            _ = try db.run(
                "DELETE FROM navigation_groups WHERE id = ? AND session_id = ?",
                [.text(groupId), .text(sessionId)]
            )
            for candidate in replacements {
                try insertGroup(db, sessionId: sessionId, group: candidate, source: .manual, fingerprint: "")
            }
        }
        return try await list(sessionId: sessionId)
    }

    /// TS: merge(sessionId, groupIds)。
    public func merge(sessionId: String, groupIds: [String]) async throws -> [NavigationGroup] {
        let uniqueIds = try NavigationAssembler.mergeUniqueIds(groupIds)
        let all = try await list(sessionId: sessionId)
        let selected = all.filter { uniqueIds.contains($0.id) }
        try NavigationAssembler.validateMergeSelection(uniqueIds: uniqueIds, selected: selected)
        let rows = try await captureRows(sessionId: sessionId)
        let merged = NavigationAssembler.mergedGroup(selected: selected, rows: rows)
        try await database.transaction { db in
            let placeholders = uniqueIds.map { _ in "?" }.joined(separator: ", ")
            _ = try db.run("""
                DELETE FROM navigation_groups
                WHERE session_id = ? AND id IN (\(placeholders))
            """, [.text(sessionId)] + uniqueIds.map(SQLiteValue.text))
            try insertGroup(db, sessionId: sessionId, group: merged, source: .manual, fingerprint: "")
        }
        return try await list(sessionId: sessionId)
    }

    // MARK: captureRows

    /// TS: captureRows —— 主查询 + 每 800 个 asset_file 一次 IN 查询的
    /// technical_quality 结果（每文件最新一条）。
    private func captureRows(sessionId: String) async throws -> [NavigationAssembler.CaptureRow] {
        let rows = try await database.query("""
            SELECT p.id, p.filepath, p.filename,
                COALESCE(NULLIF(pmc.date_taken, ''), p.created_at) AS captured_at,
                COALESCE(pmc.camera_model, '') AS camera_model,
                COALESCE(sh.hash_hex, '') AS hash_hex,
                COALESCE(pmc.rating, 0) AS rating,
                p.asset_file_id
            FROM photos p
            LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
            LEFT JOIN similarity_hashes sh ON sh.photo_id = p.id AND sh.session_id = p.session_id
            WHERE p.session_id = ? AND p.status != 'missing'
            ORDER BY captured_at, p.rowid
        """, [.text(sessionId)])

        let fileIds = Array(Set(rows.compactMap { $0.values[$0.columnOrder[7]]?.textValue }))
        var qualityByFile: [String: String] = [:]
        for offset in stride(from: 0, to: fileIds.count, by: Self.qualityChunkSize) {
            let chunk = Array(fileIds[offset..<min(offset + Self.qualityChunkSize, fileIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let analysisRows = try await database.query("""
                SELECT aa.asset_file_id, aa.result_json
                FROM asset_analysis aa
                WHERE aa.asset_file_id IN (\(placeholders)) AND aa.analysis_type = 'technical_quality'
                ORDER BY aa.asset_file_id, aa.updated_at DESC
            """, chunk.map(SQLiteValue.text))
            for row in analysisRows {
                if let fileId = row.values[row.columnOrder[0]]?.textValue, qualityByFile[fileId] == nil {
                    qualityByFile[fileId] = row.values[row.columnOrder[1]]?.textValue ?? ""
                }
            }
        }

        return rows.map { row in
            let qualityKey = row.values[row.columnOrder[7]]?.textValue
            let qualityJson = qualityKey != nil ? qualityByFile[qualityKey!] : nil
            let quality = NavigationAssembler.safeQuality(value: qualityJson)
            let rating = row.values[row.columnOrder[6]]?.intValue.map { Double($0) } ?? row.values[row.columnOrder[6]]?.doubleValue ?? 0
            return NavigationAssembler.CaptureRow(
                id: row.values[row.columnOrder[0]]?.textValue ?? "",
                filepath: row.values[row.columnOrder[1]]?.textValue ?? "",
                filename: row.values[row.columnOrder[2]]?.textValue ?? "",
                capturedAt: row.values[row.columnOrder[3]]?.textValue ?? "",
                cameraModel: row.values[row.columnOrder[4]]?.textValue ?? "",
                hashHex: row.values[row.columnOrder[5]]?.textValue ?? "",
                rating: rating,
                qualityScore: quality.qualityScore,
                qualityWarnings: quality.warnings,
                hasQuality: quality.hasQuality
            )
        }
    }

    /// TS: persistAutomatic —— manual 成员从自动组剔除（per type）。
    private func persistAutomatic(sessionId: String, groups: [NavigationGroup], fingerprint: String) async throws {
        let manualRows = try await database.query("""
            SELECT group_type, photo_ids_json FROM navigation_groups
            WHERE session_id = ? AND source = 'manual'
        """, [.text(sessionId)])
        var manuallyGrouped: [NavigationGroupType: Set<String>] = [:]
        for row in manualRows {
            guard let type = NavigationGroupType(rawValue: row.values[row.columnOrder[0]]?.textValue ?? ""),
                  let ids = NavigationAssembler.parsePhotoIds(row.values[row.columnOrder[1]]?.textValue ?? "")
            else { continue }
            manuallyGrouped[type, default: []].formUnion(ids)
        }
        var automaticGroups: [NavigationGroup] = []
        for group in groups {
            let photoIds = group.photoIds.filter { !(manuallyGrouped[group.type]?.contains($0) ?? false) }
            if photoIds.count >= 2 {
                // TS: { ...group, id: newUUID, photoIds } —— lead/explanation 保留。
                automaticGroups.append(NavigationGroup(
                    id: UUID().uuidString.lowercased(),
                    type: group.type,
                    photoIds: photoIds,
                    startAt: group.startAt,
                    endAt: group.endAt,
                    leadPhotoId: group.leadPhotoId,
                    explanation: group.explanation,
                    source: .automatic
                ))
            }
        }
        try await database.transaction { db in
            _ = try db.run(
                "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
                [.text(sessionId)]
            )
            for group in automaticGroups {
                try insertGroup(db, sessionId: sessionId, group: group, source: .automatic, fingerprint: fingerprint)
            }
        }
    }

    private func insertGroup(
        _ db: isolated SQLiteDatabase,
        sessionId: String,
        group: NavigationGroup,
        source: NavigationGroupSource,
        fingerprint: String
    ) throws {
        let now = Self.nowISO()
        _ = try db.run("""
            INSERT INTO navigation_groups (
                id, session_id, group_type, photo_ids_json, lead_photo_id,
                explanation, input_fingerprint, source, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(group.id),
            .text(sessionId),
            .text(group.type.rawValue),
            .text(NavigationAssembler.photoIdsJSON(group.photoIds)),
            group.leadPhotoId.map(SQLiteValue.text) ?? .null,
            .text(group.explanation),
            .text(fingerprint),
            .text(source.rawValue),
            .text(now),
            .text(now),
        ])
    }

    // MARK: 指纹

    private static func cachedFingerprint(database: SQLiteDatabase, sessionId: String) async throws -> String? {
        guard let row = try await database.queryOne("""
            SELECT input_fingerprint FROM navigation_groups
            WHERE session_id = ? AND source = 'automatic' LIMIT 1
        """, [.text(sessionId)]) else { return nil }
        return row.values[row.columnOrder[0]]?.textValue
    }
}

private extension NavigationService {
    static func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

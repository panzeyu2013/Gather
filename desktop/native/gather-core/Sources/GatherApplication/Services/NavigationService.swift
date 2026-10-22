// desktop/native/gather-core/Sources/GatherDomain/Services/NavigationService.swift
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
//   - crypto.createHash('sha256') → GatherPersistence SHA256（SHA256.swift 纯
//     Swift 实现，FIPS 180-4，Linux 兼容）
//   - path.basename/dirname → URL 处理；Date.parse → ISO8601DateFormatter
//   - 无 worker：captureRows 单次查询 + IN chunk 800 一致
import Foundation
import GatherPersistence
import GatherProtocol

// MARK: - 参数校验

/// TS: validateNavigationParameters —— 参数非法抛错。
public func validateNavigationParameters(burstGapSeconds: Double, sceneGapSeconds: Double) throws {
    if !burstGapSeconds.isFinite || burstGapSeconds < 0.1 || burstGapSeconds > 300 {
        throw NavigationError.burstGapInvalid
    }
    if !sceneGapSeconds.isFinite || sceneGapSeconds < burstGapSeconds || sceneGapSeconds > 86_400 {
        throw NavigationError.sceneGapInvalid
    }
}

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

// MARK: - 内部行类型

/// TS: CaptureRow。
private struct CaptureRow {
    let id: String
    let filepath: String
    let filename: String
    let capturedAt: String
    let cameraModel: String
    let hashHex: String
    let rating: Double
    let qualityScore: Double
    let qualityWarnings: [String]
    let hasQuality: Bool
}

// MARK: - 服务

public final class NavigationService {
    /// TS: IN chunk 800（quality 查询）。
    private static let qualityChunkSize = 800

    private let navigationRepo: any NavigationRepository

    public init(navigationRepo: any NavigationRepository) {
        self.navigationRepo = navigationRepo
    }

    // MARK: API

    /// TS: analyze(sessionId, burstGapSeconds=2, sceneGapSeconds=1800, dryRun=false)。
    public func analyze(
        sessionId: String,
        burstGapSeconds: Double = 2,
        sceneGapSeconds: Double = 1_800,
        dryRun: Bool = false
    ) throws -> [NavigationGroup] {
        try validateNavigationParameters(burstGapSeconds: burstGapSeconds, sceneGapSeconds: sceneGapSeconds)
        let rows = try captureRows(sessionId: sessionId)
        let capturedAt = Dictionary(rows.map { ($0.id, $0.capturedAt) }, uniquingKeysWith: { first, _ in first })
        let fingerprint = fingerprintHash(burst: burstGapSeconds, scene: sceneGapSeconds, rows: rows)

        if !dryRun {
            let cached = try list(sessionId: sessionId, capturedAt: capturedAt)
            let cachedFingerprint = try navigationRepo.cachedFingerprint(sessionId: sessionId)
            if !cached.isEmpty && cachedFingerprint == fingerprint {
                return cached
            }
        }

        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = (
            group(rows: rows, type: .burst, gapSeconds: burstGapSeconds)
                + group(rows: rows, type: .scene, gapSeconds: sceneGapSeconds)
        ).map { withLead(group: $0, byId: byId) }

        if !dryRun {
            try persistAutomatic(sessionId: sessionId, groups: groups, fingerprint: fingerprint)
            return try list(sessionId: sessionId, capturedAt: capturedAt)
        }
        return groups
    }

    /// TS: list(sessionId, capturedAt?) —— 组 <2 张被过滤。
    public func list(sessionId: String, capturedAt: [String: String]? = nil) throws -> [NavigationGroup] {
        let rows = try navigationRepo.listGroups(sessionId: sessionId)

        let capturedByPhoto: [String: String]
        if let capturedAt {
            capturedByPhoto = capturedAt
        } else {
            capturedByPhoto = Dictionary(
                (try captureRows(sessionId: sessionId)).map { ($0.id, $0.capturedAt) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return rows.compactMap { row -> NavigationGroup? in
            guard let photoIds = parsePhotoIds(row.photoIdsJSON),
                  photoIds.count >= 2
            else { return nil }
            return NavigationGroup(
                id: row.id,
                type: NavigationGroupType(rawValue: row.type) ?? .burst,
                photoIds: photoIds,
                startAt: capturedByPhoto[photoIds[0]] ?? "",
                endAt: capturedByPhoto[photoIds[photoIds.count - 1]] ?? "",
                leadPhotoId: row.leadPhotoId,
                explanation: row.explanation,
                source: NavigationGroupSource(rawValue: row.source) ?? .automatic
            )
        }
    }

    /// TS: split(sessionId, groupId, beforePhotoId)。
    public func split(sessionId: String, groupId: String, beforePhotoId: String) throws -> [NavigationGroup] {
        let groups = try list(sessionId: sessionId)
        guard let group = groups.first(where: { $0.id == groupId }) else {
            throw NavigationError.groupNotFound
        }
        let splitIndex = group.photoIds.firstIndex(of: beforePhotoId) ?? -1
        if splitIndex <= 0 || splitIndex >= group.photoIds.count {
            throw NavigationError.splitOutOfGroup
        }
        let rows = try captureRows(sessionId: sessionId)
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replacements = [
            NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: group.type,
                photoIds: Array(group.photoIds[0..<splitIndex]),
                startAt: group.startAt,
                endAt: group.endAt,
                explanation: group.explanation,
                source: .manual
            ),
            NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: group.type,
                photoIds: Array(group.photoIds[splitIndex..<group.photoIds.count]),
                startAt: group.startAt,
                endAt: group.endAt,
                explanation: group.explanation,
                source: .manual
            ),
        ].map { withLead(group: $0, byId: byId) }

        try navigationRepo.replaceGroup(
            sessionId: sessionId,
            groupId: groupId,
            with: replacements.map { write($0, source: .manual, fingerprint: "") }
        )
        return try list(sessionId: sessionId)
    }

    /// TS: merge(sessionId, groupIds)。
    public func merge(sessionId: String, groupIds: [String]) throws -> [NavigationGroup] {
        let uniqueIds = Array(Set(groupIds))
        if uniqueIds.count < 2 {
            throw NavigationError.mergeMinTwo
        }
        let all = try list(sessionId: sessionId)
        let selected = all.filter { uniqueIds.contains($0.id) }
        if selected.count != uniqueIds.count {
            throw NavigationError.groupNotFound
        }
        if Set(selected.map { $0.type }).count != 1 {
            throw NavigationError.mergeTypeMismatch
        }
        let rows = try captureRows(sessionId: sessionId)
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let photoIds = Array(Set(selected.flatMap { $0.photoIds }))
            .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        let merged = withLead(
            group: NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: selected[0].type,
                photoIds: photoIds,
                startAt: "",
                endAt: "",
                explanation: "",
                source: .manual
            ),
            byId: byId
        )
        try navigationRepo.mergeGroups(
            sessionId: sessionId,
            groupIds: uniqueIds,
            into: write(merged, source: .manual, fingerprint: "")
        )
        return try list(sessionId: sessionId)
    }

    // MARK: captureRows

    /// TS: captureRows —— 主查询 + 每 800 个 asset_file 一次 IN 查询的
    /// technical_quality 结果（每文件最新一条）。
    private func captureRows(sessionId: String) throws -> [CaptureRow] {
        try navigationRepo.captureRows(sessionId: sessionId).map { row in
            let quality = safeQuality(value: row.qualityJSON)
            return CaptureRow(
                id: row.id,
                filepath: row.filepath,
                filename: row.filename,
                capturedAt: row.capturedAt,
                cameraModel: row.cameraModel,
                hashHex: row.hashHex,
                rating: row.rating,
                qualityScore: quality.qualityScore,
                qualityWarnings: quality.warnings,
                hasQuality: quality.hasQuality
            )
        }
    }

    /// TS: safeQuality —— result_json 解析；status != 'failed' 且有 qualityScore
    /// 才算 hasQuality。
    private func safeQuality(value: String?) -> (qualityScore: Double, warnings: [String], hasQuality: Bool) {
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (0, [], false)
        }
        let score = (object["qualityScore"] as? NSNumber)?.doubleValue ?? 0
        let warnings = (object["warnings"] as? [Any])?.compactMap { $0 as? String } ?? []
        let status = object["status"] as? String
        let hasQuality = status != "failed" && (object["qualityScore"] as? NSNumber) != nil
        return (score, warnings, hasQuality)
    }

    // MARK: 分组

    /// TS: group —— 顺序扫描 + 边界判定（见文件头红线）。
    private func group(rows: [CaptureRow], type: NavigationGroupType, gapSeconds: Double) -> [NavigationGroup] {
        var groups: [NavigationGroup] = []
        var current: [CaptureRow] = []
        let flush = {
            if current.count >= 2 {
                groups.append(NavigationGroup(
                    id: UUID().uuidString.lowercased(),
                    type: type,
                    photoIds: current.map { $0.id },
                    startAt: current[0].capturedAt,
                    endAt: current[current.count - 1].capturedAt,
                    explanation: "",
                    source: .automatic
                ))
            }
            current = []
        }
        for row in rows {
            let previous = current.last
            let gap = previous.map { (parseISODate(row.capturedAt) - parseISODate($0.capturedAt)) / 1000 } ?? 0
            let directoryChanged = previous.map { dirname($0.filepath) != dirname(row.filepath) } ?? false
            let sameCamera = previous == nil || previous!.cameraModel.isEmpty || row.cameraModel.isEmpty
                || previous!.cameraModel == row.cameraModel
            let previousSequence = previous.flatMap { filenameSequence($0.filename) }
            let currentSequence = filenameSequence(row.filename)
            let sequential = previousSequence == nil || currentSequence == nil
                || (currentSequence! > previousSequence! && currentSequence! - previousSequence! <= 3)
            let visualDistance = previous.flatMap { hammingDistance($0.hashHex, row.hashHex) }
            let visuallyRelated = visualDistance == nil || visualDistance! <= (type == .burst ? 14 : 24)
            let boundary = previous != nil && (
                !gap.isFinite ||
                gap < 0 ||
                gap > gapSeconds ||
                !sameCamera ||
                (type == .burst && (!sequential || !visuallyRelated)) ||
                (type == .scene && (directoryChanged || !visuallyRelated))
            )
            if boundary { flush() }
            current.append(row)
        }
        flush()
        return groups
    }

    /// TS: withLead —— 见文件头红线。
    private func withLead(group: NavigationGroup, byId: [String: CaptureRow]) -> NavigationGroup {
        let hasAnyQuality = group.photoIds.contains { byId[$0]?.hasQuality == true }
        let ranked = group.photoIds
            .compactMap { byId[$0] }
            .sorted { left, right in
                if !hasAnyQuality { return left.rating > right.rating }
                let hasClosedEyeRisk: ([String]) -> Bool = { warnings in
                    warnings.contains("closed_eye_risk_heuristic") || warnings.contains("closed_eye_risk")
                }
                let leftPenalty = hasClosedEyeRisk(left.qualityWarnings) ? 0.25 : 0
                let rightPenalty = hasClosedEyeRisk(right.qualityWarnings) ? 0.25 : 0
                // TS: (right.score + right.rating*0.08 - rightPenalty) -
                //      (left.score + left.rating*0.08 - leftPenalty) —— 降序。
                return (left.qualityScore + left.rating * 0.08 - leftPenalty)
                    > (right.qualityScore + right.rating * 0.08 - rightPenalty)
            }
        let lead = ranked.first
        let explanation: String
        if lead != nil && hasAnyQuality {
            explanation = "NAV_RECOMMEND_QUALITY"
        } else if let lead, lead.rating > 0 {
            explanation = "NAV_RECOMMEND_RATING"
        } else {
            explanation = "NAV_RECOMMEND_ORDER"
        }
        return NavigationGroup(
            id: group.id,
            type: group.type,
            photoIds: group.photoIds,
            startAt: byId[group.photoIds[0]]?.capturedAt ?? group.startAt,
            endAt: byId[group.photoIds[group.photoIds.count - 1]]?.capturedAt ?? group.endAt,
            leadPhotoId: lead?.id,
            explanation: explanation,
            source: group.source
        )
    }

    /// TS: persistAutomatic —— manual 成员从自动组剔除（per type）。
    private func persistAutomatic(sessionId: String, groups: [NavigationGroup], fingerprint: String) throws {
        let manualRows = try navigationRepo.manualGroups(sessionId: sessionId)
        var manuallyGrouped: [NavigationGroupType: Set<String>] = [:]
        for row in manualRows {
            guard let type = NavigationGroupType(rawValue: row.type),
                  let ids = parsePhotoIds(row.photoIdsJSON)
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
        try navigationRepo.replaceAutomaticGroups(
            sessionId: sessionId,
            groups: automaticGroups.map { write($0, source: .automatic, fingerprint: fingerprint) }
        )
    }

    /// NavigationGroup → 仓储写入载荷（JSON 编码在 Persistence）。
    private func write(
        _ group: NavigationGroup,
        source: NavigationGroupSource,
        fingerprint: String
    ) -> NavigationGroupWrite {
        NavigationGroupWrite(
            id: group.id,
            type: group.type.rawValue,
            photoIds: group.photoIds,
            leadPhotoId: group.leadPhotoId,
            explanation: group.explanation,
            source: source.rawValue,
            fingerprint: fingerprint
        )
    }

    // MARK: 指纹

    /// TS: sha256(JSON.stringify([...]))。
    private func fingerprintHash(burst: Double, scene: Double, rows: [CaptureRow]) -> String {
        let payload: [Any] = [
            burst,
            scene,
            rows.map { row -> [Any] in
                [
                    row.id,
                    row.capturedAt,
                    row.hashHex,
                    row.rating,
                    row.qualityScore,
                    row.qualityWarnings.sorted(),
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return SHA256.hash(Data(data)).map { String(format: "%02x", $0) }.joined()
    }


}

// MARK: - 纯函数（对账友好，独立测试）

/// TS: filenameSequence —— 文件名尾部数字序列（无数字 → nil）。
func filenameSequence(_ filename: String) -> Int? {
    let basename = (filename as NSString).deletingPathExtension
    let pattern = #"(\d+)(?!.*\d)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: basename, range: NSRange(location: 0, length: (basename as NSString).length))
    else { return nil }
    let range = match.range(at: 1)
    return Int((basename as NSString).substring(with: range))
}

/// TS: hammingDistance —— 16 位 hex 的汉明距离（popcount）。
func hammingDistance(_ left: String, _ right: String) -> Int? {
    if left.isEmpty || right.isEmpty || left.count != right.count { return nil }
    guard let a = UInt64(left, radix: 16), let b = UInt64(right, radix: 16) else { return nil }
    return (a ^ b).nonzeroBitCount
}

/// TS: path.dirname。
func dirname(_ path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

/// TS: Date.parse(ISO string) → 毫秒时间戳。
func parseISODate(_ value: String) -> Double {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date.timeIntervalSince1970 * 1000
    }
    let formatter2 = ISO8601DateFormatter()
    if let date = formatter2.date(from: value) {
        return date.timeIntervalSince1970 * 1000
    }
    return Double.nan
}

private func parsePhotoIds(_ json: String) -> [String]? {
    guard let data = json.data(using: .utf8),
          let ids = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return nil }
    return ids
}

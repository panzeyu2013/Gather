// desktop/native/gather-core/Sources/GatherCore/Runtime/Navigation/NavigationRuntime.swift
// W2d 小步②：NavigationRuntime actor —— Services/NavigationService.swift 的查询/持久化
// 装配层下沉（纯逻辑已在 W2d 小步① 的 NavigationAssembler.swift）。
//
// 边界（设计文档 §0 门禁）：
// - 本文件只依赖 Store/NavigationStore.swift 的 NavigationStore 协议，不出现 SQL 文本、
//   SQLiteDatabase、NSLock 或 @unchecked Sendable；纯计算一律调用 NavigationAssembler。
// - 错误类型 NavigationError 仍由 Services/NavigationService.swift 声明（命名纪律：旧服务
//   文件删除前不新建公开错误类型），本文件仅引用其 case。
// - NAV_* 错误码与抛出顺序与 NavigationService 对应方法逐条一致：
//     split：先 NAV_GROUP_NOT_FOUND（组不存在），后 NAV_SPLIT_OUT_OF_GROUP（越界，查询前判定）
//     merge：先 NAV_MERGE_MIN_TWO（去重 <2），后 NAV_GROUP_NOT_FOUND，再 NAV_MERGE_TYPE_MISMATCH
//     analyze：先 NAV_BURST_GAP_INVALID / NAV_SCENE_GAP_INVALID，再查询
// - 事务边界：Store 协议未提供跨语句事务，split/merge 的 delete + insert 与
//   analyze 的 replaceAutomaticGroups 均按 Store 能力顺序调用；原子性由 Store 实现负责。
import Foundation

/// 导航运行时：actor 串行化 navigation 的查询与持久化装配。
public actor NavigationRuntime {
    /// 依赖：唯一持久化入口（NavigationStore）。
    public struct Dependencies: Sendable {
        public let store: any NavigationStore

        public init(store: any NavigationStore) {
            self.store = store
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public init(store: any NavigationStore) {
        self.dependencies = Dependencies(store: store)
    }

    private var store: any NavigationStore { dependencies.store }

    // MARK: - list

    /// TS: list(sessionId, capturedAt?) —— 组 <2 张被过滤。
    public func list(sessionId: String, capturedAt: [String: String]? = nil) async throws -> [NavigationGroup] {
        let records = try await store.groups(sessionId: sessionId)

        let capturedByPhoto: [String: String]
        if let capturedAt {
            capturedByPhoto = capturedAt
        } else {
            let rows = try await captureRows(sessionId: sessionId)
            capturedByPhoto = Dictionary(
                rows.map { ($0.id, $0.capturedAt) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        return records.compactMap { record -> NavigationGroup? in
            let photoIds = record.photoIds
            guard photoIds.count >= 2 else { return nil }
            return NavigationGroup(
                id: record.id,
                type: NavigationGroupType(rawValue: record.groupType) ?? .burst,
                photoIds: photoIds,
                startAt: capturedByPhoto[photoIds[0]] ?? "",
                endAt: capturedByPhoto[photoIds[photoIds.count - 1]] ?? "",
                leadPhotoId: record.leadPhotoId,
                explanation: record.explanation,
                source: NavigationGroupSource(rawValue: record.source) ?? .automatic
            )
        }
    }

    // MARK: - split

    /// TS: split(sessionId, groupId, beforePhotoId)。
    public func split(sessionId: String, groupId: String, beforePhotoId: String) async throws -> [NavigationGroup] {
        let groups = try await list(sessionId: sessionId)
        guard let group = groups.first(where: { $0.id == groupId }) else {
            throw NavigationError.groupNotFound
        }
        let splitIndex = try NavigationAssembler.splitIndex(group: group, beforePhotoId: beforePhotoId)
        return try await split(group: group, splitIndex: splitIndex, sessionId: sessionId)
    }

    /// 按切分下标 split：越界（<=0 或 >= 张数）抛 NAV_SPLIT_OUT_OF_GROUP。
    public func split(sessionId: String, groupId: String, atIndex splitIndex: Int) async throws -> [NavigationGroup] {
        let groups = try await list(sessionId: sessionId)
        guard let group = groups.first(where: { $0.id == groupId }) else {
            throw NavigationError.groupNotFound
        }
        if splitIndex <= 0 || splitIndex >= group.photoIds.count {
            throw NavigationError.splitOutOfGroup
        }
        return try await split(group: group, splitIndex: splitIndex, sessionId: sessionId)
    }

    /// split 公共尾部：两个新 manual 组 + 重算 lead + 替换旧组 + 回读。
    private func split(group: NavigationGroup, splitIndex: Int, sessionId: String) async throws -> [NavigationGroup] {
        let rows = try await captureRows(sessionId: sessionId)
        let replacements = NavigationAssembler.splitReplacements(group: group, splitIndex: splitIndex, rows: rows)
        try await store.deleteGroup(sessionId: sessionId, id: group.id)
        for candidate in replacements {
            try await store.insertGroup(
                sessionId: sessionId,
                group: Self.insert(group: candidate, source: .manual, fingerprint: "")
            )
        }
        return try await list(sessionId: sessionId)
    }

    // MARK: - merge

    /// TS: merge(sessionId, groupIds)。
    public func merge(sessionId: String, groupIds: [String]) async throws -> [NavigationGroup] {
        let uniqueIds = try NavigationAssembler.mergeUniqueIds(groupIds)
        let all = try await list(sessionId: sessionId)
        let selected = all.filter { uniqueIds.contains($0.id) }
        try NavigationAssembler.validateMergeSelection(uniqueIds: uniqueIds, selected: selected)
        let rows = try await captureRows(sessionId: sessionId)
        let merged = NavigationAssembler.mergedGroup(selected: selected, rows: rows)
        try await store.deleteGroups(sessionId: sessionId, ids: uniqueIds)
        try await store.insertGroup(
            sessionId: sessionId,
            group: Self.insert(group: merged, source: .manual, fingerprint: "")
        )
        return try await list(sessionId: sessionId)
    }

    // MARK: - analyze

    /// TS: analyze(sessionId, burstGapSeconds=2, sceneGapSeconds=1800, dryRun=false)。
    public func analyze(
        sessionId: String,
        burstGapSeconds: Double = 2,
        sceneGapSeconds: Double = 1_800,
        dryRun: Bool = false
    ) async throws -> [NavigationGroup] {
        try NavigationAssembler.validateNavigationParameters(
            burstGapSeconds: burstGapSeconds,
            sceneGapSeconds: sceneGapSeconds
        )
        let rows = try await captureRows(sessionId: sessionId)
        let capturedAt = Dictionary(rows.map { ($0.id, $0.capturedAt) }, uniquingKeysWith: { first, _ in first })
        let fingerprint = NavigationAssembler.fingerprintHash(burst: burstGapSeconds, scene: sceneGapSeconds, rows: rows)

        if !dryRun {
            let cached = try await list(sessionId: sessionId, capturedAt: capturedAt)
            let cachedFingerprint = try await store.cachedFingerprint(sessionId: sessionId)
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

    /// 便捷重载：gapSeconds 作为 burst 间隔（scene 沿用服务默认 1800）。
    public func analyze(sessionId: String, gapSeconds: Double, dryRun: Bool = false) async throws -> [NavigationGroup] {
        try await analyze(
            sessionId: sessionId,
            burstGapSeconds: gapSeconds,
            sceneGapSeconds: 1_800,
            dryRun: dryRun
        )
    }

    // MARK: - captureRows

    /// Store 拍摄行 → Assembler 行（quality JSON 解析在纯逻辑层）。
    private func captureRows(sessionId: String) async throws -> [NavigationAssembler.CaptureRow] {
        let rows = try await store.captureRows(sessionId: sessionId)
        return rows.map { row in
            let quality = NavigationAssembler.safeQuality(value: row.qualityJSON)
            return NavigationAssembler.CaptureRow(
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

    /// TS: persistAutomatic —— manual 成员从自动组剔除（per type）。
    private func persistAutomatic(sessionId: String, groups: [NavigationGroup], fingerprint: String) async throws {
        let manualRecords = try await store.manualGroups(sessionId: sessionId)
        var manuallyGrouped: [NavigationGroupType: Set<String>] = [:]
        for record in manualRecords {
            guard let type = NavigationGroupType(rawValue: record.groupType) else { continue }
            manuallyGrouped[type, default: []].formUnion(record.photoIds)
        }

        var automaticGroups: [NavigationGroupInsert] = []
        for group in groups {
            let photoIds = group.photoIds.filter { !(manuallyGrouped[group.type]?.contains($0) ?? false) }
            guard photoIds.count >= 2 else { continue }
            // TS: { ...group, id: newUUID, photoIds } —— lead/explanation 保留。
            automaticGroups.append(Self.insert(
                group: NavigationGroup(
                    id: UUID().uuidString.lowercased(),
                    type: group.type,
                    photoIds: photoIds,
                    startAt: group.startAt,
                    endAt: group.endAt,
                    leadPhotoId: group.leadPhotoId,
                    explanation: group.explanation,
                    source: .automatic
                ),
                source: .automatic,
                fingerprint: fingerprint
            ))
        }
        try await store.replaceAutomaticGroups(
            sessionId: sessionId,
            groups: automaticGroups,
            fingerprint: fingerprint
        )
    }

    // MARK: - 边界转换

    private static func insert(
        group: NavigationGroup,
        source: NavigationGroupSource,
        fingerprint: String
    ) -> NavigationGroupInsert {
        NavigationGroupInsert(
            id: group.id,
            groupType: group.type.rawValue,
            photoIdsJSON: NavigationAssembler.photoIdsJSON(group.photoIds),
            leadPhotoId: group.leadPhotoId,
            explanation: group.explanation,
            source: source.rawValue,
            fingerprint: fingerprint
        )
    }
}

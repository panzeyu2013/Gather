// desktop/native/gather-core/Sources/GatherApplication/Services/CurationService.swift
// P1 下一波 §3.8（策展容器）：集合 / 堆栈 / 跨工作区重复的业务编排。
//
// 分层与职责：
// - SQL 全在 GatherPersistence（CollectionRepo / StackRepo / GlobalDuplicateQuery），
//   本服务**不含任何 SQL**（check-cleanup-ratchet 的 services_prepare 预算 = 0）；
// - 本服务负责：参数与存在性校验、错误码映射（沿用既有码，不新增全局码）、
//   一照一堆栈的收敛、跨工作区重复的分组拼装与内存缓存。
//
// 错误码（全部是既有码，见 GatherErrorCode）：
//   SESSION_NOT_FOUND  会话不存在
//   ALBUM_NOT_FOUND    集合 / 堆栈不存在（同一"容器找不到"语义，params 区分）
//   PHOTO_NOT_FOUND    照片不在该会话（含跨会话误加）
//   INVALID_PARAM      名称空白/冲突、空照片集、阈值越界（params: field/reason）
//
// 并发模型：struct + 不可变仓储（DBConnection 自带递归锁）+ OSAllocatedUnfairLock
// 保护的缓存盒 ⇒ 自动 Sendable，不新增 @unchecked Sendable 预算。
import Foundation
import os
import GatherProtocol
import GatherPersistence

/// 策展域错误（CodedError：码即类型，与 NavigationError 同构）。
public enum CurationError: Error, CustomStringConvertible, CodedError {
    case sessionNotFound
    case collectionNotFound(String)
    case stackNotFound(String)
    case photoNotFound(String)
    case nameConflict(String)
    case invalidName(String)
    case emptyPhotos
    case invalidThreshold(Int)
    case invalidLimit(Int)

    public var code: GatherErrorCode {
        switch self {
        case .sessionNotFound: return .SESSION_NOT_FOUND
        case .collectionNotFound, .stackNotFound: return .ALBUM_NOT_FOUND
        case .photoNotFound: return .PHOTO_NOT_FOUND
        case .nameConflict, .invalidName, .emptyPhotos, .invalidThreshold, .invalidLimit:
            return .INVALID_PARAM
        }
    }

    /// 上屏参数（GatherError 的 {{detail}}/字段插值位）。
    public var params: [String: String] {
        switch self {
        case .sessionNotFound:
            return [:]
        case .collectionNotFound(let id):
            return ["collectionId": id]
        case .stackNotFound(let id):
            return ["stackId": id]
        case .photoNotFound(let id):
            return ["photoId": id]
        case .nameConflict(let name):
            return ["field": "name", "reason": "duplicate", "name": name]
        case .invalidName(let reason):
            return ["field": "name", "reason": reason]
        case .emptyPhotos:
            return ["field": "photoIds", "reason": "must not be empty"]
        case .invalidThreshold(let value):
            return ["field": "visualThreshold", "reason": "must be 0...14, got \(value)"]
        case .invalidLimit(let value):
            return ["field": "maxGroupCount", "reason": "must be 1...500, got \(value)"]
        }
    }

    public var description: String { code.rawValue }
}

/// 名称约束（集合名 / 堆栈名共用；去空白后 1...200 字符）。
public enum CurationNaming {
    public static let maxLength = 200

    /// 去空白；空白或超长时抛 CurationError。
    public static func normalized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else {
            throw CurationError.invalidName("must be 1...\(maxLength) characters")
        }
        return trimmed
    }
}

public struct CurationService: Sendable {
    // 无 @unchecked：四个仓储都是值类型、只包一个线程安全的 DBConnection
    // （Persistence 层既定约定），本类型自身没有可变状态；唯一的缓存由
    // OSAllocatedUnfairLock 保护。
    private let collections: CollectionRepo
    private let stacks: StackRepo
    private let duplicates: GlobalDuplicateQuery
    // 不持有 SessionRepo（非 Sendable 的 final class）：会话存在性走
    // CollectionRepo.sessionExists，从而保持本类型是**普通** Sendable，
    // 不占用 @unchecked Sendable 的 cleanup ratchet 预算。
    private let cache: OSAllocatedUnfairLock<GlobalDuplicateCache>

    /// 跨工作区重复的内存缓存（设计 §3.8.3：不新增表；失效由写路径/手动触发）。
    struct GlobalDuplicateCache: Sendable {
        var result: GlobalDuplicateScanResult?
        var computedAt: Date?
    }

    /// 缓存有效期（秒）：5 分钟。超期后下次读取重扫（扫描本身是只读 SQL + 纯计算）。
    public static let globalDuplicateCacheTTL: TimeInterval = 300

    public init(connection: DBConnection) {
        self.collections = CollectionRepo(connection: connection)
        self.stacks = StackRepo(connection: connection)
        self.duplicates = GlobalDuplicateQuery(connection: connection)
        self.cache = OSAllocatedUnfairLock(initialState: GlobalDuplicateCache())
    }

    // MARK: - 集合

    public func listCollections(sessionId: String) throws -> [CollectionSummary] {
        try requireSession(sessionId)
        return try collections.list(sessionId: sessionId).map(Self.summary)
    }

    public func createCollection(_ input: CollectionCreateInput) throws -> CollectionSummary {
        try requireSession(input.sessionId)
        let name = try CurationNaming.normalized(input.name)
        guard try !collections.nameExists(sessionId: input.sessionId, name: name) else {
            throw CurationError.nameConflict(name)
        }
        let sortOrder = try collections.nextSortOrder(sessionId: input.sessionId)
        let row = try collections.create(
            sessionId: input.sessionId, name: name, sortOrder: sortOrder
        )
        return Self.summary(row)
    }

    public func renameCollection(_ input: CollectionRenameInput) throws {
        let row = try requireCollection(input.collectionId)
        let name = try CurationNaming.normalized(input.name)
        guard try !collections.nameExists(
            sessionId: row.sessionId, name: name, excluding: row.id
        ) else {
            throw CurationError.nameConflict(name)
        }
        guard try collections.rename(id: row.id, name: name) else {
            throw CurationError.collectionNotFound(row.id)
        }
    }

    public func deleteCollection(id: String) throws {
        _ = try requireCollection(id)
        guard try collections.delete(id: id) else {
            throw CurationError.collectionNotFound(id)
        }
    }

    /// 集合成员（按 position；携带 filepath/filename 供网格直接渲染，避免二次查询）。
    public func collectionItems(collectionId: String) throws -> [CollectionMember] {
        _ = try requireCollection(collectionId)
        return try collections.items(collectionId: collectionId).map { item in
            CollectionMember(
                photoId: item.photoId,
                position: item.position,
                filepath: item.filepath,
                filename: item.filename
            )
        }
    }

    /// 尾部追加：返回新增条数（已在集合内的照片跳过）。
    @discardableResult
    public func addCollectionItems(_ input: CollectionItemsInput) throws -> Int {
        let row = try requireCollection(input.collectionId)
        let photoIds = try requirePhotos(sessionId: row.sessionId, photoIds: input.photoIds)
        let inserted = try collections.appendItems(
            collectionId: row.id, photoIds: photoIds
        )
        return inserted
    }

    @discardableResult
    public func removeCollectionItems(_ input: CollectionItemsInput) throws -> Int {
        let row = try requireCollection(input.collectionId)
        try requirePhotoIds(input.photoIds)
        return try collections.removeItems(collectionId: row.id, photoIds: input.photoIds)
    }

    /// 显式顺序（1..n，事务内一次完成）。
    public func reorderCollectionItems(_ input: CollectionReorderInput) throws {
        let row = try requireCollection(input.collectionId)
        try requirePhotoIds(input.photoIds)
        let written = try collections.reorderItems(
            collectionId: row.id, orderedPhotoIds: input.photoIds
        )
        guard written > 0 else { throw CurationError.collectionNotFound(row.id) }
    }

    /// 单行拖拽（正常只写 1 行；间隙耗尽时事务内重排）。
    public func moveCollectionItem(_ input: CollectionMoveInput) throws {
        let row = try requireCollection(input.collectionId)
        let moved = try collections.moveItem(
            collectionId: row.id,
            photoId: input.photoId,
            afterPhotoId: input.afterPhotoId,
            beforePhotoId: input.beforePhotoId
        )
        guard moved else {
            throw CurationError.photoNotFound(input.photoId)
        }
    }

    // MARK: - 堆栈

    public func listStacks(sessionId: String) throws -> [StackSummary] {
        try requireSession(sessionId)
        return try stacks.list(sessionId: sessionId).map(Self.summary)
    }

    public func stackMembers(stackId: String) throws -> [CollectionMember] {
        _ = try requireStack(stackId)
        return try stacks.members(stackId: stackId).map { member in
            CollectionMember(photoId: member.photoId, position: member.position)
        }
    }

    /// 折叠视图（网格用；只影响展示）。
    public func stackFolds(sessionId: String) throws -> [StackFold] {
        try requireSession(sessionId)
        return try stacks.folds(sessionId: sessionId)
    }

    /// 建堆栈：先把目标照片从既有堆栈里摘掉（一照一堆栈），再建新堆栈。
    ///
    /// coverPhotoId 必须属于 photoIds，否则 PHOTO_NOT_FOUND。
    public func createStack(_ input: StackCreateInput) throws -> StackSummary {
        try requireSession(input.sessionId)
        let photoIds = try requirePhotos(sessionId: input.sessionId, photoIds: input.photoIds)
        guard photoIds.count >= 2 else { throw CurationError.emptyPhotos }
        if let cover = input.coverPhotoId, !photoIds.contains(cover) {
            throw CurationError.photoNotFound(cover)
        }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = name.isEmpty ? "" : try CurationNaming.normalized(name)
        _ = try stacks.detachPhotos(photoIds: photoIds)
        let row = try stacks.create(
            sessionId: input.sessionId,
            name: normalized,
            coverPhotoId: input.coverPhotoId,
            photoIds: photoIds
        )
        return Self.summary(row)
    }

    public func updateStack(_ input: StackUpdateInput) throws {
        let row = try requireStack(input.stackId)
        var name: String?
        if let raw = input.name {
            name = try CurationNaming.normalized(raw)
        }
        if let cover = input.coverPhotoId {
            guard try stacks.members(stackId: row.id).contains(where: { $0.photoId == cover }) else {
                throw CurationError.photoNotFound(cover)
            }
        }
        guard try stacks.update(
            id: row.id,
            name: name,
            coverPhotoId: input.coverPhotoId,
            clearCover: input.clearCover
        ) else {
            throw CurationError.stackNotFound(row.id)
        }
    }

    public func deleteStack(id: String) throws {
        _ = try requireStack(id)
        guard try stacks.delete(id: id) else {
            throw CurationError.stackNotFound(id)
        }
    }

    @discardableResult
    public func addStackMembers(_ input: StackMembersInput) throws -> Int {
        let row = try requireStack(input.stackId)
        let photoIds = try requirePhotos(sessionId: row.sessionId, photoIds: input.photoIds)
        _ = try stacks.detachPhotos(photoIds: photoIds)
        return try stacks.addMembers(stackId: row.id, photoIds: photoIds)
    }

    @discardableResult
    public func removeStackMembers(_ input: StackMembersInput) throws -> Int {
        let row = try requireStack(input.stackId)
        try requirePhotoIds(input.photoIds)
        let removed = try stacks.removeMembers(stackId: row.id, photoIds: input.photoIds)
        // 成员被摘空的堆栈不留壳（与 detachPhotos 语义一致）。
        if try stacks.members(stackId: row.id).isEmpty {
            _ = try stacks.delete(id: row.id)
        }
        return removed
    }

    // MARK: - 跨工作区重复（只读）

    /// 扫描跨工作区重复/相似。可取消：每完成一个阶段检查一次，取消时抛 CancellationError。
    ///
    /// 结果按 (includeVisual, threshold, limit) 无关的整体缓存：读面只此一份，
    /// 失效由 invalidateGlobalDuplicateCache() 或 TTL 触发。
    public func scanGlobalDuplicates(
        _ input: GlobalDuplicateScanInput,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> GlobalDuplicateScanResult {
        guard (0...14).contains(input.visualThreshold) else {
            throw CurationError.invalidThreshold(input.visualThreshold)
        }
        guard (1...500).contains(input.maxGroupCount) else {
            throw CurationError.invalidLimit(input.maxGroupCount)
        }
        if let cached = cachedResult(), !isCancelled() { return cached }
        let result = try performScan(input, isCancelled: isCancelled)
        cache.withLock { state in
            state.result = result
            state.computedAt = Date()
        }
        return result
    }

    public func invalidateGlobalDuplicateCache() {
        cache.withLock { state in
            state.result = nil
            state.computedAt = nil
        }
    }

    private func cachedResult() -> GlobalDuplicateScanResult? {
        cache.withLock { state in
            guard let result = state.result, let computedAt = state.computedAt else { return nil }
            guard Date().timeIntervalSince(computedAt) < Self.globalDuplicateCacheTTL else {
                return nil
            }
            return result
        }
    }

    private func performScan(
        _ input: GlobalDuplicateScanInput,
        isCancelled: @Sendable () -> Bool
    ) throws -> GlobalDuplicateScanResult {
        let total = try duplicates.totalPhotoCount()
        let missingChecksum = try duplicates.missingChecksumCount()
        if isCancelled() { throw CancellationError() }

        // 1) 精确 checksum：跨 ≥2 个工作区。
        let exactRows = try duplicates.exactGroups(
            minSessionCount: 2,
            limit: input.maxGroupCount * 4
        )
        if isCancelled() { throw CancellationError() }
        let exactPhotos = try duplicates.photos(checksums: exactRows.map(\.checksum))
        if isCancelled() { throw CancellationError() }
        var photosByChecksum: [String: [GlobalDuplicatePhotoRow]] = [:]
        for photo in exactPhotos {
            photosByChecksum[photo.checksum, default: []].append(photo)
        }
        var groups: [GlobalDuplicateGroup] = []
        var claimedPhotoIds = Set<String>()
        for row in exactRows {
            guard let members = photosByChecksum[row.checksum], members.count >= 2 else { continue }
            let sessionCount = Set(members.map(\.sessionId)).count
            guard sessionCount >= 2 else { continue }
            claimedPhotoIds.formUnion(members.map(\.photoId))
            groups.append(GlobalDuplicateGroup(
                id: "exact:\(row.checksum)",
                kind: .exact,
                signature: row.checksum,
                members: members.map(Self.member),
                sessionCount: sessionCount
            ))
        }
        let exactGroupCount = groups.count

        // 2) 视觉近似：hash 桶内汉明比较；已进精确组的不重复展示。
        var visualGroupCount = 0
        if input.includeVisual {
            let hashRows = try duplicates.visualHashRows(limit: 50_000)
                .filter { !claimedPhotoIds.contains($0.photoId) }
            if isCancelled() { throw CancellationError() }
            let clusters = try VisualHashBuckets.clusters(
                rows: hashRows,
                threshold: input.visualThreshold
            )
            let byPhotoId = Dictionary(
                hashRows.map { ($0.photoId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for cluster in clusters {
                let members = cluster.photoIds.compactMap { byPhotoId[$0] }
                let sessionCount = Set(members.map(\.sessionId)).count
                guard members.count >= 2, sessionCount >= 2 else { continue }
                groups.append(GlobalDuplicateGroup(
                    id: "visual:\(cluster.representativeHash)",
                    kind: .visual,
                    signature: cluster.representativeHash,
                    members: members.map(Self.member),
                    sessionCount: sessionCount
                ))
            }
            visualGroupCount = groups.count - exactGroupCount
        }

        let truncated = groups.count > input.maxGroupCount
        let bounded = Array(groups.prefix(input.maxGroupCount))
        return GlobalDuplicateScanResult(
            groups: bounded,
            scannedPhotoCount: total,
            missingChecksumCount: missingChecksum,
            truncated: truncated,
            exactGroupCount: min(exactGroupCount, bounded.count),
            visualGroupCount: min(visualGroupCount, max(0, bounded.count - exactGroupCount))
        )
    }

    // MARK: - 校验与映射

    private func requireSession(_ sessionId: String) throws {
        guard try collections.sessionExists(sessionId) else {
            throw CurationError.sessionNotFound
        }
    }

    private func requireCollection(_ id: String) throws -> CollectionRow {
        guard let row = try collections.get(id: id) else {
            throw CurationError.collectionNotFound(id)
        }
        return row
    }

    private func requireStack(_ id: String) throws -> StackRow {
        guard let row = try stacks.get(id: id) else {
            throw CurationError.stackNotFound(id)
        }
        return row
    }

    private func requirePhotoIds(_ photoIds: [String]) throws {
        guard !CollectionRepo.unique(photoIds).isEmpty else {
            throw CurationError.emptyPhotos
        }
    }

    /// 去重 + 会话内存在性校验；返回去重后的顺序（保持首次出现顺序）。
    private func requirePhotos(sessionId: String, photoIds: [String]) throws -> [String] {
        let ordered = CollectionRepo.unique(photoIds)
        guard !ordered.isEmpty else { throw CurationError.emptyPhotos }
        let existing = try collections.existingPhotoIds(sessionId: sessionId, photoIds: ordered)
        if let missing = ordered.first(where: { !existing.contains($0) }) {
            throw CurationError.photoNotFound(missing)
        }
        return ordered
    }

    private static func summary(_ row: CollectionRow) -> CollectionSummary {
        CollectionSummary(
            id: row.id,
            sessionId: row.sessionId,
            name: row.name,
            itemCount: row.itemCount,
            sortOrder: row.sortOrder,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    private static func summary(_ row: StackRow) -> StackSummary {
        StackSummary(
            id: row.id,
            sessionId: row.sessionId,
            name: row.name,
            coverPhotoId: row.coverPhotoId,
            memberCount: row.memberCount,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    private static func member(_ row: GlobalDuplicatePhotoRow) -> GlobalDuplicateMember {
        GlobalDuplicateMember(
            photoId: row.photoId,
            sessionId: row.sessionId,
            sessionName: row.sessionName,
            filepath: row.filepath,
            filename: row.filename,
            fileSize: row.checksumFileSize,
            checksumComputed: !row.checksum.isEmpty
        )
    }
}

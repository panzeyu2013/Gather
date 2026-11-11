// desktop/native/gather-app/Sources/GatherHost/APIs/LiveAlbumAPI.swift
// Cut 1 / B2：AlbumAPI 的 Live 实现（5 个方法）。
//
// 对应命令（6 条）：album.create / list / update / delete / get_photos；
// album.get 已按 R4 删除（get_photos 复用同一详情构造）。
//
// 校验归属：
// - create/update 复用 AlbumCreateParams/AlbumUpdateParams；criteria 的类型在
//   解码期失败，SQL 可构建性由本实现调用 FilterEngine.buildWhereClause 校验；
// - create 的 name 是旧命令面 的 validatedString（非空白、trim）；update 的
//   albumId 非空白（旧命令面 只 requiredString，这里按 D-012 显式失败）；
// - delete 只接收 Confirmed<AlbumDeleteInput>；ALBUM_NOT_FOUND 由实现映射；
// - get_photos 的 limit/offset 由 PageRequest.album 归一化，查询/计数复用
//   FilterEngine 的全局投影（与旧 album.get_photos 同一 SQL）。
//
// WP4b：同步核心（createSync/listSync/…）已删除；协议方法直接实现同一套
// repo/filter 调用，Library 的 async 端口由 GatherHost 的 provider 适配。
//
// P1 下一波 §3.8（2026-10-30）：手动集合与堆栈挂在本 API（不新增协议域）。
// 业务规则（名称约束、一照一堆栈、位置步长与重排、错误码）全在
// CurationService；本文件只做 API 边界的三件事：
//   1. 入参形态校验（非空白 / 长度上限 / 数组规模），失败 INVALID_PARAM；
//   2. 破坏性入口只收 Confirmed<T>（D-011：调用点标记而非密码学门禁）；
//   3. CurationError → GatherError 时**保留 params**（field / reason / 容器 id），
//      否则 INVALID_PARAM 上屏会丢掉具体字段名。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveAlbumAPI: AlbumAPI, @unchecked Sendable {
    private let albumRepo: SmartAlbumRepo
    private let filterEngine: FilterEngine
    /// 策展容器（集合 / 堆栈）的业务编排；组合根注入同一实例。
    private let curation: CurationService

    /// @unchecked Sendable 依据：三个依赖均为构造后不可变的 let，
    /// 底层连接由 DBConnection 的递归锁串行化。
    public init(
        albumRepo: SmartAlbumRepo,
        filterEngine: FilterEngine,
        curation: CurationService
    ) {
        self.albumRepo = albumRepo
        self.filterEngine = filterEngine
        self.curation = curation
    }

    // MARK: - AlbumAPI

    public func create(_ input: AlbumCreateParams) async throws -> SmartAlbumDetailData {
        let name = try requireNonBlank(input.name, field: "name")
        _ = try LiveAPIErrorMapping.mapFilter { try filterEngine.buildWhereClause(input.criteria) }
        let row = try LiveAPIErrorMapping.map {
            try albumRepo.create(data: SmartAlbumCreateData(
                name: name,
                description: input.description,
                filterCriteria: input.criteria,
                sortBy: input.sortBy,
                sortOrder: input.sortOrder,
                icon: input.icon
            ))
        }
        return try albumDetailData(row: row)
    }

    public func list() async throws -> [SmartAlbumData] {
        let rows = try LiveAPIErrorMapping.map { try albumRepo.list() }
        return rows.map { row in
            do {
                let criteria = try decodeCriteria(row.filterCriteria)
                _ = try filterEngine.buildWhereClause(criteria)
                return SmartAlbumData(
                    id: row.id, schemaVersion: row.schemaVersion, name: row.name,
                    description: row.description, filterCriteria: criteria,
                    sortBy: row.sortBy, sortOrder: row.sortOrder, icon: row.icon,
                    createdAt: row.createdAt, updatedAt: row.updatedAt
                )
            } catch {
                // 损坏 criteria 的行带 validationError 保留（与旧 album.list 一致）。
                return SmartAlbumData(
                    id: row.id, schemaVersion: row.schemaVersion, name: row.name,
                    description: row.description,
                    filterCriteria: FilterGroup(logic: .and, conditions: []),
                    sortBy: row.sortBy, sortOrder: row.sortOrder, icon: row.icon,
                    createdAt: row.createdAt, updatedAt: row.updatedAt,
                    validationError: Self.validationMessage(error)
                )
            }
        }
    }

    public func update(_ input: AlbumUpdateParams) async throws {
        let albumId = try requireNonBlank(input.albumId, field: "albumId")
        if let criteria = input.criteria {
            _ = try LiveAPIErrorMapping.mapFilter { try filterEngine.buildWhereClause(criteria) }
        }
        try LiveAPIErrorMapping.map {
            try albumRepo.update(id: albumId, data: SmartAlbumUpdateData(
                name: input.name,
                description: input.description,
                filterCriteria: input.criteria,
                sortBy: input.sortBy,
                sortOrder: input.sortOrder,
                icon: input.icon
            ))
        }
    }

    public func delete(_ input: Confirmed<AlbumDeleteInput>) async throws {
        let id = try requireNonBlank(input.value.albumId, field: "albumId")
        try LiveAPIErrorMapping.map { try albumRepo.delete(id: id) }
    }

    public func photos(_ query: AlbumPhotosQuery) async throws -> GlobalPhotoPage {
        let id = try requireNonBlank(query.albumId, field: "albumId")
        guard let row = try LiveAPIErrorMapping.map({ try albumRepo.get(id: id) }) else {
            throw GatherError(code: .ALBUM_NOT_FOUND)
        }
        let criteria = try decodeStoredCriteria(row.filterCriteria, albumId: id)
        let photos = try LiveAPIErrorMapping.mapFilter {
            try filterEngine.filterGlobally(
                criteria: criteria,
                sortBy: row.sortBy,
                sortOrder: row.sortOrder,
                limit: query.page.limit,
                offset: query.page.offset
            )
        }
        let total = try LiveAPIErrorMapping.mapFilter {
            try filterEngine.countGlobally(criteria: criteria)
        }
        return GlobalPhotoPage(photos: photos, total: total)
    }

    // MARK: - 内部

    /// TS filter.ipc.ts SmartAlbumDetailData（与旧命令面 albumDetailData 同构）。
    private func albumDetailData(row: SmartAlbumRow) throws -> SmartAlbumDetailData {
        let criteria = try decodeStoredCriteria(row.filterCriteria, albumId: row.id)
        return SmartAlbumDetailData(
            id: row.id,
            schemaVersion: row.schemaVersion,
            name: row.name,
            description: row.description,
            filterCriteria: criteria,
            sortBy: row.sortBy,
            sortOrder: row.sortOrder,
            icon: row.icon,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            photoCount: try LiveAPIErrorMapping.mapFilter {
                try filterEngine.countGlobally(criteria: criteria)
            }
        )
    }

    /// filter_criteria 列是 JSON 字符串（SmartAlbumRepo.filterCriteriaJSON 写入）。
    private func decodeCriteria(_ json: String) throws -> FilterGroup {
        let value = try JSONValue.parse(json)
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(FilterGroup.self, from: data)
    }

    /// 已落库 criteria 损坏属于数据契约错误：转 FILTER_CRITERIA_INVALID（旧命令面
    /// 的 DecodingError 会落到通用 NSError 文案），保留 underlying 供日志排查。
    private func decodeStoredCriteria(_ json: String, albumId: String) throws -> FilterGroup {
        do {
            return try decodeCriteria(json)
        } catch {
            throw GatherError(
                code: .FILTER_CRITERIA_INVALID,
                params: ["albumId": albumId],
                underlying: String(describing: error)
            )
        }
    }

    private func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int = 4096
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    /// 损坏行的 validationError 文案：保留旧命令面 errorMessage 的码形/参数形态。
    private static func validationMessage(_ error: Error) -> String {
        if let filterError = error as? FilterEngineError {
            if case .fieldUnknown(let field) = filterError {
                return "FILTER_FIELD_UNKNOWN::\(field)"
            }
            return filterError.description
        }
        if let dbError = error as? DBError, case .message(let message) = dbError {
            return message
        }
        if error is DecodingError { return "INVALID_PARAMS" }
        return String(describing: error)
    }

    // MARK: - 集合（§3.8.1）

    public func collections(_ sessionId: String) async throws -> [CollectionSummary] {
        let id = try requireId(sessionId, field: "sessionId")
        return try mapCuration { try curation.listCollections(sessionId: id) }
    }

    public func collectionItems(_ collectionId: String) async throws -> [CollectionMember] {
        let id = try requireId(collectionId, field: "collectionId")
        return try mapCuration { try curation.collectionItems(collectionId: id) }
    }

    public func createCollection(_ input: CollectionCreateInput) async throws -> CollectionSummary {
        let sessionId = try requireId(input.sessionId, field: "sessionId")
        let name = try requireNonBlank(input.name, field: "name", maxLength: CurationNaming.maxLength)
        return try mapCuration {
            try curation.createCollection(
                CollectionCreateInput(sessionId: sessionId, name: name)
            )
        }
    }

    public func renameCollection(_ input: CollectionRenameInput) async throws {
        let collectionId = try requireId(input.collectionId, field: "collectionId")
        let name = try requireNonBlank(input.name, field: "name", maxLength: CurationNaming.maxLength)
        try mapCuration {
            try curation.renameCollection(
                CollectionRenameInput(collectionId: collectionId, name: name)
            )
        }
    }

    public func deleteCollection(_ input: Confirmed<CollectionDeleteInput>) async throws {
        let collectionId = try requireId(input.value.collectionId, field: "collectionId")
        try mapCuration { try curation.deleteCollection(id: collectionId) }
    }

    public func addCollectionItems(_ input: CollectionItemsInput) async throws -> Int {
        let collectionId = try requireId(input.collectionId, field: "collectionId")
        let photoIds = try requirePhotoIds(input.photoIds)
        return try mapCuration {
            try curation.addCollectionItems(
                CollectionItemsInput(collectionId: collectionId, photoIds: photoIds)
            )
        }
    }

    public func removeCollectionItems(_ input: CollectionItemsInput) async throws -> Int {
        let collectionId = try requireId(input.collectionId, field: "collectionId")
        let photoIds = try requirePhotoIds(input.photoIds)
        return try mapCuration {
            try curation.removeCollectionItems(
                CollectionItemsInput(collectionId: collectionId, photoIds: photoIds)
            )
        }
    }

    public func reorderCollectionItems(_ input: CollectionReorderInput) async throws {
        let collectionId = try requireId(input.collectionId, field: "collectionId")
        let photoIds = try requirePhotoIds(input.photoIds)
        try mapCuration {
            try curation.reorderCollectionItems(
                CollectionReorderInput(collectionId: collectionId, photoIds: photoIds)
            )
        }
    }

    public func moveCollectionItem(_ input: CollectionMoveInput) async throws {
        let collectionId = try requireId(input.collectionId, field: "collectionId")
        let photoId = try requireId(input.photoId, field: "photoId")
        let after = try input.afterPhotoId.map { try requireId($0, field: "afterPhotoId") }
        let before = try input.beforePhotoId.map { try requireId($0, field: "beforePhotoId") }
        try mapCuration {
            try curation.moveCollectionItem(
                CollectionMoveInput(
                    collectionId: collectionId,
                    photoId: photoId,
                    afterPhotoId: after,
                    beforePhotoId: before
                )
            )
        }
    }

    /// Wave2（task-15）：并 / 交 / 差 —— 物化成一个新集合。
    ///
    /// 破坏性入口只收 Confirmed<T>；集合 id 的会话归属校验在 CurationService
    /// （错误带 field=collectionIds + reason，便于 UI 指出是哪一项）。
    public func combineCollections(
        _ input: Confirmed<CollectionCombineInput>
    ) async throws -> CollectionSummary {
        let sessionId = try requireId(input.value.sessionId, field: "sessionId")
        let name = try requireNonBlank(
            input.value.name, field: "name", maxLength: CurationNaming.maxLength)
        let collectionIds = try requireIdList(
            input.value.collectionIds, field: "collectionIds", maxCount: 50)
        return try mapCuration {
            try curation.combineCollections(CollectionCombineInput(
                sessionId: sessionId,
                name: name,
                operation: input.value.operation,
                collectionIds: collectionIds
            ))
        }
    }

    // MARK: - 堆栈（§3.8.2）

    public func stacks(_ sessionId: String) async throws -> [StackSummary] {
        let id = try requireId(sessionId, field: "sessionId")
        return try mapCuration { try curation.listStacks(sessionId: id) }
    }

    public func stackMembers(_ stackId: String) async throws -> [CollectionMember] {
        let id = try requireId(stackId, field: "stackId")
        return try mapCuration { try curation.stackMembers(stackId: id) }
    }

    public func stackFolds(_ sessionId: String) async throws -> [StackFold] {
        let id = try requireId(sessionId, field: "sessionId")
        return try mapCuration { try curation.stackFolds(sessionId: id) }
    }

    public func createStack(_ input: StackCreateInput) async throws -> StackSummary {
        let sessionId = try requireId(input.sessionId, field: "sessionId")
        let photoIds = try requirePhotoIds(input.photoIds)
        let cover = try input.coverPhotoId.map { try requireId($0, field: "coverPhotoId") }
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= CurationNaming.maxLength else {
            throw GatherError.invalidParameter(
                field: "name",
                reason: "length must be at most \(CurationNaming.maxLength)"
            )
        }
        return try mapCuration {
            try curation.createStack(
                StackCreateInput(
                    sessionId: sessionId, name: name, photoIds: photoIds,
                    coverPhotoId: cover)
            )
        }
    }

    public func updateStack(_ input: StackUpdateInput) async throws {
        let stackId = try requireId(input.stackId, field: "stackId")
        let name = try input.name.map {
            try requireNonBlank($0, field: "name", maxLength: CurationNaming.maxLength)
        }
        let cover = try input.coverPhotoId.map { try requireId($0, field: "coverPhotoId") }
        try mapCuration {
            try curation.updateStack(
                StackUpdateInput(
                    stackId: stackId,
                    name: name,
                    coverPhotoId: cover,
                    clearCover: input.clearCover
                )
            )
        }
    }

    public func deleteStack(_ input: Confirmed<StackDeleteInput>) async throws {
        let stackId = try requireId(input.value.stackId, field: "stackId")
        try mapCuration { try curation.deleteStack(id: stackId) }
    }

    public func addStackMembers(_ input: StackMembersInput) async throws -> Int {
        let stackId = try requireId(input.stackId, field: "stackId")
        let photoIds = try requirePhotoIds(input.photoIds)
        return try mapCuration {
            try curation.addStackMembers(
                StackMembersInput(stackId: stackId, photoIds: photoIds)
            )
        }
    }

    public func removeStackMembers(_ input: StackMembersInput) async throws -> Int {
        let stackId = try requireId(input.stackId, field: "stackId")
        let photoIds = try requirePhotoIds(input.photoIds)
        return try mapCuration {
            try curation.removeStackMembers(
                StackMembersInput(stackId: stackId, photoIds: photoIds)
            )
        }
    }

    // MARK: - 策展入参校验

    /// id 类入参：非空白 + 长度上限 128（与 LiveAPIInput.requireSessionId 同口径）。
    private func requireId(_ value: String, field: String) throws -> String {
        guard value.count <= 128 else {
            throw GatherError.invalidParameter(field: field, reason: "length must be at most 128")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return trimmed
    }

    /// 照片 id 数组：去空、去重、上限 5000（一次拖拽/粘贴的合理上界），空数组拒绝。
    private func requirePhotoIds(_ values: [String]) throws -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(values.count)
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= 128 else {
                throw GatherError.invalidParameter(
                    field: "photoIds", reason: "each id length must be at most 128"
                )
            }
            if seen.insert(trimmed).inserted { ordered.append(trimmed) }
        }
        guard !ordered.isEmpty else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must not be empty")
        }
        guard ordered.count <= 5000 else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "length must be at most 5000"
            )
        }
        return ordered
    }

    /// Wave2：通用 id 列表校验（去空、去重、单项长度 ≤128、总数上限、空数组拒绝）。
    private func requireIdList(
        _ values: [String], field: String, maxCount: Int
    ) throws -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(values.count)
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= 128 else {
                throw GatherError.invalidParameter(
                    field: field, reason: "each id length must be at most 128")
            }
            if seen.insert(trimmed).inserted { ordered.append(trimmed) }
        }
        guard !ordered.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be empty")
        }
        guard ordered.count <= maxCount else {
            throw GatherError.invalidParameter(
                field: field, reason: "length must be at most \(maxCount)")
        }
        return ordered
    }

    /// CurationError → GatherError 时保留 params（field / reason / 容器 id）；
    /// 其余错误走通用收敛（GatherError 直传、CodedError 取码、否则原样抛）。
    private func mapCuration<T>(_ body: () throws -> T) throws -> T {
        try LiveAPIErrorMapping.mapCuration(body)
    }
}

// MARK: - 策展错误收敛

extension LiveAPIErrorMapping {
    /// CurationError → GatherError 时保留 params。
    ///
    /// 通用 map 只从 "CODE: 散文" 里取 detail，会丢掉 field / reason /
    /// collectionId——INVALID_PARAM 上屏就成了「参数无效（），用户不知道该改哪」。
    /// 其余错误仍走通用收敛（GatherError 直传、CodedError 取码、否则原样抛）。
    static func mapCuration<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let curation as CurationError {
            throw GatherError(code: curation.code, params: curation.params)
        } catch {
            throw translateDomain(error) { _ in nil }
        }
    }
}

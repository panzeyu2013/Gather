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

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveAlbumAPI: AlbumAPI, @unchecked Sendable {
    private let albumRepo: SmartAlbumRepo
    private let filterEngine: FilterEngine

    /// @unchecked Sendable 依据：albumRepo/filterEngine 均为构造后不可变的 let，
    /// 底层连接由 DBConnection 的递归锁串行化。
    public init(albumRepo: SmartAlbumRepo, filterEngine: FilterEngine) {
        self.albumRepo = albumRepo
        self.filterEngine = filterEngine
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
}

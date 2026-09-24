// API/Impl/AlbumCommandsImpl.swift
// R5 命令层接线：album 域实现（批次 B6）。
// 逻辑来源：宿主路由层的 album.* 分支；错误码、门控与返回形状保持不变。
// W5-2 待裁决项按已冻结协议落地：
// - 无 album 请求壳 DTO，create / update / delete / get_photos 以扁平参数承接；
// - create / get 返回 Protocol/Filter.swift 的 SmartAlbumDetailData，list 返回
//   [SmartAlbumData]（criteria 解码 / 校验失败的行带 validationError 保留），
//   get_photos 的 {photos, total} 以元组承载。
// 边界语义：
// - create 的 name 沿用旧校验语义（长度上限 4096、trim 后空白拒绝，通过后落库 trim 值）；
//   criteria 先经 FilterEngine.buildWhereClause 校验后落库，photoCount 由实现补齐。
// - get / get_photos 未命中 → ALBUM_NOT_FOUND；criteria 取自落库行。
// - update 仅更新非 nil 字段；criteria 传入时先经引擎校验；name 不做 trim。
// - delete 为破坏性命令：confirmed 不为 true 时抛旧消息（逐字保留）。
// - get_photos 的 limit 缺省 100、钳制 1...500，offset 缺省 0、钳制 >= 0
//   （旧分发层钳制语义），total 为全局匹配总数。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// album 域命令实现：注入智能相册命名空间与过滤引擎。
public actor AlbumCommandsImpl: AlbumCommands {
    /// 旧分发层缺省 limit（album.get_photos）。
    public static let defaultPhotoLimit = 100
    /// 旧分发层 limit 上限（album.get_photos）。
    public static let maxPhotoLimit = 500

    private let albums: AlbumsAPI
    private let engine: FilterEngine

    public init(albums: AlbumsAPI, engine: FilterEngine) {
        self.albums = albums
        self.engine = engine
    }

    // MARK: AlbumCommands

    /// 旧命令：`album.create`。name 校验通过后 trim 落库；criteria 先经引擎校验。
    public func create(
        name: String,
        description: String?,
        criteria: FilterGroup,
        sortBy: String?,
        sortOrder: String?,
        icon: String?
    ) async throws -> SmartAlbumDetailData {
        let validatedName = try Self.validatedName(name)
        _ = try engine.buildWhereClause(criteria)
        let record = try await albums.create(data: SmartAlbumCreateData(
            name: validatedName,
            description: description,
            filterCriteria: criteria,
            sortBy: sortBy,
            sortOrder: sortOrder,
            icon: icon
        ))
        return try await detail(for: record)
    }

    /// 旧命令：`album.list`。损坏 criteria 的行保留并附 validationError。
    public func list() async throws -> [SmartAlbumData] {
        let records = try await albums.list()
        return records.map { record in
            do {
                let criteria = try Self.decodeCriteria(record.filterCriteria)
                _ = try engine.buildWhereClause(criteria)
                return Self.albumData(record, criteria: criteria)
            } catch {
                return Self.albumData(
                    record,
                    criteria: FilterGroup(logic: .and, conditions: []),
                    validationError: Self.validationMessage(error)
                )
            }
        }
    }

    /// 旧命令：`album.get`。相册不存在 → ALBUM_NOT_FOUND。
    public func get(albumId: String) async throws -> SmartAlbumDetailData {
        guard let record = try await albums.get(id: albumId) else {
            throw AlbumCommandsError.notFound
        }
        return try await detail(for: record)
    }

    /// 旧命令：`album.update`。仅非 nil 字段参与更新；criteria 传入时先校验。
    public func update(
        albumId: String,
        name: String?,
        description: String?,
        criteria: FilterGroup?,
        sortBy: String?,
        sortOrder: String?,
        icon: String?
    ) async throws {
        if let criteria {
            _ = try engine.buildWhereClause(criteria)
        }
        try await albums.update(id: albumId, data: SmartAlbumUpdateData(
            name: name,
            description: description,
            filterCriteria: criteria,
            sortBy: sortBy,
            sortOrder: sortOrder,
            icon: icon
        ))
    }

    /// 旧命令：`album.delete`（破坏性）。confirmed 不为 true → 旧门控消息。
    public func delete(albumId: String, confirmed: Bool) async throws {
        guard confirmed else {
            throw AlbumCommandsError.deleteConfirmRequired
        }
        try await albums.delete(id: albumId)
    }

    /// 旧命令：`album.get_photos`。按落库 criteria 全局过滤 + 全局计数。
    public func getPhotos(
        albumId: String,
        limit: Int?,
        offset: Int?
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        guard let record = try await albums.get(id: albumId) else {
            throw AlbumCommandsError.notFound
        }
        let criteria = try Self.decodeCriteria(record.filterCriteria)
        let photos = try await engine.filterGlobally(
            criteria: criteria,
            sortBy: record.sortBy,
            sortOrder: record.sortOrder,
            limit: Self.clampedLimit(limit),
            offset: Self.clampedOffset(offset)
        )
        let total = try await engine.countGlobally(criteria: criteria)
        return (photos, total)
    }

    // MARK: - 旧语义辅助

    /// 旧相册详情装配：criteria 取落库串，photoCount 为全局计数。
    private func detail(for record: SmartAlbumRecord) async throws -> SmartAlbumDetailData {
        let criteria = try Self.decodeCriteria(record.filterCriteria)
        return SmartAlbumDetailData(
            id: record.id,
            schemaVersion: record.schemaVersion,
            name: record.name,
            description: record.description,
            filterCriteria: criteria,
            sortBy: record.sortBy,
            sortOrder: record.sortOrder,
            icon: record.icon,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            photoCount: try await engine.countGlobally(criteria: criteria)
        )
    }

    /// 旧 name 校验：超长或 trim 后空白 → INVALID_PARAM:name；通过后返回 trim 值。
    private static func validatedName(_ name: String) throws -> String {
        guard name.count <= 4096 else {
            throw AlbumCommandsError.invalidParam("name")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw AlbumCommandsError.invalidParam("name")
        }
        return trimmed
    }

    /// 落库 criteria 串 → FilterGroup（解码失败抛原始 DecodingError）。
    private static func decodeCriteria(_ json: String) throws -> FilterGroup {
        try JSONDecoder().decode(FilterGroup.self, from: Data(json.utf8))
    }

    /// 相册行 → SmartAlbumData（validationError 由调用方决定）。
    private static func albumData(
        _ record: SmartAlbumRecord,
        criteria: FilterGroup,
        validationError: String? = nil
    ) -> SmartAlbumData {
        SmartAlbumData(
            id: record.id,
            schemaVersion: record.schemaVersion,
            name: record.name,
            description: record.description,
            filterCriteria: criteria,
            sortBy: record.sortBy,
            sortOrder: record.sortOrder,
            icon: record.icon,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            validationError: validationError
        )
    }

    /// 旧分发层钳制：limit 缺省 100、钳制 1...500。
    private static func clampedLimit(_ limit: Int?) -> Int {
        guard let limit else { return defaultPhotoLimit }
        return Swift.max(1, Swift.min(maxPhotoLimit, limit))
    }

    /// 旧分发层钳制：offset 缺省 0、钳制 >= 0。
    private static func clampedOffset(_ offset: Int?) -> Int {
        Swift.max(0, offset ?? 0)
    }

    /// 旧错误消息投影（list 的 validationError 列）：字段未知带参数化后缀，
    /// 解码失败收敛为 INVALID_PARAMS，其余沿用错误自身描述。
    private static func validationMessage(_ error: Error) -> String {
        if let filterError = error as? FilterEngineError {
            if case .fieldUnknown(let field) = filterError {
                return "FILTER_FIELD_UNKNOWN::\(field)"
            }
            return filterError.description
        }
        if error is DecodingError {
            return "INVALID_PARAMS"
        }
        return error.localizedDescription
    }
}

/// album 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum AlbumCommandsError: Error, Equatable {
    /// 旧响应 error 串：`ALBUM_NOT_FOUND`。
    case notFound
    /// 旧参数校验拒绝：`INVALID_PARAM:name`。
    case invalidParam(String)
    /// 旧破坏性门控消息：`album.delete requires confirmation`。
    case deleteConfirmRequired
}

extension AlbumCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound: "ALBUM_NOT_FOUND"
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        case .deleteConfirmRequired: "album.delete requires confirmation"
        }
    }
}

extension AlbumCommandsError {
    /// 桥接层序列化用；参数错误与破坏性门控沿用旧消息文本，无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .notFound: .ALBUM_NOT_FOUND
        case .invalidParam: nil
        case .deleteConfirmRequired: nil
        }
    }
}

// API/Impl/PersonCommandsImpl.swift
// R5 命令层接线：person 域实现（批次 B4）。
// 逻辑来源：宿主路由层的 person.* 分支，命令清单为 list / get / create / update /
// delete / merge / remove_photo / search_photos；错误码与响应语义与旧分支一致。
// 边界语义：
// - get 未命中 → PERSON_NOT_FOUND；三条破坏性命令各自校验 confirmed 门控。
// - create 的 name 沿用 validateString 语义：超长或 trim 后空白拒绝，通过后返回 trim 值。
// - update 仅把非 nil 字段交给 Store；name 只去首尾空白，matchThreshold 非有限值忽略。
// - search_photos 的 {photos, total} 按协议用元组承载。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// person 域命令实现：注入人物命名空间 PersonsAPI；actor 隔离满足协议 Sendable。
public actor PersonCommandsImpl: PersonCommands {
    private let persons: PersonsAPI

    public init(persons: PersonsAPI) {
        self.persons = persons
    }

    // MARK: PersonCommands

    /// 旧命令：`person.list`。含照片 / 会话计数。
    public func list(_ params: PersonListParams) async throws -> [PersonData] {
        try await persons.list()
    }

    /// 旧命令：`person.get`。人物不存在 → PERSON_NOT_FOUND。
    public func get(_ params: PersonGetParams) async throws -> PersonDetailData {
        guard let detail = try await persons.get(id: params.personId) else {
            throw PersonCommandsError.notFound
        }
        return detail
    }

    /// 旧命令：`person.create`。name 必填；keywords 可选；返回新建人物 id。
    public func create(_ params: PersonCreateParams) async throws -> String {
        let name = try Self.validatedName(params.name)
        return try await persons.create(name: name, keywords: params.keywords)
    }

    /// 旧命令：`person.update`。仅非 nil 字段参与更新；空字段集合为 no-op。
    public func update(_ params: PersonUpdateParams) async throws {
        let fields = PersonUpdateFields(
            name: params.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: params.keywords,
            notes: params.notes,
            matchThreshold: params.matchThreshold.flatMap { $0.isFinite ? $0 : nil }
        )
        try await persons.update(id: params.personId, fields: fields)
    }

    /// 旧命令：`person.delete`（破坏性）。confirmed 不为 true →
    /// PERSON_DELETE_CONFIRM_REQUIRED。
    public func delete(_ params: PersonDeleteParams) async throws {
        guard params.confirmed else {
            throw PersonCommandsError.deleteConfirmRequired
        }
        try await persons.delete(id: params.personId)
    }

    /// 旧命令：`person.merge`（破坏性）。confirmed 不为 true →
    /// PERSON_MERGE_CONFIRM_REQUIRED；sourceId 并入 targetId。
    public func merge(_ params: PersonMergeParams) async throws {
        guard params.confirmed else {
            throw PersonCommandsError.mergeConfirmRequired
        }
        try await persons.merge(sourceId: params.sourceId, targetId: params.targetId)
    }

    /// 旧命令：`person.remove_photo`（破坏性）。confirmed 不为 true →
    /// PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED。
    public func removePhoto(_ params: PersonRemovePhotoParams) async throws {
        guard params.confirmed else {
            throw PersonCommandsError.removePhotoConfirmRequired
        }
        try await persons.removePhoto(personId: params.personId, photoId: params.photoId)
    }

    /// 旧命令：`person.search_photos`。sessionIds / limit / offset 缺省即
    /// 不过滤、不分页；total 为过滤后的匹配总数。
    public func searchPhotos(_ params: PersonSearchPhotosParams) async throws
        -> (photos: [PersonPhotoItem], total: Int) {
        try await persons.searchPhotos(
            personId: params.personId,
            sessionIds: params.sessionIds,
            limit: params.limit,
            offset: params.offset
        )
    }

    /// 旧解析 validatedString 语义：先按原始长度判超长，再按 trim 后判空白，
    /// 通过后返回 trim 值。
    private static func validatedName(_ name: String) throws -> String {
        guard name.count <= 4096 else {
            throw PersonCommandsError.invalidParam("name")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw PersonCommandsError.invalidParam("name")
        }
        return trimmed
    }
}

/// person 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum PersonCommandsError: Error, Equatable {
    /// 旧响应 error 串：`PERSON_NOT_FOUND`。
    case notFound
    /// 旧参数校验拒绝：`INVALID_PARAM:name`。
    case invalidParam(String)
    /// 旧响应 error 串：`PERSON_DELETE_CONFIRM_REQUIRED`。
    case deleteConfirmRequired
    /// 旧响应 error 串：`PERSON_MERGE_CONFIRM_REQUIRED`。
    case mergeConfirmRequired
    /// 旧响应 error 串：`PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED`。
    case removePhotoConfirmRequired
}

extension PersonCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound: "PERSON_NOT_FOUND"
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        case .deleteConfirmRequired: "PERSON_DELETE_CONFIRM_REQUIRED"
        case .mergeConfirmRequired: "PERSON_MERGE_CONFIRM_REQUIRED"
        case .removePhotoConfirmRequired: "PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED"
        }
    }
}

extension PersonCommandsError {
    /// 桥接层序列化用；参数错误无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .notFound: .PERSON_NOT_FOUND
        case .deleteConfirmRequired: .PERSON_DELETE_CONFIRM_REQUIRED
        case .mergeConfirmRequired: .PERSON_MERGE_CONFIRM_REQUIRED
        case .removePhotoConfirmRequired: .PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED
        case .invalidParam: nil
        }
    }
}

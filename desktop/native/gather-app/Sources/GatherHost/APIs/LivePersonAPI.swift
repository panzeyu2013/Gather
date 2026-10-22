// desktop/native/gather-app/Sources/GatherHost/APIs/LivePersonAPI.swift
// Cut 1 / B7a：PersonAPI 的 Live 实现（8 个方法）。
//
// 对应命令（8 条）：person.list / get / create / update / delete / merge /
// remove_photo / search_photos。协议里没有 addPhoto —— 旧命令面只有
// remove_photo；批量加照片是 PersonRepo.addPhotos（fkw.bind / reconcile 的内部
// 投影维护），没有对应的 IPC 命令，故本批不造方法。
//
// 校验归属：
// - delete / merge / removePhoto 只接收 Confirmed<T>（D-011）；载荷的非空白
//   校验在 PersonDeleteInput / PersonMergeInput / PersonRemovePhotoInput 完成，
//   本实现不重复解析、也不自行补确认；
// - get / update / searchPhotos 的 personId 按非空白 + 128 上限收敛（旧命令面
//   只校验“存在”，D-012 改为显式失败）；
// - create 的 name 复刻旧 validatedString：<=4096、trim(.whitespaces) 后非空，
//   返回 trim 值；keywords 原样透传（旧命令不做逐项校验）；
// - update 的 name 复刻旧命令面 的 trim(.whitespacesAndNewlines)，空名不报错
//   （PersonRepo 保留原名，见 update(id:fields:)）；matchThreshold 必须是有限
//   数（旧 optionalNumber 对 NaN/∞ 静默丢弃，按 G1/D-012 改为显式 INVALID_PARAM）；
// - searchPhotos 的 limit/offset 必须 >= 0（旧命令面 直接 Int() 截断且无钳制，
//   负数在 SQLite 里等价“不限制”；按 G2/D-012 改为显式失败）。
//
// 语义（与旧命令面 的 person.* 分支逐字对齐）：
// - list 用 listWithCounts（PersonData 带 photoCount/sessionCount 与最近照片
//   缩略图路径）；
// - get 无记录 → PERSON_NOT_FOUND；detail.photos 与 totalPhotoCount 复用
//   getPhotosWithDetails 的同一次查询（旧命令同构）；
// - delete / merge / removePhoto 对不存在的 id 保持 PersonRepo 的幂等 no-op
//   （旧命令同样返回 {done:true}），本批不把“未命中”升级为错误；merge 的
//   源/目标相等同样 no-op（Repo 内已有短路）；
// - searchPhotos 的 sessionIds 原样下传（空数组在 Repo 中等价不过滤）。
//
// 错误映射：DBError.message 若本身是 GatherErrorCode（PERSON_NOT_FOUND 等），
// 经 LiveAPIErrorMapping 还原为带 code 的 GatherError；其余错误原样抛出
// （D-030：不伪造业务码）。本文件不新建 PersonRepo/连接，复用组合根实例。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LivePersonAPI: PersonAPI, @unchecked Sendable {
    private let personRepo: PersonRepo

    /// @unchecked Sendable 依据：personRepo 是构造后不再变更的 let；PersonRepo
    /// 只持有 DBConnection（内部递归锁串行化同步访问），没有自有可变状态。
    public init(personRepo: PersonRepo) {
        self.personRepo = personRepo
    }

    // MARK: - 列表 / 详情

    public func list() async throws -> [PersonData] {
        try LiveAPIErrorMapping.map {
            try personRepo.listWithCounts().map(Self.personData)
        }
    }

    public func get(_ personId: String) async throws -> PersonDetailData {
        let id = try Self.requireNonBlank(personId, field: "personId", maxLength: 128)
        return try LiveAPIErrorMapping.map {
            guard let row = try personRepo.get(id: id) else {
                throw GatherError(code: .PERSON_NOT_FOUND)
            }
            let photos = try personRepo.getPhotosWithDetails(personId: id)
            return PersonDetailData(
                id: row.id,
                name: row.name,
                keywords: Self.parseKeywords(row.keywords),
                thumbnailBase64: row.thumbnailBase64,
                thumbnailPath: row.thumbnailPath,
                notes: row.notes,
                matchThreshold: row.matchThreshold,
                photoCount: try personRepo.countPhotos(personId: id),
                sessionCount: try personRepo.getSessionCount(personId: id),
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                photos: photos.photos.map(Self.personPhotoItem),
                totalPhotoCount: photos.total
            )
        }
    }

    // MARK: - 写入口

    public func create(_ input: PersonCreateParams) async throws -> PersonCreateResult {
        let name = try Self.validatedName(input.name)
        let id = try LiveAPIErrorMapping.map {
            try personRepo.create(name: name, keywords: input.keywords)
        }
        return PersonCreateResult(id: id)
    }

    public func update(_ input: PersonUpdateParams) async throws {
        let personId = try Self.requireNonBlank(input.personId, field: "personId", maxLength: 128)
        let matchThreshold = try input.matchThreshold.map {
            try Self.requireFinite($0, field: "matchThreshold")
        }
        let fields = PersonUpdateFields(
            name: input.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: input.keywords,
            notes: input.notes,
            matchThreshold: matchThreshold
        )
        _ = try LiveAPIErrorMapping.map {
            try personRepo.update(id: personId, fields: fields)
        }
    }

    public func delete(_ input: Confirmed<PersonDeleteInput>) async throws {
        _ = try LiveAPIErrorMapping.map {
            try personRepo.delete(id: input.value.personId)
        }
    }

    public func merge(_ input: Confirmed<PersonMergeInput>) async throws {
        _ = try LiveAPIErrorMapping.map {
            try personRepo.merge(sourceId: input.value.sourceId, targetId: input.value.targetId)
        }
    }

    public func removePhoto(_ input: Confirmed<PersonRemovePhotoInput>) async throws {
        try LiveAPIErrorMapping.map {
            try personRepo.removePhoto(personId: input.value.personId, photoId: input.value.photoId)
        }
    }

    // MARK: - 按人物检索照片

    public func searchPhotos(_ input: PersonSearchPhotosParams) async throws -> PersonPhotosResult {
        let personId = try Self.requireNonBlank(input.personId, field: "personId", maxLength: 128)
        let limit = try input.limit.map { try Self.requireNonNegative($0, field: "limit") }
        let offset = try input.offset.map { try Self.requireNonNegative($0, field: "offset") }
        let result = try LiveAPIErrorMapping.map {
            try personRepo.getPhotosWithDetails(
                personId: personId,
                sessionIds: input.sessionIds,
                limit: limit,
                offset: offset
            )
        }
        return PersonPhotosResult(
            photos: result.photos.map(Self.personPhotoItem),
            total: result.total
        )
    }

    // MARK: - 行映射（TS person.ipc.ts makeToPersonData / PersonPhotoItem）

    private static func personData(_ row: PersonWithCountsRow) -> PersonData {
        PersonData(
            id: row.person.id,
            name: row.person.name,
            keywords: parseKeywords(row.person.keywords),
            thumbnailBase64: row.person.thumbnailBase64,
            thumbnailPath: row.person.thumbnailPath,
            notes: row.person.notes,
            matchThreshold: row.person.matchThreshold,
            photoCount: row.photoCount,
            sessionCount: row.sessionCount,
            createdAt: row.person.createdAt,
            updatedAt: row.person.updatedAt
        )
    }

    private static func personPhotoItem(_ detail: PersonPhotoDetail) -> PersonPhotoItem {
        // 旧命令面：faceBbox 是 JSON 文本，parse 失败兜底 []。
        let bbox = (try? JSONValue.parse(detail.photo.faceBbox))?
            .arrayElements?.compactMap(\.numberValue) ?? []
        return PersonPhotoItem(
            photoId: detail.photo.photoId,
            sessionId: detail.photo.sessionId,
            sessionName: detail.sessionName,
            filename: detail.filename,
            filepath: detail.filepath,
            faceBbox: bbox,
            confidence: detail.photo.confidence
        )
    }

    private static func parseKeywords(_ raw: String) -> [String] {
        guard let parsed = try? JSONValue.parse(raw) else { return [] }
        return parsed.arrayElements?.compactMap(\.stringValue) ?? []
    }

    // MARK: - 校验

    /// 旧命令面 validatedString（maxLength 默认 4096、非空白、trim 空白）。
    private static func validatedName(_ value: String) throws -> String {
        guard value.count <= 4096 else {
            throw GatherError.invalidParameter(
                field: "name",
                reason: "length must be at most 4096"
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: "name", reason: "must not be blank")
        }
        return trimmed
    }

    private static func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int
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

    private static func requireFinite(_ value: Double, field: String) throws -> Double {
        guard value.isFinite else {
            throw GatherError.invalidParameter(field: field, reason: "must be a finite number")
        }
        return value
    }

    private static func requireNonNegative(_ value: Int, field: String) throws -> Int {
        guard value >= 0 else {
            throw GatherError.invalidParameter(field: field, reason: "must be non-negative")
        }
        return value
    }
}

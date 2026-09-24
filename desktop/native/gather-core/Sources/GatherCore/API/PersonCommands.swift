// API/PersonCommands.swift
// R5 类型化 async 域协议：person 域。
// 旧实现来源：gather-app 的会话命令分发器 person.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/Person.swift 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// person 域命令（8 条）。
///
/// 旧命令清单：`person.list`、`person.get`、`person.create`、`person.update`、
/// `person.delete`、`person.merge`、`person.remove_photo`、`person.search_photos`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `person.get` 在人物不存在时抛 PERSON_NOT_FOUND；本协议返回非可选
///   PersonDetailData，错误由实现抛出。
/// - 旧 `person.search_photos` 返回 {photos, total}；Protocol/ 暂无复合 DTO，
///   本协议以 (photos, total) 元组返回（photos 元素为 PersonPhotoItem）。
/// - 旧 `person.create` 的响应为 {id}，本协议收敛为返回新建人物 id 字符串；
///   旧 `person.update` / `person.delete` / `person.merge` /
///   `person.remove_photo` 的响应恒为 {done:true}，本协议返回空。
public protocol PersonCommands: Sendable {
    /// 旧命令：`person.list`。
    /// 人物列表（含照片 / 会话计数），元素为 Protocol/Person.swift 的 PersonData。
    func list(_ params: PersonListParams) async throws -> [PersonData]

    /// 旧命令：`person.get`。
    /// 人物详情（PersonDetailData = PersonData + photos + totalPhotoCount）；
    /// 人物不存在时由实现抛 PERSON_NOT_FOUND。
    func get(_ params: PersonGetParams) async throws -> PersonDetailData

    /// 旧命令：`person.create`。
    /// name 必填、keywords 可选；返回新建人物 id。
    func create(_ params: PersonCreateParams) async throws -> String

    /// 旧命令：`person.update`。
    /// 仅更新 DTO 中非 nil 的字段（name / keywords / notes / matchThreshold）。
    func update(_ params: PersonUpdateParams) async throws

    /// 旧命令：`person.delete`（破坏性）。
    /// PersonDeleteParams.confirmed 必须为 true，否则实现抛 PERSON_DELETE_CONFIRM_REQUIRED。
    func delete(_ params: PersonDeleteParams) async throws

    /// 旧命令：`person.merge`（破坏性）。
    /// PersonMergeParams.confirmed 必须为 true，否则实现抛 PERSON_MERGE_CONFIRM_REQUIRED；
    /// sourceId 并入 targetId。
    func merge(_ params: PersonMergeParams) async throws

    /// 旧命令：`person.remove_photo`（破坏性）。
    /// PersonRemovePhotoParams.confirmed 必须为 true，否则实现抛
    /// PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED。
    func removePhoto(_ params: PersonRemovePhotoParams) async throws

    /// 旧命令：`person.search_photos`。
    /// 按人物检索照片；sessionIds / limit / offset 可选，返回匹配照片与总数。
    func searchPhotos(_ params: PersonSearchPhotosParams) async throws
        -> (photos: [PersonPhotoItem], total: Int)
}

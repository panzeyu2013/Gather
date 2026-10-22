// desktop/native/gather-core/Sources/GatherProtocol/API/PersonAPI.swift
// Cut 1 / 阶段 1A：人物库域协议（8 个方法）。
//
// 职责：人物列表/详情、创建/更新、删除/合并/移除照片、按人物检索照片。
// 对应命令（8 条）：person.list / get / create / update / delete / merge /
// remove_photo / search_photos。
// 校验归属：
// - create/update/searchPhotos 复用旧 *Params（形状一致）；name 的非空白/长度
//   校验由实现按旧 validatedString 语义执行；
// - delete/merge/removePhoto 使用 Confirmed<T>；
// - PERSON_NOT_FOUND 与合并/归属约束由 PersonRepo 负责。

import Foundation

public protocol PersonAPI: Sendable {
    func list() async throws -> [PersonData]
    func get(_ personId: String) async throws -> PersonDetailData
    func create(_ input: PersonCreateParams) async throws -> PersonCreateResult
    func update(_ input: PersonUpdateParams) async throws
    func delete(_ input: Confirmed<PersonDeleteInput>) async throws
    func merge(_ input: Confirmed<PersonMergeInput>) async throws
    func removePhoto(_ input: Confirmed<PersonRemovePhotoInput>) async throws
    func searchPhotos(_ input: PersonSearchPhotosParams) async throws -> PersonPhotosResult
}

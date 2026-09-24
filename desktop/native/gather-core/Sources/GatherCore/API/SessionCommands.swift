// API/SessionCommands.swift
// R5 类型化 async 域协议：session 域。
// 旧实现来源：gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift 的
// session.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// session 域命令（8 条）。
///
/// 旧命令清单：`session.create`、`session.create_from_directory`、`session.list`、
/// `session.get`、`session.update`、`session.add_photos`、`session.delete`、
/// `session.delete_many`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `session.create` 在 filepaths 非空时返回 {session, failedFiles, added, skipped}
///   复合体，Protocol/ 下暂无该复合 DTO；本协议收敛为 create → SessionData，
///   导入计数由 addPhotos 的 AddPhotoResult 承载。
/// - 旧 `session.delete_many` 响应体为 null；本协议返回删除条数（服务层已有计数）。
public protocol SessionCommands: Sendable {
    /// 旧命令：`session.create`。
    /// SessionCreateParams.filepaths 非空时，实现需在创建后导入照片并回读会话。
    func create(_ params: SessionCreateParams) async throws -> SessionData

    /// 旧命令：`session.create_from_directory`。
    /// 建库与 metadata.scan 入队是同一条命令的编排（入队失败需回滚会话行）。
    func createFromDirectory(_ params: SessionCreateFromDirectoryParams) async throws -> SessionData

    /// 旧命令：`session.list`。
    func list() async throws -> [SessionData]

    /// 旧命令：`session.get`。
    /// 会话不存在时抛错（旧行为：SESSION_NOT_FOUND），因此返回非可选。
    func get(_ params: SessionGetParams) async throws -> SessionData

    /// 旧命令：`session.update`。
    func update(_ params: SessionUpdateParams) async throws -> SessionData

    /// 旧命令：`session.add_photos`。
    /// SessionAddPhotosParams.source 为 nil 时按旧行为取 "import"。
    func addPhotos(_ params: SessionAddPhotosParams) async throws -> AddPhotoResult

    /// 旧命令：`session.delete`（破坏性）。
    /// SessionDeleteParams.confirmed 必须为 true，否则实现抛 SESSION_DELETE_NOT_CONFIRMED。
    func delete(_ params: SessionDeleteParams) async throws

    /// 旧命令：`session.delete_many`（破坏性）。
    /// SessionDeleteManyParams.confirmed 必须为 true；返回删除的会话条数。
    @discardableResult
    func deleteMany(_ params: SessionDeleteManyParams) async throws -> Int
}

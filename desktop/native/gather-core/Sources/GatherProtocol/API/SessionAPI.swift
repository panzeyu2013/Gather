// desktop/native/gather-core/Sources/GatherProtocol/API/SessionAPI.swift
// Cut 1 / 阶段 1A：会话域协议（7 个方法）。
//
// 职责：会话 CRUD、文件/目录导入、工作区状态。Dashboard 不再直连 SessionService，
// 与其他 UI 一样只依赖本协议（第 13 个调用方）。
// 对应命令（9 条）：session.list / get / create / create_from_directory（M1 合并）/
// update / delete / delete_many（M2 合并）/ add_photos、workspace.status。
// 校验归属：
// - 输入类型负责 name/sessionId/filepaths 的形状校验与默认值；
// - sourcePath 的目录准入（SESSION_SOURCE_NOT_DIR / SESSION_SOURCE_ROOT_FORBIDDEN）
//   与文件导入的“公共父目录”规则由实现调用 SessionService/ScanPath 完成；
// - 删除必须经 Confirmed<SessionDeleteInput>，API 不接收裸 Bool；
// - SESSION_NOT_FOUND 由实现映射。
// 无实现：本协议只声明边界，Live 实现属于阶段 1B。

import Foundation

public protocol SessionAPI: Sendable {
    /// session.list
    func list() async throws -> [SessionData]

    /// session.get
    func get(_ sessionId: String) async throws -> SessionData

    /// session.create / session.create_from_directory（M1：统一两种返回形状）
    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult

    /// session.update（复用旧 SessionUpdateParams）
    func update(_ input: SessionUpdateParams) async throws -> SessionData

    /// session.delete / session.delete_many（M2：ids 单/多统一）
    func delete(_ input: Confirmed<SessionDeleteInput>) async throws

    /// session.add_photos（向已存在会话追加）
    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult

    /// workspace.status
    /// P1 / D：摄取（复制/重命名/校验 → 登记）。破坏性在于写文件系统，用 Confirmed 收口。
    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult

    func status(_ sessionId: String) async throws -> WorkspaceStatus
}

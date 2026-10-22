// desktop/native/gather-core/Sources/GatherProtocol/API/TemplateAPI.swift
// Cut 1 / 阶段 1A：工作流模板域协议（6 个方法；D-008 保留，不计入死代码）。
//
// 职责：模板 CRUD 与应用（当前 UI 0 调用，为 ROADMAP 4.2 预留 typed API）。
// 对应命令（6 条）：template.create / list / get / update / delete / apply。
// 校验归属：
// - create/update 复用 TemplateCreateParams/TemplateUpdateParams；
// - delete/apply 使用 Confirmed<T>；
// - TEMPLATE_NOT_FOUND / TEMPLATE_CONFIG_INVALID 由 TemplateService 负责。

import Foundation

public protocol TemplateAPI: Sendable {
    func create(_ input: TemplateCreateParams) async throws -> TemplateData
    func list() async throws -> [TemplateData]
    func get(_ templateId: String) async throws -> TemplateData
    func update(_ input: TemplateUpdateParams) async throws -> TemplateData
    func delete(_ input: Confirmed<TemplateReference>) async throws
    func apply(_ input: Confirmed<TemplateApplyInput>) async throws
}

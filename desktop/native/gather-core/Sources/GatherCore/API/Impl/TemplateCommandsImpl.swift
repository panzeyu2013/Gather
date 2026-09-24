// API/Impl/TemplateCommandsImpl.swift
// R5 命令层接线：template 域实现（批次 B4）。
// 逻辑来源：宿主路由层的 template.* 分支，命令清单为 create / list / get /
// update / delete / apply；错误码与响应语义与旧分支一致。
// 边界语义：
// - create 的 name 沿用 validateString 语义，description 缺省为空串；
//   config 的非对象校验由协议的非可选类型在解码边界静态承载，此处无需重复。
// - get / update 未命中 → TEMPLATE_NOT_FOUND；update 仅非 nil 字段参与更新。
// - delete / apply 的旧响应 {done:true} 按协议收敛为空返回。
// - apply 经 TemplatesAPI 展开配置后逐项写入设置，任一写入失败整体传播。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// template 域命令实现：注入模板命名空间与设置命名空间；actor 隔离满足协议 Sendable。
public actor TemplateCommandsImpl: TemplateCommands {
    private let templates: TemplatesAPI
    private let settings: SettingsAPI

    public init(templates: TemplatesAPI, settings: SettingsAPI) {
        self.templates = templates
        self.settings = settings
    }

    // MARK: TemplateCommands

    /// 旧命令：`template.create`。返回落库后的 TemplateData。
    public func create(_ params: TemplateCreateParams) async throws -> TemplateData {
        let name = try Self.validatedName(params.name)
        return try await templates.create(
            name: name,
            description: params.description ?? "",
            config: params.config
        )
    }

    /// 旧命令：`template.list`。全量模板，按 updated_at 倒序。
    public func list() async throws -> [TemplateData] {
        try await templates.list()
    }

    /// 旧命令：`template.get`。模板不存在 → TEMPLATE_NOT_FOUND。
    public func get(_ params: TemplateGetParams) async throws -> TemplateData {
        guard let template = try await templates.get(id: params.templateId) else {
            throw TemplateCommandsError.notFound
        }
        return template
    }

    /// 旧命令：`template.update`。仅更新传入字段；不存在 →
    /// TEMPLATE_NOT_FOUND；返回更新后的模板。
    public func update(_ params: TemplateUpdateParams) async throws -> TemplateData {
        var fields = TemplateUpdateFields()
        if let name = params.name {
            fields.name = name
        }
        if let description = params.description {
            fields.description = description
        }
        if let config = params.config {
            fields.config = config
        }
        guard let updated = try await templates.update(id: params.templateId, fields: fields) else {
            throw TemplateCommandsError.notFound
        }
        return updated
    }

    /// 旧命令：`template.delete`（破坏性）。confirmed 不为 true →
    /// TEMPLATE_DELETE_CONFIRM_REQUIRED。
    public func delete(_ params: TemplateDeleteParams) async throws {
        guard params.confirmed else {
            throw TemplateCommandsError.deleteConfirmRequired
        }
        try await templates.delete(id: params.templateId)
    }

    /// 旧命令：`template.apply`（破坏性）。confirmed 不为 true →
    /// TEMPLATE_APPLY_CONFIRM_REQUIRED；模板 / 会话状态校验由 TemplatesAPI
    /// 抛出，设置的任一写入失败向上传播，命令整体失败。
    public func apply(_ params: TemplateApplyParams) async throws {
        guard params.confirmed else {
            throw TemplateCommandsError.applyConfirmRequired
        }
        let updates = try await templates.applyUpdates(
            templateId: params.templateId, sessionId: params.sessionId)
        for update in updates {
            try await settings.set(update.key, value: update.value)
        }
    }

    /// 旧解析 validatedString 语义：先按原始长度判超长，再按 trim 后判空白，
    /// 通过后返回 trim 值。
    private static func validatedName(_ name: String) throws -> String {
        guard name.count <= 4096 else {
            throw TemplateCommandsError.invalidParam("name")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw TemplateCommandsError.invalidParam("name")
        }
        return trimmed
    }
}

/// template 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum TemplateCommandsError: Error, Equatable {
    /// 旧响应 error 串：`TEMPLATE_NOT_FOUND`。
    case notFound
    /// 旧参数校验拒绝：`INVALID_PARAM:name`。
    case invalidParam(String)
    /// 旧响应 error 串：`TEMPLATE_DELETE_CONFIRM_REQUIRED`。
    case deleteConfirmRequired
    /// 旧响应 error 串：`TEMPLATE_APPLY_CONFIRM_REQUIRED`。
    case applyConfirmRequired
}

extension TemplateCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound: "TEMPLATE_NOT_FOUND"
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        case .deleteConfirmRequired: "TEMPLATE_DELETE_CONFIRM_REQUIRED"
        case .applyConfirmRequired: "TEMPLATE_APPLY_CONFIRM_REQUIRED"
        }
    }
}

extension TemplateCommandsError {
    /// 桥接层序列化用；参数错误无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .notFound: .TEMPLATE_NOT_FOUND
        case .deleteConfirmRequired: .TEMPLATE_DELETE_CONFIRM_REQUIRED
        case .applyConfirmRequired: .TEMPLATE_APPLY_CONFIRM_REQUIRED
        case .invalidParam: nil
        }
    }
}

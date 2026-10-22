// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/TemplateInputs.swift
// Cut 1 / 阶段 1A：TemplateAPI 输入（template.* 6 条 -> 6 个方法；D-008 保留）。
//
// 对应命令：template.create / list / get / update / delete / apply。
// 复用：template.create -> TemplateCreateParams，template.update -> TemplateUpdateParams
// （config 已类型化为 WorkflowTemplateConfig，非对象/结构错误在解码期失败）。
// 校验归属：
// - delete / apply 为破坏性入口，使用 Confirmed<T>；
// - 模板不存在（TEMPLATE_NOT_FOUND）由 1B 实现映射。

import Foundation

/// template.get / delete 的标识载荷。
public struct TemplateReference: Decodable, Sendable, Equatable {
    public let templateId: String

    public init(templateId: String) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(templateId: try container.decode(String.self, forKey: .templateId))
    }

    private enum CodingKeys: String, CodingKey {
        case templateId
    }
}

/// template.apply 的载荷（Confirmed<TemplateApplyInput>）。
public struct TemplateApplyInput: Decodable, Sendable, Equatable {
    public let templateId: String
    public let sessionId: String

    public init(templateId: String, sessionId: String) throws {
        self.templateId = try APIValidation.nonBlank(templateId, field: "templateId", maxLength: 128)
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            templateId: try container.decode(String.self, forKey: .templateId),
            sessionId: try container.decode(String.self, forKey: .sessionId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case templateId, sessionId
    }
}

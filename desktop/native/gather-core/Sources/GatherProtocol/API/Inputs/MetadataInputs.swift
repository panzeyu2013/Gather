// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/MetadataInputs.swift
// Cut 1 / 阶段 1A：MetadataAPI 输入（conflicts/orphans/resolve + K0 关键词）。
//
// 校验归属：
// - resolve_conflict / resolve_orphan / apply_keywords / retry 使用 Confirmed<T>；
// - choices 的 field/choice 枚举在构造期校验，未知字段显式失败（不再透传到服务层）。

import Foundation

/// metadata.resolve_conflict 的载荷（Confirmed<MetadataResolveConflictInput>）。
/// choices 以枚举 rawValue 作为 JSON key 解码，未知 key 抛 GatherError。
public struct MetadataResolveConflictInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let xmpPath: String
    public let choices: [MetadataField: MetadataConflictChoice]

    public init(
        sessionId: String,
        xmpPath: String,
        choices: [MetadataField: MetadataConflictChoice]
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.xmpPath = try APIValidation.path(xmpPath, field: "xmpPath")
        guard !choices.isEmpty else {
            throw GatherError.invalidParameter(field: "choices", reason: "must not be empty")
        }
        self.choices = choices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let xmpPath = try container.decode(String.self, forKey: .xmpPath)
        let rawChoices = try container.decode([String: MetadataConflictChoice].self, forKey: .choices)
        var choices: [MetadataField: MetadataConflictChoice] = [:]
        for (key, value) in rawChoices {
            guard let field = MetadataField(rawValue: key) else {
                throw GatherError.invalidParameter(field: "choices", reason: "unknown metadata field: \(key)")
            }
            choices[field] = value
        }
        try self.init(sessionId: sessionId, xmpPath: xmpPath, choices: choices)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, xmpPath, choices
    }
}

/// metadata.resolve_orphan 的载荷（Confirmed<MetadataResolveOrphanInput>）。
public struct MetadataResolveOrphanInput: Decodable, Sendable, Equatable {
    public let xmpPath: String
    public let action: MetadataOrphanAction

    public init(xmpPath: String, action: MetadataOrphanAction) throws {
        self.xmpPath = try APIValidation.path(xmpPath, field: "xmpPath")
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            xmpPath: try container.decode(String.self, forKey: .xmpPath),
            action: try container.decode(MetadataOrphanAction.self, forKey: .action)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case xmpPath, action
    }
}

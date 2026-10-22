// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/MetadataInputs.swift
// Cut 1 / 阶段 1A：MetadataAPI 输入（metadata.* 7 条 -> 7 个方法）。
//
// 对应命令：metadata.get / set / batch_set / conflicts / orphans /
// resolve_conflict / resolve_orphan。
// 校验归属：
// - get 的 photoIds 非空、去重、上限 10000（G5）；
// - set / batch_set / resolve_conflict / resolve_orphan 为破坏性入口，使用 Confirmed<T>；
// - tags 不再“非对象按空对象”（G6）：类型错误在解码期失败，缺失 tags 视为输入错误；
// - choices 的 field/choice 枚举在构造期校验，未知字段显式失败（不再透传到服务层）。

import Foundation

/// metadata.get 的输入。
public struct MetadataGetInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]

    public init(photoIds: [String]) throws {
        _ = try APIValidation.nonEmpty(photoIds, field: "photoIds", maxCount: 10_000)
        var seen = Set<String>()
        var unique: [String] = []
        for (index, id) in photoIds.enumerated() {
            _ = try APIValidation.nonBlank(id, field: "photoIds[\(index)]", maxLength: 128)
            if seen.insert(id).inserted { unique.append(id) }
        }
        self.photoIds = unique
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(photoIds: try container.decode([String].self, forKey: .photoIds))
    }

    private enum CodingKeys: String, CodingKey {
        case photoIds
    }
}

/// metadata.set 的载荷（Confirmed<MetadataSetInput>）。
public struct MetadataSetInput: Decodable, Sendable, Equatable {
    public let photoId: String
    public let tags: MetadataTags

    public init(photoId: String, tags: MetadataTags) throws {
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoId: try container.decode(String.self, forKey: .photoId),
            tags: try container.decode(MetadataTags.self, forKey: .tags)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case photoId, tags
    }
}

/// metadata.batch_set 的载荷（Confirmed<MetadataBatchSetInput>）。
public struct MetadataBatchSetInput: Decodable, Sendable, Equatable {
    public let updates: [MetadataBatchUpdate]

    public init(updates: [MetadataBatchUpdate]) throws {
        _ = try APIValidation.nonEmpty(updates, field: "updates", maxCount: 10_000)
        for (index, update) in updates.enumerated() {
            _ = try APIValidation.nonBlank(update.photoId, field: "updates[\(index)].photoId", maxLength: 128)
        }
        self.updates = updates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(updates: try container.decode([MetadataBatchUpdate].self, forKey: .updates))
    }

    private enum CodingKeys: String, CodingKey {
        case updates
    }
}

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

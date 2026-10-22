// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/PersonInputs.swift
// Cut 1 / 阶段 1A：PersonAPI 输入（person.* 8 条 -> 8 个方法）。
//
// 对应命令：person.list / get / create / update / delete / merge / remove_photo /
// search_photos。
// 复用：person.create -> PersonCreateParams，person.update -> PersonUpdateParams，
// person.search_photos -> PersonSearchPhotosParams（字段形状与旧命令一致；
// 非空白/长度校验在 1B 实现层按旧 validatedString 语义完成）。
// 校验归属：delete / merge / remove_photo 为破坏性入口，使用 Confirmed<T>。

import Foundation

/// person.delete 的载荷（Confirmed<PersonDeleteInput>）。
public struct PersonDeleteInput: Decodable, Sendable, Equatable {
    public let personId: String

    public init(personId: String) throws {
        self.personId = try APIValidation.nonBlank(personId, field: "personId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(personId: try container.decode(String.self, forKey: .personId))
    }

    private enum CodingKeys: String, CodingKey {
        case personId
    }
}

/// person.merge 的载荷（Confirmed<PersonMergeInput>）。
public struct PersonMergeInput: Decodable, Sendable, Equatable {
    public let sourceId: String
    public let targetId: String

    public init(sourceId: String, targetId: String) throws {
        self.sourceId = try APIValidation.nonBlank(sourceId, field: "sourceId", maxLength: 128)
        self.targetId = try APIValidation.nonBlank(targetId, field: "targetId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceId: try container.decode(String.self, forKey: .sourceId),
            targetId: try container.decode(String.self, forKey: .targetId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceId, targetId
    }
}

/// person.remove_photo 的载荷（Confirmed<PersonRemovePhotoInput>）。
public struct PersonRemovePhotoInput: Decodable, Sendable, Equatable {
    public let personId: String
    public let photoId: String

    public init(personId: String, photoId: String) throws {
        self.personId = try APIValidation.nonBlank(personId, field: "personId", maxLength: 128)
        self.photoId = try APIValidation.nonBlank(photoId, field: "photoId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            personId: try container.decode(String.self, forKey: .personId),
            photoId: try container.decode(String.self, forKey: .photoId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case personId, photoId
    }
}

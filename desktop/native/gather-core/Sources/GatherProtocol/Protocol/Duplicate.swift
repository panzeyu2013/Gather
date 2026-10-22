// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Duplicate.swift
// TS 源: packages/shared/src/protocol/duplicate.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。
//
// 映射决策:
// - TS `X | null`（非可选但可空）字段在 JSON 中 key 恒存在、值为 null；
//   Swift 用 Optional 表达，并通过自定义 encode 把 nil 编码为 null 而非省略 key
//   （DuplicateGroup.resolution / DuplicateGroupMember.fileSize|fileMtime|resolution）。

import Foundation

// TS: resolution（duplicate.ts 内联联合 'keep_one' | 'keep_all'）
public enum DupResolution: String, Codable, CaseIterable, Equatable, Sendable {
    case keepOne = "keep_one"
    case keepAll = "keep_all"
}

// TS: DuplicateScanResult
public struct DuplicateScanResult: Codable, Equatable, Sendable {
    public var exactGroups: [DuplicateGroup]
    public var visualGroups: [DuplicateGroup]
    public var totalDuplicates: Int

    public init(exactGroups: [DuplicateGroup], visualGroups: [DuplicateGroup], totalDuplicates: Int) {
        self.exactGroups = exactGroups
        self.visualGroups = visualGroups
        self.totalDuplicates = totalDuplicates
    }
}

// TS: groupType（duplicate.ts 内联联合 'exact' | 'visual'）
public enum DuplicateGroupType: String, Codable, CaseIterable, Equatable, Sendable {
    case exact
    case visual
}

// TS: DuplicateGroup —— resolution: string | null，key 恒存在
public struct DuplicateGroup: Codable, Equatable, Sendable {
    public var id: Int
    public var groupType: DuplicateGroupType
    public var checksum: String? // TS: checksum?
    public var hashHex: String? // TS: hashHex?
    public var memberCount: Int
    public var members: [DuplicateGroupMember]
    public var resolution: String? // TS: resolution: string | null
    public var createdAt: String

    public init(
        id: Int,
        groupType: DuplicateGroupType,
        checksum: String? = nil,
        hashHex: String? = nil,
        memberCount: Int,
        members: [DuplicateGroupMember],
        resolution: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.groupType = groupType
        self.checksum = checksum
        self.hashHex = hashHex
        self.memberCount = memberCount
        self.members = members
        self.resolution = resolution
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.groupType = try container.decode(DuplicateGroupType.self, forKey: .groupType)
        self.checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        self.hashHex = try container.decodeIfPresent(String.self, forKey: .hashHex)
        self.memberCount = try container.decode(Int.self, forKey: .memberCount)
        self.members = try container.decode([DuplicateGroupMember].self, forKey: .members)
        self.resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        self.createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupType, forKey: .groupType)
        try container.encodeIfPresent(checksum, forKey: .checksum)
        try container.encodeIfPresent(hashHex, forKey: .hashHex)
        try container.encode(memberCount, forKey: .memberCount)
        try container.encode(members, forKey: .members)
        if let resolution {
            try container.encode(resolution, forKey: .resolution)
        } else {
            try container.encodeNil(forKey: .resolution)
        }
        try container.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, groupType, checksum, hashHex, memberCount, members, resolution, createdAt
    }
}

// TS: DuplicateGroupMember —— fileSize/fileMtime/resolution: X | null，key 恒存在
public struct DuplicateGroupMember: Codable, Equatable, Sendable {
    public var id: Int
    public var photoId: String
    public var isKept: Bool
    public var fileSize: Int? // TS: fileSize: number | null
    public var fileMtime: String? // TS: fileMtime: string | null
    public var resolution: String? // TS: resolution: string | null
    public var filepath: String
    public var filename: String

    public init(
        id: Int,
        photoId: String,
        isKept: Bool,
        fileSize: Int? = nil,
        fileMtime: String? = nil,
        resolution: String? = nil,
        filepath: String,
        filename: String
    ) {
        self.id = id
        self.photoId = photoId
        self.isKept = isKept
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.resolution = resolution
        self.filepath = filepath
        self.filename = filename
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.photoId = try container.decode(String.self, forKey: .photoId)
        self.isKept = try container.decode(Bool.self, forKey: .isKept)
        self.fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
        self.fileMtime = try container.decodeIfPresent(String.self, forKey: .fileMtime)
        self.resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        self.filepath = try container.decode(String.self, forKey: .filepath)
        self.filename = try container.decode(String.self, forKey: .filename)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(photoId, forKey: .photoId)
        try container.encode(isKept, forKey: .isKept)
        if let fileSize {
            try container.encode(fileSize, forKey: .fileSize)
        } else {
            try container.encodeNil(forKey: .fileSize)
        }
        if let fileMtime {
            try container.encode(fileMtime, forKey: .fileMtime)
        } else {
            try container.encodeNil(forKey: .fileMtime)
        }
        if let resolution {
            try container.encode(resolution, forKey: .resolution)
        } else {
            try container.encodeNil(forKey: .resolution)
        }
        try container.encode(filepath, forKey: .filepath)
        try container.encode(filename, forKey: .filename)
    }

    private enum CodingKeys: String, CodingKey {
        case id, photoId, isKept, fileSize, fileMtime, resolution, filepath, filename
    }
}

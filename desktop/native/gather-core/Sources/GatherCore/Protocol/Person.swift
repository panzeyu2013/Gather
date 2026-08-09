// desktop/native/gather-core/Sources/GatherCore/Protocol/Person.swift
// TS 源: packages/shared/src/protocol/person.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: PersonListParams
public struct PersonListParams: Codable, Equatable, Sendable {
    public init() {}
}

// TS: PersonGetParams
public struct PersonGetParams: Codable, Equatable, Sendable {
    public var personId: String

    public init(personId: String) {
        self.personId = personId
    }
}

// TS: PersonCreateParams
public struct PersonCreateParams: Codable, Equatable, Sendable {
    public var name: String
    public var keywords: [String]? // TS: keywords?

    public init(name: String, keywords: [String]? = nil) {
        self.name = name
        self.keywords = keywords
    }
}

// TS: PersonUpdateParams
public struct PersonUpdateParams: Codable, Equatable, Sendable {
    public var personId: String
    public var name: String? // TS: name?
    public var keywords: [String]? // TS: keywords?
    public var notes: String? // TS: notes?
    public var matchThreshold: Double? // TS: matchThreshold?

    public init(personId: String, name: String? = nil, keywords: [String]? = nil, notes: String? = nil, matchThreshold: Double? = nil) {
        self.personId = personId
        self.name = name
        self.keywords = keywords
        self.notes = notes
        self.matchThreshold = matchThreshold
    }
}

// TS: PersonDeleteParams
public struct PersonDeleteParams: Codable, Equatable, Sendable {
    public var personId: String
    public var confirmed: Bool

    public init(personId: String, confirmed: Bool) {
        self.personId = personId
        self.confirmed = confirmed
    }
}

// TS: PersonMergeParams
public struct PersonMergeParams: Codable, Equatable, Sendable {
    public var sourceId: String
    public var targetId: String
    public var confirmed: Bool

    public init(sourceId: String, targetId: String, confirmed: Bool) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.confirmed = confirmed
    }
}

// TS: PersonRemovePhotoParams
public struct PersonRemovePhotoParams: Codable, Equatable, Sendable {
    public var personId: String
    public var photoId: String
    public var confirmed: Bool

    public init(personId: String, photoId: String, confirmed: Bool) {
        self.personId = personId
        self.photoId = photoId
        self.confirmed = confirmed
    }
}

// TS: PersonSearchPhotosParams
public struct PersonSearchPhotosParams: Codable, Equatable, Sendable {
    public var personId: String
    public var sessionIds: [String]? // TS: sessionIds?
    public var limit: Int? // TS: limit?
    public var offset: Int? // TS: offset?

    public init(personId: String, sessionIds: [String]? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.personId = personId
        self.sessionIds = sessionIds
        self.limit = limit
        self.offset = offset
    }
}

// TS: PersonData
public struct PersonData: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var keywords: [String]
    public var thumbnailBase64: String? // TS: thumbnailBase64?
    public var thumbnailPath: String? // TS: thumbnailPath?
    public var notes: String
    public var matchThreshold: Double
    public var photoCount: Int
    public var sessionCount: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        keywords: [String],
        thumbnailBase64: String? = nil,
        thumbnailPath: String? = nil,
        notes: String,
        matchThreshold: Double,
        photoCount: Int,
        sessionCount: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.thumbnailBase64 = thumbnailBase64
        self.thumbnailPath = thumbnailPath
        self.notes = notes
        self.matchThreshold = matchThreshold
        self.photoCount = photoCount
        self.sessionCount = sessionCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// TS: PersonPhotoItem
public struct PersonPhotoItem: Codable, Equatable, Sendable {
    public var photoId: String
    public var sessionId: String
    public var sessionName: String
    public var filename: String
    public var filepath: String
    public var faceBbox: [Double]
    public var confidence: Double
    public var thumbnailBase64: String? // TS: thumbnailBase64?

    public init(
        photoId: String,
        sessionId: String,
        sessionName: String,
        filename: String,
        filepath: String,
        faceBbox: [Double],
        confidence: Double,
        thumbnailBase64: String? = nil
    ) {
        self.photoId = photoId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.filename = filename
        self.filepath = filepath
        self.faceBbox = faceBbox
        self.confidence = confidence
        self.thumbnailBase64 = thumbnailBase64
    }
}

// TS: PersonDetailData extends PersonData —— Swift 无继承，展开字段并追加 photoCount
public struct PersonDetailData: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var keywords: [String]
    public var thumbnailBase64: String? // TS: thumbnailBase64?
    public var thumbnailPath: String? // TS: thumbnailPath?
    public var notes: String
    public var matchThreshold: Double
    public var photoCount: Int
    public var sessionCount: Int
    public var createdAt: String
    public var updatedAt: String
    public var photos: [PersonPhotoItem]
    public var totalPhotoCount: Int

    public init(
        id: String,
        name: String,
        keywords: [String],
        thumbnailBase64: String? = nil,
        thumbnailPath: String? = nil,
        notes: String,
        matchThreshold: Double,
        photoCount: Int,
        sessionCount: Int,
        createdAt: String,
        updatedAt: String,
        photos: [PersonPhotoItem],
        totalPhotoCount: Int
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.thumbnailBase64 = thumbnailBase64
        self.thumbnailPath = thumbnailPath
        self.notes = notes
        self.matchThreshold = matchThreshold
        self.photoCount = photoCount
        self.sessionCount = sessionCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.photos = photos
        self.totalPhotoCount = totalPhotoCount
    }
}

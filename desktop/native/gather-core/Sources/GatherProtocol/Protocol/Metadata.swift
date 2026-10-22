// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Metadata.swift
// TS 源: packages/shared/src/protocol/metadata.ts（契约基线: docs/IPC_CONTRACT.md）
// 纯值类型契约层：禁止依赖任何 TS 运行时；仅 Foundation。
// 字段名与 TS 一致（camelCase），Codable 合成 JSON key 与 TS 逐字相同。

import Foundation

// TS: batch metadata updates 的元素（匿名对象 { photoId, tags }）
public struct MetadataBatchUpdate: Codable, Equatable, Sendable {
    public var photoId: String
    public var tags: MetadataTags

    public init(photoId: String, tags: MetadataTags) {
        self.photoId = photoId
        self.tags = tags
    }
}

// TS: MetadataField
public enum MetadataField: String, Codable, CaseIterable, Equatable, Sendable {
    case rating
    case label
    case keywords
}

// TS: MetadataMutationSource
public enum MetadataMutationSource: String, Codable, CaseIterable, Equatable, Sendable {
    case culling
    case faceKeyword = "face-keyword"
    case similarity
    case template
    case manual
}

// TS: MetadataPatch.rating.op（内联单值联合 'set'）
public enum MetadataRatingOp: String, Codable, CaseIterable, Equatable, Sendable {
    case set
}

// TS: MetadataPatch.rating（内联匿名对象 { op: 'set'; value: number }）
public struct MetadataRatingPatch: Codable, Equatable, Sendable {
    public var op: MetadataRatingOp
    public var value: Double

    public init(op: MetadataRatingOp = .set, value: Double) {
        self.op = op
        self.value = value
    }
}

// TS: MetadataPatch.label.op（内联单值联合 'set'）
public enum MetadataLabelOp: String, Codable, CaseIterable, Equatable, Sendable {
    case set
}

// TS: MetadataPatch.label（内联匿名对象 { op: 'set'; value: string }）
public struct MetadataLabelPatch: Codable, Equatable, Sendable {
    public var op: MetadataLabelOp
    public var value: String

    public init(op: MetadataLabelOp = .set, value: String) {
        self.op = op
        self.value = value
    }
}

// TS: MetadataPatch.keywords.op（内联联合 'append' | 'replace' | 'remove'）
public enum MetadataKeywordsOp: String, Codable, CaseIterable, Equatable, Sendable {
    case append
    case replace
    case remove
}

// TS: MetadataPatch.keywords（内联匿名对象 { op: ...; values: string[] }）
public struct MetadataKeywordsPatch: Codable, Equatable, Sendable {
    public var op: MetadataKeywordsOp
    public var values: [String]

    public init(op: MetadataKeywordsOp, values: [String]) {
        self.op = op
        self.values = values
    }
}

// TS: MetadataPatch
public struct MetadataPatch: Codable, Equatable, Sendable {
    public var rating: MetadataRatingPatch? // TS: rating?
    public var label: MetadataLabelPatch? // TS: label?
    public var keywords: MetadataKeywordsPatch? // TS: keywords?

    public init(rating: MetadataRatingPatch? = nil, label: MetadataLabelPatch? = nil, keywords: MetadataKeywordsPatch? = nil) {
        self.rating = rating
        self.label = label
        self.keywords = keywords
    }
}

// TS: MetadataMutationResult
public struct MetadataMutationResult: Codable, Equatable, Sendable {
    public var photoId: String
    public var xmpPath: String
    public var dirtyFields: [MetadataField]
    public var revision: Int
    public var status: String

    public init(photoId: String, xmpPath: String, dirtyFields: [MetadataField], revision: Int, status: String) {
        self.photoId = photoId
        self.xmpPath = xmpPath
        self.dirtyFields = dirtyFields
        self.revision = revision
        self.status = status
    }
}

// TS: MetadataConflictField —— baseline/local/remote: unknown → JSONValue
public struct MetadataConflictField: Codable, Equatable, Sendable {
    public var field: MetadataField
    public var baseline: JSONValue
    public var local: JSONValue
    public var remote: JSONValue

    public init(field: MetadataField, baseline: JSONValue, local: JSONValue, remote: JSONValue) {
        self.field = field
        self.baseline = baseline
        self.local = local
        self.remote = remote
    }
}

// TS: MetadataConflict
public struct MetadataConflict: Codable, Equatable, Sendable {
    public var xmpPath: String
    public var photoPath: String
    public var revision: Int
    public var fields: [MetadataConflictField]

    public init(xmpPath: String, photoPath: String, revision: Int, fields: [MetadataConflictField]) {
        self.xmpPath = xmpPath
        self.photoPath = photoPath
        self.revision = revision
        self.fields = fields
    }
}

// TS: MetadataConflictChoice
public enum MetadataConflictChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case keepLocal = "keep_local"
    case useRemote = "use_remote"
}

// TS: MetadataOrphan
public struct MetadataOrphan: Codable, Equatable, Sendable {
    public var xmpPath: String
    public var photoPath: String
    public var status: String
    public var revision: Int
    public var errorMessage: String
    public var updatedAt: String

    public init(xmpPath: String, photoPath: String, status: String, revision: Int, errorMessage: String, updatedAt: String) {
        self.xmpPath = xmpPath
        self.photoPath = photoPath
        self.status = status
        self.revision = revision
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

// TS: MetadataOrphanAction（metadata.ts 内联联合 'keep' | 'restore' | 'retry'）
public enum MetadataOrphanAction: String, Codable, CaseIterable, Equatable, Sendable {
    case keep
    case restore
    case retry
}

// TS: MetadataTags（全字段可选，即 Partial<MetadataTags> 的最终形状）
public struct MetadataTags: Codable, Equatable, Sendable {
    public var filename: String? // TS: filename?
    public var fileSize: Int? // TS: fileSize?
    public var format: String? // TS: format?
    public var width: Int? // TS: width?
    public var height: Int? // TS: height?
    public var mime: String? // TS: mime?
    public var make: String? // TS: make?
    public var model: String? // TS: model?
    public var serialNumber: String? // TS: serialNumber?
    public var lensModel: String? // TS: lensModel?
    public var focalLength: Double? // TS: focalLength?
    public var maxAperture: Double? // TS: maxAperture?
    public var aperture: Double? // TS: aperture?
    public var shutterSpeed: String? // TS: shutterSpeed?
    public var iso: Int? // TS: iso?
    public var exposureComp: String? // TS: exposureComp?
    public var meteringMode: String? // TS: meteringMode?
    public var whiteBalance: String? // TS: whiteBalance?
    public var dateTaken: String? // TS: dateTaken?
    public var dateDigitized: String? // TS: dateDigitized?
    public var title: String? // TS: title?
    public var description: String? // TS: description?
    public var author: String? // TS: author?
    public var copyright: String? // TS: copyright?
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?
    public var latitude: Double? // TS: latitude?
    public var longitude: Double? // TS: longitude?
    public var altitude: Double? // TS: altitude?

    public init(
        filename: String? = nil,
        fileSize: Int? = nil,
        format: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        mime: String? = nil,
        make: String? = nil,
        model: String? = nil,
        serialNumber: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        maxAperture: Double? = nil,
        aperture: Double? = nil,
        shutterSpeed: String? = nil,
        iso: Int? = nil,
        exposureComp: String? = nil,
        meteringMode: String? = nil,
        whiteBalance: String? = nil,
        dateTaken: String? = nil,
        dateDigitized: String? = nil,
        title: String? = nil,
        description: String? = nil,
        author: String? = nil,
        copyright: String? = nil,
        keywords: [String]? = nil,
        rating: Double? = nil,
        label: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil
    ) {
        self.filename = filename
        self.fileSize = fileSize
        self.format = format
        self.width = width
        self.height = height
        self.mime = mime
        self.make = make
        self.model = model
        self.serialNumber = serialNumber
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.maxAperture = maxAperture
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.exposureComp = exposureComp
        self.meteringMode = meteringMode
        self.whiteBalance = whiteBalance
        self.dateTaken = dateTaken
        self.dateDigitized = dateDigitized
        self.title = title
        self.description = description
        self.author = author
        self.copyright = copyright
        self.keywords = keywords
        self.rating = rating
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

// TS: BatchMetadataResult
public struct BatchMetadataResult: Codable, Equatable, Sendable {
    public var success: Int
    public var failed: Int
    public var errors: [String]

    public init(success: Int, failed: Int, errors: [String]) {
        self.success = success
        self.failed = failed
        self.errors = errors
    }
}

// 指纹计算失败（原声明在 Services/MetadataFingerprint.swift）。
// Cut 3 / 3a：下移到 Protocol，因为 Persistence/DeliveryError.from 需要按类型
// 归因（XMP_FINGERPRINT_FAILED），而 Persistence 不得依赖 Domain。
public enum MetadataFingerprintError: Error, Equatable {
    case statFailed(String)
}

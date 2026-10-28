// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Output.swift
// 交付配方与整套交付的运行契约（多配方 / 联系表 / manifest）。
//
// 与单次导出（ExportOptions）的关系：一个配方就是"一套导出参数 + 产物清单"；
// 跑一次 output.run = 逐配方导出 + 可选联系表 + 一份 manifest。
import Foundation

public enum OutputArtifactKind: String, Codable, CaseIterable, Equatable, Sendable {
    case photos
    case contactSheet
    /// 静态 Web 画廊（index/data.json/thumbs/large/proof.html）。
    case gallery
    case manifest
}

public struct OutputGalleryOptions: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var footer: String
    public var thumbnailMaxDimension: Int
    public var largeMaxDimension: Int

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        thumbnailMaxDimension: Int = 480,
        largeMaxDimension: Int = 1600
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.thumbnailMaxDimension = thumbnailMaxDimension
        self.largeMaxDimension = largeMaxDimension
    }
}

public struct OutputRecipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var format: ExportFormat
    public var quality: Double?
    public var maxDimension: Int?
    public var watermark: ExportWatermark?
    public var naming: ExportNaming
    public var includeXmp: Bool
    public var includeMetadata: Bool
    /// 绝对目录；空串 = <run root>/<name>（由编排器补全）。
    public var destination: String
    public var artifacts: [OutputArtifactKind]

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        format: ExportFormat = .jpeg,
        quality: Double? = 85,
        maxDimension: Int? = nil,
        watermark: ExportWatermark? = nil,
        naming: ExportNaming = ExportNaming(pattern: "{original}"),
        includeXmp: Bool = false,
        includeMetadata: Bool = true,
        destination: String = "",
        artifacts: [OutputArtifactKind] = [.photos]
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
        self.watermark = watermark
        self.naming = naming
        self.includeXmp = includeXmp
        self.includeMetadata = includeMetadata
        self.destination = destination
        self.artifacts = artifacts
    }
}

public struct OutputContactSheetOptions: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var footer: String
    public var columns: Int
    public var rows: Int

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        columns: Int = 4,
        rows: Int = 5
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct OutputRunInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var scope: ExportScope
    public var destinationRoot: String
    public var recipes: [OutputRecipe]
    /// nil = 不生成联系表（配方里勾了 contactSheet 才生成）。
    public var contactSheet: OutputContactSheetOptions?
    /// nil = 不生成画廊（配方里勾了 gallery 才生成）。
    public var gallery: OutputGalleryOptions?

    public init(
        sessionId: String,
        scope: ExportScope = .session,
        destinationRoot: String,
        recipes: [OutputRecipe],
        contactSheet: OutputContactSheetOptions? = nil,
        gallery: OutputGalleryOptions? = nil
    ) {
        self.sessionId = sessionId
        self.scope = scope
        self.destinationRoot = destinationRoot
        self.recipes = recipes
        self.contactSheet = contactSheet
        self.gallery = gallery
    }
}

public extension OutputRecipe {
    /// 交付身份用的配方形状：**去掉 artifacts**。
    ///
    /// 联系表/画廊只影响派生产物，不改变成片像素或文件名；把它们算进 job 去重键或
    /// 续跑指纹，会让「只勾一个开关」变成一次全新交付 —— 继承不到 completedPhotoIds，
    /// 目标目录已有成片时被唯一化重写，整批变成 xxx_2.jpg。
    var withoutArtifacts: OutputRecipe {
        var copy = self
        copy.artifacts = []
        return copy
    }
}

/// 整套交付中单个配方的断点续跑状态（进 job checkpoint，可 JSON 往返）。
public struct OutputRecipeResume: Codable, Equatable, Sendable {
    public var destinations: [String: String]
    public var completedPhotoIds: [String]
    public var sidecarVersions: [String: String]
    /// 配方参数 + 范围 + **源内容摘要**的指纹：参数或源片变了都不能复用旧完成清单。
    /// 不含 artifacts（联系表/画廊不影响成片）。
    public var recipeFingerprint: String

    public init(
        destinations: [String: String] = [:],
        completedPhotoIds: [String] = [],
        sidecarVersions: [String: String] = [:],
        recipeFingerprint: String = ""
    ) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
        self.sidecarVersions = sidecarVersions
        self.recipeFingerprint = recipeFingerprint
    }
}

/// manifest 里的单张产物（名称 + 字节数；不存绝对路径，避免泄漏本机目录）。
public struct OutputFileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

public struct OutputRecipeResult: Codable, Equatable, Sendable {
    public var recipeId: String
    public var name: String
    public var destination: String
    public var exported: Int
    public var failed: Int
    public var skipped: Int
    public var contactSheetPath: String?
    /// 联系表里渲染失败的格子数（>0 表示有照片缺席）。
    public var contactSheetFailedImages: Int?
    public var galleryPath: String?
    public var galleryItems: Int?
    /// 画廊里被跳过的照片数（解码失败）。
    public var gallerySkipped: Int?
    /// 本次实际交付的成品（manifest 审计用；缺省 = 旧数据）。
    public var files: [OutputFileEntry]?
    public var errors: [String]

    public init(
        recipeId: String,
        name: String,
        destination: String,
        exported: Int,
        failed: Int,
        skipped: Int,
        contactSheetPath: String? = nil,
        contactSheetFailedImages: Int? = nil,
        galleryPath: String? = nil,
        galleryItems: Int? = nil,
        gallerySkipped: Int? = nil,
        files: [OutputFileEntry]? = nil,
        errors: [String] = []
    ) {
        self.recipeId = recipeId
        self.name = name
        self.destination = destination
        self.exported = exported
        self.failed = failed
        self.skipped = skipped
        self.contactSheetPath = contactSheetPath
        self.contactSheetFailedImages = contactSheetFailedImages
        self.galleryPath = galleryPath
        self.galleryItems = galleryItems
        self.gallerySkipped = gallerySkipped
        self.files = files
        self.errors = errors
    }
}

public struct OutputRunSummary: Codable, Equatable, Sendable {
    public var runId: String
    public var sessionId: String
    public var manifestPath: String
    public var createdAt: String
    public var recipes: [OutputRecipeResult]
    /// manifest 写失败时的原因（成片已写出，交付仍算成功）。
    public var manifestError: String?
    /// true = 本次运行被取消，manifest 记录的是「已交付的部分」。
    public var cancelled: Bool?

    public init(
        runId: String,
        sessionId: String,
        manifestPath: String,
        createdAt: String,
        recipes: [OutputRecipeResult],
        manifestError: String? = nil,
        cancelled: Bool? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.manifestPath = manifestPath
        self.createdAt = createdAt
        self.recipes = recipes
        self.manifestError = manifestError
        self.cancelled = cancelled
    }

    public var totalExported: Int { recipes.reduce(0) { $0 + $1.exported } }
    public var totalFailed: Int { recipes.reduce(0) { $0 + $1.failed } }
}


/// WebDAV 发布：把本地目录（成片/画廊）上传到用户自备服务器。
public struct WebDAVPublishInput: Codable, Equatable, Sendable {
    public var localPath: String
    public var baseURL: String
    public var username: String
    public var remoteFolder: String
    /// 只上传这些相对前缀下的文件（nil = 整个目录）。用于避免把历史 manifest、
    /// 旧联系表或用户放在交付根里的无关文件一并发布。
    public var includePrefixes: [String]?

    public init(
        localPath: String, baseURL: String, username: String, remoteFolder: String,
        includePrefixes: [String]? = nil
    ) {
        self.localPath = localPath
        self.baseURL = baseURL
        self.username = username
        self.remoteFolder = remoteFolder
        self.includePrefixes = includePrefixes
    }
}

public struct WebDAVPublishFailureInfo: Codable, Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct WebDAVPublishSummary: Codable, Equatable, Sendable {
    public var uploaded: Int
    public var failed: [WebDAVPublishFailureInfo]
    public var remoteRoot: String
    public var abortedOnAuth: Bool

    public init(uploaded: Int, failed: [WebDAVPublishFailureInfo], remoteRoot: String, abortedOnAuth: Bool) {
        self.uploaded = uploaded
        self.failed = failed
        self.remoteRoot = remoteRoot
        self.abortedOnAuth = abortedOnAuth
    }

    public var isSuccess: Bool { failed.isEmpty && !abortedOnAuth }
}

/// 保存 WebDAV 凭据（密码只进 Keychain，不落 settings/日志）。
public struct WebDAVCredentialInput: Codable, Equatable, Sendable {
    public var baseURL: String
    public var username: String
    public var password: String

    public init(baseURL: String, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }
}


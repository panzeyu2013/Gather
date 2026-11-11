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
    /// 画廊页要叠加展示的字段（星条/色标点）。data.json 始终带全部元数据，
    /// 这里只决定 index.html 画什么。默认星条 + 色标 + 取舍边框。
    public var fields: ContactSheetFields

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        thumbnailMaxDimension: Int = 480,
        largeMaxDimension: Int = 1600,
        fields: ContactSheetFields = [.rating, .label, .pick]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.thumbnailMaxDimension = thumbnailMaxDimension
        self.largeMaxDimension = largeMaxDimension
        self.fields = fields
    }
}

public struct OutputRecipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var format: ExportFormat
    public var quality: Double?
    public var maxDimension: Int?
    /// P0-5 / Wave1：与 ExportOptions 同名的输出规格字段（配方编辑器 W1-4 写入，
    /// 交付编排器 OutputService 逐字段透传给 ExportOptions）。
    ///
    /// 三个字段都是可选的：旧版持久化的配方 JSON 没有这些键，合成 `init(from:)`
    /// 对 optional 走 decodeIfPresent → nil = 保持原行为（不转换色彩/不写 DPI/不锐化），
    /// 老数据照常解码，不需要 schema 迁移。
    public var colorSpace: ExportColorSpace?
    public var dpi: Int?
    public var sharpening: ExportSharpening?
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
        colorSpace: ExportColorSpace? = nil,
        dpi: Int? = nil,
        sharpening: ExportSharpening? = nil,
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
        self.colorSpace = colorSpace
        self.dpi = dpi
        self.sharpening = sharpening
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
    /// 每张要画的展示字段。默认只文件名 —— 老配方/老测试的 PDF 逐字节不变。
    public var fields: ContactSheetFields
    /// caption 模板（{filename} {title} {rating} {label} {keywords} {date} …）。
    /// 未知占位符原样保留；默认 "{filename}" 与升级前 caption 同值。
    public var captionTemplate: String
    /// 色标圆点开关（还要 fields 含 .label 才画）。
    public var showLabelChip: Bool
    /// 取舍边框开关（还要 fields 含 .pick 才画）。
    public var showPickBorder: Bool

    public init(
        title: String = "",
        subtitle: String = "",
        footer: String = "",
        columns: Int = 4,
        rows: Int = 5,
        fields: ContactSheetFields = .legacy,
        captionTemplate: String = CaptionFormatter.defaultTemplate,
        showLabelChip: Bool = true,
        showPickBorder: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.fields = fields
        self.captionTemplate = captionTemplate
        self.showLabelChip = showLabelChip
        self.showPickBorder = showPickBorder
    }
}

public struct OutputRunInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var scope: ExportScope
    /// .selected 时必填；逐配方透传给 ExportOptions。
    public var selectedPhotoIds: [String]?
    public var destinationRoot: String
    public var recipes: [OutputRecipe]
    /// nil = 不生成联系表（配方里勾了 contactSheet 才生成）。
    public var contactSheet: OutputContactSheetOptions?
    /// nil = 不生成画廊（配方里勾了 gallery 才生成）。
    public var gallery: OutputGalleryOptions?

    public init(
        sessionId: String,
        scope: ExportScope = .session,
        selectedPhotoIds: [String]? = nil,
        destinationRoot: String,
        recipes: [OutputRecipe],
        contactSheet: OutputContactSheetOptions? = nil,
        gallery: OutputGalleryOptions? = nil
    ) {
        self.sessionId = sessionId
        self.scope = scope
        self.selectedPhotoIds = selectedPhotoIds
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
    /// 联系表/画廊里元数据缺失（无 photo_metadata_cache 行）的张数：
    /// 只降级为空字段，不影响交付结果。
    public var metadataMissing: Int?
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
        metadataMissing: Int? = nil,
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
        self.metadataMissing = metadataMissing
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
    /// 发布白名单（相对前缀）。**必填语义**：nil/空不再等于"上传整个目录"——
    /// 上层必须给出精确产物清单；发布器拿不到白名单时只按交付产物收窄
    /// （manifest / 联系表 / 画廊入口 / thumbs），绝不把成片目录或无关文件传上去。
    public var includePrefixes: [String]?
    /// 分享策略：allowDownload=false 只传 thumbs + 校样页（不传 large/成片）。
    /// nil = 保守默认（不允许下载大图）。
    public var share: OutputShareOptions?

    public init(
        localPath: String, baseURL: String, username: String, remoteFolder: String,
        includePrefixes: [String]? = nil,
        share: OutputShareOptions? = nil
    ) {
        self.localPath = localPath
        self.baseURL = baseURL
        self.username = username
        self.remoteFolder = remoteFolder
        self.includePrefixes = includePrefixes
        self.share = share
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


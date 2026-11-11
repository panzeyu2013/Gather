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
    /// Wave2：配方级输出子目录规则（token 模板）；nil = 不带子目录。
    /// 交付编排器把它逐字段透传给 ExportOptions.subdirectory。
    public var subdirectory: ExportSubdirectory?
    /// Wave2：配方级联系表参数。nil = 回落本次交付的 run 级参数
    /// （旧配方/旧任务 checkpoint 的兼容路径）；非 nil 时该配方用自己的版式。
    public var contactSheet: OutputContactSheetOptions?
    /// Wave2：配方级画廊参数。nil = 回落 run 级参数（兼容路径）。
    public var gallery: OutputGalleryOptions?
    public var artifacts: [OutputArtifactKind]
    /// Wave2 收尾：artifacts 一次性迁移标记。
    ///
    /// nil = 该配方还没跑过产物清单迁移（旧 JSON 没有此键，合成 Codable 走
    /// decodeIfPresent → nil，旧数据照常解码）；1 = 已按 Wave1 历史默认处理过。
    /// 迁移只在 VM 的 loadDeliveryRecipes 里写一次（见 ExportViewModel+Delivery）；
    /// 之后即使 artifacts 被用户改过也保持 marker=1，避免重复补回用户显式取消的产物。
    public var artifactsMigrationVersion: Int?

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
        subdirectory: ExportSubdirectory? = nil,
        contactSheet: OutputContactSheetOptions? = nil,
        gallery: OutputGalleryOptions? = nil,
        artifacts: [OutputArtifactKind] = [.photos],
        artifactsMigrationVersion: Int? = nil
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
        self.subdirectory = subdirectory
        self.contactSheet = contactSheet
        self.gallery = gallery
        self.artifacts = artifacts
        self.artifactsMigrationVersion = artifactsMigrationVersion
    }
}

public struct OutputContactSheetOptions: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var footer: String
    public var columns: Int
    public var rows: Int
    /// Wave2：页面边距（pt，A4@72dpi 的页面坐标）；nil = 渲染器默认 36。
    /// 只影响联系表版面，不改成片像素。
    public var margin: Double?
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
        margin: Double? = nil,
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
        self.margin = margin
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
        // 副产品：Wave2 收尾的迁移标记只是新旧版本间的元数据，也不参与交付身份；
        // 否则升级后首批 output.run 的去重键/续跑指纹会变，旧 checkpoint 无法复用。
        copy.artifactsMigrationVersion = nil
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

/// Wave3 / task-21：导出后命令钩子的执行结果。
///
/// 只记录「跑了什么、退没退、有没有超时、输出尾部」——不记录完整环境变量，
/// 也不把命令输出当错误抛出：钩子失败**只记日志并计入导出报告**，不改交付结果。
public struct OutputPostCommandOutcome: Codable, Equatable, Sendable {
    /// 展开占位符前的命令模板（用户配置值，便于审计）。
    public var command: String
    /// 正常退出时的退出码；启动失败/超时/被信号杀掉时为 nil。
    public var exitCode: Int?
    public var timedOut: Bool
    /// 从 launch 到进程结束/被终止的墙钟耗时。
    public var durationMilliseconds: Int
    /// 启动失败（不可执行、权限等）或超时终止的说明。
    public var error: String?
    /// stdout + stderr 的尾部（截断，最多几 KB）。
    public var outputTail: String?

    public init(
        command: String,
        exitCode: Int? = nil,
        timedOut: Bool = false,
        durationMilliseconds: Int = 0,
        error: String? = nil,
        outputTail: String? = nil
    ) {
        self.command = command
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationMilliseconds = durationMilliseconds
        self.error = error
        self.outputTail = outputTail
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
    /// Wave3 / task-21：导出后命令钩子结果（nil = 未配置/未运行）。
    /// 只在整套交付（runRecipes）完成后写入；旧 manifest 没有该键 → 解码为 nil。
    public var postCommand: OutputPostCommandOutcome?

    public init(
        runId: String,
        sessionId: String,
        manifestPath: String,
        createdAt: String,
        recipes: [OutputRecipeResult],
        manifestError: String? = nil,
        cancelled: Bool? = nil,
        postCommand: OutputPostCommandOutcome? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.manifestPath = manifestPath
        self.createdAt = createdAt
        self.recipes = recipes
        self.manifestError = manifestError
        self.cancelled = cancelled
        self.postCommand = postCommand
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
    /// Wave3：发布通道；可选，nil = webdav（旧调用/旧行为逐字不变）。
    /// transport = .s3 时：baseURL = S3 endpoint（可空 = 由 bucket+region 推 AWS 默认）、
    /// username = accessKeyID、remoteFolder = key 前缀；bucket/region 见下面两个可选字段。
    /// secret 不在此结构体：发布端用 Keychain 按 (endpoint, accessKeyID) 查。
    public var transport: OutputShareTransportKind?
    /// S3 通道：bucket（WebDAV 忽略；缺省空 = 发布时报参数错）。
    public var bucket: String?
    /// S3 通道：region（WebDAV 忽略；nil 默认 us-east-1）。
    public var region: String?
    /// S3 通道：可选 STS/Session Token（WebDAV 忽略）。
    /// 临时凭据（IAM role / SSO / STS）必须带；签名时作为 x-amz-security-token 参与。
    /// 持久化位置同 secret：只进 Keychain（与 secret 打包存储），不落 settings/日志。
    public var sessionToken: String?
    /// 分享策略：allowDownload=false 只传 thumbs + 校样页（不传 large/成片）。
    /// nil = 保守默认（不允许下载大图）。
    ///
    /// 口令（share.password）只用于本次发布派生哈希写进 share.json，明文不落盘。
    public var share: OutputShareOptions?

    public init(
        localPath: String, baseURL: String, username: String, remoteFolder: String,
        includePrefixes: [String]? = nil,
        transport: OutputShareTransportKind? = nil,
        bucket: String? = nil,
        region: String? = nil,
        sessionToken: String? = nil,
        share: OutputShareOptions? = nil
    ) {
        self.localPath = localPath
        self.baseURL = baseURL
        self.username = username
        self.remoteFolder = remoteFolder
        self.includePrefixes = includePrefixes
        self.transport = transport
        self.bucket = bucket
        self.region = region
        self.sessionToken = sessionToken
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
    /// Wave5：客户可打开的入口链接（画廊 `index.html`）。
    /// - S3 通道：AWS SigV4 **query-string 预签名 GET**（URL 只含 accessKeyID 与签名，
    ///   secret 不进 URL/日志；对象仍默认私有）；到期见 `entryURLExpiresAt`。
    /// - WebDAV 通道：`endpoint + 远端目录 + index.html` 拼出的静态链接
    ///   （要求服务器自身把 index.html 当目录首页或允许直接访问）。
    /// nil = 本次发布没有画廊入口，或入口文件没有上传成功（不提供无效链接）。
    public var entryURL: String?
    /// Wave5：`entryURL` 的到期时间（ISO-8601）；nil = 永久链接（WebDAV）。
    public var entryURLExpiresAt: String?
    /// Wave5：本次因「远端未变」而跳过的文件数（HEAD 差分命中发布记录）。
    /// 跳过的文件仍视为已在远端就绪，会计入 `entryURL` 的可用性判断。
    public var skipped: Int
    /// Wave5：跳过原因 → 次数（raw value 见 `OutputShareSkipReason`；空 = 没有跳过）。
    public var skipReasons: [String: Int]?

    public init(
        uploaded: Int,
        failed: [WebDAVPublishFailureInfo],
        remoteRoot: String,
        abortedOnAuth: Bool,
        entryURL: String? = nil,
        entryURLExpiresAt: String? = nil,
        skipped: Int = 0,
        skipReasons: [String: Int]? = nil
    ) {
        self.uploaded = uploaded
        self.failed = failed
        self.remoteRoot = remoteRoot
        self.abortedOnAuth = abortedOnAuth
        self.entryURL = entryURL
        self.entryURLExpiresAt = entryURLExpiresAt
        self.skipped = skipped
        self.skipReasons = skipReasons
    }

    public var isSuccess: Bool { failed.isEmpty && !abortedOnAuth }
}

/// Wave5：读取发布历史的输入（交付目录里读 `.gather-share-publish.json`）。
public struct PublishHistoryInput: Codable, Equatable, Sendable {
    /// 本地交付目录（或发布文件所在目录）。
    public var localPath: String
    /// 最多返回几条（1...20；默认 5）。
    public var limit: Int

    public init(localPath: String, limit: Int = 5) {
        self.localPath = localPath
        self.limit = limit
    }
}

/// Wave5：一条发布历史（跨重启可见；来自交付目录里的发布记录文件）。
///
/// 不含文件清单与任何凭据：历史只用于「这次发到哪、结果如何、客户链接」。
public struct WebDAVPublishHistoryEntry: Codable, Equatable, Hashable, Sendable {
    public var publishedAt: String
    public var transport: OutputShareTransportKind
    /// 通道 + 远端根（已去掉 URL 里的 userinfo/query，无凭据）。
    public var endpointSummary: String
    public var remoteFolder: String
    public var entryURL: String?
    public var uploaded: Int
    public var skipped: Int
    public var failed: Int

    public var id: String {
        publishedAt + "|" + transport.rawValue + "|" + endpointSummary + "|" + remoteFolder
    }

    public init(
        publishedAt: String,
        transport: OutputShareTransportKind,
        endpointSummary: String,
        remoteFolder: String,
        entryURL: String?,
        uploaded: Int,
        skipped: Int,
        failed: Int
    ) {
        self.publishedAt = publishedAt
        self.transport = transport
        self.endpointSummary = endpointSummary
        self.remoteFolder = remoteFolder
        self.entryURL = entryURL
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
    }
}

/// Wave3：发布失败分类（按 reason 推断，供 UI 报告"认证/网络/服务端/校验/本地 IO"）。
public extension WebDAVPublishFailureInfo {
    var category: OutputShareFailureCategory {
        OutputShareFailureCategory.infer(fromReason: reason)
    }
}

public extension WebDAVPublishSummary {
    /// 各分类的失败计数（报告用；空 = 没有失败）。
    var failureCategories: [OutputShareFailureCategory: Int] {
        var counts: [OutputShareFailureCategory: Int] = [:]
        for failure in failed {
            counts[failure.category, default: 0] += 1
        }
        return counts
    }
}

/// 保存 WebDAV 凭据（密码只进 Keychain，不落 settings/日志）。
///
/// Wave3：S3 兼容存储复用本入口——baseURL 传 endpoint、username 传 accessKeyID、
/// password 传 secretAccessKey，同样只进 Keychain（kSecClassInternetPassword）。
public struct WebDAVCredentialInput: Codable, Equatable, Sendable {
    public var baseURL: String
    public var username: String
    public var password: String
    /// S3 可选 STS/Session Token（WebDAV 忽略）。Host 侧与 password 打包进同一条
    /// Keychain item（不新增 schema/不落库）；明文同样只在内存与 Keychain。
    public var sessionToken: String?

    public init(
        baseURL: String, username: String, password: String,
        sessionToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.sessionToken = sessionToken
    }
}


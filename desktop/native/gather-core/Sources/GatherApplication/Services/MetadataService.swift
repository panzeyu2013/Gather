// desktop/native/gather-core/Sources/GatherApplication/Services/MetadataService.swift
// TS 源: desktop/src/main/services/metadata/metadata.service.ts（536 行，逐字移植）
//
// 注入点差异（host 职责，与 SimilarityService 同款注入模式）：
// - TS 的 exifr.parse 经 ExifProvider 注入（分段输出 ifd0/exif/gps/xmp/dc/iptc，
//   与 `{ xmp: true, iptc: true, mergeOutput: false }` 选项对齐）；缺失时退化到
//   ImageDimensionsProvider（sharp 兜底）。
// - TS 的 sharp(filePath).metadata() 经 ImageDimensionsProvider 注入。
// - TS `MetadataWriterRouter.selectForRead()`（JPEG 内嵌 XMP）经 EmbeddedXMPReader
//   注入；RAW/侧车模式与 selectSidecar 统一由 XMPProvider 服务（TS 中
//   selected === sidecar 分支的映射）。exiftool/文件系统实现留在 gather-app。
// - 指纹/缓存过期判定（cacheStalenessKey）为纯逻辑，真实文件系统直接计算。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

public enum MetadataServiceError: Error, Equatable, CustomStringConvertible {
    /// TS: `Metadata writeback does not support these fields: ${fields}`
    case unsupportedFields([String])
    /// P1 / IPTC：只读元数据详情请求的照片不存在（API 层映射 PHOTO_NOT_FOUND）。
    case photoNotFound(String)
    /// 入队成功但写盘执行器失败（P1-9）：交付项保留在队列里，可经 executePending 重试。
    case writebackFailed(String)

    public var description: String {
        switch self {
        case .unsupportedFields(let fields):
            "Metadata writeback does not support these fields: \(fields.joined(separator: ", "))"
        case .photoNotFound(let photoId):
            "Photo not found: \(photoId)"
        case .writebackFailed(let message):
            message.isEmpty ? "METADATA_WRITEBACK_FAILED" : message
        }
    }
}

/// 手动元数据队列的写盘执行器接缝（P1-9）。
///
/// 宿主注入的参数是 sessionId；模块在组合根绑定为 "metadata"（core 不硬编码宿主
/// 的写回模块名）。返回 WritebackResult 让调用方能把逐项失败上抛给用户。
public typealias MetadataQueueFlush = @Sendable (String) async throws -> WritebackResult

/// 逐张属性写入的结果（模板 / triage 共用）。
public struct MetadataAttributesApplyOutcome: Equatable, Sendable {
    public var written: [String]
    /// 已提交给执行器且未被明确报错的照片（含回读校验失败者）。
    /// P0 / A2 起只作为诊断口径；批次裁剪统一用 written ∪ uncertain。
    public var attempted: [String]
    public var skipped: [String]
    public var failed: [MetadataApplyFailure]
    /// P0 / A2：写入已执行但回读失败/校验不符——**可能已写盘**。
    /// 撤销批次必须包含它们（与 written 并集），否则会出现"盘上已改、批次里没有"。
    /// 与 failed 有交集（failed 保留可读错误信息），调用方不得用 failed 反推"没写"。
    public var uncertain: [String]
    public init(
        written: [String],
        attempted: [String] = [],
        skipped: [String],
        failed: [MetadataApplyFailure],
        uncertain: [String] = []
    ) {
        self.written = written
        self.attempted = attempted
        self.skipped = skipped
        self.failed = failed
        self.uncertain = uncertain
    }

    /// 可能已落盘、需要进撤销批次的照片（去重保序）。
    public var undoable: [String] {
        var seen = Set<String>()
        return (written + uncertain).filter { seen.insert($0).inserted }
    }
}

/// TS: metadata.service.ts 的 photos 轻查询行。
/// Swift 6：batchAsync 的 worker 子任务会捕获本行（T: Sendable 约束），
/// 全字段均为不可变值类型，补上 Sendable 是纯增量的编译期事实。
/// WP3b-1：查询已下沉到 PhotoRepo.getLookupByIds；类型保留为 Persistence 投影的
/// 公开别名，调用方（MetadataService 内部）无需改字段访问。
public typealias MetadataPhotoLookup = PhotoLookupRow

/// getMetadata 的并发收集盒子：batchAsync 的 body 由多个 worker 并发调用，
/// 捕获的可变集合必须串行写入（Dictionary/Array 并发写会内存损坏）。
/// `@unchecked Sendable` 的依据：全部可变状态（`fingerprints`/`result`/
/// `pendingUpserts`）只在 `lock`（NSLock）临界区内通过同步方法读写；
/// 并发阶段结束后由调用方经 snapshot 一次性取走（此后无写者）。
private final class MetadataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: [String: (size: Int, value: String)] = [:]
    private var result: [String: MetadataTags] = [:]
    private var pendingUpserts: [(photoId: String, sessionId: String, input: MetadataCacheInput)] = []

    func recordFingerprint(photoId: String, fingerprint: (size: Int, value: String)) {
        lock.lock()
        defer { lock.unlock() }
        fingerprints[photoId] = fingerprint
    }

    func recordResult(photoId: String, tags: MetadataTags) {
        lock.lock()
        defer { lock.unlock() }
        result[photoId] = tags
    }

    func recordExtraction(photoId: String, sessionId: String, tags: MetadataTags, cacheInput: MetadataCacheInput) {
        lock.lock()
        defer { lock.unlock() }
        result[photoId] = tags
        pendingUpserts.append((photoId, sessionId, cacheInput))
    }

    func snapshotFingerprints() -> [String: (size: Int, value: String)] {
        lock.lock()
        defer { lock.unlock() }
        return fingerprints
    }

    func snapshotPendingUpserts() -> [(photoId: String, sessionId: String, input: MetadataCacheInput)] {
        lock.lock()
        defer { lock.unlock() }
        return pendingUpserts
    }

    func snapshotResult() -> [String: MetadataTags] {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// TS: MetadataService。
/// 线程安全说明（Swift 6 `Sendable`）：本类无任何可变状态——全部存储属性
/// （`metadataCacheRepo`/`xmp`/`connection`/`mutations`/`flushPending`/
/// `assetResolver`/`exif`/`dimensions`/`embeddedReader`）都是 `let`，构造后不可变，
/// 故无需锁。
/// 标注 `@unchecked` 仅因为依赖的仓库/协议存在类型未标 `Sendable`；
/// 并发收集状态全部收在上面两个锁盒子里。
public final class MetadataService: @unchecked Sendable {
    private let metadataCacheRepo: any MetadataRepository
    private let xmp: any XMPProvider
    private let photoRepo: any PhotoRepository
    private let transactions: any TransactionRunner
    private let mutations: any MetadataMutationPort
    /// 入队后的写盘执行器（P1-9；nil = 只入队，兼容旧测试/无写回宿主）。
    private let flushPending: MetadataQueueFlush?
    /// 显式重试入口（含 failed 项）；nil = 退回 flushPending。
    private let retryFlush: MetadataQueueFlush?
    private let assetResolver: PhotoAssetResolver?
    private let exif: (any ExifProvider)?
    private let dimensions: (any ImageDimensionsProvider)?
    private let embeddedReader: (any EmbeddedXMPReader)?
    /// K0：生成词来源（face/similarity/culling/template），用于阻止删除。
    private let origins: MetadataKeywordOriginRepo?
    /// 写目标解析（侧车 / 内嵌）：信息面板必须显示**真实写入位置**，不能恒说侧车。
    private let writeTarget: (@Sendable (String) -> MetadataTarget)?

    public init(
        metadataCacheRepo: any MetadataRepository,
        xmp: any XMPProvider,
        photoRepo: any PhotoRepository,
        transactions: any TransactionRunner,
        mutations: any MetadataMutationPort,
        flushPending: MetadataQueueFlush? = nil,
        retryFlush: MetadataQueueFlush? = nil,
        assetResolver: PhotoAssetResolver? = nil,
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil,
        origins: MetadataKeywordOriginRepo? = nil,
        writeTarget: (@Sendable (String) -> MetadataTarget)? = nil
    ) {
        self.metadataCacheRepo = metadataCacheRepo
        self.xmp = xmp
        self.photoRepo = photoRepo
        self.transactions = transactions
        self.mutations = mutations
        self.flushPending = flushPending
        self.retryFlush = retryFlush
        self.assetResolver = assetResolver
        self.exif = exif
        self.dimensions = dimensions
        self.embeddedReader = embeddedReader
        self.origins = origins
        self.writeTarget = writeTarget
    }

    // MARK: - TS 顶层函数

    /// TS: cacheRowToTags。
    private func cacheRowToTags(_ row: MetadataCacheRow) -> MetadataTags {
        let keywords = row.keywords
        return MetadataTags(
            fileSize: row.fileSize.map { Int($0) },
            width: row.width.map { Int($0) },
            height: row.height.map { Int($0) },
            make: row.cameraMake,
            model: row.cameraModel,
            lensModel: row.lensModel,
            focalLength: row.focalLength,
            aperture: row.fNumber,
            shutterSpeed: row.exposureTime,
            iso: row.iso.map { Int($0) },
            dateTaken: row.dateTaken,
            keywords: keywords.isEmpty ? nil : keywords,
            rating: Double(row.rating),
            label: row.label,
            latitude: row.gpsLatitude,
            longitude: row.gpsLongitude
        )
    }

    /// TS: tagsToCacheInput。
    private func tagsToCacheInput(_ tags: MetadataTags) -> MetadataCacheInput {
        MetadataCacheInput(
            dateTaken: tags.dateTaken,
            cameraMake: tags.make,
            cameraModel: tags.model,
            lensModel: tags.lensModel,
            focalLength: tags.focalLength,
            fNumber: tags.aperture,
            exposureTime: tags.shutterSpeed,
            iso: tags.iso.map { Int64($0) },
            rating: tags.rating.map { Int64($0) },
            label: tags.label,
            gpsLatitude: tags.latitude,
            gpsLongitude: tags.longitude,
            width: tags.width.map { Int64($0) },
            height: tags.height.map { Int64($0) },
            fileSize: tags.fileSize.map { Int64($0) },
            keywords: tags.keywords
        )
    }

    /// TS: normalizeKeywordList —— 镜像 EmbeddedWriter 对 exifr 关键词列表的归一化
    /// （单值到达为标量）。
    public static func normalizeKeywordList(_ value: JSONValue?) -> [String]? {
        let strings: [String]
        switch value {
        case .array(let items):
            strings = items.compactMap { item in
                if let s = item.stringValue { return s }
                if let n = item.numberValue { return keywordString(n) }
                return nil
            }
        case .none, .null:
            strings = []
        case .some(let scalar):
            if let s = scalar.stringValue {
                strings = [s]
            } else if let n = scalar.numberValue {
                strings = [keywordString(n)]
            } else {
                strings = []
            }
        }
        return strings.isEmpty ? nil : strings
    }

    // MARK: - 有效属性合成

    /// TS: readEffectiveAttributes —— 内嵌读取 + 侧车读取合并（后者覆盖前者）。
    private func readEffectiveAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        if let embeddedReader {
            let embedded = try await embeddedReader.readAttributes(photoPath: photoPath)
            let sidecar = try await xmp.readAttributes(photoPath: photoPath)
            return mergeAttributes(embedded, sidecar)
        }
        return try await xmp.readAttributes(photoPath: photoPath)
    }

    /// P0 / B1：**盘上现状**的统一读取入口（模板预览/写回、triage undo 用）。
    ///
    /// 与 readEffectiveAttributesOnce 的差别：
    /// - 面向"任意路径"（不是 session 内照片），不做缓存投影；
    /// - JPEG 走内嵌解析（XMP + IPTC）再叠加侧车；RAW 只读侧车；
    /// - 解析失败不抛错，退化为侧车读（模板 preview 的 disk=nil 语义由调用方处理）。
    ///
    /// 为什么必须读内嵌：Bridge/Lightroom 把 caption/版权写在 JPEG 的 IPTC-IIM 里，
    /// 只读 .xmp 会让 preview 把"盘上已有值"当成未知（keepExternal 失效），
    /// 也会让 triage undo 拿到错误的"当前星级"。
    public func diskAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let sidecar = try await xmp.readAttributes(photoPath: photoPath)
        return await diskSnapshot(photoPath: photoPath, sidecar: sidecar).attributes
    }

    /// 盘上合成值 + "内嵌是否读得到"。
    ///
    /// P1：JPEG 的 APP1 读不到时（parse 返回 nil 或抛错）不能当成"没有内嵌信息"——
    /// 清空类写入在看不到内嵌值的情况下必须按**不确定**处理，否则会谎报清空成功。
    struct DiskSnapshot {
        let attributes: MetadataWriteAttributes
        let embeddedReadable: Bool
    }

    /// 已读侧车的盘上值合成（写后回读用：一次侧车读同时服务校验与缓存投影）。
    ///
    /// P1：JPEG 必须叠加内嵌 IPTC/XMP。侧车只是 JPEG 的"可写投影"，Bridge/C1
    /// 写的标题/版权仍在 APP1 里；只看侧车会把它们从缓存投影里清掉。
    private func diskSnapshot(
        photoPath: String,
        sidecar: MetadataWriteAttributes
    ) async -> DiskSnapshot {
        guard Self.isJpegPath(photoPath), let exif else {
            return DiskSnapshot(attributes: sidecar, embeddedReadable: true)
        }
        do {
            guard let parsed = try await exif.parse(filePath: photoPath, isJpeg: true) else {
                // 读不到 APP1：无法判定内嵌值，标记不可读。
                return DiskSnapshot(attributes: sidecar, embeddedReadable: false)
            }
            guard let embedded = MetadataService.embeddedAttributesFromParse(parsed) else {
                return DiskSnapshot(attributes: sidecar, embeddedReadable: true)
            }
            return DiskSnapshot(
                attributes: mergeAttributes(embedded, sidecar), embeddedReadable: true)
        } catch {
            // 内嵌解析失败：退化为只读侧车（面板不阻断），但标记不可读供清空判定用。
            GatherLogger.log(
                "diskAttributes embedded parse failed (path token=\(TSPath.basename(photoPath))): "
                    + "\(error)", level: .debug)
            return DiskSnapshot(attributes: sidecar, embeddedReadable: false)
        }
    }

    /// JPEG 判定（扩展名大小写不敏感）。
    static func isJpegPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    }

    /// TS: readEffectiveAttributesOnce —— 单次读取路径：
    /// - RAW / sidecar-mode（TS: selected === sidecar）：一次侧车读。
    /// - JPEG 且内嵌派生可用（IPTC-only 关键词之外）：从已解析段派生 + 一次侧车读。
    /// - 其余回退 readEffectiveAttributes（exiftool 池）。
    private func readEffectiveAttributesOnce(
        photoPath: String,
        parsed: MetadataParseSegments,
        isJpeg: Bool
    ) async throws -> MetadataWriteAttributes {
        if !isJpeg {
            return try await xmp.readAttributes(photoPath: photoPath)
        }
        if let embedded = MetadataService.embeddedAttributesFromParse(parsed) {
            let sidecar = try await xmp.readAttributes(photoPath: photoPath)
            return mergeAttributes(embedded, sidecar)
        }
        return try await readEffectiveAttributes(photoPath: photoPath)
    }

    /// TS: `{ ...selectedAttributes, ...sidecarAttributes }`（后者按 key 覆盖）。
    private func mergeAttributes(
        _ base: MetadataWriteAttributes,
        _ overlay: MetadataWriteAttributes
    ) -> MetadataWriteAttributes {
        MetadataWriteAttributes(
            keywords: overlay.keywords ?? base.keywords,
            rating: overlay.rating ?? base.rating,
            label: overlay.label ?? base.label,
            dateTaken: overlay.dateTaken ?? base.dateTaken,
            latitude: overlay.latitude ?? base.latitude,
            longitude: overlay.longitude ?? base.longitude,
            // P0 / B1：描述性元数据**逐字段**合并（侧车覆盖内嵌，内嵌补侧车空缺）。
            // 旧实现整块 overlay：侧车只要有一个字段，JPEG 里的其它 IPTC 就全丢。
            descriptive: Self.mergeDescriptive(base.descriptive, overlay.descriptive)
        )
    }

    /// 逐字段合并：overlay 的非 nil 字段覆盖 base（nil = 该来源没有该字段）。
    static func mergeDescriptive(
        _ base: DescriptiveMetadata?,
        _ overlay: DescriptiveMetadata?
    ) -> DescriptiveMetadata? {
        switch (base, overlay) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let overlay?): return overlay
        case (let base?, let overlay?): return base.applying(overlay)
        }
    }

    /// TS: embeddedAttributesFromParse —— 从已解析段派生内嵌可写属性：
    /// - keywords：XMP dc:subject 优先于 IPTC Keywords；
    /// - rating：xmp:Rating ?? IFD0 Rating（数字或数字字符串）；
    /// - label：xmp:Label；
    /// - descriptive：dc / xmp / IPTC-IIM 的字段映射（P0 / B1）。
    ///
    /// 旧实现在"只有 IPTC 关键词"时返回 nil（TS 的 exifr 字符集不可靠）。
    /// ImageIO 实现下不成立：CGImageProperties 会把 IIM 合成为 dc:subject，
    /// 且字符串是原生 Swift String；保留该分支只会把可读文件推给未接线的
    /// EmbeddedXMPReader（等价于丢失描述性元数据）。
    public static func embeddedAttributesFromParse(_ parsed: MetadataParseSegments) -> MetadataWriteAttributes? {
        let xmp = parsed.xmp
        let dc = parsed.dc
        let iptc = parsed.iptc
        let ifd0 = parsed.ifd0
        let rawRating = xmp?["Rating"] ?? ifd0?["Rating"]
        let rating: Double?
        if let number = rawRating?.numberValue {
            rating = number
        } else if let string = rawRating?.stringValue, let parsedNumber = Double(string), parsedNumber.isFinite {
            rating = parsedNumber
        } else {
            rating = nil
        }
        // 关键词同样要做 presence 阻断：外部只清空 XMP 的 dc:subject 时，
        // ImageIO 会把 IIM 旧关键词合成回 dc:subject（实测），不判 presence 会复活旧值。
        let keywords: [String]? = if parsed.xmpPresentKeys.contains("subject") {
            MetadataService.normalizeKeywordList(dc?["subject"])
        } else {
            MetadataService.normalizeKeywordList(dc?["subject"] ?? iptc?["Keywords"])
        }
        let descriptive = descriptiveFromParse(parsed)
        if keywords == nil, rating == nil, xmp?["Label"] == nil, descriptive.isEmpty {
            return nil
        }
        return MetadataWriteAttributes(
            keywords: keywords,
            rating: rating,
            label: xmp?["Label"]?.stringValue,
            descriptive: descriptive.isEmpty ? nil : descriptive
        )
    }

    /// 内嵌描述性元数据映射（键表与 ImageIO 的 IPTC 常量逐字一致）。
    ///
    /// 取值优先级：dc（XMP 原生）→ xmp（其它命名空间的本地名）→ IPTC-IIM
    /// （Bridge/Lightroom 常写的形态）。每个字段独立取第一个非空值。
    ///
    /// P1：改为表驱动——旧实现逐行手写，漏了计划验收明确要求的 `location`；
    /// 新增字段只需加一行表项，并由一组真实 JPEG 映射测试兜住。
    private struct EmbeddedDescriptiveField {
        let field: DescriptiveField
        var dcKeys: [String] = []
        var xmpKeys: [String] = []
        var iimKeys: [String] = []
        var isList = false
    }

    private static let embeddedDescriptiveFields: [EmbeddedDescriptiveField] = [
        .init(field: .title, dcKeys: ["title"], iimKeys: ["ObjectName"]),
        .init(field: .caption, dcKeys: ["description"], iimKeys: ["Caption/Abstract"]),
        .init(field: .creator, dcKeys: ["creator"], iimKeys: ["Byline"], isList: true),
        .init(field: .copyrightNotice, dcKeys: ["rights"], iimKeys: ["CopyrightNotice"]),
        .init(field: .creatorJobTitle, xmpKeys: ["AuthorsPosition"], iimKeys: ["BylineTitle"]),
        .init(field: .credit, xmpKeys: ["Credit"], iimKeys: ["Credit"]),
        .init(field: .source, xmpKeys: ["Source"], iimKeys: ["Source"]),
        .init(field: .headline, xmpKeys: ["Headline"], iimKeys: ["Headline"]),
        .init(field: .captionWriter, xmpKeys: ["CaptionWriter"], iimKeys: ["Writer/Editor"]),
        .init(field: .jobIdentifier, xmpKeys: ["TransmissionReference"],
              iimKeys: ["OriginalTransmissionReference"]),
        // 实测：ImageIO 把 UsageTerms 写在 XMP，IIM 无对应 dataset（2:130 读作 ImageType），
        // 因此不做 IIM 回退——否则清空 XMP 后旧 IIM 会把字段复活。
        .init(field: .usageTerms, xmpKeys: ["UsageTerms"]),
        // IPTC Core 的 WebStatement 只在 XMP 命名空间（xmpRights），没有 IIM 对应。
        .init(field: .webStatement, xmpKeys: ["WebStatement"]),
        .init(field: .city, xmpKeys: ["City"], iimKeys: ["City"]),
        .init(field: .state, xmpKeys: ["State"], iimKeys: ["Province/State"]),
        .init(field: .country, xmpKeys: ["Country"], iimKeys: ["Country/PrimaryLocationName"]),
        .init(field: .countryCode, xmpKeys: ["CountryCode"],
              iimKeys: ["Country/PrimaryLocationCode"]),
        .init(field: .sublocation, xmpKeys: ["Sublocation"], iimKeys: ["SubLocation"]),
        // 计划 B1 验收字段：旧实现漏了这一行。
        .init(field: .location, xmpKeys: ["Location"], iimKeys: ["ContentLocationName"]),
        .init(field: .intellectualGenre, xmpKeys: ["IntellectualGenre"],
              iimKeys: ["ObjectAttributeReference"]),
        .init(field: .subjectCode, xmpKeys: ["SubjectCode"], iimKeys: ["SubjectReference"],
              isList: true),
        .init(field: .dateCreated, xmpKeys: ["DateCreated"], iimKeys: ["DateCreated"]),
        // IIM 2:202（实测 ImageIO 读回键名 Scene）：写侧已映射，清空时删 dataset。
        .init(field: .scene, xmpKeys: ["Scene"], iimKeys: ["Scene"], isList: true),
        .init(field: .event, xmpKeys: ["Event"]),
        .init(field: .personInImage, xmpKeys: ["PersonInImage"], isList: true),
        .init(field: .organisationInImage, xmpKeys: ["OrganisationInImageName"], isList: true),
        .init(field: .worldRegion, xmpKeys: ["WorldRegion"]),
        .init(field: .provinceState, xmpKeys: ["ProvinceState"]),
        .init(field: .modelReleaseStatus, xmpKeys: ["ModelReleaseStatus"]),
        .init(field: .propertyReleaseStatus, xmpKeys: ["PropertyReleaseStatus"]),
        .init(field: .digitalSourceType, xmpKeys: ["DigitalSourceType"]),
        .init(field: .additionalModelInfo, xmpKeys: ["AddlModelInfo"]),
    ]

    static func descriptiveFromParse(_ parsed: MetadataParseSegments) -> DescriptiveMetadata {
        var result = DescriptiveMetadata()
        for spec in embeddedDescriptiveFields {
            // 内嵌 XMP 里存在该键（哪怕值是空）= 用户显式清空过：不得再回退到 IIM，
            // 否则旧 IIM 会把已清空的字段"复活"（写侧已删 dataset，这里兜住外部残留）。
            let blockedByExplicitEmpty = (spec.dcKeys + spec.xmpKeys)
                .contains { parsed.xmpPresentKeys.contains($0) }
            if spec.isList {
                let list = firstList(parsed, keys: spec.dcKeys, isDC: true)
                    ?? firstList(parsed, keys: spec.xmpKeys, isDC: false)
                    ?? (blockedByExplicitEmpty
                        ? nil
                        : firstList(parsed, keys: spec.iimKeys, isIIM: true))
                if let list { result.set(.list(list), for: spec.field) }
            } else {
                let text = firstText(parsed, keys: spec.dcKeys, isDC: true)
                    ?? firstText(parsed, keys: spec.xmpKeys, isDC: false)
                    ?? (blockedByExplicitEmpty
                        ? nil
                        : firstText(parsed, keys: spec.iimKeys, isIIM: true))
                if let text { result.set(.text(text), for: spec.field) }
            }
        }
        // Iptc4xmpCore:CreatorContactInfo 是结构（ImageIO 返回字典），不能走
        // 上面的单值表；缺映射时 JPEG 清空联系人永远会被判"成功"。
        if let contact = contactFromParse(parsed) {
            result.contactInfo = contact
        }
        return result
    }

    /// 内嵌 IPTC Core 联系人结构（CreatorContactInfo 的成员名去掉前缀）。
    ///
    /// ImageIO 的 CGImageMetadataCopyTags 会把结构成员暴露为字典键
    /// CiAdrCity / CiEmailWork …；成员表与写入端共用 DescriptiveContact.members。
    private static func contactFromParse(_ parsed: MetadataParseSegments) -> DescriptiveContact? {
        guard case .object(let object)? = parsed.xmp?["CreatorContactInfo"] else { return nil }
        var contact = DescriptiveContact()
        for (key, qname) in DescriptiveContact.members {
            let local = qname.split(separator: ":").last.map(String.init) ?? qname
            guard let text = textValue(object[local]), !text.isEmpty else { continue }
            switch key {
            case "city": contact.city = text
            case "country": contact.country = text
            case "address": contact.address = text
            case "postalCode": contact.postalCode = text
            case "region": contact.region = text
            case "email": contact.email = text
            case "telephone": contact.telephone = text
            case "url": contact.url = text
            default: break
            }
        }
        return contact.isEmpty ? nil : contact
    }

    private static func firstText(
        _ parsed: MetadataParseSegments, keys: [String], isDC: Bool = false, isIIM: Bool = false
    ) -> String? {
        let segment = isIIM ? parsed.iptc : (isDC ? parsed.dc : parsed.xmp)
        for key in keys {
            if let text = textValue(segment?[key]), !text.isEmpty { return text }
        }
        return nil
    }

    private static func firstList(
        _ parsed: MetadataParseSegments, keys: [String], isDC: Bool = false, isIIM: Bool = false
    ) -> [String]? {
        let segment = isIIM ? parsed.iptc : (isDC ? parsed.dc : parsed.xmp)
        for key in keys {
            if let list = listValue(segment?[key]), !list.isEmpty { return list }
        }
        return nil
    }

    /// ImageIO 的 rdf:Alt 值是「带 qualifier 的 tag 数组」（如 dc:title 返回 [tag]）：
    /// 标量原样取，数组取首个字符串元素，数字转字符串。
    static func textValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        if let number = value.numberValue {
            return number.rounded() == number ? String(Int(number)) : String(number)
        }
        if let items = value.arrayElements {
            for item in items {
                if let text = textValue(item), !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// 列表型字段：数组取全部字符串；标量视为单元素列表（逗号不拆，关键词里可能有逗号）。
    static func listValue(_ value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        if let items = value.arrayElements {
            let strings = items.compactMap { textValue($0) }.filter { !$0.isEmpty }
            return strings.isEmpty ? nil : strings
        }
        if let text = textValue(value), !text.isEmpty { return [text] }
        return nil
    }

    /// TS: getPhotosByIds —— 800/块 IN 查询（镜像缓存仓库的分块，低于 SQLite
    /// 常见参数上限）。
    public func getPhotosByIds(_ photoIds: [String]) throws -> [MetadataPhotoLookup] {
        try photoRepo.getLookupByIds(photoIds)
    }

    /// P1 / IPTC：单张照片的只读元数据详情。
    ///
    /// 只读缓存投影：**不触发磁盘解析**（面板翻页不得产生 N 次 IO）。
    /// 缓存行缺失时返回空快照与空描述性元数据，而不是抛错 —— "尚未扫描"是正常态。
    public func photoDetail(photoId: String) throws -> PhotoMetadataDetail {
        guard let lookup = try photoRepo.getLookupByIds([photoId]).first else {
            throw MetadataServiceError.photoNotFound(photoId)
        }
        let row = try metadataCacheRepo.get(photoId)
        // asset_read_mode=asset 时写盘/预览都必须用解析后的资产路径；photos.filepath
        // 可能还是旧路径（写回执行器同样经 resolver），否则会读错侧车。
        let resolved = try? assetResolver?.resolve(sessionId: lookup.sessionId, photoId: photoId)
        let filepath = resolved?.filepath ?? lookup.filepath
        let filename = (filepath as NSString).lastPathComponent
        // 写目标优先用注入的解析器：内嵌模式下「写目标」就是照片本身，
        // 面板若仍显示侧车路径，用户会误判写回失败（EMBEDDED 模式下恒显示「尚未写入 XMP」）。
        let target = writeTarget?(filepath)
        let xmpPath = target?.writePath ?? resolved?.xmpPath ?? TSPath.xmpSidecarPath(filepath)
        let exif = PhotoExifSnapshot(
            dateTaken: row?.dateTaken,
            cameraMake: row?.cameraMake,
            cameraModel: row?.cameraModel,
            lensModel: row?.lensModel,
            focalLength: row?.focalLength,
            fNumber: row?.fNumber,
            exposureTime: row?.exposureTime,
            iso: row?.iso.map { Int($0) },
            gpsLatitude: row?.gpsLatitude,
            gpsLongitude: row?.gpsLongitude,
            width: row?.width.map { Int($0) },
            height: row?.height.map { Int($0) },
            fileSize: row?.fileSize.map { Int($0) },
            fileMtime: row?.fileMtime,
            rating: Int(row?.rating ?? 0),
            label: row?.label,
            keywords: row?.keywords ?? []
        )
        return PhotoMetadataDetail(
            photoId: photoId,
            sessionId: lookup.sessionId,
            filepath: filepath,
            filename: filename,
            xmpPath: xmpPath,
            hasXMP: xmp.fileExists(xmpPath),
            exif: exif,
            descriptive: row?.descriptive ?? DescriptiveMetadata(),
            cachedAt: row?.cachedAt ?? "",
            updatedAt: row?.updatedAt ?? ""
        )
    }

    /// TS: preserveValuesOnCorruptSidecar —— 损坏 sidecar 让 readAttributes 返回
    /// 空对象；没有该守卫缓存会被空值覆盖，直到文件再次变更前有效值全失。
    private func preserveValuesOnCorruptSidecar(
        photoId: String,
        filepath: String,
        attributes: inout MetadataWriteAttributes
    ) {
        if !attributes.isEmpty { return }
        if !xmp.fileExists(TSPath.xmpSidecarPath(filepath)) { return }
        guard let previous = try? metadataCacheRepo.get(photoId) else { return }
        let previousKeywords = previous.keywords
        if !previousKeywords.isEmpty { attributes.keywords = previousKeywords }
        if previous.rating != 0 { attributes.rating = Double(previous.rating) }
        if previous.label != nil { attributes.label = previous.label }
        // P1 / IPTC：损坏侧车读不出 IPTC 时同样保留旧投影，避免一次坏文件清空面板。
        let previousDescriptive = previous.descriptive
        if !previousDescriptive.isEmpty { attributes.descriptive = previousDescriptive }
    }

    // MARK: - 公开 API

    /// TS: getMetadata —— 指纹失效检查 → 缓存命中 / 缺失提取（EXIF → sharp 兜底）
    /// → 批量事务 upsert。
    public func getMetadata(photoIds: [String]) async throws -> [String: MetadataTags] {
        let allPhotos = try getPhotosByIds(photoIds)
        let photoById = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })
        // batchAsync 的 body 由多个 worker 并发调用：捕获的可变集合必须串行写入。
        // Swift 的 Dictionary/Array 非线程安全，并发下标写/append 会内存损坏
        // （实测 SIGSEGV 或静默丢行），故收集动作统一收进 MetadataCollector 的锁内。
        let collector = MetadataCollector()
        _ = try await batchAsync(allPhotos, concurrency: 16) { photo in
            if let fingerprint = try? await MetadataFingerprint.cacheStalenessKey(photo.filepath) {
                collector.recordFingerprint(photoId: photo.id, fingerprint: fingerprint)
            }
        }
        let fingerprints = collector.snapshotFingerprints()
        let cached = try metadataCacheRepo.getBatch(photoIds).filter { row in
            guard let fingerprint = fingerprints[row.photoId] else { return false }
            return row.fileSize == Int64(fingerprint.size) && row.fileMtime == fingerprint.value
        }
        let cachedIds = Set(cached.map(\.photoId))
        let missingIds = photoIds.filter { !cachedIds.contains($0) }

        for row in cached {
            collector.recordResult(photoId: row.photoId, tags: cacheRowToTags(row))
        }

        if !missingIds.isEmpty {
            let photos = missingIds.compactMap { photoById[$0] }
            // upsert 在并发提取期间缓冲、结束后单事务落库（metadataCacheRepo.upsert
            // 是裸语句无内部事务，包裹安全）；每照片 try/catch 隔离提取失败。
            _ = try await batchAsync(photos, concurrency: 10) { photo in
                do {
                    var tags = MetadataTags()
                    var cacheInput = MetadataCacheInput()
                    let fingerprint = fingerprints[photo.id]

                    if let exif = self.exif {
                        // exifr 默认跳过 XMP；内嵌 reader 会重读整文件提取 —— JPEG
                        // 会被解析两次。按内嵌 reader 的选项解析（xmp/iptc 开、分段
                        // 输出），有效属性从这一次解析派生。
                        let isJpeg = photo.filepath.lowercased().hasSuffix(".jpg")
                            || photo.filepath.lowercased().hasSuffix(".jpeg")
                        if let exifData = try await exif.parse(filePath: photo.filepath, isJpeg: isJpeg) {
                            let ifd0 = exifData.ifd0
                            let exifSegment = exifData.exif
                            let gps = exifData.gps
                            let make = ifd0?["Make"]?.stringValue ?? exifSegment?["Make"]?.stringValue
                            let model = ifd0?["Model"]?.stringValue ?? exifSegment?["Model"]?.stringValue
                            let widthValue = (ifd0?["ImageWidth"] ?? exifSegment?["ExifImageWidth"])?.numberValue.map { Int($0) }
                            let heightValue = (ifd0?["ImageHeight"] ?? exifSegment?["ExifImageHeight"])?.numberValue.map { Int($0) }
                            let isoValue = exifSegment?["ISO"]?.numberValue.map { Int($0) }
                            tags = MetadataTags(
                                width: widthValue,
                                height: heightValue,
                                make: make,
                                model: model,
                                lensModel: exifSegment?["LensModel"]?.stringValue,
                                focalLength: exifSegment?["FocalLength"]?.numberValue,
                                aperture: exifSegment?["FNumber"]?.numberValue,
                                shutterSpeed: stringValue(exifSegment?["ExposureTime"]),
                                iso: isoValue,
                                dateTaken: stringValue(exifSegment?["DateTimeOriginal"]),
                                rating: ifd0?["Rating"]?.numberValue,
                                latitude: gps?["latitude"]?.numberValue,
                                longitude: gps?["longitude"]?.numberValue
                            )
                            cacheInput = self.tagsToCacheInput(tags)
                            cacheInput.fileSize = fingerprint.map { Int64($0.size) }
                            cacheInput.fileMtime = fingerprint?.value

                            var writerAttributes = try await self.readEffectiveAttributesOnce(
                                photoPath: photo.filepath,
                                parsed: exifData,
                                isJpeg: isJpeg
                            )
                            self.preserveValuesOnCorruptSidecar(
                                photoId: photo.id,
                                filepath: photo.filepath,
                                attributes: &writerAttributes
                            )
                            if writerAttributes.keywords != nil {
                                tags.keywords = writerAttributes.keywords
                                cacheInput.keywords = writerAttributes.keywords
                            }
                            if writerAttributes.rating != nil {
                                tags.rating = writerAttributes.rating
                                cacheInput.rating = writerAttributes.rating.map { Int64($0) }
                            }
                            if writerAttributes.label != nil {
                                tags.label = writerAttributes.label
                                cacheInput.label = writerAttributes.label
                            }
                            // P1 / IPTC：空值也要投影（显式清空后缓存必须跟着变空，
                            // 否则只读面板会一直显示已被删除的字段）。
                            cacheInput.descriptive = writerAttributes.descriptive ?? DescriptiveMetadata()

                            collector.recordExtraction(
                                photoId: photo.id,
                                sessionId: photo.sessionId,
                                tags: tags,
                                cacheInput: cacheInput
                            )
                            return
                        }
                    }

                    // sharp 兜底：仅尺寸/文件大小/格式。
                    let metadata = try await self.dimensions?.metadata(filePath: photo.filepath) ?? nil
                    tags = MetadataTags(
                        fileSize: metadata?.size,
                        format: metadata?.format,
                        width: metadata?.width,
                        height: metadata?.height
                    )
                    cacheInput = MetadataCacheInput(
                        width: metadata?.width.map { Int64($0) },
                        height: metadata?.height.map { Int64($0) },
                        fileSize: metadata?.size.map { Int64($0) } ?? fingerprint.map { Int64($0.size) },
                        fileMtime: fingerprint?.value
                    )

                    var existingAttributes = try await self.readEffectiveAttributes(photoPath: photo.filepath)
                    self.preserveValuesOnCorruptSidecar(
                        photoId: photo.id,
                        filepath: photo.filepath,
                        attributes: &existingAttributes
                    )
                    if existingAttributes.keywords != nil { tags.keywords = existingAttributes.keywords }
                    if existingAttributes.rating != nil { tags.rating = existingAttributes.rating }
                    if existingAttributes.label != nil { tags.label = existingAttributes.label }
                    if existingAttributes.keywords != nil { cacheInput.keywords = existingAttributes.keywords }
                    if existingAttributes.rating != nil { cacheInput.rating = existingAttributes.rating.map { Int64($0) } }
                    if existingAttributes.label != nil { cacheInput.label = existingAttributes.label }
                    cacheInput.descriptive = existingAttributes.descriptive ?? DescriptiveMetadata()

                    collector.recordExtraction(
                        photoId: photo.id,
                        sessionId: photo.sessionId,
                        tags: tags,
                        cacheInput: cacheInput
                    )
                } catch {
                    GatherLogger.log("Failed to extract metadata for \(photo.filepath): \(error)", level: .warn)
                    collector.recordResult(photoId: photo.id, tags: MetadataTags())
                }
            }

            let pendingUpserts = collector.snapshotPendingUpserts()
            if !pendingUpserts.isEmpty {
                try transactions.transaction {
                    for entry in pendingUpserts {
                        try metadataCacheRepo.upsert(photoId: entry.photoId, sessionId: entry.sessionId, data: entry.input)
                    }
                }
            }
        }

        return collector.snapshotResult()
    }

    // MARK: - K0 关键词预览 / delta 写回

    public func sessionId(forPhotoIds photoIds: [String]) throws -> String? {
        try getPhotosByIds(photoIds).first?.sessionId
    }

    /// 预览/应用共用的结果：预览面 + 结构化阻断（不靠字符串解析 errorMessage）。
    private struct KeywordPreviewOutcome {
        let preview: WritebackPreview
        let blockedKeyword: String?
        let blockedSource: MetadataMutationSource?
        let readFailedPath: String?
        /// xmpPath → fold(keyword) → 生成来源；apply 直接复用，避免二次查库。
        let ownedByXmp: [String: [String: Set<MetadataMutationSource>]]
    }

    /// 只读预览：不 create/reopen/upsert 任何 delivery 行；预览与 apply 共用 planner。
    public func previewKeywords(
        photoIds: [String],
        added: [String],
        removed: [String],
        conflictedXmpPaths: Set<String> = []
    ) async throws -> WritebackPreview {
        try await keywordPreview(
            photoIds: photoIds,
            added: added,
            removed: removed,
            conflictedXmpPaths: conflictedXmpPaths
        ).preview
    }

    private func keywordPreview(
        photoIds: [String],
        added: [String],
        removed: [String],
        conflictedXmpPaths: Set<String>
    ) async throws -> KeywordPreviewOutcome {
        let photos = try getPhotosByIds(photoIds)
        guard !photos.isEmpty else {
            return KeywordPreviewOutcome(
                preview: WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0),
                blockedKeyword: nil,
                blockedSource: nil,
                readFailedPath: nil,
                ownedByXmp: [:]
            )
        }
        // 未知/重复 id 不能静默忽略（否则结果条 0/0/0，用户以为写成功）。
        guard Set(photoIds).count == photoIds.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        guard photos.count == photoIds.count else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "contains unknown photo ids")
        }
        // 预览与 apply 同一会话边界，避免“预览成功、确认后 apply 拒绝”。
        let sessionIds = Set(photos.map(\.sessionId))
        guard sessionIds.count == 1 else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "must belong to one session")
        }
        let targets = try keywordTargets(photos)
        // 生成词保护：一次批量读 origin，Swift 侧 fold 比对（大小写/NFC 差异不绕过）。
        var ownedByXmp: [String: [String: Set<MetadataMutationSource>]] = [:]
        if !removed.isEmpty, let origins {
            let removedKeys = Set(removed.map(KeywordNormalizer.fold))
            let paths = targets.map(\.xmpPath)
            for source in MetadataMutationSource.allCases where source != .manual {
                for row in try origins.activeKeywordOrigins(
                    xmpPaths: paths, source: source.rawValue
                ) {
                    let key = KeywordNormalizer.fold(row.keyword)
                    guard removedKeys.contains(key) else { continue }
                    ownedByXmp[row.xmpPath, default: [:]][key, default: []].insert(source)
                }
            }
        }

        // 500 张/共享侧车时串行读 XMP 是秒级；按 8 路分块并发读，保持原顺序。
        let snapshots = await readKeywordSnapshots(targets)
        var items: [WritebackItem] = []
        var blockedKeyword: String?
        var blockedSource: MetadataMutationSource?
        var readFailedPath: String?
        for target in targets {
            let snapshot = snapshots[target.xmpPath]
            let disk = snapshot?.0 ?? []
            let readFailed = snapshot?.1 ?? true
            let cache: MetadataCacheRow?
            do { cache = try metadataCacheRepo.get(target.photo.id) } catch { cache = nil }
            let cachedKeywords = cache?.keywords ?? []
            // origin 可能比磁盘陈旧（外部已删词）：只把盘上仍存在的词视为 owned，
            // 避免 K0 误报 KEYWORD_OWNED_BY_SOURCE。
            let activeOwned = (ownedByXmp[target.xmpPath] ?? [:]).filter { key, _ in
                disk.contains { KeywordNormalizer.fold($0) == key }
            }
            let plan = KeywordPlanner.plan(
                existing: disk,
                added: added,
                removed: removed,
                owned: activeOwned
            )
            let externalChanged = (cache != nil
                && KeywordNormalizer.dedupe(cachedKeywords)
                    != KeywordNormalizer.dedupe(disk))
                || conflictedXmpPaths.contains(target.xmpPath)
            let blocked = plan.blocked.first
            let status: String
            let message: String
            if readFailed {
                status = "failed"
                message = "XMP_READ_FAILED"
                if readFailedPath == nil { readFailedPath = target.filepath }
            } else if let blocked {
                status = "blocked"
                message = "KEYWORD_OWNED_BY_SOURCE:\(blocked.keyword):"
                    + (blocked.sources.first?.rawValue ?? "")
                if blockedKeyword == nil {
                    blockedKeyword = blocked.keyword
                    blockedSource = blocked.sources.first
                }
            } else {
                status = "pending"
                message = ""
            }
            let preview = WritebackItemPreview(
                dirtyFields: blocked == nil && !readFailed ? [.keywords] : [],
                before: WritebackAttributes(keywords: disk),
                after: WritebackAttributes(keywords: plan.after),
                source: "metadata",
                sharedPhotoCount: target.sharedPhotoCount,
                externalChanged: externalChanged,
                willCreate: !xmp.fileExists(target.xmpPath)
            )
            items.append(WritebackItem(
                photoId: target.photo.id,
                photoPath: target.filepath,
                sessionId: target.photo.sessionId,
                module: "metadata",
                keywords: plan.after,
                attributes: nil,
                xmpPath: target.xmpPath,
                backupPath: "",
                xmpStatus: status,
                errorMessage: message,
                attemptCount: 0,
                lastAttemptAt: "",
                preview: preview
            ))
        }
        let preview = WritebackPreview(
            items: items, totalCount: items.count, affectedPhotos: photoIds.count)
        return KeywordPreviewOutcome(
            preview: preview,
            blockedKeyword: blockedKeyword,
            blockedSource: blockedSource,
            readFailedPath: readFailedPath,
            ownedByXmp: ownedByXmp
        )
    }

    /// 按侧车分组、每侧车一次 delta 入队，最后统一 flush 一次。
    public func applyKeywordDelta(
        photoIds: [String],
        added: [String],
        removed: [String]
    ) async throws -> WritebackResult {
        let photos = try getPhotosByIds(photoIds)
        guard !photos.isEmpty else { return emptyKeywordResult() }
        guard Set(photoIds).count == photoIds.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        guard photos.count == photoIds.count else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "contains unknown photo ids")
        }
        // 一次关键词 apply 只处理一个会话：跨 session 静默只 flush 最后一个会留下 pending。
        let sessionIds = Set(photos.map(\.sessionId))
        guard sessionIds.count == 1, let sid = sessionIds.first else {
            throw GatherError.invalidParameter(
                field: "photoIds", reason: "must belong to one session")
        }
        // 全量预检：任一 target 因来源保护/读取失败不可写时，先整体拒绝。
        // 预览面同时提供结构化阻断信息与盘上快照，避免二次读盘/字符串解析。
        var snapshots: [String: [String]] = [:]
        var ownedByXmp: [String: [String: Set<MetadataMutationSource>]] = [:]
        if !removed.isEmpty {
            let preflight = try await keywordPreview(
                photoIds: photoIds, added: added, removed: removed, conflictedXmpPaths: [])
            for item in preflight.preview.items {
                if let before = item.preview?.before.keywords {
                    snapshots[item.photoId] = before
                }
            }
            if let keyword = preflight.blockedKeyword {
                throw GatherError(
                    code: .KEYWORD_OWNED_BY_SOURCE,
                    params: [
                        "keyword": keyword,
                        "source": preflight.blockedSource?.rawValue ?? "",
                    ])
            }
            if let path = preflight.readFailedPath {
                throw GatherError(
                    code: .XMP_DOCUMENT_READ_FAILED, params: ["path": path])
            }
            ownedByXmp = preflight.ownedByXmp
        }
        let targets = try keywordTargets(photos)
        for target in targets {
            // RAW/JPEG 共享侧车：每侧车只入队一次（首张照片作为 item 身份）。
            _ = try await mutations.queueKeywordDelta(
                sessionId: target.photo.sessionId,
                photoId: target.photo.id,
                added: added,
                removed: removed,
                owned: ownedByXmp[target.xmpPath] ?? [:],
                existingKeywords: snapshots[target.photo.id]
            )
        }
        // 没有新入队也必须 flush：上一次入队可能停在 pending/failed，
        // 否则第二次“确认写入”会拿 0/0 当成功并清掉草稿、丢失重试入口。
        guard let flushPending else { return emptyKeywordResult() }
        let result = try await flushPending(sid)
        // 写后回读并回填 cache（读不到保留旧 cache，不拿空值覆盖）。
        // 同侧车可能还有不在本次请求里的兄弟变体（只选 RAW 写词时 JPEG 不在
        // keywordTargets 里）；按会话投影建立 xmpPath → 全部 photoId，避免面板旧词。
        var siblingIds: [String: [String]] = [:]
        do {
            for row in try photoRepo.getBySessionProjection(sessionId: sid) {
                let xmpPath = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                siblingIds[xmpPath, default: []].append(row.id)
            }
        } catch {
            GatherLogger.log("load session photos for keyword cache refill failed: \(error)", level: .warn)
        }
        for target in targets {
            do {
                let keywords = try await xmp.readKeywords(photoPath: target.filepath)
                let ids = siblingIds[target.xmpPath] ?? target.photoIds
                for photoId in ids {
                    try metadataCacheRepo.updateKeywords(photoId: photoId, keywords: keywords)
                }
            } catch {
                continue
            }
        }
        return result
    }

    /// P1 / IPTC：把逐张的属性写入（描述性元数据 / rating / label / keywords）
    /// 经交付队列落盘。
    ///
    /// 为什么必须走队列：侧车写入的唯一路径是 deliveries（备份 → 冲突检测 → 写盘
    /// → reload-ack）。模板与 triage 直接调 XMPProvider 会绕过备份与审计，撤销也
    /// 没有交付行可追溯；这里统一入队后 flush，再回读校验并刷新缓存投影。
    public func applyMetadataAttributes(
        _ inputs: [(photoId: String, attributes: MetadataWriteAttributes)],
        source: MetadataMutationSource
    ) async throws -> MetadataAttributesApplyOutcome {
        guard !inputs.isEmpty else {
            return MetadataAttributesApplyOutcome(written: [], attempted: [], skipped: [], failed: [])
        }
        let ids = inputs.map(\.photoId)
        guard Set(ids).count == ids.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        let photos = try getPhotosByIds(ids)
        guard photos.count == ids.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "contains unknown photo ids")
        }
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })

        var skipped: [String] = []
        var queued: [(photoId: String, attributes: MetadataWriteAttributes, sessionId: String)] = []
        // 入队失败不能中断整批：已入队的照片仍要 flush，否则它们停在 pending，
        // 模板批次也不会记录（撤销输入丢失）。
        var failureByPhoto: [String: String] = [:]
        for input in inputs {
            guard !input.attributes.isEmpty else {
                skipped.append(input.photoId)
                continue
            }
            guard let photo = photoById[input.photoId] else { continue }
            do {
                _ = try mutations.queuePhotoValues(
                    sessionId: photo.sessionId,
                    photoId: input.photoId,
                    values: input.attributes.asJSONValue.objectValue ?? [:],
                    source: source
                )
                queued.append((input.photoId, input.attributes, photo.sessionId))
            } catch {
                failureByPhoto[input.photoId] = String(describing: error)
            }
        }
        guard !queued.isEmpty else {
            return MetadataAttributesApplyOutcome(
                written: [], attempted: [], skipped: skipped,
                failed: failureByPhoto.map { MetadataApplyFailure(photoId: $0.key, message: $0.value) })
        }
        // 已入队的照片都算 attempted：即使 flush 抛错/回读失败，交付项可能仍会在
        // 之后被别的 flush 写盘；批次必须先有快照，否则"盘上已改但不可撤销"。
        let attempted = queued.map(\.photoId)
        guard let flushPending else {
            throw MetadataServiceError.writebackFailed("writeback executor unavailable")
        }
        // 一次应用可能跨会话（模板 API 没有会话入参）；按会话 flush，失败互不影响。
        for sessionId in Set(queued.map(\.sessionId)).sorted() {
            do {
                let result = try await flushPending(sessionId)
                for item in result.failedItems where failureByPhoto[item.photoId] == nil {
                    failureByPhoto[item.photoId] = item.errorMessage.isEmpty
                        ? "writeback failed" : item.errorMessage
                }
            } catch {
                for entry in queued where entry.sessionId == sessionId {
                    failureByPhoto[entry.photoId] = String(describing: error)
                }
            }
        }

        var written: [String] = []
        var failed: [MetadataApplyFailure] = []
        // P0 / A2：回读失败/校验不符 = 不确定（可能已写盘）。它既留在 failed 里给
        // 用户看原因，也进 uncertain 让撤销批次包含它。
        var uncertain: [String] = []
        // 投影刷新失败只降级、不改变 written 语义；但失败次数要聚合上报——逐张逐字段
        // 打日志在万张批次下会刷数万行，反而淹没真正的信号。
        var projectionFailures = 0
        func refreshProjection(_ field: String, photoId: String, _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                projectionFailures += 1
                GatherLogger.log(
                    "metadata cache projection refresh failed (field=\(field) photo=\(photoId)): \(error)",
                    level: .debug)
            }
        }
        // RAW+JPEG 共享同一 .xmp：写后投影要刷新全部兄弟照片，否则兄弟面板/下次
        // plan 仍读旧值并误判冲突（关键词路径已有同样处理）。
        //
        // P1：兄弟刷新必须**逐张读盘上值**。JPEG 内嵌 IPTC 与侧车是两份数据；
        // 用写回目标的 actual（侧车快照）整列刷新 JPEG 兄弟，会把兄弟的内嵌
        // 标题/版权从缓存里清掉。
        var siblingPhotosByXmp: [String: [(id: String, filepath: String)]] = [:]
        var loadedSessions = Set<String>()
        /// 兄弟照片的盘上读盘结果（并发读、串行写缓存）。
        struct SiblingRead: Sendable {
            let photoId: String
            let attributes: MetadataWriteAttributes?
            let error: String?
        }
        for input in queued {
            if let message = failureByPhoto[input.photoId] {
                failed.append(MetadataApplyFailure(photoId: input.photoId, message: message))
                continue
            }
            guard let photo = photoById[input.photoId] else { continue }
            let readPath = (try? assetResolver?.resolve(
                sessionId: photo.sessionId, photoId: input.photoId))?.filepath ?? photo.filepath
            // P1：回读必须走盘上合成值（JPEG = 内嵌 + 侧车）。只读侧车会漏掉
            // 内嵌字段，并让"清空 JPEG 内嵌字段"看起来成功。
            let sidecar: MetadataWriteAttributes
            do {
                sidecar = try await xmp.readAttributes(photoPath: readPath)
            } catch {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_DOCUMENT_READ_FAILED.rawValue + ": \(error)"))
                continue
            }
            let snapshot = await diskSnapshot(photoPath: readPath, sidecar: sidecar)
            let disk = snapshot.attributes
            // 缓存投影以回读的**盘上值**为准（写入可能是"字段合并"，本地输入不等于
            // 最终文件）。只有本次明确写了描述性元数据才刷新 IPTC 投影：rating/
            // 关键词写回时若侧车解析失败，不能用空值把面板已有 IPTC 抹掉。
            if input.attributes.descriptive != nil {
                refreshProjection("descriptive", photoId: input.photoId) {
                    try metadataCacheRepo.updateDescriptive(
                        photoId: input.photoId,
                        descriptive: disk.descriptive ?? DescriptiveMetadata())
                }
                if !loadedSessions.contains(photo.sessionId) {
                    loadedSessions.insert(photo.sessionId)
                    do {
                        for row in try photoRepo.getBySessionProjection(
                            sessionId: photo.sessionId) {
                            let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                            siblingPhotosByXmp[key, default: []].append((row.id, row.filepath))
                        }
                    } catch {
                        // 兄弟刷新是投影优化；失败不回滚已写盘的文件。
                    }
                }
                // 兄弟索引按 photos.filepath 建键；asset_read_mode=asset 时 readPath 是
                // 解析后的资产路径，两者不同。只查 readPath 会让兄弟照片在 asset 模式下
                // 永不刷新（面板继续显示旧 IPTC），所以两个键都要试。
                let readKey = TSPath.normalize(TSPath.xmpSidecarPath(readPath))
                let dbKey = TSPath.normalize(TSPath.xmpSidecarPath(photo.filepath))
                // 当前照片已在上面用 disk 值刷过，这里只处理兄弟；两个键都查不到
                // 时没有兄弟可刷（fallback 曾被 where 子句过滤成空转）。
                let targets = siblingPhotosByXmp[readKey]
                    ?? siblingPhotosByXmp[dbKey]
                    ?? []
                var siblingPlans: [(id: String, path: String)] = []
                for (siblingId, siblingFilepath) in targets where siblingId != input.photoId {
                    var siblingPath = siblingFilepath
                    if let assetResolver {
                        do {
                            siblingPath = try assetResolver.resolve(
                                sessionId: photo.sessionId, photoId: siblingId).filepath
                        } catch {
                            // 解析失败退回 photos.filepath：兄弟刷新是投影优化。
                        }
                    }
                    siblingPlans.append((siblingId, siblingPath))
                }
                // 并发读盘：共享侧车的兄弟组通常 2–4 张，串行 ImageIO 解析在大批次
                // 模板套用（2000 张）下会退化成 O(k²) 读盘。写缓存仍串行。
                let siblingReads: [SiblingRead]
                do {
                    siblingReads = try await batchAsync(
                        siblingPlans, concurrency: 4
                    ) { plan -> SiblingRead in
                        do {
                            let sidecar = try await self.xmp.readAttributes(photoPath: plan.path)
                            let snapshot = await self.diskSnapshot(
                                photoPath: plan.path, sidecar: sidecar)
                            return SiblingRead(
                                photoId: plan.id, attributes: snapshot.attributes, error: nil)
                        } catch {
                            // 单张失败降级为诊断（已写盘的文件不回滚，缓存保留旧值）。
                            return SiblingRead(
                                photoId: plan.id, attributes: nil,
                                error: String(describing: error))
                        }
                    }
                } catch {
                    projectionFailures += 1
                    siblingReads = []
                }
                for read in siblingReads {
                    guard let attributes = read.attributes else {
                        // 兄弟读盘失败只降级为诊断：已写盘的文件不回滚，缓存保留旧值。
                        projectionFailures += 1
                        GatherLogger.log(
                            "metadata cache projection read failed "
                                + "(descriptive photo=\(read.photoId)): \(read.error ?? "-")",
                            level: .debug)
                        continue
                    }
                    refreshProjection("descriptive", photoId: read.photoId) {
                        try metadataCacheRepo.updateDescriptive(
                            photoId: read.photoId,
                            descriptive: attributes.descriptive ?? DescriptiveMetadata())
                    }
                }
            }
            if let rating = disk.rating {
                refreshProjection("rating", photoId: input.photoId) {
                    try metadataCacheRepo.updateRating(
                        photoId: input.photoId, rating: Int64(rating))
                }
            }
            if let label = disk.label {
                refreshProjection("label", photoId: input.photoId) {
                    try metadataCacheRepo.updateLabel(photoId: input.photoId, label: label)
                }
            } else if let wantedLabel = input.attributes.label,
                      wantedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 显式清空最后一个 label：回读 nil 也必须把缓存清零，否则面板留旧值。
                refreshProjection("label", photoId: input.photoId) {
                    try metadataCacheRepo.updateLabel(photoId: input.photoId, label: "")
                }
            }
            if let keywords = disk.keywords {
                refreshProjection("keywords", photoId: input.photoId) {
                    try metadataCacheRepo.updateKeywords(
                        photoId: input.photoId, keywords: keywords)
                }
            } else if let wantedKeywords = input.attributes.keywords, wantedKeywords.isEmpty {
                refreshProjection("keywords", photoId: input.photoId) {
                    try metadataCacheRepo.updateKeywords(
                        photoId: input.photoId, keywords: [])
                }
            }
            // P1：内嵌读不到（JPEG 的 APP1 解析失败）时，清空类写入无法判定是否真的
            // 清掉，必须按不确定处理（进 failed + uncertain），不能报 written。
            if !snapshot.embeddedReadable, Self.hasClearAttempt(input.attributes) {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue
                        + ": embedded metadata unreadable"))
                continue
            }
            // P1：JPEG 的内嵌 IPTC/XMP 无法靠写 .xmp 侧车清空。写后盘上值仍带
            // 旧字段、而侧车已没有该字段 = 侧车写入成功但内嵌值还在：必须显式
            // 失败（fail-closed），不能让调用方以为"清空成功"。
            if let clearFailure = Self.jpegEmbeddedClearFailure(
                expected: input.attributes, disk: disk, sidecar: sidecar,
                isJpeg: Self.isJpegPath(readPath)) {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId, message: clearFailure))
                continue
            }
            guard Self.attributesMatch(input.attributes, disk) else {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue))
                continue
            }
            written.append(input.photoId)
        }
        if projectionFailures > 0 {
            GatherLogger.log(
                "metadata cache projection refresh failed \(projectionFailures) time(s)",
                level: .warn)
        }
        return MetadataAttributesApplyOutcome(
            written: written, attempted: attempted, skipped: skipped,
            failed: failed, uncertain: uncertain)
    }

    /// P1：JPEG 内嵌字段的"清空失败"诊断。
    ///
    /// 侧车是 JPEG 的唯一可写面；Bridge/C1 写在 APP1 里的 IPTC/XMP 不会被
    /// 写侧车删掉。判据必须同时看两份：
    /// - 盘上合成值仍有该字段（清空没生效）；
    /// - 侧车已没有该字段（说明不是侧车写失败，而是内嵌值残留）。
    ///
    /// 返回 JPEG_EMBEDDED_CLEAR_UNSUPPORTED: <字段列表>（错误码留在前缀，
    /// UI 经 L10n.resolvedTemplate 的 "CODE: 参数" 形态本地化）。RAW 不走该判定：
    /// RAW 只有侧车一个真相源，读回不符就是普通写后校验失败。
    static func jpegEmbeddedClearFailure(
        expected: MetadataWriteAttributes,
        disk: MetadataWriteAttributes,
        sidecar: MetadataWriteAttributes,
        isJpeg: Bool
    ) -> String? {
        guard isJpeg else { return nil }
        var fields: [String] = []
        if let descriptive = expected.descriptive {
            let diskDescriptive = disk.descriptive ?? DescriptiveMetadata()
            let sidecarDescriptive = sidecar.descriptive ?? DescriptiveMetadata()
            for field in descriptive.explicitlySetFields {
                // 只检查"显式清空"：nil = 不触碰（不在 explicitlySetFields 里）。
                guard normalizedValue(descriptive.value(for: field)) == nil else { continue }
                guard normalizedValue(diskDescriptive.value(for: field)) != nil else { continue }
                // 侧车仍带值 = 侧车写入失败，交给通用 write-back verification 报错；
                // 侧车已清空但盘上仍有值 = 内嵌残留（本诊断）。
                guard normalizedValue(sidecarDescriptive.value(for: field)) == nil else { continue }
                fields.append(field.rawValue)
            }
        }
        // P1：成员级联系人清空。内联编辑器提交完整 contact 结构，"为 nil 的成员"
        // 只有列在 clearedContactMembers 里才算显式清空（模板的成员级合并不算）。
        if let cleared = expected.clearedContactMembers, !cleared.isEmpty,
           let expectedContact = expected.descriptive?.contactInfo {
            let diskContact = disk.descriptive?.contactInfo ?? DescriptiveContact()
            let sidecarContact = sidecar.descriptive?.contactInfo ?? DescriptiveContact()
            for member in cleared {
                guard Self.isBlank(expectedContact.memberValue(member)) else { continue }
                guard !Self.isBlank(diskContact.memberValue(member)) else { continue }
                guard Self.isBlank(sidecarContact.memberValue(member)) else { continue }
                fields.append("contactInfo.\(member)")
            }
        }
        if let keywords = expected.keywords, keywords.isEmpty {
            let diskKeywords = (disk.keywords ?? []).filter { !$0.isEmpty }
            let sidecarKeywords = (sidecar.keywords ?? []).filter { !$0.isEmpty }
            if !diskKeywords.isEmpty, sidecarKeywords.isEmpty { fields.append("keywords") }
        }
        if let label = expected.label,
           label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let diskLabel = disk.label,
           !diskLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (sidecar.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("label")
        }
        guard !fields.isEmpty else { return nil }
        return GatherErrorCode.JPEG_EMBEDDED_CLEAR_UNSUPPORTED.rawValue
            + ": " + fields.joined(separator: ", ")
    }

    /// 本次补丁是否包含"清空"意图（字段清空 / 空关键词 / 空 label）。
    static func hasClearAttempt(_ attributes: MetadataWriteAttributes) -> Bool {
        if let descriptive = attributes.descriptive {
            for field in descriptive.explicitlySetFields
            where normalizedValue(descriptive.value(for: field)) == nil {
                return true
            }
        }
        if let keywords = attributes.keywords, keywords.isEmpty { return true }
        if let label = attributes.label, isBlank(label) { return true }
        return false
    }

    /// 文本是否"空"（nil / 全空白）。
    static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 写后回读判定：描述性元数据逐字段（空值等价于不存在），其余字段精确比较。
    private static func attributesMatch(
        _ expected: MetadataWriteAttributes,
        _ actual: MetadataWriteAttributes
    ) -> Bool {
        if expected.rating != nil, expected.rating != actual.rating { return false }
        if let expectedLabel = expected.label {
            // 空串与 nil 等价于"没有 label"：清空后回读 nil 不能报成校验失败。
            let wanted = expectedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let got = (actual.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted != got { return false }
        }
        if let expectedKeywords = expected.keywords {
            let actualKeywords = Set(actual.keywords ?? [])
            if !Set(expectedKeywords).isSubset(of: actualKeywords) { return false }
        }
        if let descriptive = expected.descriptive {
            let actualDescriptive = actual.descriptive ?? DescriptiveMetadata()
            for field in descriptive.explicitlySetFields {
                let expectedValue = Self.normalizedValue(descriptive.value(for: field))
                let actualValue = Self.normalizedValue(actualDescriptive.value(for: field))
                if case .contact(let expectedContact) = expectedValue {
                    // 结构字段是成员级合并：模板只填部分成员时，盘上必然比输入多。
                    guard case .contact(let actualContact) = actualValue,
                          Self.contactContains(actualContact, expectedContact) else {
                        return false
                    }
                } else if expectedValue != actualValue {
                    return false
                }
            }
        }
        return true
    }

    /// expected 的每个非 nil 成员都必须与 actual 相同（成员级合并校验）。
    private static func contactContains(_ actual: DescriptiveContact, _ expected: DescriptiveContact) -> Bool {
        func eq(_ a: String?, _ b: String?) -> Bool { b == nil || a == b }
        return eq(actual.city, expected.city)
            && eq(actual.country, expected.country)
            && eq(actual.address, expected.address)
            && eq(actual.postalCode, expected.postalCode)
            && eq(actual.region, expected.region)
            && eq(actual.email, expected.email)
            && eq(actual.telephone, expected.telephone)
            && eq(actual.url, expected.url)
    }

    /// 读侧会 trim 文本并丢掉空列表项；比较前必须同口径，否则"写成功却报失败"。
    private static func normalizedValue(_ value: XMPFieldValue?) -> XMPFieldValue? {
        switch value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .list(let values):
            let items = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return items.isEmpty ? nil : .list(items)
        case .contact(let contact):
            return contact.isEmpty ? nil : .contact(contact)
        case .none:
            return nil
        }
    }

    public func retryKeywordWriteback(sessionId: String) async throws -> WritebackResult {
        guard let flush = retryFlush ?? flushPending else { return emptyKeywordResult() }
        return try await flush(sessionId)
    }

    private struct KeywordTarget {
        let photo: MetadataPhotoLookup
        let filepath: String
        let xmpPath: String
        let sharedPhotoCount: Int
        let photoIds: [String]
    }

    private func readKeywordSnapshots(
        _ targets: [KeywordTarget]
    ) async -> [String: ([String], Bool)] {
        let xmp = self.xmp
        var result: [String: ([String], Bool)] = [:]
        let batchSize = 8
        var start = 0
        while start < targets.count {
            let end = min(targets.count, start + batchSize)
            let chunk = Array(targets[start..<end])
            await withTaskGroup(of: (String, [String], Bool).self) { group in
                for target in chunk {
                    let xmpPath = target.xmpPath
                    let filepath = target.filepath
                    group.addTask {
                        do {
                            let keywords = try await xmp.readKeywords(photoPath: filepath)
                            return (xmpPath, keywords, false)
                        } catch {
                            return (xmpPath, [], true)
                        }
                    }
                }
                for await item in group {
                    result[item.0] = (item.1, item.2)
                }
            }
            start = end
        }
        return result
    }

    private func keywordTargets(_ photos: [MetadataPhotoLookup]) throws -> [KeywordTarget] {
        var resolved: [String: ResolvedPhotoAsset] = [:]
        if let assetResolver {
            let bySession = Dictionary(grouping: photos, by: \.sessionId)
            for (sessionId, rows) in bySession {
                resolved.merge(
                    try assetResolver.resolveMany(sessionId: sessionId, photoIds: rows.map(\.id))
                ) { first, _ in first }
            }
        }
        var order: [String] = []
        var first: [String: (photo: MetadataPhotoLookup, filepath: String)] = [:]
        var counts: [String: Int] = [:]
        var idsByXmp: [String: [String]] = [:]
        for photo in photos {
            let asset = resolved[photo.id]
            let filepath = asset?.filepath ?? photo.filepath
            let xmpPath = TSPath.normalize(asset?.xmpPath ?? TSPath.xmpSidecarPath(filepath))
            if first[xmpPath] == nil {
                order.append(xmpPath)
                first[xmpPath] = (photo, filepath)
            }
            counts[xmpPath, default: 0] += 1
            idsByXmp[xmpPath, default: []].append(photo.id)
        }
        return order.compactMap { xmpPath in
            guard let entry = first[xmpPath] else { return nil }
            return KeywordTarget(
                photo: entry.photo,
                filepath: entry.filepath,
                xmpPath: xmpPath,
                sharedPhotoCount: counts[xmpPath] ?? 1,
                photoIds: idsByXmp[xmpPath] ?? []
            )
        }
    }

    private func emptyKeywordResult() -> WritebackResult {
        WritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""
        )
    }
}

/// TS: `value ? String(value) : undefined`（exif 段标量字符串化）。
private func stringValue(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    if let string = value.stringValue { return string }
    if let number = value.numberValue { return keywordString(number) }
    return nil
}

/// TS: `String(item)` —— JS Number 字符串化语义：整数值不带小数点（7 → "7"，-0 → "0"），
/// NaN/±Infinity 同 JS 命名；非整数保留 Double 字符串形式（7.5 → "7.5"）。
/// 关键词归一化（normalizeKeywordList）与 EXIF 标量字符串化（stringValue）共用同一口径。
private func keywordString(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
    if let integer = Int64(exactly: number) { return String(integer) }
    return String(number)
}

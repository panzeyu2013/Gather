// desktop/native/gather-core/Sources/GatherApplication/Services/MetadataService.swift
// TS 源: desktop/src/main/services/metadata/metadata.service.ts（536 行，逐字移植）
//
// 注入点差异（host 职责，与 SimilarityService 同款注入模式）：
// - TS 的 exifr.parse 经 ExifProvider 注入（分段输出 ifd0/exif/gps/xmp/dc/iptc，
//   与 `{ xmp: true, iptc: true, mergeOutput: false }` 选项对齐）；缺失时退化到
//   ImageDimensionsProvider（sharp 兜底）。
// - TS 的 sharp(filePath).metadata() 经 ImageDimensionsProvider 注入。
// - TS `MetadataWriterRouter.selectForRead()`（JPEG 内嵌 XMP）经 EmbeddedXMPReader
//   注入；RAW/sidecar 模式与 selectSidecar 统一由 XMPProvider 服务（TS 中
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

/// TS: MetadataService。
/// 线程安全说明（Swift 6 `Sendable`）：本类无任何可变状态——全部存储属性
/// （`metadataCacheRepo`/`xmp`/`connection`/`mutations`/`flushPending`/
/// `assetResolver`/`exif`/`dimensions`/`embeddedReader`）都是 `let`，构造后不可变，
/// 故无需锁。
/// 标注 `@unchecked` 仅因为依赖的仓库/协议存在类型未标 `Sendable`；
/// 并发收集状态全部收在上面两个锁盒子里。
public final class MetadataService: @unchecked Sendable {
    private let metadataCacheRepo: any MetadataRepository
    /// #6 S1：盘上读取与合成（内嵌 + sidecar）。
    private let reader: MetadataDiskReader
    /// #6 S2：只读元数据投影（不触发磁盘解析）。
    private let projector: PhotoMetadataProjector
    /// #6 S3：元数据抽取（指纹检查 → 缓存/提取 → 单事务 upsert）。
    private let extraction: MetadataExtractionService
    /// #6 S4：属性写回（六步顺序链 + 写后校验）。
    private let attributeWriter: MetadataAttributeWriter
    /// #6 S5：关键词预览 / delta / 重试。
    private let keywordWriter: MetadataKeywordWriter
    private let photoRepo: any PhotoRepository
    /// 入队后的写盘执行器（P1-9；nil = 只入队，兼容旧测试/无写回宿主）。
    /// 显式重试入口（含 failed 项）；nil = 退回 flushPending。
    /// K0：生成词来源（face/similarity/culling/template），用于阻止删除。
    /// 写目标解析（sidecar / 内嵌）：信息面板必须显示**真实写入位置**，不能恒说 sidecar。
    /// P1：缓存更新后的关键词索引同步（失败只记日志，不影响元数据结果）。

    public init(
        metadataCacheRepo: any MetadataRepository,
        xmp: any XMPProvider,
        photoRepo: any PhotoRepository,
        transactions: any TransactionRunner,
        mutations: any MetadataMutationPort,
        flushPending: MetadataQueueFlush? = nil,
        retryFlush: MetadataQueueFlush? = nil,
        assetResolver: (any PhotoAssetResolving)? = nil,
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil,
        origins: MetadataKeywordOriginRepo? = nil,
        writeTarget: (@Sendable (String) -> MetadataTarget)? = nil,
        keywordIndex: (@Sendable (String) -> Void)? = nil
    ) {
        self.metadataCacheRepo = metadataCacheRepo
        self.reader = MetadataDiskReader(xmp: xmp, exif: exif, embeddedReader: embeddedReader)
        self.projector = PhotoMetadataProjector(
            xmp: xmp, assetResolver: assetResolver, writeTarget: writeTarget)
        self.extraction = MetadataExtractionService(
            photos: photoRepo,
            xmp: xmp,
            cache: metadataCacheRepo,
            transactions: transactions,
            reader: MetadataDiskReader(xmp: xmp, exif: exif, embeddedReader: embeddedReader),
            exif: exif,
            dimensions: dimensions,
            keywordIndex: keywordIndex)
        self.attributeWriter = MetadataAttributeWriter(
            photoRepo: photoRepo,
            xmp: xmp,
            cache: metadataCacheRepo,
            mutations: mutations,
            flushPending: flushPending,
            reader: MetadataDiskReader(xmp: xmp, exif: exif, embeddedReader: embeddedReader),
            assetResolver: assetResolver)
        self.photoRepo = photoRepo
        self.keywordWriter = MetadataKeywordWriter(
            photoRepo: photoRepo,
            xmp: xmp,
            cache: metadataCacheRepo,
            mutations: mutations,
            flushPending: flushPending,
            retryFlush: retryFlush,
            origins: origins,
            assetResolver: assetResolver)
    }

    // MARK: - TS 顶层函数

    /// TS: cacheRowToTags。
    // #6 S3 前置：两处缓存映射改为 static（它们不用 self），供抽取服务跨类型复用。
    static func cacheRowToTags(_ row: MetadataCacheRow) -> MetadataTags {
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
    static func tagsToCacheInput(_ tags: MetadataTags) -> MetadataCacheInput {
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

    /// TS: normalizeKeywordList —— #1 C4 起住在 MetadataAttributes（Protocol）。
    public static func normalizeKeywordList(_ value: JSONValue?) -> [String]? {
        MetadataAttributes.normalizeKeywordList(value)
    }
    // MARK: - 有效属性合成（#6 S1 起由 MetadataDiskReader 承担）

    /// TS: diskAttributes —— 盘上有效属性（内嵌 + sidecar 合并）。
    public func diskAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        try await reader.diskAttributes(photoPath: photoPath)
    }


    // #6 S0：属性合并 / 内嵌解析 / 关键词归一化已抽到 MetadataAttributes（纯函数，
    // 无 self、无 IO、无事务）。这里保留同名转发，避免 18 处跨 target 调用点跟着改。
    public static func mergeAttributes(
        _ base: MetadataWriteAttributes,
        _ overlay: MetadataWriteAttributes
    ) -> MetadataWriteAttributes {
        MetadataAttributes.mergeAttributes(base, overlay)
    }

    public static func mergeDescriptive(
        _ base: DescriptiveMetadata?,
        _ overlay: DescriptiveMetadata?
    ) -> DescriptiveMetadata? {
        MetadataAttributes.mergeDescriptive(base, overlay)
    }

    public static func embeddedAttributesFromParse(
        _ parsed: MetadataParseSegments
    ) -> MetadataWriteAttributes? {
        MetadataAttributes.embeddedAttributesFromParse(parsed)
    }



    /// TS: getPhotosByIds —— 800/块 IN 查询（镜像缓存仓库的分块，低于 SQLite
    /// 常见参数上限）。
    public func getPhotosByIds(_ photoIds: [String]) throws -> [MetadataPhotoLookup] {
        try photoRepo.getLookupByIds(photoIds)
    }

    /// P1 / IPTC：单张照片的只读元数据详情（#6 S2 起投影逻辑在 PhotoMetadataProjector）。
    ///
    /// 只读缓存投影：**不触发磁盘解析**（面板翻页不得产生 N 次 IO）。
    /// 缓存行缺失时返回空快照与空描述性元数据，而不是抛错 —— 尚未扫描是正常态。
    public func photoDetail(photoId: String) throws -> PhotoMetadataDetail {
        guard let lookup = try photoRepo.getLookupByIds([photoId]).first else {
            throw MetadataServiceError.photoNotFound(photoId)
        }
        return projector.project(lookup, row: try metadataCacheRepo.get(photoId))
    }

    // MARK: - 公开 API

    /// TS: getMetadata —— #6 S3 起由 MetadataExtractionService 承担。
    public func getMetadata(photoIds: [String]) async throws -> [String: MetadataTags] {
        try await extraction.extract(photoIds: photoIds)
    }

    // MARK: - K0 关键词预览 / delta 写回






    /// TS: applyMetadataAttributes —— #6 S4 起由 MetadataAttributeWriter 承担。
    public func applyMetadataAttributes(
        _ inputs: [(photoId: String, attributes: MetadataWriteAttributes)],
        source: MetadataMutationSource
    ) async throws -> MetadataAttributesApplyOutcome {
        try await attributeWriter.apply(inputs, source: source)
    }

    // MARK: - Wave5（batch5）：位置 / 拍摄时间

    /// 盘上当前 GPS 坐标与拍摄时间（编辑器初值）。
    ///
    /// 与 diskDescriptive 同口径：读盘（JPEG = 内嵌 + sidecar 合成），不读缓存。
    public func diskGeoDate(photoId: String) async throws -> MetadataGeoDateSnapshot? {
        guard let lookup = try photoRepo.getLookupByIds([photoId]).first else { return nil }
        let attributes = try await reader.diskAttributes(photoPath: lookup.filepath)
        return MetadataGeoDateSnapshot(
            latitude: attributes.latitude,
            longitude: attributes.longitude,
            dateTaken: attributes.dateTaken)
    }

    /// 写入 GPS 坐标与拍摄时间。
    ///
    /// 走既有 attributeWriter（交付队列 → 备份 → 指纹冲突检测 → 写盘 → provider 写后校验），
    /// 再对 **written** 做一次盘上回读：
    /// - AttributeWriter.attributesMatch 只比较 rating/label/keywords/descriptive，**不含**
    ///   GPS/时间（该文件不在本波写作用域），所以这里补回读才算数；
    /// - 读回不一致（典型：JPEG 内嵌目标的读侧尚未接线）→ 从 written 移到
    ///   failed + uncertain（XMP_WRITE_VERIFICATION_FAILED），宁可报"不确定"也不谎报成功。
    public func applyGeoDate(
        photoIds: [String],
        latitude: Double?,
        longitude: Double?,
        dateTaken: String?,
        source: MetadataMutationSource
    ) async throws -> MetadataAttributesApplyOutcome {
        let attributes = MetadataWriteAttributes(
            dateTaken: dateTaken, latitude: latitude, longitude: longitude)
        guard !attributes.isEmpty else {
            throw GatherError.invalidParameter(
                field: "latitude/longitude/dateTaken", reason: "must set at least one")
        }
        let lookups = try photoRepo.getLookupByIds(photoIds)
        let byId = Dictionary(uniqueKeysWithValues: lookups.map { ($0.id, $0) })
        var inputs: [(photoId: String, attributes: MetadataWriteAttributes)] = []
        for photoId in photoIds {
            guard byId[photoId] != nil else {
                throw GatherError.invalidParameter(
                    field: "photoIds", reason: "contains unknown photo ids")
            }
            inputs.append((photoId, attributes))
        }
        let result = try await attributeWriter.apply(inputs, source: source)
        guard !result.written.isEmpty else { return result }

        var stillWritten: [String] = []
        var failed = result.failed
        var uncertain = result.uncertain
        for photoId in result.written {
            guard let lookup = byId[photoId] else { continue }
            let disk: MetadataWriteAttributes
            do {
                disk = try await reader.diskAttributes(photoPath: lookup.filepath)
            } catch {
                uncertain.append(photoId)
                failed.append(MetadataApplyFailure(
                    photoId: photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue
                        + ": readback failed"))
                continue
            }
            guard Self.geoDateMatches(
                attributes: attributes, disk: disk) else {
                uncertain.append(photoId)
                failed.append(MetadataApplyFailure(
                    photoId: photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue
                        + ": geo/date not readable after write"))
                continue
            }
            stillWritten.append(photoId)
        }
        let dedupUncertain = Array(Set(uncertain)).sorted()
        return MetadataAttributesApplyOutcome(
            written: stillWritten,
            attempted: result.attempted,
            skipped: result.skipped,
            failed: failed,
            uncertain: dedupUncertain)
    }

    // MARK: - Wave5（batch9）：双源冲突可见性

    /// 内嵌 + sidecar 的字段级冲突（只做可见性提示；不清理内嵌、不改写目标策略）。
    ///
    /// 返回 nil = 无双源 / 无冲突 / 内嵌或 sidecar 读不到（无法判定）；照片不存在也返回 nil
    /// （与 diskGeoDate 同口径：未知不拦编辑）。
    public func dualSourceConflict(photoId: String) async throws -> MetadataDualSourceConflict? {
        guard let lookup = try photoRepo.getLookupByIds([photoId]).first else { return nil }
        let fields = await reader.dualSourceConflict(photoPath: lookup.filepath)
        guard !fields.isEmpty else { return nil }
        return try MetadataDualSourceConflict(photoId: photoId, fields: fields)
    }

    /// GPS/时间的盘上回读比较（dateTaken：空串与 nil 等价 = 清空；坐标：1e-5 容差）。
    static func geoDateMatches(
        attributes: MetadataWriteAttributes,
        disk: MetadataWriteAttributes
    ) -> Bool {
        if let latitude = attributes.latitude {
            guard let diskLatitude = disk.latitude,
                  abs(diskLatitude - latitude) <= 1e-5 else { return false }
        }
        if let longitude = attributes.longitude {
            guard let diskLongitude = disk.longitude,
                  abs(diskLongitude - longitude) <= 1e-5 else { return false }
        }
        if let dateTaken = attributes.dateTaken {
            let expected = dateTaken.trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = (disk.dateTaken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if expected != actual { return false }
        }
        return true
    }



    // MARK: - 关键词（#6 S5 起由 MetadataKeywordWriter 承担）

    public func sessionId(forPhotoIds photoIds: [String]) throws -> String? {
        try keywordWriter.sessionId(forPhotoIds: photoIds)
    }

    public func previewKeywords(
        photoIds: [String],
        added: [String],
        removed: [String],
        conflictedXmpPaths: Set<String> = []
    ) async throws -> WritebackPreview {
        try await keywordWriter.previewKeywords(
            photoIds: photoIds, added: added, removed: removed,
            conflictedXmpPaths: conflictedXmpPaths)
    }

    public func applyKeywordDelta(
        photoIds: [String],
        added: [String],
        removed: [String]
    ) async throws -> WritebackResult {
        try await keywordWriter.applyKeywordDelta(
            photoIds: photoIds, added: added, removed: removed)
    }

    public func retryKeywordWriteback(sessionId: String) async throws -> WritebackResult {
        try await keywordWriter.retryKeywordWriteback(sessionId: sessionId)
    }
}

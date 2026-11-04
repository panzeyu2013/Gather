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
    private let xmp: any XMPProvider
    /// #6 S1：盘上读取与合成（内嵌 + sidecar）。
    private let reader: MetadataDiskReader
    /// #6 S2：只读元数据投影（不触发磁盘解析）。
    private let projector: PhotoMetadataProjector
    /// #6 S3：元数据抽取（指纹检查 → 缓存/提取 → 单事务 upsert）。
    private let extraction: MetadataExtractionService
    /// #6 S4：属性写回（六步顺序链 + 写后校验）。
    private let attributeWriter: MetadataAttributeWriter
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
    /// 写目标解析（sidecar / 内嵌）：信息面板必须显示**真实写入位置**，不能恒说 sidecar。
    private let writeTarget: (@Sendable (String) -> MetadataTarget)?
    /// P1：缓存更新后的关键词索引同步（失败只记日志，不影响元数据结果）。
    private let keywordIndex: (@Sendable (String) -> Void)?

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
        writeTarget: (@Sendable (String) -> MetadataTarget)? = nil,
        keywordIndex: (@Sendable (String) -> Void)? = nil
    ) {
        self.metadataCacheRepo = metadataCacheRepo
        self.xmp = xmp
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
        self.keywordIndex = keywordIndex
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

    /// TS: normalizeKeywordList —— 镜像 EmbeddedWriter 对 exifr 关键词列表的归一化
    /// （单值到达为标量）。
    ///
    /// P1 下一波 §3.6.3：走 KeywordPath（层级路径 "A|B"）——
    /// - 段 trim + NFC + 丢空段（"A||B" → "A|B"）：**非法段丢弃而非整词丢弃**；
    /// - 按 foldedKey 去重（dc:subject 与 lr:hierarchicalSubject 合并后的同义重复）；
    /// - 写回时仍然只吐 [String]（wire 不变，delivery_items.keywords 不用迁移）。
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
        let normalized = KeywordCodec.normalized(strings)
        return normalized.isEmpty ? nil : normalized
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

        // 500 张/共享 sidecar 时串行读 XMP 是秒级；按 8 路分块并发读，保持原顺序。
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

    /// 按 sidecar 分组、每个 sidecar 一次 delta 入队，最后统一 flush 一次。
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
            // RAW/JPEG 共享 sidecar：每个 sidecar 只入队一次（首张照片作为 item 身份）。
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
        // 同一 sidecar 可能还有不在本次请求里的兄弟变体（只选 RAW 写词时 JPEG 不在
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

    /// TS: applyMetadataAttributes —— #6 S4 起由 MetadataAttributeWriter 承担。
    public func applyMetadataAttributes(
        _ inputs: [(photoId: String, attributes: MetadataWriteAttributes)],
        source: MetadataMutationSource
    ) async throws -> MetadataAttributesApplyOutcome {
        try await attributeWriter.apply(inputs, source: source)
    }


    /// 本次补丁是否包含"清空"意图（字段清空 / 空关键词 / 空 label）。
    static func hasClearAttempt(_ attributes: MetadataWriteAttributes) -> Bool {
        if let descriptive = attributes.descriptive {
            for field in descriptive.explicitlySetFields
            where normalizedValue(descriptive.value(for: field)) == nil {
                return true
            }
        }
        // P1：成员级联系人清空不体现在"整体为空"里，只挂在 clearedContactMembers 上；
        // 漏判会让内嵌不可读时的清空按 written 放行（旧值仍在 APP1）。
        if let cleared = attributes.clearedContactMembers, !cleared.isEmpty { return true }
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

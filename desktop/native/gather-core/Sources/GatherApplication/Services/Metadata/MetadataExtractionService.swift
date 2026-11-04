// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataExtractionService.swift
// 元数据抽取（#6 S3：从 MetadataService 切出的第四刀）。
//
// 职责：指纹失效检查 → 缓存命中 / 缺失提取（EXIF + 磁盘）→ 批量事务 upsert。
//
// 硬约束（拆分类最容易踩的两条，原实现注释里写得很清楚）：
// - 全部 cache upsert 必须在**同一个**事务内，且必须发生在**并发抽取全部结束之后**；
// - keywordIndex 回调必须在**事务提交之后**调用——挪进事务闭包会读到未提交行，
//   facet 计数出错。
//
// 六条依赖都是构造后不变的 let（MetadataRepository / TransactionRunner / 三个 Provider
// 均已是 Sendable），故本类型直接 Sendable。
import Foundation
import GatherProtocol
import GatherPersistence

final class MetadataCollector: @unchecked Sendable {
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

public struct MetadataExtractionService: Sendable {
    private let photos: any PhotoRepository
    private let xmp: any XMPProvider
    private let cache: any MetadataRepository
    private let transactions: any TransactionRunner
    private let reader: MetadataDiskReader
    private let exif: (any ExifProvider)?
    private let dimensions: (any ImageDimensionsProvider)?
    private let keywordIndex: (@Sendable (String) -> Void)?

    public init(
        photos: any PhotoRepository,
        xmp: any XMPProvider,
        cache: any MetadataRepository,
        transactions: any TransactionRunner,
        reader: MetadataDiskReader,
        exif: (any ExifProvider)?,
        dimensions: (any ImageDimensionsProvider)?,
        keywordIndex: (@Sendable (String) -> Void)?
    ) {
        self.photos = photos
        self.xmp = xmp
        self.cache = cache
        self.transactions = transactions
        self.reader = reader
        self.exif = exif
        self.dimensions = dimensions
        self.keywordIndex = keywordIndex
    }

    /// TS: getMetadata —— 指纹失效检查 → 缓存命中 / 缺失提取（EXIF → sharp 兜底）
    /// → 批量事务 upsert。
    public func extract(photoIds: [String]) async throws -> [String: MetadataTags] {
        let allPhotos = try photos.getLookupByIds(photoIds)
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
        let cached = try cache.getBatch(photoIds).filter { row in
            guard let fingerprint = fingerprints[row.photoId] else { return false }
            return row.fileSize == Int64(fingerprint.size) && row.fileMtime == fingerprint.value
        }
        let cachedIds = Set(cached.map(\.photoId))
        let missingIds = photoIds.filter { !cachedIds.contains($0) }

        for row in cached {
            collector.recordResult(photoId: row.photoId, tags: MetadataService.cacheRowToTags(row))
        }

        if !missingIds.isEmpty {
            let photos = missingIds.compactMap { photoById[$0] }
            // upsert 在并发提取期间缓冲、结束后单事务落库（cache.upsert
            // 是裸语句无内部事务，包裹安全）；每照片 try/catch 隔离提取失败。
            _ = try await batchAsync(photos, concurrency: 10) { photo in
                do {
                    var tags = MetadataTags()
                    var cacheInput = MetadataCacheInput()
                    let fingerprint = fingerprints[photo.id]

                    if let exif = exif {
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
                            cacheInput = MetadataService.tagsToCacheInput(tags)
                            cacheInput.fileSize = fingerprint.map { Int64($0.size) }
                            cacheInput.fileMtime = fingerprint?.value

                            var writerAttributes = try await reader.readEffectiveAttributesOnce(
                                photoPath: photo.filepath,
                                parsed: exifData,
                                isJpeg: isJpeg
                            )
                            preserveValuesOnCorruptSidecar(
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
                    let metadata = try await dimensions?.metadata(filePath: photo.filepath) ?? nil
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

                    var existingAttributes = try await reader.readEffectiveAttributes(photoPath: photo.filepath)
                    preserveValuesOnCorruptSidecar(
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
                        try cache.upsert(photoId: entry.photoId, sessionId: entry.sessionId, data: entry.input)
                    }
                }
                // 缓存落地后再同步关键词索引：facet 与词库计数立即反映新词。
                for entry in pendingUpserts {
                    keywordIndex?(entry.photoId)
                }
            }
        }

        return collector.snapshotResult()
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
        guard let previous = try? cache.get(photoId) else { return }
        let previousKeywords = previous.keywords
        if !previousKeywords.isEmpty { attributes.keywords = previousKeywords }
        if previous.rating != 0 { attributes.rating = Double(previous.rating) }
        if previous.label != nil { attributes.label = previous.label }
        // P1 / IPTC：损坏 sidecar 读不出 IPTC 时同样保留旧投影，避免一次坏文件清空面板。
        let previousDescriptive = previous.descriptive
        if !previousDescriptive.isEmpty { attributes.descriptive = previousDescriptive }
    }
}

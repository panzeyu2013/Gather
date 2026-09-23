// desktop/native/gather-core/Sources/GatherCore/Services/MetadataService.swift
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

public enum MetadataServiceError: Error, Equatable, CustomStringConvertible {
    /// TS: `Metadata writeback does not support these fields: ${fields}`
    case unsupportedFields([String])

    public var description: String {
        switch self {
        case .unsupportedFields(let fields):
            "Metadata writeback does not support these fields: \(fields.joined(separator: ", "))"
        }
    }
}

/// TS: metadata.service.ts 的 photos 轻查询行。
public struct MetadataPhotoLookup {
    public let id: String
    public let sessionId: String
    public let filepath: String

    public init(id: String, sessionId: String, filepath: String) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
    }
}

/// TS: MetadataService。
public final class MetadataService {
    private let metadataStore: any MetadataStore
    private let xmp: any XMPProvider
    private let connection: DBConnection
    private let mutations: any MetadataMutationPort
    private let assetResolver: PhotoAssetResolver?
    private let exif: (any ExifProvider)?
    private let dimensions: (any ImageDimensionsProvider)?
    private let embeddedReader: (any EmbeddedXMPReader)?

    public init(
        metadataStore: any MetadataStore,
        xmp: any XMPProvider,
        connection: DBConnection,
        mutations: any MetadataMutationPort,
        assetResolver: PhotoAssetResolver? = nil,
        exif: (any ExifProvider)? = nil,
        dimensions: (any ImageDimensionsProvider)? = nil,
        embeddedReader: (any EmbeddedXMPReader)? = nil
    ) {
        self.metadataStore = metadataStore
        self.xmp = xmp
        self.connection = connection
        self.mutations = mutations
        self.assetResolver = assetResolver
        self.exif = exif
        self.dimensions = dimensions
        self.embeddedReader = embeddedReader
    }

    // MARK: - TS 顶层函数

    /// TS: cacheRowToTags。
    private func cacheRowToTags(_ row: MetadataCacheRecord) -> MetadataTags {
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
                if let n = item.numberValue { return String(n) }
                return nil
            }
        case .none, .null:
            strings = []
        case .some(let scalar):
            if let s = scalar.stringValue {
                strings = [s]
            } else if let n = scalar.numberValue {
                strings = [String(n)]
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
            longitude: overlay.longitude ?? base.longitude
        )
    }

    /// TS: embeddedAttributesFromParse —— 从已解析 exifr 段派生内嵌
    /// rating/label/keywords，规则与 EmbeddedWriter.readExifrAttributes 完全一致：
    /// XMP dc:subject 优先于 IPTC，xmp:Rating ?? IFD0 rating 强转为数字，xmp:Label。
    /// IPTC-only 关键词（exifr 字符集不可靠）时返回 nil（走 exiftool 池）。
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
        let keywords = MetadataService.normalizeKeywordList(dc?["subject"])
        if keywords == nil, iptc?["Keywords"] != nil {
            return nil
        }
        return MetadataWriteAttributes(
            keywords: keywords ?? MetadataService.normalizeKeywordList(iptc?["Keywords"]),
            rating: rating,
            label: xmp?["Label"]?.stringValue
        )
    }

    /// TS: getPhotosByIds —— 800/块 IN 查询（镜像缓存仓库的分块，低于 SQLite
    /// 常见参数上限）。
    public func getPhotosByIds(_ photoIds: [String]) throws -> [MetadataPhotoLookup] {
        if photoIds.isEmpty { return [] }
        var photos: [MetadataPhotoLookup] = []
        for chunkStart in stride(from: 0, to: photoIds.count, by: 800) {
            let chunk = Array(photoIds[chunkStart..<min(chunkStart + 800, photoIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT id, session_id, filepath FROM photos WHERE id IN (\(placeholders))"
            ).query(chunk.map { .text($0) })
            photos.append(contentsOf: rows.map {
                MetadataPhotoLookup(
                    id: $0[0].textValue ?? "",
                    sessionId: $0[1].textValue ?? "",
                    filepath: $0[2].textValue ?? ""
                )
            })
        }
        return photos
    }

    /// TS: preserveValuesOnCorruptSidecar —— 损坏 sidecar 让 readAttributes 返回
    /// 空对象；没有该守卫缓存会被空值覆盖，直到文件再次变更前有效值全失。
    private func preserveValuesOnCorruptSidecar(
        photoId: String,
        filepath: String,
        attributes: inout MetadataWriteAttributes
    ) async {
        if !attributes.isEmpty { return }
        if !xmp.fileExists(TSPath.xmpSidecarPath(filepath)) { return }
        guard let previous = try? await metadataStore.metadata(photoId: photoId) else { return }
        let previousKeywords = previous.keywords
        if !previousKeywords.isEmpty { attributes.keywords = previousKeywords }
        if previous.rating != 0 { attributes.rating = Double(previous.rating) }
        if previous.label != nil { attributes.label = previous.label }
    }

    // MARK: - 公开 API

    /// TS: getMetadata —— 指纹失效检查 → 缓存命中 / 缺失提取（EXIF → sharp 兜底）
    /// → 批量事务 upsert。
    public func getMetadata(photoIds: [String]) async throws -> [String: MetadataTags] {
        var result: [String: MetadataTags] = [:]
        let allPhotos = try getPhotosByIds(photoIds)
        let photoById = Dictionary(uniqueKeysWithValues: allPhotos.map { ($0.id, $0) })
        var fingerprints: [String: (size: Int, value: String)] = [:]
        try await batchAsync(allPhotos, concurrency: 16) { photo in
            if let fingerprint = try? await MetadataFingerprint.cacheStalenessKey(photo.filepath) {
                fingerprints[photo.id] = fingerprint
            }
        }
        let cached = try await metadataStore.metadataBatch(photoIds: photoIds).filter { row in
            guard let fingerprint = fingerprints[row.photoId] else { return false }
            return row.fileSize == Int64(fingerprint.size) && row.fileMtime == fingerprint.value
        }
        let cachedIds = Set(cached.map(\.photoId))
        let missingIds = photoIds.filter { !cachedIds.contains($0) }

        for row in cached {
            result[row.photoId] = cacheRowToTags(row)
        }

        if !missingIds.isEmpty {
            let photos = missingIds.compactMap { photoById[$0] }
            // upsert 在并发提取期间缓冲、结束后批量落库（MetadataStore.upsertMetadataBatch
            // 是裸语句无内部事务，包裹安全）；每照片 try/catch 隔离提取失败。
            var pendingUpserts: [(photoId: String, sessionId: String, input: MetadataCacheInput)] = []

            try await batchAsync(photos, concurrency: 10) { photo in
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
                            await self.preserveValuesOnCorruptSidecar(
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

                            result[photo.id] = tags
                            pendingUpserts.append((photo.id, photo.sessionId, cacheInput))
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
                    await self.preserveValuesOnCorruptSidecar(
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

                    result[photo.id] = tags
                    pendingUpserts.append((photo.id, photo.sessionId, cacheInput))
                } catch {
                    GatherLogger.log("Failed to extract metadata for \(photo.filepath): \(error)", level: .warn)
                    result[photo.id] = MetadataTags()
                }
            }

            if !pendingUpserts.isEmpty {
                try await metadataStore.upsertMetadataBatch(
                    pendingUpserts.map { ($0.photoId, $0.sessionId, $0.input) })
            }
        }

        return result
    }

    /// TS: setMetadata —— 校验可写字段、合并缓存基线、入队 manual 变更、写缓存。
    public func setMetadata(photoId: String, tags: MetadataTags) async throws -> MetadataTags {
        let supported: Set<String> = ["rating", "label", "keywords"]
        let overlay = tagsDictionary(tags)
        let unsupported = overlay.keys.filter { !supported.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MetadataServiceError.unsupportedFields(unsupported)
        }
        let existing = try await metadataStore.metadata(photoId: photoId)
        let baseTags = existing.map { cacheRowToTags($0) } ?? MetadataTags()
        let merged = overlayTags(baseTags, overlay: overlay)

        let cacheInput = tagsToCacheInput(merged)
        let photos = try getPhotosByIds([photoId])
        let photo = photos.first
        let sessionId = photo?.sessionId ?? existing?.sessionId ?? ""

        if let photo, tags.keywords != nil || tags.rating != nil || tags.label != nil {
            var patch = MetadataPatch()
            if let rating = tags.rating { patch.rating = MetadataRatingPatch(value: rating) }
            if let label = tags.label { patch.label = MetadataLabelPatch(value: label) }
            if let keywords = tags.keywords {
                patch.keywords = MetadataKeywordsPatch(op: .replace, values: keywords)
            }
            _ = try await mutations.queueMutation(
                sessionId: sessionId,
                photoId: photoId,
                patch: patch,
                source: .manual
            )
        }

        try await metadataStore.upsertMetadata(photoId: photoId, sessionId: sessionId, data: cacheInput)
        return merged
    }

    /// TS: batchSet —— 按侧车路径分组串行（RAW+JPEG 共享一侧车时严格按输入序），
    /// 不同侧车并行。
    public func batchSet(updates: [(photoId: String, tags: MetadataTags)]) async throws -> BatchMetadataResult {
        var success = 0
        var failed = 0
        var errors: [String] = []

        // 批量预载照片（失败时退化为逐项查找，单块失败不 abort 整批）。
        var photosById: [String: MetadataPhotoLookup]? = nil
        do {
            photosById = Dictionary(
                uniqueKeysWithValues: try getPhotosByIds(updates.map(\.photoId)).map { ($0.id, $0) }
            )
        } catch {
            GatherLogger.log("Failed to batch-load photos for metadata batch: \(error)", level: .warn)
        }
        // 批量预解析侧车路径（每会话一次 IN 查询；解析器服务不到的行回退遗留路径）。
        var xmpPathByPhoto: [String: String]? = nil
        if let photosById, let assetResolver {
            do {
                var map: [String: String] = [:]
                var idsBySession: [String: [String]] = [:]
                for photo in photosById.values {
                    idsBySession[photo.sessionId, default: []].append(photo.id)
                }
                for (sessionId, ids) in idsBySession {
                    for (photoId, asset) in try assetResolver.resolveMany(sessionId: sessionId, photoIds: ids) {
                        map[photoId] = asset.xmpPath
                    }
                }
                xmpPathByPhoto = map
            } catch {
                // 解析失败回退逐项解析（不 abort 整批）。
                xmpPathByPhoto = nil
                GatherLogger.log("Failed to batch-resolve assets for metadata batch: \(error)", level: .warn)
            }
        }

        func groupKey(_ photoId: String) -> String {
            var photo = photosById?[photoId]
            if photo == nil, photosById == nil {
                photo = (try? getPhotosByIds([photoId]))?.first
            }
            guard let photo else { return "missing:\(photoId)" }
            if let xmpPathByPhoto, let xmpPath = xmpPathByPhoto[photoId] {
                return xmpPath
            } else if let assetResolver {
                if let xmpPath = try? assetResolver.resolve(sessionId: photo.sessionId, photoId: photoId).xmpPath {
                    return xmpPath
                }
                // 资产迁移不完整：按遗留路径分组（queueMutation 在该情形同样解析到它）。
            }
            return TSPath.xmpSidecarPath(photo.filepath)
        }

        var bySidecar: [String: [(photoId: String, tags: MetadataTags)]] = [:]
        for update in updates {
            bySidecar[groupKey(update.photoId), default: []].append(update)
        }

        try await batchAsync(Array(bySidecar.values), concurrency: 4) { group in
            for update in group {
                do {
                    _ = try await self.setMetadata(photoId: update.photoId, tags: update.tags)
                    success += 1
                } catch {
                    failed += 1
                    errors.append("\(update.photoId): \(String(describing: error))")
                }
            }
        }

        return BatchMetadataResult(success: success, failed: failed, errors: errors)
    }

    /// TS: populateCache —— sharp 尺寸/文件大小回填（无注入 provider 时 no-op）。
    public func populateCache(sessionId: String, photoIds: [String]) async throws {
        guard let dimensions else { return }
        var photoById: [String: MetadataPhotoLookup]? = nil
        do {
            photoById = Dictionary(
                uniqueKeysWithValues: try getPhotosByIds(photoIds).map { ($0.id, $0) }
            )
        } catch {
            GatherLogger.log("Failed to batch-load photos for cache populate: \(error)", level: .warn)
        }
        try await batchAsync(photoIds, concurrency: 10) { photoId in
            do {
                var photo = photoById?[photoId]
                if photo == nil, photoById == nil {
                    photo = (try? self.getPhotosByIds([photoId]))?.first
                }
                guard let photo else { return }
                guard let metadata = try await dimensions.metadata(filePath: photo.filepath) else { return }
                let input = MetadataCacheInput(
                    sessionId: sessionId,
                    width: metadata.width.map { Int64($0) },
                    height: metadata.height.map { Int64($0) },
                    fileSize: metadata.size.map { Int64($0) }
                )
                try await self.metadataStore.upsertMetadata(photoId: photoId, sessionId: sessionId, data: input)
            } catch {
                GatherLogger.log("Failed to populate cache for photo \(photoId): \(error)", level: .warn)
            }
        }
    }

    // MARK: - JSON 辅助

    /// 非 nil 字段的 JSON 字典（JSONEncoder 对 nil Optional 省略 key —— 等价
    /// TS `Object.keys(tags)` 只含真实存在的键）。
    private func tagsDictionary(_ tags: MetadataTags) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(tags),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let dict) = value else { return [:] }
        return dict
    }

    /// TS: `{ ...baseTags }` 后逐键覆盖（仅 tags 中真实存在的键）。
    private func overlayTags(_ base: MetadataTags, overlay: [String: JSONValue]) -> MetadataTags {
        guard let baseData = try? JSONEncoder().encode(base),
              var baseValue = try? JSONDecoder().decode(JSONValue.self, from: baseData),
              case .object(var baseDict) = baseValue else { return base }
        for (key, value) in overlay {
            baseDict[key] = value
        }
        baseValue = .object(baseDict)
        guard let data = try? JSONValue.stringify(baseValue),
              let merged = try? JSONDecoder().decode(MetadataTags.self, from: Data(data.utf8)) else {
            return base
        }
        return merged
    }
}

/// TS: `value ? String(value) : undefined`（exif 段标量字符串化）。
private func stringValue(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    if let string = value.stringValue { return string }
    if let number = value.numberValue { return String(number) }
    return nil
}

/// TS: batchAsync（utils/async.ts）—— 与 DuplicateService / coordinator 同款滑动窗口。
private func batchAsync<T, R>(
    _ items: [T],
    concurrency: Int,
    body: @escaping (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = MetadataBatchCursor(count: items.count)
    var collected: [(index: Int, value: R)] = []
    try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
        for _ in 0..<min(limit, items.count) {
            group.addTask {
                var local: [(Int, R)] = []
                while !Task.isCancelled, let index = cursor.nextIndex() {
                    do {
                        local.append((index, try await body(items[index])))
                    } catch {
                        cursor.markFailed()
                        throw error
                    }
                }
                return local
            }
        }
        for try await chunk in group {
            collected.append(contentsOf: chunk)
        }
    }
    collected.sort { $0.index < $1.index }
    return collected.map(\.value)
}

private final class MetadataBatchCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var failed = false
    private let count: Int

    init(count: Int) { self.count = count }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if failed || next >= count { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}

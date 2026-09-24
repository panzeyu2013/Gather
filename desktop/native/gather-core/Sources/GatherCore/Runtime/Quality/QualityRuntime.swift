// desktop/native/gather-core/Sources/GatherCore/Runtime/Quality/QualityRuntime.swift
// W2c：QualityRuntime actor —— quality.analyze / quality.get 的 Runtime 化
// （旧 Services/QualityService.swift 的 SQL 与评分逻辑分别下沉 Store / 纯函数层）。
//
// 边界与语义（docs/ARCHITECTURE-W2C-DESIGN.md §2.4）：
// - actor 无可变字段：进度计数 completed 为方法内局部（IndexCursor 充当完成序
//   计数），并发 runner 由 ConcurrentMap.run 驱动（常量 QualityModel.analyzeConcurrency）。
// - 临界区 = JobStore.upsertQualityResults 单事务；提交后调用
//   QualityInvalidationPort.invalidateQualityLookup(sessionId:)（异步端口，
//   避免与 CullingRuntime 直接耦合）。
// - 读路径：PhotoStore.getBySessionProjection / JobStore.cachedQualityResults /
//   latestQualityResults / FaceStore.largestFacePerPhoto /
//   SimilarityStore.latestResult + groupMembers；本文件零 SQL、零锁、
//   零 unchecked 并发标注。
// - 语义修正：rankings O(N+Σm log m)（纯函数层）；loadSimilarityGroups 经
//   SimilarityStore.latestResult（排除 precomputed 档）；get 按请求序返回
//   （设计 §2.4 ⑦ 行为变化）；缓存命中仅覆盖 photoId；assetFileId 缺失不落库；
//   取消经 context.throwIfCancelled 传播（不写 asset_analysis）。

import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// W2c：Quality 结果提交后的失效端口（旧 QualityService 的
/// invalidateCullingLookup 闭包从未接线；此处以协议解耦，makeDefault 注入
/// CullingSessionCache 的适配实现，Runtime 不 import CullingRuntime）。
public protocol QualityInvalidationPort: Sendable {
    /// 新的 technical_quality 结果已提交，失效该会话的质量查找缓存。
    func invalidateQualityLookup(sessionId: String) async
}

/// TS: imageService.getThumbnail(512) —— 预览灰度像素的最大边。
private let qualityPreviewMaxDimension = 512

public actor QualityRuntime {
    /// 灰度像素提供者（TS: imageService.getThumbnail(512) + sharp greyscale raw）。
    public typealias ImageMetricsProvider = (String, Int) async throws -> (pixels: [UInt8], width: Int, height: Int)
    /// stat 提供者（TS: node:fs/promises stat）。
    public typealias StatProvider = (String) throws -> (size: Int64, mtimeMs: Double)

    private let photoStore: any PhotoStore
    private let jobStore: any JobStore
    private let similarityStore: any SimilarityStore
    private let faceStore: any FaceStore
    private let imageProvider: ImageMetricsProvider
    private let statProvider: StatProvider
    private let invalidation: (any QualityInvalidationPort)?

    public init(
        photoStore: any PhotoStore,
        jobStore: any JobStore,
        similarityStore: any SimilarityStore,
        faceStore: any FaceStore,
        imageProvider: @escaping ImageMetricsProvider = QualityRuntime.defaultImageProvider,
        statProvider: @escaping StatProvider = QualityRuntime.defaultStat,
        invalidation: (any QualityInvalidationPort)? = nil
    ) {
        self.photoStore = photoStore
        self.jobStore = jobStore
        self.similarityStore = similarityStore
        self.faceStore = faceStore
        self.imageProvider = imageProvider
        self.statProvider = statProvider
        self.invalidation = invalidation
    }

    // MARK: - analyze

    /// TS: analyze —— 全量/子集评分 + 缓存命中（stat 指纹）+ 单事务落库 +
    /// 相对排名。progress 帧与 checkpoint 逐字对齐旧实现。
    public func analyze(
        sessionId: String,
        photoIds: [String]? = nil,
        context: JobRunContext? = nil
    ) async throws -> [QualityResult] {
        let sessionPhotos = try await photoStore.getBySessionProjection(sessionId: sessionId)
        let requested = photoIds.map(Set.init)
        let photos: [PhotoProjection] = requested
            .map { set in sessionPhotos.filter { set.contains($0.id) } }
            ?? PhotoAssets.collapse(sessionPhotos)
        let photoInputs = photos.map(QualityScorer.PhotoInput.init)

        // 批量预载：每照片一次 IN 查询替代逐照片缓存/人脸查询（TS 同款）。
        let cachedByPhoto = try await loadCachedBatch(photos)
        let faceInputs = try await loadFaces(sessionId: sessionId, photos: photos)

        // TS: 每 ANALYZE_CONCURRENCY 完成帧上报一次（worker 乱序完成，逐项上报
        // 可能倒退）；末帧（current === total）在循环外只发一次。
        //
        // 完成序计数：IndexCursor.nextIndex 调用即分配、唯一且单调，第 k 次完成
        // 拿到 k-1，等价于旧 completed += 1（无锁、无 actor 可变字段）。
        let completionCounter = IndexCursor(count: photos.count)
        let reportProgress: (Int) async -> Void = { current in
            // TS: checkpoint 为 { photoIds, nextPhotoIndex }；photoIds 为
            // undefined 时 JSON.stringify 丢弃该键（Swift 侧同样省略）。
            var checkpoint: [String: JSONValue] = ["nextPhotoIndex": .number(Double(current))]
            if let photoIds {
                checkpoint["photoIds"] = .array(photoIds.map { .string($0) })
            }
            await context?.updateProgress(JobProgressUpdate(
                current: current,
                total: photos.count,
                message: "quality.scoring",
                checkpoint: checkpoint
            ))
        }

        let imageProvider = self.imageProvider
        let statProvider = self.statProvider
        let total = photos.count
        let outcomes = try await ConcurrentMap.run(
            photoInputs,
            concurrency: QualityModel.analyzeConcurrency
        ) { photo -> AnalyzeOutcome in
            try await context?.throwIfCancelled()
            var result: QualityResult
            var insert: QualityScorer.InsertRow?
            do {
                let source = try statProvider(photo.filepath)
                let inputFingerprint = QualityScorer.fingerprint(size: source.size, mtimeMs: source.mtimeMs)
                if var cached = QualityScorer.matchCached(
                    cachedByPhoto[photo.id] ?? [],
                    fingerprint: inputFingerprint
                ) {
                    // 缓存命中：直接复用存储行（JOIN 已限定当前资产文件），
                    // 仅覆盖 photoId。
                    cached.photoId = photo.id
                    result = cached
                } else {
                    let preview = try await imageProvider(photo.filepath, qualityPreviewMaxDimension)
                    result = QualityScorer.score(
                        photo: photo,
                        preview: QualityScorer.PreviewInput(
                            pixels: preview.pixels, width: preview.width, height: preview.height
                        ),
                        face: faceInputs[photo.id],
                        inputFingerprint: inputFingerprint
                    )
                    // TS: 无资产文件行的照片不落库（failed 分支 insert 为 nil）。
                    guard photo.assetFileId != nil else { throw QualityError.noAssetFile }
                    insert = try QualityScorer.insertSerialization(
                        result: result, photoUpdatedAt: photo.updatedAt
                    )
                }
            } catch {
                result = QualityScorer.failed(
                    photoId: photo.id,
                    assetFileId: photo.assetFileId,
                    errorMessage: String(describing: error)
                )
                if photo.assetFileId != nil {
                    insert = try QualityScorer.insertSerialization(
                        result: result, photoUpdatedAt: photo.updatedAt
                    )
                }
            }
            let ordinal = await completionCounter.nextIndex()
            let current = min((ordinal ?? total) + 1, total)
            if current < total && current % QualityModel.analyzeConcurrency == 0 {
                await reportProgress(current)
            }
            return AnalyzeOutcome(result: result, insert: insert)
        }

        if !photos.isEmpty { await reportProgress(photos.count) }

        // 全部 INSERT 单事务串行提交（并行计算阶段不碰写）。
        let inserts = outcomes.compactMap(\.insert)
        if !inserts.isEmpty {
            try await jobStore.upsertQualityResults(inserts.map { insert in
                QualityAnalysisUpsert(
                    photoId: insert.photoId,
                    assetFileId: insert.assetFileId,
                    resultJson: insert.resultJson,
                    warningsJson: insert.warningsJson,
                    modelId: QualityModel.modelId,
                    modelVersion: QualityModel.modelVersion,
                    inputFingerprint: insert.fingerprint,
                    updatedAt: insert.updatedAt
                )
            })
        }
        // TS: culling 查找缓存失效（新结果已提交）。
        await invalidation?.invalidateQualityLookup(sessionId: sessionId)

        var results = outcomes.map(\.result)
        let groups = try await loadSimilarityGroups(sessionId: sessionId)
        QualityScorer.rankings(results: &results, groups: groups)
        return results
    }

    // MARK: - get

    /// TS: get —— 每照片最新一条 technical_quality 结果；按请求序返回
    /// （设计 §2.4 ⑦：旧实现返回 Dictionary 序，行为变化）。
    public func get(sessionId: String, photoIds: [String]? = nil) async throws -> [QualityResult] {
        let projection = try await photoStore.getBySessionProjection(sessionId: sessionId)
        let sessionIds = Set(projection.map(\.id))
        let ids = Self.requestedIds(
            photoIds,
            sessionIds: sessionIds,
            projectionIds: projection.map(\.id)
        )
        if ids.isEmpty { return [] }

        let rows = try await jobStore.latestQualityResults(photoIds: ids)
        var latest: [String: QualityResult] = [:]
        for row in rows {
            if latest[row.requestedPhotoId] != nil { continue }
            guard let data = row.resultJson.data(using: .utf8),
                  var result = try? JSONDecoder().decode(QualityResult.self, from: data) else {
                // 跳过无效历史分析行（TS catch 语义；计数 + log 提高可观测性）。
                GatherLogger.log(
                    "QualityRuntime.get skipped undecodable analysis row for photo \(row.requestedPhotoId)",
                    level: .warn
                )
                continue
            }
            result.photoId = row.requestedPhotoId
            latest[row.requestedPhotoId] = result
        }

        var results = ids.compactMap { latest[$0] }
        let groups = try await loadSimilarityGroups(sessionId: sessionId)
        QualityScorer.rankings(results: &results, groups: groups)
        return results
    }

    // MARK: - 默认 provider（旧 QualityService.defaultStat / defaultImageProvider）

    /// 默认 stat（TS stat 语义：文件缺失抛错，消息格式对齐 Node ENOENT）。
    public static func defaultStat(_ path: String) throws -> (size: Int64, mtimeMs: Double) {
        var s = stat()
        guard stat(path, &s) == 0 else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoSuchFileError,
                userInfo: [
                    NSFilePathErrorKey: path,
                    NSLocalizedDescriptionKey: "ENOENT: no such file or directory, stat '\(path)'",
                ]
            )
        }
        #if canImport(Glibc)
        let mtimeMs = Double(s.st_mtim.tv_sec) * 1000 + Double(s.st_mtim.tv_nsec) / 1_000_000
        #else
        let mtimeMs = Double(s.st_mtimespec.tv_sec) * 1000 + Double(s.st_mtimespec.tv_nsec) / 1_000_000
        #endif
        return (size: Int64(s.st_size), mtimeMs: mtimeMs)
    }

    /// 默认图像提供者：RAWDecoder.getThumbnail(512) → JPEG → CoreGraphics 灰度
    /// 像素网格（等价 sharp(buffer).greyscale().raw()）。
    public static func defaultImageProvider(path: String, maxDimension: Int) async throws -> (pixels: [UInt8], width: Int, height: Int) {
        #if canImport(ImageIO)
        let decoded = try RAWDecoder.getThumbnail(path: path, size: maxDimension)
        guard let grayscale = qualityGrayscalePixels(jpeg: decoded.buffer) else {
            throw QualityError.noAssetFile
        }
        return grayscale
        #else
        throw QualityError.noAssetFile
        #endif
    }

    // MARK: - 私有（读路径）

    /// TS: getCachedBatch —— 每照片同一 model/version 的全部存储结果
    /// （updated_at DESC；指纹精确匹配在 stat 后做）。
    private func loadCachedBatch(_ photos: [PhotoProjection]) async throws -> [String: [QualityScorer.CachedEntry]] {
        guard !photos.isEmpty else { return [:] }
        let rows = try await jobStore.cachedQualityResults(
            photoIds: photos.map(\.id),
            modelId: QualityModel.modelId,
            modelVersion: QualityModel.modelVersion
        )
        var byPhoto: [String: [QualityScorer.CachedEntry]] = [:]
        for row in rows {
            guard let data = row.resultJson.data(using: .utf8),
                  let result = try? JSONDecoder().decode(QualityResult.self, from: data) else {
                // 跳过无效历史行（TS 静默 continue；此处计数 + log）。
                GatherLogger.log(
                    "QualityRuntime.analyze skipped undecodable cached row for photo \(row.requestedPhotoId)",
                    level: .warn
                )
                continue
            }
            byPhoto[row.requestedPhotoId, default: []].append(
                QualityScorer.CachedEntry(fingerprint: row.inputFingerprint, result: result)
            )
        }
        return byPhoto
    }

    /// TS: getFacesBatch —— 每照片最大人脸观测（bbox 面积降序首行）。
    private func loadFaces(sessionId: String, photos: [PhotoProjection]) async throws -> [String: QualityScorer.FaceInput] {
        guard !photos.isEmpty else { return [:] }
        let faces = try await faceStore.largestFacePerPhoto(
            sessionId: sessionId,
            photoIds: photos.map(\.id)
        )
        return faces.mapValues {
            QualityScorer.FaceInput(
                x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                analysisSignature: $0.analysisSignature
            )
        }
    }

    /// TS: loadSimilarityGroups —— 最新非 precomputed 相似结果（latestResult）
    /// 的组成员行（旧实现直接取 latest similarity_results，会选中 precomputed 档）。
    private func loadSimilarityGroups(sessionId: String) async throws -> [Int: [String]]? {
        guard let latest = try await similarityStore.latestResult(sessionId: sessionId) else {
            return nil
        }
        guard let members = try await similarityStore.groupMembers(
            sessionId: sessionId,
            resultId: latest.id
        ) else {
            return nil
        }
        var groups: [Int: [String]] = [:]
        for member in members {
            groups[member.groupIndex, default: []].append(member.photoId)
        }
        return groups
    }

    /// 请求序去重 + 会话内过滤（photoIds == nil → 投影序）。
    private static func requestedIds(
        _ photoIds: [String]?,
        sessionIds: Set<String>,
        projectionIds: [String]
    ) -> [String] {
        let source = photoIds ?? projectionIds
        var seen = Set<String>()
        return source.filter { sessionIds.contains($0) && seen.insert($0).inserted }
    }
}

// MARK: - 私有载荷

/// 单照片分析结果 + 待落库行（TS worker 返回对）。
private struct AnalyzeOutcome {
    let result: QualityResult
    let insert: QualityScorer.InsertRow?
}

#if canImport(ImageIO)
/// JPEG 数据 → 设备灰度像素网格（sharp .greyscale().raw() 等价物）。
private func qualityGrayscalePixels(jpeg: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let colorSpace = CGColorSpaceCreateDeviceGray() as CGColorSpace?,
          let context = CGContext(
              data: &pixels,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.none.rawValue
          ) else { return nil }
    context.interpolationQuality = .high
    // 翻转坐标系：内存第 0 行 = 图像顶部（sharp raw 的 top-down 行序）。
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}
#endif

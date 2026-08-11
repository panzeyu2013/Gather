// desktop/native/gather-core/Sources/GatherCore/Services/QualityService.swift
// TS 源: desktop/src/main/services/quality/quality.service.ts（Phase 3.6 移植，全量）
// 技术质量评分服务：quality.analyze（JobService executor 长任务）与 quality.get。
//
// 移植差异说明（均为有意取舍）：
// - TS 的图片管线（imageService.getThumbnail(512) + sharp greyscale raw）经注入的
//   imageProvider 接入，产出与 sharp(raw) 等价的灰度像素网格（1 字节/像素）+ 宽高；
//   默认实现走 RAWDecoder.getThumbnail + CoreGraphics 灰度重编码（macOS），
//   与 TS 语义对齐；测试注入 fake 避免真解码慢路径。
// - stat 经 statProvider 注入（TS 无此接缝，用 node:fs 直读）；错误消息透传
//   String(describing:) 对齐 TS error.message 语义。
// - culling 可选依赖经 invalidateCullingLookup 闭包注入（TS 为可注入 CullingService）；
//   未注入时为 no-op。
// - 有界并发批处理复用 batchAsync 语义（滑动窗口，结果保序）；进度帧与 checkpoint
//  （{ photoIds, nextPhotoIndex }）逐字对齐 TS。
import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

public enum QualityServiceError: Error, Equatable {
    case noAssetFile
}

/// TS 错误消息逐字对齐（failed 结果的 errorMessage 必须等于 TS error.message）。
extension QualityServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noAssetFile: "QUALITY_NO_ASSET_FILE"
        }
    }
}

/// TS 错误码映射（桥接层序列化用）。
extension QualityServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .noAssetFile: .QUALITY_NO_ASSET_FILE
        }
    }
}

/// TS: metricFromPixels —— 灰度像素网格的锐度/曝光指标。边界保护、归一化
/// 常数（510 = 2 * 255）与钳制逐字对齐 TS。
public func metricFromPixels(data: [UInt8], width: Int, height: Int) -> (sharpness: Double, exposure: Double) {
    if width < 2 || height < 2 || data.isEmpty { return (0, 0) }
    var mean: Double = 0
    for byte in data { mean += Double(byte) }
    mean /= Double(data.count)
    var gradientSum: Double = 0
    for y in 0..<(height - 1) {
        for x in 0..<(width - 1) {
            let index = y * width + x
            gradientSum += Double(abs(Int(data[index]) - Int(data[index + 1])))
                + Double(abs(Int(data[index]) - Int(data[index + width])))
        }
    }
    let sharpness = max(0, min(1, gradientSum / Double((width - 1) * (height - 1) * 510)))
    let exposure = max(0, 1 - abs(mean - 128) / 128)
    return (sharpness, exposure)
}

/// TS: regionPixels —— 裁剪像素区域（Math.floor/ceil + 钳制），区域 < 2x2 返回 nil。
private func regionPixels(
    data: [UInt8],
    width: Int,
    height: Int,
    box: (x: Double, y: Double, width: Double, height: Double)
) -> (pixels: [UInt8], width: Int, height: Int)? {
    let left = max(0, min(width - 1, Int(box.x.rounded(.down))))
    let top = max(0, min(height - 1, Int(box.y.rounded(.down))))
    let right = max(left + 1, min(width, Int((box.x + box.width).rounded(.up))))
    let bottom = max(top + 1, min(height, Int((box.y + box.height).rounded(.up))))
    let regionWidth = right - left
    let regionHeight = bottom - top
    if regionWidth < 2 || regionHeight < 2 { return nil }
    var output = [UInt8](repeating: 0, count: regionWidth * regionHeight)
    for y in 0..<regionHeight {
        let srcStart = (top + y) * width + left
        let srcEnd = (top + y) * width + right
        output.replaceSubrange(
            y * regionWidth..<(y * regionWidth + regionWidth),
            with: data[srcStart..<srcEnd]
        )
    }
    return (output, regionWidth, regionHeight)
}

public final class QualityService {
    /// TS: MODEL_ID / MODEL_VERSION。
    public static let modelId = "technical-quality"
    public static let modelVersion = "1"
    /// TS: ANALYZE_CONCURRENCY —— 解码/stat/像素计算的并发窗口。
    public static let analyzeConcurrency = 6
    /// TS: IN_CHUNK_SIZE —— IN 列表分块，避免 SQLite 变量上限。
    public static let inChunkSize = 400

    /// 灰度像素提供者（TS: imageService.getThumbnail(512) + sharp greyscale raw）。
    public typealias ImageMetricsProvider = (String, Int) async throws -> (pixels: [UInt8], width: Int, height: Int)
    /// stat 提供者（TS: node:fs/promises stat）。
    public typealias StatProvider = (String) throws -> (size: Int64, mtimeMs: Double)

    private let photoRepo: PhotoRepo
    private let connection: DBConnection
    private let imageProvider: ImageMetricsProvider
    private let statProvider: StatProvider
    /// TS: culling?.invalidateSessionLookup（可选依赖）。
    private let invalidateCullingLookup: ((String) -> Void)?

    public init(
        photoRepo: PhotoRepo,
        connection: DBConnection,
        imageProvider: @escaping ImageMetricsProvider = QualityService.defaultImageProvider,
        statProvider: @escaping StatProvider = QualityService.defaultStat,
        invalidateCullingLookup: ((String) -> Void)? = nil
    ) {
        self.photoRepo = photoRepo
        self.connection = connection
        self.imageProvider = imageProvider
        self.statProvider = statProvider
        self.invalidateCullingLookup = invalidateCullingLookup
    }

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
        guard let grayscale = grayscalePixels(jpeg: decoded.buffer) else {
            throw QualityServiceError.noAssetFile
        }
        return grayscale
        #else
        throw QualityServiceError.noAssetFile
        #endif
    }

    /// TS: analyze —— 全量/子集评分 + 缓存命中（stat 指纹）+ 单事务落库 +
    /// 相对排名。progress 帧与 checkpoint 逐字对齐 TS。
    public func analyze(
        sessionId: String,
        photoIds: [String]? = nil,
        context: JobRunContext? = nil
    ) async throws -> [QualityResult] {
        let sessionPhotos = try photoRepo.getBySessionProjection(sessionId: sessionId)
        let requested = photoIds.map(Set.init)
        let photos: [PhotoProjectionRow] = requested
            .map { set in sessionPhotos.filter { set.contains($0.id) } }
            ?? PhotoAssets.collapse(sessionPhotos)
        // 批量预载：每照片一次 IN 查询替代逐照片缓存/人脸查询（TS 同款）。
        let cachedByPhoto = try getCachedBatch(photos)
        let facesByPhoto = try getFacesBatch(sessionId: sessionId, photos: photos)

        // TS: 每 ANALYZE_CONCURRENCY 完成帧上报一次（worker 乱序完成，逐项上报
        // 可能倒退）；末帧（current === total）在循环外只发一次。
        let progressLock = NSLock()
        var completed = 0
        let reportProgress: (Int) -> Void = { current in
            // TS: checkpoint 为 { photoIds, nextPhotoIndex }；photoIds 为
            // undefined 时 JSON.stringify 丢弃该键（Swift 侧同样省略）。
            var checkpoint: [String: JSONValue] = ["nextPhotoIndex": .number(Double(current))]
            if let photoIds {
                checkpoint["photoIds"] = .array(photoIds.map { .string($0) })
            }
            context?.updateProgress(JobProgressUpdate(
                current: current,
                total: photos.count,
                message: "quality.scoring",
                checkpoint: checkpoint
            ))
        }

        let outcomes = try await mapConcurrent(photos, concurrency: Self.analyzeConcurrency) { photo -> AnalyzeOutcome in
            try context?.throwIfCancelled()
            let assetFileId = photo.assetFileId
            var result: QualityResult
            var insert: QualityInsert?
            do {
                let source = try self.statProvider(photo.filepath)
                let inputFingerprint = "\(source.size):\(source.mtimeMs.rounded())"
                var cached: QualityResult?
                for entry in cachedByPhoto[photo.id] ?? [] where entry.fingerprint == inputFingerprint {
                    cached = entry.result
                    break
                }
                if var cached {
                    // 缓存命中：直接复用存储行（JOIN 已限定当前资产文件），
                    // 仅覆盖 photoId。
                    cached.photoId = photo.id
                    result = cached
                } else {
                    let preview = try await self.imageProvider(photo.filepath, 512)
                    let metrics = metricFromPixels(data: preview.pixels, width: preview.width, height: preview.height)
                    let face = facesByPhoto[photo.id]
                    var subjectSharpness: Double?
                    var closedEyeRisk: Double?
                    if let face {
                        var analysisMax = Double(max(photo.width, photo.height))
                        if let parsed = try? JSONValue.parse(face.analysisSignature),
                           case .object(let dict) = parsed,
                           case .number(let previewMax)? = dict["previewMaxDimension"] {
                            analysisMax = previewMax
                        }
                        let analysisScale = min(1, analysisMax / Double(max(photo.width, photo.height, 1)))
                        // TS 保持浮点（Math.max(1, width * scale)），不做整数截断。
                        let analysisWidth = max(1.0, Double(photo.width) * analysisScale)
                        let analysisHeight = max(1.0, Double(photo.height) * analysisScale)
                        let faceBox = (
                            x: face.x / analysisWidth * Double(preview.width),
                            y: face.y / analysisHeight * Double(preview.height),
                            width: face.w / analysisWidth * Double(preview.width),
                            height: face.h / analysisHeight * Double(preview.height)
                        )
                        if let subject = regionPixels(
                            data: preview.pixels, width: preview.width, height: preview.height, box: faceBox
                        ) {
                            subjectSharpness = metricFromPixels(
                                data: subject.pixels, width: subject.width, height: subject.height
                            ).sharpness
                            let eyesBox = (
                                x: Double(subject.width) * 0.12,
                                y: Double(subject.height) * 0.2,
                                width: Double(subject.width) * 0.76,
                                height: Double(subject.height) * 0.3
                            )
                            if let eyes = regionPixels(
                                data: subject.pixels, width: subject.width, height: subject.height, box: eyesBox
                            ) {
                                let eyeSharpness = metricFromPixels(
                                    data: eyes.pixels, width: eyes.width, height: eyes.height
                                ).sharpness
                                closedEyeRisk = max(
                                    0,
                                    min(1, 1 - eyeSharpness / max(0.01, (subjectSharpness ?? 0) * 1.15))
                                )
                            }
                        }
                    }
                    var warnings: [String] = []
                    if metrics.sharpness < 0.12 { warnings.append("motion_blur") }
                    if metrics.exposure < 0.3 { warnings.append("exposure_issue") }
                    if (closedEyeRisk ?? 0) > 0.72 { warnings.append("closed_eye_risk_heuristic") }
                    let focusScore = subjectSharpness ?? metrics.sharpness
                    let rounded3: (Double) -> Double = { ($0 * 1000).rounded() / 1000 }
                    result = QualityResult(
                        photoId: photo.id,
                        assetFileId: assetFileId,
                        status: .succeeded,
                        qualityScore: rounded3(
                            focusScore * 0.6 +
                            metrics.sharpness * 0.15 +
                            metrics.exposure * 0.2 +
                            (1 - (closedEyeRisk ?? 0)) * 0.05
                        ),
                        sharpness: rounded3(metrics.sharpness),
                        exposure: rounded3(metrics.exposure),
                        subjectSharpness: subjectSharpness.map(rounded3),
                        faceQuality: subjectSharpness,
                        closedEyeRisk: closedEyeRisk.map(rounded3),
                        confidence: face != nil ? 0.6 : 0.55,
                        warnings: warnings,
                        modelId: Self.modelId,
                        modelVersion: Self.modelVersion,
                        inputFingerprint: inputFingerprint,
                        updatedAt: nowISOString()
                    )
                    // TS: 无资产文件行的照片不落库（failed 分支 insert 为 nil）。
                    guard let assetFileId else { throw QualityServiceError.noAssetFile }
                    insert = QualityInsert(
                        photoId: photo.id,
                        assetFileId: assetFileId,
                        resultJson: try self.encodeJSON(result),
                        warningsJson: try self.encodeJSON(result.warnings),
                        fingerprint: result.inputFingerprint,
                        updatedAt: result.updatedAt
                    )
                }
            } catch {
                let failedAt = nowISOString()
                result = QualityResult(
                    photoId: photo.id,
                    assetFileId: assetFileId,
                    status: .failed,
                    errorMessage: String(describing: error),
                    qualityScore: 0,
                    sharpness: 0,
                    exposure: 0,
                    warnings: ["analysis_failed"],
                    modelId: Self.modelId,
                    modelVersion: Self.modelVersion,
                    inputFingerprint: "",
                    updatedAt: failedAt
                )
                if let assetFileId {
                    insert = QualityInsert(
                        photoId: photo.id,
                        assetFileId: assetFileId,
                        resultJson: try self.encodeJSON(result),
                        warningsJson: try self.encodeJSON(result.warnings),
                        fingerprint: "failed:\(photo.updatedAt)",
                        updatedAt: failedAt
                    )
                }
            }
            progressLock.lock()
            completed += 1
            let current = completed
            progressLock.unlock()
            if current < photos.count && current % Self.analyzeConcurrency == 0 {
                reportProgress(current)
            }
            return AnalyzeOutcome(result: result, insert: insert)
        }

        if !photos.isEmpty { reportProgress(photos.count) }

        // 全部 INSERT 单事务串行提交（并行计算阶段不碰写）。
        if outcomes.contains(where: { $0.insert != nil }) {
            let insertStmt = try connection.prepare("""
                INSERT OR REPLACE INTO asset_analysis (
                  photo_id, asset_file_id, analysis_type, result_json, warnings_json,
                  model_id, model_version, input_fingerprint, created_at, updated_at
                ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
              """)
            try connection.transaction {
                for outcome in outcomes {
                    guard let insert = outcome.insert else { continue }
                    _ = try insertStmt.run([
                        .text(insert.photoId),
                        .text(insert.assetFileId),
                        .text(insert.resultJson),
                        .text(insert.warningsJson),
                        .text(Self.modelId),
                        .text(Self.modelVersion),
                        .text(insert.fingerprint),
                        .text(insert.updatedAt),
                        .text(insert.updatedAt),
                    ])
                }
            }
        }
        // TS: culling 查找缓存失效（新结果已提交）。
        invalidateCullingLookup?(sessionId)

        var results = outcomes.map(\.result)
        let groups = try loadSimilarityGroups(sessionId: sessionId)
        try applyRelativeRanks(sessionId: sessionId, results: &results, groups: groups)
        return results
    }

    /// TS: get —— 每照片最新一条 technical_quality 结果（IN 分块 + latest-map）。
    public func get(sessionId: String, photoIds: [String]? = nil) throws -> [QualityResult] {
        let projection = try photoRepo.getBySessionProjection(sessionId: sessionId)
        let sessionIds = Set(projection.map(\.id))
        let ids: [String] = photoIds
            .map { Array(Set($0)).filter { sessionIds.contains($0) } }
            ?? Array(sessionIds)
        if ids.isEmpty { return [] }
        var rows: [(resultJson: String, requestedPhotoId: String)] = []
        for chunk in chunkIds(ids) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let queryRows = try connection.prepare("""
                SELECT aa.result_json, p.id AS requested_photo_id
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality' AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) })
            for row in queryRows {
                rows.append((row[0].textValue ?? "", row[1].textValue ?? ""))
            }
        }
        var latest: [String: QualityResult] = [:]
        for row in rows {
            if latest[row.requestedPhotoId] != nil { continue }
            guard let data = row.resultJson.data(using: .utf8),
                  var result = try? JSONDecoder().decode(QualityResult.self, from: data) else {
                // 跳过无效历史分析行（TS catch 语义）。
                continue
            }
            result.photoId = row.requestedPhotoId
            latest[row.requestedPhotoId] = result
        }
        var results = Array(latest.values)
        let groups = try loadSimilarityGroups(sessionId: sessionId)
        try applyRelativeRanks(sessionId: sessionId, results: &results, groups: groups)
        return results
    }

    // MARK: - 内部

    /// TS: getCachedBatch —— 每照片同一 model/version 的全部存储结果
    /// （updated_at DESC；指纹精确匹配在 stat 后做）。
    private func getCachedBatch(_ photos: [PhotoProjectionRow]) throws -> [String: [(fingerprint: String, result: QualityResult)]] {
        var rowsByPhoto: [String: [(fingerprint: String, result: QualityResult)]] = [:]
        let ids = photos.map(\.id)
        for chunk in chunkIds(ids) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT p.id AS photo_id, aa.result_json, aa.input_fingerprint
                FROM asset_analysis aa
                JOIN photos p ON p.asset_file_id = aa.asset_file_id
                WHERE p.id IN (\(placeholders)) AND aa.analysis_type = 'technical_quality'
                  AND model_id = ? AND model_version = ?
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) } + [.text(Self.modelId), .text(Self.modelVersion)])
            for row in rows {
                let photoId = row[0].textValue ?? ""
                guard let json = row[1].textValue,
                      let data = json.data(using: .utf8),
                      let result = try? JSONDecoder().decode(QualityResult.self, from: data) else {
                    continue
                }
                rowsByPhoto[photoId, default: []].append((row[2].textValue ?? "", result))
            }
        }
        return rowsByPhoto
    }

    /// TS: getFacesBatch —— 每照片最大人脸观测（bbox 面积降序首行）。
    private func getFacesBatch(sessionId: String, photos: [PhotoProjectionRow]) throws -> [String: FaceBox] {
        var faces: [String: FaceBox] = [:]
        let ids = photos.map(\.id)
        for chunk in chunkIds(ids) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
                FROM face_observations
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                ORDER BY bbox_w * bbox_h DESC
              """).query([.text(sessionId)] + chunk.map { .text($0) })
            for row in rows {
                let photoId = row[0].textValue ?? ""
                // 按面积降序，每照片首行即最大人脸。
                if faces[photoId] == nil {
                    faces[photoId] = FaceBox(
                        x: row[1].doubleValue ?? 0,
                        y: row[2].doubleValue ?? 0,
                        w: row[3].doubleValue ?? 0,
                        h: row[4].doubleValue ?? 0,
                        analysisSignature: row[5].textValue ?? ""
                    )
                }
            }
        }
        return faces
    }

    private func chunkIds(_ ids: [String]) -> [[String]] {
        var chunks: [[String]] = []
        for offset in stride(from: 0, to: ids.count, by: Self.inChunkSize) {
            chunks.append(Array(ids[offset..<min(offset + Self.inChunkSize, ids.count)]))
        }
        return chunks
    }

    /// TS: loadSimilarityGroups —— 最新 similarity_results 的组成员一次读完。
    private func loadSimilarityGroups(sessionId: String) throws -> [Int: [String]]? {
        let latest = try connection.prepare(
            "SELECT id FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1"
        ).get([.text(sessionId)])
        guard let latest, let resultId = latest[0].intValue else { return nil }
        let rows = try connection.prepare("""
            SELECT group_index, photo_id
            FROM similarity_result_members
            WHERE session_id = ? AND result_id = ?
            ORDER BY group_index, photo_id
          """).query([.text(sessionId), .int(resultId)])
        var groups: [Int: [String]] = [:]
        for row in rows {
            let groupIndex = Int(row[0].intValue ?? 0)
            groups[groupIndex, default: []].append(row[1].textValue ?? "")
        }
        return groups
    }

    /// TS: applyRelativeRanks —— 仅持久化相似组内的成功结果按 qualityScore 降序
    /// 排名（组内非本次结果的照片不占位）。
    private func applyRelativeRanks(
        sessionId: String,
        results: inout [QualityResult],
        groups: [Int: [String]]?
    ) throws {
        let successful = Dictionary(
            uniqueKeysWithValues: results
                .filter { $0.status == .succeeded }
                .map { ($0.photoId, $0) }
        )
        let memberGroups = try groups ?? loadSimilarityGroups(sessionId: sessionId)
        guard let memberGroups else { return }
        for members in memberGroups.values {
            let ranked = members
                .compactMap { successful[$0] }
                .sorted { $0.qualityScore > $1.qualityScore }
            for (index, member) in ranked.enumerated() {
                if let position = results.firstIndex(where: { $0.photoId == member.photoId }) {
                    results[position].relativeRank = Double(index + 1)
                }
            }
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - 私有载荷

/// 单照片分析结果 + 待落库行（TS worker 返回对）。
private struct AnalyzeOutcome {
    let result: QualityResult
    let insert: QualityInsert?
}

/// TS: 落库行（result_json / warnings_json 已序列化）。
private struct QualityInsert {
    let photoId: String
    let assetFileId: String
    let resultJson: String
    let warningsJson: String
    let fingerprint: String
    let updatedAt: String
}

/// face_observations 最大人脸（TS getFacesBatch 行）。
private struct FaceBox {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let analysisSignature: String
}

#if canImport(ImageIO)
/// JPEG 数据 → 设备灰度像素网格（sharp .greyscale().raw() 等价物）。
private func grayscalePixels(jpeg: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
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

/// TS: batchAsync —— 固定数量常驻 runner 从共享游标取任务（滑动窗口）；
/// 结果按输入索引保序；首个失败停止调度并传播（取消语义一致）。
private func mapConcurrent<T, R>(
    _ items: [T],
    concurrency: Int,
    body: @escaping (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = QualityBatchCursor(count: items.count)
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
    return collected.sorted { $0.index < $1.index }.map(\.value)
}

/// 共享游标（滑动窗口调度 + 首个失败即停）。
private final class QualityBatchCursor {
    private let lock = NSLock()
    private var next = 0
    private let count: Int
    private var failed = false

    init(count: Int) {
        self.count = count
    }

    func nextIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, next < count else { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }
}

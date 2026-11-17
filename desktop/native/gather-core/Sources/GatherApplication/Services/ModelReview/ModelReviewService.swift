// desktop/native/gather-core/Sources/GatherApplication/Services/ModelReview/ModelReviewService.swift
// 模型级初审的信号层：一次 1280 解码，产出人脸几何/采集质量/人脸合焦/审美。
//
// 设计约束（见 docs/design/p2-review-delivery/plan-2026-10-28.md §8）：
// - 只用系统模型（Vision / CoreGraphics），不引入模型资产；
// - 一次解码供所有人脸与审美使用（不做 decodeRegion / 不做显著性请求）；
// - 眼睛/微笑是**几何单调分**（不是概率），跨人脸只做相对比较；
// - 审美分在 macOS 26+ 恒可用；取不到分数（分析失败）时置 nil，不写警告、不阻断其它信号。
//
// P1 §3.11.5：同一次解码**顺手**产出场景语义（VNClassifyImageRequest top-8 +
// VNGenerateImageFeaturePrintRequest），写 photo_semantics。默认关闭
// （semantic_index_enabled=0）：未开启时零额外 Vision 调用、零额外存储。
// Vision 不可用 → 跳过并记 semantic_unavailable，绝不阻断初审。
import Foundation
import CoreGraphics
import ImageIO
import GatherAnalysis
import GatherProtocol
import GatherPersistence

#if canImport(Vision)
import Vision
#endif

public struct ModelReviewFaceBox: Equatable, Sendable {
    public let photoId: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let quality: Double

    public init(photoId: String, x: Double, y: Double, width: Double, height: Double, quality: Double) {
        self.photoId = photoId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.quality = quality
    }
}

public final class ModelReviewService: @unchecked Sendable {
    public static let modelId = "model-review"
    public static let modelVersion = "1"
    /// 预览最长边：人脸在 1280 上通常还有 100+ px，足够做关键点与合焦。
    public static let previewMaxDimension = 1280
    public static let analyzeConcurrency = 4
    /// 小于该边长的脸不做合焦判断（信息量不足）。
    public static let minimumFocusFacePx: Double = 96

    /// 解码预览（JPEG 字节）。默认实现走 RAWDecoder.getPreview。
    public typealias PreviewProvider = @Sendable (_ path: String, _ maxDimension: Int) async throws -> Data

    private let photoRepo: any PhotoRepository
    private let modelReviewRepo: ModelReviewRepo
    private let faceBoxes: (_ sessionId: String, _ photoIds: [String]) throws -> [ModelReviewFaceBox]
    private let previewProvider: PreviewProvider
    private let statProvider: (_ path: String) throws -> (size: Int64, mtimeMs: Double)
    /// 语义索引存储（nil = 未接线：完全不采集，行为与旧版一致）。
    private let semantics: (any PhotoSemanticsStore)?
    /// semantic_index_enabled（默认 0）。每次 analyze 读一次快照，避免逐张读设置。
    private let semanticsEnabled: () -> Bool
    /// 逐行 JSON 编解码复用（性能审计 R2）：旧实现每条结果新建 2 个 JSONEncoder、
    /// 每条缓存命中新建 1 个 JSONDecoder（1 万张 ≈ 2 万次分配）。
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(
        photoRepo: any PhotoRepository,
        modelReviewRepo: ModelReviewRepo,
        faceBoxes: @escaping (String, [String]) throws -> [ModelReviewFaceBox],
        previewProvider: @escaping PreviewProvider = ModelReviewService.defaultPreviewProvider,
        statProvider: @escaping (String) throws -> (size: Int64, mtimeMs: Double)
            = ModelReviewService.defaultStat,
        semantics: (any PhotoSemanticsStore)? = nil,
        semanticsEnabled: @escaping () -> Bool = { false }
    ) {
        self.photoRepo = photoRepo
        self.modelReviewRepo = modelReviewRepo
        self.faceBoxes = faceBoxes
        self.previewProvider = previewProvider
        self.statProvider = statProvider
        self.semantics = semantics
        self.semanticsEnabled = semanticsEnabled
    }

    public static func defaultPreviewProvider(path: String, maxDimension: Int) async throws -> Data {
        try RAWDecoder.getPreview(path: path, maxDimension: maxDimension, quality: 1).buffer
    }

    public static func defaultStat(_ path: String) throws -> (size: Int64, mtimeMs: Double) {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return (size: Int64(info.st_size), mtimeMs: Double(info.st_mtimespec.tv_sec) * 1000)
    }

    /// analyze 的逐张输入（缓存命中/需解码 + 是否需要补语义行）。
    private struct WorkItem {
        var index: Int
        var photo: PhotoProjectionRow
        var faces: [ModelReviewFaceBox]
        var fingerprint: String
        var cached: ModelReviewResult?
        /// 该照片还缺语义行：本次采集（缓存命中的也要单独补一次解码）。
        var needSemantics: Bool
    }

    public func analyze(
        sessionId: String,
        photoIds: [String]? = nil,
        force: Bool = false,
        isCancelled: () -> Bool = { false },
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [ModelReviewResult] {
        let allPhotos = try photoRepo.getBySessionProjection(sessionId: sessionId)
        let requested = photoIds.map(Set.init)
        let photos = requested.map { set in allPhotos.filter { set.contains($0.id) } }
            ?? PhotoAssets.collapse(allPhotos)
        guard !photos.isEmpty else { return [] }

        let facesByPhoto = Dictionary(grouping: try faceBoxes(sessionId, photos.map(\.id)),
                                      by: \.photoId)
        let cached = try modelReviewRepo.latest(photoIds: photos.map(\.id))

        var inserts: [ModelReviewInsert] = []
        inserts.reserveCapacity(photos.count)
        var resultsByIndex = [ModelReviewResult?](repeating: nil, count: photos.count)
        var collectedSemantics: [PhotoSemanticsInsert] = []

        // §3.11.5：语义索引默认关闭（semantic_index_enabled=0）。开启时在同一次解码上
        // 顺手采集；已建过语义行的照片不重复采集（升级/回填只补缺失的那些）。
        let semanticsStore = collectSemantics ? semantics : nil
        var indexedPhotoIds: Set<String> = []
        if let semanticsStore {
            do {
                indexedPhotoIds = try semanticsStore.indexedPhotoIds(sessionId: sessionId)
            } catch {
                // 读语义索引失败不该阻断初审：本批按"未建索引"处理（可能重复采集）。
                GatherLogger.log("model.review semantics lookup failed: \(error)", level: .warn)
            }
        }

        // 先把每张的输入算好（缓存命中/需解码），解码本身按 analyzeConcurrency 并发。
        var work: [WorkItem] = []
        work.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            let faces = (facesByPhoto[photo.id] ?? []).sorted { lhs, rhs in
                lhs.width * lhs.height > rhs.width * rhs.height
            }
            let fingerprint = Self.fingerprint(
                faces: faces, dimensions: (photo.width, photo.height),
                contentKey: photo.checksum)
            // 只复用成功行：失败行不得因指纹相同被永久缓存。
            var cachedResult: ModelReviewResult?
            if !force, let hit = cached[photo.id], hit.fingerprint == fingerprint,
               let decoded = decodeCached(hit.json), decoded.status == .succeeded {
                cachedResult = decoded
            }
            work.append(WorkItem(
                index: index, photo: photo, faces: faces,
                fingerprint: fingerprint, cached: cachedResult,
                needSemantics: semanticsStore != nil && !indexedPhotoIds.contains(photo.id)))
        }

        var completed = 0
        for start in stride(from: 0, to: work.count, by: Self.analyzeConcurrency) {
            if isCancelled() { throw CancellationError() }
            let batch = Array(work[start..<min(start + Self.analyzeConcurrency, work.count)])
            let evaluated = try await withThrowingTaskGroup(
                of: Evaluated.self, returning: [Evaluated].self
            ) { group in
                for item in batch {
                    if let cachedResult = item.cached {
                        group.addTask {
                            Evaluated(index: item.index, result: cachedResult, semantics: nil)
                        }
                    } else {
                        let service = self
                        group.addTask {
                            let outcome = await service.evaluate(
                                photo: item.photo, faces: item.faces,
                                fingerprint: item.fingerprint,
                                needSemantics: item.needSemantics)
                            return Evaluated(
                                index: item.index,
                                result: outcome.result,
                                semantics: outcome.semantics)
                        }
                    }
                }
                var collected: [Evaluated] = []
                for try await value in group { collected.append(value) }
                return collected
            }
            var batchInserts: [ModelReviewInsert] = []
            var batchSemantics: [PhotoSemanticsInsert] = []
            for item in evaluated.sorted(by: { $0.index < $1.index }) {
                let result = item.result
                resultsByIndex[item.index] = result
                if let observation = item.semantics,
                   let insert = Self.makeSemanticsInsert(
                       observation: observation,
                       photo: photos[item.index],
                       computedAt: result.updatedAt) {
                    batchSemantics.append(insert)
                }
                // 失败行不落库：否则本地化瞬时失败会被 REPLACE 刷新 updated_at，
                // 让 triage 指纹（count+max updated_at）反复变化、建议永久 stale。
                guard result.status == .succeeded else { continue }
                if let assetFileId = photos[item.index].assetFileId,
                   let insert = makeInsert(result: result, assetFileId: assetFileId) {
                    batchInserts.append(insert)
                }
            }
            // 每批落库：取消/崩溃时已完成的批次不丢，下次只补剩余照片。
            if !batchInserts.isEmpty {
                try modelReviewRepo.insertResults(
                    batchInserts, modelId: Self.modelId, modelVersion: Self.modelVersion)
            }
            // 语义行与模型行分开落库：语义失败不影响初审结果（+ 便于灰度和清空）。
            writeSemantics(batchSemantics)
            collectedSemantics.append(contentsOf: batchSemantics)
            completed += batch.count
            onProgress?(completed, photos.count)
        }
        // 语义回填：模型结果命中缓存（不需要重跑初审）但缺语义行的照片，
        // 单独补一次解码。只在"刚开启语义索引"时发生一次，不改变初审结果。
        if let semanticsStore {
            let covered = Set(collectedSemantics.map(\.photoId)).union(indexedPhotoIds)
            try await backfillSemantics(
                work.filter { $0.needSemantics && !covered.contains($0.photo.id) },
                store: semanticsStore,
                isCancelled: isCancelled)
        }

        let results = resultsByIndex.compactMap { $0 }
        guard results.count == photos.count else {
            throw CancellationError()
        }
        return results
    }

    /// 一次解码的产物：初审结果 + （可选）语义观测。
    struct Evaluated {
        let index: Int
        let result: ModelReviewResult
        let semantics: SemanticObservation?
    }

    private func evaluate(
        photo: PhotoProjectionRow,
        faces: [ModelReviewFaceBox],
        fingerprint: String,
        needSemantics: Bool
    ) async -> (result: ModelReviewResult, semantics: SemanticObservation?) {
        let now = nowISOString()
        do {
            let data = try await previewProvider(photo.filepath, Self.previewMaxDimension)
            guard let image = Self.decode(data) else {
                throw NSError(domain: "ModelReview", code: 1)
            }
            // 同一个 1280 解码上顺手采集语义（唯一额外成本是两次 Vision 请求）。
            let semantics = needSemantics ? Self.observeSemantics(image) : nil
            var warnings: [String] = []
            var signals: [FaceReviewSignal] = []
            for (index, face) in faces.prefix(3).enumerated() {
                signals.append(Self.faceSignal(
                    index: index, face: face, image: image, isPrimary: index == 0))
            }
            let primary = signals.first(where: \.isPrimary)
            if primary?.focusScore == nil, !faces.isEmpty {
                warnings.append("face_too_small")
            }
            // 与 TriagePolicy 共用阈值：两处各写一份会让「warnings 说闭眼、判定判 keep」。
            if let eyes = primary?.eyeOpenScore, eyes < TriagePolicy.v2.eyeOpenMin {
                warnings.append("eyes_closed_suspected")
            }
            if let focus = primary?.focusScore, focus < TriagePolicy.v2.faceFocusMin {
                warnings.append("face_out_of_focus")
            }
            let scores = Self.aestheticScores(image)
            let aesthetic = scores?.score
            let utility = scores?.isUtility
            if utility == true { warnings.append("utility_image") }
            return (result: ModelReviewResult(
                photoId: photo.id,
                assetFileId: photo.assetFileId,
                status: .succeeded,
                eyesOpenScore: primary?.eyeOpenScore,
                smileScore: primary?.smileScore,
                faceFocusScore: primary?.focusScore,
                aestheticScore: aesthetic,
                isUtilityImage: utility,
                faces: signals,
                warnings: warnings,
                modelId: Self.modelId,
                modelVersion: Self.modelVersion,
                inputFingerprint: fingerprint,
                updatedAt: now), semantics: semantics)
        } catch {
            return (result: ModelReviewResult(
                photoId: photo.id,
                assetFileId: photo.assetFileId,
                status: .failed,
                errorMessage: String(describing: error),
                warnings: ["analysis_failed"],
                modelId: Self.modelId,
                modelVersion: Self.modelVersion,
                inputFingerprint: fingerprint,
                updatedAt: now), semantics: nil)
        }
    }

    // MARK: - 纯函数 / 几何

    /// 指纹只由「像素尺寸 + 人脸」决定，**不含 size/mtime**：
    /// 内嵌元数据写回必然改 size/mtime（atomicReplace），但像素没变；
    /// 把 stat 放进指纹会让每次写回后全量重解码 + 让 triage 建议集体 stale。
    static func fingerprint(
        faces: [ModelReviewFaceBox],
        dimensions: (width: Int, height: Int)? = nil,
        contentKey: String = ""
    ) -> String {
        // 审美分能力位：macOS 26+ 恒可用；保留该位让旧缓存指纹不复活。
        let capabilities = 1
        let source = (dimensions.map { "\($0.width)x\($0.height)" } ?? "0x0")
            + "|" + contentKey + "|cap:\(capabilities)"
        let faceDigest = faces
            .map { "\($0.x),\($0.y),\($0.width),\($0.height),\($0.quality)" }
            .joined(separator: ";")
        return source + "|faces:" + faceDigest + "|model:" + modelVersion
    }

    /// 归一化 bbox（左上原点）→ 像素矩形。
    static func pixelRect(face: ModelReviewFaceBox, imageWidth: Int, imageHeight: Int) -> CGRect {
        let x = face.x * Double(imageWidth)
        let y = face.y * Double(imageHeight)
        let w = max(1, face.width * Double(imageWidth))
        let h = max(1, face.height * Double(imageHeight))
        return CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }

    /// 人脸合焦分：拉普拉斯方差 / 亮度标准差（对比度归一），再压到 0…1。
    /// 只做组内相对比较与保守阈值；绝对值不跨相机可比。
    static func focusScore(image: CGImage, faceRect: CGRect) -> Double? {
        let rect = faceRect.integral
        guard rect.width >= 8, rect.height >= 8,
              rect.width <= CGFloat(image.width), rect.height <= CGFloat(image.height) else {
            return nil
        }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -rect.minX, y: -(CGFloat(image.height) - rect.maxY),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let variance = laplacianVariance(pixels: pixels, width: width, height: height) else {
            return nil
        }
        return min(1, variance / (variance + 24))
    }

    /// 纯函数：灰度图的拉普拉斯方差（可测）。
    static func laplacianVariance(pixels: [UInt8], width: Int, height: Int) -> Double? {
        guard width >= 3, height >= 3, pixels.count == width * height else { return nil }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let value = 4 * Int(pixels[index])
                    - Int(pixels[index - 1]) - Int(pixels[index + 1])
                    - Int(pixels[index - width]) - Int(pixels[index + width])
                let asDouble = Double(value)
                sum += asDouble
                sumSquares += asDouble * asDouble
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        return max(0, sumSquares / Double(count) - mean * mean)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func decodeCached(_ json: String) -> ModelReviewResult? {
        do {
            return try jsonDecoder.decode(ModelReviewResult.self, from: Data(json.utf8))
        } catch {
            return nil
        }
    }

    func makeInsert(result: ModelReviewResult, assetFileId: String) -> ModelReviewInsert? {
        let json: Data
        do {
            json = try jsonEncoder.encode(result)
        } catch {
            return nil
        }
        let warnings: String
        do {
            warnings = String(data: try jsonEncoder.encode(result.warnings), encoding: .utf8) ?? "[]"
        } catch {
            warnings = "[]"
        }
        return ModelReviewInsert(
            photoId: result.photoId,
            assetFileId: assetFileId,
            resultJson: String(data: json, encoding: .utf8) ?? "{}",
            warningsJson: warnings,
            fingerprint: result.inputFingerprint,
            updatedAt: result.updatedAt)
    }

    // MARK: - 语义（photo_semantics）

    /// 语义采集总开关：接了存储 + 设置开启（semantic_index_enabled，默认 0）。
    private var collectSemantics: Bool { semantics != nil && semanticsEnabled() }

    /// Vision 语义采集；不可用时记 semantic_unavailable 并返回 nil（不阻断初审）。
    static func observeSemantics(_ image: CGImage) -> SemanticObservation? {
        switch ImageSemanticsExtractor.observe(image) {
        case .success(let observation):
            return observation
        case .failure(let failure):
            // 旧系统/Vision 不可用：只记日志，不写进 warnings（那会污染既有字段语义）。
            GatherLogger.log("model.review \(failure.description)", level: .warn)
            return nil
        }
    }

    static func makeSemanticsInsert(
        observation: SemanticObservation,
        photo: PhotoProjectionRow,
        computedAt: String
    ) -> PhotoSemanticsInsert? {
        guard !observation.labels.isEmpty || !observation.feature.isEmpty else { return nil }
        return PhotoSemanticsInsert(
            photoId: photo.id,
            sessionId: photo.sessionId,
            labelsJson: SemanticIndex.encodeLabels(observation.labels),
            feature: observation.feature.isEmpty
                ? nil : SemanticFeatureCodec.encode(observation.feature),
            featureDim: observation.feature.count,
            modelVersion: ImageSemanticsExtractor.modelVersion,
            computedAt: computedAt)
    }

    /// 语义行落库；失败只记日志（初审结果已提交，不能被语义连带改判失败）。
    private func writeSemantics(_ inserts: [PhotoSemanticsInsert]) {
        guard let semantics, !inserts.isEmpty else { return }
        do {
            try semantics.upsert(inserts)
        } catch {
            GatherLogger.log(
                "model.review semantics write failed (\(inserts.count) rows): \(error)",
                level: .warn)
        }
    }

    /// 缓存命中但缺语义行的回填（开启语义索引后的一次性补齐；取消即停）。
    private func backfillSemantics(
        _ items: [WorkItem],
        store: any PhotoSemanticsStore,
        isCancelled: () -> Bool
    ) async throws {
        guard !items.isEmpty else { return }
        for item in items {
            if isCancelled() { throw CancellationError() }
            do {
                let data = try await previewProvider(item.photo.filepath, Self.previewMaxDimension)
                guard let image = Self.decode(data),
                      let observation = Self.observeSemantics(image),
                      let insert = Self.makeSemanticsInsert(
                          observation: observation, photo: item.photo,
                          computedAt: nowISOString()) else { continue }
                try store.upsert([insert])
            } catch {
                // 单张失败不阻断整批回填（文件消失/损坏都算单张失败）。
                GatherLogger.log("model.review semantics backfill failed: \(error)", level: .warn)
            }
        }
    }
}

#if canImport(Vision)
extension ModelReviewService {
    /// 单张脸的关键点/采集质量/微笑/合焦。Vision 的 ROI 用左下原点归一化。
    static func faceSignal(
        index: Int,
        face: ModelReviewFaceBox,
        image: CGImage,
        isPrimary: Bool
    ) -> FaceReviewSignal {
        var signal = FaceReviewSignal(
            index: index, x: face.x, y: face.y, width: face.width, height: face.height,
            areaRatio: face.width * face.height, isPrimary: isPrimary)
        let roi = CGRect(
            x: face.x, y: 1 - face.y - face.height,
            width: face.width, height: face.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard roi.width > 0, roi.height > 0 else { return signal }
        let handler = VNImageRequestHandler(cgImage: image)
        // 关键点按脸框归一化：x 以脸宽、y 以脸高为单位。换算成像素等距量纲
        //（脸框像素高/宽），否则 EAR 里混进脸的长宽比，窄脸更易误判闭眼。
        let faceAspect = (roi.height * CGFloat(image.height))
            / max(1e-6, roi.width * CGFloat(image.width))

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.regionOfInterest = roi
        if perform(handler, [landmarks]),
           let faceObservation = landmarks.results?.max(by: {
               $0.boundingBox.width * $0.boundingBox.height
                   > $1.boundingBox.width * $1.boundingBox.height
           }),
           let points = faceObservation.landmarks {
            var eyes: [Double] = []
            for region in [points.leftEye, points.rightEye] {
                guard let region else { continue }
                let mapped = region.normalizedPoints.map { (x: Double($0.x), y: Double($0.y)) }
                if let ear = EyeOpenGeometry.eyeAspectRatio(mapped, aspectRatio: Double(faceAspect)) {
                    eyes.append(EyeOpenGeometry.score(ear: ear))
                }
            }
            if !eyes.isEmpty { signal.eyeOpenScore = eyes.min() }
            if let lips = points.outerLips {
                let mapped = lips.normalizedPoints.map { (x: Double($0.x), y: Double($0.y)) }
                signal.smileScore = SmileGeometry.score(points: mapped, faceWidth: 1)
            }
        }

        let capture = VNDetectFaceCaptureQualityRequest()
        capture.regionOfInterest = roi
        if perform(handler, [capture]),
           let quality = capture.results?.max(by: {
               $0.boundingBox.width * $0.boundingBox.height
                   > $1.boundingBox.width * $1.boundingBox.height
           })?.faceCaptureQuality {
            signal.captureQuality = Double(quality)
        }

        if let rect = Optional(pixelRect(face: face, imageWidth: image.width, imageHeight: image.height)),
           rect.width >= minimumFocusFacePx, rect.height >= minimumFocusFacePx {
            signal.focusScore = focusScore(image: image, faceRect: rect)
        }
        return signal
    }

    /// Vision 的 perform 失败不该中断整张照片：返回 false，调用方按"无信号"处理。
    static func perform(_ handler: VNImageRequestHandler, _ requests: [VNRequest]) -> Bool {
        do {
            try handler.perform(requests)
            return true
        } catch {
            return false
        }
    }

    static func aestheticScores(_ image: CGImage) -> (score: Double, isUtility: Bool)? {
        let request = VNCalculateImageAestheticsScoresRequest()
        guard perform(VNImageRequestHandler(cgImage: image), [request]),
              let observation = request.results?.first else { return nil }
        return (Double(observation.overallScore), observation.isUtility)
    }
}
#else
extension ModelReviewService {
    static func faceSignal(
        index: Int, face: ModelReviewFaceBox, image: CGImage, isPrimary: Bool
    ) -> FaceReviewSignal {
        FaceReviewSignal(
            index: index, x: face.x, y: face.y, width: face.width, height: face.height,
            areaRatio: face.width * face.height, isPrimary: isPrimary)
    }
}
#endif

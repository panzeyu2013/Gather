// desktop/native/gather-core/Sources/GatherApplication/Services/ModelReview/ModelReviewService.swift
// 模型级初审的信号层：一次 1280 解码，产出人脸几何/采集质量/人脸合焦/审美。
//
// 设计约束（见 docs/design/p2-review-delivery/plan-2026-10-28.md §8）：
// - 只用系统模型（Vision / CoreGraphics），不引入模型资产；
// - 一次解码供所有人脸与审美使用（不做 decodeRegion / 不做显著性请求）；
// - 眼睛/微笑是**几何单调分**（不是概率），跨人脸只做相对比较；
// - 审美分在 macOS 26+ 恒可用；取不到分数（分析失败）时置 nil，不写警告、不阻断其它信号。
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

    public init(
        photoRepo: any PhotoRepository,
        modelReviewRepo: ModelReviewRepo,
        faceBoxes: @escaping (String, [String]) throws -> [ModelReviewFaceBox],
        previewProvider: @escaping PreviewProvider = ModelReviewService.defaultPreviewProvider,
        statProvider: @escaping (String) throws -> (size: Int64, mtimeMs: Double)
            = ModelReviewService.defaultStat
    ) {
        self.photoRepo = photoRepo
        self.modelReviewRepo = modelReviewRepo
        self.faceBoxes = faceBoxes
        self.previewProvider = previewProvider
        self.statProvider = statProvider
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

        // 先把每张的输入算好（缓存命中/需解码），解码本身按 analyzeConcurrency 并发。
        struct WorkItem {
            var index: Int
            var photo: PhotoProjectionRow
            var faces: [ModelReviewFaceBox]
            var fingerprint: String
            var cached: ModelReviewResult?
        }
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
               let decoded = Self.decodeCached(hit.json), decoded.status == .succeeded {
                cachedResult = decoded
            }
            work.append(WorkItem(
                index: index, photo: photo, faces: faces,
                fingerprint: fingerprint, cached: cachedResult))
        }

        var completed = 0
        for start in stride(from: 0, to: work.count, by: Self.analyzeConcurrency) {
            if isCancelled() { throw CancellationError() }
            let batch = Array(work[start..<min(start + Self.analyzeConcurrency, work.count)])
            let evaluated = try await withThrowingTaskGroup(
                of: (Int, ModelReviewResult).self, returning: [(Int, ModelReviewResult)].self
            ) { group in
                for item in batch {
                    if let cachedResult = item.cached {
                        group.addTask { (item.index, cachedResult) }
                    } else {
                        let service = self
                        group.addTask {
                            (item.index, await service.evaluate(
                                photo: item.photo, faces: item.faces,
                                fingerprint: item.fingerprint))
                        }
                    }
                }
                var collected: [(Int, ModelReviewResult)] = []
                for try await pair in group { collected.append(pair) }
                return collected
            }
            var batchInserts: [ModelReviewInsert] = []
            for (index, result) in evaluated.sorted(by: { $0.0 < $1.0 }) {
                resultsByIndex[index] = result
                // 失败行不落库：否则本地化瞬时失败会被 REPLACE 刷新 updated_at，
                // 让 triage 指纹（count+max updated_at）反复变化、建议永久 stale。
                guard result.status == .succeeded else { continue }
                if let assetFileId = photos[index].assetFileId,
                   let insert = Self.makeInsert(result: result, assetFileId: assetFileId) {
                    batchInserts.append(insert)
                }
            }
            // 每批落库：取消/崩溃时已完成的批次不丢，下次只补剩余照片。
            if !batchInserts.isEmpty {
                try modelReviewRepo.insertResults(
                    batchInserts, modelId: Self.modelId, modelVersion: Self.modelVersion)
            }
            completed += batch.count
            onProgress?(completed, photos.count)
        }
        let results = resultsByIndex.compactMap { $0 }
        guard results.count == photos.count else {
            throw CancellationError()
        }
        return results
    }

    private func evaluate(
        photo: PhotoProjectionRow,
        faces: [ModelReviewFaceBox],
        fingerprint: String
    ) async -> ModelReviewResult {
        let now = nowISOString()
        do {
            let data = try await previewProvider(photo.filepath, Self.previewMaxDimension)
            guard let image = Self.decode(data) else {
                throw NSError(domain: "ModelReview", code: 1)
            }
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
            return ModelReviewResult(
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
                updatedAt: now)
        } catch {
            return ModelReviewResult(
                photoId: photo.id,
                assetFileId: photo.assetFileId,
                status: .failed,
                errorMessage: String(describing: error),
                warnings: ["analysis_failed"],
                modelId: Self.modelId,
                modelVersion: Self.modelVersion,
                inputFingerprint: fingerprint,
                updatedAt: now)
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

    static func probeStat(
        _ provider: (String) throws -> (size: Int64, mtimeMs: Double),
        _ path: String
    ) -> (size: Int64, mtimeMs: Double)? {
        do { return try provider(path) } catch { return nil }
    }

    static func decodeCached(_ json: String) -> ModelReviewResult? {
        do {
            return try JSONDecoder().decode(ModelReviewResult.self, from: Data(json.utf8))
        } catch {
            return nil
        }
    }

    static func makeInsert(result: ModelReviewResult, assetFileId: String) -> ModelReviewInsert? {
        let json: Data
        do {
            json = try JSONEncoder().encode(result)
        } catch {
            return nil
        }
        let warnings: String
        do {
            warnings = String(data: try JSONEncoder().encode(result.warnings), encoding: .utf8) ?? "[]"
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

// desktop/native/gather-core/Sources/GatherCore/Runtime/Quality/QualityScorer.swift
// W2c：QualityRuntime 纯函数层（指纹/缓存匹配/成功与失败结果构造/落库序列化/相对排名）。
//
// 来源与边界（Services/QualityService.swift 的纯逻辑下沉）：
// - fingerprint 对齐 analyze 的 stat 指纹 "\\(size):\\(mtimeMs.rounded())"（202）；
// - matchCached 对齐缓存命中循环（204-212，含“命中仅覆盖 photoId”语义）；
// - score 对齐成功结果构造（214-299：人脸投影/主体与眼部区域/警告/加权分/四舍五入）；
// - failed 对齐失败结果构造（301-315）；
// - insertSerialization 对齐落库行（291-298 / 316-325：成功用 inputFingerprint、
//   失败用 "failed:<photo.updatedAt>"、assetFileId 缺失返回 nil 不落库）；
// - rankings 替代旧 applyRelativeRanks（502-529）：仅对成功且命中相似组的结果
//   写 relativeRank（组内按 qualityScore 降序，index+1）；组外结果保持原值。
//   **复杂度 O(N + Σm log m)**：photoId → 结果下标一次索引（O(N)），逐组收集
//   成员（Σm）、排序（Σm log m）、回写（Σm），不再用 firstIndex 逐成员线性扫描
//   （旧实现 O(N × Σm)）。rank 值与旧实现逐一相同（同分按成员出现序，
//   与旧实现实际使用的稳定排序一致）。
// 本文件无 IO、无 SQL、不调用任何 Store 方法；时间戳经参数注入（默认
// nowISOString()）便于确定性测试。

import Foundation

public enum QualityScorer {
    // MARK: - 输入值类型

    /// 评分所需照片字段（PhotoProjection 的子集；assetFileId 缺失不落库）。
    public struct PhotoInput: Equatable, Sendable {
        public let id: String
        public let assetFileId: String?
        public let filepath: String
        public let width: Int
        public let height: Int
        public let updatedAt: String

        public init(
            id: String,
            assetFileId: String? = nil,
            filepath: String,
            width: Int,
            height: Int,
            updatedAt: String
        ) {
            self.id = id
            self.assetFileId = assetFileId
            self.filepath = filepath
            self.width = width
            self.height = height
            self.updatedAt = updatedAt
        }

        /// 从 Store 投影构造（getBysessionProjection 的行）。
        public init(_ photo: PhotoProjection) {
            self.init(
                id: photo.id,
                assetFileId: photo.assetFileId,
                filepath: photo.filepath,
                width: photo.width,
                height: photo.height,
                updatedAt: photo.updatedAt
            )
        }
    }

    /// 最大人脸观测（旧 QualityService.getFacesBatch 的 FaceBox 形状）。
    public struct FaceInput: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let w: Double
        public let h: Double
        public let analysisSignature: String

        public init(x: Double, y: Double, w: Double, h: Double, analysisSignature: String) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.analysisSignature = analysisSignature
        }
    }

    /// 灰度预览像素（旧 ImageMetricsProvider 的输出）。
    public struct PreviewInput: Equatable, Sendable {
        public let pixels: [UInt8]
        public let width: Int
        public let height: Int

        public init(pixels: [UInt8], width: Int, height: Int) {
            self.pixels = pixels
            self.width = width
            self.height = height
        }
    }

    /// 缓存条目（旧 getCachedBatch 行：input_fingerprint + 存储结果）。
    public struct CachedEntry: Equatable, Sendable {
        public let fingerprint: String
        public let result: QualityResult

        public init(fingerprint: String, result: QualityResult) {
            self.fingerprint = fingerprint
            self.result = result
        }
    }

    /// 落库行（asset_analysis 的 result_json / warnings_json 已序列化）。
    public struct InsertRow: Equatable, Sendable {
        public let photoId: String
        public let assetFileId: String
        public let resultJson: String
        public let warningsJson: String
        public let fingerprint: String
        public let updatedAt: String

        public init(
            photoId: String,
            assetFileId: String,
            resultJson: String,
            warningsJson: String,
            fingerprint: String,
            updatedAt: String
        ) {
            self.photoId = photoId
            self.assetFileId = assetFileId
            self.resultJson = resultJson
            self.warningsJson = warningsJson
            self.fingerprint = fingerprint
            self.updatedAt = updatedAt
        }
    }

    // MARK: - 指纹与缓存

    /// TS: \`\${source.size}:\${source.mtimeMs.rounded()}\`（stat 指纹）。
    public static func fingerprint(size: Int64, mtimeMs: Double) -> String {
        "\(size):\(mtimeMs.rounded())"
    }

    /// TS: 缓存命中循环 —— 指纹精确匹配的第一条存储结果（updated_at DESC 序）；
    /// 未命中返回 nil。命中行由调用方覆盖 photoId（JOIN 已限定当前资产文件）。
    public static func matchCached(
        _ entries: [CachedEntry],
        fingerprint: String
    ) -> QualityResult? {
        for entry in entries where entry.fingerprint == fingerprint {
            return entry.result
        }
        return nil
    }

    // MARK: - 结果构造

    /// TS: analyze 成功路径（214-299）—— 全图锐度/曝光 + 可选主体/眼部指标 +
    /// 警告 + 加权分（rounded3）。
    public static func score(
        photo: PhotoInput,
        preview: PreviewInput,
        face: FaceInput?,
        inputFingerprint: String,
        now: String = nowISOString()
    ) -> QualityResult {
        let metrics = QualityMetrics.metricFromPixels(
            data: preview.pixels, width: preview.width, height: preview.height
        )
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
            if let subject = QualityMetrics.regionPixels(
                data: preview.pixels, width: preview.width, height: preview.height, box: faceBox
            ) {
                subjectSharpness = QualityMetrics.metricFromPixels(
                    data: subject.pixels, width: subject.width, height: subject.height
                ).sharpness
                let eyesBox = (
                    x: Double(subject.width) * 0.12,
                    y: Double(subject.height) * 0.2,
                    width: Double(subject.width) * 0.76,
                    height: Double(subject.height) * 0.3
                )
                if let eyes = QualityMetrics.regionPixels(
                    data: subject.pixels, width: subject.width, height: subject.height, box: eyesBox
                ) {
                    let eyeSharpness = QualityMetrics.metricFromPixels(
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
        return QualityResult(
            photoId: photo.id,
            assetFileId: photo.assetFileId,
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
            modelId: QualityModel.modelId,
            modelVersion: QualityModel.modelVersion,
            inputFingerprint: inputFingerprint,
            updatedAt: now
        )
    }

    /// TS: analyze 失败路径（301-315）—— errorMessage 为 String(describing: error)。
    public static func failed(
        photoId: String,
        assetFileId: String?,
        errorMessage: String,
        now: String = nowISOString()
    ) -> QualityResult {
        QualityResult(
            photoId: photoId,
            assetFileId: assetFileId,
            status: .failed,
            errorMessage: errorMessage,
            qualityScore: 0,
            sharpness: 0,
            exposure: 0,
            warnings: ["analysis_failed"],
            modelId: QualityModel.modelId,
            modelVersion: QualityModel.modelVersion,
            inputFingerprint: "",
            updatedAt: now
        )
    }

    // MARK: - 落库序列化

    /// TS: 落库行 —— assetFileId 缺失返回 nil（不落库）；成功行指纹 =
    /// result.inputFingerprint，失败行指纹 = "failed:<photo.updatedAt>"。
    /// JSON 序列化失败抛错（旧实现 encodeJSON 同款）。
    public static func insertSerialization(
        result: QualityResult,
        photoUpdatedAt: String
    ) throws -> InsertRow? {
        guard let assetFileId = result.assetFileId else { return nil }
        let fingerprint: String
        switch result.status {
        case .succeeded: fingerprint = result.inputFingerprint
        case .failed: fingerprint = "failed:\(photoUpdatedAt)"
        }
        return InsertRow(
            photoId: result.photoId,
            assetFileId: assetFileId,
            resultJson: try encodeJSON(result),
            warningsJson: try encodeJSON(result.warnings),
            fingerprint: fingerprint,
            updatedAt: result.updatedAt
        )
    }

    // MARK: - 相对排名

    /// TS: applyRelativeRanks —— 仅持久化相似组内的成功结果按 qualityScore 降序
    /// 排名（组内非本次结果/失败结果不占位；组外结果保持原 relativeRank）。
    ///
    /// 复杂度 O(N + Σm log m)，rank 值与旧 O(N × Σm) 实现逐一相同：
    /// - photoId → 首个结果下标一次索引；
    /// - 逐组（group 键升序，保证确定性）收集成功成员、按分数降序稳定排序
    ///   （同分按成员出现序）、写 relativeRank = index + 1。
    public static func rankings(
        results: inout [QualityResult],
        groups: [Int: [String]]?
    ) {
        guard let groups else { return }
        var indexByPhotoId: [String: Int] = [:]
        indexByPhotoId.reserveCapacity(results.count)
        for (index, result) in results.enumerated() where indexByPhotoId[result.photoId] == nil {
            indexByPhotoId[result.photoId] = index
        }
        for groupIndex in groups.keys.sorted() {
            guard let members = groups[groupIndex] else { continue }
            var ranked: [(index: Int, quality: Double, order: Int)] = []
            ranked.reserveCapacity(members.count)
            for (order, photoId) in members.enumerated() {
                guard let index = indexByPhotoId[photoId],
                      results[index].status == .succeeded else { continue }
                ranked.append((index, results[index].qualityScore, order))
            }
            ranked.sort { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.order < rhs.order
            }
            for (rank, entry) in ranked.enumerated() {
                results[entry.index].relativeRank = Double(rank + 1)
            }
        }
    }

    // MARK: - 私有

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

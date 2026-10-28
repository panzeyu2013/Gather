// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ModelReview.swift
// 模型级初审的信号契约（纯值，无 I/O）。
//
// 与 technical_quality 分开存（asset_analysis.analysis_type = "model_review"）：
// - 技术质量是"像素统计"，模型信号是"人脸/审美判断"，两者的失效条件与版本不能混；
// - 换模型只让 model_review 重算，不触发 20k 行 technical_quality 全量重跑。
//
// 语义约定：
// - eyeOpenScore 是**几何单调分**（0 闭 … 1 睁），不是概率；跨人脸只做相对比较。
// - aestheticScore 只在 macOS 15+ 可用；不可用时为 nil 且带 aesthetic_unavailable 警告。
// - 所有分数都可能为 nil（无脸/太小/模型不可用），调用方必须显式处理。
import Foundation

public struct FaceReviewSignal: Codable, Equatable, Sendable {
    public var index: Int
    /// 归一化 bbox（左上原点，与 photos/face_observations 的约定一致）。
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var areaRatio: Double
    public var captureQuality: Double?
    public var eyeOpenScore: Double?
    public var smileScore: Double?
    public var focusScore: Double?
    public var isPrimary: Bool

    public init(
        index: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        areaRatio: Double,
        captureQuality: Double? = nil,
        eyeOpenScore: Double? = nil,
        smileScore: Double? = nil,
        focusScore: Double? = nil,
        isPrimary: Bool = false
    ) {
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.areaRatio = areaRatio
        self.captureQuality = captureQuality
        self.eyeOpenScore = eyeOpenScore
        self.smileScore = smileScore
        self.focusScore = focusScore
        self.isPrimary = isPrimary
    }
}

public struct ModelReviewResult: Codable, Equatable, Sendable {
    public var photoId: String
    public var assetFileId: String?
    public var status: QualityResultStatus
    public var errorMessage: String?
    /// 主体脸的眼睛睁开分（min(左,右) 的几何分）；无脸/太小为 nil。
    public var eyesOpenScore: Double?
    public var smileScore: Double?
    public var faceFocusScore: Double?
    public var aestheticScore: Double?
    public var isUtilityImage: Bool?
    public var faces: [FaceReviewSignal]
    /// 稳定警告码：eyes_closed_suspected / face_out_of_focus / utility_image /
    /// aesthetic_unavailable / face_too_small / analysis_failed。
    public var warnings: [String]
    public var modelId: String
    public var modelVersion: String
    public var inputFingerprint: String
    public var updatedAt: String

    public init(
        photoId: String,
        assetFileId: String? = nil,
        status: QualityResultStatus,
        errorMessage: String? = nil,
        eyesOpenScore: Double? = nil,
        smileScore: Double? = nil,
        faceFocusScore: Double? = nil,
        aestheticScore: Double? = nil,
        isUtilityImage: Bool? = nil,
        faces: [FaceReviewSignal] = [],
        warnings: [String] = [],
        modelId: String,
        modelVersion: String,
        inputFingerprint: String,
        updatedAt: String
    ) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.status = status
        self.errorMessage = errorMessage
        self.eyesOpenScore = eyesOpenScore
        self.smileScore = smileScore
        self.faceFocusScore = faceFocusScore
        self.aestheticScore = aestheticScore
        self.isUtilityImage = isUtilityImage
        self.faces = faces
        self.warnings = warnings
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.inputFingerprint = inputFingerprint
        self.updatedAt = updatedAt
    }
}

/// 纯函数：人脸几何 → 眼睛睁开分。
///
/// Vision 的 eye 轮廓给 6 个点（按顺序绕眼一周）。用 EAR = 上下眼睑平均距离 / 眼宽，
/// 再线性映射到 0…1。阈值取自公开的 EAR 经验区间（睁眼约 0.25–0.35，闭眼 < 0.12），
/// **只用于相对比较与保守阈值**，不当概率。
public enum EyeOpenGeometry {
    public static let closedEAR: Double = 0.10
    public static let openEAR: Double = 0.28

    /// - Parameter aspectRatio: 脸框的「像素高 / 像素宽」。Vision 的关键点按脸框归一化
    ///   （x 以脸宽、y 以脸高为单位），直接用欧氏距离会把长宽比（≈1.3–1.5）乘进垂直距离，
    ///   窄脸更容易被判闭眼。传入该比值后 y 距离换算回同一量纲。
    public static func eyeAspectRatio(
        _ points: [(x: Double, y: Double)], aspectRatio: Double = 1
    ) -> Double? {
        guard points.count >= 6, aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            let dx = a.x - b.x
            let dy = (a.y - b.y) * aspectRatio
            return (dx * dx + dy * dy).squareRoot()
        }
        let width = distance(points[0], points[3])
        guard width > 1e-6 else { return nil }
        let vertical = (distance(points[1], points[5]) + distance(points[2], points[4])) / 2
        return vertical / width
    }

    public static func score(ear: Double) -> Double {
        let t = (ear - closedEAR) / (openEAR - closedEAR)
        return min(1, max(0, t))
    }
}

/// 纯函数：嘴角几何 → 微笑分（0…1）。
///
/// 量纲：outerLips 的点按**脸框**归一化——x 以脸宽为单位、y 以脸高为单位。
/// 因此 `mouthWidth = 最大 x - 最小 x` 已经是「嘴宽 / 脸宽」，faceWidth 传 1 即可；
/// 竖直开口同理是「嘴高 / 脸高」。
///
/// 阈值按 Vision 关键点的实测区间标定（中性脸嘴宽≈0.36–0.42、微笑≈0.46–0.55；
/// 开口 0.03–0.12）。旧阈值 0.28/0.14 让几乎所有中性脸都 >1 → 分数恒饱和，
/// 组内平手排序时微笑维度实际不参与决策。
public enum SmileGeometry {
    /// points: outerLips 的点；faceWidth 用同一坐标系下的脸宽（脸框归一化时传 1）。
    public static func score(points: [(x: Double, y: Double)], faceWidth: Double) -> Double? {
        guard points.count >= 4, faceWidth > 1e-6 else { return nil }
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let mouthWidth = (maxX - minX) / faceWidth
        // 嘴张开时纵向占比变大（笑），但打哈欠也会大：宽度占比做主信号。
        let openness = maxY - minY
        let widthScore = (mouthWidth - 0.34) / 0.18
        let opennessScore = (openness - 0.04) / 0.08
        return min(1, max(0, 0.75 * widthScore + 0.25 * opennessScore))
    }
}

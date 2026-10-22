// desktop/native/gather-core/Sources/GatherAnalysis/Face/FaceQuality.swift
// 人脸质量评分（竞品对标：PhotoPrism FACE_SIZE=25 / FACE_SCORE=65 硬门槛 + OVERLAP 二次 pass；
// Immich minScore=0.7 只看检测置信度）。
//
// 本仓取"连续分"而非硬门槛：质量分 [0,1] 存入 face_observations.quality，
// 由聚类决定它能否成为核心点（见 FaceClusterer.coreQualityFloor），
// 从而既能过滤低质量脸，又不会把整张脸从结果里抹掉（可解释、可回溯）。
//
// 评分构成（权重写死、可复现）：
//   · capture  ：Vision VNDetectFaceCaptureQualityRequest 的人脸采集质量（若可用）
//                否则退回检测置信度 confidence（PhotoPrism FACE_SCORE 同义）
//   · size     ：bbox 短边像素 / 96，封顶 1（PhotoPrism FACE_SIZE 同义；25px 在我们这里
//                约对应 0.26 分，属于"可入簇但不该当核心点"）
//   · roll     ：|滚转| ≤ 15° 记满分，≥ 45° 记 0，中间线性（侧倾脸对识别贡献低）
//   quality = 0.4·capture + 0.4·size + 0.2·roll
import CoreGraphics
import Foundation

#if canImport(Vision)
import Vision

public enum FaceQuality {
    /// 尺寸满分对应的短边像素。
    public static let fullScoreFaceSizePx: Double = 96
    /// 滚转不减分阈值（度）。
    public static let rollFreeDegrees: Double = 15
    /// 滚转记 0 的阈值（度）。
    public static let rollZeroDegrees: Double = 45

    public static func sizeScore(faceSizePx: Double) -> Double {
        guard faceSizePx.isFinite, faceSizePx > 0 else { return 0 }
        return min(1, faceSizePx / fullScoreFaceSizePx)
    }

    public static func rollScore(rollDegrees: Double) -> Double {
        let magnitude = abs(rollDegrees)
        if !magnitude.isFinite { return 0 }
        if magnitude <= rollFreeDegrees { return 1 }
        if magnitude >= rollZeroDegrees { return 0 }
        return 1 - (magnitude - rollFreeDegrees) / (rollZeroDegrees - rollFreeDegrees)
    }

    /// 综合质量（[0,1]，钳制）。
    public static func composite(
        confidence: Double,
        faceSizePx: Double,
        rollDegrees: Double,
        captureQuality: Double?
    ) -> Double {
        let capture = captureQuality.map { min(max($0, 0), 1) } ?? min(max(confidence, 0), 1)
        let value = 0.4 * capture + 0.4 * sizeScore(faceSizePx: faceSizePx) + 0.2 * rollScore(rollDegrees: rollDegrees)
        return min(max(value, 0), 1)
    }

    /// 两个归一化 bbox 的交并比（Vision 坐标系一致即可用；同一次检测的框都用左下原点）。
    public static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let interArea = Double(intersection.width) * Double(intersection.height)
        let unionArea = Double(lhs.width) * Double(lhs.height) + Double(rhs.width) * Double(rhs.height) - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    /// 在两个请求（人脸检测 / 采集质量）结果之间按 bbox 最大重叠配对。
    /// Vision 不保证两次 perform 的观测顺序一致，故不能按下标配对。
    /// 返回匹配到的采集质量；无重叠（IoU ≤ 0.5）视为未匹配（避免张冠李戴）。
    public static func captureQuality(
        for box: CGRect,
        among observations: [VNFaceObservation],
        minimumOverlap: Double = 0.5
    ) -> Double? {
        var best: (overlap: Double, quality: Double)?
        for observation in observations {
            guard let quality = observation.faceCaptureQuality else { continue }
            let overlap = intersectionOverUnion(box, observation.boundingBox)
            guard overlap > minimumOverlap else { continue }
            if best == nil || overlap > best!.overlap {
                best = (overlap, Double(quality))
            }
        }
        return best?.quality
    }
}
#endif

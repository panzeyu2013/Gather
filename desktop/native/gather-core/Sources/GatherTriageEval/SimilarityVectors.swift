// desktop/native/gather-core/Sources/GatherTriageEval/SimilarityVectors.swift
// Wave3 / task-19：评估用的"临时向量"——不落模型、不改产品行为。
//
// 两条通道（与产品现状对照）：
// - featureprint：Vision `VNGenerateImageFeaturePrintRequest`（复用 Application 的
//   ImageSemanticsExtractor，1280 预览解码，与 model.review 的语义索引同源）；
// - dhash：评比赛的基线——复用 GatherApplication 的 computeVisualHashes（与
//   DuplicateService 同一函数、同一 9x8 灰度网格），只在本工具注入像素 provider。
import Foundation
import CoreGraphics
import ImageIO
import GatherApplication
import GatherAnalysis

enum SimilarityVectorSource: String {
    case featureprint
    case dhash

    var chineseLabel: String {
        switch self {
        case .featureprint: "Vision FeaturePrint"
        case .dhash: "dHash（产品基线）"
        }
    }
}

enum SimilarityVectors {
    /// 与 ModelReviewService.previewMaxDimension 对齐：语义索引也跑在 1280 预览上，
    /// 评估必须用同一分辨率的向量，否则阈值结论不能迁移到产品。
    static let featurePrintMaxDimension = 1280
    /// 与 DuplicateService 的视觉 hash 缩略图尺寸一致（256）。
    static let dHashThumbnailSize = 256

    // MARK: - 解码

    static func decodeCGImage(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // HEIC/HEIF/PSD 这类容器没有内嵌缩略图时退回整图解码（不做 EXIF 方向摆正：
        // 评估只看相对相似度，报告里会注明这个近似）。
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - FeaturePrint

    static var isFeaturePrintSupported: Bool { ImageSemanticsExtractor.isSupported }

    static func featurePrint(path: String) -> [Float]? {
        guard ImageSemanticsExtractor.isSupported else { return nil }
        guard let image = decodeCGImage(path: path, maxPixel: featurePrintMaxDimension) else {
            return nil
        }
        switch ImageSemanticsExtractor.observe(image) {
        case .success(let observation):
            return observation.feature.isEmpty ? nil : observation.feature
        case .failure:
            return nil
        }
    }

    /// 批量 dHash：复用 GatherApplication 的 computeVisualHashes（与 DuplicateService 同一入口）。
    static func dHashes(paths: [String]) async -> [String: UInt64] {
        let rows = paths.map { (id: $0, filepath: $0) }
        let computed = await computeVisualHashes(photos: rows) { path, _ in
            RAWDecoder.pixels9x8(path: path)
        }
        var result: [String: UInt64] = [:]
        for (path, hex) in computed {
            guard let hash = UInt64(hex, radix: 16) else { continue }
            result[path] = hash
        }
        return result
    }

    // MARK: - 相似度

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return -1 }
        return Double(dot / (sqrt(leftNorm) * sqrt(rightNorm)))
    }

    static func hamming(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// 统一成"越大越像"：dHash 的 64 位汉明距离换算成 [0,1]。
    static func similarity(hammingDistance: Int) -> Double {
        1 - Double(hammingDistance) / 64
    }

    /// dHash 阈值扫描：k = 允许的汉明位数（越小越严），换算回相似度阈值（升序）。
    static func dHashThresholds(maxBits: Int = 16) -> [Double] {
        (0...max(0, maxBits)).map { bits in similarity(hammingDistance: bits) }.sorted()
    }
}

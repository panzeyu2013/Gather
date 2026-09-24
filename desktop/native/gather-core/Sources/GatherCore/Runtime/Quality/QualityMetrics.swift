// desktop/native/gather-core/Sources/GatherCore/Runtime/Quality/QualityMetrics.swift
// W2c：QualityRuntime 纯函数层（灰度像素指标 + 区域裁剪 + 模型常量）。
//
// 来源与边界（Services/QualityService.swift:46-97 的纯逻辑下沉）：
// - metricFromPixels / regionPixels 逐字对齐旧实现（边界保护、归一化常数
//   510 = 2 * 255、Math.floor/ceil + 钳制、区域 < 2x2 返回 nil）；
// - QualityModel 常量对齐 QualityService 的 MODEL_ID / MODEL_VERSION /
//   ANALYZE_CONCURRENCY / IN_CHUNK_SIZE。
// 本文件无 IO、无 SQL、不调用任何 Store 方法、不依赖解码框架。
//
// 命名注记：旧 QualityService.swift 顶层已有 public func metricFromPixels（服务
// 删除前不能重名），故纯函数收进 QualityMetrics 命名空间（委托调用点从
// metricFromPixels(...) 变为 QualityMetrics.metricFromPixels(...)）。

import Foundation

/// TS: MODEL_ID / MODEL_VERSION / ANALYZE_CONCURRENCY / IN_CHUNK_SIZE。
public enum QualityModel {
    public static let modelId = "technical-quality"
    public static let modelVersion = "1"
    /// TS: ANALYZE_CONCURRENCY —— 解码/stat/像素计算的并发窗口。
    public static let analyzeConcurrency = 6
    /// TS: IN_CHUNK_SIZE —— IN 列表分块，避免 SQLite 变量上限。
    public static let inChunkSize = 400
}

public enum QualityMetrics {
    /// TS: metricFromPixels —— 灰度像素网格的锐度/曝光指标。边界保护、归一化
    /// 常数（510 = 2 * 255）与钳制逐字对齐 TS。
    public static func metricFromPixels(
        data: [UInt8],
        width: Int,
        height: Int
    ) -> (sharpness: Double, exposure: Double) {
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

    /// TS: regionPixels —— 裁剪像素区域（Math.floor/ceil + 钳制），区域 < 2x2
    /// 返回 nil。
    public static func regionPixels(
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
}

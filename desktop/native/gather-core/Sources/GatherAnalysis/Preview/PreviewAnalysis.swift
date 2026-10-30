// desktop/native/gather-core/Sources/GatherAnalysis/Preview/PreviewAnalysis.swift
// P1 下一波 §3.9：挑片可视化的纯函数（直方图 / 合焦图 / AF 几何 / 参考对比几何）。
//
// 三条硬约束（设计 §3.9 开头）：
// 1. **只吃已加载的预览像素**：本文件不打开任何文件、不调 ImageIO。输入是
//    uI 侧从"已经显示的预览"栅格化出来的 PreviewPixels（RGBA8）。因此这里的
//    一切都能在单元测试里用合成像素做金样，不需要 fixture 图片。
// 2. **语义是预览，不是 RAW**：直方图/合焦图都基于 8bit 显示预览（已应用 EXIF
//    方向与相机色彩），UI 必须标注"基于预览"——它不能当曝光工具用。
// 3. **纯函数**：相同输入必须得到相同输出；不读设置、不缓存、不打日志。
//
// 性能：降采样到 256（直方图）/ 1280（合焦图）后再算；合焦图用积分图求 3×3
// 局部方差（O(n)），1280×1280 约 2ms（Apple silicon 实测同数量级）。
import Foundation
import GatherProtocol

public enum PreviewAnalysis {
    /// 直方图降采样长边（§3.9.1：预览 → 256px）。
    public static let histogramSampleDimension = 256
    /// 合焦图计算前的降采样长边（§3.9.2：1280）。
    public static let focusSampleDimension = 1280
    /// 合焦图归一化用的分位（99%：避开单像素极值把整图压平）。
    public static let focusNormalizationPercentile = 0.99
    /// 分位统计的分桶数。
    static let normalizationBuckets = 1024

    // MARK: - 直方图

    /// 64 bin 亮度 + RGB 占比 + 阴影死黑/高光溢出比例。
    ///
    /// - bins：1...1024（越界夹取，缺省 64）。
    /// - 亮度按 Rec.709 系数（0.2126/0.7152/0.0722）在 **sRGB 编码值**上加权，
    ///   与 Photoshop/Preview 的"亮度直方图"同口径；不是线性光亮度。
    /// - 阴影死黑 = max(R,G,B) == 0；高光溢出 = max(R,G,B) == 255（任一通道触顶）。
    public static func histogram(_ pixels: PreviewPixels, bins: Int = PreviewHistogram.defaultBins) -> PreviewHistogram {
        let binCount = max(1, min(bins, 1024))
        let sampled = downsample(pixels, maxDimension: histogramSampleDimension)
        guard sampled.isWellFormed else {
            return PreviewHistogram(bins: binCount)
        }
        var luminanceBins = [Int](repeating: 0, count: binCount)
        var redBins = [Int](repeating: 0, count: binCount)
        var greenBins = [Int](repeating: 0, count: binCount)
        var blueBins = [Int](repeating: 0, count: binCount)
        var shadowPixels = 0
        var highlightPixels = 0
        var count = 0
        let rgba = sampled.rgba
        var offset = 0
        while offset + 3 < rgba.count {
            let r = Int(rgba[offset])
            let g = Int(rgba[offset + 1])
            let b = Int(rgba[offset + 2])
            let luma = luminanceByte(r: r, g: g, b: b)
            luminanceBins[binIndex(luma, bins: binCount)] += 1
            redBins[binIndex(r, bins: binCount)] += 1
            greenBins[binIndex(g, bins: binCount)] += 1
            blueBins[binIndex(b, bins: binCount)] += 1
            let maxChannel = max(r, max(g, b))
            if maxChannel == 0 { shadowPixels += 1 }
            if maxChannel == 255 { highlightPixels += 1 }
            count += 1
            offset += 4
        }
        guard count > 0 else { return PreviewHistogram(bins: binCount) }
        let scale = 1.0 / Double(count)
        return PreviewHistogram(
            bins: binCount,
            luminance: luminanceBins.map { Double($0) * scale },
            red: redBins.map { Double($0) * scale },
            green: greenBins.map { Double($0) * scale },
            blue: blueBins.map { Double($0) * scale },
            shadowClip: Double(shadowPixels) * scale,
            highlightClip: Double(highlightPixels) * scale,
            sampleCount: count
        )
    }

    // MARK: - 合焦图

    /// 合焦图：灰度 → 3×3 局部方差（积分图）→ 按 99 分位归一化到 0...1。
    ///
    /// 纯色图（含全黑/全白）方差恒 0 → 全 0；棋盘/文字/边缘区域方差高 → 接近 1。
    public static func focusMap(_ pixels: PreviewPixels) -> FocusMap {
        let sampled = downsample(pixels, maxDimension: focusSampleDimension)
        guard sampled.isWellFormed else {
            return FocusMap()
        }
        let width = sampled.width
        let height = sampled.height
        let rgba = sampled.rgba
        // 灰度（0...255 → Double）。
        var gray = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let base = index * 4
            gray[index] = Double(luminanceByte(
                r: Int(rgba[base]), g: Int(rgba[base + 1]), b: Int(rgba[base + 2])
            ))
        }
        // 积分图（w+1 × h+1）：sum 与 sumOfSquares。
        let rowStride = width + 1
        var sums = [Double](repeating: 0, count: rowStride * (height + 1))
        var squares = [Double](repeating: 0, count: rowStride * (height + 1))
        for y in 1...height {
            var rowSum = 0.0
            var rowSquare = 0.0
            for x in 1...width {
                let value = gray[(y - 1) * width + (x - 1)]
                rowSum += value
                rowSquare += value * value
                sums[y * rowStride + x] = sums[(y - 1) * rowStride + x] + rowSum
                squares[y * rowStride + x] = squares[(y - 1) * rowStride + x] + rowSquare
            }
        }
        // 3×3 局部方差（边界窗口裁剪到图内）。
        var variances = [Double](repeating: 0, count: width * height)
        var maxVariance = 0.0
        for y in 0..<height {
            let y0 = max(0, y - 1)
            let y1 = min(height - 1, y + 1)
            for x in 0..<width {
                let x0 = max(0, x - 1)
                let x1 = min(width - 1, x + 1)
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = rectSum(sums, stride: rowStride, x0: x0, y0: y0, x1: x1, y1: y1)
                let square = rectSum(squares, stride: rowStride, x0: x0, y0: y0, x1: x1, y1: y1)
                let mean = sum / area
                let variance = max(0, square / area - mean * mean)
                variances[y * width + x] = variance
                if variance > maxVariance { maxVariance = variance }
            }
        }
        guard maxVariance > 0 else {
            return FocusMap(width: width, height: height, values: variances, normalization: 0)
        }
        let denominator = max(normalizationLevel(for: variances, maxValue: maxVariance), 1e-9)
        let values = variances.map { min(1, $0 / denominator) }
        return FocusMap(
            width: width,
            height: height,
            values: values,
            normalization: denominator
        )
    }

    /// 合焦掩膜：把合焦图按区域取最大值降到 maxDimension 长边，再按阈值二值化。
    ///
    /// 用「区域内最大值」而不是最近邻采样：细小的合焦区域（眼睛/睫毛）必须保住，
    /// 否则 1280 → 320 会把它采丢。
    public static func focusMask(_ map: FocusMap, parameters: FocusMaskParameters) -> FocusMask {
        guard !map.isEmpty else { return FocusMask(threshold: parameters.threshold) }
        let target = max(16, min(parameters.maxDimension, 2048))
        let longest = max(map.width, map.height)
        let scale = Double(target) / Double(longest)
        let outWidth = max(1, min(map.width, Int((Double(map.width) * scale).rounded())))
        let outHeight = max(1, min(map.height, Int((Double(map.height) * scale).rounded())))
        var values = [UInt8](repeating: 0, count: outWidth * outHeight)
        let threshold = min(1, max(0, parameters.threshold))
        for outY in 0..<outHeight {
            let y0 = outY * map.height / outHeight
            let y1 = max(y0 + 1, (outY + 1) * map.height / outHeight)
            for outX in 0..<outWidth {
                let x0 = outX * map.width / outWidth
                let x1 = max(x0 + 1, (outX + 1) * map.width / outWidth)
                var peak = 0.0
                for y in y0..<min(y1, map.height) {
                    let rowBase = y * map.width
                    for x in x0..<min(x1, map.width) {
                        let value = map.values[rowBase + x]
                        if value > peak { peak = value }
                    }
                }
                values[outY * outWidth + outX] = peak >= threshold ? 1 : 0
            }
        }
        return FocusMask(
            width: outWidth,
            height: outHeight,
            values: values,
            threshold: threshold
        )
    }

    // MARK: - 像素工具

    /// 长边降采样到 maxDimension（最近邻；不放大）。
    public static func downsample(_ pixels: PreviewPixels, maxDimension: Int) -> PreviewPixels {
        guard pixels.isWellFormed, maxDimension > 0 else { return pixels }
        let longest = max(pixels.width, pixels.height)
        guard longest > maxDimension else { return pixels }
        let scale = Double(maxDimension) / Double(longest)
        let outWidth = max(1, Int((Double(pixels.width) * scale).rounded()))
        let outHeight = max(1, Int((Double(pixels.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            let srcY = min(pixels.height - 1, y * pixels.height / outHeight)
            for x in 0..<outWidth {
                let srcX = min(pixels.width - 1, x * pixels.width / outWidth)
                let src = (srcY * pixels.width + srcX) * 4
                let dst = (y * outWidth + x) * 4
                rgba[dst] = pixels.rgba[src]
                rgba[dst + 1] = pixels.rgba[src + 1]
                rgba[dst + 2] = pixels.rgba[src + 2]
                rgba[dst + 3] = pixels.rgba[src + 3]
            }
        }
        return PreviewPixels(width: outWidth, height: outHeight, rgba: rgba)
    }

    /// Rec.709 加权的 8bit 亮度。
    public static func luminanceByte(r: Int, g: Int, b: Int) -> Int {
        let value = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return max(0, min(255, Int(value.rounded())))
    }

    /// 8bit 值 → bin 下标（右端归入最后一格）。
    static func binIndex(_ value: Int, bins: Int) -> Int {
        let clamped = max(0, min(255, value))
        return min(bins - 1, clamped * bins / 256)
    }

    /// 积分图矩形和（inclusive 闭区间）。
    static func rectSum(
        _ integral: [Double],
        stride: Int,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) -> Double {
        let a = integral[y0 * stride + x0]
        let b = integral[y0 * stride + (x1 + 1)]
        let c = integral[(y1 + 1) * stride + x0]
        let d = integral[(y1 + 1) * stride + (x1 + 1)]
        return d - b - c + a
    }

    /// 分位归一化分母（1024 桶直方图，O(n)）。
    static func normalizationLevel(for values: [Double], maxValue: Double) -> Double {
        guard maxValue > 0, !values.isEmpty else { return 0 }
        var buckets = [Int](repeating: 0, count: normalizationBuckets)
        let scale = Double(normalizationBuckets - 1) / maxValue
        for value in values {
            let index = max(0, min(normalizationBuckets - 1, Int(value * scale)))
            buckets[index] += 1
        }
        let threshold = Int(Double(values.count) * focusNormalizationPercentile)
        var cumulative = 0
        for (index, count) in buckets.enumerated() {
            cumulative += count
            if cumulative >= threshold {
                return Double(index) * maxValue / Double(normalizationBuckets - 1)
            }
        }
        return maxValue
    }
}

// MARK: - AF 点几何

/// AF 网格形状（只描述"格数"，不含 MakerNote 偏移）。
public struct AFGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// true = 相机上报的索引按镜像排列（部分 Canon 机型）。
    public let mirrored: Bool

    public init(columns: Int, rows: Int, mirrored: Bool = false) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.mirrored = mirrored
    }

    public var pointCount: Int { columns * rows }
}

/// 已登记机型表（**空表出厂**：没有真实机型样本前不猜网格形状）。
///
/// 为什么空：AF 点来自 MakerNote，网格形状与偏移随机型/固件变化。设计 §3.9.3
/// 明确"不做全机型 MakerNote 逆向，登记表可增量加"。没有 fixture 的机型宁可
/// 走"人脸中心"回退并标注启发式，也不假装有 AF 数据。
public enum AFPointProfiles {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: AFGrid] = [:]

    /// 登记机型（宿主/测试在拿到真实样本后调用；重复登记覆盖）。
    public static func install(_ grid: AFGrid, for cameraModel: String) {
        let key = normalizedKey(cameraModel)
        guard !key.isEmpty else { return }
        lock.lock()
        table[key] = grid
        lock.unlock()
    }

    public static func grid(for cameraModel: String) -> AFGrid? {
        let key = normalizedKey(cameraModel)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return table[key]
    }

    /// 清空登记表（测试隔离用）。
    public static func removeAll() {
        lock.lock()
        table.removeAll()
        lock.unlock()
    }

    /// 机型键归一：小写、去多余空白（"Canon EOS R5" == "canon  eos r5"）。
    static func normalizedKey(_ cameraModel: String) -> String {
        let parts = cameraModel.lowercased().split(separator: " ").map(String.init)
        return parts.joined(separator: " ")
    }
}

/// AF 点提取：ExifAux / 机型表优先，无数据回退主体人脸框中心。
public enum AFPointExtractor {
    /// - Parameters:
    ///   - faceBoxes：归一化人脸框 [x, y, w, h]（按面积从大到小优先；取第一个合法者）。
    ///   - cameraModel：机型串（空 = 未知，直接走人脸回退）。
    ///   - afIndex：相机上报的 AF 点索引（nil = 没有 AF 数据）。
    public static func resolve(
        faceBoxes: [[Double]],
        cameraModel: String,
        afIndex: Int?
    ) -> AFPoint? {
        if let afIndex, let grid = AFPointProfiles.grid(for: cameraModel),
           let point = gridPoint(index: afIndex, grid: grid) {
            return AFPoint(x: point.x, y: point.y, source: .camera, label: cameraModel)
        }
        if let center = faceCenter(faceBoxes: faceBoxes) {
            return AFPoint(x: center.x, y: center.y, source: .face, label: "")
        }
        return nil
    }

    /// 网格索引 → 归一化点（格中心）。索引越界/网格非法 → nil。
    public static func gridPoint(index: Int, grid: AFGrid) -> (x: Double, y: Double)? {
        guard index >= 0, index < grid.pointCount, grid.columns > 0, grid.rows > 0 else {
            return nil
        }
        let column = index % grid.columns
        let row = index / grid.columns
        let x = (Double(column) + 0.5) / Double(grid.columns)
        let y = (Double(row) + 0.5) / Double(grid.rows)
        return (grid.mirrored ? 1 - x : x, y)
    }

    /// 首个合法人脸框的中心（归一化后夹取到 0...1）。
    public static func faceCenter(faceBoxes: [[Double]]) -> (x: Double, y: Double)? {
        for box in faceBoxes {
            guard box.count >= 4, box[2] > 0, box[3] > 0 else { continue }
            let x = box[0] + box[2] / 2
            let y = box[1] + box[3] / 2
            guard x.isFinite, y.isFinite else { continue }
            return (min(1, max(0, x)), min(1, max(0, y)))
        }
        return nil
    }
}


// MARK: - 端口适配（宿主注册用；UI 只认 PreviewAnalysisPort）

/// 纯函数 → PreviewAnalysisPort 的唯一适配器。
/// 放在分析层而不是 Host：Host 注册它即可，不复制任何像素算法。
public struct PreviewAnalysisAdapter: PreviewAnalysisPort {
    public init() {}

    public func histogram(_ pixels: PreviewPixels, bins: Int) -> PreviewHistogram {
        PreviewAnalysis.histogram(pixels, bins: bins)
    }

    public func focusMask(
        _ pixels: PreviewPixels,
        parameters: FocusMaskParameters
    ) -> FocusMask {
        PreviewAnalysis.focusMask(
            PreviewAnalysis.focusMap(pixels), parameters: parameters)
    }

    public func afPoint(
        faceBoxes: [[Double]],
        cameraModel: String,
        afIndex: Int?
    ) -> AFPoint? {
        AFPointExtractor.resolve(
            faceBoxes: faceBoxes, cameraModel: cameraModel, afIndex: afIndex)
    }
}


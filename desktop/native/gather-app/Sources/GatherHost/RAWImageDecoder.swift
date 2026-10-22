// desktop/native/gather-app/Sources/GatherHost/RAWImageDecoder.swift
// Cut 3 / 3b-3（E-04 的宿主编排侧）：RAWDecoder → ImageDecoderPort 适配器。
//
// RAWDecoder 仍在 GatherAnalysis（core 包本步不可写）；这里只做结果类型
// 的字段映射，不含解码逻辑。AppBootstrap 启动时注册到 ImageDecodingRegistry。
import Foundation
import CoreGraphics
import GatherAnalysis
import GatherUI

public struct RAWImageDecoder: ImageDecoderPort {
    public init() {}

    public func getPreview(path: String, maxDimension: Int) throws -> ImageDecodeResult {
        let result = try RAWDecoder.getPreview(path: path, maxDimension: maxDimension)
        return ImageDecodeResult(
            buffer: result.buffer,
            format: result.format,
            width: result.width,
            height: result.height
        )
    }

    public func getThumbnail(path: String, size: Int) throws -> ImageDecodeResult {
        let result = try RAWDecoder.getThumbnail(path: path, size: size)
        return ImageDecodeResult(
            buffer: result.buffer,
            format: result.format,
            width: result.width,
            height: result.height
        )
    }

    public func decodeRegion(
        path: String,
        normalizedRect: CGRect,
        maxPixel: Int
    ) throws -> ImageRegionDecodeResult {
        let result = try RAWDecoder.decodeRegion(
            path: path,
            normalizedRect: normalizedRect,
            maxPixel: maxPixel
        )
        return ImageRegionDecodeResult(
            buffer: result.buffer,
            regionWidth: result.regionWidth,
            regionHeight: result.regionHeight,
            fullWidth: result.fullWidth,
            fullHeight: result.fullHeight
        )
    }
}

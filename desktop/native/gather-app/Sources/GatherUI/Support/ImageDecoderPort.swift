// desktop/native/gather-app/Sources/GatherUI/Support/ImageDecoderPort.swift
// Cut 3 / 3b-3（E-04 的 UI 侧接缝）：页面缩略图/细节解码的能力端口。
//
// 为什么需要端口：具体图像解码器属于 GatherAnalysis，而 GatherUI 不得
// import 分析层。UI 只声明「按路径解码出 JPEG buffer」这一能力；真正实现
// 留在 GatherHost（RAWImageDecoder），启动时经 ImageDecodingRegistry 注册一次。
//
// 端口归属（3b-4 收口）：保持 UI-owned。D-014 的硬约束是 UI 不得直接依赖
// GatherAnalysis，本端口已满足（GatherUI 只 import GatherProtocol + 系统库）；
// 端口是页面消费侧的契约，上移 GatherProtocol 会扩大 core 公共面，并把
// app 专属的同步/解码适配器语义带进 Protocol，收益不足且需改 core 包结构，
// 不属于本 Cut。故不搬；将来若确需跨包复用，再单独立项评估。
import Foundation
import CoreGraphics

/// 整图/缩略图解码结果（只保留 UI 消费的字段）。
public struct ImageDecodeResult: Equatable, Sendable {
    /// 已应用 EXIF/RAW 方向的 JPEG。
    public let buffer: Data
    public let format: String
    public let width: Int
    public let height: Int

    public init(buffer: Data, format: String, width: Int, height: Int) {
        self.buffer = buffer
        self.format = format
        self.width = width
        self.height = height
    }
}

/// 区域解码结果（PhotoDetailTileView 只用 buffer + 整图宽高）。
public struct ImageRegionDecodeResult: Equatable, Sendable {
    public let buffer: Data
    public let regionWidth: Int
    public let regionHeight: Int
    public let fullWidth: Int
    public let fullHeight: Int

    public init(buffer: Data, regionWidth: Int, regionHeight: Int, fullWidth: Int, fullHeight: Int) {
        self.buffer = buffer
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
    }
}

/// 解码不可用（宿主未注册实现）：UI 侧退回占位符，不 crash。
public enum ImageDecodingError: Error, Equatable, Sendable {
    case decoderUnavailable
}

/// 页面唯一可见的解码能力面。实现必须无状态/可并发（image decoder port 契约）。
public protocol ImageDecoderPort: Sendable {
    func getPreview(path: String, maxDimension: Int) throws -> ImageDecodeResult
    func getThumbnail(path: String, size: Int) throws -> ImageDecodeResult
    func decodeRegion(
        path: String,
        normalizedRect: CGRect,
        maxPixel: Int
    ) throws -> ImageRegionDecodeResult
}

/// 进程级解码器注册表：GatherHost 启动时注册一次，视图层只读。
///
/// 静态可变状态用 NSLock 串行化并标 nonisolated(unsafe)（与缩略图缓存同纪律）。
public enum ImageDecodingRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var decoder: (any ImageDecoderPort)?

    /// 注册实现（重复注册按后者生效：bootstrap 重试时替换）。
    public static func install(_ decoder: any ImageDecoderPort) {
        lock.lock()
        self.decoder = decoder
        lock.unlock()
    }

    /// 当前实现；未注册时抛 decoderUnavailable。
    public static func current() throws -> any ImageDecoderPort {
        lock.lock()
        let decoder = self.decoder
        lock.unlock()
        guard let decoder else { throw ImageDecodingError.decoderUnavailable }
        return decoder
    }
}

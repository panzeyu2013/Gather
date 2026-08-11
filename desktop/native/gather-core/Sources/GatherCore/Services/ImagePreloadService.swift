// desktop/native/gather-core/Sources/GatherCore/Services/ImagePreloadService.swift
// Phase 3.6：缩略图/预览预加载编排。
//
// image.* 命令不把二进制数据穿过 IPC；服务只负责受控解码和任务进度，
// 实际图片请求仍由 gather-image:// scheme handler 直出。这样滚动图库时
// 可以提前触发 ImageIO 缓存，同时保留 JobService 的取消、恢复与进度语义。

import Foundation

public enum ImagePreloadError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidPath
    case unsupported

    public var description: String {
        switch self {
        case .invalidPath: return "IMAGE_PATH_INVALID"
        case .unsupported: return "IMAGE_PRELOAD_UNSUPPORTED"
        }
    }

    public var errorDescription: String? { description }
}

public final class ImagePreloadService {
    public init() {}

    /// 为一批路径建立缩略图解码任务。返回成功解码数量；单张失败不阻断
    /// 其余路径，取消则以 JobCancelledError 终止任务。
    @discardableResult
    public func buildThumbnails(
        paths: [String],
        size: Int,
        signal: JobAbortSignal? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        let safeSize = max(size, 1)
        let total = paths.count
        var succeeded = 0
        for (index, path) in paths.enumerated() {
            if signal?.aborted == true { throw JobCancelledError() }
            if FileManager.default.fileExists(atPath: path) {
#if canImport(ImageIO)
                if RAWDecoder.supports(".\((path as NSString).pathExtension.lowercased())"),
                   (try? RAWDecoder.getThumbnail(path: path, size: safeSize)) != nil {
                    succeeded += 1
                }
#else
                throw ImagePreloadError.unsupported
#endif
            }
            onProgress?(index + 1, total)
        }
        return succeeded
    }

    /// 高优先级单图请求，用于 viewport 首屏或鼠标悬停。
    public func prioritizeThumbnail(path: String, size: Int) throws {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ImagePreloadError.invalidPath
        }
#if canImport(ImageIO)
        _ = try RAWDecoder.getThumbnail(path: path, size: max(size, 1))
#else
        throw ImagePreloadError.unsupported
#endif
    }

    /// 预览只取前四张，避免一次滚动事件解码整页大图；任务由调用方持有。
    public func preloadPreviews(paths: [String], maxDimension: Int) {
        let selected = Array(paths.prefix(4))
        guard !selected.isEmpty else { return }
        let size = max(maxDimension, 1)
        Task.detached(priority: .utility) {
            for path in selected {
                guard FileManager.default.fileExists(atPath: path) else { continue }
#if canImport(ImageIO)
                _ = try? RAWDecoder.getPreview(path: path, maxDimension: size)
#endif
            }
        }
    }
}

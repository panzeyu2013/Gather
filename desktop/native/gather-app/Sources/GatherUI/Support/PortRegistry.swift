// desktop/native/gather-app/Sources/GatherUI/Support/PortRegistry.swift
// M12（Wave5 / task-9）：三个进程级端口注册表（ImageDecoding / PreviewAnalysis /
// PrintRendering）收口为单一注册表。
//
// 原来每个 registry 各持一把 NSLock + 一个 nonisolated(unsafe) 静态 var，由
// AppBootstrap.makeScene 分三次 install。本文件把它们收口为：
//   · 单一安装入口 PortRegistry.install(imageDecoder:previewAnalysis:printRendering:)
//     —— 装配方一次装齐，nil 字段保持既有注册不变（重复注册按后者生效）；
//   · 三个既有 registry 保留原 public API（install / current），内部委托本表，
//     调用点（PhotoThumbnailView / ViewerOverlays / PrintOptionsSheet）零改动。
//
// 可见性用 package（不是 public）：装配方 GatherHost 与本 target 同包，internal
// 跨不了 target，而 public 会抬高 check-public-surface-app 的 public 面基线。
// 状态用 OSAllocatedUnfairLock（SDK 自带 Sendable）承载，不新增并发标注白名单。
import Foundation
import os
import GatherProtocol

/// 进程级端口注册表（单一实例；本包内可见）。
package enum PortRegistry {
    /// 一次安装的端口集合；nil = 该端口保持既有注册不变。
    private struct Ports: Sendable {
        var imageDecoder: (any ImageDecoderPort)?
        var previewAnalysis: (any PreviewAnalysisPort)?
        var printRendering: (any PrintRenderingPort)?

        init(
            imageDecoder: (any ImageDecoderPort)? = nil,
            previewAnalysis: (any PreviewAnalysisPort)? = nil,
            printRendering: (any PrintRenderingPort)? = nil
        ) {
            self.imageDecoder = imageDecoder
            self.previewAnalysis = previewAnalysis
            self.printRendering = printRendering
        }
    }

    private static let state = OSAllocatedUnfairLock<Ports>(initialState: Ports())

    /// 单一安装入口：bootstrap 的装配阶段一次装齐；nil 字段保持既有注册不变。
    package static func install(
        imageDecoder: (any ImageDecoderPort)? = nil,
        previewAnalysis: (any PreviewAnalysisPort)? = nil,
        printRendering: (any PrintRenderingPort)? = nil
    ) {
        state.withLock { ports in
            if let imageDecoder { ports.imageDecoder = imageDecoder }
            if let previewAnalysis { ports.previewAnalysis = previewAnalysis }
            if let printRendering { ports.printRendering = printRendering }
        }
    }

    /// 当前解码实现；未注册返回 nil（由 ImageDecodingRegistry 映射成 decoderUnavailable）。
    package static func imageDecoder() -> (any ImageDecoderPort)? {
        state.withLock { $0.imageDecoder }
    }

    /// 当前预览分析实现；未注册返回 nil（叠加层显示"分析不可用"）。
    package static func previewAnalysis() -> (any PreviewAnalysisPort)? {
        state.withLock { $0.previewAnalysis }
    }

    /// 当前打印渲染实现；未注册返回 nil（面板提示渲染器不可用）。
    package static func printRendering() -> (any PrintRenderingPort)? {
        state.withLock { $0.printRendering }
    }
}

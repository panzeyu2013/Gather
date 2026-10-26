// desktop/native/gather-app/Tests/GatherAppTests/CullingGridPerfTests.swift
// P0 / G0：网格首屏布局性能门（默认跳过；GATHER_UI_PERF=1 运行）。
// 只测 200 张/页的 SwiftUI 布局，不替代真机滚动/缩略图解码。
import AppKit
import Foundation
import SwiftUI
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

private let cullingUIPerfEnabled =
    ProcessInfo.processInfo.environment["GATHER_UI_PERF"] == "1"

@MainActor
@Suite("G0 网格 UI 首屏性能")
struct CullingGridPerfTests {
    // skip-owner: p0-perf
    // 到期：2027-06-30
    // 原因：UI 首屏布局是发布前性能门，默认套件跳过，避免无窗口环境干扰。
    // 手动条件：GATHER_UI_PERF=1 swift test --filter CullingGridPerf
    @Test(.enabled(if: cullingUIPerfEnabled))
    func gridFirstPaint200Of20k() throws {
        let culling = B8CullingAPIStub()
        let vm = CullingViewModel(
            sessionId: "s1",
            culling: culling,
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
        let assets = (0..<200).map { b8CullingAsset(String(format: "p%03d", $0)) }
        vm.page = CullingPage(assets: assets, total: 20_000)
        vm.loadedPhotoIds = Set(assets.map { $0.photo.id })
        let view = CullingGridView(viewModel: vm, density: .m, onOpenSingle: {})

        var durations: [Double] = []
        for _ in 0..<5 {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 1_600, height: 1_000)
            renderer.scale = 1
            let started = DispatchTime.now().uptimeNanoseconds
            _ = renderer.nsImage
            durations.append(
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let sorted = durations.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        print("PERF culling-grid-200x20k p95=\(String(format: "%.1f", p95))ms")
        #expect(p95 < 800, "网格首屏布局 p95 超过 800ms：\(p95)ms")
    }

    // skip-owner: p0-perf
    // 到期：2027-06-30
    // 原因：真实 NSWindow 首帧包含 AppKit 绘制，默认套件跳过。
    // 手动条件：GATHER_UI_PERF=1 swift test --filter CullingGridPerf
    @Test(.enabled(if: cullingUIPerfEnabled))
    func gridWindowFirstFrame() throws {
        _ = NSApplication.shared
        let culling = B8CullingAPIStub()
        let vm = CullingViewModel(
            sessionId: "s1", culling: culling, navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(), jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(), captureOne: CaptureOneBridge())
        let assets = (0..<200).map { b8CullingAsset(String(format: "p%03d", $0)) }
        vm.page = CullingPage(assets: assets, total: 20_000)
        vm.loadedPhotoIds = Set(assets.map { $0.photo.id })
        let view = CullingGridView(viewModel: vm, density: .m, onOpenSingle: {})
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 1_000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        var durations: [Double] = []
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            durations.append(
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let sorted = durations.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        print("PERF culling-grid-window-200x20k p95=\(String(format: "%.1f", p95))ms")
        #expect(p95 < 800, "真实窗口首帧 p95 超过 800ms：\(p95)ms")
    }
}

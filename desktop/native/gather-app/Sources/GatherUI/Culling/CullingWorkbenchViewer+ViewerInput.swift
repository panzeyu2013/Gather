// desktop/native/gather-app/Sources/GatherUI/Culling/CullingWorkbenchViewer+ViewerInput.swift
// M13（Wave5 / task-9）：CullingWorkbenchViewer 的扩展——键盘分发 / 滚轮缩放 / 窗口桥。
//
// 纯搬移：成员实现逐行未改；仅去掉 private 以便跨文件（同 target）访问，逐条见报告。
import SwiftUI
import GatherProtocol

extension CullingWorkbenchViewer {
    /// 裸键分发（空格 / P / X / U / 0–5 / H / F / R / C / 方向键；原 body 内联区域，M6 纯拆分）。
    func handleViewerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.option) else { return .ignored }
            viewModel.retreatCurrent()
            return .handled
        case .rightArrow:
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.option) else { return .ignored }
            viewModel.advanceCurrent()
            return .handled
        default:
            break
        }
        // ⌘⌥0 = 实际像素（⌘0 已修正为「适配窗口」；⌘1 另绑在可见按钮上）。
        // ⌘⌥ 组合不会被系统快捷键占用，因此能在 onKeyPress 里收口。
        if press.characters == "0",
           press.modifiers.contains(.command),
           press.modifiers.contains(.option) {
            zoomToActualPixels()
            return .handled
        }
        // 裸键决策：带 ⌘/⌥ 的组合交给系统（⌘X 不能变成“淘汰”）。
        guard !press.modifiers.contains(.command),
              !press.modifiers.contains(.option) else { return .ignored }
        // Wave2（20-culling-browse #8）：叠加层/查看模式键位 H/F/R/C。
        // 裸 F = 合焦掩膜（评审设计意图），⇧F = 专注模式（Wave1 的 F 让位，
        // 「显示」菜单/查看器按钮的 help 同步标注 ⇧F）。
        if let action = CullingViewerShortcutKey.action(
            characters: press.characters,
            shift: press.modifiers.contains(.shift)
        ) {
            switch action {
            case .toggleHistogram:
                toggleHistogram()
            case .toggleFocusMask:
                toggleFocusMask()
            case .toggleFocusMode:
                onToggleFocusMode()
            case .toggleReference:
                toggleReference()
            case .cycleReferenceMode:
                // C 只在已设参考时有意义（未设参考时对比模式组本来就不显示）。
                guard overlayState.hasReference else { return .ignored }
                overlayState.cycleReferenceMode()
            }
            return .handled
        }
        // B1：键盘决策统一走 commitDecision——对比/Survey 默认只写当前照片
        // （旧实现直接走 commit = 选择集优先，盯着 A 按 X 会标掉 B…I）。
        switch press.characters.lowercased() {
        case " ":
            commitDecision(CullingUpdatePatch(pickState: .picked))
            return .handled
        case "p":
            commitDecision(CullingUpdatePatch(pickState: .picked))
            return .handled
        case "x":
            commitDecision(CullingUpdatePatch(pickState: .rejected))
            return .handled
        case "u":
            // P2-3：U 统一不前进（与检查器/网格一致），避免跳走当前照片。
            commitDecision(CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false)
            return .handled
        case "0", "1", "2", "3", "4", "5":
            guard let value = Int(press.characters) else { return .ignored }
            commitDecision(CullingUpdatePatch(rating: Double(value)))
            return .handled
        case "6", "7", "8", "9":
            // 对齐 Lightroom：6–9 = 红 / 黄 / 绿 / 蓝色标（橙/粉/紫只留在检查器菜单）。
            // 色标是"就地标注"，不触发自动前进（与星级刻意不同）。
            let label: CaptureOneColorLabel
            switch press.characters {
            case "6": label = .red
            case "7": label = .yellow
            case "8": label = .green
            default: label = .blue
            }
            commitDecision(CullingUpdatePatch(colorLabel: label), shouldAdvance: false)
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: 滚轮缩放（对齐旧版 onWheel：向上 1.15、向下 0.87，范围 1..8）

    func startWheelMonitor() {
        stopWheelMonitor()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            self.handleWheel(event)
            return event
        }
    }

    func stopWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    func handleWheel(_ event: NSEvent) {
        // 仅响应查看器窗口内、指针位于查看器区域上的滚动事件。
        // 命中区域直接取代理视图的 bounds（AppKit 维护），不再读写
        // GeometryReader 的坐标（见 viewerProxy 注）。
        guard let window = viewerWindow, event.window === window,
              let proxy = viewerProxy, proxy.window === window else { return }
        let point = proxy.convert(event.locationInWindow, from: nil)
        guard proxy.bounds.contains(point) else { return }
        let next = CullingViewerZoom.clamp(
            scale * (event.scrollingDeltaY < 0 ? 1.15 : 0.87),
            maximum: zoomMaximum)
        guard next != scale else { return }
        actualPixelsMode = false
        scale = next
        gestureScale = next
    }

    /// 点击 AF 框：以该点为中心、100% 查看（复用 FaceAlign 的坐标模型）。
    func focus(on point: AFPoint, cellSize: CGSize) {
        guard let asset = currentAsset, cellSize.width > 0, cellSize.height > 0 else { return }
        actualPixelsMode = false
        scale = 1
        gestureScale = 1
        offset = FaceAlign.offset(
            imageSize: CGSize(
                width: Double(asset.photo.width),
                height: Double(asset.photo.height)
            ),
            cellSize: cellSize,
            face: [point.x, point.y, 0, 0],
            zoom: 1
        )
        dragStartOffset = offset
        scheduleDetailTileUpdateForVisibleCells()
    }

}

/// 获取承载视图的 NSWindow（滚轮事件监听的窗口归属判断用）。
struct WindowBridge: NSViewRepresentable {
    /// (window, proxyView)：proxyView 即本 representable 的宿主视图，
    /// 其 bounds 就是查看器区域（滚轮命中的坐标系来源）。
    let onResolve: (NSWindow?, NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window, view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window, nsView) }
    }
}

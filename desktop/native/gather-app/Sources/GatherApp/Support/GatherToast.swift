// desktop/native/gather-app/Sources/GatherApp/Support/GatherToast.swift
// 全局 Toast 通知系统，对齐 Electron 版 ToastStore/Toast/ToastContainer：
// 4 类型（info/success/warning/error）、5s 自动消失、右上角堆叠、× 手动关闭。

import AppKit
import Foundation
import SwiftUI

public enum ToastType: Sendable {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .info: GatherTheme.info
        case .success: GatherTheme.success
        case .warning: GatherTheme.warning
        case .error: GatherTheme.error
        }
    }

    var iconName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

public struct ToastItem: Identifiable {
    public let id: UUID
    public let type: ToastType
    public let message: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        id: UUID = UUID(),
        type: ToastType,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.id = id
        self.type = type
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

@MainActor
@Observable
public final class GatherToastCenter {
    public static let shared = GatherToastCenter()

    public private(set) var toasts: [ToastItem] = []

    /// 自动消失时长。生产固定 5s；测试通过 `init(autoDismissDelay:)` 注入更短值，
    /// 以免"等满 5 秒"成为整个 app 测试套件的墙钟下界。
    let autoDismissDelay: Duration

    private init() {
        autoDismissDelay = .seconds(5)
    }

    init(autoDismissDelay: Duration) {
        self.autoDismissDelay = autoDismissDelay
    }

    public func show(type: ToastType, message: String) {
        show(type: type, message: message, actionTitle: nil, action: nil)
    }

    public func show(type: ToastType, message: String, actionTitle: String?, action: (() -> Void)?) {
        let item = ToastItem(type: type, message: message, actionTitle: actionTitle, action: action)
        toasts.insert(item, at: 0)
        let element = NSAccessibilityElement()
        element.setAccessibilityLabel(message)
        NSAccessibility.post(element: element, notification: .announcementRequested)
        let delay = autoDismissDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: item.id)
        }
    }

    public func dismiss(id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}

public struct ToastView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        let center = GatherToastCenter.shared
        if center.toasts.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(center.toasts) { toast in
                    ToastRow(toast: toast) {
                        center.dismiss(id: toast.id)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    // 对齐旧版 Toast.module.css slideIn 0.2s ease-out：
                    // 出现时 -8pt 上滑 + 淡入，消失时 -8pt 下滑 + 淡出。
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -8)),
                            removal: .opacity.combined(with: .offset(y: 8))
                        ))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: center.toasts.map(\.id))
            .padding(16)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ToastRow: View {
    let toast: ToastItem
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.type.iconName)
                .foregroundStyle(toast.type.color)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: 360, alignment: .leading)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .allowsHitTesting(true)
            }
            Button(action: onDismiss) {
                Label(GatherLocalization.l("关闭"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .allowsHitTesting(true)
            .help(GatherLocalization.l("关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 功能层浮面：macOS 26+ 用 Liquid Glass，更早版本用 .regularMaterial。
        // toast 是典型的「浮在内容之上的瞬时控件」，正是 Apple 允许用玻璃的场景；
        // 卡片等**内容层**表面则一律保持标准材质（见 GatherGlass 的说明）。
        .gatherFunctionalSurface(cornerRadius: GatherTheme.Radius.group, bordered: false)
        .shadow(color: GatherTheme.shadowMd, radius: 12, y: 4)
    }
}

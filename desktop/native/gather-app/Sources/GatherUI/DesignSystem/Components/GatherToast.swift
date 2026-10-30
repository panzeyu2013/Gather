// desktop/native/gather-app/Sources/GatherUI/Support/GatherToast.swift
// 全局 Toast 通知系统，对齐 Electron 版 ToastStore/Toast/ToastContainer：
// 4 类型（info/success/warning/error）、5s 自动消失（error 15s）、右上角堆叠（≤3 条）、× 手动关闭。

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

    /// 分类自动消失时长。错误类可能承载唯一出口（如导入失败的「重试」），
    /// 5s 内键盘/VoiceOver 用户来不及反应；给 15s。其余类型用注入值（生产 5s）。
    func autoDismissDelay(for type: ToastType) -> Duration {
        type == .error ? max(autoDismissDelay, .seconds(15)) : autoDismissDelay
    }

    public func show(type: ToastType, message: String) {
        show(type: type, message: message, actionTitle: nil, action: nil)
    }

    public func show(type: ToastType, message: String, actionTitle: String?, action: (() -> Void)?) {
        let item = ToastItem(type: type, message: message, actionTitle: actionTitle, action: action)
        toasts.insert(item, at: 0)
        // 上限 3 条：突发错误曾把右上角叠满并挡住工具栏点击。超出丢最旧一条。
        if toasts.count > 3 { toasts.removeLast(toasts.count - 3) }
        // AppKit 的公告必须带 userInfo（文案 + 优先级）并发给 application element；
        // 只 setAccessibilityLabel 再 post 一个空元素，VoiceOver 不会朗读。
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        let delay = autoDismissDelay(for: type)
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
                    .contentShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.floating))
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
            // 命中测试：容器**不能**关闭（祖先 false 会把子按钮一起关掉，子节点
            // 再写 allowsHitTesting(true) 也救不回来）。改为让纯展示的图标/文字
            // 不参与命中，按钮各自接收点击。
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ToastRow: View {
    let toast: ToastItem
    let onDismiss: () -> Void

    /// Cut 4 / 4b-2l：关闭按钮文案在渲染期解析（Toast 中心只存已渲染的 message）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.type.iconName)
                .foregroundStyle(toast.type.color)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Text(toast.message)
                .font(GatherFont.body)
                .lineLimit(3)
                .frame(maxWidth: 360, alignment: .leading)
                .allowsHitTesting(false)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(action: onDismiss) {
                Label(l10n("关闭"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(l10n("关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 功能层浮面：用 Liquid Glass。toast 是典型的「浮在内容之上的瞬时控件」，
        // 正是 Apple 允许用玻璃的场景；卡片等**内容层**表面则一律保持标准材质
        // （见 GatherGlass 的说明）。
        .gatherFunctionalSurface(cornerRadius: GatherTheme.Radius.floating)
        .shadow(color: GatherTheme.shadowFloating, radius: 16, y: 6)
    }
}

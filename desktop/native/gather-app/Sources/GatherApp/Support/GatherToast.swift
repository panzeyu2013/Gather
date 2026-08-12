// desktop/native/gather-app/Sources/GatherApp/Support/GatherToast.swift
// 全局 Toast 通知系统，对齐 Electron 版 ToastStore/Toast/ToastContainer：
// 4 类型（info/success/warning/error）、5s 自动消失、右上角堆叠、× 手动关闭。

import Foundation
import SwiftUI

public enum ToastType: Sendable {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .info: .accentColor
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

    public init(id: UUID = UUID(), type: ToastType, message: String) {
        self.id = id
        self.type = type
        self.message = message
    }
}

@MainActor
@Observable
public final class GatherToastCenter {
    public static let shared = GatherToastCenter()

    public private(set) var toasts: [ToastItem] = []

    private init() {}

    public func show(type: ToastType, message: String) {
        let item = ToastItem(type: type, message: message)
        toasts.append(item)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: item.id)
        }
    }

    public func dismiss(id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}

public struct ToastView: View {
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
                    // 对齐旧版 Toast.module.css slideIn 0.2s ease-out：
                    // 出现时 -8pt 上滑 + 淡入，消失时反向淡出。
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -8)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.easeOut(duration: 0.2), value: center.toasts.map(\.id))
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
                .font(.system(size: 13))
                .lineLimit(3)
                .frame(maxWidth: 300, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(true)
            .accessibilityLabel(GatherLocalization.l("关闭", "Dismiss"))
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(toast.type.color.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(toast.type.color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

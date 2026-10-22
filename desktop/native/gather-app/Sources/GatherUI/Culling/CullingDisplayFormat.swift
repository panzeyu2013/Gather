// desktop/native/gather-app/Sources/GatherUI/Culling/CullingDisplayFormat.swift
// Cut 4 / 4c-2a：挑片页共用的纯展示格式化（颜色标签 / 字段名 / 值 / 状态标题）。
// 从 CullingView.swift 原样移出；实例方法改成显式接收 L10n 的静态函数，输出不变。
import SwiftUI
import GatherProtocol

enum CullingDisplayFormat {
    /// 颜色标签色点（供胶片条/工具列/筛选卡共用）。
    /// C1 色标本身是数据（非状态色），保留固定色值；「无」用语义标签色。
    static func dot(_ label: CaptureOneColorLabel) -> Color {
        switch label {
        case .none: return Color(nsColor: .secondaryLabelColor)
        case .red: return Color(hex: 0xef5350)
        case .orange: return Color(hex: 0xff9800)
        case .yellow: return Color(hex: 0xfdd835)
        case .green: return Color(hex: 0x4caf50)
        case .blue: return Color(hex: 0x42a5f5)
        case .pink: return Color(hex: 0xec407a)
        case .purple: return Color(hex: 0xab47bc)
        }
    }

    /// 颜色标签中文文案（对齐 Library/LibraryView+Filters.swift 的 LibraryColorOption.label 表）。
    static func title(_ label: CaptureOneColorLabel, with l10n: L10n) -> String {
        switch label {
        case .none: return l10n("无")
        case .red: return l10n("红")
        case .orange: return l10n("橙")
        case .yellow: return l10n("黄")
        case .green: return l10n("绿")
        case .blue: return l10n("蓝")
        case .pink: return l10n("粉")
        case .purple: return l10n("紫")
        }
    }

    static func metadataFieldTitle(_ field: MetadataField, with l10n: L10n) -> String {
        switch field {
        case .rating: return l10n("星级")
        case .label: return l10n("颜色")
        case .keywords: return l10n("关键词")
        }
    }

    static func valueLabel(_ value: JSONValue, with l10n: L10n) -> String {
        switch value {
        case .null: return l10n("空")
        case .bool(let value): return value ? l10n("是") : l10n("否")
        case .number(let value): return String(value)
        case .string(let value): return value.isEmpty ? l10n("空") : value
        case .array(let values): return values.map { valueLabel($0, with: l10n) }.joined(separator: ", ")
        case .object: return l10n("对象")
        }
    }
}

/// 挑片状态文案（供主页面与胶片条共用；语言由调用方在渲染期传入）。
func pickStateTitle(_ state: PickState, with l10n: L10n) -> String {
    switch state {
    case .unreviewed: return l10n("未处理")
    case .picked: return l10n("保留")
    case .rejected: return l10n("淘汰")
    }
}

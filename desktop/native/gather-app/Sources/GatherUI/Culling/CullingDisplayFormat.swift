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

    /// T0：建议 verdict 的标题（网格 chip、检查器当前照片共用）。
    static func triageVerdictTitle(_ verdict: TriageVerdict, with l10n: L10n) -> String {
        switch verdict {
        case .keep: return l10n("建议保留")
        case .reject: return l10n("建议淘汰")
        case .review: return l10n("待复核")
        }
    }

    static func triageColor(_ verdict: TriageVerdict) -> Color {
        switch verdict {
        case .keep: return GatherTheme.success
        case .reject: return GatherTheme.error
        case .review: return .orange
        }
    }

    /// T0：理由码 → 用户文案。未知码原样透传，避免新增码在旧界面静默消失。
    static func triageReasonTitle(_ code: TriageReasonCode, with l10n: L10n) -> String {
        switch code {
        case .groupBest: return l10n("同组最佳")
        case .weakerThanGroupBest: return l10n("同组中有更清晰/更稳的一张")
        case .motionBlur: return l10n("疑似抖动模糊")
        case .exposureLow: return l10n("曝光可能不准")
        case .closedEyeSuspect: return l10n("疑似闭眼，请人工确认")
        case .closeCall: return l10n("差距不足以下结论")
        case .tieWithGroup: return l10n("与同组几乎一样")
        case .singleShot: return l10n("单张，无替代")
        case .noAlternative: return l10n("没有可比的替代片")
        case .lowTechnical: return l10n("技术质量偏低")
        case .qualityMissing: return l10n("尚未做技术质量分析")
        case .analysisFailed: return l10n("技术质量分析失败")
        case .duplicateExact: return l10n("完全重复文件")
        case .duplicateVisual: return l10n("视觉近似重复")
        case .multiFaceLowConfidence: return l10n("多人脸，建议人工判断")
        case .smallFace: return l10n("人脸过小，眼部信号不可靠")
        case .manualOverride: return l10n("已有人工决策")
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

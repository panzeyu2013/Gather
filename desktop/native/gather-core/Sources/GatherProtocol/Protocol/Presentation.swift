// desktop/native/gather-core/Sources/GatherProtocol/Protocol/Presentation.swift
// P1 下一波：交付展示（联系表 / 画廊 / 校样）共用的元数据模型。
//
// 一份模型、两处渲染：联系表 PDF 与 Web 画廊都只吃 DeliveryPresentationItem，
// 避免两边各长一套字段（字段名漂移会让「联系表有星、画廊没星」这类差异无法发现）。
// 数据由 OutputPresentationSource 一次 JOIN 取全批；缺行时回落默认值，绝不阻断导出。

import Foundation

/// 联系表/画廊单张的展示字段。全部来自 photo_metadata_cache + culling_decisions +
/// triage_suggestions；缺行时回落默认值，绝不阻断导出。
public struct DeliveryPresentationItem: Codable, Equatable, Sendable, Identifiable {
    public var photoId: String
    /// 成片（导出产物）的绝对路径；不是原片路径。
    public var filePath: String
    public var filename: String
    public var title: String?
    public var caption: String?
    public var rating: Int
    public var label: String
    public var pick: PickState
    public var keywords: [String]
    public var triageVerdict: TriageVerdict?
    public var captureTime: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var id: String { photoId }

    public init(
        photoId: String,
        filePath: String = "",
        filename: String,
        title: String? = nil,
        caption: String? = nil,
        rating: Int = 0,
        label: String = "",
        pick: PickState = .unreviewed,
        keywords: [String] = [],
        triageVerdict: TriageVerdict? = nil,
        captureTime: String? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) {
        self.photoId = photoId
        self.filePath = filePath
        self.filename = filename
        self.title = title
        self.caption = caption
        self.rating = max(0, min(5, rating))
        self.label = label
        self.pick = pick
        self.keywords = keywords
        self.triageVerdict = triageVerdict
        self.captureTime = captureTime
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
    }

    /// 星级可视串（固定 5 格，空位用 ☆）：只有渲染层需要"满格"观感，
    /// caption 里的 {rating} 仍用紧凑的纯实心星（见 CaptionFormatter）。
    public var ratingStars: String {
        let filled = max(0, min(5, rating))
        return String(repeating: "\u{2605}", count: filled)
            + String(repeating: "\u{2606}", count: 5 - filled)
    }

    /// 有效色标（None/空串统一折成 nil），供色点与文案共用。
    public var effectiveLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("None") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    /// 是否有任何可画/可展示的元数据（决定联系表 caption 区的高度）。
    public var hasMetadata: Bool {
        rating > 0 || effectiveLabel != nil || pick != .unreviewed
            || !keywords.isEmpty || title != nil || triageVerdict != nil
    }
}

/// 联系表可勾选的字段（rawValue 手写编解码，OptionSet 无法自动合成）。
public struct ContactSheetFields: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let filename = ContactSheetFields(rawValue: 1 << 0)
    public static let title = ContactSheetFields(rawValue: 1 << 1)
    public static let rating = ContactSheetFields(rawValue: 1 << 2)
    public static let label = ContactSheetFields(rawValue: 1 << 3)
    public static let pick = ContactSheetFields(rawValue: 1 << 4)
    public static let keywords = ContactSheetFields(rawValue: 1 << 5)
    public static let captureTime = ContactSheetFields(rawValue: 1 << 6)
    public static let triage = ContactSheetFields(rawValue: 1 << 7)

    public static let all: ContactSheetFields = [
        .filename, .title, .rating, .label, .pick, .keywords, .captureTime, .triage,
    ]

    /// 老配方/老测试的默认值：只画文件名（升级前的联系表逐字节一致）。
    public static let legacy: ContactSheetFields = [.filename]

    /// 需要绘制"星条/色点/取舍边框"这一行吗。
    public var needsBadgeRow: Bool {
        intersection([.rating, .label, .pick]).isEmpty == false
    }

    /// 需要绘制第二行文字（关键词）吗。
    public var needsKeywordRow: Bool { contains(.keywords) }
}

extension ContactSheetFields: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 纯函数：把展示字段渲染成一行 caption。未知占位符原样保留。
public enum CaptionFormatter {
    /// 默认模板 = 只文件名（与升级前一致：caption 就是成片文件名）。
    public static let defaultTemplate = "{filename}"

    public static func format(
        _ template: String,
        item: DeliveryPresentationItem,
        fields: ContactSheetFields = .all
    ) -> String {
        let has = { (field: ContactSheetFields) in fields.contains(field) }
        let replacements: [(String, String)] = [
            ("{filename}", has(.filename) ? item.filename : ""),
            ("{title}", has(.title) ? (item.title ?? "") : ""),
            ("{caption}", item.caption ?? ""),
            ("{rating}", has(.rating) && item.rating > 0
                ? String(repeating: "\u{2605}", count: item.rating) : ""),
            ("{label}", has(.label) ? (item.effectiveLabel ?? "") : ""),
            ("{pick}", has(.pick) ? pickText(item.pick) : ""),
            ("{keywords}", has(.keywords) ? item.keywords.joined(separator: ", ") : ""),
            ("{date}", has(.captureTime) ? (item.captureTime ?? "") : ""),
            ("{triage}", has(.triage) ? (item.triageVerdict?.rawValue ?? "") : ""),
        ]
        var output = template
        for (token, value) in replacements {
            output = output.replacingOccurrences(of: token, with: value)
        }
        // 模板里只有被 fields 关闭的占位符时不要留一串分隔符/空白。
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.filename : output
    }

    private static func pickText(_ pick: PickState) -> String {
        switch pick {
        case .picked: "PICK"
        case .rejected: "REJECT"
        case .unreviewed: ""
        }
    }
}

/// C1 色标 ↔ RGB/hex 的单一映射（联系表色点与画廊 CSS 共用，避免两处色号漂移）。
public enum ColorLabelPalette {
    /// 未知/None → nil（不画）。
    public static func rgb(for label: String) -> (red: Double, green: Double, blue: Double)? {
        switch label.lowercased() {
        case "red": return (0.85, 0.18, 0.18)
        case "orange": return (0.92, 0.53, 0.12)
        case "yellow": return (0.93, 0.78, 0.15)
        case "green": return (0.25, 0.65, 0.30)
        case "blue": return (0.18, 0.45, 0.85)
        case "pink": return (0.90, 0.35, 0.62)
        case "purple": return (0.55, 0.32, 0.82)
        default: return nil
        }
    }

    public static func hex(for label: String) -> String? {
        guard let rgb = rgb(for: label) else { return nil }
        let toByte = { (value: Double) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", toByte(rgb.red), toByte(rgb.green), toByte(rgb.blue))
    }
}

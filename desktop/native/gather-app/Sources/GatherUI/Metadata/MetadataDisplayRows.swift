// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataDisplayRows.swift
// P1 / IPTC：只读面板的行投影（纯函数，可直测；视图只做排版）。
//
// 为什么单独一层：面板要同时服务三处 inspector 与将来的导出预览，
// 格式化规则（焦距 mm / f 值 / 尺寸 / 文件大小 / GPS）必须只有一份实现。
import Foundation
import GatherProtocol

/// 面板一行：标签 + 显示值（空值由视图决定是隐藏还是显示占位）。
struct MetadataDisplayRow: Equatable {
    let label: String
    let value: String
    /// false = 字段未填写（面板显示占位符，而不是把它当成"没有这个字段"）。
    var isFilled: Bool = true
}

enum MetadataDisplay {
    /// IPTC Core 22 项（顺序与 XMPFieldDescriptor.all 一致）。
    static let iptcCoreFields: [DescriptiveField] = Array(DescriptiveField.allCases.prefix(22))
    /// IPTC Extension 10 项。
    static let iptcExtensionFields: [DescriptiveField] = Array(DescriptiveField.allCases.suffix(10))

    /// 十进制安全格式化（避免 50.00000000001 之类）。
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func fileSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[index])
    }

    /// 拍摄参数（顺序即面板展示顺序；nil 项由调用方过滤）。
    static func exifRows(_ exif: PhotoExifSnapshot, l10n: (String) -> String) -> [MetadataDisplayRow] {
        var rows: [MetadataDisplayRow] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(MetadataDisplayRow(label: l10n(label), value: value))
        }
        let camera = [exif.cameraMake, exif.cameraModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        add("机身", camera.isEmpty ? nil : camera)
        add("镜头", exif.lensModel)
        add("焦距", exif.focalLength.map { number($0) + " mm" })
        add("光圈", exif.fNumber.map { "f/" + number($0) })
        add("快门", exif.exposureTime)
        add("ISO", exif.iso.map(String.init))
        if let width = exif.width, let height = exif.height {
            add("尺寸", "\(width) × \(height)")
        }
        add("拍摄时间", exif.dateTaken)
        if let latitude = exif.gpsLatitude, let longitude = exif.gpsLongitude {
            let lat = String(format: "%.6f", latitude)
            let lon = String(format: "%.6f", longitude)
            add("位置", lat + ", " + lon)
        }
        add("文件大小", exif.fileSize.map(fileSize))
        add("文件修改时间", exif.fileMtime)
        return rows
    }

    /// 描述性元数据（只显示已填写字段；导出/摘要用）。
    static func iptcRows(_ descriptive: DescriptiveMetadata, l10n: (String) -> String) -> [MetadataDisplayRow] {
        fieldRows(DescriptiveField.allCases, descriptive, l10n: l10n)
            .filter(\.isFilled)
    }

    /// 全字段投影：未填写的字段也出行（isFilled = false），面板据此显示占位符。
    static func fieldRows(
        _ fields: [DescriptiveField],
        _ descriptive: DescriptiveMetadata,
        l10n: (String) -> String
    ) -> [MetadataDisplayRow] {
        fields.map { field in
            let text = valueText(descriptive.value(for: field))
            return MetadataDisplayRow(
                label: l10n(fieldTitle(field)),
                value: text,
                isFilled: !text.isEmpty
            )
        }
    }

    /// 联系方式是结构：把已填成员拼成一行。
    private static func valueText(_ value: XMPFieldValue?) -> String {
        switch value {
        case .text(let text): return text
        case .list(let values): return values.joined(separator: "、")
        case .contact(let contact): return contactSummary(contact)
        case .none: return ""
        }
    }

    static func contactSummary(_ contact: DescriptiveContact) -> String {
        var parts: [String] = []
        for key in DescriptiveContact.members.map(\.key) {
            let value: String? = switch key {
            case "city": contact.city
            case "country": contact.country
            case "address": contact.address
            case "postalCode": contact.postalCode
            case "region": contact.region
            case "email": contact.email
            case "telephone": contact.telephone
            case "url": contact.url
            default: nil
            }
            if let value, !value.isEmpty { parts.append(value) }
        }
        return parts.joined(separator: " · ")
    }

    /// 字段标题（中文是 l10n 的 key；en/zh 资源各有一份翻译）。
    static func fieldTitle(_ field: DescriptiveField) -> String {
        switch field {
        case .title: "标题"
        case .caption: "说明"
        case .creator: "作者"
        case .creatorJobTitle: "作者职位"
        case .credit: "署名"
        case .source: "来源"
        case .copyrightNotice: "版权"
        case .usageTerms: "使用条款"
        case .webStatement: "版权信息网址"
        case .headline: "标题（Headline）"
        case .captionWriter: "编辑者"
        case .jobIdentifier: "作业编号"
        case .subjectCode: "主题代码"
        case .scene: "场景代码"
        case .intellectualGenre: "类型"
        case .location: "地点"
        case .city: "城市"
        case .state: "省/州"
        case .country: "国家/地区"
        case .countryCode: "国家代码"
        case .dateCreated: "原始创建日期"
        case .contactInfo: "联系方式"
        case .personInImage: "画面人物"
        case .event: "事件"
        case .organisationInImage: "画面机构"
        case .sublocation: "次级地点"
        case .worldRegion: "世界区域"
        case .provinceState: "省/州（Ext）"
        case .modelReleaseStatus: "肖像权授权"
        case .propertyReleaseStatus: "物权授权"
        case .digitalSourceType: "数字来源类型"
        case .additionalModelInfo: "模特补充说明"
        }
    }
}

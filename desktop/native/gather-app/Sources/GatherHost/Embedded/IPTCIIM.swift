// desktop/native/gather-app/Sources/GatherHost/Embedded/IPTCIIM.swift
// IPTC-IIM（APP13 / Photoshop IRB 0x0404）的解析与编码。
//
// 为什么必须有它：XMP 与 IIM 是两个独立存储。只清 XMP 时旧 IIM 会经
// MetadataService.descriptiveFromParse 的回退链复活；「清空」必须把 dataset 删掉。
//
// 结构：
//   APP13 payload = "Photoshop 3.0\0" + IRB*
//   IRB = "8BIM" + u16 resourceID + Pascal 名（长度字节 + 字符 + 奇偶补齐）+ u32 size + data（奇偶补齐）
//   IIM = { 0x1C, record, dataset, u16 length, data }*
// 只改 0x0404；其它 IRB 资源逐字节保留。
import Foundation
import GatherProtocol

struct IIMKey: Hashable, Comparable, Sendable {
    let record: UInt8
    let dataset: UInt8

    static let codedCharacterSet = IIMKey(record: 1, dataset: 90)
    static let objectName = IIMKey(record: 2, dataset: 5)
    static let urgency = IIMKey(record: 2, dataset: 10)
    static let subjectReference = IIMKey(record: 2, dataset: 12)
    /// 2:04 ObjectAttributeReference（对应 XMP Iptc4xmpCore:IntellectualGenre）
    static let objectAttributeReference = IIMKey(record: 2, dataset: 4)
    /// 2:27 ContentLocationName（对应 XMP Iptc4xmpCore:Location）
    static let contentLocationName = IIMKey(record: 2, dataset: 27)
    static let keywords = IIMKey(record: 2, dataset: 25)
    static let dateCreated = IIMKey(record: 2, dataset: 55)
    static let byline = IIMKey(record: 2, dataset: 80)
    static let bylineTitle = IIMKey(record: 2, dataset: 85)
    static let city = IIMKey(record: 2, dataset: 90)
    static let sublocation = IIMKey(record: 2, dataset: 92)
    static let provinceState = IIMKey(record: 2, dataset: 95)
    static let countryCode = IIMKey(record: 2, dataset: 100)
    static let countryName = IIMKey(record: 2, dataset: 101)
    static let transmissionReference = IIMKey(record: 2, dataset: 103)
    static let headline = IIMKey(record: 2, dataset: 105)
    static let credit = IIMKey(record: 2, dataset: 110)
    static let source = IIMKey(record: 2, dataset: 115)
    static let copyrightNotice = IIMKey(record: 2, dataset: 116)
    static let caption = IIMKey(record: 2, dataset: 120)
    static let writerEditor = IIMKey(record: 2, dataset: 122)
    /// 2:202 Scene（IPTC Core「场景」；实测 ImageIO 读回键名为 Scene）
    static let scene = IIMKey(record: 2, dataset: 202)

    static func < (lhs: IIMKey, rhs: IIMKey) -> Bool {
        (lhs.record, lhs.dataset) < (rhs.record, rhs.dataset)
    }
}

struct IIMDataset: Equatable, Sendable {
    let key: IIMKey
    var value: Data
}

struct IPTCIIM: Equatable, Sendable {
    private(set) var datasets: [IIMDataset]

    init(datasets: [IIMDataset] = []) {
        self.datasets = datasets
    }

    var isEmpty: Bool { datasets.isEmpty }

    static func parse(_ data: Data) throws -> IPTCIIM {
        let bytes = [UInt8](data)
        var index = 0
        var result: [IIMDataset] = []
        while index < bytes.count {
            // 尾部 0 填充（部分写入器会补零对齐）。
            if bytes[index] == 0x00 {
                guard bytes[index...].allSatisfy({ $0 == 0x00 }) else {
                    throw EmbeddedJPEGError.layoutUnsupported("IIM 中间出现 0 填充 at \(index)")
                }
                break
            }
            guard bytes[index] == 0x1C else {
                throw EmbeddedJPEGError.layoutUnsupported("IIM 标记不是 0x1C at \(index)")
            }
            guard index + 4 < bytes.count else {
                throw EmbeddedJPEGError.layoutUnsupported("IIM 数据集头截断 at \(index)")
            }
            let record = bytes[index + 1]
            let dataset = bytes[index + 2]
            var length = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
            var payloadStart = index + 5
            if length & 0x8000 != 0 {
                // 扩展长度：低 15 位是"长度字段本身的字节数"。
                let width = length & 0x7FFF
                guard width > 0, width <= 4, payloadStart + width <= bytes.count else {
                    throw EmbeddedJPEGError.layoutUnsupported("IIM 扩展长度非法 at \(index)")
                }
                var extended = 0
                for offset in 0..<width {
                    extended = (extended << 8) | Int(bytes[payloadStart + offset])
                }
                payloadStart += width
                length = extended
            }
            let payloadEnd = payloadStart + length
            guard payloadEnd <= bytes.count else {
                throw EmbeddedJPEGError.layoutUnsupported("IIM 数据集越界 at \(index)")
            }
            result.append(IIMDataset(
                key: IIMKey(record: record, dataset: dataset),
                value: Data(bytes[payloadStart..<payloadEnd])))
            index = payloadEnd
        }
        return IPTCIIM(datasets: result)
    }

    func encoded() throws -> Data {
        var output = Data()
        for item in datasets {
            guard item.value.count <= 0x7FFF else {
                throw EmbeddedJPEGError.layoutUnsupported("IIM dataset 超过 32767 字节")
            }
            output.append(0x1C)
            output.append(item.key.record)
            output.append(item.key.dataset)
            output.append(UInt8((item.value.count >> 8) & 0xFF))
            output.append(UInt8(item.value.count & 0xFF))
            output.append(item.value)
        }
        return output
    }

    /// 取某个 dataset 的全部文本值（IIM 允许多次出现，如 Byline/Keywords）。
    func values(for key: IIMKey) -> [String] {
        datasets.filter { $0.key == key }.compactMap { item in
            String(data: item.value, encoding: .utf8)
                ?? String(data: item.value, encoding: .isoLatin1)
        }
    }

    /// 删除 updates 涉及的 dataset 后按 key 顺序重建；空数组 = 删除。
    /// 含非 ASCII 值时补 1:90 UTF-8 标志。
    func replacing(_ updates: [IIMKey: [String]]) throws -> IPTCIIM {
        guard !updates.isEmpty else { return self }
        var kept = datasets.filter { updates[$0.key] == nil }
        var needsUTF8 = false
        for key in updates.keys.sorted() {
            guard let values = updates[key], !values.isEmpty else { continue }
            for value in values {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if !text.allSatisfy({ $0.isASCII }) { needsUTF8 = true }
                kept.append(IIMDataset(key: key, value: Data(text.utf8)))
            }
        }
        if needsUTF8 {
            kept.removeAll { $0.key == .codedCharacterSet }
            kept.append(IIMDataset(key: .codedCharacterSet, value: Data([0x1B, 0x25, 0x47])))
        }
        kept.sort { $0.key < $1.key }
        return IPTCIIM(datasets: kept)
    }
}

/// 描述性元数据 → IIM 的可写映射（只收 IIM 1.1 真实存在的 dataset）。
/// XMP 独有字段（contact / UsageTerms / Scene 等 IPTC-Ext 字段）在 IIM 里没有 dataset：
/// 它们的「清空」只能靠 XMP 侧删除 + 读侧 presence 阻断，映射表返回 nil 是正确行为
/// （不要为它们编造 dataset 号，否则会写坏别人的 IIM）。
enum IPTCIIMMapping {
    static func updates(for descriptive: DescriptiveMetadata?, keywords: [String]?) -> [IIMKey: [String]] {
        var updates: [IIMKey: [String]] = [:]
        if let keywords {
            updates[.keywords] = keywords
        }
        guard let descriptive else { return updates }
        for field in descriptive.explicitlySetFields {
            guard let key = key(for: field), let value = descriptive.value(for: field) else { continue }
            switch value {
            case .text(let text):
                updates[key] = text.isEmpty ? [] : [text]
            case .list(let items):
                updates[key] = items
            case .contact:
                continue
            }
        }
        return updates
    }

    static func key(for field: DescriptiveField) -> IIMKey? {
        switch field {
        case .title: .objectName
        case .caption: .caption
        case .creator: .byline
        case .copyrightNotice: .copyrightNotice
        case .creatorJobTitle: .bylineTitle
        case .credit: .credit
        case .source: .source
        case .headline: .headline
        case .captionWriter: .writerEditor
        case .jobIdentifier: .transmissionReference
        case .subjectCode: .subjectReference
        case .intellectualGenre: .objectAttributeReference
        case .location: .contentLocationName
        case .city: .city
        case .state: .provinceState
        case .country: .countryName
        case .countryCode: .countryCode
        case .sublocation: .sublocation
        case .dateCreated: .dateCreated
        case .scene: .scene
        default: nil
        }
    }
}

/// Photoshop 图片资源块（IRB）——只关心 0x0404，其余原样搬运。
struct PhotoshopIRB: Equatable, Sendable {
    let resourceID: UInt16
    let name: Data
    let data: Data

    static let iptcNAA: UInt16 = 0x0404
}

enum PhotoshopIRBList {
    static func parse(_ payload: Data) throws -> [PhotoshopIRB] {
        let bytes = [UInt8](payload)
        var index = 0
        var result: [PhotoshopIRB] = []
        while index < bytes.count {
            if bytes[index] == 0x00 {
                guard bytes[index...].allSatisfy({ $0 == 0x00 }) else {
                    throw EmbeddedJPEGError.layoutUnsupported("IRB 中间出现 0 填充 at \(index)")
                }
                break
            }
            guard index + 7 <= bytes.count,
                  bytes[index] == 0x38, bytes[index + 1] == 0x42,
                  bytes[index + 2] == 0x49, bytes[index + 3] == 0x4D else {
                throw EmbeddedJPEGError.layoutUnsupported("IRB 签名不是 8BIM at \(index)")
            }
            let resourceID = UInt16(bytes[index + 4]) << 8 | UInt16(bytes[index + 5])
            var cursor = index + 6
            let nameLength = Int(bytes[cursor])
            cursor += 1
            guard cursor + nameLength <= bytes.count else {
                throw EmbeddedJPEGError.layoutUnsupported("IRB 名越界 at \(index)")
            }
            let name = Data(bytes[cursor..<(cursor + nameLength)])
            cursor += nameLength
            // Pascal 名总长（含长度字节）补齐到偶数。
            if (1 + nameLength) % 2 == 1 { cursor += 1 }
            guard cursor + 4 <= bytes.count else {
                throw EmbeddedJPEGError.layoutUnsupported("IRB 长度截断 at \(index)")
            }
            let size = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            cursor += 4
            guard size >= 0, cursor + size <= bytes.count else {
                throw EmbeddedJPEGError.layoutUnsupported("IRB 数据越界 at \(index)")
            }
            let data = Data(bytes[cursor..<(cursor + size)])
            cursor += size
            if size % 2 == 1, cursor < bytes.count { cursor += 1 }
            result.append(PhotoshopIRB(resourceID: resourceID, name: name, data: data))
            index = cursor
        }
        return result
    }

    static func encode(_ items: [PhotoshopIRB]) -> Data {
        var output = Data()
        for item in items {
            output.append(contentsOf: [0x38, 0x42, 0x49, 0x4D])  // 8BIM
            output.append(UInt8((item.resourceID >> 8) & 0xFF))
            output.append(UInt8(item.resourceID & 0xFF))
            output.append(UInt8(item.name.count & 0xFF))
            output.append(item.name)
            if (1 + item.name.count) % 2 == 1 { output.append(0x00) }
            let size = item.data.count
            output.append(contentsOf: [
                UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
            ])
            output.append(item.data)
            if size % 2 == 1 { output.append(0x00) }
        }
        return output
    }
}

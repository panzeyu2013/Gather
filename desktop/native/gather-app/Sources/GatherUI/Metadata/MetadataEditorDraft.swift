// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataEditorDraft.swift
// P0 / B2：单张元数据编辑器的"差异计算"（纯函数，直测）。
//
// 编辑器只提交用户改过的字段：空白 = 显式清空，未改 = 不触碰。把这段语义从
// SwiftUI 视图里抽出来，测试才能覆盖"只写改动字段""空值清空""contact 整块替换"。
//
// Wave5（batch2）追加受控值（IPTCControlledVocabulary）：
// - changes() 在写盘侧做归一化（countryCode 大写等），校验与写盘同一口径；
// - controlledValueViolation() 只校验"改过的、非空的"值：未改动不校验（盘上存量
//   词表外值不该让用户无法编辑其它字段），清空合法。
import Foundation
import GatherProtocol

enum MetadataEditorDraft {
    /// 改动过的字段数（contact 整块算一次）。
    static func changedFieldCount(
        values: [DescriptiveField: String],
        initial: [DescriptiveField: String],
        contact: DescriptiveContact,
        initialContact: DescriptiveContact
    ) -> Int {
        var count = 0
        for field in DescriptiveField.allCases where field != .contactInfo {
            if normalized(values[field]) != normalized(initial[field]) { count += 1 }
        }
        if contact != initialContact { count += 1 }
        return count
    }

    /// 编辑结果：字段补丁 + 显式清空的联系人成员。
    struct Patch: Equatable {
        var fields: DescriptiveMetadata
        /// 原来有值、现在被用户清空的联系人成员（DescriptiveContact.members 的 key）。
        var clearedContactMembers: [String]
    }

    /// 生成三态补丁；nil = 没有任何改动（调用方禁用以按钮）。
    static func changes(
        values: [DescriptiveField: String],
        initial: [DescriptiveField: String],
        contact: DescriptiveContact,
        initialContact: DescriptiveContact
    ) -> Patch? {
        var edited = DescriptiveMetadata()
        var clearedMembers: [String] = []
        for field in DescriptiveField.allCases where field != .contactInfo {
            let before = normalized(initial[field])
            let after = normalized(values[field])
            if after == before { continue }
            if after.isEmpty {
                edited.clear(field)
            } else if XMPFieldDescriptor.descriptor(for: field)?.isList == true {
                // 受控值列表字段（scene / subjectCode / release ID）：逐项归一化
                // （数字码/URI 不做大小写转换，country 类字段才转换）。
                let items = after.split(whereSeparator: { $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { IPTCControlledVocabulary.normalized($0, for: field) }
                edited.set(.list(items), for: field)
            } else {
                edited.set(.text(IPTCControlledVocabulary.normalized(after, for: field)), for: field)
            }
        }
        if contact != initialContact {
            edited.contactInfo = contact
            // contact 结构里 nil 既可能是"清空"也可能是"不触碰"：只有"原本有值、
            // 现在为空"的成员才算显式清空，服务端据此判断 JPEG 内嵌残留。
            clearedMembers = DescriptiveContact.members.map(\.key).filter { key in
                let before = initialContact.memberValue(key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let after = contact.memberValue(key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !before.isEmpty && after.isEmpty
            }
        }
        guard !edited.isEmpty else { return nil }
        return Patch(fields: edited, clearedContactMembers: clearedMembers)
    }

    /// 受控值校验：只校验"改过的、非空的"值。
    ///
    /// 为什么不校验全部：盘上存量值可能是外部软件写的（词表外/旧码），用户只想改
    /// 别的字段时不该被它挡住；三态语义下"未改动"本来就不会写盘。
    /// 列表字段逐项校验（每个 Scene Code / Subject Code / Release Id 都必须是词表值）。
    /// 返回第一条违规（字段 + 用户原始输入，文案要显示用户看到的东西）。
    static func controlledValueViolation(
        values: [DescriptiveField: String],
        initial: [DescriptiveField: String]
    ) -> (field: DescriptiveField, value: String)? {
        for field in DescriptiveField.allCases {
            guard IPTCControlledVocabulary.isControlled(field) else { continue }
            let before = normalized(initial[field])
            let after = normalized(values[field])
            guard after != before, !after.isEmpty else { continue }
            let isList = XMPFieldDescriptor.descriptor(for: field)?.isList == true
            let items: [String] = isList
                ? after.split(whereSeparator: { $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : [after]
            for item in items where !IPTCControlledVocabulary.isValid(item, for: field) {
                return (field, item)
            }
        }
        return nil
    }

    // MARK: - Wave5（batch5）：位置 / 拍摄时间

    /// 位置/时间的草稿：nil 字段 = 不动；dateTaken == "" = 清空。
    struct GeoDateDraft: Equatable {
        var latitude: Double?
        var longitude: Double?
        var dateTaken: String?

        var isEmpty: Bool {
            latitude == nil && longitude == nil && dateTaken == nil
        }
    }

    /// 位置/时间输入校验失败（UI 映射中文文案；协议输入层会再校验一次）。
    enum GeoDateValidationError: Error, Equatable {
        case latitudeNotNumber(String)
        case latitudeOutOfRange(Double)
        case longitudeNotNumber(String)
        case longitudeOutOfRange(Double)
        /// 只填了一个坐标：GPS 必须成对（半个坐标不是合法资产）。
        case coordinatesIncomplete
        case invalidDate(String)
    }

    /// 位置/时间三态差异计算；nil = 没有改动。
    ///
    /// 语义：
    /// - 坐标：两个空 = 不动；只有一个空 = 不完整（失败）；非数字/越界 = 失败；
    ///   与初值数值相同（容差 1e-9）= 不动；任一变化 → 两个坐标一起提交（成对写入）。
    /// - 时间：空 = 清空（初值本来为空则不算改动）；非法 = 失败；归一化后与初值相同
    ///   = 不动（盘上可能是 EXIF 冒号形态，归一化后比较才不会"假改动"）。
    static func geoDateChanges(
        latitude: String,
        longitude: String,
        dateTaken: String,
        initialLatitude: String,
        initialLongitude: String,
        initialDate: String
    ) throws -> GeoDateDraft? {
        let latText = normalized(latitude)
        let lonText = normalized(longitude)
        var latitudeValue: Double?
        var longitudeValue: Double?
        if latText.isEmpty && lonText.isEmpty {
            // 不动（保留初值）。
        } else if latText.isEmpty || lonText.isEmpty {
            throw GeoDateValidationError.coordinatesIncomplete
        } else {
            guard let lat = Double(latText), lat.isFinite else {
                throw GeoDateValidationError.latitudeNotNumber(latText)
            }
            guard (-90.0...90.0).contains(lat) else {
                throw GeoDateValidationError.latitudeOutOfRange(lat)
            }
            guard let lon = Double(lonText), lon.isFinite else {
                throw GeoDateValidationError.longitudeNotNumber(lonText)
            }
            guard (-180.0...180.0).contains(lon) else {
                throw GeoDateValidationError.longitudeOutOfRange(lon)
            }
            let initialLat = Double(normalized(initialLatitude))
            let initialLon = Double(normalized(initialLongitude))
            var unchanged = false
            if let initialLat, let initialLon {
                unchanged = abs(lat - initialLat) <= 1e-9 && abs(lon - initialLon) <= 1e-9
            }
            if !unchanged {
                latitudeValue = lat
                longitudeValue = lon
            }
        }

        let dateText = normalized(dateTaken)
        var dateValue: String?
        if dateText.isEmpty {
            // 空串 = 清空；初值本来为空则不算改动。
            if !normalized(initialDate).isEmpty { dateValue = "" }
        } else {
            guard let normalizedDate = MetadataGeoDateInput.normalizedDateTime(dateText) else {
                throw GeoDateValidationError.invalidDate(dateText)
            }
            let initialNormalized = MetadataGeoDateInput.normalizedDateTime(normalized(initialDate))
            if normalizedDate != initialNormalized { dateValue = normalizedDate }
        }

        let draft = GeoDateDraft(
            latitude: latitudeValue, longitude: longitudeValue, dateTaken: dateValue)
        return draft.isEmpty ? nil : draft
    }

    // MARK: - Wave5（batch7）：批量时间调整（纯计算）

    /// 批量时间调整方式：偏移现有值 / 设为同一指定时刻。
    enum TimeAdjustMode: String, CaseIterable, Equatable, Sendable {
        case offset
        case absolute
    }

    /// 时间偏移单位。批量"时间偏移"动作与纯计算测试共用。
    enum TimeOffsetUnit: String, CaseIterable, Equatable, Sendable {
        case seconds, minutes, hours, days

        var secondsMultiplier: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3_600
            case .days: return 86_400
            }
        }
    }

    /// 偏移量文本（可带正负号；空/非法/非整数返回 nil）→ 秒。
    ///
    /// 0 秒也返回 0：调用方据此禁用按钮（静默无操作比报错更糟）。
    static func offsetSeconds(_ amountText: String, unit: TimeOffsetUnit) -> Int? {
        let text = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let amount = Int(text) else { return nil }
        let (product, overflow) = amount.multipliedReportingOverflow(
            by: unit.secondsMultiplier)
        return overflow ? nil : product
    }

    /// 拍摄时间 + 偏移秒数 → 归一化时间文本；源不可解析返回 nil。
    ///
    /// 取舍（测试与注释同一口径）：EXIF 的 DateTimeOriginal 是**没有时区的墙上时间**，
    /// 因此按固定 UTC 日历做秒级算术——用设备本地日历会让夏令时切换日把 02:30 + 1h
    /// 变成 03:30/01:30（同一次批量在不同机器/不同日期结果不同）。跨日/跨月/闰年
    /// 进位由 Date 的绝对时间算术负责。
    static func shiftedDateTime(_ raw: String, bySeconds seconds: Int) -> String? {
        guard let normalized = MetadataGeoDateInput.normalizedDateTime(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = formatter.date(from: normalized) else { return nil }
        let shifted = date.addingTimeInterval(TimeInterval(seconds))
        return formatter.string(from: shifted)
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

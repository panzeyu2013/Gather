// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsModels.swift
// Cut 4 / 4c-2d：从 SettingsView.swift 第 35-98 行整段搬出（分组设置与滑杆定义，
// 对齐 TS Settings/index.tsx GROUPS / 滑杆段）。纯搬移，无内容改动。
import SwiftUI
import GatherProtocol

// MARK: - 分组设置与滑杆定义（对齐 TS Settings/index.tsx GROUPS / 滑杆段）

public struct SelectOption: Identifiable, Equatable {
    public let value: String
    public let labelZh: String
    public var id: String { value }
    public init(value: String, labelZh: String) {
        self.value = value
        self.labelZh = labelZh
    }
}

public enum SettingFieldType: Equatable {
    case text
    case number(min: Double?, max: Double?)
    case select([SelectOption])
}

public struct SettingField: Identifiable {
    public let key: String
    public let type: SettingFieldType
    public let zhLabel: String
    public let zhDesc: String
    public var id: String { key }
    public init(key: String, type: SettingFieldType, zhLabel: String, zhDesc: String) {
        self.key = key
        self.type = type
        self.zhLabel = zhLabel
        self.zhDesc = zhDesc
    }
}

public struct SettingGroup: Identifiable {
    public let id: String
    public let titleZh: String
    public let fields: [SettingField]
    public init(id: String, titleZh: String, fields: [SettingField]) {
        self.id = id
        self.titleZh = titleZh
        self.fields = fields
    }
}

public struct SliderSetting: Identifiable {
    public let key: String
    public let min: Double
    public let max: Double
    public let step: Double
    public let isInteger: Bool
    public let defaultValue: Double
    public let zhLabel: String
    public let zhDesc: String
    public var id: String { key }
    public init(key: String, min: Double, max: Double, step: Double, isInteger: Bool, defaultValue: Double, zhLabel: String, zhDesc: String) {
        self.key = key
        self.min = min
        self.max = max
        self.step = step
        self.isInteger = isInteger
        self.defaultValue = defaultValue
        self.zhLabel = zhLabel
        self.zhDesc = zhDesc
    }
}

// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SettingsInputs.swift
// Cut 1 / 阶段 1A：SettingsAPI 输入（settings.* 6 条 -> 6 个方法）。
//
// 对应命令：settings.get_all / get / set / reset / set_language / get_ml_status。
// 校验归属：
// - key <= 256 且非空白（trim）；value <= 4096 且允许空串；
// - set_language 只接受 zh-CN / en：InterfaceLanguage 枚举在解码期失败，
//   不再走字符串比较；
// - settings.set 不是破坏性操作，不需要 Confirmed。

import Foundation

/// settings key：<= 256、非空白、trim 后存储。
public struct SettingsKey: Decodable, Sendable, Equatable, Hashable {
    public let value: String

    public init(_ value: String) throws {
        self.value = try APIValidation.nonBlank(value, field: "key", maxLength: 256)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
}

/// settings value：<= 4096，允许空串（allowEmpty）。
public struct SettingsValue: Decodable, Sendable, Equatable, Hashable {
    public let value: String

    public init(_ value: String) throws {
        self.value = try APIValidation.bounded(value, field: "value", maxLength: 4096, allowEmpty: true)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
}

/// settings.set 的输入。
public struct SettingsSetInput: Decodable, Sendable, Equatable {
    public let key: SettingsKey
    public let value: SettingsValue

    public init(key: SettingsKey, value: SettingsValue) {
        self.key = key
        self.value = value
    }

    public init(key: String, value: String) throws {
        self.key = try SettingsKey(key)
        self.value = try SettingsValue(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(SettingsKey.self, forKey: .key),
            value: container.decode(SettingsValue.self, forKey: .value)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, value
    }
}

/// settings.set_language 的语言白名单。
public enum InterfaceLanguage: String, Codable, CaseIterable, Sendable, Equatable {
    case zhCN = "zh-CN"
    case en
}

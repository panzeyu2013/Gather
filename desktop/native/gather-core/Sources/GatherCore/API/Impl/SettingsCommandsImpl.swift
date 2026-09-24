// API/Impl/SettingsCommandsImpl.swift
// R5 命令层接线：settings 域实现（批次 B2）。
// 逻辑来源：宿主路由层 settings.* 分支（get_all / get / get_ml_status /
// set / reset / set_language）；错误码与返回形状不变。
// 已知差异：get_ml_status 依赖宿主侧 ML/Vision 状态构造（含本地化文案与模型
// 路径探测），core 定义 MLStatusProvider 注入点，app 侧接线留待 W5-4。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// settings 域命令实现：注入设置命名空间与可选的 ML 状态提供者。
public actor SettingsCommandsImpl: SettingsCommands {
    /// `settings.get_ml_status` 的宿主侧提供者：返回 Protocol/Settings.swift 的
    /// MLStatusData。core 不承载本地化文案与 app 模型目录探测，故以闭包注入；
    /// 未接线时调用抛 mlStatusProviderUnavailable，不返回伪造状态。
    public typealias MLStatusProvider = @Sendable () async throws -> MLStatusData

    private let settings: SettingsAPI
    private let mlStatusProvider: MLStatusProvider

    public init(
        settings: SettingsAPI,
        mlStatusProvider: @escaping MLStatusProvider = { throw SettingsCommandsError.mlStatusProviderUnavailable }
    ) {
        self.settings = settings
        self.mlStatusProvider = mlStatusProvider
    }

    /// 旧命令：`settings.get_all`。默认值打底 + 已落库值（SettingsAPI.all
    /// 与旧快照同源），值均为字符串。
    public func getAll() async throws -> [String: String] {
        await settings.all()
    }

    /// 旧命令：`settings.get`。key 边界校验与旧分支同码（超长或空白 →
    /// INVALID_PARAM:key）；key 未落库时兜底 ""（SettingsAPI.value 既有语义）。
    public func get(key: String) async throws -> String {
        let validated = try Self.validatedKey(key)
        return await settings.value(validated)
    }

    /// 旧命令：`settings.get_ml_status`。经注入的宿主提供者取回 MLStatusData。
    public func getMLStatus() async throws -> MLStatusData {
        try await mlStatusProvider()
    }

    /// 旧命令：`settings.set`。key 非空白且 ≤256、value ≤4096（允许空串）；
    /// 未知 key 由 SettingsAPI 抛 SettingsError.unknownKey（消息与旧一致）。
    public func set(key: String, value: String) async throws {
        let validated = try Self.validatedKey(key)
        guard value.count <= 4096 else {
            throw SettingsCommandsError.invalidParam("value")
        }
        try await settings.set(validated, value: value)
    }

    /// 旧命令：`settings.reset`。重置默认值后返回重置后的全量快照。
    public func reset() async throws -> [String: String] {
        try await settings.reset()
        return await settings.all()
    }

    /// 旧命令：`settings.set_language`。仅接受 "zh-CN" / "en"，其余 →
    /// SETTINGS_LANGUAGE_INVALID；返回落库后的语言值。
    public func setLanguage(language: String) async throws -> String {
        guard language == "zh-CN" || language == "en" else {
            throw SettingsCommandsError.languageInvalid
        }
        try await settings.set("ui_language", value: language)
        return language
    }

    /// 旧分支 validatedString(key, maxLength: 256) 语义：先按原始长度判超长，
    /// 再按 trim 后判空白；通过后返回 trim 值（写路径落库、读路径查库同值）。
    private static func validatedKey(_ key: String) throws -> String {
        if key.count > 256 {
            throw SettingsCommandsError.invalidParam("key")
        }
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            throw SettingsCommandsError.invalidParam("key")
        }
        return trimmed
    }
}

/// settings 域命令边界错误（错误码与旧宿主路由层分支逐字一致）。
public enum SettingsCommandsError: Error, Equatable {
    /// 旧分支参数校验拒绝：`INVALID_PARAM:<key>`。
    case invalidParam(String)
    /// 旧响应 error 串：`SETTINGS_LANGUAGE_INVALID`。
    case languageInvalid
    /// ML 状态提供者尚未接线（W5-4 前调用 get_ml_status 的真实失败态）。
    case mlStatusProviderUnavailable
}

extension SettingsCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidParam(let key): "INVALID_PARAM:\(key)"
        case .languageInvalid: "SETTINGS_LANGUAGE_INVALID"
        case .mlStatusProviderUnavailable: "SETTINGS_ML_STATUS_UNAVAILABLE"
        }
    }
}

extension SettingsCommandsError {
    /// 桥接层序列化用；参数错误与未接线态无 GatherErrorCode 同码 case。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .languageInvalid: .SETTINGS_LANGUAGE_INVALID
        case .invalidParam, .mlStatusProviderUnavailable: nil
        }
    }
}

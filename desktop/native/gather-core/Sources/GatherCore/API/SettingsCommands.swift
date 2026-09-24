// API/SettingsCommands.swift
// R5 类型化 async 域协议：settings 域。
// 旧实现来源：gather-app 的会话命令分发器 settings.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO 或基础类型；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// settings 域命令（6 条）。
///
/// 旧命令清单：`settings.get_all`、`settings.get`、`settings.get_ml_status`、
/// `settings.set`、`settings.reset`、`settings.set_language`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `settings.get_all` 与 `settings.reset` 的响应为 Record<string, string>；
///   Protocol/ 下暂无快照 DTO（W5 待裁决项），故沿用扁平字典。
/// - 旧 `settings.set` 响应恒为 {done: true}，本协议不返回该常量；
///   旧 `settings.set_language` 响应 {language} 收敛为返回语言字符串。
public protocol SettingsCommands: Sendable {
    /// 旧命令：`settings.get_all`。
    /// 返回全量设置快照（key → value，值均为字符串）。
    func getAll() async throws -> [String: String]

    /// 旧命令：`settings.get`。
    /// 读取单个 key；key 缺失时的兜底值由实现保持旧设置服务的既有语义。
    func get(key: String) async throws -> String

    /// 旧命令：`settings.get_ml_status`。
    /// 响应形状见 Protocol/Settings.swift 的 MLStatusData。
    func getMLStatus() async throws -> MLStatusData

    /// 旧命令：`settings.set`。
    /// key 长度上限 256、value 上限 4096（value 允许空串），校验由实现承载；
    /// 旧响应 {done: true} 为常量，故本协议返回空。
    func set(key: String, value: String) async throws

    /// 旧命令：`settings.reset`。
    /// 重置为默认值并返回重置后的全量快照，语义同 getAll。
    func reset() async throws -> [String: String]

    /// 旧命令：`settings.set_language`。
    /// language 仅接受 "zh-CN" / "en"，非法值由实现抛错；
    /// 返回落库后的语言值（旧响应 {language} 的收敛）。
    func setLanguage(language: String) async throws -> String
}

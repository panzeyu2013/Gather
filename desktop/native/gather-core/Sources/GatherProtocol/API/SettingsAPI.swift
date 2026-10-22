// desktop/native/gather-core/Sources/GatherProtocol/API/SettingsAPI.swift
// Cut 1 / 阶段 1A：设置域协议（6 个方法）。
//
// 职责：设置读取/写入/重置、语言切换、ML 状态。
// 对应命令（6 条）：settings.get_all / get / set / reset / set_language /
// get_ml_status。
// 校验归属：
// - key <= 256 非空白、value <= 4096 允许空串在输入类型；
// - setLanguage 只接受 InterfaceLanguage（解码期拒绝未知语言）；
// - 旧命令在 set_language 后重建菜单并广播；协议只返回生效语言，
//   通知由实现层（Host）负责，避免协议依赖 AppKit。

import Foundation

public protocol SettingsAPI: Sendable {
    func all() async throws -> [String: String]
    func get(_ key: SettingsKey) async throws -> String
    func set(_ input: SettingsSetInput) async throws
    func reset() async throws -> [String: String]
    func setLanguage(_ language: InterfaceLanguage) async throws -> InterfaceLanguage
    func mlStatus() async throws -> MLStatusData
}

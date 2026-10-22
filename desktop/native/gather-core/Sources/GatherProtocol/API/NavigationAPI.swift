// desktop/native/gather-core/Sources/GatherProtocol/API/NavigationAPI.swift
// Cut 1 / 阶段 1A：导航分组域协议（4 个方法）。
//
// 职责：分组列表、拆分/合并、自动分析。
// 对应命令（4 条）：navigation.list / split / merge / analyze。
// 校验归属：
// - split/merge/analyze 复用旧 *Params（字段形状一致）；数组元素类型由 [String] 保证；
// - burst/scene 间隔范围（NAV_BURST_GAP_INVALID / NAV_SCENE_GAP_INVALID）与
//   组类型/归属校验由 NavigationService 负责（旧命令即如此）；
// - analyze 的默认值 2/1800 由实现补（输入可选）。

import Foundation

public protocol NavigationAPI: Sendable {
    func list(_ sessionId: String) async throws -> [NavigationGroup]
    func split(_ input: NavigationSplitParams) async throws -> [NavigationGroup]
    func merge(_ input: NavigationMergeParams) async throws -> [NavigationGroup]
    func analyze(_ input: NavigationAnalyzeParams) async throws -> [NavigationGroup]
}

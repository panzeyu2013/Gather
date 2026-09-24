// API/QualityCommands.swift
// R5 类型化 async 域协议：quality 域。
// 旧实现来源：gather-app 的会话命令分发器 quality.* 分支
// （每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// quality 域命令（2 条）。
///
/// 旧命令清单：`quality.get`、`quality.analyze`。
public protocol QualityCommands: Sendable {
    /// 旧命令：`quality.get`。
    /// photoIds 为 nil 取该会话全部评分结果；返回元素为 Protocol/Quality.swift 的 QualityResult。
    func get(_ params: QualityGetParams) async throws -> [QualityResult]

    /// 旧命令：`quality.analyze`。
    /// 建 quality.score 作业后立即返回作业数据（旧响应即 AnalysisJobData 的序列化），
    /// 不等作业完成；photoIds 提供但为空时按 INVALID_PARAM 拒绝（实现需保留该门控）。
    func analyze(_ params: QualityAnalyzeParams) async throws -> AnalysisJobData
}

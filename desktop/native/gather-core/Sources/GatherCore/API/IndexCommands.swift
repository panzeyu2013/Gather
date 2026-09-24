// API/IndexCommands.swift
// R5 类型化 async 域协议：index 域。
// 旧实现来源：gather-app 路由层的 index.* 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、参数与返回只用 Protocol/ 既有 DTO、无同步重载。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// index 域命令（1 条）。
///
/// 旧命令清单：index.scan。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 index.scan 建 metadata.scan 作业后立即返回作业数据，不等待扫描完成
///   （进度经作业事件轮询）；Protocol/Indexer.swift 的基线契约为 IndexScanParams →
///   IndexScanResult（扫描结果形状）。本协议按 Protocol 基线签名，作业化与结果
///   映射（或改回作业数据返回）留待 W5-2 裁决。
/// - IndexScanParams.confirmed 为可选（旧命令未做破坏性门控）；扫描会写入照片
///   行，实现需先行明确 confirmed 语义。
public protocol IndexCommands: Sendable {
    /// 旧命令：index.scan。
    /// 扫描会话目录并落库；返回 Protocol/Indexer.swift 的 IndexScanResult。
    func scan(_ params: IndexScanParams) async throws -> IndexScanResult
}

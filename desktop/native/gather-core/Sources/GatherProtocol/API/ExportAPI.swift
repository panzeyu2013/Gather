// desktop/native/gather-core/Sources/GatherProtocol/API/ExportAPI.swift
// Cut 1 / 阶段 1A：导出域协议（4 个方法）。
//
// 职责：导出预览、执行（job→wait）、取消、报表。
// 对应命令（4 条）：export.preview / execute / cancel / report。
// 校验归属：
// - execute 使用 Confirmed<ExportInput>；preview 复用同一输入；
// - options 的字段/范围由 ExportOptions 类型与 ExportService 校验
//   （EXPORT_PARAMS_INVALID 等）；实现负责解码失败的码值收敛；
// - 导出指纹（deliveryFingerprint）与续跑语义留在实现（Cut 2 统一 delivery）；
// - cancel 按 sessionId 取消 job scope + 服务侧任务。

import Foundation

public protocol ExportAPI: Sendable {
    func preview(_ input: ExportInput) async throws -> ExportPreview
    func execute(_ input: Confirmed<ExportInput>) async throws -> ExportResult
    func cancel(_ sessionId: String) async throws -> Bool
    func report(_ input: ExportReportInput) async throws -> ReportData
}

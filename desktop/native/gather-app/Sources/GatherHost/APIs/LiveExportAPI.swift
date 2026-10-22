// desktop/native/gather-app/Sources/GatherHost/APIs/LiveExportAPI.swift
// Cut 1 / B6a：ExportAPI 的 Live 实现（4 个方法）。
//
// 对应命令（4 条）：export.preview / execute / cancel / report。
//
// 校验归属：
// - ExportInput / ExportReportInput 已在输入类型完成 sessionId/reportType 的
//   非空白与长度校验，本实现不重复解析 JSON；
// - options 为 nil 时沿用旧命令面 的 "{} 解码失败" 语义：抛
//   EXPORT_PARAMS_INVALID（字段级 params 由 implementation 补齐），不静默
//   构造一个合法默认值（那会从"报参数错"变成"导出到空目录"）；
// - 只有 execute 是破坏性入口，接收 Confirmed<ExportInput>；实现不自行补确认。
//
// 任务语义（与旧命令面 的 export.* 分支逐字对齐）：
// - preview：D09 续跑基线——同 sessionId + deliveryFingerprint 的最近终态
//   job checkpoint 中，只有 checkpoint.deliveryFingerprint 与本次一致时才把
//   destinations/completedPhotoIds 传给 ExportService.preview，保证预览显示的
//   是续跑真正会写的名字；预览不创建 job（B6a 测试断言）；
// - execute：JobService.start() → deliveryFingerprint → create(.exportExecute)
//   → waitForResult；dedupeKey 为 "export.execute:<sessionId>:<指纹>"，
//   checkpoint 写 options + deliveryFingerprint（与旧命令面 完全一致）；
//   空结果按旧命令面 抛 JobServiceError.jobFailed(jobId, "empty export.execute
//   result")；
// - cancel：先取消同会话的 exportExecute job（jobService.cancelScope），再
//   取消 ExportService 侧按会话登记的 run，成功返回 true；
// - report：generateReport 的 reportType 仍为自由字符串（G8 待补枚举），
//   ReportFormat 枚举在输入层保证 md/csv，映射回旧命令面 的字符串入口。
//
// 错误映射：ExportServiceError.description 多数就是 GatherErrorCode 的
// rawValue（EXPORT_DIR_INVALID / EXPORT_SOURCE_MISSING / ...），有码的收敛为
// GatherError；CANCELLED 没有协议码，保留原错误（D-030：不伪造业务码）。
// JobServiceError.jobFailed 的 message 若本身是错误码（executor 失败落库），
// 还原为带码的 GatherError（与 LiveDuplicate/LiveQuality 同一漏斗）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveExportAPI: ExportAPI, @unchecked Sendable {
    private let exportService: ExportService
    private let jobService: JobService

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；
    /// ExportService 的取消位由内部 NSLock 串行化，JobService 的任务表同样由
    /// 内部锁保护（与组合根同一约定）。
    public init(exportService: ExportService, jobService: JobService) {
        self.exportService = exportService
        self.jobService = jobService
    }

    // MARK: - 预览

    public func preview(_ input: ExportInput) async throws -> ExportPreview {
        let options = try Self.requireOptions(input.options)
        let sessionId = input.sessionId
        return try map {
            // D09 / F6：复用与执行相同的续跑基线；只有 checkpoint 记录的指纹
            // 与本次一致时才敢用它的完成清单（dedupeKey 与内容指纹可能因
            // create→claim 之间的集合变化而不一致）。
            let deliveryFingerprint = try? exportService.deliveryFingerprint(
                sessionId: sessionId,
                options: options
            )
            var resumedNames: [String: String] = [:]
            var completedPhotoIds: Set<String> = []
            if let fingerprint = deliveryFingerprint,
               let checkpoint = try? jobService.latestTerminalCheckpoint(
                   dedupeKey: "export.execute:\(sessionId):\(fingerprint)"
               ),
               checkpoint["deliveryFingerprint"]?.stringValue == fingerprint {
                resumedNames = checkpoint["destinations"]?.objectValue?.reduce(into: [String: String]()) { result, item in
                    if let value = item.value.stringValue { result[item.key] = value }
                } ?? [:]
                completedPhotoIds = Set(
                    checkpoint["completedPhotoIds"]?.arrayElements?.compactMap(\.stringValue) ?? []
                )
            }
            return try exportService.preview(
                sessionId: sessionId,
                options: options,
                resumedNames: resumedNames,
                completedPhotoIds: completedPhotoIds
            )
        }
    }

    // MARK: - 执行

    public func execute(_ input: Confirmed<ExportInput>) async throws -> ExportResult {
        let payload = input.value
        let options = try Self.requireOptions(payload.options)
        let sessionId = payload.sessionId
        // makeDefault 的 router 可被 CLI/测试直接调用；start 是幂等的，
        // 这里确保 export.execute 不会因宿主忘记启动 job service 而永久 queued。
        jobService.start()
        // D01：交付身份 = 完整输出参数 + 参与导出的照片集合指纹。只有完全相同的
        // 请求才复用同一任务身份（=真续跑，允许继承完成记录）。
        let deliveryFingerprint = try map {
            try exportService.deliveryFingerprint(sessionId: sessionId, options: options)
        }
        let job = try map {
            try jobService.create(JobCreateParams(
                type: .exportExecute,
                scopeType: "session",
                scopeId: sessionId,
                dedupeKey: "export.execute:\(sessionId):\(deliveryFingerprint)",
                checkpoint: [
                    "options": try JSONValue(from: options),
                    "deliveryFingerprint": .string(deliveryFingerprint),
                ]
            ))
        }
        let result: ExportResult? = try await mapAsync {
            try await jobService.waitForResult(jobId: job.id)
        }
        guard let result else {
            throw JobServiceError.jobFailed(job.id, "empty export.execute result")
        }
        return result
    }

    // MARK: - 取消

    public func cancel(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map {
            _ = try jobService.cancelScope(type: .exportExecute, scopeId: id)
            exportService.cancel(sessionId: id)
            return true
        }
    }

    // MARK: - 报表

    public func report(_ input: ExportReportInput) async throws -> ReportData {
        try map {
            try exportService.generateReport(
                sessionId: input.sessionId,
                reportType: input.reportType,
                format: input.format?.rawValue
            )
        }
    }

    // MARK: - 校验与错误映射

    /// 旧命令面 对缺省 options 也走 decodeExportOptions(.object([:]))，最终抛
    /// EXPORT_PARAMS_INVALID。这里显式保留同一码值与 params，不静默补默认值。
    private static func requireOptions(_ options: ExportOptions?) throws -> ExportOptions {
        guard let options else {
            throw GatherError.invalidParameter(
                code: .EXPORT_PARAMS_INVALID,
                field: "options",
                reason: "is required"
            )
        }
        return options
    }

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.translate(error)
        }
    }

    /// 域臂：ExportServiceError（description 即错误码时转码，否则原样）。
    private static func translate(_ error: Error) -> Error {
        if let common = LiveAPIErrorMapping.translateCommon(error) { return common }
        guard let export = error as? ExportServiceError else { return error }
        if let code = GatherErrorCode(rawValue: export.description) {
            return GatherError(code: code, underlying: export.description)
        }
        return export
    }
}

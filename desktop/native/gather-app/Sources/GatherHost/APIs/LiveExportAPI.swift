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
// - execute：JobService.start() → deliveryFingerprint → create(.outputRun)
//   → waitForResult；dedupeKey 为 "output.run:<sessionId>:<指纹>"，
//   checkpoint 写 options + deliveryFingerprint（与旧命令面 完全一致）；
//   空结果按旧命令面 抛 JobServiceError.jobFailed(jobId, "empty output.run
//   result")；
// - cancel：先取消同会话的 outputRun job（jobService.cancelScope），再
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
    /// W3b：WebDAV 传输与凭据（nil = 未接线，相关命令显式失败）。
    private let webDAVPublisher: WebDAVPublisher?
    private let webDAVCredentialSaver: (@Sendable (URL, String, String) throws -> Bool)?
    private let webDAVCredentialLookup: (@Sendable (URL, String) -> String?)?

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；
    /// ExportService 的取消位由内部 NSLock 串行化，JobService 的任务表同样由
    /// 内部锁保护（与组合根同一约定）。
    public init(
        exportService: ExportService,
        jobService: JobService,
        webDAVPublisher: WebDAVPublisher? = nil,
        webDAVCredentialSaver: (@Sendable (URL, String, String) throws -> Bool)? = nil,
        webDAVCredentialLookup: (@Sendable (URL, String) -> String?)? = nil
    ) {
        self.exportService = exportService
        self.jobService = jobService
        self.webDAVPublisher = webDAVPublisher
        self.webDAVCredentialSaver = webDAVCredentialSaver
        self.webDAVCredentialLookup = webDAVCredentialLookup
    }

    // MARK: - 预览

    // MARK: - WebDAV 发布

    public func saveWebDAVCredential(_ input: WebDAVCredentialInput) async throws -> Bool {
        guard let saveCredential = webDAVCredentialSaver else {
            throw GatherError(code: .INVALID_PARAM, params: [
                "field": "webdav", "reason": "credential store not wired",
            ])
        }
        guard let url = URL(string: input.baseURL), url.scheme?.hasPrefix("http") == true else {
            throw GatherError(code: .INVALID_PARAM, params: [
                "field": "baseURL", "reason": "must be http(s)",
            ])
        }
        return try saveCredential(url, input.username, input.password)
    }

    public func publish(
        _ input: Confirmed<WebDAVPublishInput>,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> WebDAVPublishSummary {
        guard let publisher = webDAVPublisher else {
            throw GatherError(code: .INVALID_PARAM, params: [
                "field": "webdav", "reason": "publisher not wired",
            ])
        }
        let payload = input.value
        guard let url = URL(string: payload.baseURL), url.scheme?.hasPrefix("http") == true else {
            throw GatherError(code: .INVALID_PARAM, params: [
                "field": "baseURL", "reason": "must be http(s)",
            ])
        }
        let password = webDAVCredentialLookup?(url, payload.username) ?? ""
        let configuration = WebDAVConfiguration(
            baseURL: url, username: payload.username,
            password: password, remoteFolder: payload.remoteFolder)
        let result = try await publisher.publish(
            localPath: payload.localPath, configuration: configuration,
            includePrefixes: payload.includePrefixes, onProgress: onProgress)
        return WebDAVPublishSummary(
            uploaded: result.uploaded,
            failed: result.failed.map { WebDAVPublishFailureInfo(path: $0.path, reason: $0.reason) },
            remoteRoot: result.remoteRoot,
            abortedOnAuth: result.abortedOnAuth)
    }

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
                   dedupeKey: "output.run:\(sessionId):\(fingerprint)"
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

    // MARK: - 整套交付

    /// 交付任务的稳定身份（排序键 + JSON 编码），用于 job dedupe。
    ///
    /// 只取「会影响成片」的部分：配方去掉 artifacts，联系表/画廊选项一律不计。
    /// 它们只影响派生产物，算进身份会让勾选一个开关就换 job —— 继承不到 checkpoint 的
    /// resume，整批成片被重导成 _2 副本（交付可恢复性被 UI 开关破坏）。
    static func outputRunFingerprint(_ input: OutputRunInput) -> String {
        struct Identity: Encodable {
            var sessionId: String
            var scope: ExportScope
            var destinationRoot: String
            var recipes: [OutputRecipe]
        }
        let identity = Identity(
            sessionId: input.sessionId,
            scope: input.scope,
            destinationRoot: input.destinationRoot,
            recipes: input.recipes.map(\.withoutArtifacts))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(identity)
        } catch {
            return UUID().uuidString.lowercased()
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// 一个 job 跑完所有配方：checkpoint 带 recipes + root，执行器分派到 OutputService。
    public func runRecipes(_ input: Confirmed<OutputRunInput>) async throws -> OutputRunSummary {
        let payload = input.value
        let sessionId = try LiveAPIInput.requireSessionId(payload.sessionId)
        guard !payload.recipes.isEmpty else {
            throw GatherError(code: .EXPORT_PARAMS_INVALID, params: [
                "field": "recipes", "reason": "must not be empty",
            ])
        }
        jobService.start()
        let encoded = try map { try JSONValue(from: payload) }
        // 去重键必须包含**配方内容**而不只是 id：id 在持久化后不变，改了长边/格式
        // 仍会命中旧的 succeeded job，waitForResult 会返回上一次的旧结果。
        let contentFingerprint = Self.outputRunFingerprint(payload)
        return try await mapAsync {
            let dedupe = "output.run:batch:\(sessionId):\(payload.destinationRoot):"
                + contentFingerprint
            let job = try self.jobService.create(JobCreateParams(
                type: .outputRun,
                scopeType: "session",
                scopeId: sessionId,
                dedupeKey: dedupe,
                checkpoint: ["outputRun": .bool(true), "input": encoded]))
            let result: OutputRunSummary? = try await self.jobService.waitForResult(jobId: job.id)
            guard let result else {
                throw JobServiceError.jobFailed(job.id, "empty output.run result")
            }
            return result
        }
    }

    // MARK: - 执行

    public func execute(_ input: Confirmed<ExportInput>) async throws -> ExportResult {
        let payload = input.value
        let options = try Self.requireOptions(payload.options)
        let sessionId = payload.sessionId
        // makeDefault 的 router 可被 CLI/测试直接调用；start 是幂等的，
        // 这里确保 output.run 不会因宿主忘记启动 job service 而永久 queued。
        jobService.start()
        // D01：交付身份 = 完整输出参数 + 参与导出的照片集合指纹。只有完全相同的
        // 请求才复用同一任务身份（=真续跑，允许继承完成记录）。
        let deliveryFingerprint = try map {
            try exportService.deliveryFingerprint(sessionId: sessionId, options: options)
        }
        let job = try map {
            try jobService.create(JobCreateParams(
                type: .outputRun,
                scopeType: "session",
                scopeId: sessionId,
                dedupeKey: "output.run:\(sessionId):\(deliveryFingerprint)",
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
            throw JobServiceError.jobFailed(job.id, "empty output.run result")
        }
        return result
    }

    // MARK: - 取消

    public func cancel(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map {
            _ = try jobService.cancelScope(type: .outputRun, scopeId: id)
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
        LiveAPIErrorMapping.translateDomain(error) { domainError in
            guard let export = domainError as? ExportServiceError else { return nil }
            // allow: string-code（ExportServiceError 的 description 与码同源，R1 例外）
            if let code = GatherErrorCode(rawValue: export.description) {
                return GatherError(code: code, underlying: export.description)
            }
            return export
        }
    }
}

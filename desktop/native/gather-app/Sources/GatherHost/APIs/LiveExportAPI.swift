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
    /// Wave3 / task-17：S3 兼容传输（nil = 使用默认 URLSession 实现；测试可注入假传输）。
    private let s3ShareTransport: (any OutputShareTransport)?
    /// Wave3 / task-21：整套交付完成后的命令钩子（nil = 未接线/未配置）。
    private let postCommand: ExportPostCommandHook?

    /// @unchecked Sendable 依据：两个依赖都是构造后不再变更的 let；
    /// ExportService 的取消位由内部 NSLock 串行化，JobService 的任务表同样由
    /// 内部锁保护（与组合根同一约定）。
    public init(
        exportService: ExportService,
        jobService: JobService,
        webDAVPublisher: WebDAVPublisher? = nil,
        webDAVCredentialSaver: (@Sendable (URL, String, String) throws -> Bool)? = nil,
        webDAVCredentialLookup: (@Sendable (URL, String) -> String?)? = nil,
        s3ShareTransport: (any OutputShareTransport)? = nil,
        postCommand: ExportPostCommandHook? = nil
    ) {
        self.exportService = exportService
        self.jobService = jobService
        self.webDAVPublisher = webDAVPublisher
        self.webDAVCredentialSaver = webDAVCredentialSaver
        self.webDAVCredentialLookup = webDAVCredentialLookup
        self.s3ShareTransport = s3ShareTransport
        self.postCommand = postCommand
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
        return try saveCredential(
            url, input.username,
            Self.packStoredCredential(
                secret: input.password, sessionToken: input.sessionToken))
    }

    // MARK: - 分享凭据打包（secret + 可选 session token 同一条 Keychain item）

    private struct StoredShareCredential: Codable {
        var secret: String
        var sessionToken: String?
    }

    /// 把 secret（+可选 session token）打包成一条 Keychain 字符串。
    ///
    /// 不新增 Keychain schema/不改 WebDAV 凭据存储实现：无 token 时仍存旧格式明文
    ///（旧凭据/旧版本读回逐字兼容）；有 token 时存 JSON 对象（包含 secret）。
    static func packStoredCredential(secret: String, sessionToken: String?) -> String {
        let token = (sessionToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return secret }
        let payload = StoredShareCredential(secret: secret, sessionToken: token)
        do {
            let data = try JSONEncoder().encode(payload)
            guard let text = String(data: data, encoding: .utf8) else { return secret }
            return text
        } catch {
            // 打包失败时退回旧格式（secret 仍然只进 Keychain；token 会丢失，
            // 发布端会因缺 token 得到可诊断的 403，而不是静默发错凭据）。
            return secret
        }
    }

    /// 解包 Keychain 字符串：旧格式明文 → secret，token = nil；新格式 JSON → 两者。
    static func unpackStoredCredential(_ stored: String) -> (secret: String, sessionToken: String?) {
        guard stored.hasPrefix("{"), let data = stored.data(using: .utf8) else {
            return (stored, nil)
        }
        do {
            let decoded = try JSONDecoder().decode(StoredShareCredential.self, from: data)
            let token = decoded.sessionToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (decoded.secret, token?.isEmpty == true ? nil : token)
        } catch {
            return (stored, nil)
        }
    }

    public func publish(
        _ input: Confirmed<WebDAVPublishInput>,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> WebDAVPublishSummary {
        let payload = input.value
        // Wave3：transport 可选且默认 webdav——旧调用/旧行为逐字不变；
        // S3 分支复用同一份凭据通道（Keychain，key = canonical endpoint + accessKeyID）。
        switch payload.transport ?? .webdav {
        case .webdav:
            guard let publisher = webDAVPublisher else {
                throw GatherError(code: .INVALID_PARAM, params: [
                    "field": "webdav", "reason": "publisher not wired",
                ])
            }
            let url = try Self.requireHTTPURL(payload.baseURL)
            let stored = webDAVCredentialLookup?(url, payload.username) ?? ""
            let password = Self.unpackStoredCredential(stored).secret
            // Wave4b：生产路径统一走 OutputSharePublisher facade（校验/分派/结果分类
            // 与 S3 同源），WebDAV 仍由既有 WebDAVPublisher 执行上传/重试/探针。
            let request = OutputSharePublishRequest(
                localPath: payload.localPath,
                transport: .webdav,
                endpoint: payload.baseURL,
                accessKeyID: payload.username,
                secret: password,
                remoteFolder: payload.remoteFolder,
                includePrefixes: payload.includePrefixes,
                share: payload.share)
            let facade = OutputSharePublisher(transports: [
                .webdav: WebDAVShareTransport(publisher: publisher),
            ])
            let result = try await facade.publish(request, onProgress: onProgress)
            return Self.summary(from: result)
        case .s3:
            let bucket = (payload.bucket ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bucket.isEmpty else {
                throw GatherError(code: .INVALID_PARAM, params: [
                    "field": "bucket", "reason": "must not be empty",
                ])
            }
            // endpoint 可空（AWS 默认由 bucket+region 推导）；Keychain 键与 UI 保存时一致。
            let canonicalEndpoint = S3ShareAddressing.canonicalEndpoint(
                baseURL: payload.baseURL, bucket: bucket, region: payload.region)
            let credentialURL = try Self.requireHTTPURL(canonicalEndpoint)
            let stored = webDAVCredentialLookup?(credentialURL, payload.username) ?? ""
            let credential = Self.unpackStoredCredential(stored)
            let inputToken = (payload.sessionToken ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionToken = inputToken.isEmpty ? credential.sessionToken : inputToken
            let request = OutputSharePublishRequest(
                localPath: payload.localPath,
                transport: .s3,
                endpoint: payload.baseURL,
                accessKeyID: payload.username,
                secret: credential.secret,
                remoteFolder: payload.remoteFolder,
                bucket: bucket,
                region: payload.region,
                sessionToken: sessionToken,
                includePrefixes: payload.includePrefixes,
                share: payload.share)
            let s3 = s3ShareTransport ?? S3ShareTransport()
            let facade = OutputSharePublisher(transports: [.s3: s3])
            let result = try await facade.publish(request, onProgress: onProgress)
            return Self.summary(from: result)
        }
    }

    private static func requireHTTPURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            throw GatherError(code: .INVALID_PARAM, params: [
                "field": "baseURL", "reason": "must be http(s)",
            ])
        }
        return url
    }

    private static func summary(from result: OutputSharePublishResult) -> WebDAVPublishSummary {
        WebDAVPublishSummary(
            uploaded: result.uploaded,
            failed: result.failed.map { WebDAVPublishFailureInfo(path: $0.path, reason: $0.reason) },
            remoteRoot: result.remoteRoot,
            abortedOnAuth: result.abortedOnAuth)
    }

    /// job 创建即终态 = dedupe 命中旧结果（缓存重放），不是本次新执行。
    static func isTerminalJobStatus(_ status: AnalysisJobStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .cancelled, .interrupted:
            return true
        case .queued, .running, .cancelling:
            return false
        }
    }

    /// 导出后钩子的执行判据（Wave4a-C3）。
    ///
    /// 只在「本次确实新跑完一次成功交付」时执行：取消、manifest 写失败、
    /// 有失败配方、manifest 路径为空、dedupe 缓存重放 — 全部不执行，
    /// 避免用户命令（上传/同步类）在失败或重复结果上产生错误/重复副作用。
    static func shouldRunPostCommand(
        for result: OutputRunSummary, cachedReplay: Bool
    ) -> Bool {
        guard !cachedReplay else { return false }
        guard result.cancelled != true else { return false }
        guard result.manifestError == nil else { return false }
        guard result.totalFailed == 0 else { return false }
        guard !result.manifestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
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
            /// .selected 的实际成员必须进入身份；否则同会话/同配方/同目录下
            /// 换一批选择仍命中旧 queued/running job，按旧选择出片。
            var selectedPhotoIds: [String]?
            var destinationRoot: String
            var recipes: [OutputRecipe]
        }
        let identity = Identity(
            sessionId: input.sessionId,
            scope: input.scope,
            selectedPhotoIds: input.selectedPhotoIds?.sorted(),
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
            // dedupe 命中「已终态」job 时 create 直接返回旧行：这是缓存重放，
            // 钩子的外部副作用不能重复执行（见 shouldRunPostCommand）。
            let cachedReplay = Self.isTerminalJobStatus(job.status)
            let decoded: OutputRunSummary? = try await self.jobService.waitForResult(jobId: job.id)
            guard let decoded else {
                throw JobServiceError.jobFailed(job.id, "empty output.run result")
            }
            var result = decoded
            // Wave3 / task-21：整套交付成功后执行用户配置的钩子。
            // 判据（Wave4a-C3）：非取消、manifest 成功、无失败配方、manifest 路径有效，
            // 且不是 dedupe 缓存重放；钩子失败只进结果与日志，不改交付结论。
            if Self.shouldRunPostCommand(for: result, cachedReplay: cachedReplay),
               let postCommand {
                if let outcome = await postCommand.runIfConfigured(
                    sessionId: payload.sessionId,
                    destinationRoot: payload.destinationRoot,
                    manifestPath: result.manifestPath) {
                    // Wave4b 脱敏：runner 内部已把原始 outcome 写进 manifest；
                    // 这里再以脱敏后的副本覆盖一次（命令模板/输出尾部可能含 token）。
                    // 未命中敏感模式时 outcome 不变，无需二次写盘。
                    let redacted = OutputPostCommandRedaction.redacted(outcome)
                    if redacted != outcome {
                        ExportPostCommandRunner.attach(
                            redacted, toManifestAt: result.manifestPath)
                    }
                    result.postCommand = redacted
                }
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

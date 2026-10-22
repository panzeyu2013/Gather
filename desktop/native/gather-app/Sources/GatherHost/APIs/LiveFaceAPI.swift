// desktop/native/gather-app/Sources/GatherHost/APIs/LiveFaceAPI.swift
// Cut 1 / B4a：FaceAPI 的 Live 实现（13 个方法）。
//
// 对应命令（14 条）：fkw.clusters / bind / merge / remove_member / analyze /
// recluster / cancel_analysis / unbind / preview / writeback / confirm_sync /
// cleanup、fkw.confirm_cleanup（M4 合并进 cleanup）、face.models_status。
//
// 校验归属：
// - 输入类型已完成 sessionId/roleName/clusterId/eps/minSamples 的形状与范围校验
//   （D-012：显式 GatherError，不静默降级）；本实现只补“裸字符串参数”的
//   sessionId 非空白 + 长度上限（对齐 LiveAPIInput.requireSessionId）；
// - 破坏性入口只接收 Confirmed<T>（unbind / writeback / cleanup，M4 后
//   confirm_cleanup 与 cleanup 同一实现），内部固定传 confirmed: true：
//   类型层面已经保证“没有确认弹窗就写不出调用点”（D-011）；
// - eps/minSamples 的缺省值仍读设置（default_eps / default_min_samples），
//   detector/encoder 路径读 detector_model_path / encoder_model_path，与旧
//   旧实现的解析顺序一致；读到脏值时先经 validateFaceClusteringParameters
//   显式失败（FACE_EPS_INVALID / FACE_MIN_CLUSTER_INVALID），不把非法设置
//   带进 job；
// - 簇归属、自合并、成员归属、写回提供者、分析互斥仍由 FaceKwService 负责，
//   本文件不复制这些规则。
//
// 任务语义（沿用旧命令面）：
// - analyze：JobService.create(.faceAnalyze) → waitForResult；dedupeKey 与
//   checkpoint 逐字保留（detectorPath/encoderPath/eps/minSamples；缺省项写
//   null，由 executor 再读设置）。空结果视为 job 失败（empty fkw.analyze
//   result），与旧命令面 的 JobServiceError.jobFailed 一致；
// - recluster：只重聚类、不重推理，直接 await FaceKwService.recluster；
// - cancelAnalysis：jobService.cancelScope(.faceAnalyze) + FaceKwService.cancel。
//
// 输出类型：preview/writeback/cleanup 复用 Protocol 的 WritebackPreview /
// WritebackResult / CleanupResult；FaceKw* 接缝类型在文件末尾做等值搬运
// （字段逐字同源，见 FaceKwWritebackBridge）。Cut 2 统一 delivery 后这层适配
// 会随 FaceKwService 的端口一起收敛。
//
// modelsStatus：走 FaceInferenceConfig（fallbackToOnnxEnabled / 嵌入模型路径），
// provider 取 FaceProvider.vision —— 旧命令返回的 "coreml" 是 ONNX 时代的
// 固定字符串，FaceProvider.resolve 两者等价；UI 只消费 modelsPresent。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveFaceAPI: FaceAPI, @unchecked Sendable {
    private let faceKwService: FaceKwService
    private let jobService: JobService
    private let settingsService: SettingsService

    /// @unchecked Sendable 依据：三个依赖都是构造后不再变更的 let；
    /// FaceKwService 的控制器表由 NSLock 保护，JobService/SettingsService 的
    /// 可变状态各自由内部锁串行化（与组合根同一约定）。
    public init(
        faceKwService: FaceKwService,
        jobService: JobService,
        settingsService: SettingsService
    ) {
        self.faceKwService = faceKwService
        self.jobService = jobService
        self.settingsService = settingsService
    }

    // MARK: - 读

    public func clusters(_ sessionId: String) async throws -> [FaceClusterData] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map { try faceKwService.getClusters(sessionId: id) }
    }

    // MARK: - 绑定 / 合并 / 成员

    public func bind(_ input: FaceBindInput) async throws {
        try map {
            try faceKwService.bindCluster(
                sessionId: input.sessionId,
                clusterId: Int64(input.clusterId),
                roleName: input.roleName,
                keywords: input.keywords
            )
        }
    }

    public func merge(_ input: FaceMergeInput) async throws {
        try map {
            try faceKwService.mergeClusters(
                sessionId: input.sessionId,
                sourceId: Int64(input.source),
                targetId: Int64(input.target)
            )
        }
    }

    public func removeMember(_ input: FaceRemoveMemberInput) async throws {
        try map {
            try faceKwService.removeMember(
                sessionId: input.sessionId,
                clusterId: Int64(input.clusterId),
                memberId: Int64(input.memberId)
            )
        }
    }

    // MARK: - 分析 / 重聚类 / 取消

    /// fkw.analyze：建 job + 等待结果（dedupeKey/checkpoint 与旧命令面 逐字一致）。
    public func analyze(_ input: FaceAnalyzeInput) async throws -> FaceAnalysisResult {
        let detectorPath = input.detectorPath
            ?? settingsService.get("detector_model_path", defaultValue: "models/face_detector.onnx")
        let encoderPath = input.encoderPath
            ?? settingsService.get("encoder_model_path", defaultValue: "models/face_encoder.onnx")
        // 缺省值来自设置：先在 API 边界显式校验，避免脏设置把非法参数带进 job。
        let resolvedEps = input.eps ?? settingsService.getNumber("default_eps", defaultValue: 0.6)
        let resolvedMinPts = input.minSamples.map(Double.init)
            ?? settingsService.getNumber("default_min_samples", defaultValue: 2)
        try map { try validateFaceClusteringParameters(eps: resolvedEps, minPts: resolvedMinPts) }

        let job = try map {
            try jobService.create(JobCreateParams(
                type: .faceAnalyze,
                scopeType: "session",
                scopeId: input.sessionId,
                // 旧命令面 的 dedupeKey 用未解析的缺省字面量（0.6 / 2），
                // 保证“设置变了但请求参数没变”仍命中同一条去重键。
                dedupeKey: "face.analyze:\(input.sessionId):\(detectorPath):\(encoderPath):"
                    + "\(Double(input.eps ?? 0.6)):\(Double(input.minSamples ?? 2))",
                checkpoint: [
                    "detectorPath": .string(detectorPath),
                    "encoderPath": .string(encoderPath),
                    "eps": input.eps.map { .number($0) } ?? .null,
                    "minSamples": input.minSamples.map { .number(Double($0)) } ?? .null,
                ]
            ))
        }
        let result: FaceAnalysisResult? = try await mapAsync {
            try await jobService.waitForResult(jobId: job.id)
        }
        guard let result else {
            throw JobServiceError.jobFailed(job.id, "empty fkw.analyze result")
        }
        return result
    }

    /// fkw.recluster：仅重聚类（不重推理），与旧命令面 一样直接 await 服务。
    public func recluster(_ input: FaceReclusterInput) async throws {
        let resolvedEps = input.eps ?? settingsService.getNumber("default_eps", defaultValue: 0.6)
        let resolvedMinPts = input.minSamples.map(Double.init)
            ?? settingsService.getNumber("default_min_samples", defaultValue: 2)
        try map { try validateFaceClusteringParameters(eps: resolvedEps, minPts: resolvedMinPts) }
        try await mapAsync {
            try await faceKwService.recluster(
                sessionId: input.sessionId,
                eps: resolvedEps,
                minPts: resolvedMinPts
            )
        }
    }

    /// fkw.cancel_analysis：job 批量取消 + 服务层 abort，返回 void（旧命令 {done}）。
    public func cancelAnalysis(_ sessionId: String) async throws {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        _ = try map { try jobService.cancelScope(type: .faceAnalyze, scopeId: id) }
        faceKwService.cancel(sessionId: id)
    }

    // MARK: - 破坏性（Confirmed<T>，内部固定 confirmed: true）

    public func unbind(_ input: Confirmed<FaceUnbindInput>) async throws -> FkwUnbindResult {
        let payload = input.value
        return try await mapAsync {
            try await faceKwService.unbind(
                sessionId: payload.sessionId,
                clusterId: Int64(payload.clusterId),
                confirmed: true
            )
        }
    }

    public func preview(_ input: FacePreviewInput) async throws -> WritebackPreview {
        // 旧命令面 对缺省 options 传空对象（FaceKwWritebackOptions()）；
        // 保留这一形状，避免提供者把 nil 当成另一套默认策略。
        let options = input.options.map(Self.toFaceKwOptions) ?? FaceKwWritebackOptions()
        let preview = try await mapAsync {
            try await faceKwService.preview(sessionId: input.sessionId, options: options)
        }
        return Self.toWritebackPreview(preview)
    }

    public func writeback(_ input: Confirmed<FaceWritebackInput>) async throws -> WritebackResult {
        let payload = input.value
        let items = payload.items.map(FaceKwWritebackBridge.toFaceKwItem)
        let result = try await mapAsync {
            try await faceKwService.writeback(
                sessionId: payload.sessionId,
                confirmed: true,
                items: items
            )
        }
        return Self.toWritebackResult(result)
    }

    public func confirmSync(_ sessionId: String) async throws -> Bool {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try await mapAsync {
            try await faceKwService.confirmSync(sessionId: id)
        }
    }

    public func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        let sessionId = input.value.sessionId
        let result = try await mapAsync {
            try await faceKwService.cleanup(sessionId: sessionId, confirmed: true)
        }
        return CleanupResult(deletedCount: result.deletedCount, errors: result.errors)
    }

    // MARK: - 模型状态

    public func modelsStatus() async throws -> FaceModelsStatus {
        // 配置层（FaceInferenceConfig）是 fallback 开关与嵌入模型路径的唯一来源；
        // 这里只补“文件是否存在”的宿主判定（与旧命令的读法一致）。
        let config = FaceInferenceConfig(
            faceEmbeddingModelPath: settingsService.get(
                FaceEmbeddingModelFactory.modelPathSetting,
                defaultValue: ""
            )
        )
        let configuredPath = config.faceEmbeddingModelPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = configuredPath.isEmpty
            ? FaceEmbeddingModelFactory.bundledModelURL
            : URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath()
        return FaceModelsStatus(
            provider: FaceProvider.vision.rawValue,
            fallbackToOnnxEnabled: config.fallbackToOnnxEnabled,
            modelsPresent: url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            downloading: false
        )
    }

    // MARK: - 校验与错误映射

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

    /// FaceKwServiceError / JobServiceError / DBError → GatherError：
    /// - 有专用码的域错误保持码值；
    /// - jobFailed 的 message 若本身就是错误码（executor 失败落库的形状），
    ///   还原成带码的 GatherError；否则原样抛出（D-030：非域错误不伪造业务码）；
    /// - 写回提供者未注入是装配错误（GatherError 无 unspecified 码，D-010），
    ///   原样抛出，避免伪装成“其他模块占用”。
    /// 域臂：FaceKwServiceError；writebackProviderMissing 原样抛（保持原语义）。
    private static func translate(_ error: Error) -> Error {
        LiveAPIErrorMapping.translateDomain(error) { domainError in
            guard let face = domainError as? FaceKwServiceError else { return nil }
            if case .writebackProviderMissing = face { return face }
            return GatherError(code: face.gatherCode, underlying: face.description)
        }
    }

    // MARK: - 接缝类型搬运（FaceKw* 与 Protocol Writeback* 互转）

    private static func toFaceKwOptions(_ options: WritebackOptions) -> FaceKwWritebackOptions {
        FaceKwWritebackOptions(
            createAlbums: options.createAlbums,
            addPrefix: options.addPrefix,
            markUngrouped: options.markUngrouped,
            writeIPTC: options.writeIPTC
        )
    }

    private static func toWritebackPreview(_ preview: FaceKwWritebackPreview) -> WritebackPreview {
        WritebackPreview(
            items: preview.items.map(FaceKwWritebackBridge.toWritebackItem),
            totalCount: preview.totalCount,
            affectedPhotos: preview.affectedPhotos
        )
    }

    private static func toWritebackResult(_ result: FaceKwWritebackResult) -> WritebackResult {
        WritebackResult(
            totalAffected: result.totalAffected,
            written: result.written,
            failed: result.failed,
            skipped: result.skipped,
            errors: result.errors,
            failedItems: result.failedItems.map(FaceKwWritebackBridge.toWritebackItem),
            report: result.report
        )
    }
}

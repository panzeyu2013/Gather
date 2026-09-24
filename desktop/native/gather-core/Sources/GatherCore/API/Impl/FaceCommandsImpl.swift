// API/Impl/FaceCommandsImpl.swift
// R5 命令层接线：face 域实现（批次 B6）。
// 逻辑来源：宿主路由层的 fkw.* / face.models_status 分支；命令清单为
// analyze / cancel_analysis / recluster / clusters / bind / unbind / merge /
// remove_member / preview / writeback / confirm_sync / confirm_cleanup / cleanup /
// models_status；错误码、门控、返回形状与缺省逐字保留：
// - analyze：detectorPath / encoderPath 缺省走设置项；eps / minSamples 缺省仅参与
//   校验（checkpoint 缺省为 null，由作业 executor 侧再解析）；建 face.analyze 作业
//   （dedupeKey / checkpoint 与旧分支逐字一致）后等待结果，结果为空抛 jobFailed；
// - cancel_analysis：取消 face.analyze 作用域作业 + 运行时在飞分析；两侧错误照旧
//   吞掉、本协议返回空（旧响应恒 {done:true}）；
// - recluster：eps / minSamples 缺省走设置项（0.6 / 2），先校验后同步重聚类；
// - clusters：运行时 FaceClusterData 投影为 Protocol/Face.swift 的 FaceCluster
//   （syncedToLibrary / matchedPersonId / matchConfidence 旧分支不返回，保持 nil）；
// - bind / merge / remove_member：类型化入参收窄为 Int64 后交给运行时，关键词的
//   JSON 数组校验属契约层职责（类型化入参已强约束，与运行时注释裁决一致）；
// - unbind / writeback / confirm_cleanup / cleanup（破坏性）：各自先做 confirmed
//   门控（FKW_UNBIND_CONFIRM_REQUIRED / WRITEBACK_CONFIRM_REQUIRED /
//   FKW_CLEANUP_CONFIRM_REQUIRED），再交运行时执行；
// - preview / writeback / confirm_sync / cleanup：运行时 FaceKwWriteback* 与
//   Protocol/Core.swift 的 Writeback* 字段同源、仅 Swift 类型不同，本文件承载
//   等值映射（dirtyFields 字符串 ↔ 枚举、id Int64 ↔ Int、attributes 同形）；
// - models_status：旧内联形状恒 modelsPresent=true / downloading=false（Vision
//   provider 无需模型资产）；按协议基线折叠为 detector/encoder 均 present，路径取
//   设置项 detector_model_path / encoder_model_path；
// - 作业 executor（face.analyze 的推理主体）仍由宿主组合根注册到同一 JobRunner，
//   本实现不重复注册。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// face 域命令实现：注入人脸关键字运行时、作业运行器与设置快照。
public actor FaceCommandsImpl: FaceCommands {
    private let face: FaceKeywordingRuntime
    private let jobs: JobRunner
    private let settings: SettingsSnapshot

    public init(face: FaceKeywordingRuntime, jobs: JobRunner, settings: SettingsSnapshot) {
        self.face = face
        self.jobs = jobs
        self.settings = settings
    }

    // MARK: - analyze

    /// 旧命令：`fkw.analyze`。校验用缺省走设置项；dedupeKey 的缺省回退与旧分支
    /// 逐字一致（0.6 / 2），checkpoint 保留显式值（缺省 null）。
    public func analyze(_ params: FkwAnalyzeParams) async throws
        -> (status: String, detectionFailures: Int, encodingFailures: Int) {
        let sessionId = params.sessionId
        let eps = params.eps
        let minSamples = params.minSamples.map(Double.init)
        let detectorPath = params.detectorPath
            ?? settings.value("detector_model_path", default: "models/face_detector.onnx")
        let encoderPath = params.encoderPath
            ?? settings.value("encoder_model_path", default: "models/face_encoder.onnx")
        try validateFaceClusteringParameters(
            eps: eps ?? settings.number("default_eps", default: 0.6),
            minPts: minSamples ?? settings.number("default_min_samples", default: 2)
        )
        let job = try await jobs.create(JobCreateParams(
            type: .faceAnalyze,
            scopeType: "session",
            scopeId: sessionId,
            dedupeKey: "face.analyze:\(sessionId):\(detectorPath):\(encoderPath):"
                + "\(eps ?? 0.6):\(minSamples ?? 2)",
            checkpoint: [
                "detectorPath": .string(detectorPath),
                "encoderPath": .string(encoderPath),
                "eps": eps.map { .number($0) } ?? .null,
                "minSamples": minSamples.map { .number($0) } ?? .null,
            ]
        ))
        let result: FaceAnalysisResult? = try await jobs.waitForResult(jobId: job.id)
        guard let result else {
            throw JobRunnerError.jobFailed(job.id, "empty fkw.analyze result")
        }
        return (
            status: result.status,
            detectionFailures: result.detectionFailures,
            encodingFailures: result.encodingFailures
        )
    }

    // MARK: - cancel_analysis

    /// 旧命令：`fkw.cancel_analysis`。取消作业作用域 + 运行时在飞分析（nonisolated
    /// 同步 abort）；取消失败照旧吞掉，本协议返回空。
    public func cancelAnalysis(_ params: FkwCancelAnalysisParams) async throws {
        _ = try? await jobs.cancelScope(type: .faceAnalyze, scopeId: params.sessionId)
        face.cancel(sessionId: params.sessionId)
    }

    // MARK: - recluster

    /// 旧命令：`fkw.recluster`。缺省走设置项，先校验后同步重聚类（不重推理）。
    public func recluster(sessionId: String, eps: Double?, minSamples: Int?) async throws {
        let epsValue = eps ?? settings.number("default_eps", default: 0.6)
        let minSamplesValue = minSamples.map(Double.init)
            ?? settings.number("default_min_samples", default: 2)
        try validateFaceClusteringParameters(eps: epsValue, minPts: minSamplesValue)
        try await face.recluster(sessionId: sessionId, eps: epsValue, minPts: minSamplesValue)
    }

    // MARK: - clusters

    /// 旧命令：`fkw.clusters`。成员截断与 size 语义由运行时承担。
    public func clusters(_ params: FkwClustersParams) async throws -> [FaceCluster] {
        try await face.getClusters(sessionId: params.sessionId).map(Self.protocolCluster)
    }

    // MARK: - bind / unbind / merge / remove_member

    /// 旧命令：`fkw.bind`。角色名归一化、关键词去重与人物库桥接由运行时承担。
    public func bind(_ params: FkwBindParams) async throws {
        try await face.bindCluster(
            sessionId: params.sessionId,
            clusterId: Int64(params.clusterId),
            roleName: params.roleName,
            keywords: params.keywords
        )
    }

    /// 旧命令：`fkw.unbind`（破坏性）。confirmed 不为 true →
    /// FKW_UNBIND_CONFIRM_REQUIRED。
    public func unbind(_ params: FkwUnbindParams) async throws -> (done: Bool, removedKeywords: [String]) {
        guard params.confirmed else {
            throw FaceCommandsError.unbindConfirmRequired
        }
        let result = try await face.unbind(
            sessionId: params.sessionId,
            clusterId: Int64(params.clusterId),
            confirmed: true
        )
        return (done: result.done, removedKeywords: result.removedKeywords)
    }

    /// 旧命令：`fkw.merge`。source == target 与簇归属由运行时校验。
    public func merge(_ params: FkwMergeParams) async throws {
        try await face.mergeClusters(
            sessionId: params.sessionId,
            sourceId: Int64(params.source),
            targetId: Int64(params.target)
        )
    }

    /// 旧命令：`fkw.remove_member`。成员不存在由运行时抛错。
    public func removeMember(_ params: FkwRemoveMemberParams) async throws {
        try await face.removeMember(
            sessionId: params.sessionId,
            clusterId: Int64(params.clusterId),
            memberId: Int64(params.memberId)
        )
    }

    // MARK: - 写回族

    /// 旧命令：`fkw.preview`。options 缺省原样传 nil（运行时接缝语义）。
    public func preview(_ params: FkwPreviewParams) async throws -> WritebackPreview {
        let preview = try await face.preview(
            sessionId: params.sessionId,
            options: params.options.map(Self.runtimeOptions)
        )
        return WritebackPreview(
            items: preview.items.map(Self.protocolItem),
            totalCount: preview.totalCount,
            affectedPhotos: preview.affectedPhotos
        )
    }

    /// 旧命令：`fkw.writeback`（破坏性）。confirmed 不为 true →
    /// WRITEBACK_CONFIRM_REQUIRED；items 为 nil 时按旧语义等价空数组。
    @discardableResult
    public func writeback(_ params: FkwWritebackParams) async throws -> WritebackResult {
        guard params.confirmed == true else {
            throw FaceCommandsError.writebackConfirmRequired
        }
        let items = (params.items ?? []).map(Self.runtimeItem)
        let result = try await face.writeback(
            sessionId: params.sessionId,
            confirmed: true,
            items: items
        )
        return WritebackResult(
            totalAffected: result.totalAffected,
            written: result.written,
            failed: result.failed,
            skipped: result.skipped,
            errors: result.errors,
            failedItems: result.failedItems.map(Self.protocolItem),
            report: result.report
        )
    }

    /// 旧命令：`fkw.confirm_sync`。旧响应恒 true，本协议返回空。
    public func confirmSync(_ params: FkwConfirmSyncParams) async throws {
        _ = try await face.confirmSync(sessionId: params.sessionId)
    }

    /// 旧命令：`fkw.confirm_cleanup`（破坏性）。confirmed 不为 true →
    /// FKW_CLEANUP_CONFIRM_REQUIRED。
    @discardableResult
    public func confirmCleanup(_ params: FkwConfirmCleanupParams) async throws -> CleanupResult {
        guard params.confirmed == true else {
            throw FaceCommandsError.cleanupConfirmRequired
        }
        let result = try await face.cleanup(sessionId: params.sessionId, confirmed: true)
        return CleanupResult(deletedCount: result.deletedCount, errors: result.errors)
    }

    /// 旧命令：`fkw.cleanup`（破坏性）。confirmed 不为 true →
    /// FKW_CLEANUP_CONFIRM_REQUIRED。
    @discardableResult
    public func cleanup(_ params: FkwCleanupParams) async throws -> CleanupResult {
        guard params.confirmed == true else {
            throw FaceCommandsError.cleanupConfirmRequired
        }
        let result = try await face.cleanup(sessionId: params.sessionId, confirmed: true)
        return CleanupResult(deletedCount: result.deletedCount, errors: result.errors)
    }

    // MARK: - models_status

    /// 旧命令：`face.models_status`。旧内联形状恒 modelsPresent=true /
    /// downloading=false（Vision provider 无需模型资产）；按协议基线折叠为
    /// detector/encoder 均 present，路径取设置项。
    public func modelsStatus() async throws -> FaceModelsStatusData {
        FaceModelsStatusData(
            detectorPresent: true,
            encoderPresent: true,
            detectorPath: settings.value(
                "detector_model_path", default: "models/face_detector.onnx"),
            encoderPath: settings.value(
                "encoder_model_path", default: "models/face_encoder.onnx")
        )
    }

    // MARK: - 类型映射（运行时接缝 ↔ Protocol 契约）

    /// FaceClusterData → FaceCluster：协议多出的同步/人物匹配字段旧分支不返回。
    private static func protocolCluster(_ cluster: FaceClusterData) -> FaceCluster {
        FaceCluster(
            id: cluster.id,
            sessionId: cluster.sessionId,
            label: cluster.label,
            size: cluster.size,
            members: cluster.members,
            status: cluster.status,
            binding: cluster.binding.map {
                BindingData(clusterId: cluster.id, roleName: $0.roleName, keywords: $0.keywords)
            },
            thumbnailBase64: cluster.thumbnailBase64
        )
    }

    /// WritebackOptions → 运行时接缝选项（字段逐字同源）。
    private static func runtimeOptions(_ options: WritebackOptions) -> FaceKwWritebackOptions {
        FaceKwWritebackOptions(
            createAlbums: options.createAlbums,
            addPrefix: options.addPrefix,
            markUngrouped: options.markUngrouped,
            writeIPTC: options.writeIPTC
        )
    }

    /// WritebackItem → 运行时接缝条目（字段逐字同源，仅 Swift 类型不同）。
    private static func runtimeItem(_ item: WritebackItem) -> FaceKwWritebackItem {
        FaceKwWritebackItem(
            id: item.id.map(Int64.init),
            photoId: item.photoId,
            photoPath: item.photoPath,
            sessionId: item.sessionId,
            module: item.module,
            keywords: item.keywords,
            attributes: item.attributes.map {
                FaceKwWritebackAttributes(
                    keywords: $0.keywords, rating: $0.rating, label: $0.label)
            },
            xmpPath: item.xmpPath,
            backupPath: item.backupPath,
            xmpStatus: item.xmpStatus,
            errorMessage: item.errorMessage,
            attemptCount: item.attemptCount,
            lastAttemptAt: item.lastAttemptAt,
            preview: item.preview.map { preview in
                FaceKwWritebackPreviewInfo(
                    dirtyFields: preview.dirtyFields.map(\.rawValue),
                    before: FaceKwWritebackAttributes(
                        keywords: preview.before.keywords,
                        rating: preview.before.rating,
                        label: preview.before.label
                    ),
                    after: FaceKwWritebackAttributes(
                        keywords: preview.after.keywords,
                        rating: preview.after.rating,
                        label: preview.after.label
                    ),
                    source: preview.source,
                    sharedPhotoCount: preview.sharedPhotoCount,
                    externalChanged: preview.externalChanged,
                    willCreate: preview.willCreate
                )
            }
        )
    }

    /// 运行时接缝条目 → WritebackItem（字段逐字同源，仅 Swift 类型不同）。
    private static func protocolItem(_ item: FaceKwWritebackItem) -> WritebackItem {
        WritebackItem(
            id: item.id.map { Int($0) },
            photoId: item.photoId,
            photoPath: item.photoPath,
            sessionId: item.sessionId,
            module: item.module,
            keywords: item.keywords,
            attributes: item.attributes.map {
                WritebackAttributes(keywords: $0.keywords, rating: $0.rating, label: $0.label)
            },
            xmpPath: item.xmpPath,
            backupPath: item.backupPath,
            xmpStatus: item.xmpStatus,
            errorMessage: item.errorMessage,
            attemptCount: item.attemptCount,
            lastAttemptAt: item.lastAttemptAt,
            preview: item.preview.map { preview in
                WritebackItemPreview(
                    dirtyFields: preview.dirtyFields.compactMap(WritebackDirtyField.init(rawValue:)),
                    before: WritebackAttributes(
                        keywords: preview.before.keywords,
                        rating: preview.before.rating,
                        label: preview.before.label
                    ),
                    after: WritebackAttributes(
                        keywords: preview.after.keywords,
                        rating: preview.after.rating,
                        label: preview.after.label
                    ),
                    source: preview.source,
                    sharedPhotoCount: preview.sharedPhotoCount,
                    externalChanged: preview.externalChanged,
                    willCreate: preview.willCreate
                )
            }
        )
    }
}

/// face 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum FaceCommandsError: Error, Equatable {
    /// 旧响应 error 串：`FKW_UNBIND_CONFIRM_REQUIRED`。
    case unbindConfirmRequired
    /// 旧响应 error 串：`WRITEBACK_CONFIRM_REQUIRED`。
    case writebackConfirmRequired
    /// 旧响应 error 串：`FKW_CLEANUP_CONFIRM_REQUIRED`。
    case cleanupConfirmRequired
}

extension FaceCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unbindConfirmRequired: "FKW_UNBIND_CONFIRM_REQUIRED"
        case .writebackConfirmRequired: "WRITEBACK_CONFIRM_REQUIRED"
        case .cleanupConfirmRequired: "FKW_CLEANUP_CONFIRM_REQUIRED"
        }
    }
}

extension FaceCommandsError {
    /// 桥接层序列化用。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .unbindConfirmRequired: .FKW_UNBIND_CONFIRM_REQUIRED
        case .writebackConfirmRequired: .WRITEBACK_CONFIRM_REQUIRED
        case .cleanupConfirmRequired: .FKW_CLEANUP_CONFIRM_REQUIRED
        }
    }
}

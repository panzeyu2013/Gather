// API/FaceCommands.swift
// R5 类型化 async 域协议：face 域（fkw.* 与 face.models_status）。
// 旧实现来源：gather-app/Sources/GatherApp/Host/路由层.swift 的 fkw.* /
// face.models_status 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO 与基础类型、无同步重载；
// 破坏性命令的 confirmed 由入参 DTO 显式携带，由实现内部校验。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// face 域命令（14 条）。
///
/// 旧命令清单：`fkw.analyze`、`fkw.cancel_analysis`、`fkw.recluster`、
/// `fkw.clusters`、`fkw.bind`、`fkw.unbind`、`fkw.merge`、`fkw.remove_member`、
/// `fkw.preview`、`fkw.writeback`、`fkw.confirm_sync`、`fkw.confirm_cleanup`、
/// `fkw.cleanup`、`face.models_status`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `fkw.analyze` 返回服务层分析结果（status / detectionFailures /
///   encodingFailures）；Protocol/ 暂无同名 DTO，本协议以同形状元组承接。
/// - 旧 `fkw.recluster` 无参数 DTO，本协议用扁平参数（sessionId / eps /
///   minSamples），缺省走设置项 default_eps / default_min_samples。
/// - 旧 `fkw.unbind` 返回 {done, removedKeywords}，同样以元组承接。
/// - 旧 `fkw.clusters` 返回服务层 FaceClusterData，本协议收敛为
///   Protocol/Face.swift 的 FaceCluster。
/// - 旧 `fkw.preview` / `fkw.writeback` / `fkw.confirm_cleanup` / `fkw.cleanup`
///   返回服务层 FaceKw 结果，本协议按 Protocol/Core.swift 的 WritebackPreview /
///   WritebackResult / CleanupResult 收敛，字段映射由实现承载。
/// - 旧 `face.models_status` 返回内联形状（provider / fallbackToOnnxEnabled /
///   modelsPresent / downloading），与 Protocol/Face.swift 的 FaceModelsStatusData
///   字段不同；本协议按 Protocol 基线返回 FaceModelsStatusData，映射由实现承载。
public protocol FaceCommands: Sendable {
    /// 旧命令：`fkw.analyze`。
    /// 建 face.analyze 作业并等待完成；返回状态与分析/编码失败计数（旧结果形状的元组投影）。
    func analyze(_ params: FkwAnalyzeParams) async throws
        -> (status: String, detectionFailures: Int, encodingFailures: Int)

    /// 旧命令：`fkw.cancel_analysis`。
    /// 取消该会话的人脸分析（旧响应 {done:true}，取消在后台完成，方法只等待提交）。
    func cancelAnalysis(_ params: FkwCancelAnalysisParams) async throws

    /// 旧命令：`fkw.recluster`。
    /// 仅重聚类不重推理；eps / minSamples 为 nil 时走设置缺省，返回空（旧 {done:true}）。
    func recluster(sessionId: String, eps: Double?, minSamples: Int?) async throws

    /// 旧命令：`fkw.clusters`。
    /// 返回该会话的人脸簇，元素为 Protocol/Face.swift 的 FaceCluster。
    func clusters(_ params: FkwClustersParams) async throws -> [FaceCluster]

    /// 旧命令：`fkw.bind`。
    /// 绑定簇到角色名与关键词；旧响应 {done:true}，本协议返回空。
    func bind(_ params: FkwBindParams) async throws

    /// 旧命令：`fkw.unbind`（破坏性）。
    /// FkwUnbindParams.confirmed 必须为 true，否则实现抛 FKW_UNBIND_CONFIRM_REQUIRED；
    /// 返回完成标记与被移除的关键词（旧结果形状的元组投影）。
    func unbind(_ params: FkwUnbindParams) async throws -> (done: Bool, removedKeywords: [String])

    /// 旧命令：`fkw.merge`。
    /// 把 source 簇并入 target 簇；旧响应 {done:true}，本协议返回空。
    func merge(_ params: FkwMergeParams) async throws

    /// 旧命令：`fkw.remove_member`。
    /// 从 clusterId 移除 memberId；旧响应 {done:true}，本协议返回空。
    func removeMember(_ params: FkwRemoveMemberParams) async throws

    /// 旧命令：`fkw.preview`。
    /// 写回预览计划（Protocol/Core.swift 的 WritebackPreview）。
    func preview(_ params: FkwPreviewParams) async throws -> WritebackPreview

    /// 旧命令：`fkw.writeback`（破坏性）。
    /// FkwWritebackParams.confirmed 必须为 true，否则实现抛 WRITEBACK_CONFIRM_REQUIRED；
    /// items 为 nil 时按旧语义等价空数组。
    @discardableResult
    func writeback(_ params: FkwWritebackParams) async throws -> WritebackResult

    /// 旧命令：`fkw.confirm_sync`。
    /// 确认写回同步；旧响应恒为 true，本协议返回空。
    func confirmSync(_ params: FkwConfirmSyncParams) async throws

    /// 旧命令：`fkw.confirm_cleanup`（破坏性）。
    /// FkwConfirmCleanupParams.confirmed 必须为 true，否则实现抛
    /// FKW_CLEANUP_CONFIRM_REQUIRED；返回清理结果。
    @discardableResult
    func confirmCleanup(_ params: FkwConfirmCleanupParams) async throws -> CleanupResult

    /// 旧命令：`fkw.cleanup`（破坏性）。
    /// FkwCleanupParams.confirmed 必须为 true，否则实现抛
    /// FKW_CLEANUP_CONFIRM_REQUIRED；返回清理结果。
    @discardableResult
    func cleanup(_ params: FkwCleanupParams) async throws -> CleanupResult

    /// 旧命令：`face.models_status`。
    /// 人脸模型与推理提供方状态（Protocol/Face.swift 的 FaceModelsStatusData）。
    func modelsStatus() async throws -> FaceModelsStatusData
}

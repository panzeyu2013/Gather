// desktop/native/gather-core/Sources/GatherProtocol/API/FaceAPI.swift
// Cut 1 / 阶段 1A：人脸关键字域协议（13 个方法）。
//
// 职责：人脸聚类读取、绑定/合并/移除成员、分析/重聚类/取消、解绑、预览与写回、
// 同步确认、清理、模型状态。
// 对应命令（14 条）：fkw.clusters / bind / merge / remove_member / analyze /
// recluster / cancel_analysis / unbind / preview / writeback / confirm_sync /
// cleanup、fkw.confirm_cleanup（M4 合并）、face.models_status。
// 校验归属：
// - eps 0...1、minSamples 1...1_000_000 在输入类型（FACE_* 码）；
// - unbind/writeback/cleanup 使用 Confirmed<T>；
// - 簇归属、自合并、写回提供者、分析互斥由 FaceKwService 负责；
// - preview/writeback/cleanup 的输出复用 Protocol 的 WritebackPreview /
//   WritebackResult / CleanupResult（1B 负责从 FaceKw* 接缝类型适配），
//   Cut 2 统一 delivery 后不再有第二套写回 DTO。
// 输出类型：FaceClusterData / FaceAnalysisResult / FkwUnbindResult 目前位于
// Services，属于稳定 Codable DTO；Cut 3 搬迁时随协议一并移入 GatherProtocol。

import Foundation

public protocol FaceAPI: Sendable {
    func clusters(_ sessionId: String) async throws -> [FaceClusterData]
    func bind(_ input: FaceBindInput) async throws
    func merge(_ input: FaceMergeInput) async throws
    func removeMember(_ input: FaceRemoveMemberInput) async throws
    func analyze(_ input: FaceAnalyzeInput) async throws -> FaceAnalysisResult
    func recluster(_ input: FaceReclusterInput) async throws
    func cancelAnalysis(_ sessionId: String) async throws
    func unbind(_ input: Confirmed<FaceUnbindInput>) async throws -> FkwUnbindResult
    func preview(_ input: FacePreviewInput) async throws -> WritebackPreview
    func writeback(_ input: Confirmed<FaceWritebackInput>) async throws -> WritebackResult
    func confirmSync(_ sessionId: String) async throws -> Bool
    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult
    func modelsStatus() async throws -> FaceModelsStatus

    // P0 / F0：拆分与复核
    func split(_ input: Confirmed<FaceSplitInput>) async throws -> FaceSplitResult
    func review(_ input: FaceReviewInput) async throws -> FaceReviewPage
}

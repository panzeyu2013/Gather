#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewAPIs.swift
// Cut 4 / 4c-1：12 个类型化 API 的**只读内存替身**（只在 DEBUG 编译）。
//
// 与 Tests/GatherAppTests/Support/Stub*.swift 的差异（有意，不是复制）：
// - 不记录调用、不注入错误、不带 LockedBox：Preview 只要求"渲染出一屏固定数据"；
// - 只有页面加载路径会用到的方法返回 fixture，其余一律 throw unavailable；
//   这样即使 Preview 里误触命令也不会产生任何真实副作用（审计 §6.2）；
// - 全部是 Sendable 值类型（struct），没有共享可变状态，可在任意隔离域调用。
//
// 页面自动加载只会走读路径：session.list/get/status、job.list、culling.page/
// summary/groups/syncStatus/history、metadata.conflicts、face.clusters/modelsStatus、
// similarity.result/writebackItems、duplicate.groups、export.preview、person.list/get、
// settings.all/mlStatus、captureOne.checkHealth/preflight。命令路径（create/delete/
// update/writeback/resolve/start/...）全部抛错，Preview 不触发真实 DB/网络。

/// Preview 替身对命令方法的统一拒绝（类型名带 Preview 前缀，避免与业务错误码混淆）。
enum PreviewAPIError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let method):
            return "Preview API 不执行命令：\(method)"
        }
    }
}

// MARK: - 会话 / 任务

struct PreviewSessionAPI: SessionAPI {
    func list() async throws -> [SessionData] { PreviewData.sessions }

    func get(_ sessionId: String) async throws -> SessionData {
        guard let session = PreviewData.sessions.first(where: { $0.id == sessionId }) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        return session
    }

    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        throw PreviewAPIError.unavailable("session.create")
    }

    func update(_ input: SessionUpdateParams) async throws -> SessionData {
        throw PreviewAPIError.unavailable("session.update")
    }

    func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        throw PreviewAPIError.unavailable("session.delete")
    }

    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        throw PreviewAPIError.unavailable("session.add_photos")
    }

    // P1 / D：摄取（stub：不碰文件系统，直接回报 0 登记）。
    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        SessionIngestResult(registered: 0, copiedButUnregistered: [], skipped: [], failed: [])
    }

    func status(_ sessionId: String) async throws -> WorkspaceStatus {
        PreviewData.workspaceStatus(sessionId)
    }
}

struct PreviewJobAPI: JobAPI {
    func list(_ filter: JobListFilter) async throws -> [AnalysisJobData] { PreviewData.jobs }

    func cancel(_ jobId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("jobs.cancel")
    }

    func retry(_ jobId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("jobs.retry")
    }

    func clearCompleted(_ input: Confirmed<ClearCompletedInput>) async throws -> Int {
        throw PreviewAPIError.unavailable("jobs.clear_completed")
    }

    func start(_ request: JobRequest) async throws -> JobHandle {
        throw PreviewAPIError.unavailable("jobs.start")
    }
}

struct PreviewSettingsAPI: SettingsAPI {
    func all() async throws -> [String: String] { PreviewData.settings }

    func get(_ key: SettingsKey) async throws -> String {
        PreviewData.settings[key.value] ?? ""
    }

    func set(_ input: SettingsSetInput) async throws {
        throw PreviewAPIError.unavailable("settings.set")
    }

    func reset() async throws -> [String: String] {
        throw PreviewAPIError.unavailable("settings.reset")
    }

    func setLanguage(_ language: InterfaceLanguage) async throws -> InterfaceLanguage {
        throw PreviewAPIError.unavailable("settings.set_language")
    }

    func mlStatus() async throws -> MLStatusData { PreviewData.mlStatus }
}

// MARK: - 挑片 / 导航

struct PreviewCullingAPI: CullingAPI {
    func page(_ query: CullingPageQuery) async throws -> CullingPage { PreviewData.cullingPage }

    func history(_ query: CullingHistoryQuery) async throws -> [CullingHistoryOperation] {
        PreviewData.cullingHistory
    }

    func groups(_ sessionId: String) async throws -> [CullingGroup] { PreviewData.cullingGroups }

    func summary(_ sessionId: String) async throws -> CullingSummary { PreviewData.cullingSummary }

    func generateTriage(_ input: TriageGenerateInput) async throws -> TriageSummary {
        throw PreviewAPIError.unavailable("culling.generate_triage")
    }

    func applyTriage(_ input: Confirmed<TriageApplyInput>) async throws -> TriageApplyResult {
        throw PreviewAPIError.unavailable("culling.apply_triage")
    }

    // P1 / D：淘汰移动（stub：直接回成功，不碰文件系统）。
    func moveRejected(_ input: Confirmed<CullingMoveRejectedInput>) async throws -> CullingMoveRejectedResult {
        CullingMoveRejectedResult(moved: input.value.photoIds, newPaths: [], failed: [])
    }

    func syncStatus(_ sessionId: String) async throws -> CullingSyncStatus {
        PreviewData.cullingSyncStatus
    }

    func applyHistory(_ input: CullingApplyHistoryInput) async throws -> [CullingUpdateResult] {
        throw PreviewAPIError.unavailable("culling.apply_history")
    }

    func update(_ input: CullingUpdateInput) async throws -> CullingUpdateResult {
        throw PreviewAPIError.unavailable("culling.update")
    }

    func batchUpdate(_ input: CullingBatchUpdateInput) async throws -> [CullingUpdateResult] {
        throw PreviewAPIError.unavailable("culling.batch_update")
    }

    func decideGroup(_ input: CullingDecideGroupInput) async throws -> [CullingUpdateResult] {
        throw PreviewAPIError.unavailable("culling.decide_group")
    }

    func reset(_ input: Confirmed<CullingResetInput>) async throws -> Bool {
        throw PreviewAPIError.unavailable("culling.reset")
    }

    func writeback(_ input: Confirmed<CullingWritebackInput>) async throws -> WritebackResult {
        throw PreviewAPIError.unavailable("culling.writeback")
    }

    func flush(_ sessionId: String) async throws -> MetadataSyncSummary {
        throw PreviewAPIError.unavailable("culling.flush")
    }

    func retrySync(_ sessionId: String) async throws -> MetadataSyncSummary {
        throw PreviewAPIError.unavailable("culling.retry_sync")
    }

    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult {
        throw PreviewAPIError.unavailable("culling.retry_failed_writeback")
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        throw PreviewAPIError.unavailable("culling.cleanup")
    }

    func finalizeSync(_ input: Confirmed<SessionReference>) async throws -> MetadataSyncSummary {
        throw PreviewAPIError.unavailable("culling.finalize_sync")
    }

    func confirmSync(_ sessionId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("culling.confirm_sync")
    }
}

struct PreviewNavigationAPI: NavigationAPI {
    func list(_ sessionId: String) async throws -> [NavigationGroup] { PreviewData.navigationGroups }

    func split(_ input: NavigationSplitParams) async throws -> [NavigationGroup] {
        throw PreviewAPIError.unavailable("navigation.split")
    }

    func merge(_ input: NavigationMergeParams) async throws -> [NavigationGroup] {
        throw PreviewAPIError.unavailable("navigation.merge")
    }

    func analyze(_ input: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        throw PreviewAPIError.unavailable("navigation.analyze")
    }
}

// MARK: - 元数据 / 画质

struct PreviewMetadataAPI: MetadataAPI {
    func metadata(_ photoId: String) async throws -> PhotoMetadataDetail {
        throw PreviewAPIError.unavailable("metadata.detail")
    }

    func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async throws -> TriageWritebackResult {
        throw PreviewAPIError.unavailable("metadata.apply_triage_writeback")
    }

    func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> TriageWritebackResult {
        throw PreviewAPIError.unavailable("metadata.undo_triage_writeback")
    }

    // P1 / B2：模板（预览态一律不可用，避免 SwiftUI Preview 触发真实写盘）。
    func templates() async throws -> [MetadataTemplateSummary] { [] }

    func saveTemplate(_ input: MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary {
        throw PreviewAPIError.unavailable("metadata.save_template")
    }

    func templateFields(id: String) async throws -> DescriptiveMetadata {
        throw PreviewAPIError.unavailable("metadata.template_fields")
    }

    func deleteTemplate(_ input: Confirmed<MetadataTemplateDeleteInput>) async throws {
        throw PreviewAPIError.unavailable("metadata.delete_template")
    }

    func previewTemplate(_ input: MetadataTemplatePreviewInput) async throws -> MetadataTemplatePreviewResult {
        throw PreviewAPIError.unavailable("metadata.preview_template")
    }

    func applyTemplate(_ input: Confirmed<MetadataTemplateApplyInput>) async throws -> MetadataTemplateApplyOutcome {
        throw PreviewAPIError.unavailable("metadata.apply_template")
    }

    func undoTemplate(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> MetadataTemplateApplyOutcome {
        throw PreviewAPIError.unavailable("metadata.undo_template")
    }

    func recentBatches(limit: Int) async throws -> [MetadataBatchSummary] { [] }

    func conflicts(_ sessionId: String) async throws -> [MetadataConflict] { PreviewData.conflicts }

    func orphans() async throws -> [MetadataOrphan] { PreviewData.orphanXMPs }

    func resolveConflict(_ input: Confirmed<MetadataResolveConflictInput>) async throws -> MetadataSyncSummary {
        throw PreviewAPIError.unavailable("metadata.resolve_conflict")
    }

    func resolveOrphan(_ input: Confirmed<MetadataResolveOrphanInput>) async throws -> [MetadataOrphan] {
        throw PreviewAPIError.unavailable("metadata.resolve_orphan")
    }

    func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview {
        throw PreviewAPIError.unavailable("metadata.preview_keywords")
    }

    func applyKeywords(_ input: Confirmed<MetadataKeywordApplyInput>) async throws -> MetadataKeywordApplyResult {
        throw PreviewAPIError.unavailable("metadata.apply_keywords")
    }

    func retryKeywordWriteback(_ input: Confirmed<SessionReference>) async throws -> MetadataKeywordApplyResult {
        throw PreviewAPIError.unavailable("metadata.retry_keywords")
    }
}

struct PreviewQualityAPI: QualityAPI {
    func analyze(_ input: QualityAnalyzeInput) async throws -> AnalysisJobData {
        throw PreviewAPIError.unavailable("quality.analyze")
    }

    func results(_ query: QualityGetParams) async throws -> [QualityResult] { [] }
}

// MARK: - 人脸 / 相似度

struct PreviewFaceAPI: FaceAPI {
    func clusters(_ sessionId: String) async throws -> [FaceClusterData] { PreviewData.faceClusters }

    func split(_ input: Confirmed<FaceSplitInput>) async throws -> FaceSplitResult {
        throw PreviewAPIError.unavailable("fkw.split")
    }

    func review(_ input: FaceReviewInput) async throws -> FaceReviewPage {
        FaceReviewPage(items: [], nextCursor: nil, total: 0, suspectTotal: 0, clusters: [])
    }

    func modelsStatus() async throws -> FaceModelsStatus { PreviewData.faceModelsStatus }

    func preview(_ input: FacePreviewInput) async throws -> WritebackPreview {
        PreviewData.faceWritebackPreview
    }

    func writeback(_ input: Confirmed<FaceWritebackInput>) async throws -> WritebackResult {
        PreviewData.faceWritebackResult
    }

    func confirmSync(_ sessionId: String) async throws -> Bool { true }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        CleanupResult(deletedCount: 0, errors: [])
    }

    func bind(_ input: FaceBindInput) async throws {
        throw PreviewAPIError.unavailable("fkw.bind")
    }

    func merge(_ input: FaceMergeInput) async throws {
        throw PreviewAPIError.unavailable("fkw.merge")
    }

    func removeMember(_ input: FaceRemoveMemberInput) async throws {
        throw PreviewAPIError.unavailable("fkw.remove_member")
    }

    func analyze(_ input: FaceAnalyzeInput) async throws -> FaceAnalysisResult {
        throw PreviewAPIError.unavailable("fkw.analyze")
    }

    func recluster(_ input: FaceReclusterInput) async throws {
        throw PreviewAPIError.unavailable("fkw.recluster")
    }

    func cancelAnalysis(_ sessionId: String) async throws {
        throw PreviewAPIError.unavailable("fkw.cancel_analysis")
    }

    func unbind(_ input: Confirmed<FaceUnbindInput>) async throws -> FkwUnbindResult {
        throw PreviewAPIError.unavailable("fkw.unbind")
    }
}

struct PreviewSimilarityAPI: SimilarityAPI {
    func result(_ query: SimilarityResultQuery) async throws -> SimilarityResult? {
        PreviewData.similarityResult
    }

    func writebackItems(_ sessionId: String) async throws -> [WritebackItem] {
        PreviewData.similarityWritebackItems
    }

    func previewWriteback(_ input: SimilarityPreviewWritebackInput) async throws -> WritebackPreview {
        PreviewData.similarityWritebackPreview
    }

    func analyze(_ input: SimilarityAnalyzeInput) async throws -> Bool {
        throw PreviewAPIError.unavailable("sim.analyze")
    }

    func recluster(_ input: SimilarityAnalyzeInput) async throws -> SimilarityResult? {
        throw PreviewAPIError.unavailable("sim.recluster")
    }

    func cancelAnalysis(_ sessionId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("sim.cancel_analysis")
    }

    func writeback(_ input: Confirmed<SimilarityWritebackInput>) async throws -> WritebackResult {
        throw PreviewAPIError.unavailable("sim.writeback")
    }

    func confirmSync(_ sessionId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("sim.confirm_sync")
    }

    func retryFailedWriteback(_ input: Confirmed<SessionReference>) async throws -> WritebackResult {
        throw PreviewAPIError.unavailable("sim.retry_failed_writeback")
    }

    func cleanup(_ input: Confirmed<SessionReference>) async throws -> CleanupResult {
        throw PreviewAPIError.unavailable("sim.cleanup")
    }
}

// MARK: - 重复 / 导出 / 人物 / C1

struct PreviewDuplicateAPI: DuplicateAPI {
    func groups(_ sessionId: String) async throws -> [DuplicateGroup] { PreviewData.duplicateGroups }

    func scan(_ input: DuplicateScanInput) async throws -> DuplicateScanResult {
        PreviewData.duplicateScanResult
    }

    func resolve(_ input: Confirmed<DuplicateResolveInput>) async throws -> Bool {
        throw PreviewAPIError.unavailable("dup.resolve")
    }

    func resolveMember(_ input: Confirmed<DuplicateResolveMemberInput>) async throws -> Bool {
        throw PreviewAPIError.unavailable("dup.resolve_member")
    }
}

struct PreviewExportAPI: ExportAPI {
    func preview(_ input: ExportInput) async throws -> ExportPreview { PreviewData.exportPreview }

    func execute(_ input: Confirmed<ExportInput>) async throws -> ExportResult {
        throw PreviewAPIError.unavailable("export.execute")
    }

    func cancel(_ sessionId: String) async throws -> Bool {
        throw PreviewAPIError.unavailable("export.cancel")
    }

    func report(_ input: ExportReportInput) async throws -> ReportData {
        throw PreviewAPIError.unavailable("export.report")
    }
}

struct PreviewPersonAPI: PersonAPI {
    func list() async throws -> [PersonData] { PreviewData.persons }

    func get(_ personId: String) async throws -> PersonDetailData {
        PreviewData.personDetail(personId)
    }

    func create(_ input: PersonCreateParams) async throws -> PersonCreateResult {
        throw PreviewAPIError.unavailable("person.create")
    }

    func update(_ input: PersonUpdateParams) async throws {
        throw PreviewAPIError.unavailable("person.update")
    }

    func delete(_ input: Confirmed<PersonDeleteInput>) async throws {
        throw PreviewAPIError.unavailable("person.delete")
    }

    func merge(_ input: Confirmed<PersonMergeInput>) async throws {
        throw PreviewAPIError.unavailable("person.merge")
    }

    func removePhoto(_ input: Confirmed<PersonRemovePhotoInput>) async throws {
        throw PreviewAPIError.unavailable("person.remove_photo")
    }

    func searchPhotos(_ input: PersonSearchPhotosParams) async throws -> PersonPhotosResult {
        throw PreviewAPIError.unavailable("person.search_photos")
    }
}

struct PreviewCaptureOne: CaptureOneBridging {
    func selectedPhotoPaths() async throws -> [String] {
        [PreviewData.galleryPaths[0], PreviewData.galleryPaths[1]]
    }

    func reloadMetadata(sessionId: String) async throws {
        throw PreviewAPIError.unavailable("captureOne.reload_metadata")
    }

    func checkHealth() async -> Result<String, CaptureOneBridgeError> {
        // 刻意返回 failure：SettingsView.checkC1Health 在 success 分支会执行
        // documentProbeScript（真实 spawn osascript）。Preview 必须零外部进程，
        // 所以这里走"未运行"分支；preflight 仍返回四层全通，供不执行脚本的调用方使用。
        .failure(.notRunning)
    }

    func preflight() async -> C1PreflightStatus {
        C1PreflightStatus(
            reachable: true,
            appRunning: true,
            automationAuthorized: true,
            documentOpen: true,
            timedOut: false,
            appName: "Capture One 23"
        )
    }

    static func documentProbeScript(appName: String) -> String {
        "return \"Preview: \(appName)\""
    }
}

struct PreviewMaintenanceAPI: MaintenanceAPI {
    func backup(_ input: MaintenanceBackupInput) async throws -> BackupRecord {
        throw PreviewAPIError.unavailable("maintenance.backup")
    }

    func listBackups() async throws -> MaintenanceInventory {
        MaintenanceInventory(backupDir: "", backups: [], lastRestore: nil, autoPaused: false)
    }

    func restore(_ input: Confirmed<RestoreBackupInput>) async throws -> RestoreReceipt {
        throw PreviewAPIError.unavailable("maintenance.restore")
    }

    func exportDiagnostics(_ input: DiagnosticsExportInput) async throws -> DiagnosticsExportResult {
        throw PreviewAPIError.unavailable("maintenance.export_diagnostics")
    }
}
#endif

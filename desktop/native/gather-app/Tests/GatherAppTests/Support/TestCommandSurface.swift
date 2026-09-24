// Tests/GatherAppTests/Support/TestCommandSurface.swift
// 测试共享：19 域类型化命令面的默认实现（协议扩展）+ 空 conformer。
// 单测只实现自己关心的域方法；未实现的方法抛 TestCommandUnimplemented。
import Foundation
import GatherCore

struct TestCommandUnimplemented: Error, CustomStringConvertible {
    let operation: String
    var description: String { "TEST_COMMAND_UNIMPLEMENTED:\(operation)" }
}

// MARK: - AlbumCommands
extension AlbumCommands {
    func create(name: String, description: String?, criteria: FilterGroup, sortBy: String?, sortOrder: String?, icon: String?) async throws -> SmartAlbumDetailData {
        throw TestCommandUnimplemented(operation: "AlbumCommands.create")
    }
    func list() async throws -> [SmartAlbumData] {
        throw TestCommandUnimplemented(operation: "AlbumCommands.list")
    }
    func get(albumId: String) async throws -> SmartAlbumDetailData {
        throw TestCommandUnimplemented(operation: "AlbumCommands.get")
    }
    func update(albumId: String, name: String?, description: String?, criteria: FilterGroup?, sortBy: String?, sortOrder: String?, icon: String?) async throws {
        throw TestCommandUnimplemented(operation: "AlbumCommands.update")
    }
    func delete(albumId: String, confirmed: Bool) async throws {
        throw TestCommandUnimplemented(operation: "AlbumCommands.delete")
    }
    func getPhotos(albumId: String, limit: Int?, offset: Int?) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        throw TestCommandUnimplemented(operation: "AlbumCommands.getPhotos")
    }
}

// MARK: - AssetsCommands
extension AssetsCommands {
    func candidates(_ params: AssetCandidateListParams) async throws -> [AssetLinkCandidateData] {
        throw TestCommandUnimplemented(operation: "AssetsCommands.candidates")
    }
    func acceptCandidate(_ params: AssetCandidateMutationParams) async throws {
        throw TestCommandUnimplemented(operation: "AssetsCommands.acceptCandidate")
    }
    func rejectCandidate(_ params: AssetCandidateMutationParams) async throws {
        throw TestCommandUnimplemented(operation: "AssetsCommands.rejectCandidate")
    }
    func volumes() async throws -> [AssetVolumeData] {
        throw TestCommandUnimplemented(operation: "AssetsCommands.volumes")
    }
    func relinkRoot(_ params: AssetRelinkRootParams) async throws -> Int {
        throw TestCommandUnimplemented(operation: "AssetsCommands.relinkRoot")
    }
}

// MARK: - CullingCommands
extension CullingCommands {
    func listPage(_ params: CullingListPageParams) async throws -> CullingPage {
        throw TestCommandUnimplemented(operation: "CullingCommands.listPage")
    }
    func groups(_ params: CullingGroupsParams) async throws -> [CullingGroup] {
        throw TestCommandUnimplemented(operation: "CullingCommands.groups")
    }
    func summary(_ params: CullingSummaryParams) async throws -> CullingSummary {
        throw TestCommandUnimplemented(operation: "CullingCommands.summary")
    }
    func history(_ params: CullingHistoryParams) async throws -> [CullingHistoryOperation] {
        throw TestCommandUnimplemented(operation: "CullingCommands.history")
    }
    func syncStatus(_ params: CullingSyncStatusParams) async throws -> MetadataSyncSummary {
        throw TestCommandUnimplemented(operation: "CullingCommands.syncStatus")
    }
    func update(_ params: CullingUpdateParams) async throws -> CullingUpdateResult {
        throw TestCommandUnimplemented(operation: "CullingCommands.update")
    }
    func batchUpdate(_ params: CullingBatchUpdateParams) async throws -> [CullingUpdateResult] {
        throw TestCommandUnimplemented(operation: "CullingCommands.batchUpdate")
    }
    func decideGroup(_ params: CullingDecideGroupParams) async throws -> [CullingUpdateResult] {
        throw TestCommandUnimplemented(operation: "CullingCommands.decideGroup")
    }
    func applyHistory(_ params: CullingHistoryApplyParams) async throws -> [CullingUpdateResult] {
        throw TestCommandUnimplemented(operation: "CullingCommands.applyHistory")
    }
    func writeback(_ params: CullingWritebackParams) async throws -> WritebackResult {
        throw TestCommandUnimplemented(operation: "CullingCommands.writeback")
    }
    func retryFailedWriteback(_ params: CullingRetryWritebackParams) async throws -> WritebackResult {
        throw TestCommandUnimplemented(operation: "CullingCommands.retryFailedWriteback")
    }
    func flush(_ params: CullingFlushParams) async throws -> MetadataSyncSummary {
        throw TestCommandUnimplemented(operation: "CullingCommands.flush")
    }
    func retrySync(_ params: CullingRetrySyncParams) async throws -> MetadataSyncSummary {
        throw TestCommandUnimplemented(operation: "CullingCommands.retrySync")
    }
    func finalizeSync(_ params: CullingFinalizeSyncParams) async throws -> MetadataSyncSummary {
        throw TestCommandUnimplemented(operation: "CullingCommands.finalizeSync")
    }
    func confirmSync(_ params: CullingConfirmSyncParams) async throws {
        throw TestCommandUnimplemented(operation: "CullingCommands.confirmSync")
    }
    func cleanup(_ params: CullingCleanupParams) async throws -> CleanupResult {
        throw TestCommandUnimplemented(operation: "CullingCommands.cleanup")
    }
    func reset(_ params: CullingResetParams) async throws {
        throw TestCommandUnimplemented(operation: "CullingCommands.reset")
    }
}

// MARK: - DuplicateCommands
extension DuplicateCommands {
    func scan(_ params: DupScanParams) async throws -> DuplicateScanResult {
        throw TestCommandUnimplemented(operation: "DuplicateCommands.scan")
    }
    func groups(_ params: DupGroupsParams) async throws -> [DuplicateGroup] {
        throw TestCommandUnimplemented(operation: "DuplicateCommands.groups")
    }
    func resolve(_ params: DupResolveParams) async throws {
        throw TestCommandUnimplemented(operation: "DuplicateCommands.resolve")
    }
    func resolveMember(_ params: DupResolveMemberParams) async throws {
        throw TestCommandUnimplemented(operation: "DuplicateCommands.resolveMember")
    }
}

// MARK: - ExportCommands
extension ExportCommands {
    func preview(_ params: ExportPreviewParams) async throws -> ExportPreview {
        throw TestCommandUnimplemented(operation: "ExportCommands.preview")
    }
    func execute(_ params: ExportExecuteParams) async throws -> ExportResult {
        throw TestCommandUnimplemented(operation: "ExportCommands.execute")
    }
    func cancel(sessionId: String) async throws {
        throw TestCommandUnimplemented(operation: "ExportCommands.cancel")
    }
    func report(_ params: ExportReportParams) async throws -> ReportData {
        throw TestCommandUnimplemented(operation: "ExportCommands.report")
    }
}

// MARK: - FaceCommands
extension FaceCommands {
    func analyze(_ params: FkwAnalyzeParams) async throws -> (status: String, detectionFailures: Int, encodingFailures: Int) {
        throw TestCommandUnimplemented(operation: "FaceCommands.analyze")
    }
    func cancelAnalysis(_ params: FkwCancelAnalysisParams) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.cancelAnalysis")
    }
    func recluster(sessionId: String, eps: Double?, minSamples: Int?) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.recluster")
    }
    func clusters(_ params: FkwClustersParams) async throws -> [FaceClusterData] {
        throw TestCommandUnimplemented(operation: "FaceCommands.clusters")
    }
    func bind(_ params: FkwBindParams) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.bind")
    }
    func unbind(_ params: FkwUnbindParams) async throws -> (done: Bool, removedKeywords: [String]) {
        throw TestCommandUnimplemented(operation: "FaceCommands.unbind")
    }
    func merge(_ params: FkwMergeParams) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.merge")
    }
    func removeMember(_ params: FkwRemoveMemberParams) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.removeMember")
    }
    func preview(_ params: FkwPreviewParams) async throws -> WritebackPreview {
        throw TestCommandUnimplemented(operation: "FaceCommands.preview")
    }
    func writeback(_ params: FkwWritebackParams) async throws -> WritebackResult {
        throw TestCommandUnimplemented(operation: "FaceCommands.writeback")
    }
    func confirmSync(_ params: FkwConfirmSyncParams) async throws {
        throw TestCommandUnimplemented(operation: "FaceCommands.confirmSync")
    }
    func confirmCleanup(_ params: FkwConfirmCleanupParams) async throws -> CleanupResult {
        throw TestCommandUnimplemented(operation: "FaceCommands.confirmCleanup")
    }
    func cleanup(_ params: FkwCleanupParams) async throws -> CleanupResult {
        throw TestCommandUnimplemented(operation: "FaceCommands.cleanup")
    }
    func modelsStatus() async throws -> FaceModelsStatusData {
        throw TestCommandUnimplemented(operation: "FaceCommands.modelsStatus")
    }
}

// MARK: - FilterCommands
extension FilterCommands {
    func photos(_ params: FilterPhotosParams, limit: Int, offset: Int) async throws -> [PhotoData] {
        throw TestCommandUnimplemented(operation: "FilterCommands.photos")
    }
    func photosGlobal(_ params: FilterPhotosGlobalParams) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        throw TestCommandUnimplemented(operation: "FilterCommands.photosGlobal")
    }
    func suggest(_ params: FilterSuggestParams) async throws -> [FilterSuggestion] {
        throw TestCommandUnimplemented(operation: "FilterCommands.suggest")
    }
}

// MARK: - IndexCommands
extension IndexCommands {
    func scan(_ params: IndexScanParams) async throws -> IndexScanResult {
        throw TestCommandUnimplemented(operation: "IndexCommands.scan")
    }
}

// MARK: - JobsCommands
extension JobsCommands {
    func list(_ params: JobListParams) async throws -> [AnalysisJobData] {
        throw TestCommandUnimplemented(operation: "JobsCommands.list")
    }
    func cancel(_ params: JobCancelParams) async throws -> Bool {
        throw TestCommandUnimplemented(operation: "JobsCommands.cancel")
    }
    func retry(_ params: JobRetryParams) async throws -> Bool {
        throw TestCommandUnimplemented(operation: "JobsCommands.retry")
    }
    func clearCompleted(_ params: JobClearCompletedParams) async throws -> Int {
        throw TestCommandUnimplemented(operation: "JobsCommands.clearCompleted")
    }
}

// MARK: - MetadataCommands
extension MetadataCommands {
    func get(_ params: MetadataGetParams) async throws -> [String: MetadataTags] {
        throw TestCommandUnimplemented(operation: "MetadataCommands.get")
    }
    func set(_ params: MetadataSetParams) async throws -> MetadataTags {
        throw TestCommandUnimplemented(operation: "MetadataCommands.set")
    }
    func batchSet(_ params: MetadataBatchSetParams) async throws -> BatchMetadataResult {
        throw TestCommandUnimplemented(operation: "MetadataCommands.batchSet")
    }
    func conflicts(_ params: MetadataConflictListParams) async throws -> [MetadataConflict] {
        throw TestCommandUnimplemented(operation: "MetadataCommands.conflicts")
    }
    func resolveConflict(_ params: MetadataConflictResolveParams) async throws -> MetadataSyncSummary {
        throw TestCommandUnimplemented(operation: "MetadataCommands.resolveConflict")
    }
    func resolveOrphan(_ params: MetadataOrphanResolveParams) async throws -> [MetadataOrphan] {
        throw TestCommandUnimplemented(operation: "MetadataCommands.resolveOrphan")
    }
    func orphans() async throws -> [MetadataOrphan] {
        throw TestCommandUnimplemented(operation: "MetadataCommands.orphans")
    }
}

// MARK: - NavigationCommands
extension NavigationCommands {
    func analyze(_ params: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        throw TestCommandUnimplemented(operation: "NavigationCommands.analyze")
    }
    func list(_ params: NavigationListParams) async throws -> [NavigationGroup] {
        throw TestCommandUnimplemented(operation: "NavigationCommands.list")
    }
    func split(_ params: NavigationSplitParams) async throws -> [NavigationGroup] {
        throw TestCommandUnimplemented(operation: "NavigationCommands.split")
    }
    func merge(_ params: NavigationMergeParams) async throws -> [NavigationGroup] {
        throw TestCommandUnimplemented(operation: "NavigationCommands.merge")
    }
}

// MARK: - PersonCommands
extension PersonCommands {
    func list(_ params: PersonListParams) async throws -> [PersonData] {
        throw TestCommandUnimplemented(operation: "PersonCommands.list")
    }
    func get(_ params: PersonGetParams) async throws -> PersonDetailData {
        throw TestCommandUnimplemented(operation: "PersonCommands.get")
    }
    func create(_ params: PersonCreateParams) async throws -> String {
        throw TestCommandUnimplemented(operation: "PersonCommands.create")
    }
    func update(_ params: PersonUpdateParams) async throws {
        throw TestCommandUnimplemented(operation: "PersonCommands.update")
    }
    func delete(_ params: PersonDeleteParams) async throws {
        throw TestCommandUnimplemented(operation: "PersonCommands.delete")
    }
    func merge(_ params: PersonMergeParams) async throws {
        throw TestCommandUnimplemented(operation: "PersonCommands.merge")
    }
    func removePhoto(_ params: PersonRemovePhotoParams) async throws {
        throw TestCommandUnimplemented(operation: "PersonCommands.removePhoto")
    }
    func searchPhotos(_ params: PersonSearchPhotosParams) async throws -> (photos: [PersonPhotoItem], total: Int) {
        throw TestCommandUnimplemented(operation: "PersonCommands.searchPhotos")
    }
}

// MARK: - PhotoCommands
extension PhotoCommands {
    func listPage(sessionId: String, afterFirstRowid: Int64?, limit: Int?, expandVariants: Bool) async throws -> (rows: [PhotoData], cursor: Int64?) {
        throw TestCommandUnimplemented(operation: "PhotoCommands.listPage")
    }
}

// MARK: - QualityCommands
extension QualityCommands {
    func get(_ params: QualityGetParams) async throws -> [QualityResult] {
        throw TestCommandUnimplemented(operation: "QualityCommands.get")
    }
    func analyze(_ params: QualityAnalyzeParams) async throws -> AnalysisJobData {
        throw TestCommandUnimplemented(operation: "QualityCommands.analyze")
    }
}

// MARK: - SessionCommands
extension SessionCommands {
    func create(_ params: SessionCreateParams) async throws -> SessionData {
        throw TestCommandUnimplemented(operation: "SessionCommands.create")
    }
    func createFromDirectory(_ params: SessionCreateFromDirectoryParams) async throws -> SessionData {
        throw TestCommandUnimplemented(operation: "SessionCommands.createFromDirectory")
    }
    func list() async throws -> [SessionData] {
        throw TestCommandUnimplemented(operation: "SessionCommands.list")
    }
    func get(_ params: SessionGetParams) async throws -> SessionData {
        throw TestCommandUnimplemented(operation: "SessionCommands.get")
    }
    func update(_ params: SessionUpdateParams) async throws -> SessionData {
        throw TestCommandUnimplemented(operation: "SessionCommands.update")
    }
    func addPhotos(_ params: SessionAddPhotosParams) async throws -> AddPhotoResult {
        throw TestCommandUnimplemented(operation: "SessionCommands.addPhotos")
    }
    func delete(_ params: SessionDeleteParams) async throws {
        throw TestCommandUnimplemented(operation: "SessionCommands.delete")
    }
    func deleteMany(_ params: SessionDeleteManyParams) async throws -> Int {
        throw TestCommandUnimplemented(operation: "SessionCommands.deleteMany")
    }
}

// MARK: - SettingsCommands
extension SettingsCommands {
    func getAll() async throws -> [String: String] {
        throw TestCommandUnimplemented(operation: "SettingsCommands.getAll")
    }
    func get(key: String) async throws -> String {
        throw TestCommandUnimplemented(operation: "SettingsCommands.get")
    }
    func getMLStatus() async throws -> MLStatusData {
        throw TestCommandUnimplemented(operation: "SettingsCommands.getMLStatus")
    }
    func set(key: String, value: String) async throws {
        throw TestCommandUnimplemented(operation: "SettingsCommands.set")
    }
    func reset() async throws -> [String: String] {
        throw TestCommandUnimplemented(operation: "SettingsCommands.reset")
    }
    func setLanguage(language: String) async throws -> String {
        throw TestCommandUnimplemented(operation: "SettingsCommands.setLanguage")
    }
}

// MARK: - SimilarityCommands
extension SimilarityCommands {
    func analyze(_ params: SimAnalyzeParams) async throws {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.analyze")
    }
    func cancelAnalysis(_ params: SimCancelAnalysisParams) async throws {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.cancelAnalysis")
    }
    func recluster(_ params: SimReclusterParams) async throws -> SimilarityResult {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.recluster")
    }
    func result(_ params: SimResultParams) async throws -> SimilarityResult? {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.result")
    }
    func previewWriteback(_ params: SimPreviewWritebackParams) async throws -> WritebackPreview {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.previewWriteback")
    }
    func writeback(_ params: SimWritebackParams) async throws -> WritebackResult {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.writeback")
    }
    func writebackItems(_ params: SimWritebackItemsParams) async throws -> [WritebackItem] {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.writebackItems")
    }
    func retryFailedWriteback(_ params: SimRetryFailedWritebackParams) async throws -> WritebackResult {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.retryFailedWriteback")
    }
    func confirmSync(_ params: SimConfirmSyncParams) async throws {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.confirmSync")
    }
    func cleanup(_ params: SimCleanupParams) async throws -> CleanupResult {
        throw TestCommandUnimplemented(operation: "SimilarityCommands.cleanup")
    }
}

// MARK: - TemplateCommands
extension TemplateCommands {
    func create(_ params: TemplateCreateParams) async throws -> TemplateData {
        throw TestCommandUnimplemented(operation: "TemplateCommands.create")
    }
    func list() async throws -> [TemplateData] {
        throw TestCommandUnimplemented(operation: "TemplateCommands.list")
    }
    func get(_ params: TemplateGetParams) async throws -> TemplateData {
        throw TestCommandUnimplemented(operation: "TemplateCommands.get")
    }
    func update(_ params: TemplateUpdateParams) async throws -> TemplateData {
        throw TestCommandUnimplemented(operation: "TemplateCommands.update")
    }
    func delete(_ params: TemplateDeleteParams) async throws {
        throw TestCommandUnimplemented(operation: "TemplateCommands.delete")
    }
    func apply(_ params: TemplateApplyParams) async throws {
        throw TestCommandUnimplemented(operation: "TemplateCommands.apply")
    }
}

// MARK: - WorkspaceCommands
extension WorkspaceCommands {
    func status(_ params: WorkspaceStatusParams) async throws -> WorkspaceStatus {
        throw TestCommandUnimplemented(operation: "WorkspaceCommands.status")
    }
}

// MARK: - 空命令面
struct EmptyAlbum: AlbumCommands {}
struct EmptyAssets: AssetsCommands {}
struct EmptyCulling: CullingCommands {}
struct EmptyDuplicate: DuplicateCommands {}
struct EmptyExport: ExportCommands {}
struct EmptyFace: FaceCommands {}
struct EmptyFilter: FilterCommands {}
struct EmptyIndex: IndexCommands {}
struct EmptyJobs: JobsCommands {}
struct EmptyMetadata: MetadataCommands {}
struct EmptyNavigation: NavigationCommands {}
struct EmptyPerson: PersonCommands {}
struct EmptyPhoto: PhotoCommands {}
struct EmptyQuality: QualityCommands {}
struct EmptySession: SessionCommands {}
struct EmptySettings: SettingsCommands {}
struct EmptySimilarity: SimilarityCommands {}
struct EmptyTemplate: TemplateCommands {}
struct EmptyWorkspace: WorkspaceCommands {}

extension CommandSurface {
    /// 全空命令面：未覆写的域方法一律抛 TestCommandUnimplemented。
    static func testEmpty() -> CommandSurface {
        CommandSurface(
            album: EmptyAlbum(),
            assets: EmptyAssets(),
            culling: EmptyCulling(),
            duplicate: EmptyDuplicate(),
            export: EmptyExport(),
            face: EmptyFace(),
            filter: EmptyFilter(),
            index: EmptyIndex(),
            jobs: EmptyJobs(),
            metadata: EmptyMetadata(),
            navigation: EmptyNavigation(),
            person: EmptyPerson(),
            photo: EmptyPhoto(),
            quality: EmptyQuality(),
            session: EmptySession(),
            settings: EmptySettings(),
            similarity: EmptySimilarity(),
            template: EmptyTemplate(),
            workspace: EmptyWorkspace(),
        )
    }
}

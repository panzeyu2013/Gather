// desktop/native/gather-app/Tests/GatherAppTests/Support/StubExportMetadataAPIs.swift
// Cut 1 / B6b 测试共享：ExportAPI / MetadataAPI 的可配置替身。
//
// 与 Support/StubAPIs.swift（B5b）同款结构：final class + LockedBox
// （@unchecked Sendable），方法可在任意隔离域调用；记录参数供断言。
// 页面/VM 只依赖协议，注入替身即可覆盖 preview/execute/cancel/report 与
// orphans/resolve_orphan、conflicts/resolve_conflict 的 API 边界。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

// MARK: - ExportAPI

private struct B6bExportState {
    var previewResult = ExportPreview(
        totalFiles: 0, totalSizeBytes: 0, freeSpaceBytes: 0, files: []
    )
    var previewError: (any Error)?
    var executeResult = ExportResult(
        totalFiles: 0, exported: 0, failed: 0, skipped: 0, errors: []
    )
    var executeError: (any Error)?
    var cancelResult = true
    var cancelError: (any Error)?
    var reportResult = ReportData(path: "/tmp/b6b-report.md", content: "", format: .md)
    var reportError: (any Error)?
    var previewInputs: [ExportInput] = []
    var executeInputs: [Confirmed<ExportInput>] = []
    var cancelCalls: [String] = []
    var reportInputs: [ExportReportInput] = []
}

/// 可配置 ExportAPI：默认返回空预览/空结果，报告返回 md 占位。
final class B6bExportAPIStub: ExportAPI, @unchecked Sendable {
    private let box = LockedBox(B6bExportState())

    var previewResult: ExportPreview {
        get { box.lock.withLock { box.previewResult } }
        set { box.lock.withLock { box.previewResult = newValue } }
    }

    var previewError: (any Error)? {
        get { box.lock.withLock { box.previewError } }
        set { box.lock.withLock { box.previewError = newValue } }
    }

    var executeResult: ExportResult {
        get { box.lock.withLock { box.executeResult } }
        set { box.lock.withLock { box.executeResult = newValue } }
    }

    var executeError: (any Error)? {
        get { box.lock.withLock { box.executeError } }
        set { box.lock.withLock { box.executeError = newValue } }
    }

    var cancelResult: Bool {
        get { box.lock.withLock { box.cancelResult } }
        set { box.lock.withLock { box.cancelResult = newValue } }
    }

    var cancelError: (any Error)? {
        get { box.lock.withLock { box.cancelError } }
        set { box.lock.withLock { box.cancelError = newValue } }
    }

    var reportResult: ReportData {
        get { box.lock.withLock { box.reportResult } }
        set { box.lock.withLock { box.reportResult = newValue } }
    }

    var reportError: (any Error)? {
        get { box.lock.withLock { box.reportError } }
        set { box.lock.withLock { box.reportError = newValue } }
    }

    var previewInputs: [ExportInput] { box.lock.withLock { box.previewInputs } }
    var executeInputs: [Confirmed<ExportInput>] { box.lock.withLock { box.executeInputs } }
    var cancelCalls: [String] { box.lock.withLock { box.cancelCalls } }
    var reportInputs: [ExportReportInput] { box.lock.withLock { box.reportInputs } }

    func preview(_ input: ExportInput) async throws -> ExportPreview {
        let (error, result): ((any Error)?, ExportPreview) = box.lock.withLock {
            box.previewInputs.append(input)
            return (box.previewError, box.previewResult)
        }
        if let error { throw error }
        return result
    }

    func saveWebDAVCredential(_ input: WebDAVCredentialInput) async throws -> Bool { true }

    func publish(
        _ input: Confirmed<WebDAVPublishInput>,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> WebDAVPublishSummary {
        WebDAVPublishSummary(uploaded: 0, failed: [], remoteRoot: "", abortedOnAuth: false)
    }

    func runRecipes(_ input: Confirmed<OutputRunInput>) async throws -> OutputRunSummary {
        OutputRunSummary(runId: "stub", sessionId: input.value.sessionId,
                         manifestPath: "", createdAt: "", recipes: [])
    }

    func execute(_ input: Confirmed<ExportInput>) async throws -> ExportResult {
        let (error, result): ((any Error)?, ExportResult) = box.lock.withLock {
            box.executeInputs.append(input)
            return (box.executeError, box.executeResult)
        }
        if let error { throw error }
        return result
    }

    func cancel(_ sessionId: String) async throws -> Bool {
        let (error, result): ((any Error)?, Bool) = box.lock.withLock {
            box.cancelCalls.append(sessionId)
            return (box.cancelError, box.cancelResult)
        }
        if let error { throw error }
        return result
    }

    func report(_ input: ExportReportInput) async throws -> ReportData {
        let (error, result): ((any Error)?, ReportData) = box.lock.withLock {
            box.reportInputs.append(input)
            return (box.reportError, box.reportResult)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - MetadataAPI

private func emptyKeywordApplyResult() -> MetadataKeywordApplyResult {
    MetadataKeywordApplyResult(
        result: WritebackResult(
            totalAffected: 0, written: 0, failed: 0, skipped: 0,
            errors: [], failedItems: [], report: ""),
        status: MetadataSyncSummary(
            sessionId: "", pending: 0, writing: 0, written: 0,
            failed: 0, conflict: 0, synced: 0, items: [])
    )
}

private struct B6bMetadataState {
    var conflicts: [MetadataConflict] = []
    var conflictsError: (any Error)?
    var orphans: [MetadataOrphan] = []
    var orphansError: (any Error)?
    var resolveConflictResult = MetadataSyncSummary(
        sessionId: "s1", pending: 0, writing: 0, written: 0,
        failed: 0, conflict: 0, synced: 0, items: []
    )
    var resolveConflictError: (any Error)?
    var resolveOrphanResult: [MetadataOrphan]?
    var resolveOrphanError: (any Error)?
    var conflictCalls: [String] = []
    var orphanCalls = 0
    var resolveConflictInputs: [Confirmed<MetadataResolveConflictInput>] = []
    var resolveOrphanInputs: [Confirmed<MetadataResolveOrphanInput>] = []
    var keywordPreviewResult = WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    var keywordPreviewError: (any Error)?
    var keywordPreviewInputs: [MetadataPreviewInput] = []
    var keywordApplyResult = emptyKeywordApplyResult()
    var keywordApplyError: (any Error)?
    var keywordApplyInputs: [Confirmed<MetadataKeywordApplyInput>] = []
    var keywordRetryResult = emptyKeywordApplyResult()
    var keywordRetryError: (any Error)?
    var keywordRetryInputs: [Confirmed<SessionReference>] = []
}

/// 可配置 MetadataAPI：默认冲突/孤儿为空；resolveOrphan 默认清空列表。
final class B6bMetadataAPIStub: MetadataAPI, @unchecked Sendable {
    private let box = LockedBox(B6bMetadataState())

    var triageApplyResult: TriageWritebackResult?

    func applyTriageWriteback(_ input: Confirmed<TriageWritebackInput>) async throws -> TriageWritebackResult {
        triageApplyResult ?? TriageWritebackResult(
            batchId: "triage-stub", written: input.value.items.map(\.photoId),
            skipped: [], failed: [], undoAvailable: !input.value.items.isEmpty)
    }

    func undoTriageWriteback(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> TriageWritebackResult {
        TriageWritebackResult(batchId: input.value.batchId, written: [], skipped: [], failed: [])
    }

    /// P1 / B2：模板 stub 状态（默认空表；apply 返回固定 batchId）。
    var templateList: [MetadataTemplateSummary] = []
    var lastAppliedBatchId: String = "batch-stub"

    func templates() async throws -> [MetadataTemplateSummary] { templateList }

    func saveTemplate(_ input: MetadataTemplateSaveInput) async throws -> MetadataTemplateSummary {
        let summary = MetadataTemplateSummary(
            id: input.id ?? "template-stub", name: input.name,
            fieldCount: input.fields.nonNilFieldCount, createdAt: "", updatedAt: ""
        )
        templateList.append(summary)
        return summary
    }

    func templateFields(id: String) async throws -> DescriptiveMetadata { DescriptiveMetadata() }

    func deleteTemplate(_ input: Confirmed<MetadataTemplateDeleteInput>) async throws {
        templateList.removeAll { $0.id == input.value.templateId }
    }

    func previewTemplate(_ input: MetadataTemplatePreviewInput) async throws -> MetadataTemplatePreviewResult {
        MetadataTemplatePreviewResult(
            templateId: input.templateId, templateName: "stub", totalPhotos: input.photoIds.count,
            changedPhotos: 0, changedFields: 0, conflictFields: 0,
            photos: input.photoIds.map { MetadataPhotoPreview(photoId: $0, writes: [], clears: [], conflicts: []) }
        )
    }

    func applyTemplate(_ input: Confirmed<MetadataTemplateApplyInput>) async throws -> MetadataTemplateApplyOutcome {
        MetadataTemplateApplyOutcome(
            batchId: lastAppliedBatchId, written: input.value.photoIds, skipped: [], conflicts: [], failed: []
        )
    }

    func diskDescriptive(_ photoId: String) async throws -> DescriptiveMetadata {
        detail?.descriptive ?? DescriptiveMetadata()
    }

    func applyDescriptive(
        _ input: Confirmed<MetadataInlineApplyInput>
    ) async throws -> MetadataTemplateApplyOutcome {
        MetadataTemplateApplyOutcome(
            batchId: lastAppliedBatchId, written: input.value.photoIds,
            skipped: [], conflicts: [], failed: [])
    }

    func undoTemplate(_ input: Confirmed<MetadataTemplateUndoInput>) async throws -> MetadataTemplateApplyOutcome {
        MetadataTemplateApplyOutcome(batchId: input.value.batchId, written: [], skipped: [], conflicts: [], failed: [])
    }

    func recentBatches(limit: Int) async throws -> [MetadataBatchSummary] { [] }

    /// P1 / IPTC：只读详情。测试默认给"空快照"，需要具体值时用 setter 注入。
    var detail: PhotoMetadataDetail?

    func metadata(_ photoId: String) async throws -> PhotoMetadataDetail {
        if let detail { return detail }
        return PhotoMetadataDetail(
            photoId: photoId, sessionId: "", filepath: "", filename: "",
            xmpPath: "", hasXMP: false, exif: PhotoExifSnapshot(),
            descriptive: DescriptiveMetadata(), cachedAt: "", updatedAt: ""
        )
    }

    var conflicts: [MetadataConflict] {
        get { box.lock.withLock { box.conflicts } }
        set { box.lock.withLock { box.conflicts = newValue } }
    }

    var conflictsError: (any Error)? {
        get { box.lock.withLock { box.conflictsError } }
        set { box.lock.withLock { box.conflictsError = newValue } }
    }

    var orphans: [MetadataOrphan] {
        get { box.lock.withLock { box.orphans } }
        set { box.lock.withLock { box.orphans = newValue } }
    }

    var orphansError: (any Error)? {
        get { box.lock.withLock { box.orphansError } }
        set { box.lock.withLock { box.orphansError = newValue } }
    }

    var resolveConflictResult: MetadataSyncSummary {
        get { box.lock.withLock { box.resolveConflictResult } }
        set { box.lock.withLock { box.resolveConflictResult = newValue } }
    }

    var resolveConflictError: (any Error)? {
        get { box.lock.withLock { box.resolveConflictError } }
        set { box.lock.withLock { box.resolveConflictError = newValue } }
    }

    var resolveOrphanResult: [MetadataOrphan]? {
        get { box.lock.withLock { box.resolveOrphanResult } }
        set { box.lock.withLock { box.resolveOrphanResult = newValue } }
    }

    var resolveOrphanError: (any Error)? {
        get { box.lock.withLock { box.resolveOrphanError } }
        set { box.lock.withLock { box.resolveOrphanError = newValue } }
    }

    var conflictCalls: [String] { box.lock.withLock { box.conflictCalls } }
    var orphanCalls: Int { box.lock.withLock { box.orphanCalls } }
    var resolveConflictInputs: [Confirmed<MetadataResolveConflictInput>] {
        box.lock.withLock { box.resolveConflictInputs }
    }
    var resolveOrphanInputs: [Confirmed<MetadataResolveOrphanInput>] {
        box.lock.withLock { box.resolveOrphanInputs }
    }

    var keywordPreviewResult: WritebackPreview {
        get { box.lock.withLock { box.keywordPreviewResult } }
        set { box.lock.withLock { box.keywordPreviewResult = newValue } }
    }

    var keywordPreviewError: (any Error)? {
        get { box.lock.withLock { box.keywordPreviewError } }
        set { box.lock.withLock { box.keywordPreviewError = newValue } }
    }

    var keywordApplyResult: MetadataKeywordApplyResult {
        get { box.lock.withLock { box.keywordApplyResult } }
        set { box.lock.withLock { box.keywordApplyResult = newValue } }
    }

    var keywordApplyError: (any Error)? {
        get { box.lock.withLock { box.keywordApplyError } }
        set { box.lock.withLock { box.keywordApplyError = newValue } }
    }

    var keywordRetryResult: MetadataKeywordApplyResult {
        get { box.lock.withLock { box.keywordRetryResult } }
        set { box.lock.withLock { box.keywordRetryResult = newValue } }
    }

    var keywordRetryError: (any Error)? {
        get { box.lock.withLock { box.keywordRetryError } }
        set { box.lock.withLock { box.keywordRetryError = newValue } }
    }

    var keywordPreviewInputs: [MetadataPreviewInput] {
        box.lock.withLock { box.keywordPreviewInputs }
    }

    var keywordApplyInputs: [Confirmed<MetadataKeywordApplyInput>] {
        box.lock.withLock { box.keywordApplyInputs }
    }

    var keywordRetryInputs: [Confirmed<SessionReference>] {
        box.lock.withLock { box.keywordRetryInputs }
    }

    func preview(_ input: MetadataPreviewInput) async throws -> WritebackPreview {
        let (error, result): ((any Error)?, WritebackPreview) = box.lock.withLock {
            box.keywordPreviewInputs.append(input)
            return (box.keywordPreviewError, box.keywordPreviewResult)
        }
        if let error { throw error }
        return result
    }

    func applyKeywords(
        _ input: Confirmed<MetadataKeywordApplyInput>
    ) async throws -> MetadataKeywordApplyResult {
        let (error, result): ((any Error)?, MetadataKeywordApplyResult) = box.lock.withLock {
            box.keywordApplyInputs.append(input)
            return (box.keywordApplyError, box.keywordApplyResult)
        }
        if let error { throw error }
        return result
    }

    func retryKeywordWriteback(
        _ input: Confirmed<SessionReference>
    ) async throws -> MetadataKeywordApplyResult {
        let (error, result): ((any Error)?, MetadataKeywordApplyResult) = box.lock.withLock {
            box.keywordRetryInputs.append(input)
            return (box.keywordRetryError, box.keywordRetryResult)
        }
        if let error { throw error }
        return result
    }

    func conflicts(_ sessionId: String) async throws -> [MetadataConflict] {
        let (error, result): ((any Error)?, [MetadataConflict]) = box.lock.withLock {
            box.conflictCalls.append(sessionId)
            return (box.conflictsError, box.conflicts)
        }
        if let error { throw error }
        return result
    }

    func orphans() async throws -> [MetadataOrphan] {
        let (error, result): ((any Error)?, [MetadataOrphan]) = box.lock.withLock {
            box.orphanCalls += 1
            return (box.orphansError, box.orphans)
        }
        if let error { throw error }
        return result
    }

    func resolveConflict(
        _ input: Confirmed<MetadataResolveConflictInput>
    ) async throws -> MetadataSyncSummary {
        let (error, result): ((any Error)?, MetadataSyncSummary) = box.lock.withLock {
            box.resolveConflictInputs.append(input)
            return (box.resolveConflictError, box.resolveConflictResult)
        }
        if let error { throw error }
        return result
    }

    func resolveOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        let (error, result): ((any Error)?, [MetadataOrphan]) = box.lock.withLock {
            box.resolveOrphanInputs.append(input)
            let remaining = box.resolveOrphanResult ?? box.orphans.filter {
                $0.xmpPath != input.value.xmpPath
            }
            box.orphans = remaining
            return (box.resolveOrphanError, remaining)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - 模型夹具

func b6bOrphan(xmpPath: String = "/shoot/a.xmp") -> MetadataOrphan {
    MetadataOrphan(
        xmpPath: xmpPath,
        photoPath: xmpPath.replacingOccurrences(of: ".xmp", with: ".jpg"),
        status: "pending",
        revision: 1,
        errorMessage: "",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

func b6bConflict(
    xmpPath: String = "/shoot/a.xmp",
    ratingLocal: Double = 5,
    ratingRemote: Double = 3
) -> MetadataConflict {
    MetadataConflict(
        xmpPath: xmpPath,
        photoPath: xmpPath.replacingOccurrences(of: ".xmp", with: ".jpg"),
        revision: 1,
        fields: [
            MetadataConflictField(
                field: .rating,
                baseline: .number(0),
                local: .number(ratingLocal),
                remote: .number(ratingRemote)
            )
        ]
    )
}

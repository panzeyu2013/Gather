// desktop/native/gather-app/Sources/GatherHost/FaceKwWritebackBridge.swift
// FaceKwService 的 FaceWritebackProvider 适配器：把 GatherDelivery 的 WritebackService
// （TS writeback.service.ts 移植）接入人脸关键字写回链（fkw.unbind / fkw.preview /
// fkw.writeback / fkw.confirm_sync / fkw.cleanup）。
// FaceKw 接缝类型（FaceKwWriteback*）与 WritebackService 类型（Writeback*）字段
// 逐字同源（都是 packages/shared/src/protocol/core.ts writeback 段的契约副本），
// 本文件只做等值搬运，不改变 JSON 形状。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery

public final class FaceKwWritebackBridge: FaceWritebackProvider, @unchecked Sendable {
    private let writebackService: WritebackService

    public init(writebackService: WritebackService) {
        self.writebackService = writebackService
    }

    /// TS: writebackService.removeOwnedFaceKeywords(sessionId, entries) → removedKeywords。
    public func removeOwnedFaceKeywords(sessionId: String, entries: [FaceKeywordEntry]) async throws -> [String] {
        try await writebackService.removeOwnedFaceKeywords(
            sessionId: sessionId,
            entries: entries.map { (photoId: $0.photoId, xmpPath: $0.xmpPath, keywords: $0.keywords) }
        )
    }

    /// TS: writebackService.preview(sessionId, 'face_kw', options, boundPhotoIds, additions)。
    public func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview {
        let preview = try await writebackService.preview(
            sessionId: sessionId,
            module: "face_kw",
            options: WritebackOptions(
                createAlbums: options?.createAlbums,
                addPrefix: options?.addPrefix,
                markUngrouped: options?.markUngrouped,
                writeIPTC: options?.writeIPTC
            ),
            photoIds: boundPhotoIds,
            keywordAdditions: additions
        )
        return FaceKwWritebackPreview(
            items: preview.items.map(Self.toFaceKwItem),
            totalCount: preview.totalCount,
            affectedPhotos: preview.affectedPhotos
        )
    }

    /// TS: writebackService.execute(sessionId, 'face_kw', items)。
    public func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult {
        let result = try await writebackService.execute(
            sessionId: sessionId,
            module: "face_kw",
            items: items.map(Self.toWritebackItem)
        )
        return FaceKwWritebackResult(
            totalAffected: result.totalAffected,
            written: result.written,
            failed: result.failed,
            skipped: result.skipped,
            errors: result.errors,
            failedItems: result.failedItems.map(Self.toFaceKwItem),
            report: result.report
        )
    }

    /// TS: writebackService.confirmSync(sessionId, 'face_kw')。
    public func confirmSync(sessionId: String) async throws {
        try await writebackService.confirmSync(sessionId: sessionId, module: "face_kw")
    }

    /// TS: writebackService.cleanup(sessionId, 'face_kw')。
    public func cleanup(sessionId: String) async throws -> FaceKwCleanupResult {
        let result = try await writebackService.cleanup(sessionId: sessionId, module: "face_kw")
        return FaceKwCleanupResult(deletedCount: result.deletedCount, errors: result.errors)
    }

    // MARK: - 类型搬运（字段逐字同源，仅 Swift 类型不同；唯一实现，LiveFaceAPI 复用）

    static func toFaceKwItem(_ item: WritebackItem) -> FaceKwWritebackItem {
        FaceKwWritebackItem(
            id: item.id.map(Int64.init),
            photoId: item.photoId,
            photoPath: item.photoPath,
            sessionId: item.sessionId,
            module: item.module,
            keywords: item.keywords,
            attributes: item.attributes.map {
                FaceKwWritebackAttributes(keywords: $0.keywords, rating: $0.rating, label: $0.label)
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
                        keywords: preview.before.keywords, rating: preview.before.rating, label: preview.before.label
                    ),
                    after: FaceKwWritebackAttributes(
                        keywords: preview.after.keywords, rating: preview.after.rating, label: preview.after.label
                    ),
                    source: preview.source,
                    sharedPhotoCount: preview.sharedPhotoCount,
                    externalChanged: preview.externalChanged,
                    willCreate: preview.willCreate
                )
            }
        )
    }

    static func toWritebackItem(_ item: FaceKwWritebackItem) -> WritebackItem {
        WritebackItem(
            id: item.id.flatMap { Int(exactly: $0) },
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
                        keywords: preview.before.keywords, rating: preview.before.rating, label: preview.before.label
                    ),
                    after: WritebackAttributes(
                        keywords: preview.after.keywords, rating: preview.after.rating, label: preview.after.label
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

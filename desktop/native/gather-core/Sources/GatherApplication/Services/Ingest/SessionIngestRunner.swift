// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/SessionIngestRunner.swift
// P1-3：摄取的可复用执行体。
//
// API 直调与 ingest.run Job 共用同一段“校验 → plan → 复制 → 登记”逻辑，
// 避免两条路径对目的地边界/根外文件/部分失败给出不同结果。
import Foundation
import GatherProtocol
import GatherAnalysis

public struct SessionIngestRunner {
    public let sessionService: SessionService
    public let ingestService: IngestService

    public init(
        sessionService: SessionService,
        ingestService: IngestService = IngestService(exif: ImageIOExifProvider())
    ) {
        self.sessionService = sessionService
        self.ingestService = ingestService
    }

    /// 从 Job checkpoint 解码请求；键与 JobCreateParams.ingestRun 同源。
    public static func decode(_ checkpoint: [String: JSONValue]) throws -> SessionIngestInput {
        guard let raw = checkpoint[JobCreateParams.ingestRunRequestKey]?.stringValue,
              let data = raw.data(using: .utf8) else {
            throw GatherError.invalidParameter(
                field: "checkpoint", reason: "missing ingest request")
        }
        do {
            return try JSONDecoder().decode(SessionIngestInput.self, from: data)
        } catch {
            throw GatherError.invalidParameter(
                field: "checkpoint", reason: "invalid ingest request")
        }
    }

    public func run(
        _ payload: SessionIngestInput,
        context: JobRunContext? = nil
    ) async throws -> SessionIngestResult {
        let session = try requireSession(payload)
        let options = try makeOptions(payload: payload, session: session)
        try context?.throwIfCancelled(forceDbCheck: true)
        let plan = try await planFor(payload: payload, options: options)
        context?.updateProgress(JobProgressUpdate(
            current: 0, total: plan.items.count, phase: "copy"))
        let result = ingestService.execute(
            plan,
            options: options,
            shouldCancel: { context?.signal.aborted == true },
            onProgress: { completed, total in
                context?.updateProgress(JobProgressUpdate(
                    current: completed, total: total, phase: "copy"))
            }
        )

        var registered = 0
        var unregistered: [String] = []
        // alreadyPresent = 目标已存在且校验和一致（崩溃恢复/重复摄取）。
        // 它们没有进 copied，但同样必须登记，否则文件永久留在 _ingest 且 job 成功。
        let registerPaths = result.copied + result.alreadyPresent
        if !registerPaths.isEmpty {
            do {
                let addResult = try sessionService.addPhotos(
                    sessionId: payload.sessionId, filepaths: registerPaths, source: "ingest"
                )
                registered = addResult.added
                unregistered = addResult.failedFiles
            } catch {
                registered = 0
                unregistered = registerPaths
                GatherLogger.log("ingest register failed: \(error)", level: .warn)
            }
        }
        // Wave4a-F3：replace 覆盖的是既有照片的 filepath，登记走 INSERT OR IGNORE
        // 不会重算哈希；这里刷新库内指纹（checksum/size/mtime），否则后续跨会话去重、
        // 重复检测、交付 manifest 都会读到与文件内容不符的旧校验和。
        if !result.replaced.isEmpty {
            do {
                let refreshed = try sessionService.refreshPhotoFingerprints(
                    sessionId: payload.sessionId, filepaths: result.replaced)
                GatherLogger.log(
                    "ingest replace refreshed fingerprints: \(refreshed)", level: .debug)
            } catch {
                GatherLogger.log(
                    "ingest replace fingerprint refresh failed: \(error)", level: .warn)
            }
        }
        let ingestResult = SessionIngestResult(
            registered: registered,
            copiedButUnregistered: unregistered,
            // Wave2：库内重复被跳过的源同样进 skipped（用户视角就是"这批没导入"），
            // 同时用下面的计数区分原因。
            skipped: result.skipped + result.librarySkipped,
            unreadable: result.unreadable,
            failed: result.failed.map {
                MetadataApplyFailureDTO(
                    photoId: $0.sourcePath, message: $0.message,
                    code: $0.code.isEmpty ? nil : $0.code,
                    retryable: $0.retryable)
            },
            libraryDuplicatesSkipped: result.librarySkipped.count,
            replaced: result.replaced.count,
            libraryDuplicateCount: result.libraryDuplicates.count,
            secondDestinationSkipped: result.secondSkipped.count,
            // Wave5（F4）：不支持格式的跳过统计随结果返回（旧任务载荷 = nil）。
            unsupportedFormats: result.unsupportedFormats,
            // Wave5 batch3：第二目的地"已复制"张数（校验开关在 UI 侧展示）。
            secondDestinationCopied: result.secondCopied.count
        )
        // 取消发生在复制/登记之后：文件已经安全落地并登记，再把 Job 收成 cancelled。
        try context?.throwIfCancelled(forceDbCheck: true)
        return ingestResult
    }

    // MARK: - Wave2（task-15）：摄取预检（只读）

    /// 只读预检：与 run 共用「校验 → 全库去重 → plan」，**不复制任何文件、不建 job**。
    ///
    /// 计数口径（与 IngestPlan 的字段一一对应）：
    /// - newCount = 本次会写盘并登记的文件数（已按策略处理过重复）；
    /// - libraryDuplicateCount = 命中全库（跨工作区）已登记照片的文件数（与策略无关）；
    /// - conflictCount = 目标目录同名异内容（现有冲突语义）；
    /// - unreadableCount = 不可读 / 越界 / 模板越界被拒的源数量；
    /// - unsupportedFormats = 源里被跳过的「不支持格式」（扩展名分组 + 样例）。
    public func preview(_ payload: SessionIngestInput) async throws -> SessionIngestPreview {
        let session = try requireSession(payload)
        // Wave4a-F2：预检走只读路径（不回填 checksum）。
        let options = try makeOptions(payload: payload, session: session, previewOnly: true)
        let plan = try await planFor(payload: payload, options: options)
        return SessionIngestPreview(
            // 口径修正（Review P2）：total 计入被 skip 策略跳过的库内重复；
            // new 排除冲突项（目标同名异内容，执行期会跳过，不算"新增"）。
            totalCount: plan.items.count + plan.skipped.count
                + plan.unreadable.count + plan.librarySkipped.count
                + plan.unsupportedFormats.count,
            newCount: plan.items.filter { !$0.conflict }.count,
            libraryDuplicateCount: plan.libraryDuplicates.count,
            conflictCount: plan.conflictCount,
            unreadableCount: plan.unreadable.count,
            policy: payload.duplicatePolicy,
            duplicateSamplePaths: Array(plan.libraryDuplicates.prefix(20)),
            librarySkippedCount: plan.librarySkipped.count,
            replaceableCount: plan.replaced.count,
            // Wave5（F4）：预检阶段就把"不支持格式 N 个（按扩展名）"亮出来，
            // 用户在下「开始摄取」前就知道哪些文件不会进来。
            unsupportedFormats: plan.unsupportedFormats,
            // Wave5 batch3：预检不再只有计数——给目标路径与冲突源的前 10 条样例。
            targetSamplePaths: Array(
                plan.items.filter { !$0.conflict }.prefix(10).map(\.destPath)),
            conflictSamplePaths: Array(
                plan.items.filter(\.conflict).prefix(10).map(\.sourcePath))
        )
    }

    // MARK: - 共用校验与计划

    /// 会话存在性 + 源根非空（空 sourcePath 会让 URL(fileURLWithPath:) 得到进程 cwd，
    /// 后面的 !base.isEmpty 永远真——必须在解析 URL 前显式 fail-closed）。
    private func requireSession(_ payload: SessionIngestInput) throws -> SessionData {
        guard let session = try sessionService.getSession(payload.sessionId) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        guard !session.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError(code: .INDEX_SESSION_NO_SOURCE)
        }
        return session
    }

    /// 目的地 / 第二目的地校验 + 计划参数（Wave2 起携带去重策略与会话源根）。
    private func makeOptions(
        payload: SessionIngestInput, session: SessionData, previewOnly: Bool = false
    ) throws -> IngestOptions {
        let base = URL(fileURLWithPath: session.sourcePath)
            .resolvingSymlinksInPath().path
        let destination = URL(fileURLWithPath: payload.destinationRoot)
            .resolvingSymlinksInPath().path
        guard !base.isEmpty, destination == base || destination.hasPrefix(base + "/") else {
            throw GatherError.invalidParameter(
                field: "destinationRoot", reason: "must be inside the session source path")
        }
        if let second = payload.secondDestinationRoot {
            let secondPath = URL(fileURLWithPath: second).resolvingSymlinksInPath().path
            guard secondPath.hasPrefix("/"), secondPath != "/" else {
                throw GatherError.invalidParameter(
                    field: "secondDestinationRoot",
                    reason: "must be an absolute directory other than /")
            }
            guard secondPath != destination,
                  !secondPath.hasPrefix(destination + "/"),
                  !destination.hasPrefix(secondPath + "/") else {
                throw GatherError.invalidParameter(
                    field: "secondDestinationRoot",
                    reason: "must not overlap destinationRoot")
            }
            guard secondPath != base, !secondPath.hasPrefix(base + "/") else {
                throw GatherError.invalidParameter(
                    field: "secondDestinationRoot",
                    reason: "must be outside the session source path")
            }
        }
        return IngestOptions(
            destinationRoot: payload.destinationRoot,
            renameTemplate: payload.renameTemplate,
            secondDestinationRoot: payload.secondDestinationRoot,
            verifyChecksum: payload.verifyChecksum,
            duplicatePolicy: payload.duplicatePolicy,
            sessionId: payload.sessionId,
            sessionSourceRoot: session.sourcePath,
            previewOnly: previewOnly
        )
    }

    /// 全库去重索引 + 会话内索引 → plan。查询失败只降级（记 warn），不阻断摄取。
    private func planFor(
        payload: SessionIngestInput, options: IngestOptions
    ) async throws -> IngestPlan {
        var existing: [String: String] = [:]
        var library: [String: SessionService.LibraryDuplicateTarget] = [:]
        var libraryCandidateSizes = Set<Int>()
        do {
            let sourceSizes = ingestService.sourceSizes(sourcePaths: payload.sourcePaths)
            existing = try sessionService.photoChecksums(
                sessionId: payload.sessionId,
                matchingSizes: sourceSizes.isEmpty ? nil : sourceSizes,
                allowChecksumBackfill: !options.previewOnly)
            // Wave4a-F1/F2：未回填 checksum 的视觉照片也参与跨会话去重（懒算+回填）；
            // 预检（previewOnly）只读，不回填。
            library = try sessionService.libraryPhotoDuplicates(
                matchingSizes: sourceSizes,
                allowChecksumBackfill: !options.previewOnly)
            libraryCandidateSizes = Set(library.values.map(\.fileSize))
        } catch {
            GatherLogger.log("ingest checksum lookup failed: \(error)", level: .warn)
        }
        return try await ingestService.plan(
            sourcePaths: payload.sourcePaths, options: options,
            existingChecksums: existing, libraryDuplicates: library,
            libraryCandidateSizes: libraryCandidateSizes)
    }
}

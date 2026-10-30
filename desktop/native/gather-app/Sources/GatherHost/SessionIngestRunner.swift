// desktop/native/gather-app/Sources/GatherHost/SessionIngestRunner.swift
// P1-3：摄取的可复用执行体。
//
// API 直调与 ingest.run Job 共用同一段“校验 → plan → 复制 → 登记”逻辑，
// 避免两条路径对目的地边界/根外文件/部分失败给出不同结果。
import Foundation
import GatherProtocol
import GatherApplication

struct SessionIngestRunner {
    let sessionService: SessionService
    let ingestService: IngestService

    init(
        sessionService: SessionService,
        ingestService: IngestService = IngestService(exif: ImageIOExifProvider())
    ) {
        self.sessionService = sessionService
        self.ingestService = ingestService
    }

    /// 从 Job checkpoint 解码请求；键与 JobCreateParams.ingestRun 同源。
    static func decode(_ checkpoint: [String: JSONValue]) throws -> SessionIngestInput {
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

    func run(
        _ payload: SessionIngestInput,
        context: JobRunContext? = nil
    ) async throws -> SessionIngestResult {
        let options = IngestOptions(
            destinationRoot: payload.destinationRoot,
            renameTemplate: payload.renameTemplate,
            secondDestinationRoot: payload.secondDestinationRoot,
            verifyChecksum: payload.verifyChecksum
        )
        guard let session = try sessionService.getSession(payload.sessionId) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        // 空 sourcePath 传给 URL(fileURLWithPath:) 会得到进程 cwd，后面的
        // !base.isEmpty 永远真；必须在解析 URL 前显式 fail-closed。
        guard !session.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError(code: .INDEX_SESSION_NO_SOURCE)
        }
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

        var existing: [String: String] = [:]
        do {
            let sourceSizes = ingestService.sourceSizes(sourcePaths: payload.sourcePaths)
            existing = try sessionService.photoChecksums(
                sessionId: payload.sessionId,
                matchingSizes: sourceSizes.isEmpty ? nil : sourceSizes)
        } catch {
            GatherLogger.log("ingest checksum lookup failed: \(error)", level: .warn)
        }
        try context?.throwIfCancelled(forceDbCheck: true)
        let plan = try await ingestService.plan(
            sourcePaths: payload.sourcePaths, options: options,
            existingChecksums: existing)
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
        let ingestResult = SessionIngestResult(
            registered: registered,
            copiedButUnregistered: unregistered,
            skipped: result.skipped,
            unreadable: result.unreadable,
            failed: result.failed.map {
                MetadataApplyFailureDTO(
                    photoId: $0.sourcePath, message: $0.message,
                    code: $0.code.isEmpty ? nil : $0.code,
                    retryable: $0.retryable)
            }
        )
        // 取消发生在复制/登记之后：文件已经安全落地并登记，再把 Job 收成 cancelled。
        try context?.throwIfCancelled(forceDbCheck: true)
        return ingestResult
    }
}

// Tests/GatherCoreTests/API/ExportCommandsImplTests.swift
// R5：export 域命令实现直测（批次 B5）。
// 覆盖旧路由分支语义：preview 的导出预览（文件清单/总大小/可用空间与会话缺失
// SESSION_NOT_FOUND）、execute 的确认门控 EXPORT_CONFIRMATION_REQUIRED 与
// 「建 export.execute 作业 + 等结果」形状（dedupeKey / checkpoint options）、
// 空结果以 jobFailed 失败、cancel 静默、report 的 reportType/format 下传。
import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身（导出 IO / 转码 / 报告数据源）

private actor ExportCommandsMemoryFileSystem: ExportFileSystem {
    private var contents: [String: Data]
    private var directories: Set<String> = []

    init(contents: [String: Data] = [:]) {
        self.contents = contents
    }

    func exists(_ path: String) async -> Bool {
        contents[path] != nil || directories.contains(path)
    }

    func fileSize(_ path: String) async -> Int {
        contents[path]?.count ?? 0
    }

    func createDirectory(_ path: String) async throws {
        directories.insert(path)
    }

    func copyItem(from sourcePath: String, to destinationPath: String) async throws {
        guard let data = contents[sourcePath] else { throw ExportCommandsTestError.missing }
        contents[destinationPath] = data
    }

    func removeItem(_ path: String) async throws {
        contents.removeValue(forKey: path)
    }

    func readData(_ path: String) async throws -> Data? {
        contents[path]
    }

    func names(inDirectory path: String) async throws -> Set<String> {
        []
    }

    func availableCapacity(at path: String) async -> Int {
        1_000_000
    }
}

private enum ExportCommandsTestError: Error {
    case missing
}

private struct ExportCommandsNoopConverter: ExportImageConverter {
    func convert(sourcePath: String, destinationPath: String, options: ExportOptions) async throws {}
}

private struct ExportCommandsEmptyReportSource: ExportReportSource {
    func sessionSummaryRows(sessionId: String) async throws -> [SQLiteRow] { [] }
    func personRows(sessionId: String) async throws -> [SQLiteRow] { [] }
    func keywordRows(sessionId: String) async throws -> [SQLiteRow] { [] }
    func cullingDecisionRows(sessionId: String) async throws -> [SQLiteRow] { [] }
}

// MARK: - 基座

private let exportSourceFile = "/vault/export/p1.cr3"
private let exportDestination = "/tmp/gather-r5b5-export"

private struct ExportCommandsHarness {
    let impl: ExportCommandsImpl
    let export: ExportRuntime
    let jobs: JobRunner
    let db: SQLiteDatabase
    let storePath: String

    func cleanup() { removeStoreFiles(storePath) }
}

private func makeHarness() async throws -> ExportCommandsHarness {
    let storePath = storeTempPath("export-commands")
    let db = try await makeMigratedStore(path: storePath)
    try await insertSession(db, "s1")
    try await insertPhoto(db, id: "p1", sessionId: "s1", filepath: exportSourceFile)
    let export = ExportRuntime(dependencies: .init(
        photoStore: SQLitePhotoStore(database: db),
        sessionStore: SQLiteSessionStore(database: db),
        reportSource: ExportCommandsEmptyReportSource(),
        fileSystem: ExportCommandsMemoryFileSystem(
            contents: [exportSourceFile: Data(repeating: 9, count: 42)]),
        imageConverter: ExportCommandsNoopConverter()
    ))
    let jobs = JobRunner(jobStore: SQLiteJobStore(database: db))
    return ExportCommandsHarness(
        impl: ExportCommandsImpl(export: export, jobs: jobs),
        export: export,
        jobs: jobs,
        db: db,
        storePath: storePath
    )
}

private func exportOptions() -> ExportOptions {
    ExportOptions(
        scope: .session,
        format: .original,
        naming: ExportNaming(pattern: "{name}"),
        includeXmp: false,
        destination: exportDestination
    )
}

// MARK: - 用例

@Suite("API/ExportCommandsImpl (R5)")
struct ExportCommandsImplTests {
    @Test("preview projects files, sizes and free space")
    func previewProjectsFiles() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        let preview = try await harness.impl.preview(ExportPreviewParams(
            sessionId: "s1", options: exportOptions()))

        #expect(preview.totalFiles == 1)
        #expect(preview.totalSizeBytes == 42)
        #expect(preview.freeSpaceBytes == 1_000_000)
        #expect(preview.files.first?.photoId == "p1")
        #expect(preview.files.first?.filename == "p1.cr3")
    }

    @Test("preview surfaces the missing session error")
    func previewSurfacesSessionNotFound() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: ExportError.sessionNotFound) {
            _ = try await harness.impl.preview(ExportPreviewParams(
                sessionId: "ghost", options: exportOptions()))
        }
    }

    @Test("execute requires confirmation with EXPORT_CONFIRMATION_REQUIRED")
    func executeRequiresConfirmation() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        await #expect(throws: ExportCommandsError.confirmationRequired) {
            _ = try await harness.impl.execute(ExportExecuteParams(
                sessionId: "s1", options: exportOptions(), confirmed: false))
        }
        #expect(String(describing: ExportCommandsError.confirmationRequired)
            == "EXPORT_CONFIRMATION_REQUIRED")
        #expect(ExportCommandsError.confirmationRequired.gatherCode
            == GatherErrorCode.EXPORT_CONFIRMATION_REQUIRED)
        let jobs = try await harness.jobs.list()
        #expect(jobs.isEmpty, "门控失败不应建作业")
    }

    @Test("execute creates the export job and returns the awaited result")
    func executeCreatesJobAndReturnsResult() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .exportExecute) { _, _ in
            ExportResult(totalFiles: 2, exported: 2, failed: 0, skipped: 0, errors: [])
        }

        let result = try await harness.impl.execute(ExportExecuteParams(
            sessionId: "s1", options: exportOptions(), confirmed: true))

        #expect(result.totalFiles == 2)
        #expect(result.exported == 2)
        let jobs = try await harness.jobs.list()
        #expect(jobs.count == 1)
        #expect(jobs.first?.type == .exportExecute)
        #expect(jobs.first?.scopeType == "session")
        #expect(jobs.first?.scopeId == "s1")
        #expect(jobs.first?.dedupeKey == "export.execute:s1")
        #expect(jobs.first?.checkpoint["options"]?["destination"]?.stringValue
            == exportDestination)
    }

    @Test("execute fails with jobFailed when the job result is empty")
    func executeFailsOnEmptyResult() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }
        await harness.jobs.registerExecutor(type: .exportExecute) { _, _ in nil }

        do {
            _ = try await harness.impl.execute(ExportExecuteParams(
                sessionId: "s1", options: exportOptions(), confirmed: true))
            Issue.record("空作业结果应以 jobFailed 失败")
        } catch let error as JobRunnerError {
            guard case .jobFailed(_, let message) = error else {
                Issue.record("期望 jobFailed，实际 \(error)")
                return
            }
            #expect(message == "empty export.execute result")
        }
    }

    @Test("report forwards reportType and format")
    func reportForwardsParams() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        let csv = try await harness.impl.report(ExportReportParams(
            sessionId: "s1", reportType: "session_summary", format: nil))
        #expect(csv.format == .csv)

        let md = try await harness.impl.report(ExportReportParams(
            sessionId: "s1", reportType: "session_summary", format: "md"))
        #expect(md.format == .md)
    }

    @Test("cancel stays silent for running and unknown sessions")
    func cancelIsSilent() async throws {
        let harness = try await makeHarness()
        defer { harness.cleanup() }

        try await harness.impl.cancel(sessionId: "s1")
        try await harness.impl.cancel(sessionId: "ghost")
        let jobs = try await harness.jobs.list()
        #expect(jobs.isEmpty)
    }
}

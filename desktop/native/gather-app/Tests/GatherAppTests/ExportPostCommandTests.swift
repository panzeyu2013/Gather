// desktop/native/gather-app/Tests/GatherAppTests/ExportPostCommandTests.swift
// Wave3 / task-21：导出后命令钩子的参数化与安全边界。
//
// 覆盖：
// 1. 占位符（{dir}/{session}/{manifest}）展开，且“先拆参数、后替换值”——
//    含空格/分号的目录值仍只是单个 argv 元素（没有 shell 注入面）；
// 2. 正常执行（/bin/echo）的 exitCode/outputTail；
// 3. 超时（/bin/sleep 5 + 1s 上限）→ timedOut、不阻塞调用方；
// 4. 不可执行路径 → 类型化 error，不抛异常；
// 5. attach 把结果写回 manifest JSON（OutputRunSummary.postCommand 往返）。
//
// 边界：只用系统 /bin/echo、/bin/sleep；不写仓库外持久文件（manifest 在临时目录）。
import Foundation
import Testing
@testable import GatherApplication
@testable import GatherProtocol
@testable import GatherHost

@Suite("导出后命令钩子")
struct ExportPostCommandTests {
    @Test func expandsPlaceholdersAfterSplitting() throws {
        let arguments = ExportPostCommandRunner.arguments(
            template: "/bin/echo {dir} {session} {manifest}",
            sessionId: "s1",
            destinationRoot: "/tmp/out dir; rm -rf /",
            manifestPath: "/tmp/out/manifest-1.json")
        #expect(arguments == [
            "/bin/echo",
            "/tmp/out dir; rm -rf /",
            "s1",
            "/tmp/out/manifest-1.json",
        ])
        // 关键安全断言：分号值仍是单个 argv 元素（若经 shell 会成为命令分隔符）。
        #expect(arguments?.count == 4)
    }

    @Test func emptyTemplateProducesNoArguments() {
        #expect(ExportPostCommandRunner.arguments(
            template: "   ", sessionId: "s", destinationRoot: "/d", manifestPath: "/m") == nil)
    }

    @Test func runsAndCapturesExitCodeAndOutput() async throws {
        let outcome = await ExportPostCommandRunner.run(
            ExportPostCommandConfiguration(template: "/bin/echo done-{session}", timeoutSeconds: 10),
            sessionId: "s-42", destinationRoot: "/tmp", manifestPath: "/tmp/m.json")
        #expect(outcome.exitCode == 0)
        #expect(!outcome.timedOut)
        #expect(outcome.error == nil)
        #expect(outcome.outputTail?.contains("done-s-42") == true)
    }

    @Test func timesOutWithoutThrowing() async throws {
        let started = Date()
        let outcome = await ExportPostCommandRunner.run(
            ExportPostCommandConfiguration(template: "/bin/sleep 5", timeoutSeconds: 1),
            sessionId: "s", destinationRoot: "/tmp", manifestPath: "/tmp/m.json")
        #expect(outcome.timedOut)
        #expect(outcome.exitCode == nil)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func missingExecutableIsReportedAsTypedError() async throws {
        let outcome = await ExportPostCommandRunner.run(
            ExportPostCommandConfiguration(
                template: "/nonexistent/gather-hook-binary {dir}", timeoutSeconds: 5),
            sessionId: "s", destinationRoot: "/tmp", manifestPath: "/tmp/m.json")
        #expect(outcome.exitCode == nil)
        #expect(outcome.error?.contains("not executable") == true)
    }

    @Test func attachesOutcomeToManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-hook-manifest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("manifest-1.json")
        let summary = OutputRunSummary(
            runId: "r1", sessionId: "s1", manifestPath: manifest.path,
            createdAt: "2026-11-11T00:00:00Z", recipes: [])
        try JSONEncoder().encode(summary).write(to: manifest)

        let outcome = OutputPostCommandOutcome(
            command: "/bin/echo hi", exitCode: 0, timedOut: false,
            durationMilliseconds: 12, error: nil, outputTail: "hi")
        #expect(ExportPostCommandRunner.attach(outcome, toManifestAt: manifest.path))

        let decoded = try JSONDecoder().decode(
            OutputRunSummary.self, from: Data(contentsOf: manifest))
        #expect(decoded.postCommand == outcome)
    }

    // MARK: - Wave4a-C3：钩子执行条件（成功 + 非 dedupe 缓存重放）

    private func summary(
        failed: Int = 0, manifestError: String? = nil, cancelled: Bool? = nil,
        manifestPath: String = "/tmp/m.json"
    ) -> OutputRunSummary {
        OutputRunSummary(
            runId: "r1", sessionId: "s1", manifestPath: manifestPath,
            createdAt: "2026-11-11T00:00:00Z",
            recipes: [OutputRecipeResult(
                recipeId: "rx", name: "r", destination: "/tmp",
                exported: 1, failed: failed, skipped: 0)],
            manifestError: manifestError, cancelled: cancelled)
    }

    @Test("C3：只在成功且非 dedupe 缓存重放时执行钩子")
    func postCommandRunsOnlyOnFreshSuccess() {
        #expect(LiveExportAPI.shouldRunPostCommand(
            for: summary(), cachedReplay: false))
        #expect(!LiveExportAPI.shouldRunPostCommand(
            for: summary(), cachedReplay: true))
        #expect(!LiveExportAPI.shouldRunPostCommand(
            for: summary(failed: 1), cachedReplay: false))
        #expect(!LiveExportAPI.shouldRunPostCommand(
            for: summary(manifestError: "disk full"), cachedReplay: false))
        #expect(!LiveExportAPI.shouldRunPostCommand(
            for: summary(cancelled: true), cachedReplay: false))
        #expect(!LiveExportAPI.shouldRunPostCommand(
            for: summary(manifestPath: "   "), cachedReplay: false))
        #expect(LiveExportAPI.isTerminalJobStatus(.succeeded))
        #expect(LiveExportAPI.isTerminalJobStatus(.failed))
        #expect(LiveExportAPI.isTerminalJobStatus(.cancelled))
        #expect(!LiveExportAPI.isTerminalJobStatus(.queued))
        #expect(!LiveExportAPI.isTerminalJobStatus(.running))
        #expect(!LiveExportAPI.isTerminalJobStatus(.cancelling))
    }

    // MARK: - Wave4a-C4：secret + session token 同一条 Keychain item

    @Test("C4：session token 与 secret 打包/解包，旧明文凭据兼容")
    func credentialEnvelopeRoundTrip() {
        #expect(LiveExportAPI.packStoredCredential(
            secret: "s3cr3t", sessionToken: nil) == "s3cr3t")
        #expect(LiveExportAPI.packStoredCredential(
            secret: "s3cr3t", sessionToken: "  ") == "s3cr3t")
        let packed = LiveExportAPI.packStoredCredential(
            secret: "s3cr3t", sessionToken: "TOKEN")
        #expect(packed.hasPrefix("{"))
        let unpacked = LiveExportAPI.unpackStoredCredential(packed)
        #expect(unpacked.secret == "s3cr3t")
        #expect(unpacked.sessionToken == "TOKEN")
        let legacy = LiveExportAPI.unpackStoredCredential("plain-password")
        #expect(legacy.secret == "plain-password")
        #expect(legacy.sessionToken == nil)
    }

    // MARK: - Wave4a-C5：处理取消不再阻塞到超时

    @Test("C5：取消 run 立即终止进程，不阻塞到超时")
    func cancellationTerminatesProcess() async {
        let started = Date()
        let task = Task {
            await ExportPostCommandRunner.run(
                ExportPostCommandConfiguration(
                    template: "/bin/sleep 5", timeoutSeconds: 30),
                sessionId: "s", destinationRoot: "/tmp", manifestPath: "/tmp/m.json")
        }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let outcome = await task.value
        #expect(Date().timeIntervalSince(started) < 3,
                "取消必须及时返回，而不是等 30s 超时")
        #expect(outcome.timedOut == false)
        #expect(outcome.error == "cancelled")
    }
}

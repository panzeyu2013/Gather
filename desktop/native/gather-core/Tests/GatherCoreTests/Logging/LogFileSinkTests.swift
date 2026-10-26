// desktop/native/gather-core/Tests/GatherCoreTests/Logging/LogFileSinkTests.swift
// P0 / B0：文件日志 sink 的持有与落盘（审计 P1：install 返回值曾被丢弃）。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherApplication

@Suite("B0 文件日志 sink")
struct LogFileSinkTests {
    @Test("install 后日志落盘，sink 被持有")
    func installWritesLogFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-log-sink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = GatherLogger.output
        defer { GatherLogger.output = previous }

        let sink = LogFileSink.install(directory: dir)
        GatherLogger.log("sink-probe", level: .info)
        // 保持 sink 存活到断言之后，模拟 AppBootstrap 的强持有。
        withExtendedLifetime(sink) {
            let log = dir.appendingPathComponent("gather.log")
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            #expect(text.contains("sink-probe"))
        }
    }

    @Test("目录不可写时入队立即返回并计数：失败日志不得重入 ioLock 自锁")
    func writeFailureDoesNotSelfLock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-log-sink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 把 sink 目录指向普通文件：写日志必然失败。
        let notADir = dir.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: notADir)
        let sink = LogFileSink(directory: notADir)
        sink.enqueue("will fail")
        #expect(sink.droppedCount == 1)
    }
}

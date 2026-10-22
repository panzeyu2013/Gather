// desktop/native/gather-core/Tests/GatherCoreTests/LoggerTests.swift
// 日志设施测试。注：本机为 CLT-only 环境（无 Xcode/XCTest），
// 测试框架使用 Swift Testing（`import Testing`），语义与原 XCTest 版本一致。

import Testing
@testable import GatherProtocol

/// 串行化放在**套件**上：测试内直接替换 GatherLogger 的全局 output/minimumLevel，
/// 并行会相互干扰。Test(.serialized) 对非参数化测试无效（编译告警且不生效）。
@Suite(.serialized)
struct LoggerTests {
    @Test func allLevelsEmitNonEmptyTimestampedLines() {
        let lines = captureLines(minimumLevel: .debug) {
            GatherLogger.log("debug message", level: .debug)
            GatherLogger.log("info message", level: .info)
            GatherLogger.log("warn message", level: .warn)
            GatherLogger.log("error message", level: .error)
        }

        #expect(lines.count == 4)
        for line in lines {
            #expect(!line.isEmpty)
            #expect(line.hasPrefix("["), "expected timestamp prefix, got: \(line)")
        }
    }

    @Test func minimumLevelFiltersLowerSeverity() {
        let lines = captureLines(minimumLevel: .warn) {
            GatherLogger.log("debug message", level: .debug)
            GatherLogger.log("info message", level: .info)
            GatherLogger.log("warn message", level: .warn)
            GatherLogger.log("error message", level: .error)
        }

        #expect(lines.count == 2)
    }

    // 与 GatherLogger.log() 共用 stateLock：整个 capture 期间独占全局状态，
    // 并行运行时与其他测试互斥（swift-testing 的 .serialized 在 Linux 6.1.2 上不生效）。
    private func captureLines(minimumLevel: LogLevel, log: () -> Void) -> [String] {
        GatherLogger.stateLock.lock()
        defer { GatherLogger.stateLock.unlock() }

        let defaultOutput = GatherLogger.output
        let defaultLevel = GatherLogger.minimumLevel
        defer {
            GatherLogger.output = defaultOutput
            GatherLogger.minimumLevel = defaultLevel
        }

        var lines: [String] = []
        GatherLogger.output = { lines.append($0) }
        GatherLogger.minimumLevel = minimumLevel
        log()
        return lines
    }
}

// desktop/native/gather-core/Tests/GatherCoreTests/LoggerTests.swift
// 日志设施测试。注：本机为 CLT-only 环境（无 Xcode/XCTest），
// 测试框架使用 Swift Testing（`import Testing`），语义与原 XCTest 版本一致。

import Testing
@testable import GatherCore

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

    private func captureLines(minimumLevel: LogLevel, log: () -> Void) -> [String] {
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

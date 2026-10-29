// desktop/native/gather-core/Tests/GatherCoreTests/LoggerTests.swift
// 日志设施测试。注：本机为 CLT-only 环境（无 Xcode/XCTest），
// 测试框架使用 Swift Testing（`import Testing`），语义与原 XCTest 版本一致。

import Foundation
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

    // 持 outputLock（不是 stateLock）：log() 只在 outputLock 内调用 sink，
    // 所以独占它就能保证别的测试的日志不会插进本次捕获；sink 慢时也只阻塞写线程。
    // 并行运行时与其他测试互斥（swift-testing 的 .serialized 在 Linux 6.1.2 上不生效）。
    private func captureLines(minimumLevel: LogLevel, log: () -> Void) -> [String] {
        GatherLogger.outputLock.lock()
        defer { GatherLogger.outputLock.unlock() }

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

    /// 回归（2026-10-29 CI 假死）：`log()` 调 sink 时**不得**持有状态锁。
    /// 旧实现把 `output(...)` 放在 stateLock 里，sink 卡住（CI 的 stdout 管道背压）
    /// 就连读 minimumLevel 的线程也全部排队，整进程停摆。
    @Test func slowSinkDoesNotBlockStateAccess() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        GatherLogger.outputLock.lock()
        let previousOutput = GatherLogger.output
        let previousLevel = GatherLogger.minimumLevel
        GatherLogger.output = { line in
            // 只卡住本用例的那一行，别的套件的日志照常通过。
            guard line.contains("hold-the-sink") else { return }
            entered.signal()
            release.wait()
        }
        GatherLogger.outputLock.unlock()
        defer {
            release.signal()
            GatherLogger.outputLock.lock()
            GatherLogger.output = previousOutput
            GatherLogger.minimumLevel = previousLevel
            GatherLogger.outputLock.unlock()
        }

        let writer = Thread {
            GatherLogger.minimumLevel = .debug
            GatherLogger.log("hold-the-sink", level: .error)
        }
        writer.start()
        #expect(entered.wait(timeout: .now() + 5) == .success, "sink 未被调用")

        // sink 仍阻塞在 release 上：读写全局状态必须立刻返回（旧实现会卡死在这里）。
        let readerDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            _ = GatherLogger.minimumLevel
            GatherLogger.minimumLevel = .info
            _ = GatherLogger.output
            readerDone.signal()
        }
        reader.start()
        #expect(readerDone.wait(timeout: .now() + 5) == .success, "慢 sink 阻塞了状态读写")
        release.signal()
    }
}

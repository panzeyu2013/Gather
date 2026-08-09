// desktop/native/gather-core/Tests/GatherCoreTests/Logging/TelemetryTests.swift
// 遥测设施测试。与 LoggerTests 同模式：Telemetry 为静态可变全局
// （output/enabledOverride/counters），并行运行会相互干扰；所有涉及
// 注入/捕获/环境变量的临界区均在 Telemetry.stateLock 内完成
// （swift-testing 的 .serialized 在 Linux 6.1.2 上不生效）。
// 并发测试不依赖输出捕获，改为在锁内直接断言内部累计值，避免
// 与其他测试的捕获互相污染（其余测试在临界区内全程持锁）。

import Foundation
import Testing
@testable import GatherCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct TelemetryTests {
    // 开关：默认关闭（无 override、无环境变量），三类 API 均不输出。
    @Test func defaultOffEmitsNothing() {
        let lines = captureLines(override: nil, env: nil) {
            _ = Telemetry.measure(name: "off.measure") { 1 }
            Telemetry.count(name: "off.count", by: 1)
            Telemetry.gauge(name: "off.gauge", value: 3.5)
        }
        #expect(lines.isEmpty)
    }

    // 开关：GATHER_TELEMETRY 环境变量控制启用。
    @Test func environmentVariableSwitchesTelemetry() {
        Telemetry.stateLock.lock()
        defer { Telemetry.stateLock.unlock() }

        let prevOverride = Telemetry.enabledOverride
        let prevEnv = Self.readEnv("GATHER_TELEMETRY")
        defer {
            Telemetry.enabledOverride = prevOverride
            Self.writeEnv("GATHER_TELEMETRY", prevEnv)
        }

        Telemetry.enabledOverride = nil
        Self.writeEnv("GATHER_TELEMETRY", nil)
        #expect(!Telemetry.isEnabled)
        Self.writeEnv("GATHER_TELEMETRY", "1")
        #expect(Telemetry.isEnabled)
        Self.writeEnv("GATHER_TELEMETRY", "true")
        #expect(Telemetry.isEnabled)
        Self.writeEnv("GATHER_TELEMETRY", "0")
        #expect(!Telemetry.isEnabled)
    }

    // measure：返回 body 的值，输出一条 duration，时长近似于 sleep 时长。
    @Test func measureWrapsDurationAndReturnsValue() {
        let lines = captureLines(override: true, env: nil) {
            let result = Telemetry.measure(name: "index.scan", tags: ["size": "500"]) {
                Thread.sleep(forTimeInterval: 0.05)
                return 42
            }
            #expect(result == 42)
        }
        #expect(lines.count == 1)
        let metric = parse(lines[0])
        #expect(metric["name"] as? String == "index.scan")
        #expect(metric["type"] as? String == "duration")
        let value = (metric["value"] as? NSNumber)?.doubleValue ?? 0
        #expect(value >= 40 && value < 5_000, "duration value out of range: \(value)")
        #expect((metric["tags"] as? [String: String]) == ["size": "500"])
        let tsMs = (metric["tsMs"] as? NSNumber)?.doubleValue ?? 0
        let nowMs = Date().timeIntervalSince1970 * 1000
        #expect(abs(nowMs - tsMs) < 60_000, "tsMs not a plausible epoch-millis timestamp")
    }

    // count：按 name 累加，输出当前累计值（1, 2, 3, 5, 10）。
    @Test func countAccumulatesRunningTotals() {
        let lines = captureLines(override: true, env: nil) {
            Telemetry.count(name: "files", by: 1)
            Telemetry.count(name: "files", by: 1)
            Telemetry.count(name: "files", by: 1)
            Telemetry.count(name: "files", by: 2)
            Telemetry.count(name: "files", by: 5)
        }
        #expect(lines.count == 5)
        #expect(parse(lines[0])["type"] as? String == "counter")
        let values: [Int64] = lines.compactMap {
            (parse($0)["value"] as? NSNumber)?.int64Value
        }
        #expect(values == [1, 2, 3, 5, 10])
    }

    // count 并发：1000 线程并发自增，累计值无丢失（锁内读取断言）。
    @Test func concurrentCountLosesNothing() {
        Telemetry.stateLock.lock()
        let prevOutput = Telemetry.output
        let prevOverride = Telemetry.enabledOverride
        Telemetry.output = { _ in }
        Telemetry.enabledOverride = true
        Telemetry.stateLock.unlock()
        defer {
            Telemetry.stateLock.lock()
            Telemetry.output = prevOutput
            Telemetry.enabledOverride = prevOverride
            Telemetry.stateLock.unlock()
        }

        let iterations = 1_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            Telemetry.count(name: "concurrent.rows", by: 1)
        }

        Telemetry.stateLock.lock()
        let total = Telemetry.counters["concurrent.rows"]
        Telemetry.stateLock.unlock()
        #expect(total == Int64(iterations))
    }

    // gauge：输出 type=gauge 的瞬时快照值。
    @Test func gaugeEmitsSnapshotValue() {
        let lines = captureLines(override: true, env: nil) {
            Telemetry.gauge(name: "peak.rss", value: 123_456.5)
        }
        #expect(lines.count == 1)
        let metric = parse(lines[0])
        #expect(metric["type"] as? String == "gauge")
        #expect((metric["value"] as? NSNumber)?.doubleValue == 123_456.5)
    }

    // 格式：每指标一行紧凑 JSON，键序稳定（sortedKeys）。
    @Test func emitsOneCompactJsonLinePerMetric() {
        let lines = captureLines(override: true, env: nil) {
            Telemetry.gauge(name: "fmt", value: 1.0)
            Telemetry.gauge(name: "fmt", value: 2.0)
        }
        #expect(lines.count == 2)
        for line in lines {
            #expect(!line.contains("\n"))
            #expect(line.hasPrefix("{"))
            #expect(line.hasSuffix("}"))
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] != nil)
        }
        #expect(lines[0].hasPrefix("{\"name\":\"fmt\",\"tsMs\":"))
    }

    // tags：非空时序列化为 tags 对象，空 tags 省略该键。
    @Test func tagsSerializeAndEmptyTagsAreOmitted() {
        let lines = captureLines(override: true, env: nil) {
            Telemetry.gauge(name: "a", value: 1, tags: ["phase": "import", "size": "500"])
            Telemetry.gauge(name: "b", value: 2)
        }
        #expect(lines.count == 2)
        #expect(
            (parse(lines[0])["tags"] as? [String: String])
                == ["phase": "import", "size": "500"]
        )
        #expect(parse(lines[1])["tags"] == nil)
    }

    // measure 抛错：错误向上传播，且不输出指标。
    @Test func throwingMeasureRethrowsWithoutEmitting() {
        let lines = captureLines(override: true, env: nil) {
            #expect(throws: TelemetryTests.TestError.self) {
                _ = try Telemetry.measure(name: "boom") { throw TelemetryTests.TestError() }
            }
        }
        #expect(lines.isEmpty)
    }

    private struct TestError: Error {}

    // 捕获模式：整个临界区持 stateLock（与其他测试互斥），
    // 与 LoggerTests.captureLines 同思路；输出闭包在锁内被调用，追加安全。
    private func captureLines(override: Bool?, env: String?, _ body: () -> Void) -> [String] {
        Telemetry.stateLock.lock()
        defer { Telemetry.stateLock.unlock() }

        let prevOutput = Telemetry.output
        let prevOverride = Telemetry.enabledOverride
        let prevEnv = Self.readEnv("GATHER_TELEMETRY")
        defer {
            Telemetry.output = prevOutput
            Telemetry.enabledOverride = prevOverride
            Self.writeEnv("GATHER_TELEMETRY", prevEnv)
        }

        var lines: [String] = []
        Telemetry.output = { lines.append($0) }
        Telemetry.enabledOverride = override
        Self.writeEnv("GATHER_TELEMETRY", env)
        body()
        return lines
    }

    private func parse(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    private static func readEnv(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }

    private static func writeEnv(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}

// desktop/native/gather-app/Tests/GatherAppTests/SessionDirectoryMonitorTests.swift
// P2：目录监听 -> 窄范围扫描的 checkpoint 覆盖判定（只测纯函数，不起 FSEvents）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherHost

@Suite("目录监听：窄扫描覆盖判定")
struct SessionDirectoryMonitorTests {
    private var key: String { JobCreateParams.metadataScanRequestedPathsKey }

    @Test("没有 requestedPaths = 全树扫描，覆盖任何目录")
    func fullTreeCoversEverything() {
        #expect(SessionDirectoryMonitor.covers([:], directories: ["/shoot/2024"]))
        #expect(SessionDirectoryMonitor.covers([:], directories: []))
    }

    @Test("窄扫描覆盖自身与子目录，不覆盖兄弟目录或祖先")
    func narrowScopeCoverage() {
        let checkpoint: [String: JSONValue] = [
            key: .array([.string("/shoot/2024"), .string("/shoot/2025")]),
        ]
        #expect(SessionDirectoryMonitor.covers(checkpoint, directories: ["/shoot/2024"]))
        #expect(SessionDirectoryMonitor.covers(
            checkpoint, directories: ["/shoot/2024/day1", "/shoot/2025/day2"]))
        #expect(!SessionDirectoryMonitor.covers(checkpoint, directories: ["/shoot/2026"]))
        #expect(!SessionDirectoryMonitor.covers(checkpoint, directories: ["/shoot"]),
                "祖先目录比 checkpoint 更宽，不能算已覆盖")

        let narrow: [String: JSONValue] = [key: .array([.string("/shoot/2024/day1")])]
        #expect(!SessionDirectoryMonitor.covers(narrow, directories: ["/shoot/2024"]),
                "活跃任务只扫 day1 时，day2 的变更必须重试")
    }

    @Test("扫描确认只减快照：await 期间新到的目录必须保留")
    func acknowledgeKeepsNewDirectories() {
        var state = SessionDirectoryMonitor.PendingScan()
        state.note(["/shoot/a"], eventID: 10)
        let snapshot = state.directories.sorted()
        // 模拟 jobs.start 等待期间又来了一个事件。
        state.note(["/shoot/b"], eventID: 11)
        state.acknowledge(snapshot)

        #expect(state.directories == ["/shoot/b"], "不能把新目录跟快照一起清掉")
        #expect(state.eventID == 11, "eventID 取最大，不能回退")
        #expect(!state.isEmpty)

        state.acknowledge(["/shoot/b"])
        #expect(state.isEmpty)
    }

    @Test("路径归一化：尾斜杠不影响覆盖判定")
    func trailingSlashNormalization() {
        let checkpoint: [String: JSONValue] = [key: .array([.string("/shoot/2024/")])]
        #expect(SessionDirectoryMonitor.covers(checkpoint, directories: ["/shoot/2024"]))
    }
}

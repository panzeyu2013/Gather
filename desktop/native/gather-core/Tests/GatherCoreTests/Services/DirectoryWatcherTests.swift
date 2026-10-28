// desktop/native/gather-core/Tests/GatherCoreTests/Services/DirectoryWatcherTests.swift
// P1 / D：FSEvents 目录监听的直测——真实文件创建必须回调到父目录，
// 且 lastEventID 可续传（非 0）。

import Foundation
import Testing
@testable import GatherApplication

private final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [DirectoryChange] = []

    func record(_ change: DirectoryChange) {
        lock.lock(); defer { lock.unlock() }
        changes.append(change)
    }
    func contains(_ directory: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return changes.contains { change in
            change.directories.contains { ($0 as NSString).standardizingPath == (directory as NSString).standardizingPath }
        }
    }
    var lastEventID: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return changes.last?.lastEventID ?? 0
    }
}

@Suite("FSEvents 目录监听")
struct DirectoryWatcherTests {
    @Test("新文件触发父目录回调，eventId 可用于续传")
    func deliversDirectoryChange() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-watch-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(atPath: dir) } catch {}
        }

        let box = ChangeBox()
        let watcher = DirectoryWatcher(paths: [dir], latency: 0.05) { change in
            box.record(change)
        }
        #expect(watcher.start(), "真实目录必须起得来")
        defer { watcher.stop() }
        // 给 FSEventStream 一点启动时间，避免把"流尚未就绪"误判成不回调。
        try await Task.sleep(for: .milliseconds(300))

        let file = (dir as NSString).appendingPathComponent("new.CR3")
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if box.contains(dir) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(box.contains(dir), "创建文件后 8 秒内必须收到目录变更")
        #expect(box.lastEventID > 0, "eventId 为 0 时无法续传")
    }

    @Test("空路径不启动：start 返回 false（调用方据此报错，而不是假装在监听）")
    func emptyPathsReportFailure() {
        let watcher = DirectoryWatcher(paths: [], latency: 0.05) { _ in }
        #expect(!watcher.start())
        watcher.stop()
    }
}

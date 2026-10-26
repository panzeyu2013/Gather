// desktop/native/gather-core/Sources/GatherApplication/Logging/LogFileSink.swift
// P0 / B0：GatherLogger → 文件 sink（5MB × 5 轮转；tee 保留 stdout）。
//
// 并发模型（P1 修复）：持 ioLock 期间不得调用 GatherLogger / BestEffort —— 它们在
// 失败时会重新进入 enqueue，而 ioLock 是非递归锁，会造成自锁。写入失败与轮转
// 都在锁外记录；写失败日志只上报一次，避免失败路径无限递归。
import Foundation
import os
import GatherProtocol
import GatherPersistence

public final class LogFileSink: Sendable {
    private struct Counters: Sendable {
        var dropped = 0
        var loggedWriteFailure = false
    }

    private let directory: URL
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let ioLock = OSAllocatedUnfairLock(initialState: ())
    private let rotationLock = OSAllocatedUnfairLock(initialState: ())
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    public init(directory: URL, maxFileBytes: Int = 5_000_000, maxFiles: Int = 5) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    @discardableResult
    public static func install(
        directory: URL,
        maxFileBytes: Int = 5_000_000,
        maxFiles: Int = 5
    ) -> LogFileSink {
        let sink = LogFileSink(directory: directory, maxFileBytes: maxFileBytes, maxFiles: maxFiles)
        sink.install()
        return sink
    }

    public func install() {
        BestEffort.attempt("create log directory") {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let previous = GatherLogger.output
        GatherLogger.output = { [weak self] line in
            previous(line)
            self?.enqueue(line)
        }
    }

    public func enqueue(_ line: String) {
        let url = directory.appendingPathComponent("gather.log")
        let data = Data((line + "\n").utf8)
        let outcome: (failure: Error?, needsRotation: Bool) = ioLock.withLock {
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    _ = FileManager.default.createFile(
                        atPath: url.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    // 关闭失败无法再记日志（会重入 ioLock），主错误由调用方记录。
                    do { try handle.close() } catch {}
                    throw error
                }
                var size = 0
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    size = (attributes[.size] as? Int) ?? 0
                } catch {
                    // 读大小失败只影响是否轮转；持锁期间不得打日志。
                }
                return (nil, size > maxFileBytes)
            } catch {
                return (error, false)
            }
        }
        var rotationFailure: Error?
        if outcome.needsRotation { rotationFailure = rotate(url) }
        if let error = outcome.failure ?? rotationFailure { recordFailure(error) }
    }

    private func recordFailure(_ error: Error) {
        let shouldLog = counters.withLock { state -> Bool in
            state.dropped += 1
            guard !state.loggedWriteFailure else { return false }
            state.loggedWriteFailure = true
            return true
        }
        guard shouldLog else { return }
        GatherLogger.log("log sink write failed: \(error)", level: .warn)
    }

    /// 返回首个失败，由调用方在锁外记录（本函数不直接打日志，避免再进 enqueue）。
    private func rotate(_ url: URL) -> Error? {
        rotationLock.withLock {
            var failure: Error?
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "gather-\(formatter.string(from: Date())).log"
            do {
                try FileManager.default.moveItem(
                    atPath: url.path,
                    toPath: directory.appendingPathComponent(name).path
                )
            } catch {
                failure = error
            }
            let logs: [String]
            do {
                logs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasPrefix("gather-") && $0.hasSuffix(".log") }
                    .sorted()
            } catch {
                return failure ?? error
            }
            if logs.count > maxFiles {
                for name in logs.prefix(logs.count - maxFiles) {
                    do {
                        try FileManager.default.removeItem(
                            atPath: directory.appendingPathComponent(name).path)
                    } catch {
                        if failure == nil { failure = error }
                    }
                }
            }
            return failure
        }
    }

    public var droppedCount: Int {
        counters.withLock { $0.dropped }
    }
}

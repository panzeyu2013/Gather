// desktop/native/gather-app/Sources/GatherUI/Settings/C1Probe.swift
// Cut 4 / 4c-2d：C1 预检结果快照、探测错误分类与 continuation 单次 resume 门
//（原 SettingsView.swift 997-1054 行）。纯搬移；C1ProbeGate 由 private 改 internal，
// 供 SettingsViewModel+C1Health 的 runAppleScript 使用。
import Foundation

// MARK: - 预检结果与 osascript 探测辅助

public struct C1HealthSnapshot: Equatable, Sendable {
    public var reachable: Bool
    public var appRunning: Bool
    public var documentOpen: Bool
    public var automationAuthorized: Bool
    public var appName: String?
    public var latencyMs: Int?
    public var lastError: String?

    public init(
        reachable: Bool,
        appRunning: Bool,
        documentOpen: Bool,
        automationAuthorized: Bool,
        appName: String?,
        latencyMs: Int?,
        lastError: String?
    ) {
        self.reachable = reachable
        self.appRunning = appRunning
        self.documentOpen = documentOpen
        self.automationAuthorized = automationAuthorized
        self.appName = appName
        self.latencyMs = latencyMs
        self.lastError = lastError
    }
}

public enum C1ProbeError: Error, Equatable, Sendable {
    case notAuthorized
    case noDocument
    case timedOut
    case scriptFailed(String)
}

/// 保证 continuation 只 resume 一次（termination handler 与超时竞争）。
final class C1ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

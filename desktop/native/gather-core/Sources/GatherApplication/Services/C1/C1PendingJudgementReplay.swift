// desktop/native/gather-core/Sources/GatherApplication/Services/C1/C1PendingJudgementReplay.swift
// Wave4c / task-48（A2 半修）：C1 判断在 metadata.scan 非 succeeded 时的 pending 重放。
//
// 背景：applyAfterIndexing 只在扫描 succeeded 后落库（A2：否则会被后续整行 upsert 清掉）；
// 但失败/超时/取消时判断只是被**跳过**，用户既看不到、也不会自动补——C1 星级/关键词
// 永久缺失。本 actor 持有 per-session pending judgements：
//   - 登记时立即广播待重试计数（UI 状态条显示）；
//   - 后台按 pollInterval 重试（有上限），一旦 applyAfterIndexing 不再返回 skippedReason
//     （= 扫描已成功 / 修复）就落库并清空；
//   - 用户可随时手动 retry（状态条按钮），与自动重试共用同一 apply；
//   - 仍然失败时保留 pending（计数不清零），避免"静默放弃"。
//
// 边界：pending 只在进程内（不写 schema/不持久化）——重启后丢失，用户可重新从 C1
// 导入判断；这是刻意不做 schema 改动的取舍（见汇报）。
import Foundation
import GatherProtocol

/// C1 判断的 pending 重放器（actor：状态只在内部改；apply/回调均注入，便于单测）。
public actor C1PendingJudgementReplay {
    /// 一次落库尝试（生产 = C1ImportJudgementService.applyAfterIndexing）。
    public typealias ApplyHandler =
        @Sendable (String, [C1VariantJudgement]) async -> C1ImportJudgementReport
    /// 待重试计数变化（sessionId, 合并后的照片数；0 = 已清空）。
    public typealias StateChangeHandler = @Sendable (String, Int) -> Void

    private struct Pending: Sendable {
        var judgements: [C1VariantJudgement]
        var attempts: Int = 0
        var lastReason: String
    }

    private let apply: ApplyHandler
    private let onStateChange: StateChangeHandler
    private let pollInterval: Duration
    private let maxAttempts: Int
    private let sleep: @Sendable (Duration) async throws -> Void

    private var pending: [String: Pending] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]

    public init(
        apply: @escaping ApplyHandler,
        onStateChange: @escaping StateChangeHandler = { _, _ in },
        pollInterval: Duration = .seconds(15),
        maxAttempts: Int = 40,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.apply = apply
        self.onStateChange = onStateChange
        self.pollInterval = pollInterval
        self.maxAttempts = maxAttempts
        self.sleep = sleep
    }

    /// 登记一份因扫描未成功而跳过的判断；立即广播计数并启动后台重试。
    public func register(
        sessionId: String,
        judgements: [C1VariantJudgement],
        skippedReason: String
    ) {
        guard !judgements.isEmpty else { return }
        pending[sessionId] = Pending(
            judgements: judgements, lastReason: skippedReason)
        publish(sessionId: sessionId)
        startWatcher(sessionId: sessionId)
    }

    /// 手动重试（状态条按钮）：立即尝试一次；失败则保留 pending 等自动重试。
    public func retry(sessionId: String) async {
        _ = await attempt(sessionId: sessionId)
    }

    /// 待重试的合并照片数（0 = 无）。
    public func pendingCount(sessionId: String) -> Int {
        guard let entry = pending[sessionId] else { return 0 }
        return C1ImportJudgementMapping.merge(entry.judgements).count
    }

    /// 最近一次跳过原因（诊断用；无 pending 时 nil）。
    public func pendingReason(sessionId: String) -> String? {
        pending[sessionId]?.lastReason
    }

    /// 停机：取消后台重试并清空（不广播——场景已关闭）。
    public func shutdown() {
        for task in watchers.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
    }

    // MARK: - 内部

    private func startWatcher(sessionId: String) {
        watchers[sessionId]?.cancel()
        // 强捕获 self：watcher 结束时会自己把条目清空，不形成常驻环。
        watchers[sessionId] = Task {
            await self.watch(sessionId: sessionId)
        }
    }

    private func watch(sessionId: String) async {
        while !Task.isCancelled {
            guard let entry = pending[sessionId], entry.attempts < maxAttempts else { break }
            do {
                try await sleep(pollInterval)
            } catch {
                watchers[sessionId] = nil
                return
            }
            if await attempt(sessionId: sessionId) { return }
        }
        guard var entry = pending[sessionId] else {
            watchers[sessionId] = nil
            return
        }
        entry.lastReason += "（自动重试已达上限 \(maxAttempts) 次，可手动重试）"
        pending[sessionId] = entry
        watchers[sessionId] = nil
        publish(sessionId: sessionId)
    }

    /// 尝试一次落库；true = 已落库并清空（或本来就没有 pending）。
    private func attempt(sessionId: String) async -> Bool {
        guard var entry = pending[sessionId] else { return true }
        entry.attempts += 1
        let report = await apply(sessionId, entry.judgements)
        if let reason = report.skippedReason {
            entry.lastReason = reason
            pending[sessionId] = entry
            return false
        }
        pending[sessionId] = nil
        watchers[sessionId]?.cancel()
        watchers[sessionId] = nil
        publish(sessionId: sessionId)
        return true
    }

    private func publish(sessionId: String) {
        onStateChange(sessionId, pendingCount(sessionId: sessionId))
    }
}

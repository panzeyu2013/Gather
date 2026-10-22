// desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Recover.swift
// P1-4 收口：JobService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：恢复与兜底（watchdog 回收 stale/自动恢复、取消宽限、停机强制迁移、宽限任务登记）。
import Foundation
import GatherPersistence
import GatherProtocol

extension JobService {

    // MARK: - 恢复

    /// 看门狗：回收 stale 租约 → 按类型策略自动恢复 interrupted → 驱动队列。
    func recoverAndResume() {
        _ = try? repo.recoverStale(leaseTimeoutMs: Int(leaseTimeoutMs))
        resumeInterruptedForRegisteredTypes()
        pump()
    }

    func resumeInterruptedForRegisteredTypes() {
        lock.lock()
        let running = !stopped
        let types = executors
            .filter { $0.value.autoResume && !JobService.nonAutoResumableTypes.contains($0.key) }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
        let cap = maxAutoResumeAttempts
        lock.unlock()
        guard running, !types.isEmpty else { return }
        _ = try? repo.resumeInterrupted(types: types, maxAttempts: cap)
    }

    func clearGraceTask(id: String) {
        lock.lock()
        let task = cancelGraceTasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    // MARK: - 取消宽限

    /// 挂取消宽限定时器：到时仍为 cancelling（本租约）则强制收尾为 cancelled，
    /// 保证 cancelling 永远能离开；执行器稍后自然退出时结果 first-wins 不覆盖。
    func scheduleCancelGrace(id: String) {
        lock.lock()
        cancelGraceTasks[id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(self.cancelGraceMs))
            if Task.isCancelled { return }
            self.forceCancel(id: id)
        }
        cancelGraceTasks[id] = task
        lock.unlock()
    }

    private func forceCancel(id: String) {
        guard let row = try? repo.get(id),
              row.status == .cancelling,
              row.leaseOwner == leaseOwner else { return }
        if (try? repo.finish(id: id, leaseOwner: leaseOwner, status: .cancelled)) == true {
            Self.logJob(
                id,
                "event=terminal phase=terminal status=cancelled reason=cancel-grace",
                level: .info)
            completeResult(id: id, error: JobCancelledError())
            emitTerminal(id: id)
        }
        clearGraceTask(id: id)
    }

    /// 停机超时兜底：按行真实状态迁移（cancelling→cancelled，running→interrupted）。
    func forceFinalizeAbandoned() {
        lock.lock()
        let ids = Array(activeRuns.keys)
        lock.unlock()
        for id in ids {
            guard let row = try? repo.get(id),
                  row.leaseOwner == leaseOwner,
                  activeAnalysisJobStatuses.contains(row.status) else { continue }
            if row.status == .cancelling {
                if (try? repo.finish(id: id, leaseOwner: leaseOwner, status: .cancelled)) == true {
                    Self.logJob(
                        id,
                        "event=terminal phase=terminal status=cancelled reason=stop-timeout",
                        level: .info)
                    completeResult(id: id, error: JobCancelledError())
                    emitTerminal(id: id)
                }
            } else if row.status == .running {
                if (try? repo.interrupt(id: id, leaseOwner: leaseOwner)) == true {
                    Self.logJob(
                        id,
                        "event=terminal phase=terminal status=interrupted reason=stop-timeout",
                        level: .info)
                    completeResult(id: id, error: JobServiceError.jobFailed(id, "Application stopped during execution"))
                    emitTerminal(id: id)
                }
            }
        }
    }
}

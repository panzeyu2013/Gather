// desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Settle.swift
// P1-4 收口：JobService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：结果等待与终态收尾（settle、first-wins 结果登记、终态/进度帧）。
import Foundation
import GatherPersistence
import GatherProtocol

extension JobService {

    // MARK: - 结果等待

    /// 等待任务结果。succeeded 且内存结果已过期时返回 nil（持久行是权威记录）。
    public func waitForResult<T>(jobId: String, timeoutMs: Int64? = nil) async throws -> T? {
        if let completed = takeCompletedResult(jobId: jobId) {
            if let error = completed.error { throw error }
            return completed.value as? T
        }

        guard let persisted = try repo.get(jobId) else {
            throw JobServiceError.jobNotFound(jobId)
        }
        if persisted.status == .succeeded {
            return nil
        }
        if [.failed, .interrupted, .cancelled].contains(persisted.status) {
            if persisted.status == .cancelled {
                throw JobCancelledError()
            }
            throw JobServiceError.jobFailed(
                jobId,
                persisted.errorMessage.isEmpty ? "Analysis job \(persisted.status.rawValue)" : persisted.errorMessage)
        }

        let timeout = timeoutMs ?? JobService.waitForResultTimeoutMs
        let result: JobResultValue = try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            // 「检查已完成结果」与「注册 waiter」同一临界区，避免完成竞态挂死。
            if let completed = registerWaiterOrTakeCompletedResult(jobId: jobId, waiter: waiter) {
                if let error = completed.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: JobResultValue(value: completed.value))
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeout))
                guard let self else { return }
                let removed = self.removeWaiter(jobId: jobId, waiter: waiter)
                if removed {
                    continuation.resume(throwing: JobServiceError.waitForResultTimeout(jobId))
                }
            }
        }
        return result.value as? T
    }

    private func takeCompletedResult(jobId: String) -> CompletedResult? {
        lock.lock()
        defer { lock.unlock() }
        return completedResults[jobId]
    }

    private func registerWaiterOrTakeCompletedResult(jobId: String, waiter: Waiter) -> CompletedResult? {
        lock.lock()
        if let completed = completedResults[jobId] {
            lock.unlock()
            return completed
        }
        var waiters = resultWaiters[jobId] ?? []
        waiters.append(waiter)
        resultWaiters[jobId] = waiters
        lock.unlock()
        return nil
    }

    private func removeWaiter(jobId: String, waiter: Waiter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var waiters = resultWaiters[jobId] ?? []
        if let index = waiters.firstIndex(where: { $0 === waiter }) {
            waiters.remove(at: index)
            if waiters.isEmpty {
                resultWaiters.removeValue(forKey: jobId)
            } else {
                resultWaiters[jobId] = waiters
            }
            return true
        }
        return false
    }

    /// 终态收尾：先写库（原子条件 UPDATE），成功才登记结果并广播真实终态帧。
    func settle(job: AnalysisJobData, outcome: Result<Any?, Error>, controller: JobAbortSignal) {
        let value: Any?
        let error: Error?
        switch outcome {
        case .success(let result):
            value = result
            error = nil
        case .failure(let resultError):
            value = nil
            error = resultError
        }
        var cancelled = controller.aborted
        if let error, error is JobCancelledError { cancelled = true }
        let stoppedNow = isStopped

        if let error, !cancelled {
            let message = String(describing: error)
            // 优先取类型化错误码（PersistenceError.detail 非空时 description 是 "CODE: detail"，
            // 纯字符串等值匹配会退化为 worker_error）。
            let code = (error as? CodedError)?.code.rawValue
                ?? Self.gatherErrorCode(from: message)
                ?? "worker_error"
            if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .failed, error: (code, message))) == true {
                // WP7b：失败终态是排障入口——warn 带 phase + 错误码/原因。
                Self.logJob(
                    job.id,
                    "event=terminal phase=terminal status=failed "
                        + "type=\(job.type.rawValue) \(runDurationField(id: job.id)) "
                        + "reason=\(code): \(message)",
                    level: .warn)
                completeResult(id: job.id, error: error)
                emitTerminal(id: job.id)
            } else {
                finishMiss(id: job.id)
            }
            return
        }

        if cancelled {
            // 应用停机导致的取消不是用户取消 → interrupted，供下次启动恢复。
            if stoppedNow,
               (try? repo.interrupt(id: job.id, leaseOwner: leaseOwner)) == true {
                Self.logJob(
                    job.id,
                    "event=terminal phase=terminal status=interrupted "
                        + "type=\(job.type.rawValue) \(runDurationField(id: job.id)) "
                        + "reason=application-stopped",
                    level: .info)
                completeResult(id: job.id, error: JobServiceError.jobFailed(job.id, "Application stopped during execution"))
                emitTerminal(id: job.id)
                return
            }
            if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .cancelled)) == true {
                // P2：取消终态必须带 reason（与 queued-cancel/cancel-grace/
                // application-stopped 的既有口径一致）。本分支是执行器在宽限期
                // 内协作退出；宽限到点由 forceCancel 收尾，两者同属取消请求，
                // 因此共用 cancel-grace（stop 导致的取消走 application-stopped）。
                Self.logJob(
                    job.id,
                    "event=terminal phase=terminal status=cancelled "
                        + "type=\(job.type.rawValue) \(runDurationField(id: job.id)) "
                        + "reason=cancel-grace",
                    level: .info)
                completeResult(id: job.id, error: JobCancelledError())
                emitTerminal(id: job.id)
            } else {
                finishMiss(id: job.id)
            }
            return
        }

        if (try? repo.finish(id: job.id, leaseOwner: leaseOwner, status: .succeeded)) == true {
            Self.logJob(
                job.id,
                "event=terminal phase=terminal status=succeeded "
                    + "type=\(job.type.rawValue) \(runDurationField(id: job.id))",
                level: .info)
            completeResult(id: job.id, value: value)
            emitTerminal(id: job.id)
        } else {
            finishMiss(id: job.id)
        }
    }

    /// 条件 UPDATE 未命中：行已不由本租约持有（对端已迁移/删除）。
    /// 只登记等待者结果（first-wins，不覆盖已有终态），不广播终态帧。
    private func finishMiss(id: String) {
        Self.logJob(
            id,
            "event=terminal phase=terminal status=lease-lost "
                + "\(runDurationField(id: id)) reason=conditional-update-missed",
            level: .warn)
        completeResult(id: id, error: JobServiceError.leaseLost(id))
    }

    /// settle 用（无参函数，避免与同名属性歧义）。
    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - 结果与事件

    func completeResult(id: String, value: Any?) {
        registerResult(id: id, value: value, error: nil)
    }

    func completeResult(id: String, error: Error) {
        registerResult(id: id, value: nil, error: error)
    }

    /// first-wins：已登记的终态结果不被迟到者覆盖（取消宽限 vs 执行器自然退出）。
    private func registerResult(id: String, value: Any?, error: Error?) {
        let expiry = Self.nowMs() + JobService.completedResultTtlMs
        lock.lock()
        if completedResults[id] != nil {
            lock.unlock()
            return
        }
        completedResults[id] = CompletedResult(value: value, error: error, expiresAt: expiry)
        let waiters = resultWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in waiters {
            if let error {
                waiter.continuation.resume(throwing: error)
            } else {
                waiter.continuation.resume(returning: JobResultValue(value: value))
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(JobService.completedResultTtlMs))
            guard let self else { return }
            self.expireCompletedResultIfDue(id: id)
        }
    }

    private func expireCompletedResultIfDue(id: String) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = completedResults[id], entry.expiresAt <= Self.nowMs() {
            completedResults.removeValue(forKey: id)
        }
    }

    func emitProgress(job: AnalysisJobData, update: JobProgressUpdate) {
        lock.lock()
        let sink = progressSink
        lock.unlock()
        sink?(job, update)
    }

    /// 终态帧：payload 与进度必须来自持久行的真实执行结果（不再用期望状态拼 1/1）。
    func emitTerminal(id: String) {
        guard let latest = try? repo.get(id) else { return }
        let message: String?
        if !latest.errorMessage.isEmpty {
            message = latest.errorMessage
        } else if !latest.progressMessage.isEmpty {
            message = latest.progressMessage
        } else {
            message = nil
        }
        emitProgress(job: latest, update: JobProgressUpdate(
            current: latest.progressCurrent,
            total: latest.progressTotal,
            phase: latest.progressMessage.isEmpty ? nil : latest.progressMessage,
            message: message,
            checkpoint: latest.checkpoint))
    }
}

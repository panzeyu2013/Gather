// desktop/native/gather-core/Sources/GatherApplication/Services/Job/JobService+Claim.swift
// P1-4 收口：JobService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：准入与领取（pump 循环、weight 预算、claim、执行任务启动、心跳循环）。
import Foundation
import GatherPersistence
import GatherProtocol

extension JobService {

    // MARK: - 调度（唯一准入控制）

    func pump() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        pumpRequested = true
        if pumping {
            lock.unlock()
            return
        }
        pumping = true
        lock.unlock()
        Task { [weak self] in
            await self?.pumpLoop()
        }
    }

    /// pumpLoop 每轮的锁内判定（多值判定 → 私有 enum，同 ScanSlotDecision）。
    private enum PumpLoopStep {
        /// 已停机：复位 pumping/pumpRequested 后退出。
        case stop
        /// 有待处理请求：复位 pumpRequested 后继续下一轮。
        case continueLoop
        /// 无待处理请求：复位 pumping 后退出。
        case idle
    }

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func pumpLoopStepLocked() -> PumpLoopStep {
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            pumping = false
            pumpRequested = false
            return .stop
        }
        if pumpRequested {
            pumpRequested = false
            return .continueLoop
        }
        pumping = false
        return .idle
    }

    private func pumpLoop() async {
        while true {
            startEligibleJobs()
            switch pumpLoopStepLocked() {
            case .stop:
                return
            case .continueLoop:
                continue
            case .idle:
                return
            }
        }
    }

    /// 队列顺序 = repo 的唯一口径（priority ASC, updated_at ASC, rowid ASC）；
    /// 逐个按 weight 预算准入，claim 失败（跨进程竞争）直接跳过。
    private func startEligibleJobs() {
        let queued: [AnalysisJobData]
        do {
            queued = try repo.list(status: .queued)
        } catch {
            return
        }
        for job in queued {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            guard let registration = executors[job.type], activeRuns[job.id] == nil else {
                lock.unlock()
                continue
            }
            let used = activeRuns.values.reduce(0) { $0 + $1.weight }
            guard used + registration.weight <= weightBudget else {
                lock.unlock()
                continue
            }
            let controller = JobAbortSignal()
            activeRuns[job.id] = ActiveRun(controller: controller, task: nil, weight: registration.weight)
            lock.unlock()

            let claimed: Bool
            do {
                claimed = try repo.claim(id: job.id, leaseOwner: leaseOwner)
            } catch {
                removeActiveRun(id: job.id)
                continue
            }
            guard claimed else {
                removeActiveRun(id: job.id)
                continue
            }

            // WP7b：claim 成功 = 本次执行真正开始；trace 可在执行器/心跳/终态间关联。
            // duration_ms 以此刻为基准：start 记 0，终态日志记实际耗时。
            beginRun(id: job.id)
            Self.logJob(
                job.id,
                "event=start phase=start type=\(job.type.rawValue) "
                    + "scope=\(job.scopeType):\(job.scopeId) "
                    + "weight=\(registration.weight) lease=\(leaseOwner) duration_ms=0",
                level: .info)

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runClaimedJob(job: job, registration: registration, controller: controller)
            }
            lock.lock()
            controllers[job.id] = controller
            if var run = activeRuns[job.id] {
                run.task = task
                activeRuns[job.id] = run
            } else {
                // 执行任务已先一步收尾并移除记录：取消刚创建的任务，避免悬挂。
                task.cancel()
            }
            lock.unlock()
        }
    }

    private func removeActiveRun(id: String) {
        lock.lock()
        activeRuns.removeValue(forKey: id)
        controllers.removeValue(forKey: id)
        // run 已结束：清掉起点，避免同 id retry 时复用旧 duration。
        runStartedAtMs.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - 执行

    private func runClaimedJob(job: AnalysisJobData, registration: Registration, controller: JobAbortSignal) async {
        let context = JobRunContext(
            signal: controller,
            repo: repo,
            jobId: job.id,
            leaseOwner: leaseOwner,
            updateProgress: { [weak self] id, owner, update in
                guard let self else { return false }
                return try self.repo.updateProgress(id: id, leaseOwner: owner, update: update)
            },
            progressSink: { [weak self] job, update in
                self?.emitProgress(job: job, update: update)
            })

        let heartbeat = Task { [weak self] in
            await self?.heartbeatLoop(job: job, controller: controller, context: context)
        }

        var outcome: Result<Any?, Error>
        do {
            let value = try await registration.executor(job, context)
            context.flushProgress()
            // 成功路径也要尊重取消：用户已取消时按 cancelled 收尾，不写 succeeded。
            do {
                try context.throwIfCancelled(forceDbCheck: true)
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
        } catch {
            context.flushProgress()
            outcome = .failure(error)
        }
        heartbeat.cancel()
        settle(job: job, outcome: outcome, controller: controller)
        removeActiveRun(id: job.id)
        clearGraceTask(id: job.id)
        pump()
    }

    /// 心跳循环：0 行 = 租约丢失（中止）；SQL 抛错 = 重试并保持 running。
    private func heartbeatLoop(job: AnalysisJobData, controller: JobAbortSignal, context: JobRunContext) async {
        var consecutiveErrors = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(heartbeatIntervalMs))
            if Task.isCancelled || controller.aborted { return }
            context.flushProgress()
            do {
                let ok = try repo.heartbeat(id: job.id, leaseOwner: leaseOwner)
                consecutiveErrors = 0
                if !ok {
                    // 0 行：行已被对端迁移（回收/取消/删除）或租约被夺；
                    // 本执行器放弃，不再改写对端状态。
                    controller.abort()
                    return
                }
            } catch {
                consecutiveErrors += 1
                guard consecutiveErrors >= 3 else { continue }
                if let row = try? repo.get(job.id),
                   row.leaseOwner == leaseOwner,
                   activeAnalysisJobStatuses.contains(row.status) {
                    // 读回确认租约仍属本进程：瞬时 DB 错误，继续 running。
                    consecutiveErrors = 0
                }
                // 读回也失败：不 abort（SQL 错误 ≠ 用户取消），继续重试心跳。
            }
        }
    }
}

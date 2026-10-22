// desktop/native/gather-app/Sources/GatherHost/AppRuntime.swift
// Cut 1 / B8.3b-1：宿主运行时生命周期（executor 注册 / JobService 启动 / 优雅停机 /
// Capture One reload ack）。
//
// 本文件只承接“运行时”职责，**不构造任何业务服务**：db / jobService /
// executorDeps 全部由组合根（AppComposition.make）构造后复用同一批实例，
// 禁止在此 new 第二份（JobService 的执行器、DB 连接都只能有一份）。
//
// S5c-2b-3b-2b-3：启动回放（draft §5.5）。start() 在 jobService.start() 之后
// 调度一次 DeliveryCoordinator.replayPendingDeliveries()：
//   · 成功：applied/skipped/failed 计数与逐条错误进日志（warn）；
//   · 失败：错误既进日志（error），也保留在 `deliveryReplayFailure` 供宿主/测试读取；
//   · 策略：**不阻塞启动**（回放是后台 Task，UI 不被文件阶段拖住），但失败绝不静默；
//   · shutdown 会先 await 这次回放再关库，避免「回放写库撞上 close」。
//
// B8.4 后字符串命令面已删除，本类型的接口保持不变。
//
// 线程安全（@unchecked Sendable 的依据）：
// 1) 依赖（db / database / jobService / delivery / executorDeps）均为不可变 let，
//    由组合根构造后只读共享；
// 2) 可变状态 lifecycle / shutdownTask / registeredTypes / replayTask / replayFailure
//    只在 lock 临界区内读写，且所有临界区都是同步辅助函数（不在 async 上下文直接
//    拿 NSLock）；
// 3) shutdown 最多执行一次：并发/重复调用等待同一个停机 Task，不会二次
//    stop / shutdown / close。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherDomain
import GatherDelivery

/// 运行时生命周期错误（调用方可见的稳定语义）。
public enum AppRuntimeError: Error, Equatable, Sendable {
    /// shutdown 之后再次 start：运行时不可复活（SQLite 已关闭、JobService 已停机）。
    /// 调用方必须重建组合根（新 db + 新服务 + 新 runtime），不得复用旧实例。
    case alreadyShutDown
}

/// 宿主运行时：组合根持有、GatherApp 驱动 start/shutdown 的唯一生命周期对象。
public final class AppRuntime: @unchecked Sendable {
    /// 组合根构造的共享 SQLite 连接（停机时关闭；测试可直接断言同一指针）。
    public let db: DBConnection
    /// 生产入口打开的库门面（GatherApp 经 Database.open 打开；测试夹具可为 nil）。
    private let ownedDatabase: Database?
    /// 组合根构造的唯一 JobService（start 启动调度器、shutdown 停机）。
    public let jobService: JobService
    /// 8 个 executor 的依赖集合（与 AppServices 共用同一批服务实例）。
    let executorDeps: ExecutorRegistry.Dependencies
    /// 唯一的交付编排器（启动回放的执行者；与四域注入的是同一实例）。
    private let delivery: DeliveryCoordinator

    /// reload ack 的写入面：与旧实现一致，只写持久列，不伪造成功。
    private let sessionRepo: SessionRepo

    private let lock = NSLock()
    private var lifecycle: Lifecycle = .idle
    private var shutdownTask: Task<Void, Never>?
    private var registeredTypes: [AnalysisJobType] = []
    /// 启动回放（start 后至多一次；测试可 await）。
    private var replayTask: Task<Void, Never>?
    /// 最近一次启动回放的失败描述（nil = 未执行 / 成功）。
    private var replayFailure: String?

    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    init(
        db: DBConnection,
        database: Database? = nil,
        jobService: JobService,
        delivery: DeliveryCoordinator,
        executorDeps: ExecutorRegistry.Dependencies
    ) {
        self.db = db
        self.ownedDatabase = database
        self.jobService = jobService
        self.delivery = delivery
        self.executorDeps = executorDeps
        self.sessionRepo = SessionRepo(connection: db)
    }

    /// 启动：注册 8 个 executor → 启动 JobService 调度器。
    ///
    /// - 已启动：幂等 no-op，返回首次注册的 type 列表；
    /// - shutdown 后：抛 `AppRuntimeError.alreadyShutDown`（失败可见，避免在已关闭
    ///   的连接上“看起来启动成功”）。
    /// - 返回值只用于装配期自检与测试断言，生产调用方可忽略。
    @discardableResult
    public func start() throws -> [AnalysisJobType] {
        lock.lock()
        switch lifecycle {
        case .stopped:
            lock.unlock()
            throw AppRuntimeError.alreadyShutDown
        case .running:
            let types = registeredTypes
            lock.unlock()
            return types
        case .idle:
            let types = registerExecutors()
            jobService.start()
            registeredTypes = types
            lifecycle = .running
            lock.unlock()
            // jobService 已在运行：此时才允许回放（回放可能补 DB 段并触发文件阶段，
            // 不得早于调度器启动，否则写回执行器还没就绪）。
            scheduleDeliveryReplay()
            return types
        }
    }

    // MARK: - 启动回放（S5c-2b-3b-2b-3）

    /// 最近一次启动回放的失败描述（nil = 未执行或成功）。失败可见、不阻塞启动。
    public var deliveryReplayFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return replayFailure
    }

    /// 等待启动回放结束（测试与宿主停机前使用；未启动时立即返回）。
    public func waitForDeliveryReplay() async {
        await replayTaskSnapshot()?.value
    }

    /// 同步取回放 Task 的快照（Swift 6：async 上下文不得直接 lock/unlock）。
    private func replayTaskSnapshot() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return replayTask
    }

    /// 调度启动回放（幂等：每个 runtime 至多一次）。
    ///
    /// 失败策略：单条 intent 的失败已由 replay() 收敛进 summary.errors；这里再兜底
    /// 捕获「读 backlog 失败」等整体错误，写 replayFailure + error 日志，不抛出、
    /// 不阻塞 start()。未完成 intent 保留在库中，下次启动或 flush/retry 会再试。
    private func scheduleDeliveryReplay() {
        lock.lock()
        guard replayTask == nil, lifecycle == .running else {
            lock.unlock()
            return
        }
        let delivery = self.delivery
        let task = Task { [weak self] in
            do {
                let summary = try await delivery.replayPendingDeliveries()
                GatherLogger.log(
                    "delivery replay: applied=\(summary.appliedCount) skipped=\(summary.skippedCount) "
                        + "failed=\(summary.failedCount)",
                    level: summary.failedCount == 0 ? .info : .warn
                )
                for error in summary.errors {
                    GatherLogger.log("delivery replay item failed: \(error)", level: .warn)
                }
            } catch {
                GatherLogger.log("delivery replay failed: \(error)", level: .error)
                self?.recordDeliveryReplayFailure(error)
            }
        }
        replayTask = task
        lock.unlock()
    }

    private func recordDeliveryReplayFailure(_ error: Error) {
        lock.lock()
        replayFailure = String(describing: error)
        lock.unlock()
    }

    /// 优雅停机（ADR-023）：等启动回放收尾 → 停任务调度器 → 关闭数据库。
    ///
    /// S5c-2b-3b-2b-3：回放是后台 Task，先 await 再关库，避免「回放写库撞上
    /// SQLite close」；旧 MetadataSyncCoordinator 的计时器/写盘已随旧栈删除，
    /// 不再需要 shutdown 排空。
    ///
    /// 幂等：重复/并发调用等待首次停机完成，不会二次 stop/close。
    /// 从未 start 的 runtime 也可以 shutdown（用于 bootstrap 中途失败的清理）。
    public func shutdown() async {
        let task = beginShutdown()
        await task?.value
    }

    /// Capture One 脚本成功后由宿主调用，写入持久 reload ack；页面不得在
    /// AppleScript 失败时伪造该标记。
    public func recordReloadAck(sessionId: String) throws {
        _ = try sessionRepo.setReloadAckedAt(sessionId: sessionId, iso: nowISOString())
    }

    /// executor 注册的唯一入口（装配期自检与 start() 共用，避免两份清单）。
    @discardableResult
    func registerExecutors() -> [AnalysisJobType] {
        ExecutorRegistry.register(jobService: jobService, deps: executorDeps)
    }

    /// 停机临界区（同步）：返回本次（或已在进行的）停机 Task。
    /// 必须在同步函数里拿锁，避免 Swift 6 async 上下文直接调用 NSLock。
    private func beginShutdown() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let shutdownTask {
            return shutdownTask
        }
        guard lifecycle != .stopped else {
            return nil
        }
        lifecycle = .stopped
        // 只捕获 Sendable 依赖（Task/Database/DBConnection/JobService），避免停机
        // Task 反向持有 runtime（成环）。
        let jobService = self.jobService
        let replay = replayTask
        let ownedDatabase = self.ownedDatabase
        let db = self.db
        let task = Task {
            await replay?.value
            await jobService.stop()
            if let ownedDatabase {
                ownedDatabase.close()
            } else {
                db.close()
            }
        }
        shutdownTask = task
        return task
    }
}

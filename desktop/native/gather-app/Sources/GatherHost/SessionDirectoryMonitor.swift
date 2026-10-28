// desktop/native/gather-app/Sources/GatherHost/SessionDirectoryMonitor.swift
// P1 / D：会话目录的 FSEvents 监听（外部改动 → 增量 metadata.scan）。
//
// 与 UI 无关：只要会话工作区被创建就启动；同一会话只保留一个 watcher。
// 事件按目录合并后交给 JobAPI（dedupeKey 会把连续事件收敛成一次扫描），
// 不做自动写盘、不移动文件。
import Foundation
import GatherProtocol
import GatherApplication

@MainActor
final class SessionDirectoryMonitor {
    static let shared = SessionDirectoryMonitor()

    private var watchers: [String: DirectoryWatcher] = [:]
    /// start 在 await 期间被 stop（LRU 淘汰）时取消，避免"先 evict 后 start"
    /// 给已关闭会话留下永久 watcher。
    private var startingSessions: Set<String> = []
    private var cancelledStarts: Set<String> = []
    /// 进程内记忆 eventId：工作区被 LRU 淘汰后重建时可续扫（不依赖持久化）。
    private var lastEventIDs: [String: UInt64] = [:]
    /// 启动失败（FSEvents 资源/路径暂时不可用）的退避重试任务：首轮之外最多再试 3 次
    /// （15s / 30s / 60s），stop/stopAll 会取消，避免"假监听"变成永久无监听。
    private var retryTasks: [String: Task<Void, Never>] = [:]
    static let maxStartAttempts = 4
    /// P2：事件扫描改成"只扫变更目录"。dedupe 可能把请求并进一个更窄的活跃任务，
    /// 此时目录集合先暂存，退避重试（2/4/8/16s）；仍不行则退回一次全树扫描保底。
    ///
    /// 每个会话只有一个扫描循环任务；事件只累积到 PendingScan，循环每次取快照、
    /// 覆盖成功后 **只减快照目录**——await 期间新到的目录不会被一起清掉。
    private var pendingScans: [String: PendingScan] = [:]
    private var scanTasks: [String: Task<Void, Never>] = [:]
    static let maxScanRetryAttempts = 5

    /// 会话级待扫描状态（纯值 + 纯函数，便于直测竞态语义）。
    struct PendingScan: Equatable {
        var directories: Set<String> = []
        var eventID: UInt64 = 0

        mutating func note(_ directories: [String], eventID: UInt64) {
            self.directories.formUnion(directories)
            self.eventID = max(self.eventID, eventID)
        }

        /// 覆盖成功后只减本次快照里的目录；期间新追加的目录必须保留。
        mutating func acknowledge(_ scanned: [String]) {
            directories.subtract(scanned)
        }

        var isEmpty: Bool { directories.isEmpty }
    }
    /// 启动进行中又收到 start（stop→start 竞态）：本轮启动结束后按"最新意图"重跑，
    /// 不能因为 startingSessions 里已有条目就直接 return（那会让新 workspace 永久无监听）。
    private var restartRequested: Set<String> = []

    private init() {}

    func start(
        sessionId: String,
        root: String,
        jobs: any JobAPI,
        settings: any SettingsAPI,
        attempt: Int = 1
    ) async {
        guard watchers[sessionId] == nil else { return }
        if startingSessions.contains(sessionId) {
            // 最新意图是"要监听"：登记重跑，清掉上一轮 stop 留下的取消标记。
            restartRequested.insert(sessionId)
            cancelledStarts.remove(sessionId)
            return
        }
        startingSessions.insert(sessionId)
        cancelledStarts.remove(sessionId)
        defer {
            startingSessions.remove(sessionId)
            // 本轮结束后若又收到过 start 请求（且没有在重试队列里），立刻重跑一次。
            if restartRequested.remove(sessionId) != nil,
               retryTasks[sessionId] == nil {
                Task { @MainActor in
                    await self.start(
                        sessionId: sessionId, root: root, jobs: jobs, settings: settings)
                }
            }
        }
        let path = (root as NSString).standardizingPath
        guard !path.isEmpty else {
            GatherLogger.log(
                "directory watcher skipped: empty root for \(sessionId)", level: .warn)
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            // 外接盘未挂载/目录暂时不可达：和 FSEventStream 起不来同样处理（重试），
            // 不能静默变成"永无监听"。
            GatherLogger.log(
                "directory watcher root missing for \(sessionId) at \(path) "
                    + "(attempt \(attempt)/\(Self.maxStartAttempts))",
                level: .warn)
            scheduleRetry(
                sessionId: sessionId, root: root, jobs: jobs, settings: settings,
                attempt: attempt + 1)
            return
        }

        // 单键 JSON 对象：SettingsService 只接受 knownSettingKeys，动态 key 会被拒。
        let keyName = "watch.lastEventIDs"
        if lastEventIDs[sessionId] == nil {
            do {
                let key = try SettingsKey(keyName)
                let raw = try await settings.get(key)
                do {
                    let value = try JSONValue.parse(raw)
                    if let stored = value.objectValue?[sessionId]?.stringValue {
                        lastEventIDs[sessionId] = UInt64(stored)
                    }
                } catch {
                    // 损坏的 eventID 表按"无历史"处理。
                }
            } catch {
                // 键不存在（首次启动）不是错误。
            }
        }

        guard !cancelledStarts.contains(sessionId) else { return }
        let watcher = DirectoryWatcher(paths: [path], latency: 0.6) { [weak self] change in
            Task { @MainActor in
                guard let self else { return }
                // P2：只扫发生变化的目录（事件已按目录合并）。全树扫描留给
                // MustScanSubDirs/RootChanged 与"窄扫描被活跃任务吞掉"的保底路径。
                self.noteScanChange(
                    sessionId: sessionId, directories: change.directories,
                    eventID: change.lastEventID, jobs: jobs, settings: settings,
                    keyName: keyName)
            }
        }
        guard watcher.start(sinceEventID: lastEventIDs[sessionId] ?? 0) else {
            // 起不来（FSEventStream 创建失败/路径失效）必须可见：否则上层以为在监听，
            // 外部改动永远不会触发增量扫描。除了日志，再退避重试（最多 3 次）。
            GatherLogger.log(
                "directory watcher failed to start for \(sessionId) at \(path) "
                    + "(attempt \(attempt)/\(Self.maxStartAttempts))",
                level: .warn)
            scheduleRetry(
                sessionId: sessionId, root: root, jobs: jobs, settings: settings,
                attempt: attempt + 1)
            return
        }
        retryTasks.removeValue(forKey: sessionId)?.cancel()
        watchers[sessionId] = watcher
    }

    // MARK: - P2：窄范围扫描与保底

    /// 记录一次目录变更并确保该会话的扫描循环在跑。
    ///
    /// 事件只累积、不直接发请求：循环每次取快照，覆盖成功后只减快照目录。
    /// 这样 await 期间新到的目录不会被"pending = nil"一起清掉（旧实现会丢事件）。
    private func noteScanChange(
        sessionId: String,
        directories: [String],
        eventID: UInt64,
        jobs: any JobAPI,
        settings: any SettingsAPI,
        keyName: String
    ) {
        var state = pendingScans[sessionId] ?? PendingScan()
        state.note(directories, eventID: eventID)
        pendingScans[sessionId] = state
        lastEventIDs[sessionId] = max(eventID, lastEventIDs[sessionId] ?? 0)
        guard scanTasks[sessionId] == nil else { return }
        scanTasks[sessionId] = Task { @MainActor [weak self] in
            await self?.runScanLoop(
                sessionId: sessionId, jobs: jobs, settings: settings, keyName: keyName)
        }
    }

    /// 单会话扫描循环：取快照 → start → 校验 checkpoint → ack 快照 → 直到 pending 空。
    private func runScanLoop(
        sessionId: String,
        jobs: any JobAPI,
        settings: any SettingsAPI,
        keyName: String
    ) async {
        var attempt = 1
        // 全树回退失败时不再自动重开循环（避免 2s 一次的空转）；等下一次事件重试。
        var restartIfPending = true
        defer {
            scanTasks[sessionId] = nil
            // 循环退出瞬间又来了新事件：补一条循环，避免 pending 永久滞留。
            if restartIfPending, pendingScans[sessionId]?.isEmpty == false {
                scanTasks[sessionId] = Task { @MainActor [weak self] in
                    await self?.runScanLoop(
                        sessionId: sessionId, jobs: jobs, settings: settings, keyName: keyName)
                }
            }
        }
        while !Task.isCancelled {
            guard let snapshot = pendingScans[sessionId], !snapshot.isEmpty else {
                await persistEventID(
                    sessionId: sessionId, settings: settings, keyName: keyName)
                pendingScans[sessionId] = nil
                return
            }
            let dirs = snapshot.directories.sorted()
            var request = JobCreateParams.metadataScan(
                sessionId: sessionId, requestedPaths: dirs)
            // 独立 dedupeKey：不污染手动 index.scan 的 checkpoint 继承。
            request.dedupeKey += ":watch"
            do {
                let handle = try await jobs.start(request)
                let job = try await jobs.list(JobListFilter(includeCheckpoint: true))
                    .first { $0.id == handle.id }
                if let job, !Self.covers(job.checkpoint, directories: dirs) {
                    // 被并进更窄的活跃扫描：本次目录未覆盖，退避后重试。
                    attempt += 1
                    if attempt > Self.maxScanRetryAttempts {
                        restartIfPending = await runFullScanFallback(
                            sessionId: sessionId, jobs: jobs, settings: settings,
                            keyName: keyName)
                        return
                    }
                    GatherLogger.log(
                        "directory watcher scan deduped into a narrower job for \(sessionId) "
                            + "(attempt \(attempt)/\(Self.maxScanRetryAttempts))",
                        level: .warn)
                    do {
                        try await Task.sleep(for: .seconds(1 << (attempt - 1)))
                    } catch {
                        return
                    }
                    continue
                }
                // 覆盖成功：只确认本次快照；期间新到的目录留在 pending 继续下一轮。
                pendingScans[sessionId]?.acknowledge(dirs)
                attempt = 1
                if pendingScans[sessionId]?.isEmpty == true {
                    await persistEventID(
                        sessionId: sessionId, settings: settings, keyName: keyName)
                    pendingScans[sessionId] = nil
                    return
                }
            } catch {
                GatherLogger.log(
                    "directory watcher enqueue scan failed for \(sessionId): \(error)",
                    level: .warn)
                attempt += 1
                if attempt > Self.maxScanRetryAttempts {
                    restartIfPending = await runFullScanFallback(
                        sessionId: sessionId, jobs: jobs, settings: settings,
                        keyName: keyName)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1 << (attempt - 1)))
                } catch {
                    return
                }
            }
        }
    }

    /// 超过重试上限：退回一次全树扫描（宁可多扫，不能漏扫）。
    ///
    /// 只确认"发起全树扫描时"的目录快照；扫描期间新到的目录保留。
    /// 返回 true = 已覆盖快照（新目录可继续下一轮）；false = 保底也失败，等下次事件。
    private func runFullScanFallback(
        sessionId: String,
        jobs: any JobAPI,
        settings: any SettingsAPI,
        keyName: String
    ) async -> Bool {
        let covered = Array(pendingScans[sessionId]?.directories ?? [])
        var request = JobCreateParams.metadataScan(
            sessionId: sessionId, requestedPaths: nil)
        request.dedupeKey += ":watch"
        do {
            _ = try await jobs.start(request)
            pendingScans[sessionId]?.acknowledge(covered)
            if pendingScans[sessionId]?.isEmpty != false {
                await persistEventID(sessionId: sessionId, settings: settings, keyName: keyName)
                pendingScans[sessionId] = nil
            }
            return true
        } catch {
            // 保底也失败：保留 pending，等下一次事件或会话重激活再试。
            GatherLogger.log(
                "directory watcher full-tree fallback failed for \(sessionId): \(error) "
                    + "(pending dirs: \(pendingScans[sessionId]?.directories.count ?? 0))",
                level: .warn)
            return false
        }
    }

    private func persistEventID(
        sessionId: String,
        settings: any SettingsAPI,
        keyName: String
    ) async {
        do {
            let key = try SettingsKey(keyName)
            // 只合并当前会话的 eventID：整表写回会把其它会话"尚未扫完"的 ID
            // 一起持久化（崩溃后那些目录就永久漏扫了）。
            var map: [String: JSONValue] = [:]
            do {
                let current = try await settings.get(key)
                let value = try JSONValue.parse(current)
                if let object = value.objectValue { map = object }
            } catch {
                // 键不存在（首次写入）或历史值损坏：按空表覆盖即可。
            }
            if let eventID = lastEventIDs[sessionId] {
                map[sessionId] = .string(String(eventID))
            }
            let encoded = try JSONValue.stringify(.object(map))
            try await settings.set(SettingsSetInput(
                key: key, value: try SettingsValue(encoded)))
        } catch {
            GatherLogger.log(
                "persist watcher event id failed for \(sessionId): \(error)", level: .warn)
        }
    }

    /// checkpoint 是否覆盖给定目录：没有 requestedPaths = 全树扫描（覆盖一切）。
    nonisolated static func covers(_ checkpoint: [String: JSONValue], directories: [String]) -> Bool {
        guard let raw = checkpoint[JobCreateParams.metadataScanRequestedPathsKey],
              let elements = raw.arrayElements else {
            return true
        }
        let roots = elements.compactMap(\.stringValue)
        return directories.allSatisfy { directory in
            let candidate = (directory as NSString).standardizingPath
            return roots.contains { root in
                let normalized = (root as NSString).standardizingPath
                return candidate == normalized || candidate.hasPrefix(normalized + "/")
            }
        }
    }

    /// 退避重试：第 2 次尝试等 15s、第 3 次 30s、第 4 次 60s；超过上限只留日志
    /// （会话重新激活时还会再试一轮）。
    private func scheduleRetry(
        sessionId: String,
        root: String,
        jobs: any JobAPI,
        settings: any SettingsAPI,
        attempt: Int
    ) {
        guard attempt <= Self.maxStartAttempts else { return }
        retryTasks[sessionId]?.cancel()
        retryTasks[sessionId] = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(15 << (attempt - 2)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.start(
                sessionId: sessionId, root: root, jobs: jobs, settings: settings,
                attempt: attempt)
        }
    }

    func stop(sessionId: String) {
        if startingSessions.contains(sessionId) { cancelledStarts.insert(sessionId) }
        retryTasks.removeValue(forKey: sessionId)?.cancel()
        scanTasks.removeValue(forKey: sessionId)?.cancel()
        pendingScans[sessionId] = nil
        watchers.removeValue(forKey: sessionId)?.stop()
    }

    /// 应用退出：停掉全部 watcher（不清理 eventId，下次启动继续续传）。
    func stopAll() {
        restartRequested.removeAll()
        cancelledStarts.formUnion(startingSessions)
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        for task in scanTasks.values { task.cancel() }
        scanTasks.removeAll()
        pendingScans.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }
}

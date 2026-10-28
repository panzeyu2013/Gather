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
                do {
                    // 用全树增量扫描：窄目录 checkpoint 会被后续"全树扫描"继承，
                    // 且活跃任务会吞掉新事件目录；全树语义下事件收敛才成立。
                    // 独立 dedupeKey 防止污染手动 index.scan 的 checkpoint。
                    var request = JobCreateParams.metadataScan(
                        sessionId: sessionId, requestedPaths: nil)
                    request.dedupeKey += ":watch"
                    _ = try await jobs.start(request)
                } catch {
                    GatherLogger.log(
                        "directory watcher enqueue scan failed for \(sessionId): \(error)",
                        level: .warn)
                    // 入队失败不得推进 eventID：否则这批改动永远不再被扫到。
                    return
                }
                self?.lastEventIDs[sessionId] = change.lastEventID
                do {
                    let key = try SettingsKey(keyName)
                    let map = self?.lastEventIDs ?? [:]
                    let encoded = try JSONValue.stringify(.object(
                        map.mapValues { .string(String($0)) }))
                    try await settings.set(SettingsSetInput(
                        key: key, value: try SettingsValue(encoded)))
                } catch {
                    GatherLogger.log(
                        "persist watcher event id failed for \(sessionId): \(error)", level: .warn)
                }
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
        watchers.removeValue(forKey: sessionId)?.stop()
    }

    /// 应用退出：停掉全部 watcher（不清理 eventId，下次启动继续续传）。
    func stopAll() {
        restartRequested.removeAll()
        cancelledStarts.formUnion(startingSessions)
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }
}

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

    private init() {}

    func start(sessionId: String, root: String, jobs: any JobAPI, settings: any SettingsAPI) async {
        guard watchers[sessionId] == nil,
              !startingSessions.contains(sessionId) else { return }
        startingSessions.insert(sessionId)
        cancelledStarts.remove(sessionId)
        defer { startingSessions.remove(sessionId) }
        let path = (root as NSString).standardizingPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }

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
        watcher.start(sinceEventID: lastEventIDs[sessionId] ?? 0)
        watchers[sessionId] = watcher
    }

    func stop(sessionId: String) {
        if startingSessions.contains(sessionId) { cancelledStarts.insert(sessionId) }
        watchers.removeValue(forKey: sessionId)?.stop()
    }

    /// 应用退出：停掉全部 watcher（不清理 eventId，下次启动继续续传）。
    func stopAll() {
        cancelledStarts.formUnion(startingSessions)
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }
}

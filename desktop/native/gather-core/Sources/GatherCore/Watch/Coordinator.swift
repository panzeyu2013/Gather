// desktop/native/gather-core/Sources/GatherCore/Watch/Coordinator.swift
// TS 源: desktop/src/main/services/indexer/index.service.ts（watcher 段 313–586，重写）
// Phase 2.4 文件监控（需 macOS）。
//
// 技术选型修正：计划原文写 NSFileCoordinator/FileProvider——NSFileCoordinator 是
// 文件读写协调（iCloud/Provider 冲突处理）API，不提供目录事件监控；FileProvider
// 是托管扩展框架，同样不适用本地目录监控。fs.watch(recursive) 在 macOS 底层
// 就是 FSEvents，因此本实现直接用 FSEventStream（CoreServices），语义与 TS
// 完全对齐，且能拿到绝对路径 + 文件级事件标志（TS 只能拿到相对文件名）。
//
// 行为契约（与 TS 逐条对应）：
//   - 每 session 一个递归 watcher，根路径 = session.source_path
//   - 受支持扩展名文件事件 → 750ms 去抖窗口内的增量候选路径集合（Set 去重）
//   - 目录事件/未知事件/内核丢事件 → watcherNeedsFullScan（全量对账兜底，
//     TS 注释原话："Directory changes can introduce/remove multiple files, so
//     a complete reconciliation is the only safe fallback"）
//   - 去抖触发：fullScan 优先于增量（有 recoveryScanScheduler 走 job，否则
//     直接全量）；增量走 scanHandler(sessionId, changed)
//   - watcher 注册失败 / RootChanged（根被移动/删除，等价 fs.watch error）→
//     close + needsFullScan + recoveryScanScheduler
//   - 15s 轮询对账（session 增删注册/注销靠它）
//   - stop 清空全部状态（timers/pending/needsFullScan/watchers）
//
// 与 TS 的差异（均是有意的增强，不改变语义）：
//   - FSEvents 直接给绝对路径，不需要 path.join(source, relative)
//   - 目录事件用 ItemIsDir 标志显式识别（TS 只能靠扩展名猜）
//   - 内核丢事件（MustScanSubDirs/UserDropped/KernelDropped）显式判全量，
//     这是"周期性全量对账兜底"的 FSEvents 原生形态（ROADMAP 1.6 决策 B）
import Foundation
import CoreServices

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 文件监控协调器：FSEvents 递归 watcher + 每 session 750ms 去抖 + 全量兜底。
/// 用法：注入 sessionProvider（等价 sessionStore.list() 过滤 source_path）与
/// scanHandler（等价 scanSession：requestedPaths=nil 即全量），setRecoveryScan
/// Scheduler 等价 TS 的 setRecoveryScanScheduler。
public final class WatchCoordinator {
    /// TS: SUPPORTED（index.service.ts 顶部）。
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "heif",
        "nef", "arw", "cr2", "cr3", "dng", "raf", "orf", "rw2", "pef", "srw",
        "tif", "tiff", "psd",
    ]

    /// TS: 750ms 去抖窗口。
    public static let debounceMs = 750
    /// TS: 15s 轮询对账间隔。
    public static let refreshIntervalMs = 15_000

    /// sessionProvider: 返回当前全部活跃 session（含 source_path）。
    public typealias SessionProvider = () -> [(sessionId: String, sourcePath: String)]
    /// scanHandler: 等价 scanSession。requestedPaths=nil 表示全量扫描。
    public typealias ScanHandler = (_ sessionId: String, _ requestedPaths: [String]?) -> Void

    private struct SessionWatch {
        let root: String
        let stream: FSEventStreamRef
        let context: StreamContext
        let contextPointer: UnsafeMutableRawPointer
    }

    /// FSEventStream 回调上下文：持有 sessionId（流注册时决定）与 coordinator
    /// 引用。生命周期用 Unmanaged.passRetained 交给 stream 持有（+1），
    /// 关闭时在队列上 release —— 保证任何已入队的回调先于 context 释放执行。
    private final class StreamContext {
        let sessionId: String
        weak var coordinator: WatchCoordinator?
        init(sessionId: String, coordinator: WatchCoordinator) {
            self.sessionId = sessionId
            self.coordinator = coordinator
        }
    }

    private let sessionProvider: SessionProvider
    private let scanHandler: ScanHandler
    private let debounceInterval: TimeInterval
    private let refreshInterval: TimeInterval

    /// 所有状态变更与回调处理都在串行队列上，无锁。
    private let queue = DispatchQueue(label: "gather.watch-coordinator")
    private var watchers: [String: SessionWatch] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    private var pendingPaths: [String: Set<String>] = [:]
    private var needsFullScan: Set<String> = []
    private var recoveryScanScheduler: ((String) -> Void)?
    private var refreshTimer: DispatchSourceTimer?

    public init(
        sessionProvider: @escaping SessionProvider,
        scanHandler: @escaping ScanHandler,
        debounceInterval: TimeInterval = Double(WatchCoordinator.debounceMs) / 1000,
        refreshInterval: TimeInterval = Double(WatchCoordinator.refreshIntervalMs) / 1000
    ) {
        self.sessionProvider = sessionProvider
        self.scanHandler = scanHandler
        self.debounceInterval = debounceInterval
        self.refreshInterval = refreshInterval
    }

    deinit {
        // 兜底：未 stop 即释放时关闭全部流（正常路径走 stop）。
        for (_, watch) in watchers {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamSetDispatchQueue(watch.stream, nil)
            FSEventStreamRelease(watch.stream)
            Unmanaged<StreamContext>.fromOpaque(watch.contextPointer).release()
        }
    }

    /// TS: setRecoveryScanScheduler —— 全量对账走 job 的路由。
    public func setRecoveryScanScheduler(_ scheduler: ((String) -> Void)?) {
        queue.async { [weak self] in
            self?.recoveryScanScheduler = scheduler
        }
    }

    /// TS: startWatchers —— 幂等；注册当前 session 并启动 15s 轮询对账。
    public func start() {
        queue.sync { [weak self] in
            guard let self else { return }
            reconcileSessions()
            if refreshTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
                timer.setEventHandler { [weak self] in
                    self?.reconcileSessions()
                }
                timer.resume()
                refreshTimer = timer
            }
        }
    }

    /// TS: stopWatchers —— 清空全部状态并关闭所有 watcher。
    public func stop() {
        queue.sync { [weak self] in
            guard let self else { return }
            refreshTimer?.cancel()
            refreshTimer = nil
            for (sessionId, watch) in watchers {
                closeWatcher(sessionId: sessionId, watch: watch)
            }
            watchers.removeAll()
        }
    }

    /// 测试探针：当前注册的 session 根路径。
    var activeRoots: [String: String] {
        queue.sync { watchers.mapValues { $0.root } }
    }

    /// TS: startWatchers 主体 —— 注销根路径变化的 watcher，注册新 session。
    private func reconcileSessions() {
        let sessions = sessionProvider()
        let activeRoots = Dictionary(
            sessions.map { ($0.sessionId, $0.sourcePath) },
            uniquingKeysWith: { first, _ in first }
        )
        for (sessionId, watch) in watchers {
            if activeRoots[sessionId] != watch.root {
                closeWatcher(sessionId: sessionId, watch: watch)
            }
        }
        for session in sessions {
            guard !session.sourcePath.isEmpty, watchers[session.sessionId] == nil else { continue }
            do {
                let watch = try startStream(sessionId: session.sessionId, root: session.sourcePath)
                watchers[session.sessionId] = watch
                // 注册成功后若此前欠着全量标记（失败恢复），补调度一次全量。
                if needsFullScan.remove(session.sessionId) != nil {
                    recoveryScanScheduler?(session.sessionId)
                }
            } catch {
                // TS: watch() 抛异常 → warn + needsFullScan + scheduler。
                GatherLogger.log("Unable to watch session \(session.sessionId): \(error)", level: .warn)
                registerFullScanRecovery(sessionId: session.sessionId)
            }
        }
    }

    /// TS: watcher error 处理 —— close + needsFullScan + scheduler（幂等去重）。
    private func registerFullScanRecovery(sessionId: String) {
        if !needsFullScan.contains(sessionId) {
            needsFullScan.insert(sessionId)
            recoveryScanScheduler?(sessionId)
        }
    }

    private func closeWatcher(sessionId: String, watch: SessionWatch) {
        FSEventStreamStop(watch.stream)
        FSEventStreamInvalidate(watch.stream)
        FSEventStreamSetDispatchQueue(watch.stream, nil)
        FSEventStreamRelease(watch.stream)
        watchers.removeValue(forKey: sessionId)
        timers[sessionId]?.cancel()
        timers.removeValue(forKey: sessionId)
        pendingPaths.removeValue(forKey: sessionId)
        needsFullScan.remove(sessionId)
        // context 延迟到队列上释放：已入队的回调（若有）先于 release 执行完，
        // 且用 stream 引用匹配（handleEvent 内）拒绝过期回调，不会误用。
        queue.async { [contextPointer = watch.contextPointer] in
            Unmanaged<StreamContext>.fromOpaque(contextPointer).release()
        }
    }

    /// FSEvents 回调返回 realpath（`/var` → `/private/var` 等符号链接已解析），
    /// 与注册路径可能前缀不同。统一 canonical 化后再进入 pending 集合与
    /// 去抖比对，保证事件路径与扫描侧路径一致（TS 侧等价物是
    /// canonicalPath/textualPath，index.service.ts:26）。
    /// 注意：必须用 POSIX realpath（等价 TS realpathSync.native）——
    /// URL.resolvingSymlinksInPath() 在 macOS 上不解析 /var → /private/var。
    /// realpath 失败时（路径已删除，删除事件的常态）回退到纯字符串映射
    /// （等价 TS textualPath：macOS 仅 /var、/tmp 两个符号链接前缀）。
    private static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let resolved = path
        if resolved == "/var" || resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        if resolved == "/tmp" || resolved.hasPrefix("/tmp/") {
            return "/private" + resolved
        }
        return resolved
    }

    /// FSEventStream 注册。等价 TS watch() 的 ENOENT：路径不存在（或不可读）
    /// 抛注册失败，由 reconcile 走 needsFullScan + recoveryScanScheduler 兜底。
    /// 注意：FSEventStreamCreate 对不存在的路径不会返回 nil（流照常创建，
    /// 只是永无事件），必须显式检查存在性。
    private func startStream(sessionId: String, root: String) throws -> SessionWatch {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WatchError.streamCreateFailed(path: root)
        }
        let context = StreamContext(sessionId: sessionId, coordinator: self)
        var streamContext = FSEventStreamContext()
        streamContext.version = 0
        // +1 引用交给 stream 持有；回调信息（info）在整个流生命周期内有效。
        streamContext.info = Unmanaged.passRetained(context).toOpaque()
        // 用 canonical 路径注册：回调事件路径与 root 前缀一致（见 canonicalPath）。
        let watchRoot = Self.canonicalPath(root)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            WatchCoordinator.eventCallback,
            &streamContext,
            [watchRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0, // latency：TS fs.watch 无延迟，事件即达（去抖在内部做）
            flags
        ) else {
            Unmanaged<StreamContext>.fromOpaque(streamContext.info!).release()
            throw WatchError.streamCreateFailed(path: root)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamRelease(stream)
            Unmanaged<StreamContext>.fromOpaque(streamContext.info!).release()
            throw WatchError.streamStartFailed(path: root)
        }
        return SessionWatch(
            root: root,
            stream: stream,
            context: context,
            contextPointer: streamContext.info!
        )
    }

    private static let eventCallback: FSEventStreamCallback = { stream, info, numEvents, pathsRaw, flagsRaw, _ in
        guard let info else { return }
        let context = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
        guard let coordinator = context.coordinator else { return }
        // kFSEventStreamCreateFlagUseCFTypes：eventPaths 是 CFArrayRef of CFStringRef。
        let cfArray = Unmanaged<CFArray>.fromOpaque(pathsRaw).takeUnretainedValue()
        let paths = cfArray as? [String] ?? []
        for index in 0..<numEvents where index < paths.count {
            coordinator.handleEvent(sessionId: context.sessionId, stream: stream, path: paths[index], flags: flagsRaw[index])
        }
    }

    /// 事件分流（等价 TS 的 fs.watch 回调）：
    ///   - RootChanged → 关闭 watcher + 全量兜底（等价 TS error 事件）
    ///   - 内核丢事件 / 目录事件 / 未知事件 → needsFullScan
    ///   - 受支持扩展名文件事件 → pending 集合
    /// 随后重置去抖窗口（750ms）。
    /// 注意：stream 参数用于拒绝已关闭流的过期回调（close 与回调同队列，
    /// 但已入队的回调可能在注销后执行——此时 watchers 中已是新流或无流）。
    private func handleEvent(sessionId: String, stream: FSEventStreamRef, path: String, flags: FSEventStreamEventFlags) {
        guard let watch = watchers[sessionId], watch.stream == stream else {
            return // 过期回调（watcher 已注销/更换）
        }
        let rootChanged = flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
        if rootChanged {
            GatherLogger.log("Watch root changed for session \(sessionId); scheduling full reconciliation", level: .warn)
            closeWatcher(sessionId: sessionId, watch: watch)
            registerFullScanRecovery(sessionId: sessionId)
            return
        }
        let dropped = flags & UInt32(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        ) != 0
        let isDirectory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let canonical = Self.canonicalPath(path)
        if dropped || isDirectory || !Self.isSupportedFile(canonical) {
            // 目录变化/丢事件可引入或移除多个文件，完整对账是唯一安全兜底。
            needsFullScan.insert(sessionId)
        } else {
            pendingPaths[sessionId, default: []].insert(canonical)
        }
        scheduleDebounce(sessionId: sessionId)
    }

    private static func isSupportedFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// TS: setTimeout(750) —— 重置式去抖。
    private func scheduleDebounce(sessionId: String) {
        timers[sessionId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushDebounce(sessionId: sessionId)
        }
        timers[sessionId] = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// TS: 去抖触发 —— fullScan 优先；有 scheduler 走 job，否则全量；否则增量。
    private func flushDebounce(sessionId: String) {
        timers.removeValue(forKey: sessionId)
        let changed = pendingPaths.removeValue(forKey: sessionId).map { Array($0) } ?? []
        let fullScan = needsFullScan.remove(sessionId) != nil
        if fullScan {
            if let scheduler = recoveryScanScheduler {
                scheduler(sessionId)
                return
            }
            scanHandler(sessionId, nil)
            return
        }
        guard !changed.isEmpty else { return }
        // TS: scanSession 失败仅 warn，不触发全量兜底。
        scanHandler(sessionId, changed)
    }
}

enum WatchError: Error, CustomStringConvertible {
    case streamCreateFailed(path: String)
    case streamStartFailed(path: String)

    var description: String {
        switch self {
        case .streamCreateFailed(let path): return "FSEventStreamCreate failed for \(path)"
        case .streamStartFailed(let path): return "FSEventStreamStart failed for \(path)"
        }
    }
}

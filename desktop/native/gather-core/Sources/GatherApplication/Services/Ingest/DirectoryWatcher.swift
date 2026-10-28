// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/DirectoryWatcher.swift
// P1 / D：目录变更监听（FSEvents）。
//
// 语义边界（Apple 文档明确"不是细粒度通知"）：
// - 默认只保证"目录里有东西变了"；必须置 kFSEventStreamCreateFlagFileEvents 才拿到文件路径；
// - 事件会合并，因此调用方拿到的是"需要重扫的目录集合"，不是"改了哪些文件"；
// - eventId 可持久化：进程重启后按 sinceEventId 补扫，避免停机期间的新文件漏掉。
import Foundation
import CoreServices

public struct DirectoryChange: Equatable, Sendable {
    /// 发生变化的目录（已去重、已排序）。
    public var directories: [String]
    /// 最近一次事件 id（持久化后供下次 sinceEventId 使用）。
    public var lastEventID: UInt64

    public init(directories: [String], lastEventID: UInt64) {
        self.directories = directories
        self.lastEventID = lastEventID
    }
}

public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (DirectoryChange) -> Void

    private let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pending: Set<String> = []
    private var lastEventID: UInt64 = 0

    /// - paths: 要监听的目录（不存在会被系统忽略，不会抛错）。
    /// - latency: 合并窗口（0.3s 是"用户能感知到新文件"的常见取值）。
    public init(paths: [String], latency: TimeInterval = 0.3, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
        self.queue = DispatchQueue(label: "app.gather.directory-watcher", qos: .utility)
        self.queue.setSpecific(key: Self.queueKey, value: 1)
    }

    /// 启动；sinceEventID 为 0 表示"只看启动之后的变化"。
    /// 返回 false = 没起起来（空路径或 FSEventStream 创建失败）——调用方必须
    /// 显式处理，不能以为"已经在监听"。
    @discardableResult
    public func start(sinceEventID: UInt64 = 0) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // 未置 UseCFTypes 时 eventPaths 是 C 字符串数组（char **）。
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changed: [String] = []
            var lastID: UInt64 = 0
            var forceRoots = false
            for index in 0..<Int(count) {
                changed.append(String(cString: paths[index]))
                lastID = max(lastID, UInt64(eventIds[index]))
                let flags = eventFlags[index]
                let rescan: FSEventStreamEventFlags =
                    FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                if flags & rescan != 0 { forceRoots = true }
            }
            watcher.ingest(paths: changed, lastEventID: lastID, forceRoots: forceRoots)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // 不置 UseCFTypes：用原始 C 字符串数组，避免 CFArray 桥接的额外拷贝。
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        // sinceEventID == 0 不是"从此刻起"，而是"从开机以来"——必须显式用 SinceNow，
        // 否则启动瞬间会收到大量历史事件（整目录重扫）。
        let since = sinceEventID == 0 ? UInt64(kFSEventStreamEventIdSinceNow) : sinceEventID
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(since),
            latency,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        lock.lock()
        let previous = self.stream
        self.stream = stream
        lock.unlock()
        // 并发 start：后到的胜出，先到的流必须停掉，否则会留下第二条仍在回调的流。
        if let previous { teardown(previous) }
        return true
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        if let current { teardown(current) }
    }

    /// 停掉一条流（幂等；可在 start 内对"被后来者顶掉"的旧流复用）。
    private func teardown(_ target: FSEventStreamRef) {
        FSEventStreamStop(target)
        FSEventStreamInvalidate(target)
        // 回调通过 passUnretained(self) 取回 watcher：先解绑 dispatch queue，再把在途
        // 回调排空，最后才 release，否则"stop 后析构 + 迟到的回调"就是 use-after-free。
        FSEventStreamSetDispatchQueue(target, nil)
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }
        FSEventStreamRelease(target)
    }

    /// 标记"当前是否运行在本 watcher 的队列上"（在队列内 sync 会自锁）。
    private static let queueKey = DispatchSpecificKey<UInt8>()

    deinit { stop() }

    /// 事件合并：把这一批路径归到"最深的父目录"，交给上层做整目录 rescan。
    private func ingest(paths: [String], lastEventID: UInt64, forceRoots: Bool) {
        lock.lock()
        self.lastEventID = max(self.lastEventID, lastEventID)
        if forceRoots {
            // 目录被改名/挂载点变化：具体文件路径不可信，让上层重扫全部监听根。
            pending.formUnion(self.paths)
        } else {
            for path in paths {
                let directory = (path as NSString).deletingLastPathComponent
                pending.insert(directory.isEmpty ? path : directory)
            }
        }
        let directories = pending.sorted()
        pending.removeAll()
        let eventID = self.lastEventID
        lock.unlock()
        guard !directories.isEmpty else { return }
        handler(DirectoryChange(directories: directories, lastEventID: eventID))
    }
}

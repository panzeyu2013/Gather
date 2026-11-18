// desktop/native/gather-app/Sources/GatherUI/Support/ThumbnailDiskCache.swift
// A-3（性能审计）：持久化缩略图缓存。
//
// 旧实现只有进程内 NSCache（512MB，按实测 cost 1024 档 3.24MB/张 ≈ 只容 161 张），
// 冷启动与滚动回看都要从原图重解（实测 256px 18.6ms / RAW 100-800ms）。
// 这里把**解码产出的 JPEG** 直接落盘：键含源文件 mtime + size，源文件一改自动失效。
//
// 默认关闭，由 App 启动时显式打开（isEnabled = true）——这样单元测试与
// 基准不会被上一次运行的缓存污染。

import Foundation
// Cut 3 / 3b-3：缓存键的 SHA-256 用系统 CryptoKit（GatherPersistence 的
// SHA256 属于下层 target，GatherUI 不得 import）；摘要算法与 hex 输出一致。
import CryptoKit
import GatherProtocol

/// 可变状态盒子（与 PhotoThumbnailCacheBox 同风格）：锁纪律无法被编译器静态验证，
/// 因此标注 @unchecked Sendable；所有读写都在 stateLock 临界区内。
private final class ThumbnailDiskCacheState: @unchecked Sendable {
    let lock = NSLock()
    var enabled = false
    var directory: URL?
    /// prune 节流（每次解码都枚举整个缓存目录会成为新的 IO 热点）。
    var storesSincePrune = 0
    var bytesSincePrune = 0
    var lastPruneAt = Date.distantPast
    var overridden: URL?
    /// 启动一次性 prune 是否已调度（round-3 性能；见 pruneAtStartupIfNeeded）。
    var didStartupPrune = false
}

public enum ThumbnailDiskCache {
    private static let state = ThumbnailDiskCacheState()

    /// 由 App 启动时打开（测试默认关闭，避免跨用例污染）。
    public static var isEnabled: Bool {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.enabled }
        set { state.lock.lock(); defer { state.lock.unlock() }; state.enabled = newValue }
    }

    /// 启动时一次性后台 prune（round-3 性能）。
    ///
    /// 为什么需要：上限 512MB 只在「下一次 store」才会检查——上次进程异常退出/
    /// 降版本可能留下超限目录，而且枚举目录的成本会落在触发它的那次解码后台线程上，
    /// 让首屏缩略图变慢。启动时把清理丢到 utility 队列，与本次解码解耦。
    ///
    /// 边界：只删 thumb-cache 目录内的缓存 JPEG（pruneIfNeeded 既有语义），
    /// 不触碰用户照片/设置；进程内至多调度一次；缓存未开启时不做任何事。
    package static func pruneAtStartupIfNeeded() {
        // 评审 R2-A6：先确认启用再消费一次性标志，避免「未启用时调用一次就把启动
        // prune 永久吃掉」的顺序陷阱。
        guard isEnabled else { return }
        state.lock.lock()
        let firstCall = !state.didStartupPrune
        state.didStartupPrune = true
        state.lock.unlock()
        guard firstCall else { return }
        Task.detached(priority: .utility) {
            pruneIfNeeded()
        }
    }

    /// 上限 512MB（与内存缓存同量级）；超限按修改时间从旧到新删除。
    static let maxBytes: Int64 = 512 * 1024 * 1024

#if DEBUG
    /// 目录覆盖（测试注入临时目录，避免污染真实 Application Support）。
    public static var directoryOverride: URL? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.overridden }
        set { state.lock.lock(); state.overridden = newValue; state.directory = nil; state.lock.unlock() }
    }
#endif

    private static func directory() -> URL? {
        state.lock.lock()
        defer { state.lock.unlock() }
        if let cached = state.directory { return cached }
        if let overridden = state.overridden {
            try? FileManager.default.createDirectory(at: overridden, withIntermediateDirectories: true)
            state.directory = overridden
            return overridden
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base
            .appendingPathComponent("Gather", isDirectory: true)
            .appendingPathComponent("thumb-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        state.directory = dir
        return dir
    }

    /// 缓存键 = 模式 + 解码尺寸 + 路径 + 源文件 mtime/size（一次 stat，远低于解码成本）。
    static func key(path: String, size: Int, preview: Bool) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              let mtime = attributes[.modificationDate] as? Date else { return nil }
        return "\(preview ? "preview" : "thumb"):\(size):\(path):\(Int64(mtime.timeIntervalSince1970 * 1000)):\(fileSize)"
    }

    private static func fileURL(for key: String) -> URL? {
        guard let directory = directory() else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).jpg")
    }

    /// 命中时 mtime 触碰的节流窗口（round-4 性能）。
    ///
    /// 旧实现每次命中都 `setAttributes(.modificationDate)`：一次缓存读 = stat 源文件
    /// + 读整份 JPEG + 一次 inode 元数据写。滚动回看时每个缩略图都写一次，属写放大
    /// （还会弄脏文件系统 journal）。LRU 只需要「最近一段时间有没有被用过」的粗粒度，
    /// 1h 内重复命中不再写；代价是多一次 stat（比元数据写便宜，且不产生写）。
    static let touchInterval: TimeInterval = 3600

    public static func data(path: String, size: Int, preview: Bool) -> Data? {
        guard isEnabled, let key = key(path: path, size: size, preview: preview),
              let url = fileURL(for: key) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        touchIfStale(url)
        return data
    }

    /// 触碰缓存文件 mtime 供 LRU 清理；touchInterval 内已触碰过的跳过（失败不影响读取）。
    ///
    /// LRU 正确性：prune 按 mtime 从旧到新删除，最多让热文件的 mtime 滞后 1h——
    /// 只有「超过 512MB 且已连续 1h 未被读取」的项才可能被判旧删掉。淘汰目标是清掉
    /// 真正的冷缓存，1h 粒度足够；且窗口内不写保证了读路径不产生元数据写。
    private static func touchIfStale(_ url: URL) {
        let now = Date()
        var lastModified: Date?
        do {
            lastModified = try FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        } catch {
            lastModified = nil
        }
        if let lastModified, now.timeIntervalSince(lastModified) < touchInterval { return }
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: now], ofItemAtPath: url.path)
        } catch {
            // mtime 触碰失败不影响读取（与旧实现一致：只影响 LRU 精度）。
        }
    }

    public static func store(_ data: Data, path: String, size: Int, preview: Bool) {
        guard isEnabled, !data.isEmpty, let key = key(path: path, size: size, preview: preview),
              let url = fileURL(for: key) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        schedulePruneIfNeeded(addedBytes: data.count)
    }

    /// prune 节流：每 128 次写入或距上次 ≥60s 才真正枚举目录。
    private static func schedulePruneIfNeeded(addedBytes: Int) {
        state.lock.lock()
        state.storesSincePrune += 1
        state.bytesSincePrune += addedBytes
        // 仅有条数/时间阈值会把 512MB 硬上限变成软上限（两次 prune 之间最多再进
        // 128 张 2560 档 ≈ 数百 MB）。字节阈值让上限重新成为硬约束。
        let shouldPrune = state.bytesSincePrune >= 64 * 1024 * 1024
            || state.storesSincePrune >= 128
            || Date().timeIntervalSince(state.lastPruneAt) >= 60
        if shouldPrune {
            state.storesSincePrune = 0
            state.bytesSincePrune = 0
            state.lastPruneAt = Date()
        }
        state.lock.unlock()
        guard shouldPrune else { return }
        pruneIfNeeded()
    }

    /// 超限清理：按修改时间从旧到新删，直到降到上限的 80%。
    static func pruneIfNeeded() {
        guard let directory = directory() else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }
        var total: Int64 = 0
        var files: [(url: URL, date: Date, size: Int64)] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            let fileSize = Int64(values.fileSize ?? 0)
            total += fileSize
            files.append((entry, values.contentModificationDate ?? .distantPast, fileSize))
        }
        guard total > maxBytes else { return }
        let target = Int64(Double(maxBytes) * 0.8)
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}

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
}

public enum ThumbnailDiskCache {
    private static let state = ThumbnailDiskCacheState()

    /// 由 App 启动时打开（测试默认关闭，避免跨用例污染）。
    public static var isEnabled: Bool {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.enabled }
        set { state.lock.lock(); defer { state.lock.unlock() }; state.enabled = newValue }
    }

    /// 上限 512MB（与内存缓存同量级）；超限按修改时间从旧到新删除。
    static let maxBytes: Int64 = 512 * 1024 * 1024

    /// 目录覆盖（测试注入临时目录，避免污染真实 Application Support）。
    public static var directoryOverride: URL? {
        get { state.lock.lock(); defer { state.lock.unlock() }; return state.overridden }
        set { state.lock.lock(); state.overridden = newValue; state.directory = nil; state.lock.unlock() }
    }

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

    public static func data(path: String, size: Int, preview: Bool) -> Data? {
        guard isEnabled, let key = key(path: path, size: size, preview: preview),
              let url = fileURL(for: key) else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // 触碰 mtime，供 LRU 清理（失败不影响读取）。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
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

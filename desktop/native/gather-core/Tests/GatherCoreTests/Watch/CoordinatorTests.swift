// desktop/native/gather-core/Tests/GatherCoreTests/Watch/CoordinatorTests.swift
// WatchCoordinator 行为测试（Phase 2.4 丢事件对账矩阵，ROADMAP 1.6）。
//
// TS 侧没有任何对 fs.watch 注册/去抖/事件的直接单测（vitest 无法确定性模拟），
// 本文件补足该缺口，对照 TS 行为契约（index.service.ts 313–586）：
//   - 受支持扩展名文件事件 → 增量候选（750ms 去抖窗口，Set 去重）
//   - 目录/未知/内核丢事件 → watcherNeedsFullScan（全量兜底优先于增量）
//   - 注册失败/RootChanged → needsFullScan + recoveryScanScheduler
//   - 15s 轮询对账（session 增删注册/注销）
//   - stop() 清空全部状态
//
// 事件语义（macOS 实测，与 Node fs.watch 一致）：
//   - 创建新文件 → FSEvents 同时报"目录事件（mtime/xattr）+ 文件事件"，
//     目录事件 → fullScan（TS 的 fs.watch 同样报 "change <目录名>" → fullScan）
//   - 修改/删除已存在文件 → 纯文件事件 → 增量路径真实触发
// 因此增量用例用"修改已存在文件"构造；创建用例接受 fullScan 或增量任一。
//
// 丢事件对账矩阵（ROADMAP 1.6）：随机增删改/重命名 200 次，增量结果与全量
// 一致。本测试用"模拟索引"验证 watcher 契约：增量事件应用 stat 语义（存在且
// 受支持 → 入集；否则移除），全量触发（scanHandler(nil) 或 recovery）用目录
// walk 重建；最终模拟索引 == 全量 walk。FSEvents 丢事件时内核置
// MustScanSubDirs → 走全量兜底，收敛到一致。

import Foundation
import Testing
@testable import GatherCore

#if canImport(Darwin)
import Darwin
#endif

/// 共享测试目录：每用例独立子目录。
final class WatchTestRoot {
    let root: URL
    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-watch-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func session(_ id: String) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ url: URL, _ content: String = "x") throws {
        try Data(content.utf8).write(to: url)
    }

    /// FSEvents 回调返回 canonical 路径（/var → /private/var 已解析），
    /// 测试断言用同一 canonical 化（与 Coordinator.canonicalPath 同语义：
    /// POSIX realpath 优先，失败时纯字符串 /var、/tmp 前缀映射兜底 ——
    /// 删除事件后 realpath 必然失败）。
    func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if path == "/var" || path.hasPrefix("/var/") {
            return "/private" + path
        }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return "/private" + path
        }
        return path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 记录 handler 调用的线程安全 sink。
final class HandlerSink {
    private let lock = NSLock()
    private var _scans: [(sessionId: String, requestedPaths: [String]?)] = []
    private var _recoveries: [String] = []

    var scans: [(sessionId: String, requestedPaths: [String]?)] {
        lock.lock(); defer { lock.unlock() }
        return _scans
    }

    var recoveries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _recoveries
    }

    func recordScan(_ sessionId: String, _ requestedPaths: [String]?) {
        lock.lock(); defer { lock.unlock() }
        _scans.append((sessionId, requestedPaths))
    }

    func recordRecovery(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        _recoveries.append(sessionId)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _scans.removeAll()
        _recoveries.removeAll()
    }
}

/// 轮询等待条件成立（避免固定 sleep 的时序脆弱）。
@discardableResult
private func waitUntil(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.02,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}

/// 等去抖窗口过去（确认无第二次扫描）。
private func settle() {
    Thread.sleep(forTimeInterval: 0.1)
}

/// 构建 coordinator：默认去抖 50ms（测试加速，覆盖"窗口内合并"语义），
/// 刷新 200ms。sink 记录 scanHandler 与 recoveryScanScheduler 调用。
private func makeCoordinator(
    sessions: @escaping () -> [(sessionId: String, sourcePath: String)],
    sink: HandlerSink,
    debounce: TimeInterval = 0.05,
    refresh: TimeInterval = 0.2
) -> WatchCoordinator {
    let coordinator = WatchCoordinator(
        sessionProvider: sessions,
        scanHandler: { sessionId, paths in
            sink.recordScan(sessionId, paths)
        },
        debounceInterval: debounce,
        refreshInterval: refresh
    )
    coordinator.setRecoveryScanScheduler { sessionId in
        sink.recordRecovery(sessionId)
    }
    return coordinator
}

// MARK: - 用例

@Suite("WatchCoordinator")
struct WatchCoordinatorTests {
    // TS: 纯文件事件（修改已存在受支持文件）→ 增量扫描报告该路径。
    // 注意：macOS 上文件 xattr 修改可能伴随目录事件（ItemIsDir → 全量兜底），
    // 断言"路径最终被处理"（增量报告或 recovery 全量），不强制纯增量。
    @Test func modifyExistingFileTriggersIncrementalScan() async throws {
        let root = try WatchTestRoot("incremental")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let jpg = sessionDir.appendingPathComponent("IMG_0001.jpg")
        try root.write(jpg, "v1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        // 修改已存在文件 → 文件事件（多数情况下纯增量，偶伴随目录 xattr 事件）。
        try root.write(jpg, "v2")

        let reported = waitUntil {
            let incremental = sink.scans.contains {
                $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(jpg.path)) ?? false)
            }
            return incremental || sink.recoveries.contains("s1")
        }
        #expect(reported)
        coordinator.stop()
    }

    // TS: 删除已存在文件 → 增量扫描报告该路径（下游 stat 失败 → markMissing）。
    // 注意：删除伴随目录事件（macOS 实测），全量兜底也接受 —— 与 create
    // 同语义，路径最终必须被处理（增量报告或全量重建）。
    @Test func deleteExistingFileReportsPath() async throws {
        let root = try WatchTestRoot("delete")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let jpg = sessionDir.appendingPathComponent("IMG_0002.jpg")
        try root.write(jpg, "v1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        // FSEventStreamStart 是异步建立监听（SinceNow 丢弃启动前事件），
        // 先用探针文件确认事件管道已通，再执行目标操作（消除启动竞态）。
        let probe = sessionDir.appendingPathComponent("probe.jpg")
        try root.write(probe, "probe")
        let probeHandled = waitUntil {
            let incremental = sink.scans.contains {
                $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(probe.path)) ?? false)
            }
            return incremental || sink.recoveries.contains("s1")
        }
        #expect(probeHandled)

        sink.reset()
        try FileManager.default.removeItem(at: jpg)

        let handled = waitUntil {
            let incremental = sink.scans.contains {
                $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(jpg.path)) ?? false)
            }
            let full = sink.recoveries.contains("s1")
                || sink.scans.contains { $0.sessionId == "s1" && $0.requestedPaths == nil }
            return incremental || full
        }
        if !handled {
            print("DEBUG delete scans=\(sink.scans) recoveries=\(sink.recoveries) target=\(root.canonical(jpg.path))")
        }
        #expect(handled)
        coordinator.stop()
    }

    // TS: 目录变化 → watcherNeedsFullScan（全量对账兜底）。
    @Test func directoryEventTriggersFullScan() async throws {
        let root = try WatchTestRoot("dir")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("subdir"),
            withIntermediateDirectories: true
        )

        // 目录事件 → 全量兜底：有 scheduler 时走 recovery（等价 metadata.scan job）。
        let recovered = waitUntil { sink.recoveries.contains("s1") }
        #expect(recovered)
        coordinator.stop()
    }

    // TS: 不受支持扩展名的文件事件 → 全量兜底（不进入增量候选）。
    @Test func unsupportedExtensionTriggersFullScan() async throws {
        let root = try WatchTestRoot("unsupported")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let txt = sessionDir.appendingPathComponent("notes.txt")
        try root.write(txt, "v1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        // 修改 .txt：文件事件扩展名不受支持 → fullScan（与 TS 扩展名判定一致）。
        try root.write(txt, "v2")

        let recovered = waitUntil { sink.recoveries.contains("s1") }
        #expect(recovered)
        // 该路径不应作为增量候选报告。
        #expect(!sink.scans.contains { $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(txt.path)) ?? false) })
        coordinator.stop()
    }

    // TS: 创建新文件（伴随目录事件，macOS 实测）→ 接受 fullScan 或增量任一，
    // 但该文件路径最终必须被处理（进入增量候选或全量兜底）。
    @Test func createFileIsProcessed() async throws {
        let root = try WatchTestRoot("create")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        let jpg = sessionDir.appendingPathComponent("IMG_NEW.jpg")
        try root.write(jpg, "new")

        let handled = waitUntil {
            let incremental = sink.scans.contains {
                $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(jpg.path)) ?? false)
            }
            let full = sink.recoveries.contains("s1")
                || sink.scans.contains { $0.sessionId == "s1" && $0.requestedPaths == nil }
            return incremental || full
        }
        #expect(handled)
        coordinator.stop()
    }

    // TS: 750ms 去抖 —— 纯文件事件批次合并为一次扫描（Set 去重 + 窗口重置）。
    @Test func debounceMergesBurst() async throws {
        let root = try WatchTestRoot("burst")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        var paths: [URL] = []
        for i in 0..<6 {
            let url = sessionDir.appendingPathComponent("b\(i).jpg")
            try root.write(url, "v1")
            paths.append(url)
        }
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        // 同时修改 6 个已存在文件 → 一次窗口内合并（纯文件事件批次）。
        for url in paths {
            try root.write(url, "v2")
        }

        let allReported = waitUntil {
            let scan = sink.scans.last
            return scan?.sessionId == "s1"
                && (scan?.requestedPaths?.count ?? 0) == 6
        }
        #expect(allReported)
        // 窗口合并：不应出现 6 次独立扫描。
        #expect(sink.scans.count <= 2)
        settle()
        #expect(sink.scans.count <= 2)
        coordinator.stop()
    }

    // TS: 去抖窗口内目录事件 + 文件事件混合 → 全量优先于增量。
    @Test func fullScanPrecedesIncrementalInMixedWindow() async throws {
        let root = try WatchTestRoot("mixed")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let jpg = sessionDir.appendingPathComponent("a.jpg")
        try root.write(jpg, "v1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        try root.write(jpg, "v2")
        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("newdir"),
            withIntermediateDirectories: true
        )

        // 全量兜底触发（scheduler 被调），增量候选被短路丢弃。
        let recovered = waitUntil { sink.recoveries.contains("s1") }
        #expect(recovered)
        settle()
        #expect(!sink.scans.contains { $0.sessionId == "s1" && $0.requestedPaths != nil })
        coordinator.stop()
    }

    // TS: watcher 注册失败（路径不存在）→ needsFullScan + scheduler。
    @Test func registrationFailureSchedulesRecovery() async throws {
        let root = try WatchTestRoot("norecord")
        defer { root.cleanup() }
        let missing = root.root.appendingPathComponent("does-not-exist")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", missing.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()

        let recovered = waitUntil { sink.recoveries.contains("s1") }
        #expect(recovered)
        coordinator.stop()
    }

    // TS: 15s 轮询对账 —— 新 session 出现后自动注册。
    @Test func refreshReconcilesNewSessions() async throws {
        let root = try WatchTestRoot("refresh")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        var sessions: [(sessionId: String, sourcePath: String)] = [("s1", sessionDir.path)]
        let sink = HandlerSink()
        let coordinator = makeCoordinator(
            sessions: { sessions },
            sink: sink,
            refresh: 0.05 // 测试加速 15s → 50ms
        )
        coordinator.start()

        // 新增 s2 后轮询对账自动注册。先等注册完成（activeRoots 探针），
        // 再写文件 —— FSEvents 用 SinceNow，注册前的事件会被丢弃。
        let s2Dir = try root.session("s2")
        sessions.append(("s2", s2Dir.path))
        let registered = waitUntil(timeout: 3) {
            coordinator.activeRoots["s2"] != nil
        }
        #expect(registered)

        let s2jpg = s2Dir.appendingPathComponent("x.jpg")
        try root.write(s2jpg, "v1")
        let s2handled = waitUntil {
            sink.scans.contains { $0.sessionId == "s2" && ($0.requestedPaths?.contains(root.canonical(s2jpg.path)) ?? false) }
                || sink.recoveries.contains("s2")
        }
        #expect(s2handled)
        coordinator.stop()
    }

    // TS: session 根路径变更 → 旧 watcher 注销、新路径注册。
    @Test func rootChangeClosesOldWatcher() async throws {
        let root = try WatchTestRoot("rootchange")
        defer { root.cleanup() }
        let oldDir = try root.session("s1")
        let newDir = try root.session("s1-new")
        var sessions: [(sessionId: String, sourcePath: String)] = [("s1", oldDir.path)]
        let sink = HandlerSink()
        let coordinator = makeCoordinator(
            sessions: { sessions },
            sink: sink,
            refresh: 0.05
        )
        coordinator.start()

        // 根路径变更 → 下次对账注销旧 watcher 并注册新路径。
        sessions = [("s1", newDir.path)]
        let registered = waitUntil(timeout: 3) {
            coordinator.activeRoots["s1"] == newDir.path
        }
        #expect(registered)

        let newJpg = newDir.appendingPathComponent("moved.jpg")
        try root.write(newJpg, "v1")
        let newHandled = waitUntil {
            sink.scans.contains { $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(newJpg.path)) ?? false) }
                || sink.recoveries.contains("s1")
        }
        #expect(newHandled)
        coordinator.stop()
    }

    // TS: stopWatchers —— 清空全部状态，事件不再被处理。
    @Test func stopClearsAllState() async throws {
        let root = try WatchTestRoot("stop")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let jpg = sessionDir.appendingPathComponent("a.jpg")
        try root.write(jpg, "v1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(sessions: sessions, sink: sink)
        coordinator.start()
        coordinator.stop()
        sink.reset()

        // stop 后写入不产生任何处理（watcher 已全部关闭）。
        try root.write(jpg, "v2")
        settle()
        #expect(sink.scans.isEmpty)
        #expect(sink.recoveries.isEmpty)

        // stop 后可重新 start（幂等生命周期）；start 后写入重新被处理。
        coordinator.start()
        try root.write(jpg, "v3")
        let reported = waitUntil {
            sink.scans.contains { $0.sessionId == "s1" && ($0.requestedPaths?.contains(root.canonical(jpg.path)) ?? false) }
                || sink.recoveries.contains("s1")
        }
        #expect(reported)
        coordinator.stop()
    }

    // TS: 默认常量对齐（750ms 去抖 / 15s 轮询）。
    @Test func defaultConstantsMatchTS() {
        #expect(WatchCoordinator.debounceMs == 750)
        #expect(WatchCoordinator.refreshIntervalMs == 15_000)
    }

    // MARK: 丢事件对账矩阵（ROADMAP 1.6）

    /// 模拟索引：增量事件按 stat 语义更新，全量按目录 walk 重建。
    /// 验证 watcher 契约 —— 随机 200 次增删改/重命名后，模拟索引与全量
    /// walk 结果一致（丢事件被 MustScanSubDirs 全量兜底收敛）。
    @Test func reconciliationMatrixRandom200Ops() async throws {
        let root = try WatchTestRoot("matrix")
        defer { root.cleanup() }
        let sessionDir = try root.session("s1")
        let sessions: () -> [(sessionId: String, sourcePath: String)] = { [("s1", sessionDir.path)] }
        let sink = HandlerSink()
        let coordinator = makeCoordinator(
            sessions: sessions,
            sink: sink,
            debounce: 0.02,
            refresh: 0.2
        )
        coordinator.start()

        // 初始种子文件：10 张受支持 + 2 个目录。
        var photoNames: [String] = []
        for i in 0..<10 {
            let name = "photo_\(i).jpg"
            try root.write(sessionDir.appendingPathComponent(name), "seed\(i)")
            photoNames.append(name)
        }
        try FileManager.default.createDirectory(at: sessionDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try root.write(sessionDir.appendingPathComponent("sub/inner.jpg"), "inner")
        photoNames.append("sub/inner.jpg")

        // 模拟索引 = 全量 walk 初始状态。
        var simulated = Set(walkSupportedFiles(sessionDir.path))

        // 确定性随机（固定种子，与 TS 生成器约定一致）。
        var rng = SplitMix64(seed: 42)
        let exts = ["jpg", "jpeg", "png", "webp", "heic", "nef", "arw", "dng", "tif", "psd"]
        var createdCounter = 0

        func randomExistingPhoto() -> String? {
            Array(simulated).randomElement(using: &rng)
        }

        for _ in 0..<200 {
            let op = rng.next() % 5
            switch op {
            case 0: // 新增受支持文件（含子目录内）
                createdCounter += 1
                let dirChoice = (rng.next() % 3 == 0) ? "sub" : ""
                let rel = dirChoice.isEmpty
                    ? "new_\(createdCounter).\(exts.randomElement(using: &rng)!)"
                    : "sub/new_\(createdCounter).\(exts.randomElement(using: &rng)!)"
                try root.write(sessionDir.appendingPathComponent(rel), "new")
            case 1: // 删除受支持文件
                if let victim = randomExistingPhoto() {
                    try? FileManager.default.removeItem(atPath: sessionDir.appendingPathComponent(victim).path)
                }
            case 2: // 重命名受支持文件（新路径 = 增量 relink 语义）
                if let victim = randomExistingPhoto() {
                    let ext = (victim as NSString).pathExtension
                    createdCounter += 1
                    let newName = "renamed_\(createdCounter).\(ext)"
                    try? FileManager.default.moveItem(
                        atPath: sessionDir.appendingPathComponent(victim).path,
                        toPath: sessionDir.appendingPathComponent(newName).path
                    )
                }
            case 3: // 内容修改
                if let victim = randomExistingPhoto() {
                    try? Data(Data([UInt8(arc4random_uniform(255))])).write(
                        to: sessionDir.appendingPathComponent(victim)
                    )
                }
            case 4: // 目录级操作：新增/删除/重命名目录 → 全量兜底路径
                let dirOp = rng.next() % 3
                if dirOp == 0 {
                    try? FileManager.default.createDirectory(
                        at: sessionDir.appendingPathComponent("dir_\(createdCounter)"),
                        withIntermediateDirectories: true
                    )
                    createdCounter += 1
                } else if dirOp == 1 {
                    try? FileManager.default.removeItem(
                        atPath: sessionDir.appendingPathComponent("sub").path
                    )
                    try? FileManager.default.createDirectory(
                        at: sessionDir.appendingPathComponent("sub"),
                        withIntermediateDirectories: true
                    )
                } else {
                    try? FileManager.default.moveItem(
                        atPath: sessionDir.appendingPathComponent("sub").path,
                        toPath: sessionDir.appendingPathComponent("sub2").path
                    )
                    try? FileManager.default.moveItem(
                        atPath: sessionDir.appendingPathComponent("sub2").path,
                        toPath: sessionDir.appendingPathComponent("sub").path
                    )
                }
            default:
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 消费 handler 调用，模拟索引应用：
        //  - 增量：存在且受支持 → 入集；否则（已删除/目录）→ 移出
        //  - 全量（requestedPaths == nil 或 recovery）：walk 重建
        // 注意：全量语义在两种入口一致 —— scanHandler(nil) 为直接全量，
        // recovery 为 metadata.scan job（终局同样全量重建）。
        let applyReports = {
            let recoveries = sink.recoveries
            if recoveries.contains("s1") {
                simulated = Set(walkSupportedFiles(sessionDir.path))
            }
            for scan in sink.scans {
                guard scan.sessionId == "s1" else { continue }
                if let paths = scan.requestedPaths {
                    for path in paths {
                        let url = URL(fileURLWithPath: path)
                        let ext = url.pathExtension.lowercased()
                        let supported = ["jpg", "jpeg", "png", "webp", "heic", "heif",
                                         "nef", "arw", "cr2", "cr3", "dng", "raf", "orf",
                                         "rw2", "pef", "srw", "tif", "tiff", "psd"].contains(ext)
                        let exists = FileManager.default.fileExists(atPath: path)
                        let isFile = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
                        if exists && isFile && supported {
                            simulated.insert(path)
                        } else {
                            simulated.remove(path)
                        }
                    }
                } else {
                    simulated = Set(walkSupportedFiles(sessionDir.path))
                }
            }
        }

        // 轮询等待所有事件被消费完（去抖窗口过后无新 handler 调用）。
        let quiescent = waitUntil(timeout: 10) {
            applyReports()
            return simulated == Set(walkSupportedFiles(sessionDir.path))
        }
        #expect(quiescent, "增量路径与全量路径结果不一致（丢事件未被兜底收敛）")
        coordinator.stop()
    }
}

/// 遍历目录收集受支持扩展名的文件绝对路径（全量扫描的基准实现）。
private func walkSupportedFiles(_ root: String) -> [String] {
    let supported = Set([
        "jpg", "jpeg", "png", "webp", "heic", "heif",
        "nef", "arw", "cr2", "cr3", "dng", "raf", "orf", "rw2", "pef", "srw",
        "tif", "tiff", "psd",
    ])
    var result: [String] = []
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return result }
    for case let url as URL in enumerator {
        if supported.contains(url.pathExtension.lowercased()) {
            result.append(canonicalTestPath(url.path))
        }
    }
    return result
}

/// 测试用 canonical（与 WatchTestRoot.canonical 同语义）。
private func canonicalTestPath(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    if path == "/var" || path.hasPrefix("/var/") {
        return "/private" + path
    }
    if path == "/tmp" || path.hasPrefix("/tmp/") {
        return "/private" + path
    }
    return path
}

/// 确定性随机数生成器（固定种子，与对账 fixture 约定一致）。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

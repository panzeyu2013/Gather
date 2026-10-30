// desktop/native/gather-core/Tests/GatherTestSupport/TempHygiene.swift
// 测试临时目录卫生：进程退出时清掉本次运行创建的临时目录。
//
// 背景（2026-10-30 实测，$TMPDIR = /var/folders/.../T）：
//   · makeTempDir() 注释写“测试结束由调用方删除”，实际残留 80,486 个
//     gather-repo-tests-*（4KB/个）；连同其它 gather-* 共 102,611 个 / 556.7MB；
//   · ImageMetadataProvidersTests / SidecarXMPProviderIPTCTests 直接
//     NSTemporaryDirectory() + UUID 建目录且没有 defer（单文件上万次）；
//   · 用 Ctrl-C 或进程被杀时，即使写了 defer 也不执行（gather-junk-*.mlmodelc
//     残留即此），所以不能只依赖各用例的 defer。
//
// 兜底方式：注册 atexit 钩子——
//   ① 删除显式 track() 的路径；
//   ② 删除 mtime >= 本进程启动时间的 `gather-*` 条目。不用“首次调用时的快照”：
//      安装时机可能晚于并行用例的首次建目录，快照会把它们误判成“既有残留”
//      （实测：首版快照方案漏掉 2 个 gather-replay-*.lock）；启动时刻必须取
//      `proc_pidinfo(PROC_PIDTBSDINFO)`，不能用 `Date() - systemUptime`（那是开机时刻）。
//      `gather-models-*` 归 app 的 ModelInstaller 所有（下载包/解压目录），显式跳过。
//
// 已知边界：atexit 不覆盖 SIGKILL；-9 中断仍可能漏。跨进程并发测试不在设计内
// （scripts/test.sh 与 CI 都是单进程串行/并行一次）。

import Darwin
import Foundation

public enum TempHygiene {
    /// 已登记、退出时删除的路径。
    nonisolated(unsafe) private static var tracked: [String] = []
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()
    /// 本进程启动时刻，与 install()/首次访问的时机解耦。
    /// 注意不能用 `Date() - systemUptime`：那是**开机**时刻（本机 9-29 开机，
    /// 首版实现因此在验证时把 5 天里攒下的 102k 个历史残留一并删了）。
    private static let processStart: Date = {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let copied = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard copied == size else { return Date() }
        let seconds = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }()

    /// atexit 只接受无捕获的 C 回调。
    private static let exitHandler: @convention(c) () -> Void = {
        TempHygiene.sweep()
    }

    /// 安装钩子；重复调用无副作用。
    public static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        atexit(exitHandler)
    }

    /// 登记一个目录/文件，正常退出时删除。
    public static func track(_ url: URL) {
        track(path: url.path)
    }

    public static func track(path: String) {
        install()
        lock.lock()
        tracked.append(path)
        lock.unlock()
    }

    /// atexit 入口：先删显式登记项，再删本次运行新增的 `gather-*` 条目。
    public static func sweep() {
        lock.lock()
        let trackedPaths = tracked
        lock.unlock()

        let fileManager = FileManager.default
        for path in trackedPaths {
            try? fileManager.removeItem(atPath: path)
        }
        let tempDir = fileManager.temporaryDirectory
        let names = (try? fileManager.contentsOfDirectory(atPath: tempDir.path)) ?? []
        for name in names {
            guard name.hasPrefix("gather-"), !name.hasPrefix("gather-models") else { continue }
            let url = tempDir.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified >= processStart else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

// Tests/GatherAppTests/CommandSurfaceRuntimeTests.swift
// 118 条命令的「真实路由运行时派发契约」：语义轮确认的最大覆盖空洞 —— 此前
// 命令面只有静态门禁（注册/重复/未调用）+ 载荷契约测试，没有任何用例构造真实
// SessionCommandRouter 验证「命令名 → switch 分支」的接线。
//
// 黄金列表来源（机械扫描，非手抄）：对 Sources/GatherApp/Host/SessionCommandRouter.swift
// 扫 ^\s*case " 行并限定在两个函数体内 —— execute（603–1560）82 条、
// executeAsync（1561–2439）36 条；扫描结果 118 条、逐条唯一、两集不相交，
// 与本文件清单逐字一致。路由增删命令而不同步更新清单 → 清单用例显红。
//
// 判据：空参数下只要求「命令被识别」。抛/返回业务错误（缺参数、找不到会话、
// 确认门禁等）算通过；只有 NOT_IMPLEMENTED（BridgeError.notImplemented）算失败。
// 对照组（伪造命令名）证明该判据有灵敏度。
import Foundation
import Testing
import GatherCore
@testable import GatherApp

/// 假 XMPProvider：派发测试不触碰文件系统（默认 SidecarXMPProvider 会读写真实侧车）。
private struct NoopXMPProvider: XMPProvider {
    func readKeywords(photoPath: String) async throws -> [String] { [] }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { MetadataWriteAttributes() }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { false }
    func removeFile(_ path: String) async throws {}
}

/// executeAsync 的完成回调可能来自任意线程；这里做一次性落定 + 有界等待。
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: WebResponse?
    private var continuations: [CheckedContinuation<WebResponse?, Never>] = []
    private var finished = false

    func finish(_ response: WebResponse?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.response = response
        let pending = continuations
        continuations = []
        lock.unlock()
        pending.forEach { $0.resume(returning: response) }
    }

    /// 同步快照已落定值（Swift 6：NSLock 在 async 上下文不可直接 lock/unlock，
    /// 故把临界区收进同步 helper；nil = 尚未落定，.some(nil) = 已落定为 nil）。
    private func finishedValue() -> WebResponse?? {
        lock.lock()
        defer { lock.unlock() }
        guard finished else { return nil }
        return .some(response)
    }

    func wait() async -> WebResponse? {
        if let value = finishedValue() { return value }
        // 必须先解锁再挂 continuation：NSLock 非递归，在闭包里二次加锁会自锁。
        // 闭包内是同步临界区（不在 async 上下文），可继续直接 lock/unlock。
        return await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let value = response
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}

@Suite("CommandSurfaceRuntime 118 命令真实路由派发", .serialized)
struct CommandSurfaceRuntimeTests {
    /// execute 同步 switch 的黄金清单（82 条）。
    static let syncCommands: [String] = [
        "session.list",
        "session.get",
        "session.create",
        "session.delete",
        "session.delete_many",
        "session.update",
        "session.add_photos",
        "photo.list",
        "photo.list_page",
        "workspace.status",
        "jobs.list",
        "jobs.cancel",
        "jobs.retry",
        "jobs.clear_completed",
        "settings.get_all",
        "settings.get",
        "settings.set",
        "settings.reset",
        "settings.set_language",
        "settings.get_ml_status",
        "filter.photos",
        "filter.photos_global",
        "filter.suggest",
        "navigation.list",
        "navigation.split",
        "navigation.merge",
        "sim.result",
        "sim.cancel_analysis",
        "assets.candidates",
        "dup.resolve",
        "dup.resolve_member",
        "fkw.clusters",
        "fkw.bind",
        "fkw.merge",
        "fkw.remove_member",
        "fkw.cancel_analysis",
        "person.list",
        "person.get",
        "person.create",
        "person.update",
        "person.delete",
        "person.merge",
        "person.remove_photo",
        "person.search_photos",
        "template.create",
        "template.list",
        "template.get",
        "template.update",
        "template.delete",
        "template.apply",
        "quality.get",
        "metadata.orphans",
        "sim.writeback_items",
        "assets.accept_candidate",
        "assets.reject_candidate",
        "assets.volumes",
        "assets.relink_root",
        "album.create",
        "album.list",
        "album.get",
        "album.update",
        "album.delete",
        "album.get_photos",
        "image.prioritize_thumbnail",
        "image.preload_thumbnails",
        "image.preload_previews",
        "image.get_dimensions",
        "export.cancel",
        "export.report",
        "face.models_status",
        "culling.list_page",
        "culling.history",
        "culling.apply_history",
        "culling.update",
        "culling.batch_update",
        "culling.decide_group",
        "culling.sync_status",
        "culling.groups",
        "culling.decide",
        "culling.batch_decide",
        "culling.summary",
        "culling.reset",
    ]

    /// executeAsync 特化 switch 的黄金清单（36 条）。
    static let asyncCommands: [String] = [
        "navigation.analyze",
        "sim.recluster",
        "sim.analyze",
        "dup.scan",
        "fkw.analyze",
        "fkw.recluster",
        "fkw.unbind",
        "fkw.preview",
        "fkw.writeback",
        "fkw.confirm_sync",
        "fkw.confirm_cleanup",
        "fkw.cleanup",
        "dup.groups",
        "culling.retry_failed_writeback",
        "culling.cleanup",
        "sim.retry_failed_writeback",
        "sim.cleanup",
        "index.scan",
        "quality.analyze",
        "session.create_from_directory",
        "metadata.resolve_conflict",
        "metadata.resolve_orphan",
        "culling.writeback",
        "culling.flush",
        "culling.retry_sync",
        "export.preview",
        "export.execute",
        "metadata.get",
        "metadata.set",
        "metadata.batch_set",
        "metadata.conflicts",
        "sim.preview_writeback",
        "sim.writeback",
        "sim.confirm_sync",
        "culling.finalize_sync",
        "culling.confirm_sync",
    ]

    /// 真实路由（内存库 + 迁移）；假 XMP + 1 小时写去抖，避免文件 IO 与后台落盘。
    private static func makeRouter() throws -> SessionCommandRouter {
        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        return SessionCommandRouter.makeDefault(
            db: db,
            xmpProvider: NoopXMPProvider(),
            metadataWriteDebounceMs: 3_600_000
        )
    }

    @Test("黄金清单：82 + 36 = 118，条条唯一且两集不相交")
    func goldenListsAreConsistent() {
        let sync = Self.syncCommands
        let asyncCommands = Self.asyncCommands
        #expect(sync.count == 82)
        #expect(asyncCommands.count == 36)
        #expect(Set(sync).count == sync.count, "同步清单存在重复命令")
        #expect(Set(asyncCommands).count == asyncCommands.count, "异步清单存在重复命令")
        #expect(Set(sync).isDisjoint(with: Set(asyncCommands)), "同一命令不得同时出现在两个 switch")
        #expect(Set(sync).union(asyncCommands).count == 118)
    }

    @Test("对照组：伪造命令在两个入口都必须 NOT_IMPLEMENTED（证明判据灵敏度）")
    func unknownCommandIsNotImplemented() async throws {
        let router = try Self.makeRouter()
        let bogus = "__nope__.nope"

        var syncNotImplemented = false
        do {
            _ = try router.execute(bogus, params: [:])
        } catch let error as BridgeError {
            if case .notImplemented(let name) = error { syncNotImplemented = (name == bogus) }
        }
        #expect(syncNotImplemented, "execute 对伪造命令应抛 BridgeError.notImplemented")

        let box = ResponseBox()
        router.executeAsync(bogus, params: [:]) { box.finish($0) }
        let response = await box.wait()
        #expect(
            response?.error == "NOT_IMPLEMENTED: \(bogus)",
            "executeAsync 对伪造命令应回落 execute 并报 NOT_IMPLEMENTED，实际：\(response?.error ?? "nil")"
        )
    }

    @Test("82 条同步命令：空参数逐条派发，全部被识别（非 NOT_IMPLEMENTED）")
    func syncCommandsAreDispatched() throws {
        let router = try Self.makeRouter()
        var unrecognized: [String] = []
        for command in Self.syncCommands {
            do {
                _ = try router.execute(command, params: [:])
            } catch let error as BridgeError {
                if case .notImplemented = error {
                    unrecognized.append("\(command) → \(error.description)")
                }
                // 其它 BridgeError（缺参数/确认门禁/未找到等）= 已被分派：通过。
            } catch {
                // 任意业务错误同样证明命令名被路由识别：通过。
            }
        }
        #expect(
            unrecognized.isEmpty,
            Comment(rawValue: "以下同步命令未被路由识别（漏注册/命令名写错）：\n" + unrecognized.joined(separator: "\n"))
        )
    }

    @Test("36 条异步命令：空参数逐条派发，全部被识别且 5s 内落定（挂起即失败）")
    func asyncCommandsAreDispatched() async throws {
        let router = try Self.makeRouter()
        var failures: [String] = []
        for command in Self.asyncCommands {
            let box = ResponseBox()
            router.executeAsync(command, params: [:]) { box.finish($0) }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(5))
                box.finish(nil)
            }
            let response = await box.wait()
            timeout.cancel()
            guard let response else {
                failures.append("\(command) → 5s 超时：空参数下未落定（疑似阻塞/挂起）")
                continue
            }
            if response.error == "NOT_IMPLEMENTED: \(command)" {
                failures.append("\(command) → 未被识别（\(response.error ?? "")）")
            }
        }
        #expect(
            failures.isEmpty,
            Comment(rawValue: "以下异步命令未被识别或在空参数下阻塞：\n" + failures.joined(separator: "\n"))
        )
    }
}

// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataWritebackStateMachineTests.swift
// 写回内核单一状态机的语义测试（R4）：
// 1) writing 是租约态且永远有出口（迁移表 + 启动恢复 + 到期恢复/达上限转 failed）
// 2) 路径口径唯一（photo/sidecar 混用归一到同一行）
// 3) 字段级合并 + 字段归属（跨模块 discard 不误删他人字段）
// 4) 逐文件隔离（一个文件失败不影响其它文件落盘，失败行有类型化原因且可重试）
// 5) confirm 返回真实计数（未完成抛错，绝不乐观上报）

import Foundation
import Testing
@testable import GatherCore

// MARK: - 真实文件系统 XMP 假件（可注入逐文件写失败）

private struct FakeXMPError: Error, MetadataCodedError {
    let code: String
    let xmpPath: String
}

private final class FakeXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var failingPhotos: Set<String> = []
    private var backupCounter = 0

    func setFailing(_ photoPath: String) {
        lock.lock()
        failingPhotos.insert(photoPath)
        lock.unlock()
    }

    func setSucceeding(_ photoPath: String) {
        lock.lock()
        failingPhotos.remove(photoPath)
        lock.unlock()
    }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func isFailing(_ photoPath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failingPhotos.contains(photoPath)
    }

    private func nextBackupCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        backupCounter += 1
        return backupCounter
    }

    private func sidecar(_ photoPath: String) -> String { TSPath.xmpSidecarPath(photoPath) }

    private func read(_ photoPath: String) -> MetadataWriteAttributes {
        guard let data = FileManager.default.contents(atPath: sidecar(photoPath)) else {
            return MetadataWriteAttributes()
        }
        return (try? JSONDecoder().decode(MetadataWriteAttributes.self, from: data)) ?? MetadataWriteAttributes()
    }

    func readKeywords(photoPath: String) async throws -> [String] { read(photoPath).keywords ?? [] }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes { read(photoPath) }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {
        if isFailing(photoPath) {
            throw FakeXMPError(code: "XMP_WRITE_FAILED", xmpPath: sidecar(photoPath))
        }
        let data = try JSONEncoder().encode(attributes)
        try data.write(to: URL(fileURLWithPath: sidecar(photoPath)), options: .atomic)
    }

    func backup(photoPath: String) async throws -> String {
        let counter = nextBackupCounter()
        let source = sidecar(photoPath)
        // 与真实 SidecarXMPProvider.backup 一致：无侧车可备份时返回 ""（不是"指向不存在文件的路径"），
        // 否则 cleanup 会把"从未存在的备份"误判为 XMP_BACKUP_MISSING。
        guard FileManager.default.fileExists(atPath: source) else { return "" }
        let path = source + ".backup-" + String(counter)
        if let data = FileManager.default.contents(atPath: source) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    func restore(photoPath: String, backupPath: String) async throws {
        let target = sidecar(photoPath)
        if let data = FileManager.default.contents(atPath: backupPath) {
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: target)
        }
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func removeFile(_ path: String) async throws { try FileManager.default.removeItem(atPath: path) }
}

// MARK: - 夹具

private struct WritebackFixture {
    let db: DBConnection
    let dir: String
    let sessionId: String
    let outbox: MetadataOutboxRepo
    let provider: FakeXMP
    let coordinator: MetadataSyncCoordinator

    init(skipReloadAck: Bool = true) throws {
        db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-wb-" + UUID().uuidString, isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        sessionId = "s-" + UUID().uuidString
        try insertSession(db, sessionId)
        outbox = MetadataOutboxRepo(connection: db)
        provider = FakeXMP()
        coordinator = MetadataSyncCoordinator(
            outboxRepo: outbox,
            writebackRepo: WritebackRepo(connection: db),
            xmp: provider,
            connection: db,
            getNumber: { _, _ in 0 },
            skipReloadAck: skipReloadAck
        )
    }

    func photoPath(_ name: String) -> String { dir + "/" + name }

    func sidecar(_ name: String) -> String { TSPath.xmpSidecarPath(photoPath(name)) }

    @discardableResult
    func enqueue(_ name: String, values: [String: JSONValue], source: String, dirty: [String]) throws -> MetadataOutboxRow {
        var patch = values
        patch["source"] = .string(source)
        return try outbox.mergePatch(
            xmpPath: sidecar(name),
            sessionId: sessionId,
            photoPath: photoPath(name),
            patch: .object(patch),
            dirtyFields: dirty
        )
    }

    /// 造一行 writing（claim 后按需改写租约时间/尝试次数，模拟崩溃残留）。
    @discardableResult
    func makeWritingRow(_ name: String, rating: Double, attempts: Int, updatedAt: String?) throws -> MetadataOutboxRow {
        let row = try enqueue(name, values: ["rating": .number(rating)], source: "culling", dirty: ["rating"])
        _ = try outbox.claim(xmpPath: row.xmpPath, expectedRevision: row.revision)
        if let updatedAt {
            try db.prepare("UPDATE metadata_outbox SET updated_at = ?, attempt_count = ? WHERE xmp_path = ?")
                .run([.text(updatedAt), .int(Int64(attempts)), .text(row.xmpPath)])
        } else if attempts != 1 {
            try db.prepare("UPDATE metadata_outbox SET attempt_count = ? WHERE xmp_path = ?")
                .run([.int(Int64(attempts)), .text(row.xmpPath)])
        }
        guard let updated = try outbox.get(row.xmpPath) else {
            throw MetadataOutboxError.rowNotFound(xmpPath: row.xmpPath)
        }
        return updated
    }
}

// MARK: - 测试

@Suite("MetadataWritebackStateMachine")
struct MetadataWritebackStateMachineTests {
    @Test("状态机：writing 永远有出口，任何状态都有合法后继")
    func writingAlwaysHasExit() {
        #expect(MetadataOutboxStatus.writing.canTransition(to: .pending))
        #expect(MetadataOutboxStatus.writing.canTransition(to: .written))
        #expect(MetadataOutboxStatus.writing.canTransition(to: .failed))
        #expect(MetadataOutboxStatus.writing.canTransition(to: .conflict))
        // 非法迁移必须在表上被拒（避免任何"跳状态"的隐式路径）。
        #expect(!MetadataOutboxStatus.written.canTransition(to: .writing))
        #expect(!MetadataOutboxStatus.synced.canTransition(to: .writing))
        #expect(!MetadataOutboxStatus.conflict.canTransition(to: .written))
        for status in MetadataOutboxStatus.allCases {
            let hasSuccessor = MetadataOutboxStatus.allCases.contains { status.canTransition(to: $0) }
            #expect(hasSuccessor, "状态 \(status.rawValue) 没有合法后继（死状态）")
        }
    }

    @Test("崩溃恢复：进程启动把 writing 归位 pending 并真实落盘")
    func startupRecoveryRewritesPending() async throws {
        let f = try WritebackFixture()
        let row = try f.makeWritingRow("a.cr3", rating: 4, attempts: 1, updatedAt: nil)
        #expect(try f.outbox.get(row.xmpPath)?.status == "writing")

        // 组合根调用 start(eventSink:) —— 唯一恢复入口（首次使用也会执行）。
        f.coordinator.start(eventSink: nil)
        #expect(try f.outbox.get(row.xmpPath)?.status != "writing")

        let summary = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(summary.written + summary.synced == 1)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("a.cr3")).rating == 4)
        await f.coordinator.shutdown()
    }

    @Test("租约恢复：过期归位、未过期与在飞不动、达上限转 failed+XMP_WRITING_LEASE_EXPIRED")
    func expiredLeaseRecovery() throws {
        let f = try WritebackFixture()
        let expired = try f.makeWritingRow("a.cr3", rating: 1, attempts: 1, updatedAt: "2000-01-01T00:00:00Z")
        let fresh = try f.makeWritingRow("b.cr3", rating: 2, attempts: 1, updatedAt: nil)

        // 在飞（activePaths 命中）即使租约到期也不动。
        let activeRecovery = try f.outbox.recoverExpiredLeases(
            activePaths: [expired.xmpPath, fresh.xmpPath], leaseMs: 0, maxAttempts: 5)
        #expect(activeRecovery.isEmpty)

        let recovered = try f.outbox.recoverExpiredLeases(activePaths: [], leaseMs: 1_000, maxAttempts: 5)
        #expect(recovered.count == 1)
        #expect(recovered.first?.xmpPath == expired.xmpPath)
        #expect(recovered.first?.newStatus == .pending)
        #expect(try f.outbox.get(expired.xmpPath)?.status == "pending")
        // 未过期（刚 claim，updated_at = now）不动。
        #expect(try f.outbox.get(fresh.xmpPath)?.status == "writing")

        let exhausted = try f.makeWritingRow("c.cr3", rating: 3, attempts: 5, updatedAt: "2000-01-01T00:00:00Z")
        let second = try f.outbox.recoverExpiredLeases(activePaths: [], leaseMs: 1_000, maxAttempts: 5)
        #expect(second.count == 1)
        #expect(second.first?.xmpPath == exhausted.xmpPath)
        #expect(second.first?.newStatus == .failed)
        let failedRow = try f.outbox.get(exhausted.xmpPath)
        #expect(failedRow?.status == "failed")
        #expect(failedRow?.errorMessage == "XMP_WRITING_LEASE_EXPIRED")
    }
    @Test("路径口径唯一：photo/sidecar 混用归一到同一行且幂等")
    func pathNormalizationIsSingleValued() throws {
        let f = try WritebackFixture()
        let photo = f.photoPath("a.cr3")
        // 独立 oracle：目录 canonical 拼写 + stem + ".xmp"（字符串拼接，不复述被测表达式组合）。
        let expected = ScanPath.canonical(f.dir) + "/a.xmp"
        #expect(MetadataOutboxPath.sidecar(photo) == expected)
        #expect(MetadataOutboxPath.normalize(expected) == expected)

        let first = try f.outbox.mergePatch(
            xmpPath: photo, sessionId: f.sessionId, photoPath: photo,
            patch: .object(["rating": .number(3), "source": .string("culling")]), dirtyFields: ["rating"])
        let second = try f.outbox.mergePatch(
            xmpPath: expected, sessionId: f.sessionId, photoPath: photo,
            patch: .object(["label": .string("Red"), "source": .string("culling")]), dirtyFields: ["label"])
        #expect(first.xmpPath == expected)
        #expect(second.xmpPath == expected)
        #expect(second.revision == 2, "两次入队落在同一行")
        #expect(try f.outbox.getBySession(f.sessionId).count == 1)
        #expect(second.photoPath == ScanPath.canonical(photo))
    }

    @Test("字段级合并与归属：后者覆盖同名、未提及字段保留、discard 只删本模块字段")
    func fieldLevelMergeAndOwnership() throws {
        let f = try WritebackFixture()
        try f.enqueue("a.cr3", values: ["rating": .number(2)], source: "culling", dirty: ["rating"])
        _ = try f.enqueue("a.cr3", values: ["keywords": .array([.string("k1")])], source: "face-keyword", dirty: ["keywords"])
        var row = try f.enqueue("a.cr3", values: ["label": .string("Green")], source: "similarity", dirty: ["label"])
        #expect(row.fieldsPatch.keys.sorted() == ["keywords", "label", "rating"])
        #expect(row.fieldOwners["rating"] == "culling")
        #expect(row.fieldOwners["keywords"] == "face-keyword")
        #expect(row.fieldOwners["label"] == "similarity")

        // 后写覆盖同名 rating=3，其余字段原样保留（不丢 label/keywords）
        row = try f.enqueue("a.cr3", values: ["rating": .number(3)], source: "culling", dirty: ["rating"])
        #expect(row.fieldsPatch["rating"]?.numberValue == 3)
        #expect(row.fieldsPatch["label"]?.stringValue == "Green")
        #expect(row.fieldsPatch["keywords"]?.arrayElements?.count == 1)

        // culling 丢弃只删 rating：行保留，其它模块字段与归属不受影响
        let discarded = try f.outbox.discardModulePending(sessionId: f.sessionId, sourceModule: "culling")
        #expect(discarded.deleted == 0)
        #expect(discarded.trimmed == 1)
        let trimmed = try f.outbox.get(f.sidecar("a.cr3"))
        #expect(trimmed?.fieldsPatch.keys.sorted() == ["keywords", "label"])
        #expect(trimmed?.fieldOwners["rating"] == nil)
        #expect(trimmed?.dirty == ["keywords", "label"])
        #expect(trimmed?.status == "pending")
    }

    @Test("逐文件隔离：一个文件失败不影响其它文件落盘；失败行有类型化原因且可重试")
    func perFileIsolation() async throws {
        let f = try WritebackFixture()
        try f.enqueue("ok1.cr3", values: ["rating": .number(1)], source: "culling", dirty: ["rating"])
        try f.enqueue("bad.cr3", values: ["rating": .number(2)], source: "culling", dirty: ["rating"])
        try f.enqueue("ok2.cr3", values: ["rating": .number(3)], source: "culling", dirty: ["rating"])
        f.provider.setFailing(f.photoPath("bad.cr3"))

        let summary = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(summary.written + summary.synced == 2, "成功文件必须已落盘并计为 written")
        #expect(summary.failed == 1)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("ok1.cr3")).rating == 1)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("ok2.cr3")).rating == 3)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("bad.cr3")).rating == nil)

        let failedRow = try f.outbox.get(f.sidecar("bad.cr3"))
        #expect(failedRow?.status == "failed")
        #expect(failedRow?.errorMessage.contains("XMP_WRITE_FAILED") == true, "错误必须是稳定错误码")
        #expect(failedRow?.errorMessage.contains(f.sidecar("bad.cr3")) == true, "错误必须带出错的侧车路径")

        // 修复后重试：真实落盘、失败计数归零
        f.provider.setSucceeding(f.photoPath("bad.cr3"))
        let retried = try await f.coordinator.retrySession(sessionId: f.sessionId)
        #expect(retried.failed == 0)
        #expect(retried.written + retried.synced == 3)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("bad.cr3")).rating == 2)
        await f.coordinator.shutdown()
    }

    @Test("confirm 返回真实计数：未完成抛 XMP_CONFIRM_INCOMPLETE，完成后 synced 计数为真")
    func confirmReportsRealCounts() async throws {
        let f = try WritebackFixture()
        try f.enqueue("a.cr3", values: ["rating": .number(4)], source: "culling", dirty: ["rating"])
        try f.enqueue("b.cr3", values: ["label": .string("Red")], source: "culling", dirty: ["label"])

        do {
            _ = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")
            Issue.record("expected confirmIncomplete")
        } catch let error as MetadataSyncError {
            #expect(error == .confirmIncomplete)
        }

        let flushed = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(flushed.written == 2)
        #expect(flushed.failed == 0)

        let confirmed = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")
        #expect(confirmed.synced == 2, "确认后返回真实 synced 计数")
        #expect(confirmed.written == 0)
        #expect(confirmed.pending == 0)

        // 失败行存在时不得乐观通过：新增一行失败后 confirm 必须抛错
        try f.enqueue("c.cr3", values: ["rating": .number(1)], source: "culling", dirty: ["rating"])
        f.provider.setFailing(f.photoPath("c.cr3"))
        _ = try await f.coordinator.flushSession(sessionId: f.sessionId)
        do {
            _ = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")
            Issue.record("expected confirmIncomplete with failed row")
        } catch let error as MetadataSyncError {
            #expect(error == .confirmIncomplete)
        }
        await f.coordinator.shutdown()
    }

    @Test("reload-ack 门控：未确认时 confirm 抛 XMP_RELOAD_NOT_ACKED（不做乐观确认）")
    func confirmRequiresReloadAck() async throws {
        let f = try WritebackFixture(skipReloadAck: false)
        try f.enqueue("a.cr3", values: ["rating": .number(2)], source: "culling", dirty: ["rating"])
        _ = try await f.coordinator.flushSession(sessionId: f.sessionId)
        do {
            _ = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")
            Issue.record("expected reloadNotAcked")
        } catch let error as MetadataSyncError {
            #expect(error == .reloadNotAcked)
        }
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "written", "门控失败不得推进状态")
        await f.coordinator.shutdown()
    }

    @Test("cleanup 逐文件隔离：一个文件备份缺失不阻塞其它文件恢复与删除（真实计数+原因）")
    func cleanupIsolatesPerFileFailures() async throws {
        let f = try WritebackFixture()
        // 预置旧侧车，使备份真实生成（备份缺失场景才可构造）。
        for name in ["a.cr3", "b.cr3"] {
            let old = MetadataWriteAttributes(keywords: nil, rating: 0, label: nil)
            try JSONEncoder().encode(old).write(to: URL(fileURLWithPath: f.sidecar(name)), options: .atomic)
        }
        try f.enqueue("a.cr3", values: ["rating": .number(4)], source: "culling", dirty: ["rating"])
        try f.enqueue("b.cr3", values: ["rating": .number(5)], source: "culling", dirty: ["rating"])
        _ = try await f.coordinator.flushSession(sessionId: f.sessionId)
        _ = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")

        // a 的备份被人为删除：a 必须逐行失败（不静默），b 必须照常恢复并删除。
        let backupA = try f.outbox.get(f.sidecar("a.cr3"))?.backupPath ?? ""
        #expect(!backupA.isEmpty)
        try FileManager.default.removeItem(atPath: backupA)

        let result = try await f.coordinator.cleanup(sessionId: f.sessionId, sourceModule: "culling")
        #expect(result.deletedCount == 1, "只有 b 被清理")
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.contains("XMP_BACKUP_MISSING") == true)
        #expect(try f.outbox.get(f.sidecar("b.cr3")) == nil, "b 的行已删除")
        #expect(try f.outbox.get(f.sidecar("a.cr3")) != nil, "a 的行保留（不谎报已清理）")
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("b.cr3")).rating == 0, "b 已恢复备份")
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("a.cr3")).rating == 4, "a 保持写后状态")
        await f.coordinator.shutdown()
    }

    @Test("waitForIdle：陈旧 writing 行先恢复，不产生假超时（XMP_WRITER_TIMEOUT）")
    func waitForIdleRecoversStaleWriting() async throws {
        let f = try WritebackFixture()
        let stale = try f.makeWritingRow("a.cr3", rating: 4, attempts: 1, updatedAt: "2000-01-01T00:00:00Z")
        // 无恢复时这里会等到 200ms 后抛 writerTimeout。
        try await f.coordinator.waitForIdle(xmpPath: stale.xmpPath, timeoutMs: 200)
        #expect(try f.outbox.get(stale.xmpPath)?.status != "writing")
        await f.coordinator.shutdown()
    }

    @Test("冲突两条出口：use_remote 结清删行；keep_local/空 choices 重基线重写（getConflicts 必有可裁决字段）")
    func conflictResolutionBothExits() async throws {
        let f = try WritebackFixture()
        for (name, rating) in [("a.cr3", 4.0), ("b.cr3", 2.0), ("c.cr3", 6.0)] {
            try f.enqueue(name, values: ["rating": .number(rating)], source: "culling", dirty: ["rating"])
        }
        _ = try await f.coordinator.flushSession(sessionId: f.sessionId)
        for name in ["a.cr3", "b.cr3", "c.cr3"] {
            _ = try f.outbox.markConflict(
                xmpPath: f.sidecar(name), remote: .object(["rating": .number(9)]),
                reason: "XMP_EXTERNAL_EDIT_CONFLICT")
        }
        let conflicts = try await f.coordinator.getConflicts(sessionId: f.sessionId)
        #expect(conflicts.count == 3)
        #expect(conflicts.allSatisfy { !$0.fields.isEmpty }, "冲突行必须给出可裁决字段（否则 UI 无出口）")

        // 出口 1：全部接受远程 → 结清删行（磁盘上的远程值保留）。
        _ = try await f.coordinator.resolveConflict(
            sessionId: f.sessionId, xmpPath: f.sidecar("a.cr3"), choices: [.rating: .useRemote])
        #expect(try f.outbox.get(f.sidecar("a.cr3")) == nil, "全 use_remote → 结清删行")

        // 出口 2：keep_local → 以当前磁盘状态重基线并重写本地值。
        _ = try await f.coordinator.resolveConflict(
            sessionId: f.sessionId, xmpPath: f.sidecar("b.cr3"), choices: [.rating: .keepLocal])
        let flushed = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(flushed.written + flushed.synced >= 1)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("b.cr3")).rating == 2,
                "保留本地 → 重写本地值")

        // 出口 3：空 choices = 显式结清（保留本地），同样必须能离开 conflict。
        _ = try await f.coordinator.resolveConflict(
            sessionId: f.sessionId, xmpPath: f.sidecar("c.cr3"), choices: [:])
        #expect(try f.outbox.get(f.sidecar("c.cr3"))?.status != "conflict")
        _ = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(try await f.provider.readAttributes(photoPath: f.photoPath("c.cr3")).rating == 6)
        await f.coordinator.shutdown()
    }

    @Test("双会话共享侧车：未确认会话阻塞成功（指名会话），双方确认后 cleanup 不死锁")
    func doubleSessionConfirmRequiresAllSessions() async throws {
        let f = try WritebackFixture()
        let second = "s2-" + UUID().uuidString
        try insertSession(f.db, second)
        try f.enqueue("a.cr3", values: ["rating": .number(4)], source: "culling", dirty: ["rating"])
        // s2 链接同一侧车（非归属会话：它不拥有 rating）。
        _ = try f.outbox.mergePatch(
            xmpPath: f.sidecar("a.cr3"), sessionId: second, photoPath: f.photoPath("a.cr3"),
            patch: .object(["source": .string("similarity")]), dirtyFields: [])
        let summary = try await f.coordinator.flushSession(sessionId: f.sessionId)
        #expect(summary.written == 1)

        // s1 确认：本会话确认落地（进度可累积），但行仍 written → 必须抛错并指名 s2。
        do {
            _ = try f.coordinator.confirmSync(sessionId: f.sessionId, sourceModule: "culling")
            Issue.record("expected otherSessionNotConfirmed")
        } catch let error as MetadataSyncError {
            #expect(error == .otherSessionNotConfirmed(sessionId: second))
        }
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "written", "不得谎报确认成功")

        // s2 确认（非归属会话也能确认自己的视图）→ 全部关联会话确认 → 行转 synced。
        _ = try f.coordinator.confirmSync(sessionId: second, sourceModule: "similarity")
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "synced")

        // cleanup 不再死锁：真实清理 1 行。
        let cleaned = try await f.coordinator.cleanup(sessionId: f.sessionId, sourceModule: "culling")
        #expect(cleaned.deletedCount == 1)
        #expect(cleaned.errors.isEmpty)
        await f.coordinator.shutdown()
    }

    @Test("written 行不被 discard（丢弃只作用于 pending/failed 的本模块字段）")
    func writtenRowsSurviveDiscard() throws {
        let f = try WritebackFixture()
        try f.enqueue("a.cr3", values: ["rating": .number(4)], source: "culling", dirty: ["rating"])
        #expect(try f.outbox.claim(xmpPath: f.sidecar("a.cr3"), expectedRevision: 1))
        #expect(try f.outbox.markWritten(
            xmpPath: f.sidecar("a.cr3"), revision: 1, fingerprint: "fp",
            baseValues: .object([:]), backupPath: ""))
        let discarded = try f.outbox.discardModulePending(sessionId: f.sessionId, sourceModule: "culling")
        #expect(discarded.deleted == 0)
        #expect(discarded.trimmed == 0)
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "written", "written 行（已落盘待确认）不得被丢弃")
    }

    @Test("遗留 clean/cleaned 行归一为 synced：不再既不计 pending、又不进恢复、cleanup 必抛")
    func legacyTerminalStatusesNormalized() throws {
        let f = try WritebackFixture()
        try f.enqueue("a.cr3", values: ["rating": .number(4)], source: "culling", dirty: ["rating"])
        try f.db.prepare("UPDATE metadata_outbox SET status = 'clean' WHERE xmp_path = ?")
            .run([.text(f.sidecar("a.cr3"))])
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "clean", "CHECK 允许的遗留状态确实存在")
        _ = try f.outbox.recoverInterrupted()
        #expect(try f.outbox.get(f.sidecar("a.cr3"))?.status == "synced")
        let summary = try f.coordinator.getSummary(sessionId: f.sessionId)
        #expect(summary.synced == 1)
        #expect(summary.pending == 0)
    }
}

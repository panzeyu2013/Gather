// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/MetadataOutboxRepoTests.swift
// metadata_outbox 仓库测试（R4 重写：对齐显式状态机 / 租约恢复 / 字段级归属）。
//
// 覆盖：
// - 语义化写入 API（markWritten / markConflict / markFailed / resetForRetry / transition）
// - 迁移表：非法迁移抛 XMP_OUTBOX_ILLEGAL_TRANSITION
// - 恢复：recoverInterrupted（全量 writing→pending）、recoverExpiredLeases（到期→pending /
//   达上限→failed + XMP_WRITING_LEASE_EXPIRED；在飞行不回收）
// - 字段级合并与 __owners__ 归属：后者覆盖同名、未提及字段保留、discard 只删本模块字段
// - markWritten 的真实性：抢到 writing 才返回 true、才可记录 baseline；否则 false 不谎报

import Foundation
import Testing
@testable import GatherCore

struct MetadataOutboxRepoTests {
    private func makeRepo() throws -> (DBConnection, MetadataOutboxRepo) {
        let db = try makeMigratedDB()
        try insertSession(db, "s1")
        try insertSession(db, "s2")
        return (db, MetadataOutboxRepo(connection: db))
    }

    private func claimAndWrite(_ repo: MetadataOutboxRepo, xmpPath: String, revision: Int64) throws {
        #expect(try repo.claim(xmpPath: xmpPath, expectedRevision: revision))
        #expect(try repo.markWritten(
            xmpPath: xmpPath, revision: revision, fingerprint: "fp-\(revision)",
            baseValues: .object([:]), backupPath: "/b/\(revision)"))
        try repo.resetForRetry(xmpPath) // written → 不影响后续断言；仅用于测试清理
    }

    @Test func getUnknownAndMergePatchCreate() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.get("/v/IMG_1.xmp") == nil)

        let patch = JSONValue.object([
            "source": JSONValue.string("face-keyword"),
            "keywords": JSONValue.array([JSONValue.string("a")]),
        ])
        let row = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: patch, dirtyFields: ["keywords"])
        #expect(row.status == "pending")
        #expect(row.revision == 1)
        #expect(row.persistedRevision == 0)
        #expect(row.sourceModule == "face-keyword")
        #expect(row.ownerSessionId == "s1")
        #expect(row.photoPath == "/v/IMG_1.jpg")
        #expect(row.dirty == ["keywords"])
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(try repo.getSessionIds("/v/IMG_1.xmp") == ["s1"])
    }

    @Test func mergePatchMergesWhenNotNewRevision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp",
            sessionId: "s1",
            photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("face-keyword"), "keywords": JSONValue.array([JSONValue.string("a")])]),
            dirtyFields: ["keywords"]
        )
        // 状态仍为 pending → 同 revision 内合并 patch/dirty（字段级：未提及字段保留）
        let row = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp",
            sessionId: "s1",
            photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["rating": JSONValue.int(4)]),
            dirtyFields: ["rating"]
        )
        #expect(row.revision == 2)
        #expect(row.dirty == ["keywords", "rating"], "dirty_fields 去重合并")
        #expect(row.patch["keywords"]?.arrayValue == ["a"])
        #expect(row.patch["rating"] == .number(4))
        // 字段归属：keywords 仍归 face-keyword，rating 归 source_module（本次 patch 无 source）。
        #expect(row.fieldOwners["keywords"] == "face-keyword")
    }

    @Test func mergePatchKeepsWritingStatusAndLetsInFlightWriteRecordBaseline() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(1)]),
            dirtyFields: ["rating"])
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        // 在飞写入期间新变更到达：行必须保持 writing（否则在飞写入无法记录基线 → 假冲突）
        let bumped = try repo.mergePatch(
            xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "label": JSONValue.string("Red")]),
            dirtyFields: ["label"])
        #expect(bumped.status == "writing")
        #expect(bumped.revision == 2)
        // 旧 revision 落盘：**被新 revision 取代也返回 true**（本次写入已记账 = persisted/基线落库），
        // 行回到 pending 等待新 revision —— 返回值表示"已记账"，不表示"已终态"。
        #expect(try repo.markWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp1",
            baseValues: .object(["rating": .number(1)]), backupPath: "/b/1"))
        let afterWrite = try repo.get("/v/IMG_1.xmp")
        #expect(afterWrite?.status == "pending")
        #expect(afterWrite?.persistedRevision == 1)
        #expect(afterWrite?.baseFingerprint == "fp1")
        #expect(afterWrite?.dirty == ["rating", "label"])
    }

    @Test func mergePatchStartsNewRevisionAfterWritten() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual"), "rating": JSONValue.int(1)]), dirtyFields: ["rating"])
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp", baseValues: .object([:]), backupPath: "/backup/xmp"))

        // written 状态 → startsNewRevision → patch 不再合并（旧合成事务已结束）
        let row = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["rating": JSONValue.int(5)]), dirtyFields: ["rating"])
        #expect(row.revision == 2)
        #expect(row.status == "pending")
        #expect(row.patch["rating"] == .number(5))
        #expect(row.dirty == ["rating"])
    }

    @Test func sessionScopedQueries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p1 = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p1, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s2", photoPath: "/v/IMG_2.jpg", patch: p1, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg", patch: p1, dirtyFields: [])

        #expect(try repo.getBySession("s1").map(\.xmpPath).sorted() == ["/v/IMG_1.xmp", "/v/IMG_3.xmp"])
        #expect(try repo.getSummaryRowsBySession("s1").count == 2)
        #expect(try repo.countBySession("s1")["pending"] == 2)
        #expect(try repo.getSessionIds("/v/IMG_1.xmp") == ["s1"])
    }

    @Test func hasActiveOtherModuleGate() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("face-keyword")]), dirtyFields: [])
        #expect(try repo.hasActiveOtherModule(sessionId: "s1", module: "similarity") == false, "pending 不算其它模块已完成")

        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp", baseValues: .object([:]), backupPath: ""))
        #expect(try repo.hasActiveOtherModule(sessionId: "s1", module: "similarity"), "written 的 face-keyword 挡住 similarity")
        #expect(try repo.hasActiveOtherModule(sessionId: "s1", module: "face-keyword") == false, "自己不算其它模块")
    }

    /// 互斥门必须对每个批量写回模块生效（face-keyword / similarity / template），
    /// 且 culling（交互式连续同步）不在门内 —— 只挡 face-keyword 会让 similarity
    /// 的未确认写回被下一个模块静默覆盖。
    @Test func hasActiveOtherModuleGateCoversEveryBulkModule() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // 每个模块独占一个会话：这样"自己不算其它模块"与"挡住别人"互不干扰。
        let cases: [(session: String, path: String, module: String)] = [
            ("s1", "/v/G1.xmp", "face-keyword"),
            ("s2", "/v/G2.xmp", "similarity"),
            ("s3", "/v/G3.xmp", "template"),
        ]
        try insertSession(db, "s3")
        for item in cases {
            _ = try repo.mergePatch(
                xmpPath: item.path, sessionId: item.session, photoPath: item.path + ".jpg",
                patch: JSONValue.object(["source": JSONValue.string(item.module), "rating": JSONValue.int(1)]),
                dirtyFields: ["rating"])
            #expect(try repo.claim(xmpPath: item.path, expectedRevision: 1))
            #expect(try repo.markWritten(
                xmpPath: item.path, revision: 1, fingerprint: "fp",
                baseValues: .object([:]), backupPath: ""))
            #expect(try repo.hasActiveOtherModule(sessionId: item.session, module: item.module) == false,
                    "自己不算其它模块（\(item.module)）")
            for observed in ["face-keyword", "similarity", "template"] where observed != item.module {
                #expect(try repo.hasActiveOtherModule(sessionId: item.session, module: observed),
                        "\(item.module) 的 written 行必须挡住 \(observed)")
            }
        }

        // culling：交互式连续同步，不在批量互斥门内（不得挡任何批量模块）。
        try insertSession(db, "s4")
        _ = try repo.mergePatch(
            xmpPath: "/v/G4.xmp", sessionId: "s4", photoPath: "/v/G4.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(1)]),
            dirtyFields: ["rating"])
        #expect(try repo.claim(xmpPath: "/v/G4.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(
            xmpPath: "/v/G4.xmp", revision: 1, fingerprint: "fp",
            baseValues: .object([:]), backupPath: ""))
        for observed in ["face-keyword", "similarity", "template"] {
            #expect(try repo.hasActiveOtherModule(sessionId: "s4", module: observed) == false,
                    "culling 的 written 行不得挡住批量模块")
        }
    }

    @Test func recoverableAndOrphanQueries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: p, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg", patch: p, dirtyFields: [])
        // IMG_2：failed（不可恢复态 → 可恢复集合命中 failed）
        _ = try repo.markFailed(xmpPath: "/v/IMG_2.xmp", reason: "XMP_WRITE_FAILED: /v/IMG_2.xmp")
        // IMG_3：synced（不进入可恢复集合）
        #expect(try repo.claim(xmpPath: "/v/IMG_3.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(xmpPath: "/v/IMG_3.xmp", revision: 1, fingerprint: "fp", baseValues: .object([:]), backupPath: ""))
        try repo.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try repo.get("/v/IMG_3.xmp")?.status == "synced")

        let recoverable = try repo.getRecoverableActive().map(\.xmpPath).sorted()
        #expect(recoverable == ["/v/IMG_1.xmp", "/v/IMG_2.xmp"], "pending/failed 可恢复；synced 不在内")

        _ = try repo.mergePatch(xmpPath: "/v/orphan.xmp", sessionId: "s1", photoPath: "/v/orphan.jpg", patch: p, dirtyFields: [])
        try db.prepare("DELETE FROM metadata_outbox_sessions WHERE xmp_path = ?").run([.text("/v/orphan.xmp")])
        let orphans = try repo.getOrphans()
        #expect(orphans.map(\.xmpPath) == ["/v/orphan.xmp"])
    }

    @Test func claimStateMachine() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: [])
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "writing")
        #expect(try repo.get("/v/IMG_1.xmp")?.attemptCount == 1)
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1) == false, "writing 不可二次 claim")
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 2) == false, "revision 不匹配不可 claim")

        #expect(try repo.markFailed(xmpPath: "/v/IMG_1.xmp", reason: "XMP_WRITE_FAILED").status == "failed")
        try repo.resetForRetry("/v/IMG_1.xmp")
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "pending", "resetForRetry 作用于 failed")
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1) == true, "pending 可重新 claim")
        #expect(try repo.recoverInterrupted() == ["/v/IMG_1.xmp"], "启动恢复全量 writing→pending")
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "pending")
    }

    @Test func recoverExpiredLeases() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: [])
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        // 未到期：不回收
        #expect(try repo.recoverExpiredLeases(activePaths: [], leaseMs: 60_000).isEmpty)
        // 在飞：即使 leaseMs=0 也不回收
        #expect(try repo.recoverExpiredLeases(activePaths: ["/v/IMG_1.xmp"], leaseMs: 0).isEmpty)
        // 强制过期：→ pending
        try db.prepare("UPDATE metadata_outbox SET updated_at = ? WHERE xmp_path = ?")
            .run([.text("2000-01-01T00:00:00Z"), .text("/v/IMG_1.xmp")])
        let recovered = try repo.recoverExpiredLeases(activePaths: [], leaseMs: 1_000, maxAttempts: 5)
        #expect(recovered == [MetadataOutboxLeaseRecovery(
            xmpPath: "/v/IMG_1.xmp", newStatus: .pending, reason: "XMP_WRITING_LEASE_EXPIRED")])
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "pending")

        // 达尝试上限：→ failed + 错误码（writing 永远有出口）
        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        try db.prepare("UPDATE metadata_outbox SET updated_at = ?, attempt_count = 5 WHERE xmp_path = ?")
            .run([.text("2000-01-01T00:00:00Z"), .text("/v/IMG_1.xmp")])
        let exhausted = try repo.recoverExpiredLeases(activePaths: [], leaseMs: 1_000, maxAttempts: 5)
        #expect(exhausted == [MetadataOutboxLeaseRecovery(
            xmpPath: "/v/IMG_1.xmp", newStatus: .failed, reason: "XMP_WRITING_LEASE_EXPIRED")])
        #expect(try repo.get("/v/IMG_1.xmp")?.errorMessage == "XMP_WRITING_LEASE_EXPIRED")
    }

    @Test func transitionTableRejectsIllegalMoves() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(MetadataOutboxStatus.writing.canTransition(to: .pending))
        #expect(MetadataOutboxStatus.writing.canTransition(to: .written))
        #expect(!MetadataOutboxStatus.synced.canTransition(to: .writing))

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: [])
        // 非法迁移（pending → synced）必须抛错而不是静默写入。
        do {
            _ = try repo.transition(xmpPath: "/v/IMG_1.xmp", from: [.pending], to: .synced)
            Issue.record("expected illegalTransition")
        } catch let error as MetadataOutboxError {
            #expect(error.code == "XMP_OUTBOX_ILLEGAL_TRANSITION")
        }
        // expected 前置状态不匹配同样抛错。
        do {
            _ = try repo.transition(xmpPath: "/v/IMG_1.xmp", from: [.written], to: .pending)
            Issue.record("expected illegalTransition")
        } catch let error as MetadataOutboxError {
            #expect(error.code == "XMP_OUTBOX_ILLEGAL_TRANSITION")
        }
        // 合法迁移（pending → conflict，携带远程快照）成功。
        let conflicted = try repo.markConflict(xmpPath: "/v/IMG_1.xmp", remote: .object(["rating": .number(5)]), reason: "XMP_EXTERNAL_EDIT_CONFLICT")
        #expect(conflicted.status == "conflict")
        #expect(conflicted.remoteSnapshot == .object(["rating": .number(5)]))
    }

    @Test func markWrittenOnlyReportsRealWrites() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: JSONValue.object(["source": JSONValue.string("manual")]), dirtyFields: [])
        // 未 claim（不在 writing）→ 不得记录落盘成功
        #expect(try repo.markWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp",
            baseValues: .object([:]), backupPath: "/b/1") == false)
        #expect(try repo.get("/v/IMG_1.xmp")?.persistedRevision == 0)
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "pending")

        #expect(try repo.claim(xmpPath: "/v/IMG_1.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(
            xmpPath: "/v/IMG_1.xmp", revision: 1, fingerprint: "fp",
            baseValues: .object(["rating": .number(4)]), backupPath: "/b/1"))
        let row = try repo.get("/v/IMG_1.xmp")
        #expect(row?.status == "written")
        #expect(row?.persistedRevision == 1)
        #expect(row?.baseFingerprint == "fp")
        #expect(row?.baseValuesJSON.contains("\"rating\"") == true)
    }

    @Test func baselineAndBackupUpdates() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let p = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_4.xmp", sessionId: "s1", photoPath: "/v/IMG_4.jpg", patch: p, dirtyFields: [])

        try repo.initializeBaseline(xmpPath: "/v/IMG_4.xmp", baselineFingerprint: "fp1", baselineValues: .object(["rating": .number(1)]))
        #expect(try repo.get("/v/IMG_4.xmp")?.baseFingerprint == "fp1")
        try repo.initializeBaseline(xmpPath: "/v/IMG_4.xmp", baselineFingerprint: "fp2", baselineValues: .object([:]))
        #expect(try repo.get("/v/IMG_4.xmp")?.baseFingerprint == "fp1", "已有基线不被覆盖")

        try repo.setBackupPath(xmpPath: "/v/IMG_4.xmp", backupPath: "/b/4")
        #expect(try repo.get("/v/IMG_4.xmp")?.backupPath == "/b/4")

        try repo.deleteByRevision(xmpPath: "/v/IMG_4.xmp", revision: 999)
        #expect(try repo.get("/v/IMG_4.xmp") != nil, "revision 不匹配不删除")
        try repo.deleteByRevision(xmpPath: "/v/IMG_4.xmp", revision: 1)
        #expect(try repo.get("/v/IMG_4.xmp") == nil)

        _ = try repo.mergePatch(xmpPath: "/v/IMG_5.xmp", sessionId: "s1", photoPath: "/v/IMG_5.jpg", patch: p, dirtyFields: [])
        try repo.delete("/v/IMG_5.xmp")
        #expect(try repo.get("/v/IMG_5.xmp") == nil)
    }

    @Test func discardOnlyRemovesOwnedFieldsAcrossModules() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // IMG_1/IMG_2：face-keyword 的纯预约行（无字段）→ 整行归 face-keyword，可丢弃
        let reservation = JSONValue.object(["source": JSONValue.string("face-keyword")])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_1.xmp", sessionId: "s1", photoPath: "/v/IMG_1.jpg", patch: reservation, dirtyFields: [])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_2.xmp", sessionId: "s1", photoPath: "/v/IMG_2.jpg", patch: reservation, dirtyFields: [])

        // IMG_3：多模块混合行（culling.rating + face-keyword.keywords + similarity.label）
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(3)]), dirtyFields: ["rating"])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg",
            patch: JSONValue.object(["source": JSONValue.string("face-keyword"), "keywords": JSONValue.array([JSONValue.string("k1")])]), dirtyFields: ["keywords"])
        _ = try repo.mergePatch(xmpPath: "/v/IMG_3.xmp", sessionId: "s1", photoPath: "/v/IMG_3.jpg",
            patch: JSONValue.object(["source": JSONValue.string("similarity"), "label": JSONValue.string("Green")]), dirtyFields: ["label"])

        let discarded = try repo.discardModulePending(sessionId: "s1", sourceModule: "face-keyword")
        #expect(discarded.deleted == 2, "纯预约行整行删除")
        #expect(discarded.trimmed == 1, "混合行只裁剪")
        #expect(try repo.get("/v/IMG_1.xmp") == nil)
        let mixed = try repo.get("/v/IMG_3.xmp")
        #expect(mixed?.fieldsPatch.keys.sorted() == ["label", "rating"], "关键词（face-keyword 拥有）被丢弃，其它模块字段保留")
        #expect(mixed?.fieldOwners["keywords"] == nil)
        #expect(mixed?.fieldOwners["rating"] == "culling")
        #expect(mixed?.fieldOwners["label"] == "similarity")
        #expect(mixed?.dirty == ["rating", "label"])
        #expect(mixed?.status == "pending")
    }

    @Test func pathNormalizationIsSingleValued() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // photo 路径与 sidecar 路径混用 → 同一行（唯一口径）
        let photo = "/v/deep/IMG_9.CR3"
        // 独立 oracle（手算，不调用被测表达式）：dirname(/v/deep) + stem(IMG_9) + ".xmp"。
        // 旧断言写的是 `TSPath.xmpSidecarPath(ScanPath.canonical(photo))` —— 那是实现本身的
        // 复述，去掉 canonical（变异 M5）也照绿，等于零覆盖。
        #expect(MetadataOutboxPath.sidecar(photo) == "/v/deep/IMG_9.xmp")
        #expect(MetadataOutboxPath.normalize("/v/deep/IMG_9.xmp") == "/v/deep/IMG_9.xmp", "对侧车路径幂等")

        let p = JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(2)])
        let viaPhoto = try repo.mergePatch(xmpPath: photo, sessionId: "s1", photoPath: photo, patch: p, dirtyFields: ["rating"])
        let viaSidecar = try repo.mergePatch(xmpPath: "/v/deep/IMG_9.xmp", sessionId: "s1", photoPath: photo, patch: .object(["source": .string("culling"), "label": .string("Red")]), dirtyFields: ["label"])
        #expect(viaPhoto.xmpPath == "/v/deep/IMG_9.xmp")
        #expect(viaSidecar.xmpPath == "/v/deep/IMG_9.xmp")
        #expect(viaSidecar.revision == 2, "两次入队落在同一行")
        #expect(viaSidecar.photoPath == "/v/deep/IMG_9.CR3")
        #expect(try repo.getBySession("s1").count == 1)
    }

    /// 变异守卫：claim 的 WHERE 若只接受 'pending'，失败行（flushSession/进程重排的
    /// 输入）永远抢不到租约 —— 静默跳过而不是重试。
    @Test func claimRetriesFailedRowWithoutReset() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_F.xmp", sessionId: "s1", photoPath: "/v/IMG_F.jpg",
            patch: JSONValue.object(["source": JSONValue.string("manual"), "rating": JSONValue.int(2)]),
            dirtyFields: ["rating"])
        #expect(try repo.markFailed(xmpPath: "/v/IMG_F.xmp", reason: "XMP_WRITE_FAILED").status == "failed")

        // 不先 resetForRetry：failed → writing 是合法迁移，必须能直接抢到租约。
        #expect(try repo.claim(xmpPath: "/v/IMG_F.xmp", expectedRevision: 1), "failed 行必须可被 claim（重试路径）")
        #expect(try repo.get("/v/IMG_F.xmp")?.status == "writing")
        #expect(try repo.get("/v/IMG_F.xmp")?.attemptCount == 1)
    }

    /// 变异守卫：keepsPatch 的终态集合若漏掉 'synced'，已确认行的旧合成事务会被
    /// 并进下一次 patch —— 每次写回都重写上一轮已落盘的关键词。
    @Test func mergePatchAfterSyncedStartsFreshRevisionAndDropsStalePatch() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_S.xmp", sessionId: "s1", photoPath: "/v/IMG_S.jpg",
            patch: JSONValue.object(["source": JSONValue.string("face-keyword"),
                                     "keywords": JSONValue.array([JSONValue.string("stale")])]),
            dirtyFields: ["keywords"])
        #expect(try repo.claim(xmpPath: "/v/IMG_S.xmp", expectedRevision: 1))
        #expect(try repo.markWritten(
            xmpPath: "/v/IMG_S.xmp", revision: 1, fingerprint: "fp",
            baseValues: .object([:]), backupPath: ""))
        try repo.markSessionSynced(sessionId: "s1", sourceModule: "face-keyword")
        #expect(try repo.get("/v/IMG_S.xmp")?.status == "synced")

        let next = try repo.mergePatch(
            xmpPath: "/v/IMG_S.xmp", sessionId: "s1", photoPath: "/v/IMG_S.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "label": JSONValue.string("Red")]),
            dirtyFields: ["label"])
        #expect(next.status == "pending")
        #expect(next.revision == 2)
        #expect(next.dirty == ["label"])
        #expect(next.fieldsPatch.keys.sorted() == ["label"], "synced 行的旧 patch 不得被合并进新 revision")
        #expect(next.fieldOwners["keywords"] == nil)
    }

    /// 变异守卫：路径口径若丢掉 ScanPath.canonical，/private 前缀与 "." / ".." 分量
    /// 的两种拼写会落到两行 —— 同一侧车被并发写两次。
    @Test func sidecarKeyFoldsPrivatePrefixAndDotSegments() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(MetadataOutboxPath.sidecar("/private/tmp/gather-x/IMG.cr3") == "/tmp/gather-x/IMG.xmp")
        #expect(MetadataOutboxPath.sidecar("/v/deep/./IMG.cr3") == "/v/deep/IMG.xmp")
        #expect(MetadataOutboxPath.sidecar("/v/a/../b/IMG.cr3") == "/v/b/IMG.xmp")

        let p = JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(2)])
        let viaPrivate = try repo.mergePatch(
            xmpPath: "/private/tmp/gather-x/IMG.cr3", sessionId: "s1",
            photoPath: "/private/tmp/gather-x/IMG.cr3", patch: p, dirtyFields: ["rating"])
        let viaPublic = try repo.mergePatch(
            xmpPath: "/tmp/gather-x/IMG.cr3", sessionId: "s1",
            photoPath: "/tmp/gather-x/IMG.cr3", patch: p, dirtyFields: ["rating"])
        #expect(viaPrivate.xmpPath == viaPublic.xmpPath)
        #expect(viaPublic.revision == 2, "同一侧车的两种拼写必须落在同一行")
        #expect(try repo.getBySession("s1").count == 1)
    }

    /// 变异守卫：mergePatch 的 CASE 若把 conflict 行写成 pending，未裁决的外部编辑
    /// 会被新变更静默覆盖（远程快照也必须随行保留）。
    @Test func mergePatchOnConflictRowKeepsConflictAndRemoteSnapshot() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_C.xmp", sessionId: "s1", photoPath: "/v/IMG_C.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(4)]),
            dirtyFields: ["rating"])
        _ = try repo.markConflict(
            xmpPath: "/v/IMG_C.xmp", remote: .object(["rating": .number(9)]),
            reason: "XMP_EXTERNAL_EDIT_CONFLICT")

        let row = try repo.mergePatch(
            xmpPath: "/v/IMG_C.xmp", sessionId: "s1", photoPath: "/v/IMG_C.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "label": JSONValue.string("Red")]),
            dirtyFields: ["label"])
        #expect(row.status == "conflict", "冲突未裁决前不得降级为 pending")
        #expect(row.remoteSnapshot == .object(["rating": .number(9)]), "远程快照必须随行保留")
        #expect(row.revision == 2)
    }

    /// 变异守卫：遗留 clean/cleaned 行被新变更命中必须重开为 pending。
    /// 迁移表刻意不含 clean/cleaned → pending（入队是"重开一行"的原子 CAS，不经
    /// transition()）—— 这条偏差是**必需的**：保持遗留终态会让该行永不写盘。
    @Test func mergePatchReopensLegacyCleanRowAsPending() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.mergePatch(
            xmpPath: "/v/IMG_L.xmp", sessionId: "s1", photoPath: "/v/IMG_L.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "rating": JSONValue.int(4)]),
            dirtyFields: ["rating"])
        #expect(!MetadataOutboxStatus.clean.canTransition(to: .pending), "迁移表不接受 clean→pending（偏差是有意的）")
        #expect(!MetadataOutboxStatus.cleaned.canTransition(to: .pending))
        try db.prepare("UPDATE metadata_outbox SET status = 'clean' WHERE xmp_path = ?")
            .run([.text("/v/IMG_L.xmp")])

        let row = try repo.mergePatch(
            xmpPath: "/v/IMG_L.xmp", sessionId: "s1", photoPath: "/v/IMG_L.jpg",
            patch: JSONValue.object(["source": JSONValue.string("culling"), "label": JSONValue.string("Red")]),
            dirtyFields: ["label"])
        #expect(row.status == "pending", "遗留终态行被新变更命中必须重开为 pending，否则永不写盘")
        #expect(try repo.getRecoverableActive().map(\.xmpPath) == ["/v/IMG_L.xmp"],
                "重开后必须进入可恢复集合（协调器才会真正写它）")
    }
}

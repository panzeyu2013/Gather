// desktop/native/gather-core/Tests/GatherCoreTests/Database/DeliveryRepoTests.swift
// Cut 2 / S2：delivery 持久化层的行为门禁（只覆盖新表，不碰旧 outbox/writeback）。
//
// 建库口径：DBConnection(path: ":memory:") + exec(SchemaCurrent.createSQL)——一次性建齐 43 表/索引/FK，
// 与 Database.open 的 Cut 2 接线方式一致；不用迁移链（D-003：V1 不做版本升级）。
//
// 覆盖面：
// 1. create/get 幂等（xmp_path UNIQUE 冲突不覆盖首次写入）；
// 2. revision CAS 成功/失败 + 状态 CAS（迁移表拒绝 documented 非法路径）；
// 3. 合法/非法状态迁移（delivery + item，含 synced 重新打开与 cleaned 终态）；
// 4. item upsert / UNIQUE(delivery_id,photo_id,module) 冲突更新；
// 5. confirm 单事务：跨会话门禁、module scope、失败整体回滚（触发器注入）；
// 6. 显式列读取按列名映射，不依赖 DDL 物理列序（乱序列清单 + 缺列显式失败）；
// 7. CHECK 取值集合与 Swift enum 双向一致（draft §4.1）。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

// MARK: - V1 内存库 fixtures

private func makeV1DB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaCurrent.createSQL)
    return db
}

private func v1InsertSession(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, '', 'draft', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id)])
}

private func v1InsertPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, created_at, updated_at)
        VALUES (?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
        """).run([.text(id), .text(sessionId), .text("/photos/" + id + ".jpg"), .text(id + ".jpg")])
}

private func v1Count(_ db: DBConnection, _ sql: String, _ values: [DBValue?] = []) throws -> Int {
    guard let row = try db.prepare(sql).get(values) else { return 0 }
    return Int(row[0].intValue ?? 0)
}

private func v1ConfirmedAt(_ db: DBConnection, xmpPath: String, sessionId: String) throws -> String {
    let row = try db.prepare("""
        SELECT ds.confirmed_at
        FROM delivery_sessions ds
        JOIN deliveries d ON d.id = ds.delivery_id
        WHERE d.xmp_path = ? AND ds.session_id = ?
        """).get([.text(xmpPath), .text(sessionId)])
    return row?[0].textValue ?? ""
}

private func v1TableSQL(_ db: DBConnection, _ table: String) throws -> String? {
    try db.prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")
        .get([.text(table)])?[0].textValue
}

/// 从 CREATE TABLE 文本里取出 CHECK (column IN ('a','b',...)) 的取值集合。
private func v1CheckValues(_ sql: String, column: String) throws -> Set<String> {
    let marker = column + " IN ("
    guard let range = sql.range(of: marker) else {
        throw DeliveryRepoError.missingColumn("CHECK " + marker)
    }
    let rest = sql[range.upperBound...]
    guard let end = rest.firstIndex(of: ")") else {
        throw DeliveryRepoError.invalidArgument("CHECK 未闭合: " + marker)
    }
    return Set(rest[..<end].split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    })
}

// MARK: - 测试

struct DeliveryRepoTests {
    private let xmp = "/v/IMG_1.xmp"
    private let photo = "/v/IMG_1.jpg"

    private func makeRepo() throws -> (DBConnection, DeliveryRepo) {
        let db = try makeV1DB()
        try v1InsertSession(db, "s1")
        try v1InsertSession(db, "s2")
        return (db, DeliveryRepo(connection: db))
    }

    /// 把交付推进到 written（写成功、待确认）。
    private func driveToWritten(
        _ repo: DeliveryRepo,
        xmpPath: String,
        revision: Int64
    ) throws {
        _ = try repo.markWriting(xmpPath: xmpPath, revision: revision)
        _ = try repo.markWritten(
            xmpPath: xmpPath, revision: revision,
            baseFingerprint: "fp-1", baseValues: .object([:]), backupPath: "/v/IMG_1.xmp.gather-backup-test")
    }

    // MARK: create / get

    @Test func createOrGetIsIdempotentAndKeepsFirstWrite() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let first = try repo.createOrGet(
            xmpPath: self.xmp,
            photoPath: self.photo,
            revision: 3,
            baseFingerprint: "fp-a",
            baseValues: .object(["rating": .number(5)])
        )
        #expect(first.status == "pending")
        #expect(first.revision == 3)
        #expect(first.attemptCount == 0)

        // 同一 xmp 路径（带 ./ 归一化）再次入队：不覆盖首次写入。
        let second = try repo.createOrGet(
            xmpPath: "/v/./IMG_1.xmp",
            photoPath: "/elsewhere/IMG_1.jpg",
            revision: 99,
            baseFingerprint: "fp-b"
        )
        #expect(second.id == first.id)
        #expect(second.photoPath == self.photo)
        #expect(second.revision == 3)
        #expect(second.baseFingerprint == "fp-a")
        #expect(try v1Count(db, "SELECT COUNT(*) FROM deliveries") == 1)

        let fetched = try #require(try repo.get(self.xmp))
        #expect(fetched.id == first.id)
        #expect(try repo.get("/v/missing.xmp") == nil)
    }

    @Test func createOrGetRejectsNegativeRevision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        do {
            _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: -1)
            Issue.record("负 revision 必须被拒绝")
        } catch let error as DeliveryRepoError {
            guard case .invalidArgument = error else {
                Issue.record("错误类型不符: \(error)")
                return
            }
        } catch {
            Issue.record("错误类型不符: \(error)")
        }
        #expect(try v1Count(db, "SELECT COUNT(*) FROM deliveries") == 0)
    }

    // MARK: 状态迁移 / CAS

    @Test func markWritingThenWrittenPersistsLeaseAndBaseline() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 2)

        let writing = try #require(try repo.markWriting(
            xmpPath: self.xmp, revision: 2, leaseOwner: "worker-1"))
        #expect(writing.status == "writing")
        #expect(writing.attemptCount == 1)
        #expect(writing.leaseOwner == "worker-1")
        #expect(writing.heartbeatAt != "")
        #expect(writing.revision == 2, "状态迁移不推进 revision（revision 是输入版本号）")

        let written = try #require(try repo.markWritten(
            xmpPath: self.xmp,
            revision: 2,
            leaseOwner: "worker-1",
            baseFingerprint: "fp-after",
            baseValues: .object(["rating": .number(4)]),
            backupPath: "/v/IMG_1.xmp.gather-backup-test"
        ))
        #expect(written.status == "written")
        #expect(written.baseFingerprint == "fp-after")
        #expect(written.backupPath == "/v/IMG_1.xmp.gather-backup-test")
        #expect(written.baseValues == .object(["rating": .number(4)]))
        #expect(written.leaseOwner == "")
        #expect(written.heartbeatAt == "")
    }

    // MARK: writing 租约（P1-2：claim / renew）

    @Test func claimWritingRenewsSameOwnerWithoutBumpingAttempt() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 3)
        let first = try #require(try repo.claimWriting(
            xmpPath: self.xmp, revision: 3, leaseOwner: "w1",
            heartbeatAt: "2026-01-01T00:00:00.000Z"))
        #expect(first.status == "writing")
        #expect(first.attemptCount == 1)
        #expect(first.leaseOwner == "w1")
        #expect(first.heartbeatAt == "2026-01-01T00:00:00.000Z")

        // 同 owner 续租：刷新 heartbeat，不新增写尝试。
        let renewed = try #require(try repo.claimWriting(
            xmpPath: self.xmp, revision: 3, leaseOwner: "w1",
            now: Date().addingTimeInterval(10)))
        #expect(renewed.attemptCount == 1, "续租不是新的写尝试")
        #expect(renewed.leaseOwner == "w1")
        #expect(renewed.heartbeatAt != first.heartbeatAt)
        #expect(renewed.status == "writing")

        // renewWriting 只动 heartbeat，不满足 owner 条件时返回 false。
        #expect(try repo.renewWriting(
            xmpPath: self.xmp, revision: 3, leaseOwner: "w2") == false)
        #expect(try repo.renewWriting(
            xmpPath: self.xmp, revision: 3, leaseOwner: "w1"))
    }

    @Test func claimWritingRejectsOtherOwnerWhileLeaseIsFresh() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 2)
        _ = try repo.claimWriting(xmpPath: self.xmp, revision: 2, leaseOwner: "w1")

        do {
            _ = try repo.claimWriting(xmpPath: self.xmp, revision: 2, leaseOwner: "w2")
            Issue.record("未过期的他人租约必须拒绝抢占")
        } catch let error as DeliveryRepoError {
            guard case .leaseHeld(let path, let owner, let heartbeat) = error else {
                Issue.record("错误类型不符: \(error)")
                return
            }
            #expect(path == self.xmp)
            #expect(owner == "w1")
            #expect(!heartbeat.isEmpty)
        }

        // 拒绝后行保持原 owner/attempt，未被静默改写。
        let row = try #require(try repo.get(self.xmp))
        #expect(row.status == "writing")
        #expect(row.leaseOwner == "w1")
        #expect(row.attemptCount == 1)
    }

    @Test func claimWritingPreemptsExpiredLease() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 2)
        _ = try repo.claimWriting(xmpPath: self.xmp, revision: 2, leaseOwner: "w1")

        // 超过 TTL（5 分钟）后视为崩溃遗留：新 owner 抢占并 +1 次写尝试。
        let stolen = try #require(try repo.claimWriting(
            xmpPath: self.xmp, revision: 2, leaseOwner: "w2",
            now: Date().addingTimeInterval(DeliveryRepo.writingLeaseTTLSeconds + 1)))
        #expect(stolen.status == "writing")
        #expect(stolen.leaseOwner == "w2")
        #expect(stolen.attemptCount == 2)
    }

    @Test func markWrittenRejectsTheWrongLeaseOwnerAndKeepsRow() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 3)
        _ = try repo.claimWriting(xmpPath: self.xmp, revision: 3, leaseOwner: "writer-a")

        do {
            _ = try repo.markWritten(
                xmpPath: self.xmp, revision: 3, leaseOwner: "writer-b",
                baseFingerprint: "fp-thief",
                baseValues: .object(["rating": .number(1)]),
                backupPath: "/backup/thief.xmp")
            Issue.record("owner 不匹配必须拒绝 markWritten")
        } catch let error as DeliveryRepoError {
            guard case .leaseLost(let path, let owner, let currentOwner, let status) = error else {
                Issue.record("错误类型不符: \(error)")
                return
            }
            #expect(path == self.xmp)
            #expect(owner == "writer-b")
            #expect(currentOwner == "writer-a")
            #expect(status == "writing")
        }

        // 行必须原样保留：错 owner 不得覆盖基线或清租约。
        let untouched = try #require(try repo.get(self.xmp))
        #expect(untouched.status == "writing")
        #expect(untouched.leaseOwner == "writer-a")
        #expect(untouched.baseFingerprint == "")
        #expect(untouched.backupPath == "")

        // 真正持有租约的 writer 仍可提交（拒绝不是把行锁死）。
        let written = try #require(try repo.markWritten(
            xmpPath: self.xmp, revision: 3, leaseOwner: "writer-a",
            baseFingerprint: "fp-a",
            baseValues: .object(["rating": .number(5)]),
            backupPath: "/backup/a.xmp"))
        #expect(written.status == "written")
        #expect(written.baseFingerprint == "fp-a")
        #expect(written.leaseOwner == "")
    }

    @Test func claimWritingPreemptsWritingRowWithEmptyHeartbeat() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 1)
        // 旧实现/历史行可能只有 "" heartbeat：按过期处理，允许抢占。
        _ = try repo.markWriting(
            xmpPath: self.xmp, revision: 1, leaseOwner: "", heartbeatAt: "")
        let stolen = try #require(try repo.claimWriting(
            xmpPath: self.xmp, revision: 1, leaseOwner: "w2"))
        #expect(stolen.leaseOwner == "w2")
        #expect(!stolen.heartbeatAt.isEmpty)
        #expect(stolen.attemptCount == 2)
    }

    @Test func revisionCasRejectsStaleRevisionAndIllegalStatus() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 7)

        // revision 过期：CAS 返回 nil，行保持 pending。
        #expect(try repo.markWriting(xmpPath: self.xmp, revision: 6) == nil)
        #expect(try repo.get(self.xmp)?.status == "pending")

        let writing = try #require(try repo.markWriting(xmpPath: self.xmp, revision: 7))
        #expect(writing.status == "writing")

        let written = try #require(try repo.markWritten(
            xmpPath: self.xmp, revision: 7,
            baseFingerprint: "", baseValues: .object([:]), backupPath: ""))
        #expect(written.status == "written")

        // 状态 CAS：written → writing 不在迁移表内，必须显式拒绝而不是返回 nil。
        #expect(throws: DeliveryRepoError.illegalTransition(
            xmpPath: self.xmp, from: "written", to: "writing")) {
            _ = try repo.markWriting(xmpPath: self.xmp, revision: 7)
        }
    }

    @Test func markSyncedOnlyAcceptsWrittenOrSynced() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 1)
        #expect(throws: DeliveryRepoError.illegalTransition(
            xmpPath: self.xmp, from: "pending", to: "synced")) {
            _ = try repo.markSynced(xmpPath: self.xmp, revision: 1)
        }

        try driveToWritten(repo, xmpPath: self.xmp, revision: 1)
        let synced = try #require(try repo.markSynced(xmpPath: self.xmp, revision: 1))
        #expect(synced.status == "synced")

        // 自迁移幂等（重放同一请求不抛错）。
        let replay = try #require(try repo.markSynced(xmpPath: self.xmp, revision: 1))
        #expect(replay.status == "synced")
    }

    @Test func failedAndConflictTransitionsClearLease() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 4)
        _ = try repo.markWriting(xmpPath: self.xmp, revision: 4, leaseOwner: "w1")

        let failed = try #require(try repo.markFailedForTesting(
            xmpPath: self.xmp, revision: 4, errorMessage: "disk full", leaseOwner: "w1"))
        #expect(failed.status == "failed")
        #expect(failed.errorMessage == "disk full")
        #expect(failed.leaseOwner == "")
        #expect(failed.attemptCount == 1)

        // failed → writing 重试，attempt_count 递增。
        let retry = try #require(try repo.markWriting(xmpPath: self.xmp, revision: 4))
        #expect(retry.attemptCount == 2)

        let conflict = try #require(try repo.markConflictForTesting(
            xmpPath: self.xmp, revision: 4, errorMessage: "external edit"))
        #expect(conflict.status == "conflict")
        #expect(conflict.errorMessage == "external edit")

        // conflict → writing（裁决后直接重写）合法。
        #expect(try repo.markWriting(xmpPath: self.xmp, revision: 4)?.status == "writing")

        // 不存在的行：显式 rowNotFound（不是 CAS nil）。
        #expect(throws: DeliveryRepoError.rowNotFound(xmpPath: "/v/missing.xmp")) {
            _ = try repo.markWriting(xmpPath: "/v/missing.xmp", revision: 0)
        }
    }


    /// P2：markFailed/markConflict 与 markWritten 同一 owner CAS。
    @Test func failedAndConflictRejectLeaseTakenOverByAnotherWriter() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 2)
        _ = try repo.markWriting(
            xmpPath: self.xmp, revision: 2, leaseOwner: "old",
            heartbeatAt: "2020-01-01T00:00:00.000Z")
        _ = try #require(try repo.claimWriting(
            xmpPath: self.xmp, revision: 2, leaseOwner: "new"))

        let lost = DeliveryRepoError.leaseLost(
            xmpPath: self.xmp, leaseOwner: "old",
            currentOwner: "new", status: "writing")
        #expect(throws: lost) {
            _ = try repo.markFailedForTesting(
                xmpPath: self.xmp, revision: 2, errorMessage: "boom", leaseOwner: "old")
        }
        #expect(throws: lost) {
            _ = try repo.markConflictForTesting(
                xmpPath: self.xmp, revision: 2, errorMessage: "external", leaseOwner: "old")
        }
        // 空 owner 同样带 lease_owner='' CAS：不能覆盖新租约，只返回 nil。
        #expect(try repo.markFailedForTesting(
            xmpPath: self.xmp, revision: 2, errorMessage: "boom") == nil)

        let failed = try #require(try repo.markFailedForTesting(
            xmpPath: self.xmp, revision: 2, errorMessage: "boom", leaseOwner: "new"))
        #expect(failed.status == "failed")
        #expect(failed.leaseOwner == "")
    }

    @Test func cleanedIsTerminalAndLegacyCleanValueIsRemoved() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try db.prepare("UPDATE deliveries SET status = 'cleaned' WHERE xmp_path = ?")
            .run([.text(self.xmp)])

        // cleaned 是终态：不可复活（要重写就新建行）。
        #expect(throws: DeliveryRepoError.illegalTransition(
            xmpPath: self.xmp, from: "cleaned", to: "writing")) {
            _ = try repo.markWriting(xmpPath: self.xmp, revision: 0)
        }
        #expect(DeliveryStatus.cleaned.canTransition(to: .synced) == false)
        #expect(DeliveryStatus.synced.canTransition(to: .cleaned))
        // draft §4.5-2：旧 8 值里的 clean 不再进入新 enum。
        #expect(DeliveryStatus(rawValue: "clean") == nil)
    }

    @Test func stateEnumsMatchSchemaCheckConstraints() throws {
        let db = try makeV1DB()
        defer { db.close() }

        let deliveriesSQL = try #require(try v1TableSQL(db, "deliveries"))
        #expect(try v1CheckValues(deliveriesSQL, column: "status")
            == Set(DeliveryStatus.allCases.map(\.rawValue)))

        let itemsSQL = try #require(try v1TableSQL(db, "delivery_items"))
        #expect(try v1CheckValues(itemsSQL, column: "status")
            == Set(DeliveryItemStatus.allCases.map(\.rawValue)))
        #expect(try v1CheckValues(itemsSQL, column: "module")
            == Set(DeliveryModule.allCases.map(\.rawValue)))
    }

    // MARK: items

    @Test func itemUpsertUpdatesExistingRowOnUniqueConflict() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)

        let first = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling,
            attributes: ["rating": .number(1)], keywords: ["a"])
        #expect(first.typedStatus == .pending)
        #expect(first.typedModule == .culling)

        let second = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling,
            attributes: ["rating": .number(2)], keywords: ["a", "b"], status: .written)
        #expect(second.id == first.id, "UNIQUE(delivery_id,photo_id,module) 命中同一行")
        #expect(second.typedStatus == .written)
        #expect(second.attributes["rating"] == .number(2))
        #expect(second.keywordList == ["a", "b"])
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_items") == 1)

        // written → pending：新输入重新打开同一条 item。
        let reopened = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling,
            keywords: ["a"], status: .pending)
        #expect(reopened.typedStatus == .pending)
        #expect(reopened.keywordList == ["a"])
    }

    @Test func itemIllegalTransitionIsRejected() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .pending)

        #expect(throws: DeliveryRepoError.illegalTransition(
            xmpPath: self.xmp, from: "item:pending", to: "item:synced")) {
            _ = try repo.upsertItem(
                xmpPath: self.xmp, photoId: "p1", module: .culling, status: .synced)
        }

        // pending → written → synced → pending 是合法链。
        #expect(try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written).typedStatus == .written)
        #expect(try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling, status: .synced).typedStatus == .synced)
        #expect(try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling, status: .pending).typedStatus == .pending)
    }

    @Test func listItemsScopesBySessionModuleAndStatus() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        try v1InsertPhoto(db, id: "p2", sessionId: "s1")
        try v1InsertPhoto(db, id: "p3", sessionId: "s2")
        _ = try repo.createOrGet(xmpPath: "/v/IMG_1.xmp", photoPath: "/v/IMG_1.jpg")
        _ = try repo.createOrGet(xmpPath: "/v/IMG_2.xmp", photoPath: "/v/IMG_2.jpg")
        _ = try repo.upsertItem(xmpPath: "/v/IMG_1.xmp", photoId: "p1", module: .culling)
        _ = try repo.upsertItem(
            xmpPath: "/v/IMG_1.xmp", photoId: "p2", module: .faceKeyword,
            keywords: ["alice"], status: .written)
        _ = try repo.upsertItem(xmpPath: "/v/IMG_2.xmp", photoId: "p3", module: .similarity)

        let s1Items = try repo.listItems(sessionId: "s1")
        #expect(s1Items.count == 2)
        #expect(Set(s1Items.map(\.photoId)) == ["p1", "p2"])

        #expect(try repo.listItems(sessionId: "s1", module: .faceKeyword).map(\.photoId) == ["p2"])
        let written = try repo.listItems(sessionId: "s1", status: .written)
        #expect(written.count == 1)
        #expect(written[0].keywordList == ["alice"])
        #expect(written[0].xmpPath == "/v/IMG_1.xmp")

        #expect(try repo.listItems(sessionId: "s2").map(\.xmpPath) == ["/v/IMG_2.xmp"])
    }

    @Test func deleteItemsOnlyRemovesRequestedStatuses() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        try v1InsertPhoto(db, id: "p2", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .pending)
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p2", module: .culling, status: .written)

        // 默认只删 pending/failed（旧 discard 语义）。
        #expect(try repo.deleteItems(xmpPath: self.xmp) == 1)
        #expect(try repo.listItems(sessionId: "s1").map(\.photoId) == ["p2"])
        #expect(try repo.deleteItems(xmpPath: self.xmp, module: .faceKeyword) == 0)
        #expect(try repo.deleteItems(
            xmpPath: self.xmp, module: .culling, statuses: [.written]) == 1)
        #expect(try repo.listItems(sessionId: "s1").isEmpty)
    }

    // MARK: 会话链接 / confirm

    @Test func linkSessionRejectsUnknownSessionAndLeavesNoRow() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)

        var threw = false
        do {
            _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "ghost")
        } catch {
            threw = true
        }
        #expect(threw, "FK 必须拒绝不存在的 session")
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_sessions") == 0)

        // 正常链接幂等。
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_sessions") == 1)
    }

    @Test func applyMetadataMutationRollsBackWhenSessionLinkFails() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")

        // linkSession 链接不存在的 session：openDelivery + mergeItem 已执行，
        // FK 必须让整个原子入口回滚（而不是留下 revision 已推进的幽灵 pending）。
        #expect(throws: (any Error).self) {
            _ = try repo.applyMetadataMutation(
                xmpPath: self.xmp,
                photoPath: self.photo,
                photoId: "p1",
                sessionId: "ghost",
                attributes: ["rating": .number(5)],
                keywords: ["keep"])
        }
        #expect(try repo.get(self.xmp) == nil)
        #expect(try v1Count(db, "SELECT COUNT(*) FROM deliveries") == 0)
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_items") == 0)
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_sessions") == 0)
        let empty = try DeliverySummaryQuery(connection: db)
            .summary(sessionId: "s1", module: .metadata)
        #expect(empty.isEmpty)
        #expect(empty.isConfirmable)

        // 失败没有消耗 revision：同一输入重试是首个输入（revision 1），
        // item 与 link 由同一次提交落库。
        let row = try repo.applyMetadataMutation(
            xmpPath: self.xmp,
            photoPath: self.photo,
            photoId: "p1",
            sessionId: "s1",
            attributes: ["rating": .number(5)],
            keywords: ["keep"])
        #expect(row.revision == 1)
        #expect(row.typedStatus == .pending)
        let item = try #require(try repo.item(
            xmpPath: self.xmp, photoId: "p1", module: .metadata))
        #expect(item.attributes["rating"] == .number(5))
        #expect(item.keywordList == ["keep"])
        #expect(try v1Count(
            db, "SELECT COUNT(*) FROM delivery_sessions WHERE session_id = 's1'") == 1)
    }

    @Test func confirmSyncsDeliveryItemsAndLinksInOneTransaction() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        let summary = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(summary.confirmedLinks == 1)
        #expect(summary.deliveriesSynced == 1)
        #expect(summary.itemsSynced == 1)
        #expect(summary.unconfirmedSessionIds.isEmpty)
        #expect(try repo.get(self.xmp)?.status == "synced")
        #expect(try repo.listItems(sessionId: "s1").first?.typedStatus == .synced)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "")

        // 重复 confirm 幂等：不产生二次迁移、计数为 0。
        let replay = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(replay.confirmedLinks == 0)
        #expect(replay.deliveriesSynced == 0)
        #expect(replay.itemsSynced == 0)
    }

    @Test func confirmWaitsForAllLinkedSessions() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s2")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        let first = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(first.confirmedLinks == 1)
        #expect(first.deliveriesSynced == 0, "仍有未确认会话：delivery 不得翻 synced")
        #expect(first.itemsSynced == 0)
        #expect(first.unconfirmedSessionIds == ["s2"])
        #expect(try repo.get(self.xmp)?.status == "written")
        #expect(try repo.listItems(sessionId: "s1").first?.typedStatus == .written)

        let second = try repo.confirm(scope: .session, sessionId: "s2")
        #expect(second.confirmedLinks == 1)
        #expect(second.deliveriesSynced == 1)
        #expect(second.itemsSynced == 1)
        #expect(second.unconfirmedSessionIds.isEmpty)
        #expect(try repo.get(self.xmp)?.status == "synced")
    }

    @Test func confirmGateRereadsStatusInsideTheSameTransaction() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // 模拟「门禁读之后、confirmed_at 更新之前」另一个写者 mergeInput：
        // 交付被重开为 pending（所有关联会话确认同时失效）。
        _ = try repo.mergeInput(
            xmpPath: self.xmp, photoPath: self.photo,
            expectedRevision: 0, newRevision: 1,
            baseFingerprint: "fp-new", baseValues: .object([:]))

        // 门禁在事务内重读：拒绝，且不落 confirmed_at（旧实现会写半套确认）。
        #expect(throws: DeliveryConfirmGateError.incomplete(
            blockers: ["delivery:pending=1"])) {
            _ = try repo.confirm(scope: .session, sessionId: "s1")
        }
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "",
                "被重开的交付不得落 confirmed_at")
        #expect(try repo.get(self.xmp)?.status == "pending")

        // 新 revision 重新写回后门禁放行：不是永久拒绝。
        try driveToWritten(repo, xmpPath: self.xmp, revision: 1)
        let confirmed = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(confirmed.confirmedLinks == 1)
        #expect(confirmed.deliveriesSynced == 1)
    }

    @Test func linkSessionAddsNewSessionUnconfirmedAndBlocksConfirm() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertSession(db, "s3")
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s2")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // s1 先确认：s2 仍未确认，delivery 停在 written。
        let first = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(first.deliveriesSynced == 0)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "")
        #expect(try repo.get(self.xmp)?.status == "written")

        // 新链接 s3：必须从「未确认」开始，不得继承交付上已有的确认；
        // 链接本身也不得清掉 s1 已有的确认。
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s3")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s3") == "",
                "新链接会话必须从 confirmed_at='' 开始")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "",
                "linkSession 不得替其他会话清确认")
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_sessions") == 3)
        #expect(try repo.get(self.xmp)?.status == "written", "链接本身不改 delivery.status")

        // s1 再确认也不能翻 synced：新链接的 s3（以及 s2）仍未确认。
        let again = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(again.confirmedLinks == 0)
        #expect(again.deliveriesSynced == 0)
        #expect(again.unconfirmedSessionIds == ["s2", "s3"])
        #expect(try repo.get(self.xmp)?.status == "written")

        // 两个后来者都确认后才允许翻 synced。
        #expect(try repo.confirm(scope: .session, sessionId: "s2").deliveriesSynced == 0)
        let last = try repo.confirm(scope: .session, sessionId: "s3")
        #expect(last.deliveriesSynced == 1)
        #expect(last.unconfirmedSessionIds.isEmpty)
        #expect(try repo.get(self.xmp)?.status == "synced")
    }

    @Test func moduleScopeConfirmsOnlyMatchingDeliveries() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        try v1InsertPhoto(db, id: "p2", sessionId: "s1")

        _ = try repo.createOrGet(xmpPath: "/v/IMG_1.xmp", photoPath: "/v/IMG_1.jpg")
        _ = try repo.linkSession(xmpPath: "/v/IMG_1.xmp", sessionId: "s1")
        _ = try repo.upsertItem(
            xmpPath: "/v/IMG_1.xmp", photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: "/v/IMG_1.xmp", revision: 0)

        _ = try repo.createOrGet(xmpPath: "/v/IMG_2.xmp", photoPath: "/v/IMG_2.jpg")
        _ = try repo.linkSession(xmpPath: "/v/IMG_2.xmp", sessionId: "s1")
        _ = try repo.upsertItem(
            xmpPath: "/v/IMG_2.xmp", photoId: "p2", module: .faceKeyword, status: .written)
        try driveToWritten(repo, xmpPath: "/v/IMG_2.xmp", revision: 0)

        let summary = try repo.confirm(scope: .module, sessionId: "s1", module: .culling)
        #expect(summary.confirmedLinks == 1)
        #expect(summary.deliveriesSynced == 1)
        #expect(summary.itemsSynced == 1)
        #expect(try repo.get("/v/IMG_1.xmp")?.status == "synced")
        #expect(try repo.get("/v/IMG_2.xmp")?.status == "written")
        #expect(try v1ConfirmedAt(db, xmpPath: "/v/IMG_2.xmp", sessionId: "s1") == "")

        // scope=.module 必须带 module。
        #expect(throws: DeliveryRepoError.invalidArgument("scope=.module 必须提供 module")) {
            _ = try repo.confirm(scope: .module, sessionId: "s1")
        }
    }

    @Test func confirmRollsBackEverythingWhenAMidTransactionWriteFails() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // 注入：confirm 的第三步（items → synced）中途失败；前两步必须一起回滚。
        _ = try db.exec("""
            CREATE TEMP TRIGGER delivery_items_sync_fail
            BEFORE UPDATE OF status ON delivery_items
            WHEN NEW.status = 'synced'
            BEGIN
              SELECT RAISE(ABORT, 'injected sync failure');
            END;
            """)

        var threw = false
        do {
            _ = try repo.confirm(scope: .session, sessionId: "s1")
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(try repo.get(self.xmp)?.status == "written", "deliveries 更新必须回滚")
        #expect(try repo.listItems(sessionId: "s1").first?.typedStatus == .written, "items 更新必须回滚")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "", "confirmed_at 必须回滚")

        // 去掉注入后同一事务可正常提交（A/B 证明失败来自触发器而非逻辑）。
        _ = try db.exec("DROP TRIGGER delivery_items_sync_fail")
        let summary = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(summary.deliveriesSynced == 1)
        #expect(summary.itemsSynced == 1)
        #expect(try repo.get(self.xmp)?.status == "synced")
    }

    @Test func confirmRollsBackOnInjectedForeignKeyFailure() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // 注入：deliveries 翻 synced 后往 delivery_sessions 插一条未知 session（FK 立即失败）。
        _ = try db.exec("""
            CREATE TEMP TRIGGER confirm_fk_fail
            AFTER UPDATE OF status ON deliveries
            WHEN NEW.status = 'synced'
            BEGIN
              INSERT INTO delivery_sessions (delivery_id, session_id) VALUES (NEW.id, 'ghost');
            END;
            """)

        var threw = false
        do {
            _ = try repo.confirm(scope: .session, sessionId: "s1")
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(try repo.get(self.xmp)?.status == "written", "FK 失败必须回滚 deliveries")
        #expect(try repo.listItems(sessionId: "s1").first?.typedStatus == .written, "FK 失败必须回滚 items")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "", "FK 失败必须回滚 links")
        #expect(try v1Count(db, "SELECT COUNT(*) FROM delivery_sessions") == 1, "触发器插入不得留下幽灵行")

        _ = try db.exec("DROP TRIGGER confirm_fk_fail")
        let summary = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(summary.deliveriesSynced == 1)
        #expect(summary.itemsSynced == 1)
    }

    // MARK: 显式列 / 列序无关

    @Test func rowMapperReadsExplicitColumnsByNameNotPosition() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(
            xmpPath: self.xmp, photoPath: self.photo, revision: 7,
            baseFingerprint: "fp-7", baseValues: .object(["rating": .number(4)]))
        _ = try repo.markWriting(xmpPath: self.xmp, revision: 7, leaseOwner: "w")
        _ = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .faceKeyword,
            attributes: ["person": .string("Alice")],
            keywords: ["alice", "portrait"],
            status: .written)

        // 列序刻意打乱：与 DDL 物理列序、与仓储 SELECT 列序都不同。
        let deliveryColumns = [
            "updated_at", "status", "id", "revision", "xmp_path", "photo_path",
            "base_fingerprint", "base_values_json", "backup_path", "error_message",
            "attempt_count", "lease_owner", "heartbeat_at", "created_at",
        ]
        let deliveryRow = try #require(try db.prepare(
            "SELECT " + deliveryColumns.joined(separator: ", ") + " FROM deliveries WHERE xmp_path = ?"
        ).get([.text(self.xmp)]))
        let mappedDelivery = try DeliveryRow(columns: deliveryColumns, row: deliveryRow)
        #expect(mappedDelivery.xmpPath == self.xmp)
        #expect(mappedDelivery.photoPath == self.photo)
        #expect(mappedDelivery.status == "writing")
        #expect(mappedDelivery.revision == 7)
        #expect(mappedDelivery.baseFingerprint == "fp-7")
        #expect(mappedDelivery.baseValues == .object(["rating": .number(4)]))
        #expect(mappedDelivery.leaseOwner == "w")
        #expect(mappedDelivery.attemptCount == 1)
        #expect(mappedDelivery.createdAt != "")
        #expect(mappedDelivery.updatedAt != "")

        let itemColumns = [
            "updated_at", "status", "keywords", "attributes_json", "module", "photo_id",
            "delivery_id", "id", "error_message", "attempt_count", "created_at", "xmp_path",
        ]
        let itemSQLColumns = itemColumns.map { $0 == "xmp_path" ? "d.xmp_path" : "di." + $0 }
        let itemRow = try #require(try db.prepare("""
            SELECT \(itemSQLColumns.joined(separator: ", "))
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.photo_id = ?
            """).get([.text("p1")]))
        let mappedItem = try DeliveryItemRow(columns: itemColumns, row: itemRow)
        #expect(mappedItem.photoId == "p1")
        #expect(mappedItem.typedModule == .faceKeyword)
        #expect(mappedItem.typedStatus == .written)
        #expect(mappedItem.attributes["person"] == .string("Alice"))
        #expect(mappedItem.keywordList == ["alice", "portrait"])
        #expect(mappedItem.xmpPath == self.xmp)

        // 缺必需列必须显式失败（禁止静默取默认值）。
        let pairs = Dictionary(uniqueKeysWithValues: zip(deliveryColumns, deliveryRow))
        let missingNames = deliveryColumns.filter { $0 != "status" }
        let missingRow = missingNames.compactMap { pairs[$0] }
        #expect(throws: DeliveryRepoError.missingColumn("status")) {
            _ = try DeliveryRow(columns: missingNames, row: missingRow)
        }
    }

    // MARK: mergeInput（S3 新输入 / revision CAS）

    @Test func mergeInputAdvancesRevisionPhotoPathAndBaselineWithoutTouchingItems() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(
            xmpPath: self.xmp,
            photoPath: self.photo,
            revision: 3,
            baseFingerprint: "fp-3",
            baseValues: .object(["rating": .number(2)]))
        _ = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling,
            attributes: ["rating": .number(2)], keywords: ["keep"])

        // 路径带 ./：与 create/get 同一归一化口径。
        let merged = try #require(try repo.mergeInput(
            xmpPath: "/v/./IMG_1.xmp",
            photoPath: "/v/IMG_1-renamed.jpg",
            expectedRevision: 3,
            newRevision: 4,
            baseFingerprint: "fp-4",
            baseValues: .object(["rating": .number(4)])))
        #expect(merged.revision == 4)
        #expect(merged.photoPath == "/v/IMG_1-renamed.jpg")
        #expect(merged.baseFingerprint == "fp-4")
        #expect(merged.baseValues == .object(["rating": .number(4)]))
        #expect(merged.updatedAt != "")
        #expect(merged.status == "pending", "D-031：mergeInput 必须把行重新打开为 pending")

        // 不改 items（attributes/keywords 原样保留）。
        let items = try repo.listItems(sessionId: "s1")
        #expect(items.count == 1)
        #expect(items[0].attributes["rating"] == .number(2))
        #expect(items[0].keywordList == ["keep"])

        // expectedRevision 过期：CAS 失配返回 nil，行保持 merge 后的值。
        #expect(try repo.mergeInput(
            xmpPath: self.xmp,
            photoPath: "/v/stale.jpg",
            expectedRevision: 3,
            newRevision: 5,
            baseFingerprint: "stale",
            baseValues: .object([:])) == nil)
        let after = try #require(try repo.get(self.xmp))
        #expect(after.revision == 4)
        #expect(after.photoPath == "/v/IMG_1-renamed.jpg")
        #expect(after.baseFingerprint == "fp-4")
        #expect(after.baseValues == .object(["rating": .number(4)]))
        #expect(after.status == "pending", "CAS 失败不得改状态")
    }

    @Test func mergeInputReopensWrittenAndSyncedAsPending() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // D-031：written 行收到新输入 → pending（不能停留在 written，否则 confirm 会误判）。
        _ = try repo.createOrGet(
            xmpPath: self.xmp, photoPath: self.photo, revision: 1, baseFingerprint: "old")
        try driveToWritten(repo, xmpPath: self.xmp, revision: 1)
        #expect(try repo.get(self.xmp)?.status == "written")

        let fromWritten = try #require(try repo.mergeInput(
            xmpPath: self.xmp,
            photoPath: "/v/IMG_1-written.jpg",
            expectedRevision: 1,
            newRevision: 2,
            baseFingerprint: "written-new",
            baseValues: .object(["rating": .number(3)])))
        #expect(fromWritten.status == "pending")
        #expect(fromWritten.revision == 2)
        #expect(fromWritten.photoPath == "/v/IMG_1-written.jpg")
        #expect(fromWritten.baseFingerprint == "written-new")

        // D-031：synced 行收到新输入 → pending（新输入可以重新打开已确认行）。
        _ = try repo.markWriting(xmpPath: self.xmp, revision: 2)
        _ = try repo.markWritten(
            xmpPath: self.xmp, revision: 2,
            baseFingerprint: "synced-base", baseValues: .object([:]), backupPath: "")
        #expect(try repo.markSynced(xmpPath: self.xmp, revision: 2)?.status == "synced")

        let fromSynced = try #require(try repo.mergeInput(
            xmpPath: self.xmp,
            photoPath: "/v/IMG_1-synced.jpg",
            expectedRevision: 2,
            newRevision: 3,
            baseFingerprint: "synced-new",
            baseValues: .object(["rating": .number(1)])))
        #expect(fromSynced.status == "pending")
        #expect(fromSynced.revision == 3)
        #expect(fromSynced.photoPath == "/v/IMG_1-synced.jpg")
        #expect(fromSynced.baseFingerprint == "synced-new")

        // 迁移表：D-031 列出的四个来源态都可回到 pending（cleaned 除外）。
        #expect(DeliveryStatus.written.canTransition(to: .pending))
        #expect(DeliveryStatus.synced.canTransition(to: .pending))
        #expect(DeliveryStatus.failed.canTransition(to: .pending))
        #expect(DeliveryStatus.conflict.canTransition(to: .pending))
        #expect(!DeliveryStatus.cleaned.canTransition(to: .pending))
    }

    @Test func mergeInputClearsConfirmationOfEveryLinkedSession() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s2")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // 前置：两个会话都确认，delivery 翻 synced，两行 confirmed_at 均非空。
        #expect(try repo.confirm(scope: .session, sessionId: "s1").deliveriesSynced == 0)
        let both = try repo.confirm(scope: .session, sessionId: "s2")
        #expect(both.deliveriesSynced == 1)
        #expect(try repo.get(self.xmp)?.typedStatus == .synced)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") != "")

        // s1 的新输入推进 revision 并回 pending：**所有**关联会话的确认一起失效。
        let merged = try #require(try repo.mergeInput(
            xmpPath: self.xmp,
            photoPath: self.photo,
            expectedRevision: 0,
            newRevision: 1,
            baseFingerprint: "fp-new",
            baseValues: .object(["rating": .number(5)])))
        #expect(merged.typedStatus == .pending)
        #expect(merged.revision == 1)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "",
                "当前会话必须重新确认")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "",
                "P1-1：其他会话的旧确认必须一起清空")

        // 新 revision 写回后只有 s1 确认：s2 的旧确认不得被复用，delivery 停在 written。
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .pending)
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 1)
        let s1Only = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(s1Only.confirmedLinks == 1)
        #expect(s1Only.deliveriesSynced == 0, "s2 未看到新内容：不得翻 synced")
        #expect(s1Only.itemsSynced == 0)
        #expect(s1Only.unconfirmedSessionIds == ["s2"])
        #expect(try repo.get(self.xmp)?.status == "written")
        #expect(try repo.listItems(sessionId: "s1").first?.typedStatus == .written)

        // s2 重新确认后才允许翻 synced（门禁没有被放宽）。
        let s2Again = try repo.confirm(scope: .session, sessionId: "s2")
        #expect(s2Again.deliveriesSynced == 1)
        #expect(s2Again.itemsSynced == 1)
        #expect(try repo.get(self.xmp)?.status == "synced")
    }

    @Test func repeatedMergeInputIsIdempotentAndStaleCASKeepsConfirmations() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s2")
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)
        _ = try repo.confirm(scope: .session, sessionId: "s1")
        _ = try repo.confirm(scope: .session, sessionId: "s2")
        #expect(try repo.get(self.xmp)?.typedStatus == .synced)

        // 第一次 merge：0 → 1，确认全清。
        _ = try repo.mergeInput(
            xmpPath: self.xmp, photoPath: self.photo,
            expectedRevision: 0, newRevision: 1,
            baseFingerprint: "fp-1", baseValues: .object([:]))
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .pending)
        _ = try repo.upsertItem(xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 1)

        // s1 对新 revision 确认；s2 仍未确认。
        let s1Confirmed = try repo.confirm(scope: .session, sessionId: "s1")
        #expect(s1Confirmed.deliveriesSynced == 0)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "")

        // revision 过期的重复 merge：CAS 失配返回 nil，且不得顺手清掉 s1 的新确认。
        #expect(try repo.mergeInput(
            xmpPath: self.xmp, photoPath: self.photo,
            expectedRevision: 0, newRevision: 2,
            baseFingerprint: "stale", baseValues: .object([:])) == nil)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "",
                "CAS 失配的 merge 不得清确认")
        let afterStale = try #require(try repo.get(self.xmp))
        #expect(afterStale.revision == 1)
        #expect(afterStale.status == "written")

        // 成功的重复 merge（1 → 2）：再次把 s1/s2 的确认全清，revision 正常推进。
        let repeated = try #require(try repo.mergeInput(
            xmpPath: self.xmp, photoPath: self.photo,
            expectedRevision: 1, newRevision: 2,
            baseFingerprint: "fp-2", baseValues: .object([:])))
        #expect(repeated.status == "pending")
        #expect(repeated.revision == 2)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "")

        // 同一请求再放一次：CAS 失配 nil，行/确认保持重复 merge 后的状态。
        #expect(try repo.mergeInput(
            xmpPath: self.xmp, photoPath: self.photo,
            expectedRevision: 1, newRevision: 2,
            baseFingerprint: "fp-2", baseValues: .object([:])) == nil)
        let replay = try #require(try repo.get(self.xmp))
        #expect(replay.revision == 2)
        #expect(replay.status == "pending")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "")
    }

    @Test func resetConfirmationsClearsEveryLinkedSessionForTargetDeliveryOnly() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s1")
        _ = try repo.linkSession(xmpPath: self.xmp, sessionId: "s2")
        _ = try repo.upsertItem(
            xmpPath: self.xmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: self.xmp, revision: 0)

        // s1 已确认旧内容，s2 尚未确认：交付停在 written。
        #expect(try repo.confirm(scope: .session, sessionId: "s1").confirmedLinks == 1)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") != "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "")
        #expect(try repo.get(self.xmp)?.typedStatus == .written)

        // P1-10 残余：外部内容成为新基线后，所有会话的旧确认一起失效。
        #expect(try repo.resetConfirmations(xmpPath: self.xmp) == 1)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "")
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s2") == "")
        #expect(try repo.get(self.xmp)?.typedStatus == .written, "reset 只清确认，不改交付状态")

        // 重复调用幂等：没有可清的行时返回 0。
        #expect(try repo.resetConfirmations(xmpPath: self.xmp) == 0)

        // 另一条交付的确认不受影响（WHERE delivery_id 限定）。
        let otherXmp = "/v/IMG_2.xmp"
        _ = try repo.createOrGet(xmpPath: otherXmp, photoPath: "/v/IMG_2.jpg")
        _ = try repo.linkSession(xmpPath: otherXmp, sessionId: "s1")
        _ = try repo.upsertItem(
            xmpPath: otherXmp, photoId: "p1", module: .culling, status: .written)
        try driveToWritten(repo, xmpPath: otherXmp, revision: 0)
        // s1 同时确认两条交付；随后只重置目标交付。
        #expect(try repo.confirm(scope: .session, sessionId: "s1").confirmedLinks == 2)
        #expect(try v1ConfirmedAt(db, xmpPath: otherXmp, sessionId: "s1") != "")
        #expect(try repo.resetConfirmations(xmpPath: self.xmp) == 1)
        #expect(try v1ConfirmedAt(db, xmpPath: self.xmp, sessionId: "s1") == "")
        #expect(try v1ConfirmedAt(db, xmpPath: otherXmp, sessionId: "s1") != "",
                "reset 不得清其它交付的确认")
    }

    @Test func resetConfirmationsWithoutLinkedSessionsIsIdempotent() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)
        #expect(try repo.resetConfirmations(xmpPath: self.xmp) == 0)
        #expect(try repo.resetConfirmations(xmpPath: self.xmp) == 0)
        #expect(try repo.get(self.xmp)?.typedStatus == .pending)
        #expect(throws: DeliveryRepoError.rowNotFound(xmpPath: "/v/MISSING.xmp")) {
            _ = try repo.resetConfirmations(xmpPath: "/v/MISSING.xmp")
        }
    }

    @Test func mergeInputRejectsCleanedDeliveryAndLeavesItUntouched() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let cleanedXmp = "/v/C.xmp"
        _ = try repo.createOrGet(xmpPath: cleanedXmp, photoPath: "/v/C.jpg", revision: 2)
        _ = try db.prepare("UPDATE deliveries SET status = 'cleaned' WHERE xmp_path = ?")
            .run([.text(cleanedXmp)])
        #expect(!DeliveryStatus.cleaned.canTransition(to: .pending))

        #expect(try repo.mergeInput(
            xmpPath: cleanedXmp,
            photoPath: "/v/C-renamed.jpg",
            expectedRevision: 2,
            newRevision: 3,
            baseFingerprint: "new",
            baseValues: .object([:])) == nil)
        let cleanedRow = try #require(try repo.get(cleanedXmp))
        #expect(cleanedRow.status == "cleaned")
        #expect(cleanedRow.revision == 2)
        #expect(cleanedRow.photoPath == "/v/C.jpg")
        #expect(cleanedRow.baseFingerprint == "")
    }

    @Test func mergeInputRejectsMissingRowAndBackwardRevision() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // 行不存在：显式 rowNotFound（不是 CAS nil）。
        #expect(throws: DeliveryRepoError.rowNotFound(xmpPath: "/v/missing.xmp")) {
            _ = try repo.mergeInput(
                xmpPath: "/v/missing.xmp",
                photoPath: "/v/missing.jpg",
                expectedRevision: 0,
                newRevision: 1,
                baseFingerprint: "",
                baseValues: .object([:]))
        }

        // revision 只能推进，不能借 mergeInput 回退。
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo, revision: 5)
        #expect(throws: DeliveryRepoError.invalidArgument(
            "newRevision 不能小于 expectedRevision: 4 < 5")) {
            _ = try repo.mergeInput(
                xmpPath: self.xmp,
                photoPath: "/v/backward.jpg",
                expectedRevision: 5,
                newRevision: 4,
                baseFingerprint: "",
                baseValues: .object([:]))
        }
        #expect(try repo.get(self.xmp)?.revision == 5)
        #expect(try repo.get(self.xmp)?.photoPath == self.photo)
    }

    // MARK: - 手动队列 / 冲突 / 孤儿 helpers（S5c-2b-3b-2b-2）

    @Test func mergeItemKeepsUnmentionedFieldsAndKeywords() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")
        _ = try repo.createOrGet(xmpPath: self.xmp, photoPath: self.photo)

        _ = try repo.mergeItem(
            xmpPath: self.xmp, photoId: "p1", module: .metadata,
            attributes: ["rating": .number(4)], keywords: ["a"])
        let merged = try repo.mergeItem(
            xmpPath: self.xmp, photoId: "p1", module: .metadata,
            attributes: ["label": .string("Green")])

        // 后者覆盖同名字段；未提及字段与 keywords（nil）保留。
        #expect(merged.attributes["rating"] == .number(4))
        #expect(merged.attributes["label"] == .string("Green"))
        #expect(merged.keywordList == ["a"])
        #expect(merged.typedStatus == .pending)
        #expect(try repo.item(xmpPath: self.xmp, photoId: "p1", module: .metadata)?.id == merged.id)
        #expect(try repo.items(deliveryId: merged.deliveryId).count == 1)
    }

    @Test func conflictAndOrphanQueriesFollowSessionLinks() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }
        try v1InsertPhoto(db, id: "p1", sessionId: "s1")

        let linked = "/v/Linked.xmp"
        _ = try repo.createOrGet(xmpPath: linked, photoPath: "/v/Linked.jpg")
        _ = try repo.markWriting(xmpPath: linked, revision: 0)
        _ = try repo.markFailedForTesting(xmpPath: linked, revision: 0, errorMessage: "boom")
        _ = try repo.markConflictForTesting(xmpPath: linked, revision: 0, errorMessage: "XMP_EXTERNAL_EDIT_CONFLICT")
        _ = try repo.linkSession(xmpPath: linked, sessionId: "s1")

        let orphanXmp = "/v/Orphan.xmp"
        _ = try repo.createOrGet(xmpPath: orphanXmp, photoPath: "/v/Orphan.jpg")
        _ = try repo.upsertItem(
            xmpPath: orphanXmp, photoId: "p1", module: .metadata, keywords: ["o"])

        // conflict 只按会话链接可见；孤儿是「没有任何链接」的交付。
        #expect(try repo.conflictDeliveries(sessionId: "s1").map(\.xmpPath) == [linked])
        #expect(try repo.conflictDeliveries(sessionId: "s2").isEmpty)
        #expect(try repo.orphanDeliveries().map(\.xmpPath) == [orphanXmp])

        // 已链接交付不得按孤儿删除（revision 与链接双守卫）。
        #expect((try repo.deleteOrphanDelivery(xmpPath: linked, revision: 0)) == false)
        #expect(try repo.get(linked) != nil)
        // 孤儿删除成功并清掉子行。
        #expect((try repo.deleteOrphanDelivery(xmpPath: orphanXmp, revision: 0)) == true)
        #expect(try repo.get(orphanXmp) == nil)
        #expect(try repo.orphanDeliveries().isEmpty)
        #expect(try repo.metadataSummary(sessionId: "s1").conflict == 1)
    }
}

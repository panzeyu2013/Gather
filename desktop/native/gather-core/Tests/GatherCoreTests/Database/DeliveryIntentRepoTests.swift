// desktop/native/gather-core/Tests/GatherCoreTests/Database/DeliveryIntentRepoTests.swift
// Cut 2 / S3：delivery_intents 持久化层的行为门禁。
//
// 建库口径与 DeliveryRepoTests 一致：DBConnection(path: ":memory:") + exec(SchemaCurrent.createSQL)，
// 不走迁移链（V1 新建库）。
//
// 覆盖面：
// 1. prepare：显式列 + 参数绑定、路径归一化、payload 往返、自增 id；
// 2. advance：prepared → fileDone → applied 合法链；跳相位/回退/自迁移显式抛错；
// 3. finish：成功删除；error 标记 applied + error_message；行不存在显式失败；
// 4. pending：prepared/fileDone 分开、按 id 升序、排除 applied、只读；
// 5. replayAll：返回 prepared/fileDone/applied（applied 由调用方补删备份后清行）、重复调用幂等；
// 6. 行映射按列名而非物理列序；CHECK 取值集合与 Swift enum 双向一致。

import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence

// MARK: - fixtures

private func makeIntentDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try db.exec(SchemaCurrent.createSQL)
    return db
}

private func intentCount(_ db: DBConnection, _ phase: String? = nil) throws -> Int {
    let sql: String
    let values: [DBValue?]
    if let phase {
        sql = "SELECT COUNT(*) FROM delivery_intents WHERE phase = ?"
        values = [.text(phase)]
    } else {
        sql = "SELECT COUNT(*) FROM delivery_intents"
        values = []
    }
    guard let row = try db.prepare(sql).get(values) else { return 0 }
    return Int(row[0].intValue ?? 0)
}

private func intentTableSQL(_ db: DBConnection) throws -> String? {
    try db.prepare("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")
        .get([.text("delivery_intents")])?[0].textValue
}

/// 从 CREATE TABLE 文本里取出 CHECK (column IN ('a','b',...)) 的取值集合。
private func intentCheckValues(_ sql: String, column: String) throws -> Set<String> {
    let marker = column + " IN ("
    guard let range = sql.range(of: marker) else {
        throw DeliveryIntentRepoError.missingColumn("CHECK " + marker)
    }
    let rest = sql[range.upperBound...]
    guard let end = rest.firstIndex(of: ")") else {
        throw DeliveryIntentRepoError.invalidArgument("CHECK 未闭合: " + marker)
    }
    return Set(rest[..<end].split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    })
}

// MARK: - 测试

struct DeliveryIntentRepoTests {
    private let xmp = "/v/IMG_1.xmp"
    private let otherXmp = "/v/IMG_2.xmp"

    private func makeRepo() throws -> (DBConnection, DeliveryIntentRepo) {
        let db = try makeIntentDB()
        return (db, DeliveryIntentRepo(connection: db))
    }

    // MARK: prepare / get

    @Test func preparePersistsPreparedIntentWithPayloadAndNormalizesPath() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let id = try repo.prepare(
            kind: .cleanup,
            xmpPath: "/v/./IMG_1.xmp",
            payload: .object([
                "backup_path": .string("/v/IMG_1.xmp.gather-backup-test"),
                "delivery_id": .number(7),
                "revision": .number(3),
            ])
        )
        #expect(id > 0)

        let row = try #require(try repo.get(id))
        #expect(row.id == id)
        #expect(row.kind == "cleanup")
        #expect(row.typedKind == .cleanup)
        #expect(row.xmpPath == self.xmp, "prepare 必须归一化 xmpPath（折叠 ./）")
        #expect(row.phase == "prepared")
        #expect(row.typedPhase == .prepared)
        #expect(row.payload["backup_path"] == .string("/v/IMG_1.xmp.gather-backup-test"))
        #expect(row.payload["revision"] == .number(3))
        #expect(row.errorMessage == "")
        #expect(row.createdAt != "")
        #expect(row.updatedAt != "")
        #expect(try intentCount(db) == 1)

        // write intent 与 cleanup 共用表，payload 缺省为空对象。
        let writeId = try repo.prepare(kind: .write, xmpPath: self.otherXmp)
        #expect(writeId > id)
        let writeRow = try #require(try repo.get(writeId))
        #expect(writeRow.typedKind == .write)
        #expect(writeRow.payload == .object([:]))
    }

    @Test func prepareRejectsEmptyPathWithoutWriting() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(throws: DeliveryIntentRepoError.invalidArgument("xmpPath 不能为空")) {
            _ = try repo.prepare(kind: .cleanup, xmpPath: "   ")
        }
        #expect(try intentCount(db) == 0)
    }

    @Test func rowMapperReadsExplicitColumnsByNameNotPosition() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let id = try repo.prepare(
            kind: .cleanup, xmpPath: self.xmp,
            payload: .object(["backup_path": .string("/b.xmp")]))

        // 列序刻意打乱：与 DDL 物理列序、与仓储 SELECT 列序都不同。
        let columns = [
            "updated_at", "payload_json", "id", "phase",
            "xmp_path", "kind", "error_message", "created_at",
        ]
        let raw = try #require(try db.prepare(
            "SELECT " + columns.joined(separator: ", ") + " FROM delivery_intents WHERE id = ?"
        ).get([.int(id)]))
        let mapped = try DeliveryIntentRow(columns: columns, row: raw)
        #expect(mapped.id == id)
        #expect(mapped.typedKind == .cleanup)
        #expect(mapped.typedPhase == .prepared)
        #expect(mapped.xmpPath == self.xmp)
        #expect(mapped.payload["backup_path"] == .string("/b.xmp"))

        // 缺必需列必须显式失败（禁止静默取默认值）。
        let pairs = Dictionary(uniqueKeysWithValues: zip(columns, raw))
        let missingNames = columns.filter { $0 != "phase" }
        let missingRow = missingNames.compactMap { pairs[$0] }
        #expect(throws: DeliveryIntentRepoError.missingColumn("phase")) {
            _ = try DeliveryIntentRow(columns: missingNames, row: missingRow)
        }
    }

    // MARK: advance

    @Test func advanceWalksPreparedToFileDoneToApplied() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let id = try repo.prepare(kind: .cleanup, xmpPath: self.xmp)

        let fileDone = try repo.advance(id: id, to: .fileDone)
        #expect(fileDone.id == id)
        #expect(fileDone.typedPhase == .fileDone)
        #expect(try repo.get(id)?.typedPhase == .fileDone)

        let applied = try repo.advance(id: id, to: .applied)
        #expect(applied.typedPhase == .applied)
        #expect(applied.errorMessage == "")
        #expect(try repo.get(id)?.typedPhase == .applied)
    }

    @Test func advanceRejectsSkippedBackwardAndRepeatedPhases() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let id = try repo.prepare(kind: .cleanup, xmpPath: self.xmp)

        // prepared → applied 跳相位。
        #expect(throws: DeliveryIntentRepoError.illegalTransition(
            id: id, xmpPath: self.xmp, from: "prepared", to: "applied")) {
            _ = try repo.advance(id: id, to: .applied)
        }
        // 自迁移不是推进，显式拒绝。
        #expect(throws: DeliveryIntentRepoError.illegalTransition(
            id: id, xmpPath: self.xmp, from: "prepared", to: "prepared")) {
            _ = try repo.advance(id: id, to: .prepared)
        }
        #expect(try repo.get(id)?.typedPhase == .prepared, "非法迁移不得改行")

        _ = try repo.advance(id: id, to: .fileDone)
        // fileDone → prepared 回退。
        #expect(throws: DeliveryIntentRepoError.illegalTransition(
            id: id, xmpPath: self.xmp, from: "fileDone", to: "prepared")) {
            _ = try repo.advance(id: id, to: .prepared)
        }
        #expect(try repo.get(id)?.typedPhase == .fileDone)

        _ = try repo.advance(id: id, to: .applied)
        // applied 是终态。
        #expect(throws: DeliveryIntentRepoError.illegalTransition(
            id: id, xmpPath: self.xmp, from: "applied", to: "fileDone")) {
            _ = try repo.advance(id: id, to: .fileDone)
        }
        #expect(try repo.get(id)?.typedPhase == .applied)

        // 不存在的行：rowNotFound（不是 CAS nil，也不是静默 no-op）。
        #expect(throws: DeliveryIntentRepoError.rowNotFound(id: 999)) {
            _ = try repo.advance(id: 999, to: .fileDone)
        }
    }

    // MARK: finish

    @Test func finishDeletesOnSuccessAndMarksAppliedOnError() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        // 成功闭环：删除 intent。
        let successId = try repo.prepare(kind: .cleanup, xmpPath: self.xmp)
        try repo.finish(id: successId)
        #expect(try repo.get(successId) == nil)
        #expect(try intentCount(db) == 0)

        // 已删除的 id 再 finish：显式失败。
        #expect(throws: DeliveryIntentRepoError.rowNotFound(id: successId)) {
            try repo.finish(id: successId)
        }

        // 带 error：保留行、标记 applied、记录 error_message（终态，不再被 pending 返回）。
        let failedId = try repo.prepare(kind: .cleanup, xmpPath: self.otherXmp)
        try repo.finish(id: failedId, error: "restore failed")
        let failed = try #require(try repo.get(failedId))
        #expect(failed.typedPhase == .applied)
        #expect(failed.errorMessage == "restore failed")
        #expect(try repo.pending().isEmpty)
        #expect(try intentCount(db, "applied") == 1)
    }

    // MARK: pending / replayAll

    @Test func pendingSeparatesPhasesOrderedByIdAndExcludesApplied() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let preparedA = try repo.prepare(kind: .cleanup, xmpPath: "/v/A.xmp")
        let fileDoneB = try repo.prepare(kind: .cleanup, xmpPath: "/v/B.xmp")
        let appliedC = try repo.prepare(kind: .cleanup, xmpPath: "/v/C.xmp")
        let preparedD = try repo.prepare(kind: .write, xmpPath: "/v/D.xmp")

        _ = try repo.advance(id: fileDoneB, to: .fileDone)
        _ = try repo.advance(id: appliedC, to: .fileDone)
        _ = try repo.advance(id: appliedC, to: .applied)

        let backlog = try repo.pending()
        #expect(backlog.prepared.map(\.id) == [preparedA, preparedD])
        #expect(backlog.fileDone.map(\.id) == [fileDoneB])
        #expect(backlog.count == 3)
        #expect(!backlog.isEmpty)
        #expect(backlog.all.map(\.id) == [preparedA, preparedD, fileDoneB])
        #expect(backlog.prepared.first?.typedKind == .cleanup)
        #expect(backlog.prepared.last?.typedKind == .write)

        // pending 只读：不清理 applied、不改相位。
        #expect(try intentCount(db) == 4)
        #expect(try intentCount(db, "applied") == 1)
        #expect(try repo.get(appliedC)?.typedPhase == .applied)
    }

    @Test func replayAllReturnsAppliedWithoutPurgingUntilCallerFinishes() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let preparedId = try repo.prepare(kind: .cleanup, xmpPath: "/v/A.xmp")
        let fileDoneId = try repo.prepare(kind: .cleanup, xmpPath: "/v/B.xmp")
        let appliedId = try repo.prepare(kind: .cleanup, xmpPath: "/v/C.xmp")
        _ = try repo.advance(id: fileDoneId, to: .fileDone)
        _ = try repo.advance(id: appliedId, to: .fileDone)
        _ = try repo.advance(id: appliedId, to: .applied)

        let backlog = try repo.replayAll()
        #expect(backlog.prepared.map(\.id) == [preparedId])
        #expect(backlog.fileDone.map(\.id) == [fileDoneId])
        // A3：applied 行不再由 replayAll 删除——调用方要先补删备份再 finish(nil)。
        #expect(backlog.applied.map(\.id) == [appliedId])
        #expect(backlog.count == 3)
        #expect(try repo.get(appliedId)?.typedPhase == .applied)

        // 第二次 replayAll：同一 applied 行仍返回，直到调用方显式收尾。
        let second = try repo.replayAll()
        #expect(second == backlog)
        #expect(try intentCount(db) == 3)

        try repo.finish(id: appliedId, error: nil)
        #expect(try repo.get(appliedId) == nil)
    }

    // MARK: 状态边界（D-031）

    /// intent 只做 DB 记账，不得改写 deliveries.status；delivery 的重新打开只属于
    /// DeliveryRepo.mergeInput（D-031）。这里用 synced → prepared intent 钉住该边界。
    @Test func prepareIntentDoesNotReopenSyncedDelivery() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        let deliveryRepo = DeliveryRepo(connection: db)
        _ = try deliveryRepo.createOrGet(
            xmpPath: self.xmp, photoPath: "/v/IMG_1.jpg", revision: 1)
        _ = try deliveryRepo.markWriting(xmpPath: self.xmp, revision: 1)
        _ = try deliveryRepo.markWritten(
            xmpPath: self.xmp, revision: 1,
            baseFingerprint: "fp", baseValues: .object([:]), backupPath: "")
        #expect(try deliveryRepo.markSynced(xmpPath: self.xmp, revision: 1)?.status == "synced")

        let id = try repo.prepare(kind: .cleanup, xmpPath: self.xmp)
        #expect(try repo.get(id)?.typedPhase == .prepared)
        #expect(try deliveryRepo.get(self.xmp)?.status == "synced",
                "intent 记账不是新输入：不得把 synced 偷偷改回 pending")
        #expect(try deliveryRepo.get(self.xmp)?.revision == 1)
    }

    // MARK: schema 对齐

    @Test func intentEnumsMatchSchemaCheckConstraints() throws {
        let db = try makeIntentDB()
        defer { db.close() }

        let sql = try #require(try intentTableSQL(db))
        #expect(try intentCheckValues(sql, column: "kind")
            == Set(DeliveryIntentKind.allCases.map(\.rawValue)))
        #expect(try intentCheckValues(sql, column: "phase")
            == Set(DeliveryIntentPhase.allCases.map(\.rawValue)))
        #expect(DeliveryIntentPhase.applied.isTerminal)
        #expect(!DeliveryIntentPhase.fileDone.isTerminal)
    }
}

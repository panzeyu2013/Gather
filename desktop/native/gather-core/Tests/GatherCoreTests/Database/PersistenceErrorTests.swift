// desktop/native/gather-core/Tests/GatherCoreTests/Database/PersistenceErrorTests.swift
// P1-2 / R1：Persistence 域错误码类型化的回归锚点。
//
// 覆盖：① 真实 SQLite 下 Repo 抛 PersistenceError 且 code 正确；
// ② CodedError 统一取码；③ detail 只影响 description、不影响相等性。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

@Suite("PersistenceError：域错误码类型化")
struct PersistenceErrorTests {
    @Test("relinkRoot 同根 → PersistenceError(.ASSET_RELINK_SAME_ROOT)")
    func relinkSameRootCarriesCode() throws {
        let db = try makeTestDB()
        defer { db.close() }
        let repo = AssetRepo(connection: db)
        #expect(throws: PersistenceError(code: .ASSET_RELINK_SAME_ROOT)) {
            _ = try repo.relinkRoot(oldRoot: "/tmp/gather-same-root", newRoot: "/tmp/gather-same-root")
        }
    }

    @Test("空历史栈 undo → PersistenceError(.CULLING_UNDO_NOT_LATEST)")
    func historyUndoCarriesCode() throws {
        let db = try makeTestDB()
        defer { db.close() }
        let repo = CullingHistoryRepo(connection: db)
        #expect(throws: PersistenceError(code: .CULLING_UNDO_NOT_LATEST)) {
            try repo.setUndone(sessionId: "s1", operationId: 1, undone: true)
        }
    }

    @Test("CodedError 统一取码；detail 只进 description")
    func codedErrorContract() {
        let error: any CodedError = PersistenceError(
            code: .CULLING_HISTORY_CORRUPT, detail: "row 3"
        )
        #expect(error.code == .CULLING_HISTORY_CORRUPT)
        #expect((error as? PersistenceError)?.description == "CULLING_HISTORY_CORRUPT: row 3")
        #expect(
            PersistenceError(code: .CULLING_HISTORY_STALE)
                == PersistenceError(code: .CULLING_HISTORY_STALE, detail: "ignored for equality")
        )
    }
}

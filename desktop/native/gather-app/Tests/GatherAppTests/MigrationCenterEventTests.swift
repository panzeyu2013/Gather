// desktop/native/gather-app/Tests/GatherAppTests/MigrationCenterEventTests.swift
// P2（task-31 review）：导入新建工作区后，library 域事件必须指向新 session，
// 否则按 session 过滤的页面不会刷新新库。
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("迁移卡片事件（P2）")
struct MigrationCenterEventTests {
    @Test func importEventTargetsImportedSession() {
        let report = LibraryImportReport(
            sessionId: "imported-session", importedPhotos: 1)
        #expect(MigrationCenterCard.importEventSessionId(report) == "imported-session")
    }
}

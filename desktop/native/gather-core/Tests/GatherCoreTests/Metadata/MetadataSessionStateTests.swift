// desktop/native/gather-core/Tests/GatherCoreTests/Metadata/MetadataSessionStateTests.swift
// aggregateSessionState（Services/CaptureOneSessionState.swift → Metadata/MetadataSessionState.swift）
// 直测：2.3.2 优先级与未知状态保守语义。原文件零专用单测，用例按 TS sync-state.ts 补齐。

import Foundation
import Testing
@testable import GatherCore

struct MetadataSessionStateTests {

    @Test func aggregateEmptyCountsIsSynced() {
        #expect(aggregateSessionState(counts: [:], reloadAckedAt: nil) == .synced)
        #expect(aggregateSessionState(counts: [:], reloadAckedAt: "t") == .synced)
    }

    @Test func aggregateConflictBeatsEveryOtherState() {
        let counts = ["conflict": 1, "failed": 2, "pending": 3, "writing": 1, "written": 1]
        #expect(aggregateSessionState(counts: counts, reloadAckedAt: nil) == .conflict)
    }

    @Test func aggregateFailedBeatsPendingAndWritten() {
        #expect(aggregateSessionState(counts: ["failed": 1, "pending": 5], reloadAckedAt: nil) == .failed)
        #expect(aggregateSessionState(counts: ["failed": 1, "written": 5], reloadAckedAt: "t") == .failed)
    }

    @Test func aggregatePendingOrWritingIsSyncing() {
        #expect(aggregateSessionState(counts: ["pending": 1], reloadAckedAt: nil) == .syncing)
        #expect(aggregateSessionState(counts: ["writing": 1], reloadAckedAt: nil) == .syncing)
        #expect(aggregateSessionState(counts: ["pending": 1, "written": 1], reloadAckedAt: "t") == .syncing)
    }

    @Test func aggregateWrittenIsC1ReadEvenWithStaleReloadAck() {
        #expect(aggregateSessionState(counts: ["written": 1], reloadAckedAt: nil) == .c1Read)
        #expect(aggregateSessionState(counts: ["written": 1], reloadAckedAt: "stale") == .c1Read)
    }

    @Test func aggregateUnknownStatusIsConservativelyC1Read() {
        #expect(aggregateSessionState(counts: ["bogus": 1], reloadAckedAt: "t") == .c1Read)
        // 已知终态 + 未知状态：other > 0 优先于 safeToCleanup。
        #expect(aggregateSessionState(counts: ["clean": 1, "bogus": 1], reloadAckedAt: nil) == .c1Read)
    }

    @Test func aggregateAllTerminalRequiresReloadAckForSafeToCleanup() {
        let terminal = ["synced": 2, "clean": 1, "cleaned": 3]
        #expect(aggregateSessionState(counts: terminal, reloadAckedAt: nil) == .c1Read)
        #expect(aggregateSessionState(counts: terminal, reloadAckedAt: "2025-01-01T00:00:00Z") == .safeToCleanup)
    }
}

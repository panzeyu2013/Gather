// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Navigation/NavigationAssemblerTests.swift
// NavigationAssembler 纯函数行为测试（W2d；由 Services/NavigationServiceTests 迁移，断言逐字保留）。

import Testing
@testable import GatherCore

@Suite("Navigation/NavigationAssembler (W2d)")
struct NavigationAssemblerTests {
    // TS: filenameSequence —— 取文件名尾部数字序号。
    @Test func filenameSequenceExtractsTrailingDigits() {
        #expect(NavigationAssembler.filenameSequence("IMG_0001.JPG") == 1)
        #expect(NavigationAssembler.filenameSequence("IMG_0042.jpg") == 42)
        #expect(NavigationAssembler.filenameSequence("IMG_0001_EDIT.JPG") == 1)
        #expect(NavigationAssembler.filenameSequence("IMG.JPG") == nil)
        #expect(NavigationAssembler.filenameSequence("0001.JPG") == 1)
    }

    // TS: hammingDistance —— 同长 hex 逐位差异。
    @Test func hammingDistanceCountsBits() {
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "0000000000000000") == 0)
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "0000000000000001") == 1)
        #expect(NavigationAssembler.hammingDistance("0000000000000000", "ffffffffffffffff") == 64)
        #expect(NavigationAssembler.hammingDistance("0000000000000001", "0000000000000003") == 1)
        // 长度不同 → nil。
        #expect(NavigationAssembler.hammingDistance("0000", "0000000000000000") == nil)
        // 空串 → nil。
        #expect(NavigationAssembler.hammingDistance("", "0000000000000000") == nil)
    }

    /// 债务 D1（旧 closedEyeWarningPenalizedInLead）：闭眼警告候选扣 0.25，lead 改选分数略低但无警告者。
    @Test func closedEyeWarningPenalizesLeadSelection() {
        func row(_ id: String, rating: Double, score: Double, warnings: [String]) -> NavigationAssembler.CaptureRow {
            NavigationAssembler.CaptureRow(
                id: id,
                filepath: "/photos/\(id).JPG",
                filename: "\(id).JPG",
                capturedAt: "2026-01-01T00:00:00.000Z",
                cameraModel: "C",
                hashHex: "0",
                rating: rating,
                qualityScore: score,
                qualityWarnings: warnings,
                hasQuality: true
            )
        }
        let clean = row("p1", rating: 0, score: 0.5, warnings: [])
        let closedEye = row("p2", rating: 0, score: 0.6, warnings: ["closed_eye_risk_heuristic"])
        let group = NavigationGroup(
            id: "g1",
            type: .burst,
            photoIds: ["p2", "p1"],
            startAt: "2026-01-01T00:00:00.000Z",
            endAt: "2026-01-01T00:00:01.000Z",
            explanation: "e",
            source: .manual
        )
        let out = NavigationAssembler.withLead(group: group, byId: ["p1": clean, "p2": closedEye])
        #expect(out.leadPhotoId == "p1")
    }
}

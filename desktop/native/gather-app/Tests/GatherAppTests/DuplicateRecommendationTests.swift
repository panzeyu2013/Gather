// desktop/native/gather-app/Tests/GatherAppTests/DuplicateRecommendationTests.swift
// 复审 P2（C4）：UI 推荐保留必须与服务端 resolveGroup 同一口径
// （mtime 非法 = NaN 永不中选；全非法时取首个成员）。
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("Duplicate 推荐保留口径")
@MainActor
struct DuplicateRecommendationTests {
    private func member(id: Int, size: Int, mtime: String?) -> DuplicateGroupMember {
        DuplicateGroupMember(
            id: id, photoId: "p\(id)", isKept: false,
            fileSize: size, fileMtime: mtime,
            filepath: "/tmp/\(id).jpg", filename: "\(id).jpg")
    }

    private func group(_ members: [DuplicateGroupMember]) -> DuplicateGroup {
        DuplicateGroup(
            id: 1, groupType: .exact, memberCount: members.count,
            members: members, createdAt: "2020-01-01T00:00:00.000Z")
    }

    @Test func invalidMtimeNeverWinsEvenWithLargerSize() {
        let invalid = member(id: 1, size: 10_000, mtime: "not-a-date")
        let valid = member(id: 2, size: 1, mtime: "2020-01-01T00:00:00.000Z")
        #expect(DuplicatesViewModel.recommendation(in: group([invalid, valid]))?.id == 2)
    }

    @Test func allInvalidMtimeFallsBackToFirstMember() {
        let first = member(id: 1, size: 10_000, mtime: "bad")
        let second = member(id: 2, size: 1, mtime: "bad")
        #expect(DuplicatesViewModel.recommendation(in: group([first, second]))?.id == 1)
    }
}

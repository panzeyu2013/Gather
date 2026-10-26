// desktop/native/gather-app/Tests/GatherAppTests/FaceSplitReviewViewModelTests.swift
// P0 / F0：复核列表、成员选择、拆分调用与错误映射（VM 级）。
import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

private func makeReviewItem(
    memberId: Int,
    clusterId: Int = 1,
    cohesion: Double = 0.42,
    flags: [FaceReviewFlag] = []
) -> FaceReviewItem {
    FaceReviewItem(
        clusterId: clusterId,
        clusterLabel: "簇 \(clusterId)",
        memberId: memberId,
        photoId: "p\(memberId)",
        photoPath: "/tmp/p\(memberId).NEF",
        filename: "p\(memberId).NEF",
        bbox: [0.1, 0.1, 0.2, 0.2],
        confidence: 0.9,
        quality: 0.8,
        faceSizePx: 120,
        cohesion: cohesion,
        flags: flags
    )
}

private func makeSummary(
    clusterId: Int = 1,
    reviewCount: Int = 2,
    suspectCount: Int = 1
) -> FaceReviewClusterSummary {
    FaceReviewClusterSummary(
        clusterId: clusterId,
        label: "簇 \(clusterId)",
        size: 2,
        suspectCount: suspectCount,
        reviewCount: reviewCount,
        cohesion: 0.42
    )
}

@Suite("F0 复核与拆分 ViewModel", .serialized)
@MainActor
struct FaceSplitReviewViewModelTests {
    private func makeStack(sessionId: String = "session-a") -> (FaceKeywordingViewModel, B8FaceAPIStub, B5bJobAPIStub) {
        let face = B8FaceAPIStub()
        let jobs = B5bJobAPIStub()
        let vm = FaceKeywordingViewModel(
            sessionId: sessionId,
            face: face,
            jobs: jobs,
            captureOne: CaptureOneBridge()
        )
        return (vm, face, jobs)
    }

    @Test("loadReview 填充成员/游标/概要，并按 clusterId + includeResolved 请求")
    func loadReview() async {
        let (vm, face, _) = makeStack()
        face.reviewPageValue = FaceReviewPage(
            items: [makeReviewItem(memberId: 11), makeReviewItem(memberId: 12)],
            nextCursor: 12,
            total: 3,
            suspectTotal: 2,
            clusters: [makeSummary()]
        )
        let cluster = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        vm.select(cluster)

        await vm.loadReview(clusterId: 1, reset: true)

        #expect(vm.reviewItems.map(\.memberId) == [11, 12])
        #expect(vm.reviewNextCursor == 12)
        #expect(vm.reviewTotal == 3)
        #expect(vm.reviewSuspectTotal == 2)
        #expect(vm.reviewSummary(for: 1)?.reviewCount == 2)
        #expect(face.reviewInputs.last?.clusterId == 1)
        #expect(face.reviewInputs.last?.includeResolved == false)
        #expect(face.reviewInputs.last?.cursor == nil)
    }

    @Test("loadMoreReview 追加下一页且不重复")
    func loadMoreReview() async {
        let (vm, face, _) = makeStack()
        face.reviewPageValue = FaceReviewPage(
            items: [makeReviewItem(memberId: 11)],
            nextCursor: 11,
            total: 2,
            suspectTotal: 2,
            clusters: [makeSummary(reviewCount: 2)]
        )
        let cluster = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        vm.select(cluster)
        await vm.loadReview(clusterId: 1, reset: true)

        face.reviewPageValue = FaceReviewPage(
            items: [makeReviewItem(memberId: 12)],
            nextCursor: nil,
            total: 2,
            suspectTotal: 2,
            clusters: [makeSummary(reviewCount: 2)]
        )
        await vm.loadMoreReview()

        #expect(vm.reviewItems.map(\.memberId) == [11, 12])
        #expect(vm.reviewNextCursor == nil)
        #expect(face.reviewInputs.last?.cursor == 11)
    }

    @Test("成员选择：toggle / 全选 / 清空")
    func memberSelection() {
        let (vm, _, _) = makeStack()
        vm.select(b8FaceCluster(id: 1, sessionId: "session-a", size: 2))
        vm.reviewItems = [makeReviewItem(memberId: 11), makeReviewItem(memberId: 12)]

        vm.toggleMemberSelection(11)
        #expect(vm.selectedMemberIds == [11])
        vm.selectAllReviewMembers()
        #expect(vm.selectedMemberIds == Set([11, 12]))
        vm.clearMemberSelection()
        #expect(vm.selectedMemberIds.isEmpty)
    }

    @Test("拆分成功：调用 split、reload、选中新簇并加载其复核")
    func splitSuccess() async {
        let (vm, face, _) = makeStack()
        let old = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        let new = b8FaceCluster(id: 2, sessionId: "session-a", size: 1)
        face.clustersValue = [old, new]
        face.splitResultValue = FaceSplitResult(
            newClusterId: 2, movedCount: 1, remainingCount: 1, label: "Person 2"
        )
        vm.select(old)
        vm.reviewItems = [makeReviewItem(memberId: 11), makeReviewItem(memberId: 12)]
        vm.toggleMemberSelection(11)

        await vm.splitSelectedMembers(from: old, confirmed: true)

        #expect(face.splitInputs.count == 1)
        #expect(face.splitInputs.last?.value.clusterId == 1)
        #expect(face.splitInputs.last?.value.memberIds == [11])
        #expect(vm.selectedClusterId == 2)
        #expect(face.reviewInputs.contains { $0.clusterId == 2 })
    }

    @Test("已绑定簇拒绝拆分，且不发命令")
    func boundClusterRejected() async {
        let (vm, face, _) = makeStack()
        let cluster = b8FaceCluster(
            id: 1, sessionId: "session-a", roleName: "Alice", size: 2
        )
        vm.select(cluster)
        vm.reviewItems = [makeReviewItem(memberId: 11)]
        vm.toggleMemberSelection(11)

        await vm.splitSelectedMembers(from: cluster, confirmed: true)

        #expect(face.splitInputs.isEmpty)
        #expect(vm.reviewActionError?.code == "FACE_CLUSTER_BOUND")
    }

    @Test("全选会清空原簇：KEEP_ONE 拦截，不发命令")
    func keepOneGuard() async {
        let (vm, face, _) = makeStack()
        let cluster = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        vm.select(cluster)
        vm.reviewItems = [makeReviewItem(memberId: 11), makeReviewItem(memberId: 12)]
        vm.selectAllReviewMembers()

        await vm.splitSelectedMembers(from: cluster, confirmed: true)

        #expect(face.splitInputs.isEmpty)
        #expect(vm.reviewActionError?.code == "FACE_SPLIT_KEEP_ONE")
    }

    @Test("关闭仅看复核后 includeResolved=true")
    func includeResolvedToggle() async {
        let (vm, face, _) = makeStack()
        face.reviewPageValue = FaceReviewPage(
            items: [makeReviewItem(memberId: 11)],
            nextCursor: nil,
            total: 2,
            suspectTotal: 1,
            clusters: [makeSummary()]
        )
        let cluster = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        vm.select(cluster)
        await vm.loadReview(clusterId: 1, reset: true)

        await vm.setIncludeOnlyReviewMembers(false)

        #expect(vm.includeOnlyReviewMembers == false)
        #expect(face.reviewInputs.last?.includeResolved == true)
    }

    @Test("复核加载失败落到 reviewActionError")
    func reviewError() async {
        let (vm, face, _) = makeStack()
        face.reviewError = NSError(domain: "test", code: 1)
        vm.select(b8FaceCluster(id: 1, sessionId: "session-a", size: 2))

        await vm.loadReview(clusterId: 1, reset: true)

        #expect(vm.reviewActionError != nil)
        #expect(vm.reviewItems.isEmpty)
    }

    @Test("移除复核成员：调用 remove_member 并刷新")
    func removeReviewMember() async {
        let (vm, face, _) = makeStack()
        let cluster = b8FaceCluster(id: 1, sessionId: "session-a", size: 2)
        face.clustersValue = [cluster]
        vm.select(cluster)
        let item = makeReviewItem(memberId: 11)

        await vm.removeReviewMember(item, from: cluster)

        #expect(face.removeMemberInputs.last?.memberId == 11)
        #expect(face.removeMemberInputs.last?.clusterId == 1)
    }
}

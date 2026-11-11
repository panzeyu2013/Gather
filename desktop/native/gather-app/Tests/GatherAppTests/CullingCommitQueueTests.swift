// desktop/native/gather-app/Tests/GatherAppTests/CullingCommitQueueTests.swift
// P0-4（Wave1）：挑片决策的"加载中按键"语义——单槽 pending commit + 忙碌态。
//
// 背景：旧实现 commit 在 isLoading 时直接 return（20-culling-browse #13）：
// 20k 会话连按 5 次 X 只有 3 张变红，用户当 bug。本用例钉住修复后的行为：
// - 加载期间按下的决策不丢弃，进单槽队列（后到覆盖先到）；
// - 加载结束（loadPage 出口）自动补执行最后一次；
// - 提交执行期间 isCommitting 为真（工作台忙碌角标的数据源）；
// - 关闭会话清空排队按键（不把未确认意图留到会话结束后写盘）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

@Suite("挑片决策：加载中按键排队（P0-4）", .serialized)
@MainActor
struct CullingCommitQueueTests {
    private func makeStack() -> (CullingViewModel, B8CullingAPIStub) {
        let culling = B8CullingAPIStub()
        let viewModel = CullingViewModel(
            sessionId: "s1",
            culling: culling,
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
        viewModel.page = b8CullingPage([b8CullingAsset("p1"), b8CullingAsset("p2")])
        viewModel.currentPhotoId = "p1"
        return (viewModel, culling)
    }

    @Test("加载期间按下的决策进单槽队列，加载结束补执行")
    func commitDuringLoadIsQueuedThenFlushed() async {
        let (viewModel, culling) = makeStack()
        viewModel.isLoading = true

        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))

        #expect(culling.updateInputs.isEmpty, "加载期间不得静默提交（旧实现）")
        #expect(viewModel.hasPendingCommit, "按键必须进单槽队列，而不是被丢掉")
        #expect(viewModel.pendingCommit?.patch.pickState == .picked)

        viewModel.isLoading = false
        await viewModel.flushPendingCommit()

        #expect(culling.updateInputs.count == 1, "加载结束必须补执行排队的那一拍")
        #expect(culling.updateInputs.first?.patch.pickState == .picked)
        #expect(culling.updateInputs.first?.photoId == "p1")
        #expect(!viewModel.hasPendingCommit)
        #expect(viewModel.pendingCommit == nil)
    }

    @Test("连按多拍只重放最后一次（单槽：后到覆盖先到）")
    func latestQueuedCommitWins() async {
        let (viewModel, culling) = makeStack()
        viewModel.isLoading = true

        await viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked), shouldAdvance: false)

        #expect(viewModel.pendingCommit?.patch.pickState == .picked, "只保留最后一拍")
        #expect(viewModel.pendingCommit?.shouldAdvance == false)

        viewModel.isLoading = false
        await viewModel.flushPendingCommit()

        #expect(culling.updateInputs.count == 1, "排队只重放一拍，不把中途意图叠加写盘")
        #expect(culling.updateInputs.first?.patch.pickState == .picked)
    }

    @Test("没有排队时 flush 是 no-op")
    func flushWithoutPendingIsNoOp() async {
        let (viewModel, culling) = makeStack()
        await viewModel.flushPendingCommit()
        #expect(culling.updateInputs.isEmpty)
    }

    @Test("提交执行期间 isCommitting 为真，最后一拍结束后复位")
    func isCommittingTracksCommitChain() async {
        let (viewModel, culling) = makeStack()
        culling.responseDelay = .milliseconds(50)

        let commitTask = Task { await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked)) }
        let started = await waitUntilAsync { viewModel.isCommitting }
        #expect(started, "提交链执行期间必须报告忙碌（工作台角标据此显示）")

        await commitTask.value
        #expect(!viewModel.isCommitting)
    }

    @Test("loadPage 出口自动补执行排队的一拍")
    func loadPageFlushesQueuedCommit() async {
        let culling = B8CullingAPIStub()
        culling.pageResult = b8CullingPage([b8CullingAsset("p1"), b8CullingAsset("p2")])
        culling.responseDelay = .milliseconds(30)
        let viewModel = CullingViewModel(
            sessionId: "s1",
            culling: culling,
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )

        let loadTask = Task { await viewModel.loadPage(reset: true) }
        #expect(await waitUntilAsync { viewModel.isLoading }, "loadPage 必须先把 isLoading 置真")

        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(viewModel.hasPendingCommit, "加载中的按键先排队")

        await loadTask.value
        #expect(await waitUntilAsync { culling.updateInputs.count == 1 },
                "加载结束必须自动补执行排队的一拍")
        #expect(!viewModel.hasPendingCommit)
    }

    @Test("目标照片在加载期间变化：flush 丢弃排队按键（不写到新照片）")
    func flushDropsQueuedCommitWhenTargetPhotoChanged() async {
        let (viewModel, culling) = makeStack()
        viewModel.isLoading = true
        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(viewModel.pendingCommit?.targetPhotoId == "p1", "入队时必须冻结当时的目标照片")

        // 模拟加载把当前照片换成另一张（筛选/范围变化后回退到新页首张）。
        viewModel.currentPhotoId = "p2"
        viewModel.isLoading = false
        await viewModel.flushPendingCommit()

        #expect(culling.updateInputs.isEmpty, "目标已变时必须丢弃，不能把 X 写到 p2")
        #expect(viewModel.pendingCommit == nil)
        #expect(viewModel.notice != nil, "丢弃必须可见（notice），不能回到静默丢键")
    }

    @Test("目标照片未变化：flush 仍按原目标执行（B1 回归）")
    func flushReplaysWhenTargetPhotoUnchanged() async {
        let (viewModel, culling) = makeStack()
        viewModel.isLoading = true
        await viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
        viewModel.isLoading = false
        await viewModel.flushPendingCommit()

        #expect(culling.updateInputs.count == 1)
        #expect(culling.updateInputs.first?.photoId == "p1")
        #expect(culling.updateInputs.first?.patch.pickState == .rejected)
    }

    @Test("选择集在加载期间变化：flush 丢弃排队按键")
    func flushDropsQueuedCommitWhenSelectionChanged() async {
        let (viewModel, culling) = makeStack()
        viewModel.selectedPhotoIds = ["p1", "p2"]
        viewModel.isLoading = true
        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(viewModel.pendingCommit?.targetSelection == ["p1", "p2"])

        viewModel.selectedPhotoIds = ["p2"]
        viewModel.isLoading = false
        await viewModel.flushPendingCommit()

        #expect(culling.updateInputs.isEmpty, "选择集已变时不得按新选择重放")
        #expect(culling.batchUpdateInputs.isEmpty)
        #expect(viewModel.notice != nil)
    }

    @Test("shutdown 清空排队按键（会话结束后不再写盘）")
    func shutdownClearsPendingCommit() async {
        let (viewModel, _) = makeStack()
        viewModel.isLoading = true
        await viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
        #expect(viewModel.hasPendingCommit)

        viewModel.shutdown()
        #expect(viewModel.pendingCommit == nil)
        #expect(!viewModel.isCommitting)
    }
}

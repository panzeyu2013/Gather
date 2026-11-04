// desktop/native/gather-app/Tests/GatherAppTests/CullingObservationTests.swift
// Observation 哨兵（#6 desk 抽取的安全网）。
//
// 为什么需要：CullingViewModel 的 345 处 View 调用点全部走 root，不是 $viewModel 绑定。
// 把状态挪进子 desk 之后，如果转发属性读的不是 @Observable 属性的 getter（或 desk 忘了
// 标 @Observable / @MainActor），SwiftUI 会**静默不重绘**——现有 140 条用例抓不到这类故障，
// 因为它们不渲染，只断言状态值。
//
// 这里用 withObservationTracking 钉住「读 root 属性 → 改状态 → onChange 触发」这条链路；
// 拆 desk 之后这条用例必须仍然绿。
//
// 注意：不要为了写探针新增 @unchecked Sendable——cleanup-ratchet 的预算已经 60/60。
// 需要跨线程传值时用仓里已有的 LockedBox（GatherTestSupport）。
import Foundation
import Testing
import Observation
import GatherTestSupport
import GatherProtocol
@testable import GatherUI
@testable import GatherHost

@Suite("CtillingViewModel Observation 哨兵", .serialized)
@MainActor
struct CullingObservationTests {
    @Test("读 root 的转发属性会被追踪：改状态触发 onChange")
    func forwardingPropertiesAreTracked() throws {
        let viewModel = CullingViewModel(
            sessionId: "s-obs",
            culling: B8CullingAPIStub(),
            navigation: B8NavigationAPIStub(),
            metadata: B6bMetadataAPIStub(),
            jobs: B5bJobAPIStub(),
            quality: B5bQualityAPIStub(),
            captureOne: CaptureOneBridge()
        )
        struct Probe { var fired = false }
        let probe = LockedBox(Probe())
        withObservationTracking {
            // 触摸一个会在筛选/选择时变化的属性（desk 抽取后它可能来自子模型）。
            _ = viewModel.filterState
            _ = viewModel.selectedPhotoIds
        } onChange: {
            probe.lock.withLock { probe.fired = true }
        }
        viewModel.selectedPhotoIds = ["p1"]
        #expect(probe.lock.withLock { probe.fired },
                "改 selectedPhotoIds 必须让 observation 失效，否则拆 desk 后 View 会静默不再重绘")
    }
}

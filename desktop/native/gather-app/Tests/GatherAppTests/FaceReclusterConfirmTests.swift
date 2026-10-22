// desktop/native/gather-app/Tests/GatherAppTests/FaceReclusterConfirmTests.swift
// 「仅重新聚类」确认接线（UX 审查 P0 #2）：
//   全量重聚类会重建簇行、还原人工绑定与合并，而命令面无 confirmed 门控 —— 因此必须在
//   UI 侧拦住。本文件守住三件事：影响面计数正确、文案陈述真实数量并指向增量入口、
//   取消分支写入可见文案（不静默 return）。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

@Suite("人脸重新聚类确认")
@MainActor
struct FaceReclusterConfirmTests {
    private func cluster(
        id: Int,
        roleBinding: String? = nil,
        matchedPersonId: String? = nil
    ) -> FaceClusterData {
        FaceClusterData(
            id: id, sessionId: "session-a", label: "簇 \(id)", size: 2,
            status: "new", thumbnailBase64: "t\(id)",
            binding: roleBinding.map { FaceClusterBinding(roleName: $0, keywords: [$0]) },
            thumbnailPhotoId: nil,
            members: [],
            matchedPersonId: matchedPersonId
        )
    }

    /// 生产装配（FaceAPI + JobAPI + CaptureOneBridge）的 typed 替身；
    /// load() 走 async reload，等簇落地后再返回（不再同步 字符串命令响应表）。
    private func makeViewModel(_ clusters: [FaceClusterData]) async throws -> FaceKeywordingViewModel {
        let face = B8FaceAPIStub()
        face.clustersValue = clusters
        let viewModel = FaceKeywordingViewModel(
            sessionId: "session-a",
            face: face,
            jobs: B5bJobAPIStub(),
            captureOne: CaptureOneBridge()
        )
        viewModel.load()
        // 条件等待必须显式失败：超时后若继续断言，impactCounts 只会以 0 失败，
        // 掩盖真正的「load 未落定」原因。
        try #require(
            await waitUntilAsync { viewModel.clusters.count == clusters.count },
            "load 后簇数量未在超时内落定（期望 \(clusters.count)，实际 \(viewModel.clusters.count)）"
        )
        return viewModel
    }

    @Test("影响面计数：角色绑定与人物建议都算已绑定，未绑定的不算")
    func impactCountsBothBindingKinds() async throws {
        let viewModel = try await makeViewModel([
            cluster(id: 1, roleBinding: "张三"),
            cluster(id: 2, matchedPersonId: "person-1"),
            cluster(id: 3),
        ])
        let impact = viewModel.reclusterImpact()
        #expect(impact.clusterCount == 3)
        #expect(impact.boundClusterCount == 2)
    }

    @Test("确认文案陈述真实数量，并给出增量入口")
    func scopeTextStatesImpactAndPointsToIncremental() {
        let pending = PendingFaceRecluster(clusterCount: 12, boundClusterCount: 3)
        // Cut 4 / 4b-2b：确认文案在渲染期用 L10n 解析（这里固定 zh 断言）。
        let text = pending.scopeText(with: L10n(language: .zhCN))
        #expect(text.contains("12"), "必须写明簇总数：\(text)")
        #expect(text.contains("3"), "必须写明已绑定数：\(text)")
        #expect(text.contains("开始分析"), "必须指向保留绑定的增量入口：\(text)")
        #expect(text.contains("撤销"), "必须说明不可撤销：\(text)")
    }

    @Test("取消重新聚类写入可见文案，而不是静默返回")
    func cancelIsVisible() async throws {
        let viewModel = try await makeViewModel([cluster(id: 1)])
        #expect(viewModel.notice == nil)
        // Cut 4 / 4b-2b：动作只存 key，FaceNotice 渲染期解析。
        viewModel.reportCancellation(LocalizedText("重新聚类"))
        #expect(viewModel.notice != nil)
        let text = viewModel.notice?.resolve(with: L10n(language: .zhCN)) ?? ""
        #expect(text.contains("已取消"), "必须给出可见取消文案：\(text)")
    }
}

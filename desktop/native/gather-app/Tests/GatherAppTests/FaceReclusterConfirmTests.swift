// desktop/native/gather-app/Tests/GatherAppTests/FaceReclusterConfirmTests.swift
// 「仅重新聚类」确认接线（UX 审查 P0 #2）：
//   全量重聚类会重建簇行、还原人工绑定与合并，而命令面无 confirmed 门控 —— 因此必须在
//   UI 侧拦住。本文件守住三件事：影响面计数正确、文案陈述真实数量并指向增量入口、
//   取消分支写入可见文案（不静默 return）。

import Foundation
import Testing
import GatherCore
@testable import GatherApp

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

    private func makeViewModel(_ clusters: [FaceClusterData]) -> FaceKeywordingViewModel {
        let router = StubCommandRouter(responses: [
            "fkw.clusters": .array(clusters.map { try! JSONValue(from: $0) })
        ])
        let viewModel = FaceKeywordingViewModel(sessionId: "session-a", router: router)
        viewModel.load()
        return viewModel
    }

    @Test("影响面计数：角色绑定与人物建议都算已绑定，未绑定的不算")
    func impactCountsBothBindingKinds() {
        let viewModel = makeViewModel([
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
        let text = pending.scopeText
        #expect(text.contains("12"), "必须写明簇总数：\(text)")
        #expect(text.contains("3"), "必须写明已绑定数：\(text)")
        #expect(text.contains("开始分析"), "必须指向保留绑定的增量入口：\(text)")
        #expect(text.contains("撤销"), "必须说明不可撤销：\(text)")
    }

    @Test("取消重新聚类写入可见文案，而不是静默返回")
    func cancelIsVisible() {
        let viewModel = makeViewModel([cluster(id: 1)])
        #expect(viewModel.notice == nil)
        AppLanguageLock.withStableCopy {
            viewModel.reportCancellation(GatherLocalization.l("重新聚类"))
            #expect(viewModel.notice != nil)
        }
    }
}

// desktop/native/gather-app/Sources/GatherHost/SessionWorkspaceFactory.swift
// Cut 4 / 4a-2a-1：会话工作区工厂（SceneState 装配；RootView 暂不消费）。
//
// 职责：把 RootShellDependencies（§4.6 的壳层依赖包）**逐参数**交给 7 个
// ViewModel 的现有 init，组装成一个 SessionWorkspace：
//
//   culling / duplicates / export / face / control / gallery / similarity
//
// 约束（与审计 §4.5 的接缝表一致）：
// - 不构造任何服务/API/桥：deps 里的 session / job / culling / face / … 就是
//   AppServices 的同一实例，captureOne 是 AppBootstrap 已注册的那一只；
// - 不启动轮询、不发命令、不查库：本工厂只做对象图装配。gallery 的 init 自带
//   一次首屏补载（既有行为），因此本类型在 RootView 迁移前不会被调用；
// - face 的 initialRoleFilter 传 nil：4a-2a-2 起改由 WorkspaceIntent.faceRole
//   在页面 .task 中消费（审计 §4.5 "Face" 行），工厂不预埋深链状态。
import Foundation
import GatherProtocol
import GatherUI

@MainActor
package struct SessionWorkspaceFactory {
    private let deps: RootShellDependencies

    package init(deps: RootShellDependencies) {
        self.deps = deps
    }

    /// 构造一个会话的 7 个 VM。参数顺序与 RootView 现有创建点逐项对齐：
    /// culling/duplicates/export/face 的装配见 RootView 的 exportViewModel(for:)
    /// 等方法；control/gallery/similarity 见 SessionControlView 与 RootView 的
    /// 单槽创建点。7 个 VM 的 sessionId 必须全部等于入参（测试固定）。
    package func makeWorkspace(sessionId: String) -> SessionWorkspace {
        SessionWorkspace(
            sessionId: sessionId,
            culling: CullingViewModel(
                sessionId: sessionId,
                culling: deps.culling,
                navigation: deps.navigation,
                metadata: deps.metadata,
                jobs: deps.job,
                quality: deps.quality,
                captureOne: deps.captureOne
            ),
            duplicates: DuplicatesViewModel(
                sessionId: sessionId,
                duplicate: deps.duplicate,
                jobs: deps.job
            ),
            export: ExportViewModel(
                sessionId: sessionId,
                export: deps.export,
                session: deps.session
            ),
            face: FaceKeywordingViewModel(
                sessionId: sessionId,
                face: deps.face,
                jobs: deps.job,
                captureOne: deps.captureOne,
                initialRoleFilter: nil
            ),
            control: SessionControlViewModel(
                sessionId: sessionId,
                session: deps.session,
                culling: deps.culling,
                jobAPI: deps.job,
                qualityAPI: deps.quality
            ),
            gallery: GalleryViewModel(
                sessionId: sessionId,
                provider: deps.galleryProvider,
                job: deps.job
            ),
            similarity: SimilarityViewModel(
                sessionId: sessionId,
                similarity: deps.similarity,
                jobs: deps.job,
                captureOne: deps.captureOne
            )
        )
    }
}

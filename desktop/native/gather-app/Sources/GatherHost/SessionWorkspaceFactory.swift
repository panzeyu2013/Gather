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
        let cullingViewModel = CullingViewModel(
            sessionId: sessionId,
            culling: deps.culling,
            navigation: deps.navigation,
            metadata: deps.metadata,
            jobs: deps.job,
            quality: deps.quality,
            captureOne: deps.captureOne,
            photo: deps.photo
        )
        // SettingsAPI 是 async；先构造 VM（默认开），再异步读取 Beta 开关。
        // 已打开会话内设置变更由 settingsChanged 通知触发重读。
        let settings = deps.settings
        cullingViewModel.triageEnabledProvider = {
            do {
                let key = try SettingsKey("triage_enabled")
                return try await settings.get(key) == "1"
            } catch {
                GatherLogger.log("read triage_enabled failed: \(error)", level: .warn)
                return false
            }
        }
        cullingViewModel.triageAutoGenerateProvider = {
            do {
                let key = try SettingsKey("triage_auto_generate")
                return try await settings.get(key) == "1"
            } catch {
                GatherLogger.log("read triage_auto_generate failed: \(error)", level: .warn)
                return false
            }
        }
        cullingViewModel.gridDefaultsProvider = {
            var sortRaw = "import"
            var densityRaw = "m"
            do {
                sortRaw = try await settings.get(SettingsKey("grid_default_sort"))
            } catch {
                GatherLogger.log("read grid_default_sort failed: \(error)", level: .warn)
            }
            do {
                densityRaw = try await settings.get(SettingsKey("grid_density"))
            } catch {
                GatherLogger.log("read grid_density failed: \(error)", level: .warn)
            }
            return (sortRaw, densityRaw)
        }
        Task { @MainActor in
            await cullingViewModel.refreshTriageSettings()
            await cullingViewModel.refreshGridDefaults()
        }
        return SessionWorkspace(
            sessionId: sessionId,
            culling: cullingViewModel,
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

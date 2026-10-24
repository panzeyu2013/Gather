// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellNavigation.swift
// 单一路由模型：AppRoute / SessionPage。
//
// 唯一路由状态：`route: AppRoute`；`SessionPage` 是页面身份。
// 旧 `Destination` / `SessionTab` 兼容层已删除。
//
// 返回语义（保留 9-30 / B1 / E-P0 / 问题 8 的产品契约）：
// - 会话页「返回」= 优先回到真实页级来源（图库/相似度/上一个会话）；
//   没有页级来源时离开会话，回到进入前的全局页；
// - 图库/相似度「返回」= 回到进入前的那个页面（含页签）；
// - 普通会话页签切换不改变返回目标；从图库/相似度切走则记录页级来源；
// - 跨会话跳转记录上一个会话页。
import Observation

@MainActor
@Observable
package final class RootNavigation {
    enum WebPage: String, CaseIterable, Identifiable {
        case persons

        var id: String { rawValue }

        func title(with l10n: L10n) -> String {
            switch self {
            case .persons: return l10n("人脸库")
            }
        }

        var systemImage: String {
            switch self {
            case .persons: return "person.2"
            }
        }
    }

    private(set) var route: AppRoute = .dashboard
    /// 进入会话区域前的全局页 / 另一个会话页。
    private(set) var sessionOrigin: AppRoute?
    /// 图库/相似度/跨会话跳转的单步返回槽。
    private(set) var previousRoute: AppRoute?

    /// 入口意图写入 SessionWorkspace（由 RootView 装配；预览可为 nil）。
    /// navigator 只负责路由 + 意图转发，不持有 SessionStore。
    @ObservationIgnored
    var enqueueIntent: ((String, WorkspaceIntent) -> Void)?

    /// 清掉某会话的某类未消费意图（图库入口在写入新意图前先清旧照片）。
    @ObservationIgnored
    var clearIntent: ((String, WorkspaceIntent.Kind) -> Void)?

    var isDashboard: Bool { if case .dashboard = route { return true }; return false }
    var isLibrary: Bool { if case .library = route { return true }; return false }
    var isPersons: Bool { if case .persons = route { return true }; return false }

    var currentSessionId: String? { route.sessionId }

    func isGallery(sessionId: String) -> Bool {
        if case .session(let id, .gallery) = route { return id == sessionId }
        return false
    }

    func isSimilarity(sessionId: String) -> Bool {
        if case .session(let id, .similarity) = route { return id == sessionId }
        return false
    }

    func isSessionPage(sessionId: String, page: SessionPage) -> Bool {
        route == .session(sessionId: sessionId, page: page)
    }

    // MARK: - 全局目的地

    func selectDashboard() {
        clearReturnState()
        route = .dashboard
    }

    func selectLibrary() {
        clearReturnState()
        route = .library
    }

    func selectWeb(_ page: WebPage) {
        clearReturnState()
        switch page {
        case .persons: route = .persons
        }
    }

    // MARK: - 会话入口

    /// 打开工作区：默认落控制中心（与 TS /sessions/:id 一致）。
    func openSession(_ sessionId: String) {
        enterSession(sessionId, page: .control)
    }

    /// 会话页面入口（旧 SessionTab 入口已统一到 SessionPage）。
    func openSessionPage(_ sessionId: String, _ page: SessionPage) {
        open(page, in: sessionId)
    }

    /// 新的页面入口：同会话换普通页签不覆盖来源；从图库/相似度离开时记录
    /// 页级来源，返回先回图库/相似度（对齐旧 openSessionTab 的 recordOrigin）。
    func open(_ page: SessionPage, in sessionId: String) {
        if case .session(let currentId, let currentPage) = route, currentId == sessionId {
            if currentPage != page,
               currentPage == .gallery || currentPage == .similarity {
                previousRoute = route
            }
            route = .session(sessionId: sessionId, page: page)
            return
        }
        enterSession(sessionId, page: page)
    }

    func openGallery(_ sessionId: String) {
        guard !isGallery(sessionId: sessionId) else { return }
        recordEntryIfNeeded()
        previousRoute = route
        route = .session(sessionId: sessionId, page: .gallery)
    }

    func openSimilarity(_ sessionId: String) {
        guard !isSameSessionPage(sessionId: sessionId, page: .similarity) else { return }
        recordEntryIfNeeded()
        previousRoute = route
        route = .session(sessionId: sessionId, page: .similarity)
    }

    // MARK: - 返回

    /// 会话页返回：先回页级来源（图库/相似度/上一个会话），没有则离开会话。
    func backFromSession(sessionId: String) {
        _ = goBack()
    }

    /// 图库入口：可选直达某张照片 / 套用筛选。
    func openGallery(_ sessionId: String, photoId: String? = nil, photoPath: String? = nil) {
        clearIntent?(sessionId, .galleryPhoto)
        if photoId != nil || photoPath != nil {
            enqueueIntent?(sessionId, .galleryPhoto(id: photoId, path: photoPath))
        }
        openGallery(sessionId)
    }

    func openGalleryOffline(_ sessionId: String) {
        clearIntent?(sessionId, .galleryPhoto)
        enqueueIntent?(sessionId, .galleryFilter(.offline))
        openGallery(sessionId)
    }

    func openFaceAnalyze(_ sessionId: String) {
        enqueueIntent?(sessionId, .faceAnalyze)
        open(.faceKw, in: sessionId)
    }

    func openFaceRole(_ role: String, in sessionId: String) {
        enqueueIntent?(sessionId, .faceRole(role))
        open(.faceKw, in: sessionId)
    }

    func openCullingConflicts(_ sessionId: String) {
        enqueueIntent?(sessionId, .cullingConflicts)
        open(.culling, in: sessionId)
    }

    func openExport(_ sessionId: String, intent: ExportRangeIntent) {
        enqueueIntent?(sessionId, .exportRange(intent))
        open(.export, in: sessionId)
    }

    /// 图库/相似度返回：回到进入前的页面（页签/全局页）。
    func backFromGallery() {
        _ = goBack()
    }

    func backFromSimilarity(sessionId: String) {
        _ = goBack()
    }

    /// 单步返回：previous 优先，否则 sessionOrigin，最后工作台。
    @discardableResult
    func goBack() -> Bool {
        // 先取出并清空：任何分支（previous / origin / dashboard）都必须满足
        // “回到目标后不再残留页级返回槽”，否则下一次返回会复活旧页面。
        let previous = previousRoute
        previousRoute = nil
        if let previous, previous != route {
            route = previous
            return true
        }
        if let origin = sessionOrigin, origin != route {
            route = origin
            return false
        }
        route = .dashboard
        return false
    }

    // MARK: - 私有

    private func enterSession(_ sessionId: String, page: SessionPage) {
        if route.isSession {
            previousRoute = route
        } else {
            sessionOrigin = route
            previousRoute = nil
        }
        route = .session(sessionId: sessionId, page: page)
    }

    private func recordEntryIfNeeded() {
        if !route.isSession {
            sessionOrigin = route
        }
    }

    private func isSameSessionPage(sessionId: String, page: SessionPage) -> Bool {
        if case .session(let id, let current) = route {
            return id == sessionId && current == page
        }
        return false
    }

    private func clearReturnState() {
        sessionOrigin = nil
        previousRoute = nil
    }
}

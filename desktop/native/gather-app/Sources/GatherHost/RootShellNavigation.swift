// desktop/native/gather-app/Sources/GatherHost/RootShellNavigation.swift
// Cut 4 / 4c-2k：RootNavigation 从 RootView.swift（原 27-224 行）原样搬移。
//
// 行为不变：目的地状态机 / 来源记录 / B1 单步返回 / 侧栏选中判定全部逐字保留；
// 本文件只承载类型，不构造 View。
import Observation
import GatherUI

@MainActor
@Observable
package final class RootNavigation {
    enum WebPage: String, CaseIterable, Identifiable {
        case persons

        var id: String { rawValue }

        /// Cut 4 / 4b-3：标题在**渲染期**按注入的语言解析（枚举本身不持有
        /// 语言源；旧实现读进程全局，切语言后需要整树重建才会变）。
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

    /// 单一表示：WebPage 即页面身份，网页类页面统一走 .page(WebPage)。
    /// （旧实现同时存在 .persons 与 .page(.persons) 两套表示，令 .page(.persons)
    /// 永远构造不出来——已收敛，人脸库经侧栏 selectWeb(.persons) 真实可达。）
    enum Destination: Equatable {
        case dashboard
        case page(WebPage)
        case library
        case gallery(String)
        case similarity(String)
        case sessionTab(String, SessionTab)
    }

    private(set) var destination: Destination = .dashboard

    var selectedWebPage: WebPage? {
        if case .page(let page) = destination { return page }
        return nil
    }

    var isDashboard: Bool { if case .dashboard = destination { return true }; return false }
    var isLibrary: Bool { if case .library = destination { return true }; return false }
    var isPersons: Bool { if case .page(.persons) = destination { return true }; return false }

    /// 测试用判定（B1 返回语义）。
    func isGallery(sessionId: String) -> Bool {
        if case .gallery(let id) = destination { return id == sessionId }
        return false
    }

    func isSessionTab(sessionId: String, tab: SessionTab) -> Bool {
        if case .sessionTab(let id, let current) = destination { return id == sessionId && current == tab }
        return false
    }

    var gallerySessionId: String? {
        if case .gallery(let id) = destination { return id }
        return nil
    }

    var similaritySessionId: String? {
        if case .similarity(let id) = destination { return id }
        return nil
    }

    var sessionTabDestination: (sessionId: String, tab: SessionTab)? {
        if case .sessionTab(let id, let tab) = destination { return (id, tab) }
        return nil
    }

    /// 当前打开的会话 id（对齐旧版 sessionStore.currentSessionId 驱动的
    /// 侧栏"当前会话"项）：gallery / similarity / 任一工作区页签均算。
    var currentSessionId: String? {
        if let id = gallerySessionId { return id }
        if let id = similaritySessionId { return id }
        if let tab = sessionTabDestination { return tab.sessionId }
        return nil
    }

    func selectDashboard() { destination = .dashboard }
    func selectLibrary() { destination = .library }

    func selectWeb(_ page: WebPage) {
        destination = .page(page)
    }

    /// 进入工作区之前的来源页（第三轮审计 E-P0）。
    ///
    /// 会话页的返回按钮原先**写死**去图库：从工作台点「进入」、从人脸库深链、
    /// 或从全局图库点照片进来，返回都落图库，用户被丢到没去过的页面。
    /// 这里记录真实的来源，返回时回到那里。
    enum SessionOrigin: Equatable {
        case dashboard
        case library
        case persons
        case gallery
        case similarity
    }

    private(set) var sessionOrigin: SessionOrigin = .gallery

    /// 上一个真实页面（含工作区 id 与页签）。B1（9-30 审查）：粗粒度的
    /// SessionOrigin 只能表达「哪一类页面」，无法表达「控制中心 / 浏览 / 相似度」
    /// 这类同层页签切换——「工作台 → 控制中心 → 浏览 → 相似度 → 返回」于是回到
    /// 工作台而不是浏览页。返回语义改用完整目的地。
    private(set) var previousDestination: Destination?

    /// 记录来源（仅在进入会话/图库/相似度时调用）。
    private func recordOrigin() {
        previousDestination = destination
        switch destination {
        case .dashboard: sessionOrigin = .dashboard
        case .library: sessionOrigin = .library
        case .page(.persons): sessionOrigin = .persons
        // A6（审计 4）：.gallery 与 .similarity 以前落 default 被吞掉 →
        // 「工作台 → 会话 → 图库页签 → 返回」会回到工作台（更早的页面），
        // 而不是用户实际所在的图库。
        case .gallery: sessionOrigin = .gallery
        case .similarity: sessionOrigin = .similarity
        default: break
        }
    }

    /// 通用返回（B1 9-30 审查）：优先回到**上一个真实页面**（可精确到
    /// 工作区 + 页签 / 图库 / 相似度 / 页面型目的地）；没有记录时退回粗粒度来源。
    ///
    /// 返回后清空 previousDestination（单步返回，不做前进栈），避免来回弹跳。
    @discardableResult
    func goBack(sessionId: String) -> Bool {
        if let previous = previousDestination, previous != destination {
            previousDestination = nil
            destination = previous
            return true
        }
        // 兜底：按粗粒度来源回到对应页面（含图库——B1 的复现路径）。
        switch sessionOrigin {
        case .dashboard: selectDashboard()
        case .library: selectLibrary()
        case .persons: selectWeb(.persons)
        case .gallery: openGallery(sessionId)
        case .similarity: openSimilarity(sessionId)
        }
        return false
    }

    /// 从工作区页面返回：回到真实来源页。
    func backFromSession(sessionId: String) {
        goBack(sessionId: sessionId)
    }

    /// 相似度页返回：回到进入相似度之前的页面（A6/G-3 审计 4/5 + B1）。
    func backFromSimilarity(sessionId: String) {
        goBack(sessionId: sessionId)
    }

    /// 工作区入口与 TS /sessions/:id 一致：先进入控制中心。
    ///
    /// 4a-2c：lastSessionId 由 SessionStore.activate 唯一写入；待打开照片 /
    /// 入口意图由 Shell 在 workspace 上 enqueue，本类型只负责目的地。
    func openSession(_ sessionId: String) {
        recordOrigin()
        destination = .sessionTab(sessionId, .control)
    }

    func openGallery(_ sessionId: String) {
        // 记录来源：图库的返回按钮也要回到真实的来源页（工作台 / 全局图库 / 人脸库）。
        if case .gallery = destination {} else { recordOrigin() }
        destination = .gallery(sessionId)
    }

    func openSimilarity(_ sessionId: String) {
        // G-3（审计 5）：相似度页的返回也要回到真实来源（此前写死去图库）。
        recordOrigin()
        destination = .similarity(sessionId)
    }

    func openSessionTab(_ sessionId: String, _ tab: SessionTab) {
        // 会话**内部**的页签切换不改变来源（否则来回切页签会把来源覆盖掉），
        // 但**会话之间**的跳转必须记录来源（A6：图库 → 会话页签的返回落点）。
        if case .sessionTab(let current, _) = destination, current == sessionId {} else { recordOrigin() }
        destination = .sessionTab(sessionId, tab)
    }

    /// 图库页返回：回到进入图库之前的页面（默认工作台）。
    func backFromGallery() {
        // 问题 8（第三轮审查）：旧实现把 gallery/similarity/dashboard 合并成
        // 「回工作台」，而新的 previousDestination/goBack 只被会话与相似度入口使用
        // ⇒「工作台 → 控制中心 → 图库 → 返回」落到工作台而不是控制中心。
        // 图库同样走统一返回（精确恢复到上一个完整页面）。
        goBack(sessionId: gallerySessionId ?? "")
    }
}

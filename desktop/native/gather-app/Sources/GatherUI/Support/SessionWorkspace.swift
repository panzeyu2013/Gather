// desktop/native/gather-app/Sources/GatherUI/Support/SessionWorkspace.swift
// Cut 4 / 4a-0：每会话工作区（§4.2/§4.3/§4.4）。
//
// 一个 SessionWorkspace 汇总一个会话的 7 个 ViewModel（设计 §4.2 的 4 个 +
// 审计补的 control/gallery/similarity），并显式持有生命周期、可见性、入口意图。
//
// Cut 4 / 4a-2c + R4 P1-2：可见性分两级，避免"整会话可见"被当成"每页都可见"。
// 1. 会话级：workspace.setVisible 只标记会话区域进出。true 不启动任何 VM
//    （否则从未挂载的 gallery/control/similarity 会在后台空转）；false 仍全量
//    扇出停止 7 个 VM —— 离开会话/关闭时必须全停，漏停比多停危险。
// 2. 页面级：VM.setVisible(true) 只由**当前挂载页面**的 onAppear 经
//    setPageVisible 启动；页签切换由旧页 onDisappear(false) + 新页 onAppear(true)
//    交接，进入会话不再顺带启动未挂载页面。
// 会话区域进出由外壳调 workspace.setVisible（见 RootView.switchWorkspace）；
// close 按注册表逐个 shutdown（取消各自长任务）。
//
// #12（生命周期表驱动）：上面三处扇出（会话级 hidden / 页面级 hidden / close）
// 不再逐页手写字面量，统一迭代 SessionPage → SessionPageModel 注册表
// （pageModels / lifecycleOrder）。加页面只需在 init 登记一次；
// 视图构造（SessionPageHost.pageView）与标题（SessionPage.titleKey）仍是穷尽
// switch —— 那里编译期报错是刻意的，换成表只会把错误推迟到运行时。
// 生命周期完整性由 init 的 assert（debug）+ WorkspaceVisibilityTests 的
// 「注册表覆盖全部页面」用例（CI）共同兜住。
//
// 构造：VM 全部由 SessionStore 的工厂闭包创建后注入，本文件不构造 VM；
// 标题缓存走 SessionAPI.get（GatherUI 只依赖 GatherProtocol）。
import Foundation
import Observation
import GatherProtocol

@MainActor
@Observable
public final class SessionWorkspace: Identifiable {
    /// 显式生命周期：closed 是终态（endSession 之后不可复用）。
    public enum Lifecycle: Equatable, Sendable {
        case active
        case suspended
        case closed
    }

    /// 会话区域内的 7 个页面（与 7 个 VM 一一对应）。
    /// 页面级可见性只经 `setPageVisible` 按页路由：切页签只启停对应 VM，
    /// 不会因为 workspaces 里有 7 个 VM 就全部置真（R4 P1-2）。
    ///
    /// 单一身份来源是 `SessionPage`；旧类型名保留为别名，避免工作区/测试
    /// 一次性大改。新代码应直接使用 `SessionPage`。
    public typealias Page = SessionPage

    public let sessionId: String
    public let culling: CullingViewModel
    public let duplicates: DuplicatesViewModel
    public let export: ExportViewModel
    public let face: FaceKeywordingViewModel
    public let control: SessionControlViewModel
    public let gallery: GalleryViewModel
    public let similarity: SimilarityViewModel

    /// 页面生命周期注册表：SessionPage → 该页的 ViewModel。
    ///
    /// 为什么加：三处扇出（会话级 hidden / 页面级 hidden / close）原先是 7 行
    /// 手写字面量，加页面必须记得改三处；现在只在这里登记一次，扇出统一迭代。
    /// 强类型字段（culling/gallery/…）保留：67 处消费点靠它们做类型推断，
    /// 换成 any SessionPageModel 只会把编译期类型检查换成运行时 cast。
    ///
    /// 完整性由两方面保证：init 里的 assert（debug）+ WorkspaceVisibilityTests
    /// 的「注册表覆盖 SessionPage.allCases」用例（两道都失败才会漏）。
    private let pageModels: [Page: any SessionPageModel]

    /// 生命周期扇出顺序：与历史手写顺序逐字一致（culling → … → similarity）。
    ///
    /// 顺序有语义：shutdown 是终态，先停 culling 的画质轮询再停别人，与旧行为
    /// 保持同一副作用次序；用数组而不是字典遍历，保证不依赖哈希顺序。
    static let lifecycleOrder: [Page] = [
        .culling, .duplicates, .export, .faceKw, .control, .gallery, .similarity,
    ]

    public private(set) var lifecycle: Lifecycle = .suspended
    /// 会话级可见性（= SessionStore.activeSessionId 命中且目的地属于本会话）。
    /// **不**代表任一页面的 VM 已可见：页面级真相在各页 onAppear/onDisappear
    /// 经 `setPageVisible` 写入（R4 P1-2/P2-16）。
    public private(set) var isVisible = false
    /// 缓存标题，替代 RootView.refreshWindowTitle 的同步查库。
    public private(set) var sessionName: String?
    /// 入口意图：同 Kind 后到覆盖先到；take 取出即清。
    public private(set) var pendingIntents: [WorkspaceIntent.Kind: WorkspaceIntent] = [:]

    /// 标题异步查询任务（同一 workspace 只查一次；close 时取消）。
    @ObservationIgnored private var nameTask: Task<Void, Never>?

    public nonisolated var id: String { sessionId }

    public init(
        sessionId: String,
        culling: CullingViewModel,
        duplicates: DuplicatesViewModel,
        export: ExportViewModel,
        face: FaceKeywordingViewModel,
        control: SessionControlViewModel,
        gallery: GalleryViewModel,
        similarity: SimilarityViewModel,
        sessionName: String? = nil
    ) {
        self.sessionId = sessionId
        self.culling = culling
        self.duplicates = duplicates
        self.export = export
        self.face = face
        self.control = control
        self.gallery = gallery
        self.similarity = similarity
        self.sessionName = sessionName
        self.pageModels = [
            .culling: culling,
            .duplicates: duplicates,
            .export: export,
            .faceKw: face,
            .control: control,
            .gallery: gallery,
            .similarity: similarity,
        ]
        // 新页面漏登记时，debug 直接炸在第一处构造；release 由测试与
        // setPageVisible 的 assertionFailure 兜底。
        assert(
            Set(pageModels.keys) == Set(Page.allCases),
            "SessionWorkspace 注册表缺少页面：\(Set(Page.allCases).subtracting(pageModels.keys))")
    }

    /// 注册表读取（internal：测试断言完整性/终态；生产只经三处扇出）。
    func pageModel(_ page: Page) -> (any SessionPageModel)? { pageModels[page] }

    public var isClosed: Bool { lifecycle == .closed }

    /// 会话级可见性（第一级）：只标记会话区域进出，**不**启动任何 VM 轮询。
    /// - visible=true：无 VM 副作用；当前挂载页的 onAppear 会经 setPageVisible
    ///   启动它自己的那个 VM（进入会话不再启动未挂载页面）；
    /// - visible=false：离开会话/关闭，按注册表全量停止（必须全停，漏停比多停危险）；
    /// - shutdown 之后明确 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard lifecycle != .closed else { return }
        isVisible = visible
        lifecycle = visible ? .active : .suspended
        guard !visible else { return }
        for page in Self.lifecycleOrder {
            pageModels[page]?.setVisible(false)
        }
    }

    /// 页面级可见性（第二级）：只由**当前挂载页面**的 onAppear/onDisappear 调用。
    ///
    /// 与旧的 7 VM 扇出相反，本方法只经注册表启停 `page` 对应的那一个 VM：进入
    /// sessionTab(culling) 只启动 culling，切到图库只启动 gallery，未挂载的
    /// control/similarity 不会因会话激活而在后台轮询（R4 P1-2）。
    /// close 之后 no-op，避免页面离场回调复活已关闭的 VM。
    public func setPageVisible(_ page: Page, _ visible: Bool) {
        guard lifecycle != .closed else { return }
        guard let model = pageModels[page] else {
            // release 下静默跳过（宁可少停一个页面，也不能崩掉整条离场路径）；
            // debug 用 assertionFailure 把「漏登记」暴露在第一次切页时。
            assertionFailure("SessionWorkspace 未登记页面 \(page.rawValue) 的生命周期模型")
            return
        }
        model.setVisible(visible)
    }

    // MARK: - 标题缓存

    /// 异步缓存会话标题（替代外壳每次导航同步 listSessions 查库）。
    ///
    /// 幂等：已有标题 / 查询在途 / 已关闭时 no-op。查询失败保留 nil，
    /// 下次进入会话页会重试（标题退回「Gather」，不影响页面可用性）。
    public func loadSessionNameIfNeeded(using session: any SessionAPI) {
        guard lifecycle != .closed, sessionName == nil, nameTask == nil else { return }
        nameTask = Task { [weak self] in
            guard let self else { return }
            defer { self.nameTask = nil }
            guard let data = try? await session.get(self.sessionId),
                  !Task.isCancelled,
                  self.lifecycle != .closed else { return }
            self.sessionName = data.name.isEmpty ? nil : data.name
        }
    }

    // MARK: - 入口意图

    public func enqueue(_ intent: WorkspaceIntent) {
        guard lifecycle != .closed else { return }
        pendingIntents[intent.kind] = intent
    }

    /// 取出即清：返回 nil 表示没有该种意图（调用方不得重复消费）。
    public func take(_ kind: WorkspaceIntent.Kind) -> WorkspaceIntent? {
        pendingIntents.removeValue(forKey: kind)
    }

    // MARK: - 关闭

    /// 会话结束（删除会话 / LRU 淘汰 / Store 替换）：终态 + 取消标题查询 +
    /// 清入口意图 / 大集合，并调 7 个 VM 的 shutdown 取消各自长生命周期 Task。
    public func close() {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        isVisible = false
        nameTask?.cancel()
        nameTask = nil
        for page in Self.lifecycleOrder {
            pageModels[page]?.shutdown()
        }
        pendingIntents.removeAll()
        sessionName = nil
    }
}

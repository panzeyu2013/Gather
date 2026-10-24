// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Load.swift
// Cut 4 / 4c-2d：首屏加载单飞、补载、重置取首页（原 GalleryViewModel.swift 470-546 行）。
// 纯搬移：reload 自己递增代数的 D04 修复与「首页被拒不再假空态」兜底不变；
// reload 改 internal（+Filter/+Scroll 也调用）。
import Foundation

extension GalleryViewModel {

    // MARK: 加载

    func load() async {
        // 单飞加载：首次激活（activateIfNeeded）与显式 load（重试/深链）并发时
        // 合并为同一轮，后者直接等待前者结果，避免两轮加载互相覆盖
        //（fetchNextPage 的 isFetchingNextPage 早退会把 phase 兜底成 loaded）。
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        phase = .loading
        do {
            session = try await provider.getSession(sessionId)
        } catch {
            actionError = CommandError(error)
        }
        // B8.2a：thumbnail_size 经 SettingsAPI.get（async）。
        thumbnailSize = await provider.thumbnailSize()
        await refreshWorkspaceStatus()
        await reload()
    }

    /// 首载激活（R4 P1-4）：只由页面首次可见触发（setVisible(true)，来源是
    /// GatherSessionPage 的 onAppear → workspace.setPageVisible(.gallery, true)）。
    ///
    /// 构造 workspace 不再取页：旧实现把 loadIfNeeded() 挂在 init 的 initTask 上，
    /// 进入 control/face/export 或只 enqueue 意图都会打一次 photo.list_page。
    /// 本入口只生效一次：
    /// - 再次 onAppear / 隐藏再显示：hasActivated 已置真，不重复取页；
    /// - shutdown 之后：isShutdown 守卫，不复活；
    /// - 失败态不自动重试（仍由显式 load()，即视图「重试」按钮，恢复）。
    public func activateIfNeeded() {
        guard !isShutdown, !hasActivated else { return }
        hasActivated = true
        activateTask = Task { [weak self] in
            // 激活与关闭竞态：若 Task 尚未开始 VM 已关闭，直接放弃取页。
            guard let self, !self.isShutdown else { return }
            await self.loadIfNeeded()
        }
    }

    /// 补载入口（.task(id:)/onChange/首次激活共用）：仅当从未成功加载时取首页，
    /// 避免同一次会话切换的多路触发重复取页；失败态不自动重试（由视图「重试」按钮 load()）。
    /// 关闭是终态：shutdown 后迟到的 .task/激活不得再取页。
    func loadIfNeeded() async {
        guard !isShutdown, pages.isEmpty, phase == .loading else { return }
        await load()
    }

    /// 重置并取第一页（TS queryKey ['photos', sessionId, expandVariants] 变更）。
    func reload() async {
        // 取消在途链式拉取（chain-fetch 循环每次迭代检查取消），防止与
        // 重置后的首页竞态（isFetchingNextPage 早退导致 phase 滞留 loading）。
        fetchTask?.cancel()
        fetchTask = nil
        // P1-1（审计 2）：reload 必须**自己**递增代数。旧实现只清理数组：
        // 此时若仍有同代取页在途（滚动预取/哨兵/定位都不受 fetchTask 管理），
        // 新首页会被 fetchNextPage 的「同代拒绝」挡掉 → phase 兜成 loaded →
        // 界面显示「暂无照片」，随后旧响应（代数没变，校验通过）把旧游标之后的
        // 行 append 进空数组 → 网格从 p200 开始（D04 症状从 ⌘R/刷新路径复现）。
        fetchGeneration += 1
        pages = []
        pagesGeneration += 1
        flatCache = nil
        filteredCache = nil
        pageCursors = []
        committedSearch = search.trimmingCharacters(in: .whitespaces)
        committedFilter = filter
        committedExpandVariants = expandVariants
        searchActiveWas = false
        phase = .loading
        // 第三轮审计 C-#3 + 深度审查 D07：换筛选/搜索后，选择集必须收敛到
        //「还会出现」的照片。清空必须发生在**所有**改查询的入口（不只 reload）：
        // 普通搜索走 commitSearch，不经过 reload，旧选择会留在隐藏项上。
        clearSelectionForNewQuery()
        await fetchNextPage()
        // A1（审计 4）：筛选/搜索态的**首页只有一页 limit**，客户端过滤要看到全局结果
        // 必须链式拉满。旧实现把链式拉满只放在 commitSearch 里，而「进入页面时带着
        // 筛选意图」（控制中心『N 张离线 → 查看』）路径上 commitSearch 早于首页加载，
        // hasNextPage 还是 false → 空转 → 用户停在「没有符合条件的照片」的死态。
        if searchActive {
            await chainFetchIfActive()
        }
        // 兜底：仅在本轮没有在途请求时收尾（有在途请求时由它自己写 phase）。
        // 旧实现无条件兜底：首页被拒时会把「空数据集」标成 loaded，用户看到假空态。
        if phase == .loading, fetchingGeneration == nil { phase = .loaded }
    }
}

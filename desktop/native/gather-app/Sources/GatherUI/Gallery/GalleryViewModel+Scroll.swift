// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Scroll.swift
// Cut 4 / 4c-2d：滚动分页、链式拉满、目标照片定位与取页（原 GalleryViewModel.swift
// 712-881 行）。纯搬移：D05「无进展即终止」、D08 四种定位结果与在途代数守卫不变；
// chainFetchIfActive / fetchNextPage 改 internal（+Load/+Filter/+Events 调用）。
import Foundation

extension GalleryViewModel {

    // MARK: 滚动加载（TS sentinel + chain-fetch effect）

    /// 视图滚近末尾时调用：非搜索态取下一页；搜索/筛选态链式拉满。
    public func loadMoreIfNeeded() async {
        // TS Gallery.tsx:118 —— 无更多页时哨兵不触发取页（含空页确认后的
        // 终态；搜索态由 chainFetchIfActive 内部再判）。
        guard !pages.isEmpty, hasNextPage, !isFetchingNextPage else { return }
        if searchActive {
            await chainFetchIfActive()
        } else {
            _ = await fetchNextPage()
        }
    }

    func chainFetchIfActive() async {
        guard searchActive, hasNextPage, !isFetchingNextPage else { return }
        // 链式拉取挂到 fetchTask：reload/事件刷新可取消在途循环（弱引用防环）。
        fetchTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            while self.searchActive && self.hasNextPage && !self.isFetchingNextPage {
                do { try Task.checkCancellation() } catch { return }
                let before = self.pages.count
                let hadMore = await self.fetchNextPage()
                // D05：任一失败（或无进展）立即终止链式取数。旧实现忽略返回值——
                // 下一页持续失败时游标仍在，循环条件恒成立，用户没点重试就自动
                // 发出 21+ 次请求。保留已加载结果，把重试留给用户（滚动/重试）。
                // pages 无增长同时挡住「并发取页早退返回 hasNextPage=true」的自旋。
                guard hadMore, self.pages.count > before else { return }
            }
        }
        fetchTask = task
        // Task 的失败类型为 Never（内部 do/catch 已吞掉取消），无需 try?
        await task.value
    }

    /// D08：把目标照片定位到已加载数据集里。
    ///
    /// 旧实现只在 filteredPhotos 里查找：初始页大小 200，目标排在其后时页面只会停在
    /// 首页（用户以为「查看照片」没生效），要靠自己滚到目标附近才触发分页。
    /// 这里主动向后取页直到找到目标；仍找不到返回 false，由调用方给出明确反馈。
    ///
    /// 定位结果（审计 2 P2-4）：把「找不到」「超出扫描范围」「取页失败」分开。
    /// 旧实现只返回 Bool，三种情况都报「可能已被移除」——取页瞬时失败会让用户
    /// 以为照片没了，目标在上万张之后也被说成已删除。
    public enum PhotoLocateOutcome: Equatable, Sendable {
        case found
        case notFound
        case outOfRange
        case failed
    }

    public func locatePendingPhoto(photoId: String?, photoPath: String?) async -> PhotoLocateOutcome {
        guard photoId != nil || photoPath != nil else { return .notFound }
        func isFound() -> Bool {
            loadedPhotos.contains { row in
                if let photoId, row.id == photoId { return true }
                if let photoPath, row.filepath == photoPath { return true }
                return false
            }
        }
        /// 目标可能是被折叠的兄弟变体（RAW/JPEG 对里非首选那张）：这时它在
        /// loadedPhotos 里根本不存在（list_page 默认每资产只回首选行），
        /// 旧实现会扫完上限后误报「已被移除」（审计 2 P2-3）。
        func isFoldedVariant() -> Bool {
            loadedPhotos.contains { row in
                row.variants.contains { variant in
                    if let photoId, variant.photoId == photoId { return true }
                    if let photoPath, variant.filepath == photoPath { return true }
                    return false
                }
            }
        }
        if isFound() { return .found }
        if isFoldedVariant(), !expandVariants {
            // 展开变体后目标会作为独立行出现；只展开一次（expandVariants 已置位）。
            expandVariants = true
            await reload()
            return await locatePendingPhoto(photoId: photoId, photoPath: photoPath)
        }
        var pagesFetched = 0
        while hasNextPage, pagesFetched < Self.locatePageLimit {
            // P2-5：离开页面（.task 取消）后不再继续扫。
            if Task.isCancelled { return .failed }
            pagesFetched += 1
            let before = loadedPhotos.count
            let hadMore = await fetchNextPage()
            if isFound() { return .found }
            if isFoldedVariant(), !expandVariants {
                expandVariants = true
                await reload()
                return await locatePendingPhoto(photoId: photoId, photoPath: photoPath)
            }
            guard hadMore, loadedPhotos.count > before else {
                // 无进展：区分「取页失败」（有错误）与「真的没有了」。
                return actionError == nil ? .notFound : .failed
            }
        }
        if isFound() { return .found }
        return hasNextPage ? .outOfRange : (actionError == nil ? .notFound : .failed)
    }

    /// 目标在扫描上限之外（审计 2 P2-4）：不是「不存在」，要给出可执行的建议。
    public func reportPhotoTargetOutOfRange() {
        actionError = CommandError.localized("目标照片在已加载范围之外，请用搜索缩小范围后再试。")
    }

    /// 定位被中断（取页失败/页面离开）（审计 2 P2-4）：保留原始错误，不谎称「已被移除」。
    public func reportPhotoLocateFailed() {
        if actionError == nil {
            actionError = CommandError.localized("定位照片时中断，请重试。")
        }
    }

    /// 定位失败的明确反馈（D08）：目标被删除/不属于本工作区时不静默等待。
    public func reportPhotoTargetMissing() {
        actionError = CommandError.localized("未在当前工作区找到这张照片（可能已被移除或不在本工作区）。")
    }

    /// 目标定位的最大取页数（每页 200 张 → 上限 10000 张）。更靠后时不继续扫，
    /// 避免为一次跳转把整个大图库全部拉进内存。
    private static let locatePageLimit = 50

    /// 取下一页（键集游标）；返回是否还有更多页。
    ///
    /// 审计 2 P2-10：原 isFirst 参数在函数体内从未使用（首页/续页同一条键集语义），
    /// 已删除——死参数会让调用方误以为两条路径有区别。
    @discardableResult
    func fetchNextPage() async -> Bool {
        // D04/D06：请求绑定数据代数。await 之后若代数已变（切变体/换筛选/事件重载），
        // 这份响应属于上一个数据集，必须整份丢弃——不 append 行、不改 phase。
        let generation = fetchGeneration
        // 同一代数内只允许一个在途取页；跨代数不阻塞（新首页必须能立刻取）。
        guard fetchingGeneration != generation else { return hasNextPage }
        fetchingGeneration = generation
        defer {
            // 只清自己的标记：旧代数的请求返回时不能误清新代数的在途状态。
            if fetchingGeneration == generation { fetchingGeneration = nil }
        }
        do {
            let cursor = pageCursors.last ?? nil
            // TS Gallery.tsx:69-71 —— limit 由 searchActive 决定（搜索态 1000
            // 减短链式拉取的往返次数，非搜索态 200）。
            let limit = searchActive ? Self.chainFetchLimit : Self.pageSize
                let result = try await provider.photoPage(
                sessionId: sessionId,
                afterFirstRowid: cursor,
                limit: limit,
                expandVariants: committedExpandVariants
            )
            guard generation == fetchGeneration else { return false }
            pages.append(result.rows)
            pagesGeneration += 1
            pageCursors.append(result.cursor)
            if phase == .loading { phase = .loaded }
            // P2-2（审计 2）：成功取页清掉上一次的瞬时错误。旧实现只有写没有清：
            // 一次分页失败的红条会永久挂在页顶（VM 按 session 缓存，离开再回来还在）。
            actionError = nil
            return result.cursor != nil
        } catch {
            guard generation == fetchGeneration else { return false }
            if pages.isEmpty && phase == .loading {
                // 4a-3b-2a：首屏失败只存错误载体，文案在渲染期解析。
                phase = .failed(CommandError(error))
            } else {
                actionError = CommandError(error)
            }
            return false
        }
    }
}

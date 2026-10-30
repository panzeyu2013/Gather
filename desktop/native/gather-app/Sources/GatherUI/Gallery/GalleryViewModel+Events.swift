// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Events.swift
// Cut 4 / 4c-2d：终态事件刷新（500ms 合并 + 就地重取不闪 loading，原
// GalleryViewModel.swift 911-994 行）。纯搬移：代数校验、可取消让出与
// 选择集 formIntersection 收敛逐字不变。
import Foundation
import GatherProtocol

extension GalleryViewModel {

    // MARK: 终态事件刷新（对齐 TS 事件失效语义）

    /// 终态事件驱动的按需刷新：500ms 合并连续终态帧（索引结束多帧风暴
    /// 只触发一次重载），替代“打开即快照”的过期展示。
    /// 隐藏期只登记（隐藏页不发命令），setVisible(true) 时补一次。
    public func scheduleEventRefresh() {
        guard !isShutdown else { return }
        guard isVisible else {
            deferredRefreshWhileHidden = true
            return
        }
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshOnEvent()
        }
    }

    /// 重取会话与当前查询（react-query invalidate 语义：终态事件后页面
    /// 立即反映照片补齐/元数据变化）。
    /// P15：不重置页码——从首页重新拉取直至重新覆盖原已加载数量，网格与
    /// 滚动位置就地更新（页面保持 loaded，全程不闪 loading），不再回卷首页。
    func refreshOnEvent() async {
        do {
            session = try await provider.getSession(sessionId)
        } catch {
            actionError = CommandError(error)
        }
        await refreshWorkspaceStatus()
        let targetCount = loadedPhotos.count
        // 审计 2 P1-2：事件刷新此前完全在代数协议之外——它整份替换 pages/pageCursors，
        // 与 reload / 切变体 / 在途取页并发时互相覆盖（旧快照覆盖新数据集、游标链跳跃），
        // 也让 locatePendingPhoto 的「行数增长」判据失效 → 误报「未找到」。
        // 现在绑定代数并在写入前校验；循环内改用可取消的让出，使旧刷新真的能被打断。
        // 自增代数：在途的 loadMoreIfNeeded/fetchNextPage（哨兵/预取）不归 fetchTask
        // 管，只 cancel fetchTask 拦不住——旧游标页会在整份替换之后 append 回来，
        // 造成重复行与游标链回退（R1 F3）。自增后旧请求的 guard 失效、整份丢弃。
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchTask?.cancel()
        var nextPages: [[GalleryPhotoData]] = []
        var nextCursors: [Int64?] = []
        do {
            var cursor: Int64?
            repeat {
                // P1（D5 接缝）：facet/规则/4 档/搜索串走服务端 criteria 时，
                // 事件刷新必须用**同一条** WHERE 重取；旧实现固定走 provider 的
                // 无 criteria 分页，任何领域事件（挑片/写回/库变更）都会把筛过的网格
                // 换成未筛行。D5 关掉了「事件后用链式拉取补几页」的兜底，这个缺口
                // 会直接表现为"滤镜在刷新后消失"。
                let limit = searchActive ? Self.chainFetchLimit : Self.pageSize
                let result: (rows: [GalleryPhotoData], cursor: Int64?)
                if let criteria = activeCriteria, let photoAPI {
                    let page = try await photoAPI.page(try PhotoPageQuery(
                        sessionId: sessionId,
                        limit: limit,
                        afterFirstRowid: cursor,
                        expandVariants: committedExpandVariants,
                        criteria: criteria))
                    result = (page.rows.map(GalleryPhotoData.init), page.cursor)
                } else {
                    result = try await provider.photoPage(
                        sessionId: sessionId,
                        afterFirstRowid: cursor,
                        limit: limit,
                        expandVariants: committedExpandVariants
                    )
                }
                guard generation == fetchGeneration else {
                    actionError = nil
                    return
                }
                nextPages.append(result.rows)
                nextCursors.append(result.cursor)
                cursor = result.cursor
                // 逐页让出主线程（可取消），避免大深度重取一帧卡死。
                try Task.checkCancellation()
            } while cursor != nil && nextPages.reduce(0, { $0 + $1.count }) < targetCount
            guard generation == fetchGeneration else {
                actionError = nil
                return
            }
            pages = nextPages
            pagesGeneration += 1
            flatCache = nil
            filteredCache = nil
            pageCursors = nextCursors
            // P2-1（审计 2）：事件刷新会丢弃已删除行，逐张勾选的选择集必须随之收敛。
            // 服务端全范围选择（⌘A）不能被刷新裁回已加载页——那会把“已选 20k”变成“已选 200”。
            if !isScopeSelection {
                selectedIds.formIntersection(loadedPhotos.map(\.id))
            }
            actionError = nil
        } catch is CancellationError {
            // 被新一轮刷新/导航取代：旧快照整份丢弃，不动任何状态。
            return
        } catch {
            // 重取失败：保留旧网格（就地语义），仅提示错误。
            guard generation == fetchGeneration else { return }
            actionError = CommandError(error)
        }
        // 搜索/筛选态链式拉满保证过滤结果的全局完整性（对齐 commitSearch）。
        if searchActive {
            await chainFetchIfActive()
        }
        if phase == .loading { phase = .loaded }
    }
}

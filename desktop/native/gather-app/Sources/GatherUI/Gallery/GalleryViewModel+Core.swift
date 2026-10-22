// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Core.swift
// Cut 4 / 4c-2d：可见性/关闭、选择集与错误载体约定（原 GalleryViewModel.swift
// 627-666、883-904、906-909 行）。纯搬移：shutdown 终态、隐藏期不刷新与
// 选择清空语义不变；clearSelectionForNewQuery 改 internal（+Load/+Filter 调用）。
import Foundation

extension GalleryViewModel {

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2b）

    /// 可见性唯一入口（PageVisibility）：View 的 onAppear/task/onDisappear 只调这里。
    /// - 幂等：与当前状态相同直接返回（重复 onAppear 不重复补刷/激活）；
    /// - visible=false：停索引状态轮询；期间的事件刷新只登记不执行；
    /// - visible=true：恢复轮询、补一次隐藏期错过的事件刷新，并在首次可见时
    ///   显式激活首载（R4 P1-4：init 不再自动取页）；
    /// - shutdown 之后明确 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown, transitionVisibility(&isVisible, to: visible) else { return }
        if visible {
            startIndexStatusPolling()
            // R4 P1-4：页面首次挂载（onAppear → setPageVisible）才取首屏；
            // 重复 onAppear/隐藏再显示由 hasActivated 去重。
            activateIfNeeded()
            if deferredRefreshWhileHidden {
                deferredRefreshWhileHidden = false
                scheduleEventRefresh()
            }
        } else {
            stopIndexStatusPolling()
        }
    }

    /// 关闭：取消本 VM 持有的全部 Task（轮询 / 取页 / 防抖 / 事件刷新 / 首载激活）。
    /// 关闭后 setVisible(true) 不重启，避免 workspace 淘汰后仍后台取页。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
        deferredRefreshWhileHidden = false
        // 让 shutdown 前发起的 workspace.status 响应失效（即使代次校验通过，
        // 回调也不得写已关闭的 VM）。
        statusRequestID += 1
        statusPollTask?.cancel()
        statusPollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        loadTask?.cancel()
        loadTask = nil
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        activateTask?.cancel()
        activateTask = nil
    }
    // MARK: 选择（TS toggleSelect / clearSelection）

    /// D07：查询条件（搜索/筛选/变体）变化时清空选择集。
    ///
    /// 清空的语义是「筛选条件下的旧选择没有稳定含义」——否则选择栏会显示屏幕上
    /// 不存在的照片数量，「全选/取消全选当前结果」也无法取消这些隐藏项。
    func clearSelectionForNewQuery() {
        guard !selectedIds.isEmpty else { return }
        selectedIds = []
    }

    public func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    public func clearSelection() {
        selectedIds = []
    }
    // MARK: 错误载体（Cut 4 / 4a-3b-2b）

    // 旧实现把本地化文案存进 actionError；现在统一走 CommandError(error)
    // （码/参数/诊断，不查表），渲染期由 CommandErrorText 解析。
}

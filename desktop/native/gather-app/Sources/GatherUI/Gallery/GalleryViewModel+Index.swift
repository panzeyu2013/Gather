// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryViewModel+Index.swift
// Cut 4 / 4c-2d：索引头文案推导（可单测纯函数）、索引状态轮询与重试（原
// GalleryViewModel.swift 421-466、468-469、605-625、668-710 行）。纯搬移：
// 状态请求序号守卫、progress 帧去抖与 dedupeKey 形状不变。
import Foundation
import GatherProtocol

extension GalleryViewModel {

    // MARK: 索引头推导（TS indexProgress.ts deriveIndexHeaderCopy:32-63 +
    //         workspace-view.ts deriveWorkspaceHeaderCopy:289-322）

    /// 索引头文案纯推导（可单测；nonisolated：不依赖任何实例状态）：
    /// 扫描活跃/失败期间绝不把阶段计数当权威数据展示；photoCount==0 且无
    /// 扫描任务时整行不渲染（返回 nil，对齐旧版 render null，而非「暂无照片」）。
    /// - 扫描中（active/created 窗口）且有数值：「正在索引 N / M（x%）」，
    ///   percent = min(100, round(N/M*100)) 自算并内联进文案；
    /// - 扫描中无数值：「扫描中…」（无进度条）；
    /// - 失败：「索引失败」（视图附「重试」按钮）；
    /// - 索引成功（stage == .indexed）或从未扫描：「已索引 N 张照片」；
    ///   截断导入在精确总数落定前保留「已索引 ≥N 张照片」。
    ///
    /// Cut 4 / 4b-2i：文案改由**调用方显式传入的 L10n** 在渲染期解析
    ///（本函数仍是纯推导、仍返回 String 载体的 GalleryIndexHeaderCopy），
    /// 不再读进程全局 appLanguage——并行测试/切语言都不会读到过期语言。
    /// 三个整数参数（done/total/percent、photoCount）走 l10n.format；模板里的
    /// %% 是字面百分号，输出单个 %（如 98%），与旧版格式化调用逐字一致。
    nonisolated public static func indexHeaderCopy(
        status: WorkspaceStatus?,
        photoCount: Int,
        truncatedImport: Bool,
        with l10n: L10n
    ) -> GalleryIndexHeaderCopy? {
        if let status, status.stage == .created || status.indexing.status == .active {
            if status.indexing.total > 0, status.indexing.done > 0 {
                // TS: percent = Math.min(100, Math.round(current/total*100))。
                let percent = min(100, Int((Double(status.indexing.done) / Double(status.indexing.total) * 100).rounded()))
                return GalleryIndexHeaderCopy(
                    kind: .scanning,
                    text: l10n.format("正在索引 %lld / %lld（%lld%%）", status.indexing.done, status.indexing.total, percent),
                    percent: percent
                )
            }
            return GalleryIndexHeaderCopy(kind: .scanning, text: l10n("扫描中…"), percent: nil)
        }
        if let status, status.indexing.status == .failed {
            return GalleryIndexHeaderCopy(kind: .error, text: l10n("索引失败"), percent: nil)
        }
        // 无 job / 已成功（stage == .indexed）：photoCount==0 → 不渲染。
        if photoCount == 0 { return nil }
        if truncatedImport, status?.stage != .indexed {
            return GalleryIndexHeaderCopy(kind: .count, text: l10n.format("已索引 ≥%lld 张照片", photoCount), percent: nil)
        }
        return GalleryIndexHeaderCopy(kind: .count, text: l10n.format("已索引 %lld 张照片", photoCount), percent: nil)
    }
    // MARK: 索引状态数据源（workspace.status 轮询 + jobs:progress 事件）

    /// 视图可见时启动索引状态轮询（活跃 3s / 空闲 15s；任务随 VM 释放）。
    /// 幂等：已在轮询则不重复建 Task（setVisible 可能被 onAppear/task 重复调用）。
    public func startIndexStatusPolling() {
        guard !isShutdown, statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshWorkspaceStatus()
                guard !Task.isCancelled else { return }
                let interval: Duration = self.workspaceStatus?.indexing.status == .active
                    ? self.activeStatusPollInterval : self.idleStatusPollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 视图隐藏时停止轮询（opacity 常驻架构：避免后台空转）。
    public func stopIndexStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
    }
    /// jobs:progress 帧（metadata.scan）：1s 去抖后刷新索引状态，进度更跟手。
    public func handleIndexJobProgress(_ event: GatherJobEvent) {
        guard event.job.type == .metadataScan, event.job.scopeId == sessionId else { return }
        guard Date().timeIntervalSince(lastStatusRefreshAt) >= Self.progressFrameDebounceSeconds else { return }
        Task { await refreshWorkspaceStatus() }
    }

    /// 重取工作区索引状态（best-effort：失败保留旧值，不打断浏览）。
    func refreshWorkspaceStatus() async {
        // shutdown 是终态：关闭后既不再发起新请求，也不允许在途响应写回状态
        //（R4 P2-4 / P0-2 的 Gallery shutdown flake：旧实现只做代次校验，
        // shutdown 后仍会写 workspaceStatus）。
        guard !isShutdown else { return }
        lastStatusRefreshAt = Date()
        // P2-9（审计 2）：索引头有四个并发调用方（load / 轮询 / 进度帧去抖 / 重试），
        // 旧响应后到会让进度百分比与阶段回退。只接受最新一次请求的结果。
        statusRequestID += 1
        let requestID = statusRequestID
        do {
            let status = try await provider.workspaceStatus(sessionId)
            guard !isShutdown, requestID == statusRequestID else { return }
            workspaceStatus = status
        } catch {
            // 索引头为辅助信息：瞬时失败静默保留旧状态，不整页报错。
        }
    }

    /// TS handleRetryIndex：重新入队 metadata.scan；入队后立即刷新状态
    ///（JobService 同步建行 → workspace.status 即报 active → 头显「扫描中…」）。
    /// R1 P1-3：建任务语义（scope/dedupeKey/checkpoint）由
    /// `JobCreateParams.metadataScan` 单源定义；这里只表达「重跑 = 目录全树，
    /// requestedPaths 交给 JobService 按 dedupeKey 继承续跑」。
    public func retryIndex() async {
        do {
            let handle = try await jobAPI.start(
                JobCreateParams.metadataScan(sessionId: sessionId, requestedPaths: nil))
            // 索引头由 workspace.status 轮询 + 任务事件推进；这里消费掉事件流，
            // 避免观察者/AsyncStream 悬挂（与 Dashboard 的 retryScan 同款）。
            handle.drain()
        } catch {
            actionError = CommandError(error)
        }
        await refreshWorkspaceStatus()
    }
}

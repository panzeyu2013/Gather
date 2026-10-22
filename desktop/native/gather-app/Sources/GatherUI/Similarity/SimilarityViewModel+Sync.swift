// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Sync.swift
// Cut 4 / 4c-2h：从 SimilarityViewModel.swift 移出 C1 同步状态机与三按钮门控
// （原 898-1017 行）。纯搬移：latest-wins 代数、reload ack 近似、
// deriveSyncControls / deriveSyncControlHints / syncStatusCopy 逐分支移植未动。
import Foundation
import GatherProtocol

extension SimilarityViewModel {

    // MARK: C1 同步状态机（TS utils/c1-sync-controls.ts 移植，2.3.5 P1）

    /// 重拉同步状态视图（sim.writeback_items 行计数 → aggregateSessionState）。
    ///
    /// 保留同步签名：SimilarityView 在 c1SyncStatus 通知回调里直接调用。
    /// 生产实现调度异步查询；需要等待结果的调用方（load/写回动作）走
    /// reloadSyncState()。失败保留上次视图（未知状态下按钮按保守策略全部
    /// 禁用），但给出可见提示，不再静默吞错（审计 7c）。
    public func refreshSyncState() {
        guard !isShutdown else { return }
        syncStateRequestID += 1
        let requestID = syncStateRequestID
        syncStateTask?.cancel()
        syncStateTask = Task { [weak self] in
            await self?.reloadSyncState(requestID: requestID)
        }
    }

    /// 需要等待结果的内部调用（load / 写回动作）：自增代数后查询，只有最新
    /// 一代响应可以落地。
    func reloadSyncState() async {
        syncStateRequestID += 1
        await reloadSyncState(requestID: syncStateRequestID)
    }

    func reloadSyncState(requestID: Int) async {
        let items: [WritebackItem]
        do {
            items = try await similarity.writebackItems(sessionId)
        } catch {
            guard requestID == syncStateRequestID else { return }
            actionError = CommandError(error)
            return
        }
        guard requestID == syncStateRequestID else { return }
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.xmpStatus, default: 0] += 1
        }
        // E-19 相邻：聚合经端口（实现=GatherDomain.aggregateSessionState）；
        // 未注册时保持「加载中」状态，不伪造同步结论。
        let state = CaptureOneSyncStateRulesRegistry.current()?.aggregateSyncState(
            counts: counts,
            reloadAckedAt: reloadAcked ? "x" : nil
        )
        syncView = SimilaritySyncView(state: state, written: counts["written"] ?? 0)
    }

    /// 三按钮可用性 + 禁用提示 + 状态文案（deriveSyncControls /
    /// deriveSyncControlHints / syncStatusCopy 逐分支移植）。
    public var syncControls: SimilaritySyncControls {
        let state = syncView?.state
        let hasWritten = (syncView?.written ?? 0) > 0
        let acked = reloadAcked

        var canLoadMetadata = false
        var canConfirmSync = false
        var canCleanup = false
        if let state {
            let loadable = state == .syncing || state == .c1Read || state == .safeToCleanup
            canLoadMetadata = loadable
            let confirmable = (state == .c1Read && hasWritten && acked) || state == .safeToCleanup
            canConfirmSync = confirmable
            canCleanup = state == .safeToCleanup
        }

        let loadHint: LocalizedText?
        if canLoadMetadata {
            loadHint = nil
        } else if state == .synced {
            loadHint = LocalizedText("已完成同步，无需再次加载元数据")
        } else if state == .failed {
            loadHint = LocalizedText("存在写入失败项，请先重试")
        } else if state == .conflict {
            loadHint = LocalizedText("存在 XMP 冲突，请先裁决")
        } else {
            loadHint = LocalizedText("没有可加载的已写入元数据")
        }
        let confirmHint: LocalizedText?
        if canConfirmSync {
            confirmHint = nil
        } else if state == .synced {
            confirmHint = LocalizedText("已完成同步")
        } else if !acked {
            confirmHint = LocalizedText("请先在 Capture One 中加载元数据，再确认同步")
        } else {
            confirmHint = LocalizedText("请先等待写入完成或处理失败项")
        }
        let cleanupHint: LocalizedText?
        if canCleanup {
            cleanupHint = nil
        } else if state == .synced {
            cleanupHint = LocalizedText("已完成清理")
        } else {
            cleanupHint = LocalizedText("请先加载元数据并确认同步，再执行清理")
        }

        let statusText: LocalizedText
        switch state {
        case .syncing: statusText = LocalizedText("同步中：Gather 正在写入 XMP…")
        case .c1Read: statusText = LocalizedText("Gather 已写入，等待 C1 读取")
        case .safeToCleanup: statusText = LocalizedText("C1 已读取，可安全清理")
        case .synced: statusText = LocalizedText("已同步")
        case .failed: statusText = LocalizedText("有写入失败项，请先重试")
        case .conflict: statusText = LocalizedText("存在 XMP 冲突，请先裁决")
        case .disconnected: statusText = LocalizedText("Capture One 未连接")
        case .connected: statusText = LocalizedText("已连接 Capture One，暂无写入")
        case nil: statusText = LocalizedText("同步状态加载中…")
        }

        return SimilaritySyncControls(
            canLoadMetadata: canLoadMetadata,
            canConfirmSync: canConfirmSync,
            canCleanup: canCleanup,
            loadHint: loadHint,
            confirmHint: confirmHint,
            cleanupHint: cleanupHint,
            statusText: statusText
        )
    }

}

// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Writeback.swift
// Cut 4 / 4c-2h：从 SimilarityViewModel.swift 移出关键词写回全链路
// （原 677-896 行：预览 / 写回 / 重试 / loadMetadata→confirmSync→cleanup）。
// 纯搬移：Confirmed(.userDialog) 唯一构造点、notice 文案 key、错误落地逐字未动。
import Foundation
import GatherProtocol

extension SimilarityViewModel {

    // MARK: 关键词写回（TS KeywordWritebackPanel）

    /// 中英文逗号分隔（TS `.split(/[,，]/)`）。
    public var parsedWritebackKeywords: [String] {
        writebackKeywords.split { $0 == "," || $0 == "，" }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// TS: previewWriteback/writeback 均以结果档位为参（result.stats.threshold），
    /// 草稿阈值仅用于展示与预计算档位切换。
    private var writebackThreshold: Int? {
        result.map { Int($0.stats.threshold) }
    }

    /// TS: canPreview（assignments > 0 && keywords > 0 && !busy）。
    public var canPreviewWriteback: Bool {
        !selectedGroupIds.isEmpty && !parsedWritebackKeywords.isEmpty && !isSyncBusy
    }

    /// 关键词/选择变化 → 清空旧预览、旧写回结果与同步状态视图（TS effect：
    /// setPreview(null) + setWritebackResult(null) + setSyncView(null)，按钮全禁用）。
    public func markWritebackDraftChanged() {
        writebackPreview = nil
        writebackResult = nil
        syncView = nil
    }

    public func previewKeywordWriteback() async {
        _ = await ensureWritebackPreview()
    }

    /// 写回确认准备：无预览时先生成预览（取消/失败都会写可见文案），
    /// 让确认弹窗展示真实影响范围；返回是否存在可确认的预览。
    @discardableResult
    public func prepareWritebackConfirmation() async -> WritebackPreview? {
        await ensureWritebackPreview()
    }

    /// 预览的唯一实现：给出「不发生任何写入」的影响范围。
    private func ensureWritebackPreview() async -> WritebackPreview? {
        guard canPreviewWriteback else {
            if selectedGroupIds.isEmpty {
                actionError = CommandError.localized("请选择至少一个相似度分组")
            } else if parsedWritebackKeywords.isEmpty {
                actionError = CommandError.localized("请输入要写回的关键字")
            }
            return nil
        }
        if let writebackPreview = writebackPreview { return writebackPreview }
        isSyncBusy = true
        defer { isSyncBusy = false }
        do {
            let input = try SimilarityPreviewWritebackInput(
                sessionId: sessionId,
                assignments: writebackAssignments,
                threshold: writebackThreshold
            )
            let preview = try await similarity.previewWriteback(input)
            writebackPreview = preview
            actionError = nil
            guard !preview.items.isEmpty else {
                notice = SimilarityNotice("预览没有可写回项")
                return nil
            }
            notice = SimilarityNotice(
                "预览完成：%lld 张照片将合并这些关键词。",
                params: ["\(preview.affectedPhotos)"]
            )
            return preview
        } catch {
            actionError = CommandError(error)
            // 失败提示统一走上屏错误载体（API 诊断只进 diagnostic/tooltip），
            // 不再把预本地化的错误串塞进 notice。
            notice = nil
            return nil
        }
    }

    private var writebackAssignments: [SimilarityKeywordAssignment] {
        selectedGroupIds.sorted().map { SimilarityKeywordAssignment(groupId: $0, keywords: parsedWritebackKeywords) }
    }

    /// 用户确认后执行写回（sim.writeback 是 confirmed 门控的破坏性命令；
    /// `confirmed` 只能由确认弹窗传入 true，旧实现恒 true 已删除）。
    public func executeKeywordWriteback(confirmed: Bool) async {
        guard confirmed else {
            notice = SimilarityNotice("未确认，已取消写入")
            return
        }
        guard let preview = writebackPreview, !selectedGroupIds.isEmpty, !parsedWritebackKeywords.isEmpty else {
            actionError = CommandError.localized("请先生成写回预览并确认影响范围")
            return
        }
        let ids = preview.items.compactMap(\.id)
        guard !ids.isEmpty else {
            notice = SimilarityNotice("预览没有可写回项")
            return
        }
        isSyncBusy = true
        do {
            let input = try SimilarityWritebackInput(
                sessionId: sessionId,
                itemIds: ids,
                threshold: writebackThreshold
            )
            let nextResult = try await similarity.writeback(Confirmed(input, source: .userDialog))
            writebackResult = nextResult
            // 新写入活动使会话 reload-ack 失效（DB clearReloadAck 语义）。
            reloadAcked = false
            publishMetadataChange()
            notice = SimilarityNotice(
                "XMP 写入完成：成功 %lld，失败 %lld，跳过 %lld。",
                params: ["\(nextResult.written)", "\(nextResult.failed)", "\(nextResult.skipped)"]
            )
            actionError = nil
        } catch {
            actionError = CommandError(error)
            notice = nil
        }
        isSyncBusy = false
        await reloadSyncState()
    }

    /// 重试失败项（sim.retry_failed_writeback 同为 confirmed 门控）。
    public func retryKeywordWriteback(confirmed: Bool) async {
        guard confirmed else {
            notice = SimilarityNotice("未确认，已取消重试")
            return
        }
        guard let failedItems = writebackResult?.failedItems, !failedItems.isEmpty else {
            actionError = CommandError.localized("没有可重试的失败项")
            return
        }
        isSyncBusy = true
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let nextResult = try await similarity.retryFailedWriteback(
                Confirmed(reference, source: .userDialog)
            )
            writebackResult = nextResult
            reloadAcked = false
            publishMetadataChange()
            notice = SimilarityNotice(
                "重试完成：成功 %lld，失败 %lld。",
                params: ["\(nextResult.written)", "\(nextResult.failed)"]
            )
            actionError = nil
        } catch {
            actionError = CommandError(error)
            notice = nil
        }
        isSyncBusy = false
        await reloadSyncState()
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    public func reportCancellation(_ action: LocalizedText) {
        notice = SimilarityNotice(cancelled: action)
        actionError = nil
    }

    /// 写路径统一广播：XMP/同步队列域（设置页、C1 胶囊、控制中心按域刷新）。
    private func publishMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: sessionId)
    }

    /// 第一步：Capture One 加载元数据（成功才写入持久 ack；绝不自动确认）。
    public func loadMetadataInCaptureOne() async {
        isSyncBusy = true
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            reloadAcked = true
            notice = SimilarityNotice("已在 Capture One 中加载元数据，返回后请确认同步")
            actionError = nil
        } catch {
            actionError = CommandError(error)
            notice = nil
        }
        isSyncBusy = false
        await reloadSyncState()
    }

    /// 第二步：确认同步（服务端 requireReloadAck 兜底）。
    public func confirmSync() async {
        do {
            _ = try await similarity.confirmSync(sessionId)
            publishMetadataChange()
            notice = SimilarityNotice("已确认 Capture One 完成「加载元数据」，现在可以安全清理临时 XMP 变更。")
            actionError = nil
        } catch {
            actionError = CommandError(error)
            notice = nil
        }
        await reloadSyncState()
    }

    /// 清理临时 XMP 变更（sim.cleanup 同为 confirmed 门控）。
    public func cleanupKeywordWriteback(confirmed: Bool) async {
        guard confirmed else {
            notice = SimilarityNotice("未确认，已取消清理")
            return
        }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let cleanup = try await similarity.cleanup(Confirmed(reference, source: .userDialog))
            publishMetadataChange()
            writebackResult = nil
            writebackPreview = nil
            notice = SimilarityNotice(
                "清理完成：已恢复或移除 %lld 个 sidecar 文件。",
                params: ["\(cleanup.deletedCount)"]
            )
            actionError = nil
        } catch {
            actionError = CommandError(error)
            notice = nil
        }
        await reloadSyncState()
    }

}

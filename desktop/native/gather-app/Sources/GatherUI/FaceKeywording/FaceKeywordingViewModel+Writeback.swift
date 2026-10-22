// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingViewModel+Writeback.swift
// Cut 4 / 4c-2b：写回预览/执行/重试、C1 重新加载、确认同步与清理、取消文案
// （原 FaceKeywordingView.swift 538-670 行，逐字搬移）。
import Foundation
import GatherProtocol

extension FaceKeywordingViewModel {
    public func previewWriteback() async {
        guard analysisDone else {
            errorMessage = CommandError.localized("请先完成人脸分析")
            return
        }
        do {
            let options = WritebackOptions(
                createAlbums: false,
                addPrefix: false,
                markUngrouped: false,
                writeIPTC: false
            )
            preview = try await face.preview(FacePreviewInput(
                sessionId: sessionId,
                options: options
            ))
            writebackResult = nil
            notice = FaceNotice("写回预览已生成")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 写回确认准备：无预览时先生成一次预览，让确认弹窗展示真实影响范围
    /// （绑定簇 / 受影响照片 / XMP 项与示例路径）。返回是否存在可确认的写回项。
    public func prepareWritebackConfirmation() async -> Bool {
        guard analysisDone else {
            errorMessage = CommandError.localized("请先完成人脸分析")
            return false
        }
        if preview == nil { await previewWriteback() }
        guard let preview = preview, !preview.items.isEmpty else {
            if self.preview != nil {
                errorMessage = CommandError.localized("预览没有可写回项")
            }
            return false
        }
        return true
    }

    /// TS handleExecute（StepWriteback.tsx:53-69）：用户确认后按预览项执行写回。
    /// `confirmed` 只能由确认弹窗传入 true；旧实现「无预览自动补预览 + 恒 true」
    /// 已删除（预览改由 prepareWritebackConfirmation 负责）。
    public func writeback(confirmed: Bool) async {
        guard confirmed else {
            notice = FaceNotice("未确认，已取消写回")
            return
        }
        guard let preview = preview, !preview.items.isEmpty else {
            errorMessage = CommandError.localized("请先生成写回预览并确认影响范围")
            return
        }
        isWritingBack = true
        defer { isWritingBack = false }
        do {
            let input = try FaceWritebackInput(sessionId: sessionId, items: preview.items)
            writebackResult = try await face.writeback(Confirmed(input, source: .userDialog))
            isSyncConfirmed = false
            publishChange(.metadata)
            notice = FaceNotice("已写回 %lld 项；请先让 Capture One 重新加载元数据", params: ["\(writebackResult?.written ?? 0)"])
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 重试失败项：同样是 WRITEBACK_CONFIRM_REQUIRED 门控的破坏性命令。
    public func retryFailed(confirmed: Bool) async {
        guard confirmed else {
            notice = FaceNotice("未确认，已取消重试")
            return
        }
        guard let items = writebackResult?.failedItems, !items.isEmpty else {
            errorMessage = CommandError.localized("没有可重试的失败项")
            return
        }
        do {
            let input = try FaceWritebackInput(sessionId: sessionId, items: items)
            writebackResult = try await face.writeback(Confirmed(input, source: .userDialog))
            isSyncConfirmed = false
            publishChange(.metadata)
            notice = FaceNotice("已重试失败写回项")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            notice = FaceNotice("Capture One 已重新加载元数据，现在可以确认同步")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    public func confirmSync() async {
        do {
            _ = try await face.confirmSync(sessionId)
            isSyncConfirmed = true
            publishChange(.metadata)
            notice = FaceNotice("已确认人脸关键字同步")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 清理备份：FKW_CLEANUP_CONFIRM_REQUIRED 门控，`confirmed` 只能由确认弹窗
    /// 传入 true（旧实现恒 true 已删除）。
    public func cleanup(confirmed: Bool) async {
        guard confirmed else {
            notice = FaceNotice("未确认，已取消清理")
            return
        }
        do {
            _ = try await face.cleanup(Confirmed(
                try SessionReference(sessionId: sessionId),
                source: .userDialog
            ))
            publishChange(.metadata)
            notice = FaceNotice("已清理人脸写回备份")
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 取消破坏性动作：可见文案（不静默 return，也不发命令）。
    /// Cut 4 / 4b-2b：动作本身也存 key + 参数（可能带 `#%lld` / 文件名），
    /// 由 FaceNotice 在渲染期解析。
    public func reportCancellation(_ action: LocalizedText) {
        notice = FaceNotice(cancelled: action)
        errorMessage = nil
        reviewActionError = nil
    }
}

// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Preview.swift
// Cut 4 / 4c-2f：手动预览（原 ExportView.swift 247-276）。参数快照 + 请求序号
// 与静默刷新同源，过期响应整份丢弃；正文逐字未动。
import GatherProtocol

extension ExportViewModel {
    /// 手动「预览」：B3（9-30 审查）——必须与自动刷新走**同一套**参数快照 + 请求序号，
    /// 否则「慢的手动预览 A」会覆盖「已经生效的自动预览 B」，屏幕上的清单属于旧参数，
    /// 而 isPlanStale 还认为计划有效（plannedSignature 也没被 A 更新）。
    public func previewExport() async {
        guard !destinationIsEmpty else {
            await run(isPreviewing: true) { throw GatherError(code: .EXPORT_DIR_INVALID) }
            return
        }
        let signature = planSignature
        let input: ExportInput
        do {
            input = try ExportInput(sessionId: sessionId, options: try exportOptions())
        } catch {
            fieldError = Self.fieldError(for: error)
            errorMessage = CommandError(error)
            return
        }
        planGeneration += 1
        let generation = planGeneration
        await run(isPreviewing: true) {
            let fetched = try await self.exportAPI.preview(input)
            // 过期响应（期间用户改了参数或已有更新的预览请求）整份丢弃。
            guard self.planGeneration == generation, self.planSignature == signature else { return }
            self.preview = fetched
            self.plannedSignature = signature
            self.planError = nil
            self.result = nil
            self.notice = LocalizedText("预览已更新")
        }
    }
}

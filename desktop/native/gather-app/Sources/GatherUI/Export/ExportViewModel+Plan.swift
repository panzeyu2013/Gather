// desktop/native/gather-app/Sources/GatherUI/Export/ExportViewModel+Plan.swift
// Cut 4 / 4c-2f：计划指纹、过期判断与 300ms 去抖后的静默刷新（原 278-350）。
// 计划状态本身仍声明在 ExportViewModel.swift（extension 不能新增存储属性）。
import GatherProtocol

extension ExportViewModel {
    /// 影响导出计划的全部参数指纹（N03）。
    ///
    /// 旧实现只监听范围和目录：把「变体」从首选改成 JPEG 后，页面仍显示上一个
    /// 计划的 NEF 与数量，直到手动点「预览」。凡是能改变导出文件集合的参数
    /// （范围/变体/格式/目录/命名/水印/XMP）都必须进入指纹。
    public var planSignature: String {
        let destinationKey = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let watermarkKey = (watermarkEnabled && transformsAllowed)
            ? "w:\(watermarkText):\(watermarkPosition.rawValue):\(watermarkOpacity):\(watermarkFontSize)"
            : "w:-"
        return [
            scope.rawValue,
            variantPolicy.rawValue,
            format.rawValue,
            destinationKey,
            namingPattern,
            includeXmp ? "xmp:1" : "xmp:0",
            watermarkKey,
        ].joined(separator: "|")
    }

    /// 当前屏幕上的计划是否已经过期（参数变过但还没重算完）。
    public var isPlanStale: Bool {
        preview == nil || plannedSignature != planSignature
    }

    /// 视图的 300ms 去抖一调度就置位（refreshPlan 开始时清位）。
    func markPlanRefreshScheduled() {
        isPlanRefreshScheduled = true
    }

    /// 静默刷新导出计划（F04 / N03）：任何影响计划的参数变化后重算
    /// 「本次将导出多少张 + 文件清单」。
    ///
    /// 与 previewExport 的区别：不改写 notice、不弹错误横幅，失败只在范围区
    /// 行内说明。先把上一次的 preview 作废——宁可短暂显示「正在计算」，
    /// 也不能把旧参数的文件数留在屏幕上冒充当前选择。
    public func refreshPlan() async {
        isPlanRefreshScheduled = false
        preview = nil
        plannedSignature = nil
        planError = nil
        guard !destinationIsEmpty else { return }
        let signature = planSignature
        planGeneration += 1
        let generation = planGeneration
        isPlanning = true
        defer { if planGeneration == generation { isPlanning = false } }
        do {
            let input = try ExportInput(sessionId: sessionId, options: try exportOptions())
            let fetched = try await exportAPI.preview(input)
            // 过期响应（用户已经改了参数）直接丢弃，绝不覆盖更新的选择。
            guard planGeneration == generation, planSignature == signature else { return }
            preview = fetched
            plannedSignature = signature
            result = nil
        } catch {
            guard planGeneration == generation, planSignature == signature else { return }
            planError = CommandError(error)
        }
    }
}

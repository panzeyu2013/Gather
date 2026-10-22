// desktop/native/gather-app/Sources/GatherUI/Export/ExportConfirmation.swift
// Cut 4 / 4c-2f：从 ExportView.swift 原样迁出（原 626-669）。
// 「开始导出」确认载荷：弹窗文案的事实来源（目的地 + 范围 + 本次将写入的文件数）。
// 形状、id 语义（scopeLabel.key）与 scopeLabel(for:) 逐字未动。
import GatherProtocol

/// 「开始导出」确认载荷：弹窗文案的事实来源（目的地 + 范围 + 本次将写入的文件数）。
public struct ExportConfirmation: Equatable, Identifiable {
    public var destination: String
    public var fileCount: Int
    /// 范围文案（F04）：导出范围必须出现在确认文案里，不能让用户靠猜。
    /// Cut 4 / 4b-2h：改存 LocalizedText（key + 参数），由 View 在渲染期按当前
    /// 语言解析；切语言后重绘即可换文案，VM 不预先解析。
    public var scopeLabel: LocalizedText
    /// 计划指纹（D03）：确认的是**哪一份计划**；执行前参数若已变化，这份确认作废。
    public var planSignature: String
    /// **冻结的导出参数**（D03，ExportOptions）：确认后执行的就是这一份，
    /// 不再重新读界面状态。
    ///
    /// 旧实现只保存展示用的目录/数目/范围文案，确认回调再调 executeExport，由它
    /// 重新读一遍 ViewModel 的可变参数：用户在预览等待期间改了目录或范围，
    /// 弹窗显示「新目录 + 旧文件数」，执行的又是第三份参数。
    public var request: ExportOptions
    /// 身份用 scopeLabel.key（而不是解析后的译文）：id 不随界面语言变化，
    /// 切语言导致的等值判断/弹窗重建不会把同一份确认当成不同载荷。
    public var id: String { destination + "|" + scopeLabel.key + "|" + planSignature }

    public init(
        destination: String,
        fileCount: Int,
        scopeLabel: LocalizedText,
        planSignature: String,
        request: ExportOptions
    ) {
        self.destination = destination
        self.fileCount = fileCount
        self.scopeLabel = scopeLabel
        self.planSignature = planSignature
        self.request = request
    }

    /// Cut 4 / 4b-2h：返回延迟本地化文本（确认弹窗、范围 Picker、VM 的确认载荷共用）。
    public static func scopeLabel(for scope: ExportScope) -> LocalizedText {
        switch scope {
        case .filtered: return LocalizedText("保留片（挑片决策为保留）")
        case .session: return LocalizedText("工作区全部照片")
        case .selected: return LocalizedText("所选照片")
        }
    }
}

// 共享写回报告组件：对齐旧版 WritebackReport.tsx —— 三色统计卡（已写入/
// 失败/已跳过）+ 失败项明细（路径 + 错误码翻译），供 FaceKw/Similarity/
// Culling 三处统一复用，消除实现分裂。
import SwiftUI
import GatherProtocol

public struct WritebackFailureItem: Identifiable, Equatable {
    public let id: String
    public let path: String
    public let message: String

    public init(id: String, path: String, message: String) {
        self.id = id
        self.path = path
        self.message = message
    }
}

public struct WritebackReportCard: View {
    public let written: Int
    public let failed: Int
    public let skipped: Int
    public let failedItems: [WritebackFailureItem]

    /// Cut 4 / 4b-1：失败项错误码在渲染期按当前语言解析（外壳已注入 store；
    /// 独立 Preview/测试无 store 时按默认中文渲染）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// 已跳过卡的颜色（统一为警告语义色）。
    public var skippedColor: Color = GatherTheme.warning

    public init(
        written: Int,
        failed: Int,
        skipped: Int,
        failedItems: [WritebackFailureItem],
        skippedColor: Color = GatherTheme.warning
    ) {
        self.written = written
        self.failed = failed
        self.skipped = skipped
        self.failedItems = failedItems
        self.skippedColor = skippedColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GatherStatCard(value: written, label: l10n("已写入"), color: GatherTheme.success)
                GatherStatCard(value: failed, label: l10n("失败"), color: GatherTheme.error)
                GatherStatCard(value: skipped, label: l10n("已跳过"), color: skippedColor)
            }
            if !failedItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.format("失败项（%lld）", failedItems.count))
                        .font(.callout.weight(.semibold))
                    ForEach(failedItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(item.path)
                            Spacer(minLength: 8)
                            if !item.message.isEmpty {
                                Text(l10n.errorText(item.message))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        if item.id != failedItems.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                        .fill(GatherTheme.error.opacity(0.08))
                )
            }
        }
    }
}

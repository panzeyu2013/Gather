// 共享写回报告组件：对齐旧版 WritebackReport.tsx —— 三色统计卡（已写入/
// 失败/已跳过）+ 失败项明细（路径 + 错误码翻译），供 FaceKw/Similarity/
// Culling 三处统一复用，消除实现分裂。
import SwiftUI
import GatherCore

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
                GatherStatCard(value: written, label: GatherLocalization.l("已写入"), color: GatherTheme.success)
                GatherStatCard(value: failed, label: GatherLocalization.l("失败"), color: GatherTheme.error)
                GatherStatCard(value: skipped, label: GatherLocalization.l("已跳过"), color: skippedColor)
            }
            if !failedItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: GatherLocalization.l("失败项（%lld）"), failedItems.count))
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
                                Text(GatherLocalization.errorText(item.message))
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

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
    /// 已跳过卡的颜色（FaceKw=橙、Similarity=灰，按旧版各页原样）。
    public var skippedColor: Color = .gray

    public init(
        written: Int,
        failed: Int,
        skipped: Int,
        failedItems: [WritebackFailureItem],
        skippedColor: Color = .gray
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
                statCard(value: written, label: "已写入", color: GatherTheme.success)
                statCard(value: failed, label: "失败", color: GatherTheme.error)
                statCard(value: skipped, label: "已跳过", color: skippedColor)
            }
            if !failedItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("失败项（\(failedItems.count)）")
                        .font(.caption.weight(.semibold))
                    ForEach(failedItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.path)
                                .font(.caption)
                                .lineLimit(1)
                                .help(item.path)
                            Spacer(minLength: 8)
                            if !item.message.isEmpty {
                                Text(GatherLocalization.errorText(item.message))
                                    .font(.caption)
                                    .foregroundStyle(GatherTheme.error)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.error.opacity(0.06)))
            }
        }
    }

    private func statCard(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 28, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.backgroundSecondary))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gatherBorder.opacity(0.6), lineWidth: 0.5))
    }
}

// desktop/native/gather-app/Sources/GatherUI/Culling/C1HotFolderNotice.swift
// Wave3 / task-18（G12）：C1 Hot Folder 的**能力边界**提示。
//
// C1 16.7 sdef 没有读取 Hot Folder 设置的命令/属性（本机字典核对：无 hot folder 术语），
// 因此 Gather 无法检测目标目录是否被 C1 监视。这里只做风险提示，绝不假装检测到
//（C1HotFolderCaveat.canDetect 固定 false，用例守护）。
import SwiftUI
import GatherProtocol

/// Hot Folder 协同的风险提示（摄取目的地 / 淘汰移出共用）。
struct C1HotFolderNotice: View {
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        HStack(alignment: .top, spacing: GatherMetrics.Space.xs) {
            Image(systemName: "questionmark.circle")
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(l10n("Capture One Hot Folder 未检测：C1 不提供读取该设置的接口；若该目录被 C1 监视，导入或移出可能重复。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

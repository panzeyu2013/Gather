// desktop/native/gather-app/Sources/GatherUI/Culling/CullingConflictPanel.swift
// Cut 4 / 4c-2a：浮动冲突面板 + 失败写回清单（原 CullingView.swift 2588-2741 行）。
// 每次展示一个冲突，应用后进入下一个；所有出口仍经确认弹窗（pendingAction）。
import SwiftUI
import GatherProtocol

// MARK: 浮动冲突面板（对齐旧版 .conflictPanel：每次展示一个冲突，应用后进入下一个）。
struct CullingConflictPanel: View {
    let viewModel: CullingViewModel
    @Binding var pendingAction: PendingCullingAction?
    @Binding var conflictChoices: [String: MetadataConflictChoice]

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if viewModel.conflicts.first != nil || !viewModel.failedSyncItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let conflict = viewModel.conflicts.first {
                    conflictBlock(conflict)
                }
                if !viewModel.failedSyncItems.isEmpty {
                    if viewModel.conflicts.first != nil { Divider() }
                    failureBlock
                }
            }
            .gatherCard()
            .shadow(color: GatherTheme.shadowFloating, radius: 16, y: 8)
        }
    }

    /// 单个冲突：展示逐字段差异 + 失败原因 + 两条无障碍出口
    /// （采用外部值 / 保留 Gather 并显式结清）。所有出口都经确认弹窗。
    @ViewBuilder
    private func conflictBlock(_ conflict: MetadataConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(l10n("XMP 字段冲突"), systemImage: "exclamationmark.triangle.fill")
                    .font(GatherFont.cardTitle)
                    .foregroundStyle(GatherTheme.errorText)
                Spacer()
                Text(URL(fileURLWithPath: conflict.xmpPath).lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(conflict.xmpPath)
            }
            if let reason = viewModel.syncFailureReason(xmpPath: conflict.xmpPath, with: l10n) {
                Text(l10n.format("原因：%@", reason))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .lineLimit(3)
                    .help(reason)
            }
            if conflict.fields.isEmpty {
                Text(l10n("该冲突行没有可逐字段裁决的差异：直接结清即可（保留 Gather 值并以当前磁盘状态为新基线重写）。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(conflict.fields, id: \.field.rawValue) { field in
                let key = "\(conflict.xmpPath)|\(field.field.rawValue)"
                HStack(spacing: 8) {
                    Text(CullingDisplayFormat.metadataFieldTitle(field.field, with: l10n))
                        .font(GatherFont.secondaryStrong)
                        .frame(minWidth: 64, alignment: .leading)
                    Text(l10n.format("Gather：%@", CullingDisplayFormat.valueLabel(field.local, with: l10n)))
                        .font(.callout)
                        .lineLimit(1)
                        .help(CullingDisplayFormat.valueLabel(field.local, with: l10n))
                    Text(l10n.format("外部：%@", CullingDisplayFormat.valueLabel(field.remote, with: l10n)))
                        .font(.callout)
                        .lineLimit(1)
                        .help(CullingDisplayFormat.valueLabel(field.remote, with: l10n))
                    Picker(l10n("处理"), selection: Binding(
                        get: { conflictChoices[key] ?? .keepLocal },
                        set: { conflictChoices[key] = $0 }
                    )) {
                        Text(l10n("保留 Gather")).tag(MetadataConflictChoice.keepLocal)
                        Text(l10n("采用外部值")).tag(MetadataConflictChoice.useRemote)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(l10n("冲突处理方式"))
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                        .fill(GatherTheme.secondaryContentBackground)
                )
            }
            HStack {
                Text(viewModel.conflicts.count > 1
                    ? l10n.format("还有 %lld 个冲突", viewModel.conflicts.count - 1)
                    : l10n("这是最后一个冲突"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l10n("采用外部值")) {
                    pendingAction = .resolveConflict(conflict, choicesForConflict(conflict, .useRemote))
                }
                .help(l10n("丢弃 Gather 待写入值，接受磁盘上的外部修改"))
                Button(l10n("保留 Gather 并结清")) {
                    // 空 choices = 显式结清（coordinator 的第三条出口），字段为空时同样可达。
                    pendingAction = .resolveConflict(conflict, [:])
                }
                .help(l10n("把 Gather 的值写回 XMP，以当前磁盘状态为新基线"))
                if !conflict.fields.isEmpty {
                    Button(l10n("应用选择并继续写入")) {
                        pendingAction = .resolveConflict(conflict, selectedChoices(conflict))
                    }
                }
            }
        }
    }

    /// 失败写回清单：逐条展示路径与 coordinator 写入的真实原因 + 重试出口。
    private var failureBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.format("写回失败 %lld 项", viewModel.failedSyncItems.count))
                    .font(GatherFont.cardTitle)
                    .foregroundStyle(GatherTheme.errorText)
                Spacer()
                Button(l10n("重试失败项")) { pendingAction = .retryFailedWriteback }
            }
            ForEach(Array(viewModel.failedSyncItems.prefix(3)), id: \.xmpPath) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                        .font(.callout.weight(.medium))
                    // 上屏走错误码漏斗；原始诊断已由 applySyncStatus 写日志。
                    Text(item.errorMessage.isEmpty
                        ? l10n("未记录原因")
                        : CullingViewModel.funnelErrorText(item.errorMessage, with: l10n))
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.errorText)
                        .lineLimit(3)
                        .help(item.errorMessage.isEmpty ? "" : CullingViewModel.funnelErrorText(item.errorMessage, with: l10n))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                        .fill(GatherTheme.secondaryContentBackground)
                )
            }
            if viewModel.failedSyncItems.count > 3 {
                Text(l10n.format("另有 %lld 项失败", viewModel.failedSyncItems.count - 3))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choicesForConflict(
        _ conflict: MetadataConflict,
        _ choice: MetadataConflictChoice
    ) -> [MetadataField: MetadataConflictChoice] {
        Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) })
    }

    private func selectedChoices(_ conflict: MetadataConflict) -> [MetadataField: MetadataConflictChoice] {
        Dictionary(uniqueKeysWithValues: conflict.fields.map { field in
            (field.field, conflictChoices["\(conflict.xmpPath)|\(field.field.rawValue)"] ?? .keepLocal)
        })
    }
}

// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceReviewMemberRowView.swift
// P0 / F0：复核成员行（FaceReviewItem 驱动）。
//
// 与旧 MemberRowView 的差异：复选框（可拆分选择）、cohesion、低质量/小脸/未解析/
// 模型不兼容徽标；移除按钮仍走确认弹窗。
import SwiftUI
import GatherProtocol

struct FaceReviewMemberRowView: View {
    let item: FaceReviewItem
    let isSelected: Bool
    let focusedMemberId: FocusState<Int?>.Binding
    let onToggle: () -> Void
    let onRemove: () -> Void

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var cohesionText: String {
        guard item.cohesion >= 0 else { return l10n("未解析") }
        return String(format: "%.2f", item.cohesion)
    }

    private var selectionLabel: String {
        l10n.format("选择成员 %@，与簇中心相似度 %@", item.filename, cohesionText)
    }

    var body: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(GatherFont.bodyStrong)
                    .foregroundStyle(isSelected ? GatherTheme.accent : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n("选择该成员用于拆分"))
            .accessibilityLabel(selectionLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            FaceCropThumbnailView(path: item.photoPath, bbox: item.bbox, loadSize: 256)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                Text(item.filename)
                    .font(GatherFont.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: GatherMetrics.Space.xs) {
                    Text(l10n.format("与簇中心相似度 %@", cohesionText))
                        .font(GatherFont.label)
                        .foregroundStyle(.secondary)
                    ForEach(item.flags, id: \.rawValue) { flag in
                        flagChip(flag)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(minWidth: 24, minHeight: 24)
            .help(l10n.format("从簇中移除成员 %@", item.filename))
            .accessibilityLabel(l10n.format("从簇中移除成员 %@", item.filename))
        }
        .padding(EdgeInsets(top: GatherMetrics.Space.xs, leading: 0, bottom: GatherMetrics.Space.xs, trailing: 0))
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .focusable()
        .focused(focusedMemberId, equals: item.memberId)
        .onKeyPress(.space) {
            onToggle()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isSelected ? l10n("已选择") : l10n("未选择"))
    }

    @ViewBuilder
    private func flagChip(_ flag: FaceReviewFlag) -> some View {
        Text(flagTitle(flag))
            .font(GatherFont.label)
            .foregroundStyle(flag == .suspect ? GatherTheme.warningText : .secondary)
            .padding(EdgeInsets(top: GatherMetrics.Space.xxs, leading: GatherMetrics.Space.xs, bottom: GatherMetrics.Space.xxs, trailing: GatherMetrics.Space.xs))
            .background(
                Capsule().fill(
                    flag == .suspect
                        ? GatherTheme.warning.opacity(0.12)
                        : GatherTheme.surfaceMuted
                )
            )
    }

    private func flagTitle(_ flag: FaceReviewFlag) -> String {
        switch flag {
        case .suspect: return l10n("待复核")
        case .lowQuality: return l10n("低质量")
        case .smallFace: return l10n("小脸")
        case .unresolvedObservation: return l10n("未解析")
        case .incompatibleModel: return l10n("模型不兼容")
        }
    }
}

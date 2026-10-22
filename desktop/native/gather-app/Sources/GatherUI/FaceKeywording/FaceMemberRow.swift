// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceMemberRow.swift
// Cut 4 / 4c-2b：成员行（原 2065-2135 行，逐字搬移）。
// @FocusState 仍与 MemberRowView 内 .focused($isFocused) 同一调用位置。
import SwiftUI
import GatherProtocol

struct MemberRowView: View {
    let index: Int
    let member: ClusterMember
    let onRemove: () -> Void

    @State private var isHovered = false
    /// 键盘焦点：F12 —— 只在 hover 时显示动作会让纯键盘用户看不到入口。
    @FocusState private var isFocused: Bool

    // Cut 4 / 4b-2b：语言源由外壳经 environment 下发（页面内的独立子视图）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var confidenceText: String {
        String(format: "%.0f%%", member.confidence * 100)
    }

    var body: some View {
        HStack(spacing: 8) {
            // F05：成员行也给人脸裁切——文件名 + 百分比无法回答
            //「这两张脸是不是同一个人」，同一张照片的两张脸尤其难分辨。
            FaceCropThumbnailView(path: member.photoPath, bbox: member.bbox, loadSize: 256)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
            Text("#\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
                .accessibilityHidden(true)
            Text(member.filename)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 置信度只朗读一次（F12）：文字本身对无障碍隐藏，由 label 提供
            // 带单位的唯一描述，避免「85%」+「置信度 85%」被读两遍。
            Text(confidenceText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(l10n.format("置信度 %@", confidenceText))
            // 移除不可逆：悬停 **或键盘焦点** 任一状态都可见（命中区 ≥24pt）
            // + 右键菜单第二入口；旧实现只在 hover 显现（F12）。
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(minWidth: 24, minHeight: 24)
            .opacity(isHovered || isFocused ? 1 : 0)
            .focused($isFocused)
            .accessibilityLabel(l10n.format("从簇中移除成员 %@", member.filename))
            .help(l10n.format("从簇中移除成员 %@", member.filename))
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(l10n("移除成员"), role: .destructive) { onRemove() }
        }
        // F12：不再 children: .combine —— 合并后整行只剩一个文本元素，
        // 移除动作对 VoiceOver 不可达。用 .contain 暴露子元素（文件名、
        // 置信度、移除按钮各是一个可用元素）。
        .accessibilityElement(children: .contain)
    }
}

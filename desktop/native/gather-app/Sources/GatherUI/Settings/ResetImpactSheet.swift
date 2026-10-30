// desktop/native/gather-app/Sources/GatherUI/Settings/ResetImpactSheet.swift
// P1-5：恢复默认的影响面预览与分级选择。
import SwiftUI
import GatherProtocol

struct ResetImpactSheet: View {
    let impact: SettingsResetImpact
    let onConfirm: (_ preferences: Bool, _ userContent: Bool, _ language: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var resetPreferences = true
    @State private var resetUserContent = false
    @State private var resetLanguage = false
    @State private var acknowledgeUserContent = false

    private var canConfirm: Bool {
        guard resetPreferences || resetUserContent || resetLanguage else { return false }
        return !resetUserContent || acknowledgeUserContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.l) {
            Text(l10n("恢复默认设置"))
                .font(GatherFont.pageTitle)
            Text(l10n("选择要重置的范围。未勾选的内容会保留。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)

            Toggle(l10n.format("偏好设置（%lld 项）", impact.preferenceCount),
                   isOn: $resetPreferences)
                .toggleStyle(.checkbox)

            Toggle(l10n("用户内容"), isOn: $resetUserContent)
                .toggleStyle(.checkbox)
            Text(l10n.format(
                "元数据模板 %lld 个 / 批次历史 %lld 条 / 交付配方 %lld 个 / 交付目录与备份目录设置",
                impact.templateCount, impact.batchCount, impact.recipeCount))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .padding([.leading], GatherMetrics.Space.xl)

            if resetUserContent {
                Text(l10n("用户内容一旦清除不可恢复。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.error)
                    .padding([.leading], GatherMetrics.Space.xl)
                Toggle(l10n("我了解这些内容不可恢复"), isOn: $acknowledgeUserContent)
                    .toggleStyle(.checkbox)
                    .padding([.leading], GatherMetrics.Space.xl)
            }

            Toggle(l10n("同时重置界面语言"), isOn: $resetLanguage)
                .toggleStyle(.checkbox)

            Divider()

            HStack(spacing: GatherMetrics.Space.s) {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: resetUserContent ? .destructive : nil) {
                    onConfirm(resetPreferences, resetUserContent, resetLanguage)
                    dismiss()
                } label: {
                    Text(l10n("恢复默认"))
                }
                // 破坏性动作不接裸 Return：误按回车会清空偏好（F-P1-4）。
                // 用 ⌘↩ 保留键盘可达性（FKA 关闭时 Tab 到不了按钮，只有 Esc 可退）。
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canConfirm)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(width: 520)
    }
}

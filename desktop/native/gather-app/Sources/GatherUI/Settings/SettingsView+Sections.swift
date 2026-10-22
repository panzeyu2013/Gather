// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+Sections.swift
// Cut 4 / 4c-2d：顶部提示条、保存规则说明与语言分组（原 SettingsView.swift
// 1415-1452、1754-1773 行）。纯搬移：Section 层级、文案与控件宽度不变。
import SwiftUI
import GatherProtocol

extension SettingsView {

    // MARK: 提示条

    @ViewBuilder
    var banners: some View {
        if viewModel.errorMessage != nil || viewModel.notice != nil {
            Section {
                if let error = viewModel.errorMessage {
                    NativeBanner(
                        text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.error
                    )
                }
                if let notice = viewModel.notice {
                    NativeBanner(
                        text: l10n.resolve(notice),
                        systemImage: "checkmark.circle.fill",
                        color: GatherTheme.success
                    )
                }
            }
        }
    }

    // MARK: 保存规则说明（F11）

    /// 统一保存规则说明：文本/数字「离开输入框或回车」保存，选择项立即保存，
    /// 每次保存都有「已保存 X」提示。用户不必先猜回车语义再改设置。
    var saveRuleHint: some View {
        Section {
            Label(
                l10n("文本与数字在离开输入框或按回车时保存；下拉选择立即保存，结果会显示在顶部提示条。"),
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
    // MARK: 语言

    var languageSection: some View {
        Section(l10n("语言")) {
            LabeledContent(l10n("界面语言")) {
                Picker("", selection: Binding(
                    get: { viewModel.language },
                    set: { viewModel.setLanguage($0) }
                )) {
                    Text(l10n("简体中文")).tag("zh-CN")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Text(l10n("切换语言后菜单与全部页面文案立即更新，并持久化保存。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

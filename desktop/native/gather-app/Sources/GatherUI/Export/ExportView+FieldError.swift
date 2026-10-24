// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+FieldError.swift
// Cut 4 / 4c-2f：行内错误行（原 ExportView.swift 1071-1082）。
// Banner 保留，对应字段附近再重复提示一次以就近定位；文案与样式逐字未动。
import SwiftUI

struct ExportFieldErrorText: View {
    let field: ExportViewModel.ExportFieldError
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if viewModel.fieldError == field, let message = viewModel.errorMessage {
            Text(CommandErrorText.resolve(message, with: l10n))
                .font(.callout)
                .foregroundStyle(GatherTheme.errorText)
        }
    }
}

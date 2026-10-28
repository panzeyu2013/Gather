// desktop/native/gather-app/Sources/GatherUI/Export/WebDAVPublishSheet.swift
// W3b：发布到用户自备 WebDAV（凭据进 Keychain，密码不回显、不落日志）。
import SwiftUI
import GatherProtocol

struct WebDAVPublishSheet: View {
    let viewModel: ExportViewModel
    let localPath: String
    let includePrefixes: [String]?
    @Environment(\.languageStore) private var languageStore
    @Environment(\.dismiss) private var dismiss
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remoteFolder = "gather"
    /// 发布任务句柄：面板关闭/点「停止发布」时必须能取消，否则上传会在后台继续。
    @State private var publishTask: Task<Void, Never>?

    private var isURLValid: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("发布到 WebDAV")).font(GatherFont.sectionTitle)
            Text(l10n("凭据保存在钥匙串；上传的是本机交付目录。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            TextField(l10n("服务器地址（https://…）"), text: $baseURL)
                .textFieldStyle(.roundedBorder)
            if !baseURL.isEmpty, !isURLValid {
                Text(l10n("地址必须以 http:// 或 https:// 开头"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
            }
            TextField(l10n("用户名"), text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField(l10n("密码"), text: $password)
                .textFieldStyle(.roundedBorder)
            TextField(l10n("远端目录"), text: $remoteFolder)
                .textFieldStyle(.roundedBorder)
            Text(localPath)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress = viewModel.publishProgress {
                Text(l10n.format("已上传 %lld / %lld", progress.done, progress.total))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            // 失败必须在这个面板里可见：旧实现把错误留在背后的导出页，
            // 面板不动、按钮恢复可点，用户分不清是地址错还是密码错。
            if let error = viewModel.errorMessage {
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error)
            }
            if let notice = viewModel.notice {
                NativeBanner(text: l10n.resolve(notice), color: GatherTheme.warning)
            }
            HStack {
                Spacer()
                Button(l10n("取消")) {
                    publishTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if viewModel.isPublishing {
                    Button(l10n("停止发布")) { publishTask?.cancel() }
                }
                Button(viewModel.isPublishing ? l10n("正在发布…") : l10n("发布")) {
                    publishTask = Task {
                        await viewModel.publishToWebDAV(
                            localPath: localPath, baseURL: baseURL,
                            username: username, password: password, remoteFolder: remoteFolder,
                            includePrefixes: includePrefixes)
                        // 仅在真的产生了发布结果时关闭；失败/取消留在面板里看原因。
                        if viewModel.webDAVPublish != nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .gatherPrimaryActionButton()
                .disabled(viewModel.isPublishing || !isURLValid)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 420)
        .onDisappear { publishTask?.cancel() }
    }
}

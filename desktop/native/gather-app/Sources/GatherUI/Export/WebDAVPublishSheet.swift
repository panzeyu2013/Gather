// desktop/native/gather-app/Sources/GatherUI/Export/WebDAVPublishSheet.swift
// W3b / Wave3 task-17：发布交付包到用户自备 WebDAV 或 S3 兼容对象存储。
//
// 边界：不做服务端托管（本机不起 web 服务），发布是"把静态文件写到你提供的存储"；
// 口令/到期只是静态校样页的纯前端门槛与提示，不是加密、也没有服务端强制。
// 凭据：secret 只写 Keychain（S3 复用 WebDAV 凭据通道：endpoint + accessKeyID 作为键）；
// 明文只在本面板内的 SecureField 里，不写日志、不进 share.json。
import AppKit
import SwiftUI
import GatherProtocol

struct WebDAVPublishSheet: View {
    let viewModel: ExportViewModel
    let localPath: String
    /// 本次交付的精确产物清单（空 = 无法确定，禁止发布）。
    let includePrefixes: [String]
    /// Wave5：独立发布入口（不依赖本次交付的内存 result）：成功后不自动关闭。
    var standalone: Bool = false
    /// Wave5：显示发布历史（从交付目录的发布记录读取；跨重启可见）。
    var showsHistory: Bool = true
    @Environment(\.languageStore) private var languageStore
    @Environment(\.dismiss) private var dismiss
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// Wave5：本地发布记录（最近 5 次）。
    @State private var history: [WebDAVPublishHistoryEntry] = []

    @State private var transport: OutputShareTransportKind = .webdav
    @State private var endpoint = ""
    @State private var username = ""
    @State private var secret = ""
    /// S3 可选 STS/Session Token（与 secret 同一条 Keychain item；WebDAV 不用）。
    @State private var sessionToken = ""
    @State private var remoteFolder = "gather"
    @State private var bucket = ""
    @State private var region = "us-east-1"
    @State private var allowDownload = false
    /// 校样页口令（可选；哈希进 share.json，明文不落盘）。
    @State private var proofPassword = ""
    @State private var useExpiry = false
    @State private var expiryDate = Date().addingTimeInterval(7 * 24 * 3600)
    /// 发布任务句柄：面板关闭/点「停止发布」时必须能取消，否则上传会在后台继续。
    @State private var publishTask: Task<Void, Never>?

    // MARK: - 校验

    private var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRemoteFolder: String {
        remoteFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedBucket: String {
        bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRegion: String {
        region.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasAllowlist: Bool { !includePrefixes.isEmpty }

    private var endpointIsValid: Bool {
        // WebDAV 必填；S3 endpoint 可空（AWS 默认由 bucket+region 推导）。
        if transport == .s3, trimmedEndpoint.isEmpty { return true }
        return trimmedEndpoint.hasPrefix("http://") || trimmedEndpoint.hasPrefix("https://")
    }

    private var s3FieldsAreValid: Bool {
        transport != .s3 || !trimmedBucket.isEmpty
    }

    private var proofExpiresAt: String? {
        guard useExpiry else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: expiryDate)
    }

    private var shareOptions: OutputShareOptions {
        OutputShareOptions(
            allowDownload: allowDownload,
            expiresAt: proofExpiresAt,
            remoteSubfolder: trimmedRemoteFolder,
            password: proofPassword.isEmpty ? nil : proofPassword)
    }

    private var validationMessage: String? {
        if !hasAllowlist {
            return l10n("无法确定发布清单（缺少成品清单）：已禁用发布。")
        }
        if !endpointIsValid {
            return l10n("地址必须以 http:// 或 https:// 开头")
        }
        if !s3FieldsAreValid {
            return l10n("S3 兼容存储需要填写 Bucket")
        }
        guard let issue = shareOptions.validationIssue() else { return nil }
        switch issue {
        case .expiresAtInvalid:
            return l10n("到期时间格式不合法（需要 ISO-8601）")
        case .expiresAtInPast:
            return l10n("到期时间必须晚于现在")
        case .passwordLengthInvalid:
            return l10n("口令长度必须在 4 到 128 之间")
        case .remoteSubfolderInvalid:
            return l10n("远端目录不能是绝对路径，也不能包含 ..")
        }
    }

    private var canPublish: Bool {
        hasAllowlist && endpointIsValid && s3FieldsAreValid && validationMessage == nil
    }

    private func categoryLabel(_ category: OutputShareFailureCategory) -> String {
        switch category {
        case .auth: return l10n("认证失败（凭据错误或无权限）")
        case .notFound: return l10n("目标不存在（桶/目录/网络）")
        case .network: return l10n("网络错误（可重试）")
        case .server: return l10n("服务端错误（可重试）")
        case .validation: return l10n("参数或目标配置错误")
        case .localIO: return l10n("本地文件读取失败")
        case .unknown: return l10n("未知错误")
        }
    }

    private var failureSummary: String? {
        guard let result = viewModel.webDAVPublish, !result.isSuccess else { return nil }
        let counts = result.failureCategories
        let parts = OutputShareFailureCategory.allCases.compactMap { category -> String? in
            guard let count = counts[category] else { return nil }
            return "\(categoryLabel(category)) ×\(count)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "；")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(standalone
                 ? l10n("发布已生成的交付包")
                 : (transport == .webdav ? l10n("发布到 WebDAV") : l10n("发布交付包")))
                .font(GatherFont.sectionTitle)
            Text(l10n("凭据保存在钥匙串；只上传本次交付的产物，不会上传整个目录。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            Text(l10n("发布只是把静态文件写进你自备的存储；应用不托管服务端，也不起本地 web 服务。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            Picker(l10n("传输方式"), selection: $transport) {
                Text(l10n("WebDAV")).tag(OutputShareTransportKind.webdav)
                Text(l10n("S3 兼容存储")).tag(OutputShareTransportKind.s3)
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isPublishing)

            if transport == .webdav {
                TextField(l10n("服务器地址（https://…）"), text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField(l10n("用户名"), text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField(l10n("密码"), text: $secret)
                    .textFieldStyle(.roundedBorder)
                Text(l10n("留空 = 沿用已保存的凭据"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                TextField(l10n("远端目录"), text: $remoteFolder)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(l10n("Endpoint（可留空 = AWS 默认）"), text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField(l10n("Bucket"), text: $bucket)
                    .textFieldStyle(.roundedBorder)
                TextField(l10n("Region"), text: $region)
                    .textFieldStyle(.roundedBorder)
                TextField(l10n("Access Key ID"), text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField(l10n("Secret Access Key"), text: $secret)
                    .textFieldStyle(.roundedBorder)
                SecureField(l10n("Session Token（可选，临时凭据）"), text: $sessionToken)
                    .textFieldStyle(.roundedBorder)
                Text(l10n("留空 = 沿用已保存的凭据"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                Text(l10n("临时凭据（IAM role/SSO）需要 Session Token；它只进钥匙串，不落 settings/日志。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                TextField(l10n("远端前缀"), text: $remoteFolder)
                    .textFieldStyle(.roundedBorder)
                Text(l10n("Secret 只进钥匙串，不会写进日志或 share.json；对象默认私有，不开启公开读。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            }

            Toggle(l10n("允许下载大图与成片"), isOn: $allowDownload)
                .disabled(viewModel.isPublishing)
            Text(allowDownload
                 ? l10n("客户可在画廊里看大图，也能直接下载成片。")
                 : l10n("只上传缩略图与校样页，客户看不到大图/成片；灯箱清晰度会降低。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)

            Divider()

            Text(l10n("校样页口令与有效期（可选）")).font(GatherFont.labelRegular)
            SecureField(
                l10n("访问口令（留空 = 不设口令；最少 4 位）"), text: $proofPassword)
                .textFieldStyle(.roundedBorder)
            Text(l10n("口令只防随手翻阅，页面不是加密的；share.json 只保存带盐的 PBKDF2 哈希，明文不落盘。"))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            Toggle(l10n("设置有效期"), isOn: $useExpiry)
                .disabled(viewModel.isPublishing)
            if useExpiry {
                DatePicker(
                    selection: $expiryDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text(l10n("有效期至"))
                }
                Text(l10n("到期后校样页显示只读过期态并禁止提交；没有服务端强制，服务器上的文件不会自动删除。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            }

            if hasAllowlist {
                Text(l10n.format("本次将发布 %lld 项产物", includePrefixes.count))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            Text(localPath)
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let message = validationMessage {
                NativeBanner(text: message, color: GatherTheme.warning)
            }
            if let progress = viewModel.publishProgress {
                Text(l10n.format("已上传 %lld / %lld", progress.done, progress.total))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            // 失败必须在这个面板里可见，并给出分类（认证/网络/服务端/目标不存在）。
            if let error = viewModel.errorMessage {
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error)
            }
            if let summary = failureSummary {
                NativeBanner(text: summary, color: GatherTheme.error)
            }
            if let notice = viewModel.notice {
                NativeBanner(text: l10n.resolve(notice), color: GatherTheme.warning)
            }
            // Wave5：发布结果（含客户链接/跳过计数）与本次目录的发布历史。
            if let result = viewModel.webDAVPublish {
                SharePublishResultView(publish: result)
            }
            if showsHistory {
                historySection
            }
            HStack {
                Spacer()
                Button(l10n("取消")) {
                    publishTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .gatherButton(.secondary)
                if viewModel.isPublishing {
                    Button(l10n("停止发布")) { publishTask?.cancel() }
                        .gatherButton(.secondary)
                }
                Button(viewModel.isPublishing ? l10n("正在发布…") : l10n("发布")) {
                    publishTask = Task {
                        await viewModel.publishToWebDAV(
                            localPath: localPath,
                            transport: transport,
                            endpoint: trimmedEndpoint,
                            accessKeyID: trimmedUsername,
                            secret: secret,
                            remoteFolder: trimmedRemoteFolder,
                            bucket: transport == .s3 ? trimmedBucket : nil,
                            region: transport == .s3 ? (trimmedRegion.isEmpty ? nil : trimmedRegion) : nil,
                            includePrefixes: includePrefixes,
                            allowDownload: allowDownload,
                            proofPassword: proofPassword.isEmpty ? nil : proofPassword,
                            expiresAt: proofExpiresAt,
                            sessionToken: transport == .s3
                                && !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                : nil)
                        await refreshHistory()
                        // 交付内发布成功后关闭；独立入口保留面板看结果/历史。
                        if !standalone, let result = viewModel.webDAVPublish, result.isSuccess { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                .disabled(viewModel.isPublishing || !canPublish)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 460)
        .accessibilityLabel(l10n("发布交付包"))
        // Wave4b：切换传输方式时清空敏感输入，避免把 S3 secret/token 当 WebDAV
        // 密码存进 Keychain（或反之）。endpoint/用户名等非敏感字段保留便于复用。
        .onChange(of: transport) { _, _ in
            secret = ""
            sessionToken = ""
        }
        .task { await refreshHistory() }
        .onDisappear { publishTask?.cancel() }
    }

    // MARK: - Wave5：发布历史

    private func refreshHistory() async {
        guard showsHistory else { return }
        history = await viewModel.publishHistory(localPath: localPath)
    }

    @ViewBuilder
    private var historySection: some View {
        Divider()
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(l10n("发布历史")).font(GatherFont.labelRegular)
            if history.isEmpty {
                Text(l10n("暂无发布记录"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            } else {
                ForEach(history, id: \.id) { entry in
                    historyRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: WebDAVPublishHistoryEntry) -> some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Text(Self.historyTime(entry.publishedAt))
                .font(GatherFont.secondary)
                .foregroundStyle(GatherTheme.secondaryText)
            Text(entry.transport == .s3 ? l10n("S3 兼容存储") : l10n("WebDAV"))
                .font(GatherFont.secondary)
            Text(entry.remoteFolder.isEmpty
                 ? entry.endpointSummary
                 : entry.endpointSummary + "/" + entry.remoteFolder)
                .font(GatherFont.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.endpointSummary)
            Text(l10n.format("成功 %lld / 跳过 %lld / 失败 %lld",
                             entry.uploaded, entry.skipped, entry.failed))
                .font(GatherFont.secondary)
                .foregroundStyle(entry.failed > 0 ? GatherTheme.errorText : GatherTheme.secondaryText)
            Spacer(minLength: 0)
            if let link = entry.entryURL, let url = URL(string: link) {
                Button(l10n("打开链接")) { NSWorkspace.shared.open(url) }
                    .gatherButton(.tertiary, size: .small)
            }
        }
    }

    /// 发布记录时间（ISO-8601 → 本地短格式；解析失败原样显示，不猜时间）。
    static func historyTime(_ iso8601: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso8601) else { return iso8601 }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Wave5：发布结果 + 客户链接（交付结果区与发布面板共用）。
///
/// 链接只在「发布成功 + 入口在远端就绪」时出现：不给客户一个 404/403 的链接；
/// S3 预签名链接显示剩余小时数，WebDAV 静态链接不过期。
struct SharePublishResultView: View {
    let publish: WebDAVPublishSummary
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(publish.isSuccess
                 ? l10n.format("已发布 %lld 个文件", publish.uploaded)
                 : l10n.format("发布完成：成功 %lld，失败 %lld",
                               publish.uploaded, publish.failed.count))
                .font(GatherFont.secondary)
                .foregroundStyle(publish.isSuccess ? GatherTheme.successText : GatherTheme.errorText)
            if publish.skipped > 0 {
                Text(l10n.format("跳过 %lld 个文件（远端未变）", publish.skipped))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
            }
            if publish.isSuccess, let link = publish.entryURL, let url = URL(string: link) {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                    HStack(spacing: GatherMetrics.Space.s) {
                        Text(l10n("客户链接"))
                            .font(GatherFont.labelRegular)
                        Spacer(minLength: 0)
                        Button(l10n("复制链接")) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(link, forType: .string)
                        }
                        .gatherButton(.tertiary, size: .small)
                        Button(l10n("在浏览器中打开")) {
                            NSWorkspace.shared.open(url)
                        }
                        .gatherButton(.tertiary, size: .small)
                    }
                    Text(link)
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let expiresAt = publish.entryURLExpiresAt,
                       let expiry = Self.linkExpiryText(expiresAt, with: l10n) {
                        Text(expiry)
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 预签名链接剩余时长文案（解析失败不显示，不猜假时长）。
    static func linkExpiryText(_ expiresAt: String, with l10n: L10n) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: expiresAt) else { return nil }
        let hours = max(1, Int((date.timeIntervalSinceNow / 3600).rounded()))
        return l10n.format("链接 %lld 小时后过期", hours)
    }
}

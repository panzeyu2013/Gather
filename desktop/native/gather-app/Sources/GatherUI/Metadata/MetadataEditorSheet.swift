// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataEditorSheet.swift
// P0 / B2：单张照片的直接元数据编辑（32 字段 + 联系人 8 成员）。
//
// 语义：
// - 初值来自缓存投影（只读面板同源）；不触发磁盘解析；
// - 只提交"用户改过的字段"，空白 = 显式清空（不是"不触碰"）；
// - 提交走 metadata.applyDescriptive（批次 templateId="inline"），撤销复用批次历史；
// - JPEG 的写入仍是 .xmp 侧车：面板明确提示 Bridge 可能读内嵌 IPTC。
import SwiftUI
import GatherProtocol

struct MetadataEditorSheet: View {
    let photoId: String
    let api: any MetadataAPI
    var onApplied: (MetadataTemplateApplyOutcome) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var detail: PhotoMetadataDetail?
    @State private var values: [DescriptiveField: String] = [:]
    @State private var initialValues: [DescriptiveField: String] = [:]
    @State private var contact = DescriptiveContact()
    @State private var initialContact = DescriptiveContact()
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var errorText: String?
    /// 盘上元数据读不到：fail-closed，禁用保存（缓存值可能落后，保存会覆盖外部改动）。
    @State private var diskReadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("编辑元数据"))
                .font(GatherFont.cardTitle)
            Text(l10n("初值来自盘上（含 JPEG 内嵌 IPTC）；只提交改动过的字段，留空表示清空该字段。JPEG 的写入仍落在同名 .xmp 侧车。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                        Text(detail.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        section(title: l10n("IPTC Core"), fields: MetadataDisplay.iptcCoreFields)
                        section(title: l10n("IPTC Extension"), fields: MetadataDisplay.iptcExtensionFields)
                        contactSection
                    }
                }
                .frame(maxHeight: 460)
            } else {
                Text(l10n("无法读取元数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if diskReadFailed {
                Text(l10n("无法读取盘上元数据，为避免覆盖外部改动，保存已禁用。请关闭后重试。"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text(l10n.format("将写入 %lld 个字段", changedFieldCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l10n("取消")) { dismiss() }
                Button(l10n("应用")) { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || isLoading || diskReadFailed || changedFieldCount == 0)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 620)
        .task { await load() }
    }

    private func section(title: String, fields: [DescriptiveField]) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(fields.filter { $0 != .contactInfo }, id: \.self) { field in
                HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
                    Text(l10n(MetadataDisplay.fieldTitle(field)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    TextField(l10n("未填写"), text: Binding(
                        get: { values[field] ?? "" },
                        set: { values[field] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("联系人"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            contactRow(l10n("城市"), value: Binding(
                get: { contact.city ?? "" }, set: { contact.city = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("国家"), value: Binding(
                get: { contact.country ?? "" }, set: { contact.country = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("地址"), value: Binding(
                get: { contact.address ?? "" }, set: { contact.address = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("邮编"), value: Binding(
                get: { contact.postalCode ?? "" }, set: { contact.postalCode = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("地区"), value: Binding(
                get: { contact.region ?? "" }, set: { contact.region = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("邮箱"), value: Binding(
                get: { contact.email ?? "" }, set: { contact.email = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("电话"), value: Binding(
                get: { contact.telephone ?? "" }, set: { contact.telephone = $0.isEmpty ? nil : $0 }))
            contactRow(l10n("网址"), value: Binding(
                get: { contact.url ?? "" }, set: { contact.url = $0.isEmpty ? nil : $0 }))
        }
    }

    private func contactRow(_ label: String, value: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            TextField(l10n("未填写"), text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 变更计算

    /// 改动过的字段数（含 contact 整块一次）。
    private var changedFieldCount: Int {
        MetadataEditorDraft.changedFieldCount(
            values: values, initial: initialValues,
            contact: contact, initialContact: initialContact)
    }

    private func load() async {
        defer { isLoading = false }
        do {
            // 展示用详情（文件名/EXIF）仍来自缓存投影；编辑初值必须读盘，
            // 否则缓存落后时用户看到旧值、保存静默覆盖外部改动（P0 / B2）。
            let loaded = try await api.metadata(photoId)
            detail = loaded
            let disk = try await api.diskDescriptive(photoId)
            var initial: [DescriptiveField: String] = [:]
            for field in DescriptiveField.allCases where field != .contactInfo {
                switch disk.value(for: field) {
                case .text(let text): initial[field] = text
                case .list(let items): initial[field] = items.joined(separator: "、")
                case .contact, .none: break
                }
            }
            initialValues = initial
            values = initial
            initialContact = disk.contactInfo ?? DescriptiveContact()
            contact = initialContact
        } catch {
            // 读盘失败不等于"没有元数据"：不能拿缓存继续编辑（fail-closed）。
            diskReadFailed = true
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    private func apply() async {
        isBusy = true
        defer { isBusy = false }
        guard let edited = MetadataEditorDraft.changes(
            values: values, initial: initialValues,
            contact: contact, initialContact: initialContact) else {
            errorText = l10n("没有改动")
            return
        }
        do {
            let input = try MetadataInlineApplyInput(photoIds: [photoId], fields: edited)
            let outcome = try await api.applyDescriptive(Confirmed(input, source: .userDialog))
            onApplied(outcome)
            dismiss()
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }
}

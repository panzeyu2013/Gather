// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataEditorSheet.swift
// P0 / B2：单张照片的直接元数据编辑（36 字段 + 联系人 8 成员）。
//
// Wave5（batch2）：受控值字段（countryCode / scene / subjectCode / digitalSourceType）
// 用词表 Picker（列表字段用"常用值"菜单追加）+ 应用前校验：
// 改过的非空值必须在词表内，否则留在面板里报错、不写盘（详见 MetadataEditorDraft）。
//
// 语义：
// - 初值来自**盘上**（metadata.diskDescriptive：sidecar + JPEG 内嵌 IPTC），
//   读不到时 fail-closed 禁用保存（缓存可能落后，不能拿它当编辑基线）；
// - 只提交"用户改过的字段"，空白 = 显式清空（不是"不触碰"）；
// - 补丁不含 contactInfo 时不得置 replace_contact（否则会清空整块联系人）；
// - 提交走 metadata.applyDescriptive（批次 templateId="inline"），撤销复用批次历史；
// - JPEG 的写入仍是 .xmp sidecar：面板明确提示 Bridge 可能读内嵌 IPTC。
//
// Wave5（batch5）：新增「位置与时间」分区（GPS 坐标 / 拍摄时间 + 按坐标反查地名）。
// - 初值同样读盘（metadata.diskGeoDate；读不到退回缓存投影，不 fail-closed 整个编辑器）；
// - 与描述性字段同一次确认：先写位置/时间（失败即停，不动描述性字段），再写描述字段；
// - 反查只填 city/state/country，不写坐标；失败给出可见文案，不静默。
import SwiftUI
import GatherProtocol

struct MetadataEditorSheet: View {
    let photoId: String
    let api: any MetadataAPI
    var onApplied: (MetadataTemplateApplyOutcome) -> Void = { _ in }
    /// 反查端口（默认 MapKit；测试/预览可注入 fake，不触网）。
    var geoLookup: any GeoPlaceLookup = MapKitGeoPlaceLookup()

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
    @State private var showDiscardConfirm = false
    /// 盘上元数据读不到：fail-closed，禁用保存（缓存值可能落后，保存会覆盖外部改动）。
    @State private var diskReadFailed = false
    // Wave5（batch5）：位置与时间（与描述性字段分开维护：它们不在 DescriptiveField 表里）。
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var dateTakenText = ""
    @State private var initialLatitudeText = ""
    @State private var initialLongitudeText = ""
    @State private var initialDateTakenText = ""
    @State private var isLookingUpPlace = false
    // Wave5（batch9）：双源（内嵌 + sidecar）冲突可见性；空数组 = 不显示（读不到/未接线也不显示）。
    @State private var dualSourceConflictFields: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("编辑元数据"))
                .font(GatherFont.cardTitle)
            Text(l10n("初值来自盘上（含 JPEG 内嵌 IPTC）；只提交改动过的字段。留空表示清空附属文件字段；JPEG 的内嵌字段（Bridge/Capture One 写入）无法在此清空，需先在原软件中清空。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let warning = dualSourceWarningText {
                // Wave5（batch9）：只提示，不阻断编辑、不自动清理内嵌（策略说明见文案）。
                Text(warning)
                    .font(GatherFont.label)
                    .foregroundStyle(GatherTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                        // Wave5（batch2）：交付字段（受控值 Picker / 列表"常用值"菜单）。
                        section(title: l10n("交付字段"), fields: MetadataDisplay.wave5DeliveryFields)
                        geoDateSection
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
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(l10n("取消")) {
                    if hasEdits { showDiscardConfirm = true } else { dismiss() }
                }
                .gatherButton(.secondary)
                Button(l10n("应用")) { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .gatherButton(.primary)
                    .disabled(isBusy || isLoading || diskReadFailed || !hasEdits)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 620)
        .task { await load() }
        .interactiveDismissDisabled(hasEdits)
        .confirmationDialog(
            l10n("放弃未保存的改动？"),
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n("放弃并关闭"), role: .destructive) { dismiss() }
            Button(l10n("继续编辑"), role: .cancel) {}
        } message: {
            Text(l10n("关闭后本次修改不会保存。"))
        }
    }

    private func section(title: String, fields: [DescriptiveField]) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(fields.filter { $0 != .contactInfo }, id: \.self) { field in
                fieldRow(field)
            }
        }
    }

    // MARK: - 位置与时间（Wave5 batch5）

    /// 位置与时间分区：GPS 坐标 / 拍摄时间 / 按坐标反查地名。
    ///
    /// Wave5（batch7）起 JPEG 内嵌目标也可读写：内嵌读侧补齐后，生产默认的
    /// embedded_fast_path 写回会在写后校验里读到 exif:* 元素；设置 embedded_fast_path=0
    /// 走旧写回实现时，若文件原生 EXIF 已有日期，写后校验可能失败（ImageIO 原生值优先）
    /// —— 失败会显式上报，不会谎报成功。
    /// - 坐标清空本波不支持（MetadataWriteAttributes 的 nil 只能表达"不触碰"）；
    ///   拍摄时间留空 = 清空（与描述性字段同一三态语义）。
    private var geoDateSection: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n("位置与时间"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
                Text(l10n("纬度"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                TextField("31.230400", text: $latitudeText)
                    .textFieldStyle(.roundedBorder)
                Text(l10n("经度"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                TextField("121.473700", text: $longitudeText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
                Text(l10n("拍摄时间"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                TextField("2026-12-01T10:00:00", text: $dateTakenText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("根据坐标反查地名")) {
                    Task { await reverseGeocodePlace() }
                }
                .gatherButton(.secondary)
                .disabled(isBusy || isLoading || isLookingUpPlace)
                if isLookingUpPlace {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            Text(l10n("反查只填城市/省州/国家，不写坐标；失败会保留原值。"))
                .font(GatherFont.label)
                .foregroundStyle(.secondary)
        }
    }

    /// 坐标 → 输入框文本（6 位小数；nil → 空串）。
    private static func coordinateText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", value)
    }

    /// 按坐标反查地名并填入 city/state/country（只填命中的字段，未命中的保留原值）。
    private func reverseGeocodePlace() async {
        let latText = latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lonText = longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latitude = Double(latText), let longitude = Double(lonText),
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            errorText = l10n("请先填写合法的纬度与经度（-90~90 / -180~180）")
            return
        }
        isLookingUpPlace = true
        defer { isLookingUpPlace = false }
        do {
            let place = try await geoLookup.reverseGeocode(
                latitude: latitude, longitude: longitude)
            for (field, value) in GeoPlaceMapping.fieldValues(place) {
                values[field] = value
            }
            errorText = nil
        } catch {
            errorText = l10n(GeoPlaceMapping.messageKey(for: error))
        }
    }

    /// 一行字段。三种形态：
    /// - 受控值标量字段（countryCode / digitalSourceType）：Picker（词表 + 未填写 +
    ///   "现值（词表外）"兜底，保存时由 Draft 校验拦截词表外输入）；
    /// - 受控值列表字段（scene / subjectCode）：TextField（顿号分隔）+"常用值"菜单追加，
    ///   避免把 24 个场景码做成多选控件；
    /// - 其余：自由文本 TextField（行为与旧版一致）。
    private func fieldRow(_ field: DescriptiveField) -> some View {
        let options = IPTCControlledVocabulary.options(for: field)
        let isList = XMPFieldDescriptor.descriptor(for: field)?.isList == true
        return HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.s) {
            Text(l10n(MetadataDisplay.fieldTitle(field)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if let options, !isList {
                Picker("", selection: valueBinding(for: field)) {
                    ForEach(controlledPickerTags(field: field, options: options)) { tag in
                        Text(tag.label).tag(tag.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } else {
                TextField(l10n("未填写"), text: valueBinding(for: field))
                    .textFieldStyle(.roundedBorder)
                if let options, isList {
                    Menu(l10n("常用值")) {
                        ForEach(options) { option in
                            Button(option.label) { appendControlledValue(option.value, to: field) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func valueBinding(for field: DescriptiveField) -> Binding<String> {
        Binding(
            get: { values[field] ?? "" },
            set: { values[field] = $0 })
    }

    /// Picker 的一个候选（SwiftUI 的 ForEach 不接受元组元素，单独建一个 Identifiable）。
    private struct ControlledPickerTag: Identifiable {
        let id: String
        let label: String
    }

    /// Picker 的候选：(空 = 未填写) + 词表 + 盘上现值（词表外时保留，不改写存量数据）。
    private func controlledPickerTags(
        field: DescriptiveField, options: [IPTCControlledVocabulary.Option]
    ) -> [ControlledPickerTag] {
        var tags: [ControlledPickerTag] = [
            ControlledPickerTag(id: "", label: l10n("未填写"))
        ]
        tags.append(contentsOf: options.map {
            ControlledPickerTag(id: $0.value, label: $0.label)
        })
        let current = values[field] ?? ""
        let normalizedCurrent = IPTCControlledVocabulary.normalized(current, for: field)
        if !normalizedCurrent.isEmpty,
           !options.contains(where: { $0.value == normalizedCurrent }) {
            tags.append(ControlledPickerTag(
                id: current, label: l10n.format("现值（词表外）：%@", current)))
        }
        return tags
    }

    /// 列表受控值追加：顿号分隔、去重、空值不追加。
    private func appendControlledValue(_ value: String, to field: DescriptiveField) {
        let current = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var items = current.isEmpty
            ? []
            : current.split(whereSeparator: { $0 == "、" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        guard !items.contains(value) else { return }
        items.append(value)
        values[field] = items.joined(separator: "、")
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

    /// 位置/时间输入框是否有未保存改动（原始文本比较；归一化与合法性交给 apply）。
    private var geoDateEdited: Bool {
        func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed(latitudeText) != trimmed(initialLatitudeText)
            || trimmed(longitudeText) != trimmed(initialLongitudeText)
            || trimmed(dateTakenText) != trimmed(initialDateTakenText)
    }

    /// 有任何未保存改动（决定应用按钮/关闭确认）。
    private var hasEdits: Bool { changedFieldCount > 0 || geoDateEdited }

    /// 状态行：描述性字段数 +（有改动时）位置/时间。
    private var summaryText: String {
        let fields = l10n.format("将写入 %lld 个字段", changedFieldCount)
        return geoDateEdited ? fields + " + " + l10n("位置与时间") : fields
    }

    // MARK: - Wave5（batch9）：双源冲突可见性

    /// 双源冲突警示文案（nil = 不显示；只提示，不阻断编辑）。
    private var dualSourceWarningText: String? {
        guard let names = Self.dualSourceFieldNames(
            dualSourceConflictFields, localize: { l10n($0) }) else { return nil }
        return l10n.format(
            "内嵌元数据与 sidecar 不一致（字段：%@）；当前以 sidecar 为准，内嵌不会自动清理。",
            names)
    }

    /// 冲突字段 id → 显示名（中文 key；描述性字段复用 MetadataDisplay.fieldTitle 表）。
    /// nonisolated：纯映射，单测/非 MainActor 调用方不应被 View 的隔离域限制。
    nonisolated static func dualSourceFieldLabelKey(_ id: String) -> String {
        switch id {
        case "rating": return "评分"
        case "label": return "色标"
        case "keywords": return "关键词"
        case "dateTaken": return "拍摄时间"
        case "latitude": return "纬度"
        case "longitude": return "经度"
        default:
            if let field = DescriptiveField(rawValue: id) {
                return MetadataDisplay.fieldTitle(field)
            }
            return id
        }
    }

    /// 冲突字段的显示名拼接（纯函数，便于单测）：空 fields = nil（不显示警示）。
    nonisolated static func dualSourceFieldNames(
        _ fields: [String],
        localize: (String) -> String
    ) -> String? {
        guard !fields.isEmpty else { return nil }
        return fields.map { localize(dualSourceFieldLabelKey($0)) }.joined(separator: "、")
    }

    /// reportError=false：失败分支已经给出更具体的文案（例如 JPEG 内嵌清空
    /// 失败），这次重新读盘只是把输入框拉回盘上值，不能把原因覆盖成"读盘失败"。
    private func load(reportError: Bool = true) async {
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
            // Wave5（batch5）：位置/时间初值读盘；未接线/读失败退回缓存投影
            // （不让 GPS/时间读失败禁用整个编辑器——描述性字段仍可编辑）。
            var geoSnapshot: MetadataGeoDateSnapshot?
            do {
                geoSnapshot = try await api.diskGeoDate(photoId: photoId)
            } catch {
                geoSnapshot = nil
            }
            let latitudeValue = geoSnapshot?.latitude ?? loaded.exif.gpsLatitude
            let longitudeValue = geoSnapshot?.longitude ?? loaded.exif.gpsLongitude
            let dateValue = geoSnapshot?.dateTaken ?? loaded.exif.dateTaken
            initialLatitudeText = Self.coordinateText(latitudeValue)
            initialLongitudeText = Self.coordinateText(longitudeValue)
            initialDateTakenText = dateValue ?? ""
            latitudeText = initialLatitudeText
            longitudeText = initialLongitudeText
            dateTakenText = initialDateTakenText
            // Wave5（batch9）：双源可见性（仅 JPEG + sidecar）。读失败/未接线静默不显示，
            // 不阻断编辑；也不把"读不到"当成"无冲突"写进任何缓存。
            do {
                dualSourceConflictFields =
                    try await api.dualSourceConflict(photoId: photoId)?.fields ?? []
            } catch {
                dualSourceConflictFields = []
            }
        } catch {
            // 读盘失败不等于"没有元数据"：不能拿缓存继续编辑（fail-closed）。
            diskReadFailed = true
            if reportError {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            }
        }
    }

    private func apply() async {
        // 受控值先校验再算补丁：写盘侧不做二次拒绝（服务层不认识 UI 词表）。
        if let violation = MetadataEditorDraft.controlledValueViolation(
            values: values, initial: initialValues) {
            errorText = l10n.format(
                "「%@」的值「%@」不在受控词表内，请从列表选择、改正或清空后再应用。",
                l10n(MetadataDisplay.fieldTitle(violation.field)), violation.value)
            return
        }
        // 位置/时间：先校验（越界/格式错留在面板，不做任何写入）。
        let geoDraft: MetadataEditorDraft.GeoDateDraft?
        do {
            geoDraft = try MetadataEditorDraft.geoDateChanges(
                latitude: latitudeText, longitude: longitudeText,
                dateTaken: dateTakenText,
                initialLatitude: initialLatitudeText,
                initialLongitude: initialLongitudeText,
                initialDate: initialDateTakenText)
        } catch let error as MetadataEditorDraft.GeoDateValidationError {
            errorText = geoDateErrorMessage(error)
            return
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
            return
        }
        let patch = MetadataEditorDraft.changes(
            values: values, initial: initialValues,
            contact: contact, initialContact: initialContact)
        guard patch != nil || geoDraft != nil else {
            errorText = l10n("没有改动")
            return
        }
        isBusy = true
        defer { isBusy = false }

        // 1) 先写位置/时间：失败即停（不动描述性字段，避免"半套改动"）。
        if let geoDraft {
            do {
                let geoInput = try MetadataGeoDateInput(
                    photoIds: [photoId],
                    latitude: geoDraft.latitude,
                    longitude: geoDraft.longitude,
                    dateTaken: geoDraft.dateTaken)
                let outcome = try await api.applyGeoAndDate(
                    Confirmed(geoInput, source: .userDialog))
                GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
                if let failure = outcome.failed.first {
                    errorText = MetadataDisplay.localizedFailure(failure.message, with: l10n)
                    onApplied(outcome)
                    await load(reportError: false)
                    return
                }
                if outcome.written.isEmpty,
                   !(outcome.conflicts.isEmpty && outcome.skipped.isEmpty) {
                    errorText = l10n("位置/时间没有写入：与盘上值冲突或写目标不支持")
                    onApplied(outcome)
                    await load(reportError: false)
                    return
                }
                onApplied(outcome)
            } catch {
                errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
                return
            }
        }

        // 2) 描述性字段（与位置/时间同一次确认；patch 为 nil = 只改了位置/时间）。
        guard let patch else {
            await load(reportError: false)
            dismiss()
            return
        }
        do {
            let input = try MetadataInlineApplyInput(
                photoIds: [photoId], fields: patch.fields,
                clearedContactMembers: patch.clearedContactMembers.isEmpty
                    ? nil : patch.clearedContactMembers)
            let outcome = try await api.applyDescriptive(Confirmed(input, source: .userDialog))
            // #11：编辑器写的是 XMP，常驻页（C1 胶囊/设置页）要立刻知道。
            GatherEventCenter.postDomainChange(.metadata, sessionId: nil)
            // P1：失败（尤其是 JPEG 内嵌字段无法清空）必须留在编辑器里可见；
            // 同时重新读盘，让输入框回到盘上真实值，而不是用户刚敲的空值。
            if let failure = outcome.failed.first {
                errorText = MetadataDisplay.localizedFailure(failure.message, with: l10n)
                await load(reportError: false)
                // 可能已写 sidecar（批次可撤销）：外层仍要刷新并保留撤销入口。
                onApplied(outcome)
                return
            }
            // 冲突/跳过导致一张都没写：不能悄悄关闭当成成功。
            if outcome.written.isEmpty,
               !(outcome.conflicts.isEmpty && outcome.skipped.isEmpty) {
                errorText = l10n("没有写入：与盘上值冲突或无需改动，请关闭后重新读取再试")
                onApplied(outcome)
                return
            }
            onApplied(outcome)
            dismiss()
        } catch {
            errorText = CommandErrorText.resolve(CommandError(error), with: l10n)
        }
    }

    /// 位置/时间校验失败 → 中文文案（新增 key 列在回执，由 Lead 统一补 en）。
    private func geoDateErrorMessage(
        _ error: MetadataEditorDraft.GeoDateValidationError
    ) -> String {
        switch error {
        case .latitudeNotNumber(let text):
            return l10n.format("纬度必须是数字（当前：%@）", text)
        case .latitudeOutOfRange(let value):
            return l10n.format("纬度必须在 -90 ~ 90 之间（当前：%@）", String(value))
        case .longitudeNotNumber(let text):
            return l10n.format("经度必须是数字（当前：%@）", text)
        case .longitudeOutOfRange(let value):
            return l10n.format("经度必须在 -180 ~ 180 之间（当前：%@）", String(value))
        case .coordinatesIncomplete:
            return l10n("请同时填写纬度和经度（GPS 需要成对）")
        case .invalidDate(let text):
            return l10n.format("拍摄时间格式不正确（%@），示例：2026-12-01T10:00:00", text)
        }
    }
}

// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Keywords.swift
// P0 / K0：挑片页关键词草稿、只读预览、delta 写回与自动补全。
//
// 边界：
//   - 草稿只影响当前选择集；切换选择必须重置，避免把 A 批的修改写到 B 批；
//   - preview 只读；apply 才写盘，且必须经 Confirmed（由面板确认 sheet 构造）；
//   - 写回请求上限 500 张；生成词由服务层 origin 保护，UI 只展示错误。
import Foundation
import GatherProtocol

extension CullingViewModel {
    // MARK: - 目标与并集

    /// 当前选择集对应的逻辑资产；未多选时退化为当前照片。
    var keywordTargetAssets: [CullingAsset] {
        guard let page else { return [] }
        if selectedPhotoIds.isEmpty {
            return currentAsset.map { [$0] } ?? []
        }
        return page.assets.filter { selectedPhotoIds.contains($0.photo.id) }
    }

    var keywordTargetPhotoIds: [String] {
        keywordTargetAssets.map(\.photo.id)
    }

    /// 选择集身份：面板用它检测选择变化并重置草稿。
    var keywordSelectionSignature: String {
        keywordTargetPhotoIds.sorted().joined(separator: "|")
    }

    /// 预览/应用的一致性签名：选择 + 归一化后的新增/删除集合。
    var keywordDraftSignature: String {
        let added = keywordAdded.map(KeywordNormalizer.fold).sorted().joined(separator: ",")
        let removed = keywordRemoved.map(KeywordNormalizer.fold).sorted().joined(separator: ",")
        return keywordSelectionSignature + "|" + added + "|" + removed
    }

    var keywordTargetCount: Int { keywordTargetAssets.count }

    /// 目标集索引：并集（保留首次拼写/顺序）+ 每个 fold 命中的资产数。
    /// 缓存以 selection + pageVersion 为键；写缓存本身不参与 Observation。
    private var keywordTargetIndex: KeywordTargetIndex {
        let key = keywordSelectionSignature + "#\(pageVersion)"
        if let cached = keywordTargetIndexCache, cached.key == key { return cached }
        var union: [String] = []
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for asset in keywordTargetAssets {
            for keyword in asset.keywords {
                let folded = KeywordNormalizer.fold(keyword)
                if seen.insert(folded).inserted { union.append(keyword) }
                counts[folded, default: 0] += 1
            }
        }
        let index = KeywordTargetIndex(key: key, union: union, counts: counts)
        keywordTargetIndexCache = index
        return index
    }

    /// 选中资产的关键词并集（保留首次拼写与顺序）。
    var keywordExistingKeywords: [String] {
        keywordTargetIndex.union
    }

    /// 当前生效词表：并集 − removed + added。
    var keywordEffectiveKeywords: [String] {
        let removedKeys = Set(keywordRemoved.map(KeywordNormalizer.fold))
        var result = keywordExistingKeywords.filter {
            !removedKeys.contains(KeywordNormalizer.fold($0))
        }
        var present = Set(result.map(KeywordNormalizer.fold))
        for keyword in keywordAdded where present.insert(KeywordNormalizer.fold(keyword)).inserted {
            result.append(keyword)
        }
        return result
    }

    /// 该词只在部分选中资产上存在（UI 显示 “—” 前缀）。
    func keywordIsPartial(_ keyword: String) -> Bool {
        let total = keywordTargetAssets.count
        guard total > 1 else { return false }
        let count = keywordTargetIndex.counts[KeywordNormalizer.fold(keyword)] ?? 0
        return count > 0 && count < total
    }

    func keywordIsAdded(_ keyword: String) -> Bool {
        let key = KeywordNormalizer.fold(keyword)
        return keywordAdded.contains { KeywordNormalizer.fold($0) == key }
    }

    var keywordCanEdit: Bool {
        !keywordTargetAssets.isEmpty && keywordTargetCount <= 500 && !isKeywordBusy
    }

    var keywordCanPreview: Bool {
        keywordCanEdit && (!keywordAdded.isEmpty || !keywordRemoved.isEmpty)
    }

    /// 预览中因生成词来源保护/读取失败而不可写的 XMP 数；>0 时禁止整批确认。
    var keywordPreviewBlockedCount: Int {
        keywordPreview?.items.filter {
            $0.xmpStatus == "blocked" || $0.xmpStatus == "failed"
        }.count ?? 0
    }

    var keywordCanApply: Bool {
        keywordCanEdit && keywordPreview != nil && keywordPreviewBlockedCount == 0
    }

    // MARK: - 草稿

    /// 切换照片但保留已输入 chips；只丢弃旧 selection 的预览/结果，
    /// 避免把上一次预览误当成新选择的预览。
    func clearKeywordPreviewForSelectionChange() {
        keywordPreview = nil
        keywordPreviewSignature = ""
        keywordResult = nil
        keywordSuggestions = []
        keywordError = nil
    }

    func resetKeywordDraft() {
        keywordAdded = []
        keywordRemoved = []
        keywordSuggestions = []
        keywordPreview = nil
        keywordPreviewSignature = ""
        keywordResult = nil
        keywordError = nil
    }

    func addKeyword(_ raw: String) {
        guard keywordCanEdit else {
            if keywordTargetAssets.isEmpty {
                keywordError = CommandError.localized("请先选择照片")
            } else if keywordTargetCount > 500 {
                keywordError = CommandError.localized("一次最多修改 500 张照片，请减少选择")
            }
            return
        }
        guard let keyword = KeywordNormalizer.normalize(raw) else {
            keywordError = CommandError.localized("关键词格式无效")
            return
        }
        guard keywordAdded.count + keywordRemoved.count < 100 else {
            keywordError = CommandError.localized("一次最多修改 100 个关键词")
            return
        }
        let key = KeywordNormalizer.fold(keyword)
        if keywordEffectiveKeywords.contains(where: { KeywordNormalizer.fold($0) == key }) {
            keywordError = nil
            return
        }
        keywordRemoved.removeAll { KeywordNormalizer.fold($0) == key }
        keywordAdded.append(keyword)
        keywordError = nil
        keywordPreview = nil
        keywordResult = nil
    }

    func removeKeyword(_ raw: String) {
        guard keywordCanEdit else {
            if !keywordTargetAssets.isEmpty, keywordTargetCount > 500 {
                keywordError = CommandError.localized("一次最多修改 500 张照片，请减少选择")
            }
            return
        }
        let key = KeywordNormalizer.fold(raw)
        keywordAdded.removeAll { KeywordNormalizer.fold($0) == key }
        guard keywordExistingKeywords.contains(where: { KeywordNormalizer.fold($0) == key }) else {
            keywordError = nil
            return
        }
        if !keywordRemoved.contains(where: { KeywordNormalizer.fold($0) == key }) {
            keywordRemoved.append(raw)
        }
        keywordError = nil
        keywordPreview = nil
        keywordResult = nil
    }

    func clearKeywordSuggestions() {
        keywordSuggestions = []
    }

    // MARK: - 预览 / 写回 / 重试

    func previewKeywordWriteback() async {
        guard keywordCanPreview else { return }
        let signature = keywordDraftSignature
        let photoIds = keywordTargetPhotoIds
        let added = keywordAdded
        let removed = keywordRemoved
        isKeywordBusy = true
        keywordError = nil
        defer { isKeywordBusy = false }
        do {
            let input = try MetadataPreviewInput(
                photoIds: photoIds, addedKeywords: added, removedKeywords: removed)
            let preview = try await metadataAPI.preview(input)
            // 返回时选择/草稿已变：丢弃旧预览，确认面板绝不能对着新目标。
            guard signature == keywordDraftSignature else { return }
            keywordPreview = preview
            keywordPreviewSignature = signature
        } catch {
            guard signature == keywordDraftSignature else { return }
            keywordPreview = nil
            keywordPreviewSignature = ""
            keywordError = CommandError(error)
        }
    }

    func applyKeywordWriteback() async {
        guard keywordCanApply else { return }
        // 预览之后选择/草稿变化过：不能用旧预览的确认去写新目标。
        guard keywordPreviewSignature == keywordDraftSignature else {
            keywordError = CommandError.localized("选择或草稿已变化，请重新预览")
            return
        }
        isKeywordBusy = true
        keywordError = nil
        defer { isKeywordBusy = false }
        do {
            let input = try MetadataKeywordApplyInput(
                photoIds: keywordTargetPhotoIds,
                addedKeywords: keywordAdded,
                removedKeywords: keywordRemoved
            )
            let result = try await metadataAPI.applyKeywords(Confirmed(input))
            keywordResult = result
            if result.result.failed == 0 {
                keywordAdded = []
                keywordRemoved = []
                keywordPreview = nil
                keywordPreviewSignature = ""
                postMetadataChange()
                refreshSilently(forcePage: true)
            }
        } catch {
            keywordError = CommandError(error)
        }
    }

    func retryKeywordWriteback() async {
        guard !isKeywordBusy else { return }
        isKeywordBusy = true
        keywordError = nil
        defer { isKeywordBusy = false }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            keywordResult = try await metadataAPI.retryKeywordWriteback(Confirmed(reference))
            postMetadataChange()
            refreshSilently(forcePage: true)
        } catch {
            keywordError = CommandError(error)
        }
    }

    // MARK: - 自动补全

    /// 服务端 suggestions 优先；不可用/失败时退化为当前页关键词，保证离线可编辑。
    func loadKeywordSuggestions(prefix: String) async {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, keywordCanEdit else {
            keywordSuggestions = []
            return
        }
        let existing = Set(keywordEffectiveKeywords.map(KeywordNormalizer.fold))
        var values: [String] = []

        if let photoAPI {
            do {
                let query = try PhotoSuggestionQuery(sessionId: sessionId, keyword: trimmed)
                let groups = try await photoAPI.suggestions(query)
                values = KeywordNormalizer.unique(
                    groups.filter { $0.field == "keyword" }.flatMap(\.values)
                )
            } catch {
                values = localKeywordSuggestions(prefix: trimmed)
            }
        } else {
            values = localKeywordSuggestions(prefix: trimmed)
        }

        let key = KeywordNormalizer.fold(trimmed)
        keywordSuggestions = values
            .filter {
                let folded = KeywordNormalizer.fold($0)
                return folded.contains(key) && !existing.contains(folded)
            }
            .prefix(8)
            .map { $0 }
    }

    private func localKeywordSuggestions(prefix: String) -> [String] {
        let key = KeywordNormalizer.fold(prefix)
        return KeywordNormalizer.unique(
            (page?.assets ?? []).flatMap(\.keywords) + keywordAdded
        ).filter { KeywordNormalizer.fold($0).contains(key) }
    }
}

// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataAttributeWriter.swift
// 元数据属性写回（#6 S4：从 MetadataService 切出的第五刀，也是风险最高的一块）。
//
// 方法体**逐字搬运**，不重排任何一步。六步顺序链是行为契约，破坏其中任一环都会
// 静默改变结果（原实现注释里逐条写过原因）：
//   1. 全部 queue（入队到 delivery_items）
//   2. 按会话 flush（一次会话一次 executePending）
//   3. 逐张回读盘上值
//   4. 清空判定（必须早于缓存投影——否则 B1 降级路径复现）
//   5. 缓存投影（含兄弟照片刷新：每会话只查一次投影，并发 4 路读盘，写缓存串行）
//   6. 写后校验（JPEG 内嵌字段清空失败要显式报 XMP_EMBEDDED_CLEAR_UNSUPPORTED）
//
// 另外两条：一张照片只读一次 sidecar（同一次读取同时服务校验与投影）；
// refreshProjection / projectionFailures 是**方法内局部状态**，不得提成字段
// （提成字段会让类型不再 Sendable，且并发重入会串污染）。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public struct MetadataAttributeWriter: Sendable {
    private let photoRepo: any PhotoRepository
    private let xmp: any XMPProvider
    private let cache: any MetadataRepository
    private let mutations: any MetadataMutationPort
    private let flushPending: MetadataQueueFlush?
    private let reader: MetadataDiskReader
    private let assetResolver: PhotoAssetResolver?

    public init(
        photoRepo: any PhotoRepository,
        xmp: any XMPProvider,
        cache: any MetadataRepository,
        mutations: any MetadataMutationPort,
        flushPending: MetadataQueueFlush?,
        reader: MetadataDiskReader,
        assetResolver: PhotoAssetResolver?
    ) {
        self.photoRepo = photoRepo
        self.xmp = xmp
        self.cache = cache
        self.mutations = mutations
        self.flushPending = flushPending
        self.reader = reader
        self.assetResolver = assetResolver
    }

    /// P1 / IPTC：把逐张的属性写入（描述性元数据 / rating / label / keywords）
    /// 经交付队列落盘。
    ///
    /// 为什么必须走队列：sidecar 写入的唯一路径是 deliveries（备份 → 冲突检测 → 写盘
    /// → reload-ack）。模板与 triage 直接调 XMPProvider 会绕过备份与审计，撤销也
    /// 没有交付行可追溯；这里统一入队后 flush，再回读校验并刷新缓存投影。
    public func apply(
        _ inputs: [(photoId: String, attributes: MetadataWriteAttributes)],
        source: MetadataMutationSource
    ) async throws -> MetadataAttributesApplyOutcome {
        guard !inputs.isEmpty else {
            return MetadataAttributesApplyOutcome(written: [], attempted: [], skipped: [], failed: [])
        }
        let ids = inputs.map(\.photoId)
        guard Set(ids).count == ids.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "must be unique")
        }
        let photos = try photoRepo.getLookupByIds(ids)
        guard photos.count == ids.count else {
            throw GatherError.invalidParameter(field: "photoIds", reason: "contains unknown photo ids")
        }
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })

        var skipped: [String] = []
        var queued: [(photoId: String, attributes: MetadataWriteAttributes, sessionId: String)] = []
        // 入队失败不能中断整批：已入队的照片仍要 flush，否则它们停在 pending，
        // 模板批次也不会记录（撤销输入丢失）。
        var failureByPhoto: [String: String] = [:]
        for input in inputs {
            guard !input.attributes.isEmpty else {
                skipped.append(input.photoId)
                continue
            }
            guard let photo = photoById[input.photoId] else { continue }
            do {
                _ = try mutations.queuePhotoValues(
                    sessionId: photo.sessionId,
                    photoId: input.photoId,
                    values: input.attributes.asJSONValue.objectValue ?? [:],
                    source: source
                )
                queued.append((input.photoId, input.attributes, photo.sessionId))
            } catch {
                failureByPhoto[input.photoId] = String(describing: error)
            }
        }
        guard !queued.isEmpty else {
            return MetadataAttributesApplyOutcome(
                written: [], attempted: [], skipped: skipped,
                failed: failureByPhoto.map { MetadataApplyFailure(photoId: $0.key, message: $0.value) })
        }
        // 已入队的照片都算 attempted：即使 flush 抛错/回读失败，交付项可能仍会在
        // 之后被别的 flush 写盘；批次必须先有快照，否则"盘上已改但不可撤销"。
        let attempted = queued.map(\.photoId)
        guard let flushPending else {
            throw MetadataServiceError.writebackFailed("writeback executor unavailable")
        }
        // 一次应用可能跨会话（模板 API 没有会话入参）；按会话 flush，失败互不影响。
        for sessionId in Set(queued.map(\.sessionId)).sorted() {
            do {
                let result = try await flushPending(sessionId)
                for item in result.failedItems where failureByPhoto[item.photoId] == nil {
                    failureByPhoto[item.photoId] = item.errorMessage.isEmpty
                        ? "writeback failed" : item.errorMessage
                }
            } catch {
                for entry in queued where entry.sessionId == sessionId {
                    failureByPhoto[entry.photoId] = String(describing: error)
                }
            }
        }

        var written: [String] = []
        var failed: [MetadataApplyFailure] = []
        // P0 / A2：回读失败/校验不符 = 不确定（可能已写盘）。它既留在 failed 里给
        // 用户看原因，也进 uncertain 让撤销批次包含它。
        var uncertain: [String] = []
        // 投影刷新失败只降级、不改变 written 语义；但失败次数要聚合上报——逐张逐字段
        // 打日志在万张批次下会刷数万行，反而淹没真正的信号。
        var projectionFailures = 0
        func refreshProjection(_ field: String, photoId: String, _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                projectionFailures += 1
                GatherLogger.log(
                    "metadata cache projection refresh failed (field=\(field) photo=\(photoId)): \(error)",
                    level: .debug)
            }
        }
        // RAW+JPEG 共享同一 .xmp：写后投影要刷新全部兄弟照片，否则兄弟面板/下次
        // plan 仍读旧值并误判冲突（关键词路径已有同样处理）。
        //
        // P1：兄弟刷新必须**逐张读盘上值**。JPEG 内嵌 IPTC 与 sidecar 是两份数据；
        // 用写回目标的 actual（sidecar 快照）整列刷新 JPEG 兄弟，会把兄弟的内嵌
        // 标题/版权从缓存里清掉。
        var siblingPhotosByXmp: [String: [(id: String, filepath: String)]] = [:]
        var loadedSessions = Set<String>()
        /// 兄弟照片的盘上读盘结果（并发读、串行写缓存）。
        struct SiblingRead: Sendable {
            let photoId: String
            let attributes: MetadataWriteAttributes?
            let error: String?
        }
        for input in queued {
            if let message = failureByPhoto[input.photoId] {
                failed.append(MetadataApplyFailure(photoId: input.photoId, message: message))
                continue
            }
            guard let photo = photoById[input.photoId] else { continue }
            let readPath = (try? assetResolver?.resolve(
                sessionId: photo.sessionId, photoId: input.photoId))?.filepath ?? photo.filepath
            // P1：回读必须走盘上合成值（JPEG = 内嵌 + sidecar）。只读 sidecar 会漏掉
            // 内嵌字段，并让"清空 JPEG 内嵌字段"看起来成功。
            let sidecar: MetadataWriteAttributes
            do {
                sidecar = try await xmp.readAttributes(photoPath: readPath)
            } catch {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_DOCUMENT_READ_FAILED.rawValue + ": \(error)"))
                continue
            }
            let snapshot = await reader.diskSnapshot(photoPath: readPath, sidecar: sidecar)
            let disk = snapshot.attributes
            // P1：内嵌读不到（JPEG 的 APP1 解析失败）时，清空类写入无法判定是否真的
            // 清掉，必须按不确定处理（进 failed + uncertain），不能报 written。
            // 判定必须在**写缓存投影之前**：否则会先用"仅 sidecar"快照整列覆盖
            // iptc_json，把内嵌值从面板抹掉，随后才报失败（B1 类问题在降级路径复现）。
            if !snapshot.embeddedReadable, Self.hasClearAttempt(input.attributes) {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue
                        + ": embedded metadata unreadable"))
                continue
            }
            // 缓存投影以回读的**盘上值**为准（写入可能是"字段合并"，本地输入不等于
            // 最终文件）。只有本次明确写了描述性元数据才刷新 IPTC 投影：rating/
            // 关键词写回时若 sidecar 解析失败，不能用空值把面板已有 IPTC 抹掉。
            if input.attributes.descriptive != nil {
                refreshProjection("descriptive", photoId: input.photoId) {
                    try cache.updateDescriptive(
                        photoId: input.photoId,
                        descriptive: disk.descriptive ?? DescriptiveMetadata())
                }
                if !loadedSessions.contains(photo.sessionId) {
                    loadedSessions.insert(photo.sessionId)
                    do {
                        for row in try photoRepo.getBySessionProjection(
                            sessionId: photo.sessionId) {
                            let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
                            siblingPhotosByXmp[key, default: []].append((row.id, row.filepath))
                        }
                    } catch {
                        // 兄弟刷新是投影优化；失败不回滚已写盘的文件。
                    }
                }
                // 兄弟索引按 photos.filepath 建键；asset_read_mode=asset 时 readPath 是
                // 解析后的资产路径，两者不同。只查 readPath 会让兄弟照片在 asset 模式下
                // 永不刷新（面板继续显示旧 IPTC），所以两个键都要试。
                let readKey = TSPath.normalize(TSPath.xmpSidecarPath(readPath))
                let dbKey = TSPath.normalize(TSPath.xmpSidecarPath(photo.filepath))
                // 当前照片已在上面用 disk 值刷过，这里只处理兄弟；两个键都查不到
                // 时没有兄弟可刷（fallback 曾被 where 子句过滤成空转）。
                let targets = siblingPhotosByXmp[readKey]
                    ?? siblingPhotosByXmp[dbKey]
                    ?? []
                var siblingPlans: [(id: String, path: String)] = []
                for (siblingId, siblingFilepath) in targets where siblingId != input.photoId {
                    var siblingPath = siblingFilepath
                    if let assetResolver {
                        do {
                            siblingPath = try assetResolver.resolve(
                                sessionId: photo.sessionId, photoId: siblingId).filepath
                        } catch {
                            // 解析失败退回 photos.filepath：兄弟刷新是投影优化。
                        }
                    }
                    siblingPlans.append((siblingId, siblingPath))
                }
                // 并发读盘：共享 sidecar 的兄弟组通常 2–4 张，串行 ImageIO 解析在大批次
                // 模板套用（2000 张）下会退化成 O(k²) 读盘。写缓存仍串行。
                let siblingReads: [SiblingRead]
                do {
                    siblingReads = try await batchAsync(
                        siblingPlans, concurrency: 4
                    ) { plan -> SiblingRead in
                        do {
                            let sidecar = try await xmp.readAttributes(photoPath: plan.path)
                            let snapshot = await reader.diskSnapshot(
                                photoPath: plan.path, sidecar: sidecar)
                            return SiblingRead(
                                photoId: plan.id, attributes: snapshot.attributes, error: nil)
                        } catch {
                            // 单张失败降级为诊断（已写盘的文件不回滚，缓存保留旧值）。
                            return SiblingRead(
                                photoId: plan.id, attributes: nil,
                                error: String(describing: error))
                        }
                    }
                } catch {
                    projectionFailures += 1
                    siblingReads = []
                }
                for read in siblingReads {
                    guard let attributes = read.attributes else {
                        // 兄弟读盘失败只降级为诊断：已写盘的文件不回滚，缓存保留旧值。
                        projectionFailures += 1
                        GatherLogger.log(
                            "metadata cache projection read failed "
                                + "(descriptive photo=\(read.photoId)): \(read.error ?? "-")",
                            level: .debug)
                        continue
                    }
                    refreshProjection("descriptive", photoId: read.photoId) {
                        try cache.updateDescriptive(
                            photoId: read.photoId,
                            descriptive: attributes.descriptive ?? DescriptiveMetadata())
                    }
                }
            }
            if let rating = disk.rating {
                refreshProjection("rating", photoId: input.photoId) {
                    try cache.updateRating(
                        photoId: input.photoId, rating: Int64(rating))
                }
            }
            if let label = disk.label {
                refreshProjection("label", photoId: input.photoId) {
                    try cache.updateLabel(photoId: input.photoId, label: label)
                }
            } else if let wantedLabel = input.attributes.label,
                      wantedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 显式清空最后一个 label：回读 nil 也必须把缓存清零，否则面板留旧值。
                refreshProjection("label", photoId: input.photoId) {
                    try cache.updateLabel(photoId: input.photoId, label: "")
                }
            }
            if let keywords = disk.keywords {
                refreshProjection("keywords", photoId: input.photoId) {
                    try cache.updateKeywords(
                        photoId: input.photoId, keywords: keywords)
                }
            } else if let wantedKeywords = input.attributes.keywords, wantedKeywords.isEmpty {
                refreshProjection("keywords", photoId: input.photoId) {
                    try cache.updateKeywords(
                        photoId: input.photoId, keywords: [])
                }
            }
            // P1：JPEG 的内嵌 IPTC/XMP 无法靠写 .xmp sidecar 清空。写后盘上值仍带
            // 旧字段、而 sidecar 已没有该字段 = sidecar 写入成功但内嵌值还在：必须显式
            // 失败（fail-closed），不能让调用方以为"清空成功"。
            if let clearFailure = Self.jpegEmbeddedClearFailure(
                expected: input.attributes, disk: disk, sidecar: sidecar,
                isJpeg: MetadataDiskReader.isJpegPath(readPath)) {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId, message: clearFailure))
                continue
            }
            guard Self.attributesMatch(input.attributes, disk) else {
                uncertain.append(input.photoId)
                failed.append(MetadataApplyFailure(
                    photoId: input.photoId,
                    message: GatherErrorCode.XMP_WRITE_VERIFICATION_FAILED.rawValue))
                continue
            }
            written.append(input.photoId)
        }
        if projectionFailures > 0 {
            GatherLogger.log(
                "metadata cache projection refresh failed \(projectionFailures) time(s)",
                level: .warn)
        }
        return MetadataAttributesApplyOutcome(
            written: written, attempted: attempted, skipped: skipped,
            failed: failed, uncertain: uncertain)
    }

    /// P1：JPEG 内嵌字段的"清空失败"诊断。
    ///
    /// sidecar 是 JPEG 的唯一可写面；Bridge/C1 写在 APP1 里的 IPTC/XMP 不会被
    /// 写 sidecar 删掉。判据必须同时看两份：
    /// - 盘上合成值仍有该字段（清空没生效）；
    /// - sidecar 已没有该字段（说明不是 sidecar 写失败，而是内嵌值残留）。
    ///
    /// 返回 JPEG_EMBEDDED_CLEAR_UNSUPPORTED: <字段列表>（错误码留在前缀，
    /// UI 经 L10n.resolvedTemplate 的 "CODE: 参数" 形态本地化）。RAW 不走该判定：
    /// RAW 只有 sidecar 一个真相源，读回不符就是普通写后校验失败。
    static func jpegEmbeddedClearFailure(
        expected: MetadataWriteAttributes,
        disk: MetadataWriteAttributes,
        sidecar: MetadataWriteAttributes,
        isJpeg: Bool
    ) -> String? {
        guard isJpeg else { return nil }
        var fields: [String] = []
        if let descriptive = expected.descriptive {
            let diskDescriptive = disk.descriptive ?? DescriptiveMetadata()
            let sidecarDescriptive = sidecar.descriptive ?? DescriptiveMetadata()
            for field in descriptive.explicitlySetFields {
                // 只检查"显式清空"：nil = 不触碰（不在 explicitlySetFields 里）。
                guard normalizedValue(descriptive.value(for: field)) == nil else { continue }
                guard normalizedValue(diskDescriptive.value(for: field)) != nil else { continue }
                // sidecar 仍带值 = sidecar 写入失败，交给通用 write-back verification 报错；
                // sidecar 已清空但盘上仍有值 = 内嵌残留（本诊断）。
                guard normalizedValue(sidecarDescriptive.value(for: field)) == nil else { continue }
                fields.append(field.rawValue)
            }
        }
        // P1：成员级联系人清空。内联编辑器提交完整 contact 结构，"为 nil 的成员"
        // 只有列在 clearedContactMembers 里才算显式清空（模板的成员级合并不算）。
        if let cleared = expected.clearedContactMembers, !cleared.isEmpty,
           let expectedContact = expected.descriptive?.contactInfo {
            let diskContact = disk.descriptive?.contactInfo ?? DescriptiveContact()
            let sidecarContact = sidecar.descriptive?.contactInfo ?? DescriptiveContact()
            for member in cleared {
                guard Self.isBlank(expectedContact.memberValue(member)) else { continue }
                guard !Self.isBlank(diskContact.memberValue(member)) else { continue }
                guard Self.isBlank(sidecarContact.memberValue(member)) else { continue }
                fields.append("contactInfo.\(member)")
            }
        }
        if let keywords = expected.keywords, keywords.isEmpty {
            let diskKeywords = (disk.keywords ?? []).filter { !$0.isEmpty }
            let sidecarKeywords = (sidecar.keywords ?? []).filter { !$0.isEmpty }
            if !diskKeywords.isEmpty, sidecarKeywords.isEmpty { fields.append("keywords") }
        }
        if let label = expected.label,
           label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let diskLabel = disk.label,
           !diskLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (sidecar.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append("label")
        }
        guard !fields.isEmpty else { return nil }
        return GatherErrorCode.JPEG_EMBEDDED_CLEAR_UNSUPPORTED.rawValue
            + ": " + fields.joined(separator: ", ")
    }

    /// 本次补丁是否包含"清空"意图（字段清空 / 空关键词 / 空 label）。
    static func hasClearAttempt(_ attributes: MetadataWriteAttributes) -> Bool {
        if let descriptive = attributes.descriptive {
            for field in descriptive.explicitlySetFields
            where normalizedValue(descriptive.value(for: field)) == nil {
                return true
            }
        }
        // P1：成员级联系人清空不体现在"整体为空"里，只挂在 clearedContactMembers 上；
        // 漏判会让内嵌不可读时的清空按 written 放行（旧值仍在 APP1）。
        if let cleared = attributes.clearedContactMembers, !cleared.isEmpty { return true }
        if let keywords = attributes.keywords, keywords.isEmpty { return true }
        if let label = attributes.label, isBlank(label) { return true }
        return false
    }

    /// 文本是否"空"（nil / 全空白）。
    static func isBlank(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 写后回读判定：描述性元数据逐字段（空值等价于不存在），其余字段精确比较。
    private static func attributesMatch(
        _ expected: MetadataWriteAttributes,
        _ actual: MetadataWriteAttributes
    ) -> Bool {
        if expected.rating != nil, expected.rating != actual.rating { return false }
        if let expectedLabel = expected.label {
            // 空串与 nil 等价于"没有 label"：清空后回读 nil 不能报成校验失败。
            let wanted = expectedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let got = (actual.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted != got { return false }
        }
        if let expectedKeywords = expected.keywords {
            let actualKeywords = Set(actual.keywords ?? [])
            if !Set(expectedKeywords).isSubset(of: actualKeywords) { return false }
        }
        if let descriptive = expected.descriptive {
            let actualDescriptive = actual.descriptive ?? DescriptiveMetadata()
            for field in descriptive.explicitlySetFields {
                let expectedValue = Self.normalizedValue(descriptive.value(for: field))
                let actualValue = Self.normalizedValue(actualDescriptive.value(for: field))
                if case .contact(let expectedContact) = expectedValue {
                    // 结构字段是成员级合并：模板只填部分成员时，盘上必然比输入多。
                    guard case .contact(let actualContact) = actualValue,
                          Self.contactContains(actualContact, expectedContact) else {
                        return false
                    }
                } else if expectedValue != actualValue {
                    return false
                }
            }
        }
        return true
    }

    /// expected 的每个非 nil 成员都必须与 actual 相同（成员级合并校验）。
    private static func contactContains(_ actual: DescriptiveContact, _ expected: DescriptiveContact) -> Bool {
        func eq(_ a: String?, _ b: String?) -> Bool { b == nil || a == b }
        return eq(actual.city, expected.city)
            && eq(actual.country, expected.country)
            && eq(actual.address, expected.address)
            && eq(actual.postalCode, expected.postalCode)
            && eq(actual.region, expected.region)
            && eq(actual.email, expected.email)
            && eq(actual.telephone, expected.telephone)
            && eq(actual.url, expected.url)
    }

    /// 读侧会 trim 文本并丢掉空列表项；比较前必须同口径，否则"写成功却报失败"。
    private static func normalizedValue(_ value: XMPFieldValue?) -> XMPFieldValue? {
        switch value {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        case .list(let values):
            let items = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return items.isEmpty ? nil : .list(items)
        case .contact(let contact):
            return contact.isEmpty ? nil : .contact(contact)
        case .none:
            return nil
        }
    }
}

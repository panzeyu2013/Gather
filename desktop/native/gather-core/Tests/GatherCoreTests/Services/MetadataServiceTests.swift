// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataServiceTests.swift
// MetadataService 缓存/陈旧键/损坏 sidecar 守卫的直测（用真实文件 + 计数 ExifProvider 做独立 oracle）。
//
// 覆盖此前 0 覆盖的两条数据安全契约：
// 1) 缓存陈旧键判据是 **且**：源文件大小相同但 sidecar mtime 变化必须重新提取；
//    若判据退化为或，外部对 sidecar 的修改永远不会被重新读取。
// 2) 损坏 sidecar（readAttributes 返回空但 sidecar 文件存在）不得用空值覆盖有效缓存。
import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
@testable import GatherDelivery
@testable import GatherMetadataIO

/// 计数 EXIF provider：调用次数即"是否重新提取"的独立证据。
private final class CountingExif: ExifProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func callCount() -> Int { lock.lock(); defer { lock.unlock() }; return calls }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func incrementCalls() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }

    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        incrementCalls()
        return MetadataParseSegments(
            ifd0: .object(["Make": .string("GatherCam"), "Model": .string("X-T5"), "ImageWidth": .number(100)]),
            exif: .object(["DateTimeOriginal": .string("2024:05:01 10:20:30"), "ISO": .number(200)]),
            gps: .object(["latitude": .number(1.5)])
        )
    }
}

/// 可切换属性/存在性的 XMP 替身（比真实实现更严格：不存在任何"静默返回旧值"的兜底）。
private final class SwitchableXMP: XMPProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var attributes = MetadataWriteAttributes()
    private var sidecarExists = true

    private var dropsGeoDateOnRead = false

    func setAttributes(_ value: MetadataWriteAttributes) {
        // 真实 SidecarXMP 写盘会把空串 dateTaken 处理成"删除元素"（读回 nil）；
        // 这个内存替身必须同口径归一化，否则清空用例会看到 "" 而非 nil。
        var normalized = value
        if let date = normalized.dateTaken,
           date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.dateTaken = nil
        }
        lock.lock(); attributes = normalized; lock.unlock()
    }
    func setSidecarExists(_ value: Bool) { lock.lock(); sidecarExists = value; lock.unlock() }
    func setDropsGeoDateOnRead(_ value: Bool) {
        lock.lock(); dropsGeoDateOnRead = value; lock.unlock()
    }
    func dropsGeoDate() -> Bool {
        lock.lock(); defer { lock.unlock() }; return dropsGeoDateOnRead
    }

    /// 同步锁临界区辅助（Swift 6：async 上下文不得直接 lock/unlock）。
    private func attributesSnapshot() -> MetadataWriteAttributes {
        lock.lock()
        defer { lock.unlock() }
        return attributes
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        attributesSnapshot().keywords ?? []
    }
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let snapshot = attributesSnapshot()
        guard dropsGeoDate() else { return snapshot }
        // 模拟「写盘成功但读侧拿不到」的宿主（Wave5 batch5：JPEG 内嵌目标的真实形态）：
        // GPS/时间被丢弃，服务层回读必须判失败，不能谎报 written。
        return MetadataWriteAttributes(
            keywords: snapshot.keywords,
            rating: snapshot.rating,
            label: snapshot.label,
            descriptive: snapshot.descriptive,
            triageSignal: snapshot.triageSignal,
            keywordsMode: snapshot.keywordsMode,
            replaceContact: snapshot.replaceContact,
            clearedContactMembers: snapshot.clearedContactMembers)
    }
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}
    func backup(photoPath: String) async throws -> String { "" }
    func restore(photoPath: String, backupPath: String) async throws {}
    func fileExists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return sidecarExists }
    func removeFile(_ path: String) async throws {}
}

private struct NoopMutations: MetadataMutationPort {
    func queuePhotoValues(
        sessionId: String, photoId: String, values: [String: JSONValue],
        source: MetadataMutationSource, schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(photoId: photoId, xmpPath: photoId + ".xmp", dirtyFields: [], revision: 1, status: "pending")
    }
}

struct MetadataServiceTests {
    private struct Fixture {
        let db: DBConnection
        let dir: String
        let photoId: String
        let photoPath: String
        let exif: CountingExif
        let xmp: SwitchableXMP
        let service: MetadataService

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeFixture() throws -> Fixture {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-metadata-service-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        try insertSession(db, sessionId)
        let photoId = "p-\(UUID().uuidString)"
        let photoPath = dir + "/photo.cr3"
        try Data("raw-bytes".utf8).write(to: URL(fileURLWithPath: photoPath))
        // sidecar 真实存在：陈旧键包含 sidecar mtime，这是"外部改了 XMP"的唯一廉价信号。
        try Data("sidecar".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(photoPath)))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        let exif = CountingExif()
        let xmp = SwitchableXMP()
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: NoopMutations(),
            assetResolver: nil,
            exif: exif,
            dimensions: nil,
            embeddedReader: nil
        )
        return Fixture(db: db, dir: dir, photoId: photoId, photoPath: photoPath, exif: exif, xmp: xmp, service: service)
    }

    // MARK: - P1 / IPTC：只读详情

    /// photoDetail 只读缓存：不得触发 EXIF/XMP 解析（面板翻页不能产生 N 次 IO）。
    @Test("photoDetail：缓存投影不触发解析，描述性元数据与 EXIF 都来自缓存行")
    func photoDetailReadsCacheOnly() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let repo = MetadataCacheRepo(connection: fx.db)
        let sessionRow = try fx.db.prepare("SELECT session_id FROM photos WHERE id = ?")
            .get([.text(fx.photoId)])
        let sessionId = sessionRow?[0].textValue ?? ""
        try repo.upsert(photoId: fx.photoId, sessionId: sessionId, data: MetadataCacheInput(
            cameraModel: "X-T5",
            lensModel: "23mm F1.4",
            iso: 400,
            descriptive: DescriptiveMetadata(title: "落日", city: "上海", personInImage: ["张三"])
        ))

        let detail = try fx.service.photoDetail(photoId: fx.photoId)
        #expect(detail.exif.cameraModel == "X-T5")
        #expect(detail.exif.iso == 400)
        #expect(detail.descriptive.title == "落日")
        #expect(detail.descriptive.city == "上海")
        #expect(detail.descriptive.personInImage == ["张三"])
        #expect(detail.filledDescriptiveCount == 3)
        #expect(detail.filename == "photo.cr3")
        #expect(detail.xmpPath.hasSuffix(".xmp"))
        #expect(detail.hasXMP)
        #expect(fx.exif.callCount() == 0, "只读详情不得触发 EXIF 解析")
    }

    @Test("photoDetail：缓存缺失返回空快照；照片不存在抛 photoNotFound")
    func photoDetailMissingCacheAndUnknownPhoto() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let detail = try fx.service.photoDetail(photoId: fx.photoId)
        #expect(detail.exif.isEmpty)
        #expect(detail.descriptive.isEmpty)

        #expect(throws: MetadataServiceError.self) {
            _ = try fx.service.photoDetail(photoId: "missing-photo")
        }
    }

    /// P1 / IPTC：扫描必须把 sidecar 描述性元数据投影到缓存（否则只读面板永远为空）。
    @Test("扫描：sidecar IPTC 投影到缓存；sidecar 消失后清空投影")
    func scanProjectsDescriptiveMetadata() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(descriptive: DescriptiveMetadata(
            title: "落日", creator: ["张三"], city: "上海",
            contactInfo: DescriptiveContact(email: "a@b.c"))))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        let repo = MetadataCacheRepo(connection: fx.db)
        let cached = try repo.get(fx.photoId)?.descriptive
        #expect(cached?.title == "落日")
        #expect(cached?.creator == ["张三"])
        #expect(cached?.city == "上海")
        #expect(cached?.contactInfo?.email == "a@b.c")

        // sidecar 被删除（合法清空）：守卫只针对"文件在但读不出"的损坏场景。
        fx.xmp.setAttributes(MetadataWriteAttributes())
        fx.xmp.setSidecarExists(false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: fx.photoPath)
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(try repo.get(fx.photoId)?.descriptive.title == nil, "sidecar 被删除后缓存必须同步清空")
    }

    /// 变异守卫：缓存命中判据 && 退化为 || 时，源文件大小不变、仅 sidecar mtime 变化
    /// 的情况会被误判为命中 —— 外部软件写进 sidecar 的关键词/星级永远读不到。
    @Test("缓存陈旧键：指纹未变命中缓存；仅 sidecar mtime 变化必须重新提取")
    func cacheStalenessKeyRequiresBothSizeAndMtime() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Green"))

        let first = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 1)
        // 独立 oracle：EXIF 段与 XMP 有效属性都必须落到缓存值上（不是只断言"被调用"）。
        #expect(first[fx.photoId]?.iso == 200)
        #expect(first[fx.photoId]?.make == "GatherCam")
        #expect(first[fx.photoId]?.width == 100)
        #expect(first[fx.photoId]?.rating == 3, "sidecar rating 覆盖 EXIF 缺省")
        #expect(first[fx.photoId]?.keywords == ["k1", "k2"])
        #expect(first[fx.photoId]?.label == "Green")

        // 源文件与 sidecar 都没动 → 必须命中缓存，不再调用 exif。
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 1, "指纹未变时必须命中缓存")

        // 只动 sidecar mtime（源文件大小/内容/mtime 全不变）→ 陈旧键变化 → 必须重新提取。
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes(
            [.modificationDate: future], ofItemAtPath: TSPath.xmpSidecarPath(fx.photoPath))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 2, "仅 sidecar mtime 变化也必须使缓存失效（判据是且，不是或）")
    }

    /// 变异守卫：损坏 sidecar 守卫取反（或有 sidecar 就早退）时，空读取会用空关键词/0 星
    /// 覆盖缓存里的有效值，直到文件再次变更前一直显示错误值。
    @Test("损坏 sidecar（文件在但读回空）必须保留缓存里的关键词/星级/色标")
    func corruptSidecarPreservesCachedValues() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Green"))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])

        // sidecar 仍存在，但读取返回空（损坏）→ 同时让源文件 mtime 前移，强制走重新提取。
        fx.xmp.setAttributes(MetadataWriteAttributes())
        fx.xmp.setSidecarExists(true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: fx.photoPath)

        let second = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(fx.exif.callCount() == 2, "源文件 mtime 变化必须重新提取（前置条件）")
        #expect(second[fx.photoId]?.keywords == ["k1", "k2"], "损坏 sidecar 不得用空值覆盖有效缓存")
        #expect(second[fx.photoId]?.rating == 3, "损坏 sidecar 不得把星级清零")
        #expect(second[fx.photoId]?.label == "Green", "损坏 sidecar 不得把色标抹掉")
    }

    /// 对照：sidecar**不存在**（合法的空初始状态）时不保留旧值 —— 守卫不能被理解成
    /// "永远保留缓存"（那会让真正被外部清空的关键词永远复活）。
    @Test("sidecar 不存在时不得复活缓存旧值（守卫只针对损坏）")
    func absentSidecarDoesNotResurrectCachedValues() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        fx.xmp.setAttributes(MetadataWriteAttributes(keywords: ["k1"], rating: 3, label: "Green"))
        _ = try await fx.service.getMetadata(photoIds: [fx.photoId])

        fx.xmp.setAttributes(MetadataWriteAttributes())
        fx.xmp.setSidecarExists(false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)], ofItemAtPath: fx.photoPath)

        let second = try await fx.service.getMetadata(photoIds: [fx.photoId])
        #expect(second[fx.photoId]?.keywords == nil)
        #expect(second[fx.photoId]?.rating == nil)
        #expect(second[fx.photoId]?.label == nil)
    }

    /// main 分支 2f81fcd8（D4/D7）：数字关键词按 JS `String(item)` 口径字符串化 ——
    /// 整数值不得带 ".0"（否则写回 XMP 的关键词从 "7" 变成 "7.0"，破坏跨端一致）。
    @Test("数字关键词字符串化：7→\"7\"、7.5→\"7.5\"、-0→\"0\"")
    func numericKeywordStringification() {
        let list = MetadataAttributes.normalizeKeywordList(
            .array([.number(7), .number(7.5), .number(-0.0), .string("lead"), .null])
        )
        #expect(list == ["7", "7.5", "0", "lead"])
        #expect(MetadataAttributes.normalizeKeywordList(.number(7)) == ["7"])
        #expect(MetadataAttributes.normalizeKeywordList(.none) == nil)
    }

    /// P1：JPEG 清空诊断覆盖 descriptive / keywords / label；RAW 与"sidecar 也没写"
    /// 不得误报（sidecar 写失败走通用 write-back verification）。
    @Test("JPEG 内嵌清空诊断：多字段命中，RAW 与 sidecar 未清空不误报")
    func jpegEmbeddedClearDiagnostics() {
        let expected = MetadataWriteAttributes(
            keywords: [],
            label: "",
            descriptive: DescriptiveMetadata(caption: ""))
        let disk = MetadataWriteAttributes(
            keywords: ["k1"],
            label: "Red",
            descriptive: DescriptiveMetadata(caption: "旧说明"))
        let sidecar = MetadataWriteAttributes()

        let message = MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: expected, disk: disk, sidecar: sidecar, isJpeg: true)
        #expect(message?.contains("caption") == true)
        #expect(message?.contains("keywords") == true)
        #expect(message?.contains("label") == true)

        // RAW 只有 sidecar 一个真相源：同样的差异是普通写后校验，不是内嵌残留。
        #expect(MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: expected, disk: disk, sidecar: sidecar, isJpeg: false) == nil)

        // sidecar 仍带值 = sidecar 没写成功：交给通用 verification，不谎报"内嵌不支持"。
        let sidecarStillHasValue = MetadataWriteAttributes(
            keywords: ["k1"],
            label: "Red",
            descriptive: DescriptiveMetadata(caption: "旧说明"))
        #expect(MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: expected, disk: disk,
            sidecar: sidecarStillHasValue, isJpeg: true) == nil)
    }

    /// P1：成员级联系人清空。内联编辑器提交完整 contact 结构，nil 成员只有列在
    /// clearedContactMembers 里才算"清空"（模板的成员级合并不算）。
    @Test("JPEG 成员级联系人清空：只认显式上报的成员")
    func jpegEmbeddedClearDetectsContactMembers() {
        let expected = MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")),
            replaceContact: true,
            clearedContactMembers: ["city"])
        let disk = MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(
                contactInfo: DescriptiveContact(city: "上海", email: "a@b.c")))
        let sidecar = MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")))

        let message = MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: expected, disk: disk, sidecar: sidecar, isJpeg: true)
        #expect(message?.contains("contactInfo.city") == true, "\(message ?? "-")")

        // sidecar 仍带该成员 = sidecar 没写成功，交给通用校验，不谎报"内嵌不支持"。
        let sidecarStillHasCity = MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(city: "上海")))
        #expect(MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: expected, disk: disk, sidecar: sidecarStillHasCity, isJpeg: true) == nil)

        // 没有上报的成员（模板成员级合并）不得被当成清空。
        let unreported = MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")),
            replaceContact: true)
        #expect(MetadataAttributeWriter.jpegEmbeddedClearFailure(
            expected: unreported, disk: disk, sidecar: sidecar, isJpeg: true) == nil)
    }

    @Test("清空意图判定：字段/关键词/label 的空值都算清空尝试")
    func clearAttemptDetection() {
        #expect(!MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes()), "空补丁没有清空意图")
        #expect(!MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(caption: "有值"))))
        #expect(MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(caption: ""))))
        #expect(MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(keywords: [])))
        #expect(!MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(keywords: ["k"])))
        #expect(MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(label: "  ")))
        // P1 回归：成员级联系人清空不体现在"整体为空"里，只挂在 clearedContactMembers 上。
        // 漏判 → 内嵌不可读时 clear 被当成 written（旧值仍在 APP1）。
        #expect(MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")),
            replaceContact: true,
            clearedContactMembers: ["city"])))
        #expect(!MetadataAttributeWriter.hasClearAttempt(MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(email: "a@b.c")))))
    }

    /// P2：读侧空结构不等于"显式清空"。
    ///
    /// 外部工具常留一个空 `CreatorContactInfo` 壳；若解析成 `.contact(空)`，
    /// mergeAttributes 的 overlay 语义会把 JPEG 内嵌联系人整块抹掉。显式清空只走写侧
    /// （clearedContactMembers / replaceContact）。
    @Test("空 contact 结构不覆盖已有联系人")
    func emptyContactStructureDoesNotWipe() {
        let base = DescriptiveMetadata(contactInfo: DescriptiveContact(city: "上海"))
        let overlayWithoutContact = DescriptiveMetadata(caption: "无联系人壳")
        let merged = MetadataAttributes.mergeDescriptive(base, overlayWithoutContact)
        #expect(merged?.contactInfo?.city == "上海", "空 overlay 不得抹掉内嵌联系人")
    }
}

// MARK: - Wave5（batch5）：位置 / 拍摄时间

/// 记录入队属性并在 flush 时真写 XMP 的变更端口（交付队列语义的最小替身）。
private final class StoringMutations: MetadataMutationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: MetadataWriteAttributes] = [:]

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        lock.lock()
        defer { lock.unlock() }
        pending[photoId] = MetadataWriteAttributes(jsonValue: .object(values))
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }

    func takePending() -> [String: MetadataWriteAttributes] {
        lock.lock()
        defer { lock.unlock() }
        let result = pending
        pending = [:]
        return result
    }
}

@Suite("位置/拍摄时间写入（MetadataService）")
struct MetadataGeoDateServiceTests {
    private struct Fixture {
        let db: DBConnection
        let dir: String
        let photoId: String
        let photoPath: String
        let xmp: SwitchableXMP
        let service: MetadataService

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeFixture(dropGeoDateOnRead: Bool = false) throws -> Fixture {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-geodate-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        try insertSession(db, sessionId)
        let photoId = "p-\(UUID().uuidString)"
        let photoPath = dir + "/geo.cr3"
        try Data("raw-bytes".utf8).write(to: URL(fileURLWithPath: photoPath))
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)

        let xmp = SwitchableXMP()
        xmp.setDropsGeoDateOnRead(dropGeoDateOnRead)
        let mutations = StoringMutations()
        let paths = [photoId: photoPath]
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: mutations,
            flushPending: { _ in
                // 交付队列替身：把入队值写进假 XMP（SwitchableXMP 的读就是 attributes，
                // 因此写盘=setAttributes；真实链路由 provider 写文件）。
                let pending = mutations.takePending()
                for (id, attributes) in pending where paths[id] != nil {
                    xmp.setAttributes(attributes)
                }
                return WritebackResult(
                    totalAffected: pending.count, written: pending.count, failed: 0,
                    skipped: 0, errors: [], failedItems: [], report: "")
            }
        )
        return Fixture(
            db: db, dir: dir, photoId: photoId, photoPath: photoPath,
            xmp: xmp, service: service)
    }

    @Test("applyGeoDate：坐标+时间经交付队列写盘，回读一致 → written")
    func writesAndReadsBack() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let outcome = try await fixture.service.applyGeoDate(
            photoIds: [fixture.photoId],
            latitude: 31.2304,
            longitude: 121.4737,
            dateTaken: "2026-12-01T10:00:00",
            source: .manual)
        #expect(outcome.written == [fixture.photoId])
        #expect(outcome.failed.isEmpty)
        let readBack = try await fixture.xmp.readAttributes(photoPath: fixture.photoPath)
        #expect(abs((readBack.latitude ?? 0) - 31.2304) < 1e-5)
        #expect(abs((readBack.longitude ?? 0) - 121.4737) < 1e-5)
        #expect(readBack.dateTaken == "2026-12-01T10:00:00")
        let snapshot = try await fixture.service.diskGeoDate(photoId: fixture.photoId)
        #expect(snapshot?.dateTaken == "2026-12-01T10:00:00")
        #expect(abs((snapshot?.latitude ?? 0) - 31.2304) < 1e-5)
    }

    @Test("applyGeoDate：空串清空拍摄时间")
    func clearsDateTaken() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.applyGeoDate(
            photoIds: [fixture.photoId], latitude: nil, longitude: nil,
            dateTaken: "2026-12-01T10:00:00", source: .manual)
        let outcome = try await fixture.service.applyGeoDate(
            photoIds: [fixture.photoId], latitude: nil, longitude: nil,
            dateTaken: "", source: .manual)
        #expect(outcome.written == [fixture.photoId])
        let readBack = try await fixture.xmp.readAttributes(photoPath: fixture.photoPath)
        #expect(readBack.dateTaken == nil)
    }

    @Test("applyGeoDate：写盘成功但读回拿不到 GPS/时间 → failed + uncertain，不谎报 written")
    func failsWhenReadBackDropsFields() async throws {
        let fixture = try makeFixture(dropGeoDateOnRead: true)
        defer { fixture.cleanup() }
        let outcome = try await fixture.service.applyGeoDate(
            photoIds: [fixture.photoId], latitude: 31.2304, longitude: 121.4737,
            dateTaken: nil, source: .manual)
        #expect(outcome.written.isEmpty)
        #expect(outcome.uncertain.contains(fixture.photoId))
        let message = try #require(outcome.failed.first?.message)
        #expect(message.hasPrefix("XMP_WRITE_VERIFICATION_FAILED"))
    }

    @Test("applyGeoDate：未知 photoId 显式失败")
    func rejectsUnknownPhoto() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await #expect(throws: GatherError.self) {
            _ = try await fixture.service.applyGeoDate(
                photoIds: ["missing"], latitude: 1, longitude: 2,
                dateTaken: nil, source: .manual)
        }
    }
}

@Suite("sidecar GPS/拍摄时间写盘（真实 SidecarXMPProvider）")
struct SidecarGeoDatePatchingTests {
    private func makeTempPhoto() throws -> (dir: String, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-sidecar-geodate-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/IMG_0001.cr3"
        try Data("raw-bytes".utf8).write(to: URL(fileURLWithPath: path))
        return (dir, path)
    }

    @Test("写盘往返：exif:GPSLatitude/GPSLongitude/DateTimeOriginal 落盘且读回一致")
    func writesExifGeoDate() async throws {
        let temp = try makeTempPhoto()
        defer { try? FileManager.default.removeItem(atPath: temp.dir) }
        let provider = SidecarXMPProvider()
        let attributes = MetadataWriteAttributes(
            dateTaken: "2026-12-01T10:00:00",
            latitude: 31.2304,
            longitude: 121.4737)
        try await provider.writeAttributes(photoPath: temp.path, attributes: attributes)
        let readBack = try await provider.readAttributes(photoPath: temp.path)
        #expect(readBack.dateTaken == "2026-12-01T10:00:00")
        #expect(abs((readBack.latitude ?? 0) - 31.2304) < 1e-5)
        #expect(abs((readBack.longitude ?? 0) - 121.4737) < 1e-5)
        let text = try String(
            contentsOfFile: TSPath.xmpSidecarPath(temp.path), encoding: .utf8)
        #expect(text.contains("exif:GPSLatitude"))
        #expect(text.contains("exif:GPSLongitude"))
        #expect(text.contains("exif:DateTimeOriginal"))
        #expect(text.contains("xmlns:exif="), "exif 前缀必须声明，否则产出非法 XMP")
    }

    @Test("空串清空拍摄时间：元素删除，读回 nil")
    func clearsDateTimeOriginal() async throws {
        let temp = try makeTempPhoto()
        defer { try? FileManager.default.removeItem(atPath: temp.dir) }
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(
            photoPath: temp.path,
            attributes: MetadataWriteAttributes(dateTaken: "2026-12-01T10:00:00"))
        try await provider.writeAttributes(
            photoPath: temp.path, attributes: MetadataWriteAttributes(dateTaken: ""))
        let readBack = try await provider.readAttributes(photoPath: temp.path)
        #expect(readBack.dateTaken == nil)
        let text = try String(
            contentsOfFile: TSPath.xmpSidecarPath(temp.path), encoding: .utf8)
        #expect(!text.contains("exif:DateTimeOriginal"))
    }

    @Test("写后校验：宿主丢弃 exif 元素时必须显式失败（不谎报成功）")
    func verificationFailureIsLoud() async throws {
        let temp = try makeTempPhoto()
        defer { try? FileManager.default.removeItem(atPath: temp.dir) }
        let provider = SidecarXMPProvider(writeTransform: { text in
            var stripped = text
            for name in ["exif:GPSLatitude", "exif:GPSLongitude", "exif:DateTimeOriginal"] {
                let pattern = "<" + name + ">[^<]*</" + name + ">"
                stripped = stripped.replacingOccurrences(
                    of: pattern, with: "", options: .regularExpression)
            }
            return stripped
        })
        await #expect(throws: SidecarXMPError.self) {
            try await provider.writeAttributes(
                photoPath: temp.path,
                attributes: MetadataWriteAttributes(latitude: 31.2304, longitude: 121.4737))
        }
    }
}


// MARK: - Wave5（batch9）：双源冲突可见性

/// 可编程的内嵌读侧替身（ExifProvider）：nil = 内嵌不可读，throw = 解析失败。
private struct StubExif: ExifProvider {
    enum Behavior: Sendable {
        case segments(MetadataParseSegments)
        case unreadable
        case failure
    }

    let behavior: Behavior

    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        switch behavior {
        case .segments(let segments):
            return segments
        case .unreadable:
            return nil
        case .failure:
            throw GatherError.invalidParameter(field: "exif", reason: "stub failure")
        }
    }
}

@Suite("双源冲突可见性（内嵌 + sidecar）")
struct MetadataDualSourceConflictTests {
    /// 组装可写属性（只填本用例关心的字段）。
    private func attributes(
        rating: Double? = nil,
        label: String? = nil,
        keywords: [String]? = nil,
        dateTaken: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        descriptive: DescriptiveMetadata? = nil
    ) -> MetadataWriteAttributes {
        MetadataWriteAttributes(
            keywords: keywords, rating: rating, label: label, dateTaken: dateTaken,
            latitude: latitude, longitude: longitude, descriptive: descriptive)
    }

    @Test("纯比较：两侧都有值且不同 → 全部字段按名字排序报出")
    func detectsAllFieldKinds() {
        let embedded = attributes(
            rating: 5, label: "Red", keywords: ["婚礼", "上海"],
            dateTaken: "2026:12:01 10:00:00",
            latitude: 31.2304, longitude: 121.4737,
            descriptive: DescriptiveMetadata(title: "内嵌标题", caption: "一致说明"))
        let sidecar = attributes(
            rating: 3, label: "Green", keywords: ["上海", "人像"],
            dateTaken: "2026-12-02T10:00:00",
            latitude: 30, longitude: 120,
            descriptive: DescriptiveMetadata(title: "sidecar 标题", caption: "一致说明"))
        #expect(MetadataDiskReader.dualSourceConflictFields(embedded: embedded, sidecar: sidecar)
            == ["dateTaken", "keywords", "label", "latitude", "longitude", "rating", "title"])
    }

    @Test("纯比较：等价格式 / 乱序 / 容差内 / 列表乱序 → 无冲突")
    func equalValuesDoNotConflict() {
        let embedded = attributes(
            rating: 4, label: "Red", keywords: ["a", "b"],
            dateTaken: "2026:12:01 10:00:00",
            latitude: 31.2304, longitude: 121.4737,
            descriptive: DescriptiveMetadata(personInImage: ["张三", "李四"]))
        let sidecar = attributes(
            rating: 4, label: "Red", keywords: ["b", "a"],
            dateTaken: "2026-12-01T10:00:00",
            latitude: 31.2304000001, longitude: 121.4737000001,
            descriptive: DescriptiveMetadata(personInImage: ["李四", "张三"]))
        #expect(MetadataDiskReader.dualSourceConflictFields(embedded: embedded, sidecar: sidecar).isEmpty)
    }

    @Test("纯比较：一侧缺失不算冲突；contactInfo 结构不参与提示")
    func oneSideMissingAndContactIgnored() {
        let empty = attributes()
        let onlyEmbedded = attributes(
            rating: 5, label: "Red", keywords: ["a"],
            descriptive: DescriptiveMetadata(title: "标题"))
        #expect(MetadataDiskReader.dualSourceConflictFields(embedded: onlyEmbedded, sidecar: empty).isEmpty)
        #expect(MetadataDiskReader.dualSourceConflictFields(embedded: empty, sidecar: onlyEmbedded).isEmpty)

        let leftContact = attributes(descriptive: DescriptiveMetadata(
            contactInfo: DescriptiveContact(email: "a@b.c")))
        let rightContact = attributes(descriptive: DescriptiveMetadata(
            contactInfo: DescriptiveContact(email: "x@y.z")))
        #expect(MetadataDiskReader.dualSourceConflictFields(
            embedded: leftContact, sidecar: rightContact).isEmpty)
    }

    // MARK: IO 门禁（JPEG + sidecar）

    private struct IOFixture {
        let dir: String
        let photoPath: String

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeIOFixture(ext: String = "jpg", withSidecar: Bool = true) throws -> IOFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-dual-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/IMG_1." + ext
        try Data("jpeg-bytes".utf8).write(to: URL(fileURLWithPath: path))
        if withSidecar {
            try Data("sidecar".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(path)))
        }
        return IOFixture(dir: dir, photoPath: path)
    }

    @Test("IO 门禁：JPEG+sidecar 才比较；非 JPEG/无 sidecar/内嵌不可读 → 空且不抛")
    func ioGating() async throws {
        let embeddedSegments = MetadataParseSegments(
            ifd0: .object(["Rating": .number(5)]),
            dc: .object(["title": .string("内嵌标题")]))
        let xmp = SwitchableXMP()
        xmp.setAttributes(attributes(
            rating: 3, descriptive: DescriptiveMetadata(title: "sidecar 标题")))

        let jpeg = try makeIOFixture()
        defer { jpeg.cleanup() }
        let reader = MetadataDiskReader(
            xmp: xmp, exif: StubExif(behavior: .segments(embeddedSegments)), embeddedReader: nil)
        let fields = await reader.dualSourceConflict(photoPath: jpeg.photoPath)
        #expect(fields == ["rating", "title"])

        let raw = try makeIOFixture(ext: "cr3")
        defer { raw.cleanup() }
        let rawFields = await reader.dualSourceConflict(photoPath: raw.photoPath)
        #expect(rawFields.isEmpty, "非 JPEG 不存在双源")

        let noSidecar = try makeIOFixture(withSidecar: false)
        defer { noSidecar.cleanup() }
        let noSidecarFields = await reader.dualSourceConflict(photoPath: noSidecar.photoPath)
        #expect(noSidecarFields.isEmpty, "没有 sidecar 就没有第二个源")

        let unreadable = MetadataDiskReader(
            xmp: xmp, exif: StubExif(behavior: .unreadable), embeddedReader: nil)
        let unreadableFields = await unreadable.dualSourceConflict(photoPath: jpeg.photoPath)
        #expect(unreadableFields.isEmpty, "内嵌不可读 = 无法判定，不报冲突")

        let failing = MetadataDiskReader(
            xmp: xmp, exif: StubExif(behavior: .failure), embeddedReader: nil)
        let failingFields = await failing.dualSourceConflict(photoPath: jpeg.photoPath)
        #expect(failingFields.isEmpty, "解析失败不得抛错/误报")

        let noExif = MetadataDiskReader(xmp: xmp, exif: nil, embeddedReader: nil)
        let noExifFields = await noExif.dualSourceConflict(photoPath: jpeg.photoPath)
        #expect(noExifFields.isEmpty, "未注入 EXIF 读取器 = 无法判定")
    }

    // MARK: 服务层

    private struct ServiceFixture {
        let db: DBConnection
        let dir: String
        let photoId: String
        let photoPath: String
        let xmp: SwitchableXMP
        let service: MetadataService

        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeServiceFixture(
        ext: String = "jpg",
        withSidecar: Bool = true,
        behavior: StubExif.Behavior
    ) throws -> ServiceFixture {
        let db = try makeTestDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-dual-service-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sessionId = "s-\(UUID().uuidString)"
        try insertSession(db, sessionId)
        let photoId = "p-\(UUID().uuidString)"
        let photoPath = dir + "/dual." + ext
        try Data("bytes".utf8).write(to: URL(fileURLWithPath: photoPath))
        if withSidecar {
            try Data("sidecar".utf8).write(to: URL(fileURLWithPath: TSPath.xmpSidecarPath(photoPath)))
        }
        try insertPhoto(db, id: photoId, sessionId: sessionId, filepath: photoPath)
        let xmp = SwitchableXMP()
        let service = MetadataService(
            metadataCacheRepo: MetadataCacheRepo(connection: db),
            xmp: xmp,
            connection: db,
            mutations: NoopMutations(),
            exif: StubExif(behavior: behavior))
        return ServiceFixture(
            db: db, dir: dir, photoId: photoId, photoPath: photoPath, xmp: xmp, service: service)
    }

    @Test("服务层：冲突返回排序 DTO（canonical=sidecar）；未知照片 → nil")
    func serviceReturnsDTO() async throws {
        let fixture = try makeServiceFixture(
            behavior: .segments(MetadataParseSegments(
                ifd0: .object(["Rating": .number(5)]))))
        defer { fixture.cleanup() }
        fixture.xmp.setAttributes(attributes(rating: 3, label: "Red"))
        let conflict = try await fixture.service.dualSourceConflict(photoId: fixture.photoId)
        #expect(conflict?.photoId == fixture.photoId)
        #expect(conflict?.fields == ["rating"])
        #expect(conflict?.canonical == .sidecar)

        let missing = try await fixture.service.dualSourceConflict(photoId: "missing-photo")
        #expect(missing == nil)
    }

    @Test("服务层：非 JPEG 即使 sidecar 有差异也不报")
    func serviceSkipsNonJpeg() async throws {
        let fixture = try makeServiceFixture(
            ext: "cr3",
            behavior: .segments(MetadataParseSegments(
                ifd0: .object(["Rating": .number(5)]))))
        defer { fixture.cleanup() }
        fixture.xmp.setAttributes(attributes(rating: 3))
        let conflict = try await fixture.service.dualSourceConflict(photoId: fixture.photoId)
        #expect(conflict == nil)
    }
}

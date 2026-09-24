// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Metadata/MetadataServiceTests.swift
// R4：MetadataService 迁入 Runtime/Metadata/ 后的直测。旧 Services 位置无专属用例
// （全仓 grep 证实），故按「测试迁移不丢覆盖」补上此前仅由构建与域 filter 间接
// 覆盖的编排面：
// 1) getPhotosByIds：轻查询经 Store/PhotoStore.photoLookups（空参不触库、幽灵 id
//    缺席）；并覆盖路由层当前仍走的 database 兜底装配路径。
// 2) getMetadata：指纹命中返回缓存投影且不触 provider；未命中走 XMP 有效属性
//    提取 + 缓存 upsert（fileSize/fileMtime 落库）。
// 3) setMetadata：可写字段白名单（不支持字段抛错且不入队/不写缓存）；合并缓存
//    基线、按 manual 入队变更、写缓存并返回合并结果。
// 4) batchSet：逐项失败隔离（成功/失败计数与错误文本）。
// 5) normalizeKeywordList / embeddedAttributesFromParse：纯逻辑（dc:subject 优先
//    IPTC、IPTC-only 返回 nil、rating 数字/字符串强转、label 取值）。
//
// 替身说明：
// - XMPProvider / MetadataMutationPort 用 actor 替身（actor 隔离满足 Sendable，
//   不引入任何并发标注）；fileExists 是同步协议要求，用 nonisolated let 集合实现。
// - 其余依赖用真实 Store（SQLiteMetadataStore / SQLitePhotoStore）+ 迁移库。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 替身

private struct RecordedMutation: Sendable, Equatable {
    let sessionId: String
    let photoId: String
    let patch: MetadataPatch
    let source: MetadataMutationSource
}

private actor MetadataServiceFakeXMP: XMPProvider {
    nonisolated let existingPaths: Set<String>
    private var attributesByPath: [String: MetadataWriteAttributes]
    private(set) var readPaths: [String] = []

    init(attributesByPath: [String: MetadataWriteAttributes] = [:], existingPaths: Set<String> = []) {
        self.attributesByPath = attributesByPath
        self.existingPaths = existingPaths
    }

    func setAttributes(_ photoPath: String, _ attributes: MetadataWriteAttributes) {
        attributesByPath[photoPath] = attributes
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        readPaths.append(photoPath)
        return attributesByPath[photoPath]?.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        readPaths.append(photoPath)
        return attributesByPath[photoPath] ?? MetadataWriteAttributes()
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    nonisolated func fileExists(_ path: String) -> Bool { existingPaths.contains(path) }

    func removeFile(_ path: String) async throws {}
}

private actor MetadataServiceFakeMutations: MetadataMutationPort {
    private(set) var recorded: [RecordedMutation] = []
    private(set) var directValueCalls = 0

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) async throws -> MetadataMutationResult {
        directValueCalls += 1
        return MetadataMutationResult(
            photoId: photoId, xmpPath: "", dirtyFields: [], revision: 1, status: "pending")
    }

    func queueMutation(
        sessionId: String,
        photoId: String,
        patch: MetadataPatch,
        source: MetadataMutationSource
    ) async throws -> MetadataMutationResult {
        recorded.append(RecordedMutation(
            sessionId: sessionId, photoId: photoId, patch: patch, source: source))
        return MetadataMutationResult(
            photoId: photoId,
            xmpPath: "/sidecars/\(photoId).xmp",
            dirtyFields: [.rating, .label, .keywords],
            revision: recorded.count,
            status: "pending"
        )
    }
}

/// exif 分段按文件路径注入（对应 TS exifr.parse 分段输出）。
private struct MetadataServiceFakeExif: ExifProvider {
    let segmentsByPath: [String: MetadataParseSegments]

    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        segmentsByPath[filePath]
    }
}

// MARK: - 基座

private struct MetadataServiceHarness {
    let database: SQLiteDatabase
    let storePath: String
    let photoStore: SQLitePhotoStore
    let metadata: SQLiteMetadataStore
    let xmp: MetadataServiceFakeXMP
    let mutations: MetadataServiceFakeMutations
    let service: MetadataService
}

/// injectPhotoStore=false 走 database 兜底装配（路由层当前仍传 database 的路径）。
private func makeMetadataServiceHarness(
    label: String,
    injectPhotoStore: Bool = true,
    exif: (any ExifProvider)? = nil
) async throws -> MetadataServiceHarness {
    let (database, storePath) = try await makeMigratedStoreDatabase(label: label)
    try await insertSession(database, "s1")
    let photoStore = SQLitePhotoStore(database: database)
    let metadata = SQLiteMetadataStore(database: database)
    let xmp = MetadataServiceFakeXMP()
    let mutations = MetadataServiceFakeMutations()
    let service: MetadataService
    if injectPhotoStore {
        service = MetadataService(
            metadataStore: metadata,
            xmp: xmp,
            database: database,
            mutations: mutations,
            exif: exif,
            photoStore: photoStore
        )
    } else {
        service = MetadataService(
            metadataStore: metadata,
            xmp: xmp,
            database: database,
            mutations: mutations,
            exif: exif
        )
    }
    return MetadataServiceHarness(
        database: database,
        storePath: storePath,
        photoStore: photoStore,
        metadata: metadata,
        xmp: xmp,
        mutations: mutations,
        service: service
    )
}

// MARK: - 用例

@Suite("Runtime/MetadataService (R4)")
struct MetadataServiceTests {

    @Test func photoLookupDelegatesToStoreAndRejectsEmpty() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-lookup")
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")
        try await insertPhoto(harness.database, id: "p2", sessionId: "s1", filepath: "/v/p2.jpg")

        let empty = try await harness.service.getPhotosByIds([])
        #expect(empty.isEmpty, "空参不触库")

        let rows = try await harness.service.getPhotosByIds(["p1", "ghost"])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "p1")
        #expect(rows.first?.sessionId == "s1")
        #expect(rows.first?.filepath == "/v/p1.jpg")
    }

    @Test func photoLookupWorksThroughDatabaseFallbackInit() async throws {
        let harness = try await makeMetadataServiceHarness(
            label: "meta-service-fallback", injectPhotoStore: false)
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/p1.jpg")

        let rows = try await harness.service.getPhotosByIds(["p1"])
        #expect(rows.map(\.id) == ["p1"], "database 兜底装配仍经 Store 查询")
        #expect(rows.first?.sessionId == "s1")
    }

    @Test func getMetadataEmptyIdsIsNoop() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-empty")
        let result = try await harness.service.getMetadata(photoIds: [])
        #expect(result.isEmpty)
    }

    @Test func getMetadataCacheHitUsesFingerprintAndSkipsProviders() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-hit")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(
            in: dir, name: "hit.jpg", content: Data(repeating: 7, count: 123))
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: filepath)

        guard let fingerprint = try await MetadataFingerprint.cacheStalenessKey(filepath) else {
            Issue.record("临时照片应可 stat")
            return
        }
        var input = MetadataCacheInput(rating: 4, label: "Red")
        input.fileSize = Int64(fingerprint.size)
        input.fileMtime = fingerprint.value
        input.keywords = ["kw1"]
        try await harness.metadata.upsertMetadata(photoId: "p1", sessionId: "s1", data: input)

        let result = try await harness.service.getMetadata(photoIds: ["p1"])
        #expect(result["p1"]?.rating == 4)
        #expect(result["p1"]?.label == "Red")
        #expect(result["p1"]?.keywords == ["kw1"])
        #expect(result["p1"]?.fileSize == 123)
        let readPaths = await harness.xmp.readPaths
        #expect(readPaths.isEmpty, "指纹命中不触 provider")
    }

    @Test func getMetadataMissExtractsAttributesAndUpsertsCache() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-miss")
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filepath = try writeTempFile(
            in: dir, name: "miss.jpg", content: Data(repeating: 1, count: 64))
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: filepath)
        await harness.xmp.setAttributes(
            filepath,
            MetadataWriteAttributes(keywords: ["k1", "k2"], rating: 3, label: "Blue"))

        let result = try await harness.service.getMetadata(photoIds: ["p1"])
        #expect(result["p1"]?.keywords == ["k1", "k2"])
        #expect(result["p1"]?.rating == 3)
        #expect(result["p1"]?.label == "Blue")

        let cached = try await harness.metadata.metadata(photoId: "p1")
        #expect(cached?.rating == 3)
        #expect(cached?.label == "Blue")
        #expect(cached?.keywords == ["k1", "k2"])
        #expect(cached?.fileSize == 64, "指纹 size 落库")
        #expect(cached?.fileMtime != nil, "指纹 value 落库")
        let readPaths = await harness.xmp.readPaths
        #expect(readPaths == [filepath])
    }

    @Test func getMetadataStringifiesExifScalarNumbersWithJSStringSemantics() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let integerPath = try writeTempFile(
            in: dir, name: "int.jpg", content: Data(repeating: 2, count: 40))
        let fractionPath = try writeTempFile(
            in: dir, name: "frac.jpg", content: Data(repeating: 3, count: 40))
        let harness = try await makeMetadataServiceHarness(
            label: "meta-service-exif-scalars",
            exif: MetadataServiceFakeExif(segmentsByPath: [
                integerPath: MetadataParseSegments(exif: .object([
                    "ExposureTime": .number(10),
                    "DateTimeOriginal": .number(7),
                ])),
                fractionPath: MetadataParseSegments(exif: .object([
                    "ExposureTime": .number(0.005),
                    "DateTimeOriginal": .number(2.5),
                ])),
            ])
        )
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: integerPath)
        try await insertPhoto(harness.database, id: "p2", sessionId: "s1", filepath: fractionPath)

        let result = try await harness.service.getMetadata(photoIds: ["p1", "p2"])
        #expect(result["p1"]?.shutterSpeed == "10", "整数：JS String(number) 不带 .0 后缀")
        #expect(result["p1"]?.dateTaken == "7")
        #expect(result["p2"]?.shutterSpeed == "0.005", "非整数：保留 Double 形式")
        #expect(result["p2"]?.dateTaken == "2.5")

        let cached = try await harness.metadata.metadata(photoId: "p1")
        #expect(cached?.exposureTime == "10")
        #expect(cached?.dateTaken == "7")
    }

    @Test func setMetadataRejectsUnsupportedFieldsWithoutSideEffects() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-unsupported")
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/u.jpg")

        await #expect(throws: MetadataServiceError.unsupportedFields(["dateTaken"])) {
            _ = try await harness.service.setMetadata(
                photoId: "p1", tags: MetadataTags(dateTaken: "2024:01:01 00:00:00"))
        }
        let recorded = await harness.mutations.recorded
        #expect(recorded.isEmpty, "校验失败不入队")
        let cached = try await harness.metadata.metadata(photoId: "p1")
        #expect(cached == nil, "校验失败不写缓存")
    }

    @Test func setMetadataQueuesManualMutationAndWritesCache() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-set")
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/set.jpg")

        let merged = try await harness.service.setMetadata(
            photoId: "p1",
            tags: MetadataTags(keywords: ["a", "b"], rating: 5, label: "Green"))
        #expect(merged.rating == 5)
        #expect(merged.label == "Green")
        #expect(merged.keywords == ["a", "b"])

        let recorded = await harness.mutations.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.sessionId == "s1")
        #expect(recorded.first?.source == .manual)
        #expect(recorded.first?.patch.rating?.value == 5)
        #expect(recorded.first?.patch.label?.value == "Green")
        #expect(recorded.first?.patch.keywords?.op == .replace)
        #expect(recorded.first?.patch.keywords?.values == ["a", "b"])

        let cached = try await harness.metadata.metadata(photoId: "p1")
        #expect(cached?.rating == 5)
        #expect(cached?.label == "Green")
        #expect(cached?.keywords == ["a", "b"])
    }

    @Test func setMetadataMergesExistingCacheBaseline() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-merge")
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/merge.jpg")
        var baseline = MetadataCacheInput(rating: 2)
        baseline.keywords = ["old"]
        try await harness.metadata.upsertMetadata(photoId: "p1", sessionId: "s1", data: baseline)

        let merged = try await harness.service.setMetadata(
            photoId: "p1", tags: MetadataTags(label: "Yellow"))
        #expect(merged.rating == 2, "未覆盖的缓存基线字段保留")
        #expect(merged.keywords == ["old"])
        #expect(merged.label == "Yellow")
    }

    @Test func batchSetIsolatesItemFailures() async throws {
        let harness = try await makeMetadataServiceHarness(label: "meta-service-batch")
        try await insertPhoto(harness.database, id: "p1", sessionId: "s1", filepath: "/v/b1.jpg")
        try await insertPhoto(harness.database, id: "p2", sessionId: "s1", filepath: "/v/b2.jpg")

        let result = try await harness.service.batchSet(updates: [
            (photoId: "p1", tags: MetadataTags(rating: 1)),
            (photoId: "p2", tags: MetadataTags(dateTaken: "2024:01:01 00:00:00")),
        ])
        #expect(result.success == 1)
        #expect(result.failed == 1)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.hasPrefix("p2:") == true)
        let recorded = await harness.mutations.recorded
        #expect(recorded.map(\.photoId) == ["p1"])
    }

    @Test func keywordNormalizationAndEmbeddedAttributeDerivation() throws {
        #expect(MetadataService.normalizeKeywordList(nil) == nil)
        #expect(MetadataService.normalizeKeywordList(.array([])) == nil)
        #expect(MetadataService.normalizeKeywordList(.string("solo")) == ["solo"])
        // 数字按 JS String(number) 字符串化（与 TS 参考实现一致：7 → "7"）。
        #expect(MetadataService.normalizeKeywordList(.number(7)) == ["7"])
        #expect(MetadataService.normalizeKeywordList(.number(7.5)) == ["7.5"])
        #expect(
            MetadataService.normalizeKeywordList(.array([.string("a"), .number(2), .null]))
                == ["a", "2"])

        let parsed = MetadataParseSegments(
            ifd0: .object(["Rating": .number(2)]),
            xmp: .object(["Rating": .string("4"), "Label": .string("Red")]),
            dc: .object(["subject": .array([.string("dc-kw")])]),
            iptc: .object(["Keywords": .array([.string("iptc-kw")])]))
        let attributes = MetadataService.embeddedAttributesFromParse(parsed)
        #expect(attributes?.keywords == ["dc-kw"], "dc:subject 优先于 IPTC")
        #expect(attributes?.rating == 4, "xmp:Rating 字符串强转数字")
        #expect(attributes?.label == "Red")
        #expect(attributes?.dateTaken == nil)

        let ifd0Only = MetadataParseSegments(ifd0: .object(["Rating": .number(3)]))
        #expect(MetadataService.embeddedAttributesFromParse(ifd0Only)?.rating == 3)
        #expect(MetadataService.embeddedAttributesFromParse(ifd0Only)?.keywords == nil)

        let iptcOnly = MetadataParseSegments(iptc: .object(["Keywords": .array([.string("i")])]))
        #expect(MetadataService.embeddedAttributesFromParse(iptcOnly) == nil, "IPTC-only 关键词回退 exiftool 池")
    }
}

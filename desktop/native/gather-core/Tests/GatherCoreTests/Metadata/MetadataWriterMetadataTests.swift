// Tests/GatherCoreTests/Metadata/MetadataWriterMetadataTests.swift
// mwmeta / W4-3d：MetadataWriter.getMetadata 读路径直测。
// 语义基线：Services/MetadataService.getMetadata 的「缓存命中 / 未命中」分支
// （指纹失效检查与未命中提取 + upsertMetadataBatch 属写面，见 MetadataWriter.getMetadata
// 注释中的有意差异）。覆盖：空 photoIds 不触 Store、全缓存命中返回轻投影、部分未缓存
// 显式标记 capability=unsupported（错误携带已命中缓存）、providerSet 已接线但提取面
// 未接线显式上抛、Store 抛错原样上抛。

import Foundation
import Testing
@testable import GatherCore

@Suite("Metadata/MetadataWriter (mwmeta)")
struct MetadataWriterMetadataTests {

    // MARK: - 基建

    /// 真实 SQLite 库 + 真实 MetadataStore（缓存行经 upsertMetadata 预置）；
    /// metadataStore 可换成抛错替身以证明「未触库 / 上抛」。
    private func makeWriter(
        label: String,
        metadataStore: (any MetadataStore)? = nil,
        providerSet: MetadataProviderSet? = nil
    ) async throws -> (
        writer: MetadataWriter,
        metadata: SQLiteMetadataStore,
        database: SQLiteDatabase,
        path: String
    ) {
        let (database, path) = try await makeMigratedStoreDatabase(label: label)
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        for photoId in ["p1", "p2"] {
            try await database.run(
                """
                INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
                VALUES (?, 's1', ?, 'f.jpg', 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(photoId), .text("/\(photoId).jpg")]
            )
        }
        let outbox = SQLiteWritebackStore(database: database)
        let metadata = SQLiteMetadataStore(database: database)
        let writer = MetadataWriter(
            dependencies: .init(
                writebackStore: outbox,
                metadataStore: metadataStore ?? metadata,
                providerSet: providerSet
            )
        )
        return (writer, metadata, database, path)
    }

    /// 预置 p1 的缓存行（rating/label/keywords 三列轻投影可读）。
    private func seedCache(_ metadata: SQLiteMetadataStore) async throws {
        try await metadata.upsertMetadata(
            photoId: "p1",
            sessionId: "s1",
            data: MetadataCacheInput(rating: 4, label: "Red", keywords: ["nature", "travel"])
        )
    }

    // MARK: - 用例

    @Test func emptyPhotoIdsReturnEmptyWithoutStoreTouch() async throws {
        // Store 替身对任何读都抛错：空参若触库必失败，借此证明早退。
        let (writer, _, _, path) = try await makeWriter(
            label: "mwmeta-empty",
            metadataStore: MwMetaThrowingMetadataStore()
        )
        defer { removeStoreFiles(path) }

        let result = try await writer.getMetadata(photoIds: [])
        #expect(result.isEmpty, "空参返回 [:] 且不得触库")
    }

    @Test func allCachedHitsReturnLightProjection() async throws {
        let (writer, metadata, _, path) = try await makeWriter(label: "mwmeta-hit")
        defer { removeStoreFiles(path) }
        try await seedCache(metadata)

        let result = try await writer.getMetadata(photoIds: ["p1"])

        #expect(Set(result.keys) == ["p1"])
        let tags = try #require(result["p1"])
        #expect(tags.rating == 4)
        #expect(tags.label == "Red")
        #expect(tags.keywords == ["nature", "travel"])
    }

    @Test func partialMissWithoutProviderMarksCapabilityUnsupported() async throws {
        let (writer, metadata, _, path) = try await makeWriter(label: "mwmeta-partial")
        defer { removeStoreFiles(path) }
        try await seedCache(metadata)

        let cached = try await metadata.metadataBatchLite(photoIds: ["p1"])
        let expected = MetadataWriterError.providerUnsupported(
            cached: cached, missingPhotoIds: ["p2"])
        await #expect(throws: expected) {
            _ = try await writer.getMetadata(photoIds: ["p1", "p2"])
        }
    }

    @Test func partialMissWithWiredProviderMarksExtractionDeferred() async throws {
        // provider 集合已接线（尺寸兜底），但提取所需的 photo 路径端口与批量
        // upsert 属写面：必须显式上抛，不得伪造只含命中行的结果。
        let (writer, metadata, _, path) = try await makeWriter(
            label: "mwmeta-deferred",
            providerSet: MetadataProviderSet(dimensions: MwMetaStubDimensions())
        )
        defer { removeStoreFiles(path) }
        try await seedCache(metadata)

        let cached = try await metadata.metadataBatchLite(photoIds: ["p1"])
        let expected = MetadataWriterError.extractionDeferred(
            cached: cached, missingPhotoIds: ["p2"])
        await #expect(throws: expected) {
            _ = try await writer.getMetadata(photoIds: ["p1", "p2"])
        }
    }

    @Test func storeFailuresPropagate() async throws {
        let (writer, _, _, path) = try await makeWriter(
            label: "mwmeta-throw",
            metadataStore: MwMetaThrowingMetadataStore()
        )
        defer { removeStoreFiles(path) }

        await #expect(throws: MwMetaThrowingMetadataStore.InjectedFailure.self) {
            _ = try await writer.getMetadata(photoIds: ["p1"])
        }
    }
}

// MARK: - 替身

/// MetadataStore 替身：所有端口方法抛同一注入错误。getMetadata 只应触碰
/// metadataBatchLite；空参早退不触库，故兼作「0 次读」探针。
private struct MwMetaThrowingMetadataStore: MetadataStore {
    struct InjectedFailure: Error, Equatable {}

    func upsertMetadata(photoId: String, sessionId: String, data: MetadataCacheInput) async throws {
        throw InjectedFailure()
    }

    func upsertMetadataBatch(
        _ entries: [(photoId: String, sessionId: String, data: MetadataCacheInput)]
    ) async throws {
        throw InjectedFailure()
    }

    func mergeMetadata(photoId: String, sessionId: String, data: MetadataCacheInput) async throws {
        throw InjectedFailure()
    }

    func metadataBatchLite(photoIds: [String]) async throws -> [String: MetadataTags] {
        throw InjectedFailure()
    }

    func metadata(photoId: String) async throws -> MetadataCacheRecord? {
        throw InjectedFailure()
    }

    func metadataBatch(photoIds: [String]) async throws -> [MetadataCacheRecord] {
        throw InjectedFailure()
    }

    func ratingLabels(photoIds: [String]) async throws -> [MetadataRatingLabelRow] {
        throw InjectedFailure()
    }

    func deleteMetadataBySession(_ sessionId: String) async throws {
        throw InjectedFailure()
    }

    func deleteMetadataByPhotoId(_ photoId: String) async throws {
        throw InjectedFailure()
    }

    func updateRating(photoId: String, rating: Int64) async throws {
        throw InjectedFailure()
    }

    func updateLabel(photoId: String, label: String) async throws {
        throw InjectedFailure()
    }

    func updateKeywords(photoId: String, keywords: [String]) async throws {
        throw InjectedFailure()
    }

    func markKeywordIntroduced(xmpPath: String, source: String, keywords: [String]) async throws {
        throw InjectedFailure()
    }

    func activeIntroducedKeywords(
        xmpPath: String, source: String, keywords: [String]
    ) async throws -> [String] {
        throw InjectedFailure()
    }

    func deactivateKeywordOrigins(xmpPath: String, source: String, keywords: [String]) async throws {
        throw InjectedFailure()
    }
}

/// 尺寸 provider 替身：只为让 providerSet.isWired == true（本步不调用提取）。
private struct MwMetaStubDimensions: ImageDimensionsProvider {
    func metadata(
        filePath: String
    ) async throws -> (width: Int?, height: Int?, size: Int?, format: String?)? {
        nil
    }
}

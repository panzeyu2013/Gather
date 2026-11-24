// desktop/native/gather-core/Tests/GatherCoreTests/Services/SemanticIndexTests.swift
// P1 §3.11.5：feature print 编解码 + 余弦检索 + 标签匹配 + 场景分组。
import Foundation
import Testing
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

/// 内存语义存储（不碰库：检索逻辑是纯计算 + 一次读）。
private final class FakeSemanticsStore: PhotoSemanticsStore {
    var rows: [String: PhotoSemanticsRow] = [:]

    func upsert(_ inserts: [PhotoSemanticsInsert]) throws {
        for insert in inserts {
            rows[insert.photoId] = PhotoSemanticsRow(
                photoId: insert.photoId,
                sessionId: insert.sessionId,
                labelsJson: insert.labelsJson,
                feature: insert.feature,
                featureDim: insert.featureDim,
                modelVersion: insert.modelVersion,
                computedAt: insert.computedAt)
        }
    }

    func load(photoId: String) throws -> PhotoSemanticsRow? { rows[photoId] }

    func loadRows(sessionId: String, limit: Int) throws -> [PhotoSemanticsRow] {
        let filtered = rows.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.photoId < $1.photoId }
        guard limit > 0 else { return filtered }
        return Array(filtered.prefix(limit))
    }

    func loadRows(sessionId: String, photoIds: [String]) throws -> [PhotoSemanticsRow] {
        photoIds.compactMap { rows[$0] }.filter { $0.sessionId == sessionId }
    }

    func indexedPhotoIds(sessionId: String) throws -> Set<String> {
        Set(rows.values.filter { $0.sessionId == sessionId }.map(\.photoId))
    }

    /// P0-3：2 参重载必须显式实现（协议已删掉默认实现，否则版本语义在单测里不生效）。
    func indexedPhotoIds(sessionId: String, modelVersion: String) throws -> Set<String> {
        Set(rows.values
            .filter { $0.sessionId == sessionId && $0.modelVersion == modelVersion }
            .map(\.photoId))
    }

    func clearStaleRows(sessionId: String, keepingModelVersion: String) throws -> Int {
        let stale = rows.values.filter {
            $0.sessionId == sessionId && $0.modelVersion != keepingModelVersion
        }
        for row in stale { rows.removeValue(forKey: row.photoId) }
        return stale.count
    }

    func count(sessionId: String) throws -> Int {
        rows.values.filter { $0.sessionId == sessionId }.count
    }

    func deleteSession(_ sessionId: String) throws -> Int {
        let ids = rows.values.filter { $0.sessionId == sessionId }.map(\.photoId)
        for id in ids { rows.removeValue(forKey: id) }
        return ids.count
    }

    func deleteAll() throws -> Int {
        let count = rows.count
        rows.removeAll()
        return count
    }
}

/// 造一条语义行：feature 走真实 Float16 编码路径（不做快捷假设）。
private func row(
    photoId: String,
    sessionId: String = "s1",
    vector: [Float],
    labels: [SemanticLabel] = [],
    modelVersion: String = ImageSemanticsExtractor.modelVersion
) -> PhotoSemanticsRow {
    PhotoSemanticsRow(
        photoId: photoId,
        sessionId: sessionId,
        labelsJson: SemanticIndex.encodeLabels(labels),
        feature: SemanticFeatureCodec.encode(vector),
        featureDim: vector.count,
        modelVersion: modelVersion,
        computedAt: "2026-10-30T00:00:00.000Z")
}

@Suite("SemanticFeatureCodec")
struct SemanticFeatureCodecTests {
    @Test("Float16 往返误差小于 0.1%")
    func roundTrip() {
        let values: [Float] = [0, 0.5, -0.25, 1.0, 3.75, -8.5]
        let encoded = SemanticFeatureCodec.encode(values)
        #expect(encoded.count == values.count * 2)
        let decoded = SemanticFeatureCodec.decode(encoded, dimension: values.count)
        #expect(decoded.count == values.count)
        for (original, restored) in zip(values, decoded) {
            #expect(abs(Double(original - restored)) <= max(0.005, abs(Double(original)) * 0.001))
        }
    }

    #if arch(arm64)
    @Test("手写 half 编解码与原生 Float16 逐位一致（arm64）")
    func halfCodecMatchesNative() {
        var decodeMismatches = 0
        var firstDecode = ""
        for bits in UInt16.min...UInt16.max {
            let native = Float(Float16(bitPattern: bits))
            let manual = SemanticFeatureCodec.float(fromHalf: bits)
            let same = native.isNaN ? manual.isNaN : manual == native
            if !same {
                decodeMismatches += 1
                if firstDecode.isEmpty {
                    firstDecode = "\(bits): \(manual) != \(native)"
                }
            }
        }
        #expect(decodeMismatches == 0, "decode mismatches \(decodeMismatches): \(firstDecode)")

        let samples: [Float] = [
            0, -0.0, 0.5, -0.25, 1, 3.14159, 65504, 65520, -65520,
            1e-8, -1e-8, .infinity, -.infinity, .nan,
        ]
        var encodeMismatches = 0
        var firstEncode = ""
        for value in samples {
            let native = Float16(value).bitPattern
            let manual = SemanticFeatureCodec.halfBits(from: value)
            let same = value.isNaN
                ? ((manual & 0x7C00) == 0x7C00 && (manual & 0x03FF) != 0)
                : manual == native
            if !same {
                encodeMismatches += 1
                if firstEncode.isEmpty {
                    firstEncode = "\(value): \(manual) != \(native)"
                }
            }
        }
        #expect(encodeMismatches == 0, "encode mismatches \(encodeMismatches): \(firstEncode)")
    }
    #endif

    @Test("维度不符/空数据 → 空数组（不猜）")
    func rejectsMalformedBlob() {
        let encoded = SemanticFeatureCodec.encode([1, 2, 3])
        #expect(SemanticFeatureCodec.decode(encoded, dimension: 4).isEmpty)
        #expect(SemanticFeatureCodec.decode(nil, dimension: 3).isEmpty)
        #expect(SemanticFeatureCodec.decode(Data([0x01]), dimension: 0).isEmpty)
    }
}

@Suite("SemanticIndex 余弦/标签")
struct SemanticIndexSearchTests {
    @Test("同图不同尺寸：余弦 > 0.95")
    func similarImages() throws {
        let store = FakeSemanticsStore()
        // 同一张图的两次特征：加了极小扰动（Float16 量化级别）。
        let base: [Float] = (0..<64).map { Float($0 % 7) / 7 }
        let near = base.enumerated().map { index, value in
            index % 5 == 0 ? value + 0.001 : value
        }
        let far: [Float] = (0..<64).map { _ in 0.25 }
        try store.upsert([
            PhotoSemanticsInsert(
                photoId: "a", sessionId: "s1", labelsJson: SemanticIndex.encodeLabels([]),
                feature: SemanticFeatureCodec.encode(base), featureDim: base.count,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
            PhotoSemanticsInsert(
                photoId: "b", sessionId: "s1", labelsJson: SemanticIndex.encodeLabels([]),
                feature: SemanticFeatureCodec.encode(near), featureDim: near.count,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
            PhotoSemanticsInsert(
                photoId: "c", sessionId: "s1", labelsJson: SemanticIndex.encodeLabels([]),
                feature: SemanticFeatureCodec.encode(far), featureDim: far.count,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
        ])
        let index = SemanticIndex(store: store)
        let outcome = try index.similar(to: "a", sessionId: "s1", limit: 10, minSimilarity: 0.95)
        #expect(outcome.method == .featurePrint)
        #expect(outcome.hits.map(\.photoId) == ["b"])
        let similarity = outcome.hits.first?.similarity ?? 0
        #expect(similarity > 0.95)
        #expect(similarity <= 1.0)
    }

    @Test("维度不一致的行被跳过，不参与比较")
    func skipsMismatchedDimensions() throws {
        let store = FakeSemanticsStore()
        let vector: [Float] = [1, 0, 0, 0]
        try store.upsert([
            PhotoSemanticsInsert(
                photoId: "a", sessionId: "s1", labelsJson: "[]",
                feature: SemanticFeatureCodec.encode(vector), featureDim: 4,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
            PhotoSemanticsInsert(
                photoId: "b", sessionId: "s1", labelsJson: "[]",
                feature: SemanticFeatureCodec.encode([1, 0, 0]), featureDim: 3,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
        ])
        let index = SemanticIndex(store: store)
        let outcome = try index.similar(to: "a", sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(outcome.skipped == 1)
        #expect(outcome.hits.isEmpty)
    }

    @Test("没有向量时给出原因而不是抛错")
    func unavailableReason() throws {
        let store = FakeSemanticsStore()
        let index = SemanticIndex(store: store)
        let outcome = try index.similar(to: "missing", sessionId: "s1")
        #expect(outcome.hits.isEmpty)
        #expect(outcome.unavailableReason != nil)
    }

    @Test("标签文本匹配：包含匹配 + Jaccard 门槛")
    func labelSearch() throws {
        let store = FakeSemanticsStore()
        let vector: [Float] = [1, 1, 1, 1]
        try store.upsert([
            PhotoSemanticsInsert(
                photoId: "wedding1", sessionId: "s1",
                labelsJson: SemanticIndex.encodeLabels([
                    SemanticLabel(label: "wedding", confidence: 0.8),
                    SemanticLabel(label: "indoor", confidence: 0.4),
                ]),
                feature: SemanticFeatureCodec.encode(vector), featureDim: 4,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
            PhotoSemanticsInsert(
                photoId: "beach1", sessionId: "s1",
                labelsJson: SemanticIndex.encodeLabels([
                    SemanticLabel(label: "beach", confidence: 0.9),
                ]),
                feature: SemanticFeatureCodec.encode(vector), featureDim: 4,
                modelVersion: ImageSemanticsExtractor.modelVersion, computedAt: "t"),
        ])
        let index = SemanticIndex(store: store)
        let outcome = try index.search(sessionId: "s1", labels: ["Wedding"], limit: 10)
        #expect(outcome.method == .labels)
        #expect(outcome.hits.map(\.photoId) == ["wedding1"])
        #expect(outcome.hits.first?.matchedLabels == ["wedding"])
        #expect(outcome.hits.first?.similarity == nil)
        let empty = try index.search(sessionId: "s1", labels: ["  "], limit: 10)
        #expect(empty.hits.isEmpty)
        #expect(empty.unavailableReason != nil)
    }

    @Test("场景分组：标签 Jaccard 与 embedding 两条依据")
    func sceneGroups() {
        let wedding = SemanticVector(
            photoId: "w1", labels: [
                SemanticLabel(label: "wedding", confidence: 0.9),
                SemanticLabel(label: "indoor", confidence: 0.7),
            ], vector: [1, 0, 0], modelVersion: "m")
        let wedding2 = SemanticVector(
            photoId: "w2", labels: [
                SemanticLabel(label: "wedding", confidence: 0.8),
                SemanticLabel(label: "indoor", confidence: 0.6),
            ], vector: [0, 1, 0], modelVersion: "m")
        let sameScene = SemanticVector(
            photoId: "w3", labels: [], vector: [1, 0, 0], modelVersion: "m")
        let other = SemanticVector(
            photoId: "b1", labels: [SemanticLabel(label: "beach", confidence: 0.9)],
            vector: [0, 0, 1], modelVersion: "m")
        let groups = SemanticIndex.cluster([wedding, wedding2, sameScene, other])
        #expect(groups.count == 1)
        #expect(groups.first?.photoIds == ["w1", "w2", "w3"])
        #expect(groups.first?.labels.contains("wedding") == true)
    }

    @Test("余弦：零向量/长度不符返回 -1（不可比，不是 0）")
    func cosineEdgeCases() {
        #expect(SemanticIndex.cosine([1, 0], [0, 1]) == 0)
        #expect(abs(SemanticIndex.cosine([2, 0], [5, 0]) - 1) < 0.0001)
        #expect(SemanticIndex.cosine([0, 0], [1, 0]) == -1)
        #expect(SemanticIndex.cosine([1, 0], [1, 0, 0]) == -1)
        #expect(SemanticIndex.jaccard([], []) == 0)
        #expect(SemanticIndex.jaccard(["a"], ["a"]) == 1)
        #expect(abs(SemanticIndex.jaccard(["a", "b"], ["b", "c"]) - 1.0 / 3.0) < 0.0001)
    }

    @Test("模型版本过滤：vectors()/sceneGroups()/similar() 都不混两种向量空间")
    func modelVersionFiltering() throws {
        let store = FakeSemanticsStore()
        let labels = [SemanticLabel(label: "beach", confidence: 0.9)]
        store.rows["a"] = row(photoId: "a", vector: [1, 0, 0], labels: labels)
        store.rows["b"] = row(photoId: "b", vector: [1, 0, 0], labels: labels)
        // 旧模型版本的同一场景照片：同维但属于另一种向量空间，必须排除。
        store.rows["old"] = PhotoSemanticsRow(
            photoId: "old", sessionId: "s1",
            labelsJson: SemanticIndex.encodeLabels(labels),
            feature: SemanticFeatureCodec.encode([1, 0, 0]), featureDim: 3,
            modelVersion: "vision.fp0", computedAt: "2026-10-30T00:00:00.000Z")
        let index = SemanticIndex(store: store)

        let decoded = try index.vectors(sessionId: "s1")
        #expect(decoded.vectors.map(\.photoId) == ["a", "b"])
        #expect(decoded.skipped == 1, "旧版本行计入 skipped，而不是参与比较")
        #expect(try index.sceneGroups(sessionId: "s1").map(\.photoIds) == [["a", "b"]])
        // scanVectors 走 indexedPhotoIds(2 参)：旧版本照片不能进候选（fake 的显式实现生效）。
        let outcome = try index.similar(to: "a", sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(outcome.hits.map(\.photoId) == ["b"])
    }

    @Test("查询侧版本校验：旧版本查询图/种子不跨向量空间比较，原因是 stale")
    func staleQueryVector() throws {
        let store = FakeSemanticsStore()
        let vector: [Float] = [1, 0, 0]
        // 旧版本行既当查询图也当种子；同会话备一张当前版本候选，证明不是"没得比"。
        store.rows["oldQuery"] = row(
            photoId: "oldQuery", vector: vector, modelVersion: "vision.fp0")
        store.rows["oldSeed"] = row(
            photoId: "oldSeed", vector: vector, modelVersion: "vision.fp0")
        store.rows["freshSeed"] = row(photoId: "freshSeed", vector: vector)
        store.rows["candidate"] = row(photoId: "candidate", vector: vector)
        let index = SemanticIndex(store: store)

        // 查询侧版本校验：旧版本返回 nil（与"没有向量"同一条 unavailable 路径）。
        #expect(try index.vector(photoId: "oldQuery") == nil)
        #expect(try index.vector(photoId: "candidate") != nil)

        // 单张查询图过期：不拿旧向量算余弦，也不假装"没有相似照片"。
        let single = try index.similar(to: "oldQuery", sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(single.hits.isEmpty)
        #expect(single.scanned == 0)
        #expect(single.unavailableReason == SemanticIndex.staleModelVersionReason)

        // 全部种子过期：旧种子计入 skipped，原因同样是 stale。
        let allStale = try index.similar(
            to: ["oldQuery", "oldSeed"], sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(allStale.hits.isEmpty)
        #expect(allStale.skipped == 2, "旧种子计入 skipped")
        #expect(allStale.unavailableReason == SemanticIndex.staleModelVersionReason)

        // 新旧种子混用：旧种子只计 skipped，不污染平均向量，新种子照常命中。
        let mixed = try index.similar(
            to: ["oldSeed", "freshSeed"], sessionId: "s1", limit: 10, minSimilarity: 0.5)
        #expect(mixed.skipped == 1)
        #expect(mixed.hits.map(\.photoId) == ["candidate"])
        #expect(mixed.unavailableReason == nil)
    }
}

// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Culling/CullingAssemblerTests.swift
// W2b 步骤 2：CullingAssembler 纯函数测试（无数据库：最小输入 + 直接断言）。
//
// 语义对照 Services/CullingServiceTests.swift（W2b 完成后随之删除）的 10 个用例：
// listAssemblesFullRows / listFilteredScope / faceNormalization / qualityRelativeRank /
// metadataSourceAndConflictFilter / groupsCountsAndOrder / groupsWithoutResult /
// summaryCounts / summaryTotalGroupsFallback / summaryWithoutSimilarity。
// 其余为搬移后补充的边界守护（groupKey 归一化、损坏输入退化、补丁辅助、索引）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 最小夹具（不触碰数据库）

private func makeRow(
    id: String,
    filepath: String? = nil,
    filename: String? = nil,
    assetId: String? = nil,
    width: Int = 100,
    height: Int = 100,
    metadata: String = "{}",
    result: String = "{}",
    status: String = "pending"
) -> CullingPhotoRow {
    let path = filepath ?? "/shoot/\(id).jpg"
    return CullingPhotoRow(
        id: id, sessionId: "session", filepath: path,
        filename: filename ?? (path as NSString).lastPathComponent,
        checksum: "", status: status,
        assetId: assetId, assetFileId: nil,
        width: width, height: height,
        metadata: metadata, result: result,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeDecision(
    photoId: String,
    decision: String = "pending",
    rating: Int64 = 0,
    colorLabel: String = "None",
    decisionSource: String = "manual",
    revision: Int64 = 1
) -> CullingDecisionRecord {
    CullingDecisionRecord(
        id: 1, sessionId: "session", photoId: photoId, groupId: "ungrouped",
        decision: decision, rating: rating, colorLabel: colorLabel,
        decisionSource: decisionSource, revision: revision,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeCache(
    photoId: String,
    rating: Int64 = 0,
    label: String? = nil,
    keywordsJSON: String = "[]"
) -> MetadataCacheRecord {
    MetadataCacheRecord(
        id: 1, photoId: photoId, sessionId: "session",
        dateTaken: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
        focalLength: nil, fNumber: nil, exposureTime: nil, iso: nil,
        rating: rating, label: label, gpsLatitude: nil, gpsLongitude: nil,
        width: nil, height: nil, fileSize: nil, fileMtime: nil,
        keywordsJSON: keywordsJSON,
        cachedAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeQuality(
    score: Double,
    status: CullingQualityStatus = .succeeded,
    relativeRank: Double? = nil
) -> CullingQuality {
    CullingQuality(
        status: status, score: score, sharpness: 0, exposure: 0,
        relativeRank: relativeRank, warnings: []
    )
}

private func makeOutbox(xmpPath: String, patchJSON: String, status: String) -> OutboxRecord {
    OutboxRecord(
        xmpPath: xmpPath, ownerSessionId: "session", createdBySessionId: "session",
        photoPath: "", patchJSON: patchJSON, dirtyFields: "[]", sourceModule: "culling",
        revision: 1, persistedRevision: 0, baseFingerprint: "", baseValuesJSON: "{}",
        backupPath: "", status: status, attemptCount: 0, errorMessage: "",
        updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeResult(
    id: Int64 = 9,
    statsJson: String,
    groupsJson: String = #"{"groups":[]}"#
) -> SimilarityResultRecord {
    SimilarityResultRecord(
        id: id, sessionId: "session", groupsJson: groupsJson, statsJson: statsJson,
        paramThreshold: 10, paramMinGroupSize: 2,
        createdAt: "2026-01-01T00:00:00.000Z"
    )
}

// MARK: - 测试

@Suite("CullingAssembler")
struct CullingAssemblerTests {

    // MARK: 列表装配（旧 listAssemblesFullRows / listFilteredScope）

    @Test("list() 全量装配：metadata JSON 解析 + session 级富化")
    func listAssemblesFullRows() {
        let row = makeRow(id: "p1", filepath: "/shoot/a.jpg", metadata: #"{"make":"Nikon"}"#)

        let assets = CullingAssembler.assembleAssets(photos: [row], lookup: CullingAssetLookup())

        #expect(assets.count == 1)
        #expect(assets[0].photo.id == "p1")
        #expect(assets[0].photo.metadata["make"] == .string("Nikon"))
        #expect(assets[0].photo.faceCount == 0)
        #expect(assets[0].state.pickState == .unreviewed)
        #expect(assets[0].state.rating == 0)
        #expect(assets[0].state.colorLabel == .none)
        #expect(assets[0].state.source == .imported)
        #expect(assets[0].syncStatus == .clean)
        #expect(assets[0].linkedVariantCount == 1)
        #expect(assets[0].xmpPath == "/shoot/a.xmp")
        // linkedCounts 由 LookupLoader 提供（断言透传）。
        let linked = CullingAssembler.assembleAssets(
            photos: [row],
            lookup: CullingAssetLookup(linkedCounts: ["/shoot/a.xmp": 2])
        )
        #expect(linked[0].linkedVariantCount == 2)
    }

    @Test("list() filtered 经 matches 过滤；metadataConflictOnly 只在 JS 层应用")
    func listFilteredScope() {
        let row = makeRow(id: "p1", filepath: "/shoot/a.jpg")
        let cacheOnly = makeRow(id: "p2", filepath: "/shoot/b.jpg")
        var lookup = CullingAssetLookup()
        lookup.decisions["p1"] = makeDecision(photoId: "p1", decision: "keep", rating: 5)
        lookup.cacheRows["p1"] = makeCache(photoId: "p1", label: "Red")
        lookup.cacheRows["p2"] = makeCache(photoId: "p2", label: "Red")
        let assets = CullingAssembler.assembleAssets(photos: [row, cacheOnly], lookup: lookup)

        #expect(assets[0].state.pickState == .picked)
        #expect(assets[0].state.rating == 5)
        // 决策行存在：行的 color_label('None') 覆盖 cache 的 'Red'（rowToState 语义）。
        #expect(assets[0].state.colorLabel == .none)
        #expect(assets[1].state.colorLabel == .red)
        #expect(assets[1].state.pickState == .unreviewed)

        let kept = CullingAssembler.filterVisible(
            assets, scope: .filtered,
            filters: CullingFilters(ratings: [5], pickStates: [.picked]),
            requestedGroupId: nil
        )
        #expect(kept.count == 1)
        #expect(kept[0].state.rating == 5)
        // colorLabels 谓词：p1 的行标签 'None' 不匹配，p2 的 cache 'Red' 匹配。
        #expect(CullingAssembler.filterVisible(
            assets, scope: .filtered, filters: CullingFilters(colorLabels: [.red]),
            requestedGroupId: nil
        ).map(\.photo.id) == ["p2"])

        let excluded = CullingAssembler.filterVisible(
            assets, scope: .filtered, filters: CullingFilters(ratings: [3]),
            requestedGroupId: nil
        )
        #expect(excluded.isEmpty)

        // scope = all 忽略 filters（与 TS list() 一致）：两条资产都返回。
        #expect(CullingAssembler.filterVisible(
            assets, scope: .all, filters: CullingFilters(ratings: [3]), requestedGroupId: nil
        ).map(\.photo.id) == ["p1", "p2"])

        // CullingFilters → SQL 规格（五个维度编译进同一规格；无约束时退化为空列表）。
        let specs = CullingAssembler.specs(from: CullingFilters(
            ratings: [5], pickStates: [.picked], colorLabels: [.red],
            unreviewedOnly: true, qualityStatus: .analysed
        ))
        #expect(specs.count == 1)
        #expect(CullingAssembler.specs(from: nil).isEmpty)
        #expect(CullingAssembler.specs(from: CullingFilters(ratings: [])).isEmpty)
        #expect(CullingAssembler.specs(from: CullingFilters(ratings: [5])).count == 1)
        #expect(!CullingAssembler.matches(assets[0], specs: specs, metadataConflictOnly: false))

        // unreviewedOnly：已决策资产被排除。
        let unreviewed = CullingAssembler.specs(from: CullingFilters(unreviewedOnly: true))
        #expect(!CullingAssembler.matches(assets[0], specs: unreviewed, metadataConflictOnly: false))
    }

    // MARK: 资产富化（旧 faceNormalization / qualityRelativeRank / metadataSourceAndConflictFilter）

    @Test("面孔归一化：归一化 bbox 保留，预览像素坐标换算并 clamp，按面积降序")
    func faceNormalization() {
        let row = makeRow(id: "p1", width: 200, height: 100)
        var lookup = CullingAssetLookup()
        // 照片级 analysisMax 取首行分析签名（loadFaces 语义）：100 → 缩放 0.5。
        lookup.facesByPhoto["p1"] = [[0.1, 0.2, 0.3, 0.4], [50, 25, 100, 50]]
        lookup.analysisMaxByPhoto["p1"] = 100

        let assets = CullingAssembler.assembleAssets(photos: [row], lookup: lookup)

        #expect(assets[0].photo.faceCount == 2)
        let faces = assets[0].faceBboxes
        #expect(faces.count == 2)
        // 面积降序：像素版 0.5*1.0=0.5 最大在前；clamp 到 1。
        #expect(faces[0] == [0.5, 0.5, 1.0, 1.0])
        #expect(faces[1] == [0.1, 0.2, 0.3, 0.4])

        // 无分析签名（旧行）→ getNumber 兜底 2048，不缩放 → 像素除以原始尺寸。
        let fallback = CullingAssembler.assembleAssets(
            photos: [row],
            lookup: CullingAssetLookup(facesByPhoto: ["p1": [[50, 25, 100, 50]]])
        )
        #expect(fallback[0].faceBboxes == [[0.25, 0.25, 0.5, 0.5]])

        // 注入的 getNumber 生效（100 → analysisWidth=100 → 像素归一化）。
        let injected = CullingAssembler.assembleAssets(
            photos: [row],
            lookup: CullingAssetLookup(facesByPhoto: ["p1": [[50, 25, 100, 50]]]),
            getNumber: { _, _ in 100 }
        )
        #expect(injected[0].faceBboxes == [[0.5, 0.5, 1.0, 1.0]])

        // 直接调用：越界值 clamp、损坏行（<4 列）丢弃。
        #expect(CullingAssembler.normalizedFaceBoxes(
            [[50, 25, 200, 200], [0, 0, 0]],
            analysisMax: 100, width: 100, height: 100
        ) == [[0.5, 0.25, 1.0, 1.0]])
    }

    @Test("质量相对排名：同组成功质量按分数降序 1 起排名")
    func qualityRelativeRank() {
        let photos = [makeRow(id: "p1"), makeRow(id: "p2")]
        let similarityMap = ["p1": "9:0", "p2": "9:0"]
        let base = ["p1": makeQuality(score: 0.8), "p2": makeQuality(score: 0.9)]
        var lookup = CullingAssetLookup()
        lookup.similarityMap = similarityMap
        lookup.qualityByPhoto = CullingAssembler.applyRelativeRank(
            base, similarityMap: similarityMap
        )

        let assets = CullingAssembler.assembleAssets(photos: photos, lookup: lookup)
        let byId = Dictionary(uniqueKeysWithValues: assets.map { ($0.photo.id, $0) })

        #expect(byId["p2"]?.quality?.relativeRank == 1)
        #expect(byId["p1"]?.quality?.relativeRank == 2)
        #expect(byId["p1"]?.similarityGroupId == "9:0")

        // 失败结果 / 无组结果不参与排名。
        let ranked = CullingAssembler.applyRelativeRank(
            [
                "a": makeQuality(score: 0.5),
                "b": makeQuality(score: 0.9, status: .failed),
                "c": makeQuality(score: 0.9),
            ],
            similarityMap: ["a": "9:0", "b": "9:0"]
        )
        #expect(ranked["a"]?.relativeRank == 1)
        #expect(ranked["b"]?.relativeRank == nil)
        #expect(ranked["c"]?.relativeRank == nil)
    }

    @Test("metadataSource 从 outbox patch 解析；conflict 状态驱动 metadataConflictOnly 过滤")
    func metadataSourceAndConflictFilter() {
        let p1 = makeRow(id: "p1")
        let p2 = makeRow(id: "p2")
        var lookup = CullingAssetLookup()
        lookup.outboxByPath["/shoot/p1.xmp"] = makeOutbox(
            xmpPath: "/shoot/p1.xmp",
            patchJSON: #"{"rating":5,"source":"face-keyword"}"#,
            status: "conflict"
        )

        let assets = CullingAssembler.assembleAssets(photos: [p1, p2], lookup: lookup)

        #expect(assets[0].metadataSource == .faceKeyword)
        #expect(assets[0].syncStatus == .conflict)
        #expect(assets[1].metadataSource == nil)
        #expect(assets[1].syncStatus == .clean)

        // metadataConflictOnly 只在 JS 层应用（SQL 无此下推）。
        let conflicts = CullingAssembler.filterVisible(
            assets, scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: true), requestedGroupId: nil
        )
        #expect(conflicts.map(\.photo.id) == ["p1"])
        let all = CullingAssembler.filterVisible(
            assets, scope: .filtered,
            filters: CullingFilters(metadataConflictOnly: false), requestedGroupId: nil
        )
        #expect(all.map(\.photo.id) == ["p1", "p2"])

        // 损坏 patch / 未知 source：不产生 metadataSource，syncStatus 仍透传。
        var broken = CullingAssetLookup()
        broken.outboxByPath["/shoot/p2.xmp"] = makeOutbox(
            xmpPath: "/shoot/p2.xmp", patchJSON: "not json", status: "pending"
        )
        broken.outboxByPath["/shoot/p1.xmp"] = makeOutbox(
            xmpPath: "/shoot/p1.xmp",
            patchJSON: #"{"source":"bogus"}"#, status: "clean"
        )
        let brokenAssets = CullingAssembler.assembleAssets(photos: [p1, p2], lookup: broken)
        #expect(brokenAssets[0].metadataSource == nil)
        #expect(brokenAssets[1].metadataSource == nil)
        #expect(brokenAssets[1].syncStatus == .pending)
    }

    @Test("qualityStatus 谓词：analysed=succeeded / failed / unanalysed=无质量行")
    func qualityStatusSpecs() {
        var lookup = CullingAssetLookup()
        lookup.qualityByPhoto = [
            "good": makeQuality(score: 0.9),
            "bad": makeQuality(score: 0.1, status: .failed),
        ]
        let photos = ["good", "bad", "none"].map { makeRow(id: $0) }
        let assets = CullingAssembler.assembleAssets(photos: photos, lookup: lookup)

        func ids(_ status: CullingFilterQualityStatus) -> [String] {
            CullingAssembler.filterVisible(
                assets, scope: .filtered,
                filters: CullingFilters(qualityStatus: status), requestedGroupId: nil
            ).map(\.photo.id)
        }
        #expect(ids(.analysed) == ["good"])
        #expect(ids(.failed) == ["bad"])
        #expect(ids(.unanalysed) == ["none"])
    }

    // MARK: 相似度组（旧 groupsCountsAndOrder / groupsWithoutResult）

    @Test("getGroups 计数 keep/reject/pending 并按 groupIndex 排序")
    func groupsCountsAndOrder() {
        let photos = ["p1", "p2", "p3", "p4", "p5", "p6"].map { makeRow(id: $0) }
        let membership = [
            "p1": "9:1", "p2": "9:1", "p3": "9:1", "p4": "9:0", "p5": "9:0",
        ]
        let decisions = ["p1": "keep", "p2": "reject"]

        let groups = CullingAssembler.groups(
            photos: photos, membership: membership, decisions: decisions
        )

        #expect(groups.count == 2)
        #expect(groups.map(\.groupIndex) == [0, 1])
        let group0 = groups[0]
        #expect(group0.groupId == "9:0")
        #expect(group0.images.map(\.photoId) == ["p4", "p5"])
        #expect(group0.keepCount == 0)
        #expect(group0.rejectCount == 0)
        #expect(group0.pendingCount == 2)
        let group1 = groups[1]
        #expect(group1.groupId == "9:1")
        #expect(group1.images.map(\.photoId) == ["p1", "p2", "p3"])
        #expect(group1.keepCount == 1)
        #expect(group1.rejectCount == 1)
        #expect(group1.pendingCount == 1)
        #expect(group1.images[0].decision == .keep)
        #expect(group1.images[0].filepath == "/shoot/p1.jpg")
        #expect(group1.images[0].filename == "p1.jpg")
        #expect(group1.images[2].decision == .pending)

        // 损坏组 id：索引解析退化 0，但排序稳定（同索引按首次出现序）。
        let corrupt = CullingAssembler.groups(
            photos: [makeRow(id: "x")],
            membership: ["x": "broken"], decisions: [:]
        )
        #expect(corrupt.count == 1)
        #expect(corrupt[0].groupIndex == 0)
        #expect(corrupt[0].groupId == "broken")
    }

    @Test("无相似度结果时 groups 为空")
    func groupsWithoutResult() {
        let photos = [makeRow(id: "p1")]
        #expect(CullingAssembler.groups(photos: photos, membership: [:], decisions: [:]).isEmpty)

        // 成员表无该照片（未入组）同样为空。
        #expect(CullingAssembler.groups(
            photos: photos, membership: ["other": "9:0"], decisions: [:]
        ).isEmpty)
    }

    // MARK: 徽标计数（旧 summaryCounts / summaryTotalGroupsFallback / summaryWithoutSimilarity）

    @Test("summary 计数 kept/rejected/pending/rated/labeled + totalGroups（stats_json）")
    func summaryCounts() {
        let photos = ["p1", "p2", "p3", "p4", "p5"].map { makeRow(id: $0) }
        let decisions = [
            "p1": makeDecision(photoId: "p1", decision: "keep", rating: 5),
            "p2": makeDecision(photoId: "p2", decision: "keep"),
            "p3": makeDecision(photoId: "p3", decision: "reject"),
        ]
        let cacheByPhoto: [String: (rating: Int64, label: String?)] = [
            "p4": (rating: 3, label: "Red"),
        ]

        let summary = CullingAssembler.summary(
            photos: photos, decisions: decisions, cacheByPhoto: cacheByPhoto,
            result: makeResult(statsJson: #"{"totalGroups":3}"#)
        )

        #expect(summary.totalPhotos == 5)
        #expect(summary.kept == 2)
        #expect(summary.rejected == 1)
        #expect(summary.pending == 2)
        #expect(summary.rated == 2) // p1(5) + p4(cache 3)
        #expect(summary.labeled == 1) // p4 的 cache 'Red'
        #expect(summary.totalGroups == 3)

        // 决策行 rating 覆盖 cache；label 'None' 不计入 labeled。
        let override = CullingAssembler.summary(
            photos: [makeRow(id: "p4")],
            decisions: ["p4": makeDecision(photoId: "p4", rating: 2, colorLabel: "None")],
            cacheByPhoto: ["p4": (rating: 5, label: "Blue")],
            result: nil
        )
        #expect(override.rated == 1)
        #expect(override.labeled == 0)
    }

    @Test("totalGroups 在 stats_json 缺 totalGroups 时回退 groups_json 长度")
    func summaryTotalGroupsFallback() {
        let summary = CullingAssembler.summary(
            photos: [makeRow(id: "p1")], decisions: [:], cacheByPhoto: [:],
            result: makeResult(statsJson: "{}", groupsJson: #"{"groups":[{}, {}, {}]}"#)
        )
        #expect(summary.totalGroups == 3)
    }

    @Test("无相似度结果时 totalGroups 为 0")
    func summaryWithoutSimilarity() {
        let summary = CullingAssembler.summary(
            photos: [makeRow(id: "p1")], decisions: [:], cacheByPhoto: [:], result: nil
        )
        #expect(summary.totalGroups == 0)
        #expect(summary.pending == 1)

        // 损坏 stats_json/groups_json 同样退化为 0。
        #expect(CullingAssembler.parseTotalGroups(
            makeResult(statsJson: "not json", groupsJson: "also not json")
        ) == 0)
    }

    // MARK: 新增边界守护

    @Test("groupKey 归一化空 asset_id；RAW 优先折叠变体")
    func groupKeyAndVariantFold() {
        #expect(CullingAssembler.groupKey(assetId: nil, photoId: "p1") == "photo:p1")
        #expect(CullingAssembler.groupKey(assetId: "", photoId: "p1") == "photo:p1")
        #expect(CullingAssembler.groupKey(assetId: "a1", photoId: "p1") == "a1")
        #expect(CullingAssembler.isPreferredVariant(filename: "A.NEF"))
        #expect(CullingAssembler.isPreferredVariant(filename: "a.arw"))
        #expect(!CullingAssembler.isPreferredVariant(filename: "a.jpg"))
        #expect(!CullingAssembler.isPreferredVariant(filename: "noext"))

        // 配对折叠：RAW 首选，变体顺序保留首见，role primary/variant。
        let jpg = makeRow(id: "pair-jpg", filepath: "/shoot/pair.jpg", assetId: "pair")
        let raw = makeRow(id: "pair-raw", filepath: "/shoot/pair.NEF", assetId: "pair")
        let assets = CullingAssembler.assembleAssets(
            photos: [jpg, raw], lookup: CullingAssetLookup()
        )
        #expect(assets.count == 1)
        #expect(assets[0].photo.id == "pair-raw")
        #expect(assets[0].photo.variantCount == 2)
        #expect(assets[0].photo.variants?.map(\.photoId) == ["pair-jpg", "pair-raw"])
        #expect(assets[0].photo.variants?.map(\.role) == ["variant", "primary"])

        // 空串 asset_id 不把互不相关的照片折成同一资产。
        let a = makeRow(id: "a", assetId: "")
        let b = makeRow(id: "b", assetId: "")
        #expect(CullingAssembler.assembleAssets(
            photos: [a, b], lookup: CullingAssetLookup()
        ).count == 2)
        #expect(CullingAssembler.photosByAssetIndex([a, b]).isEmpty)
    }

    @Test("photosByAssetIndex / linkedByXmpIndex：变体聚合与共享侧车")
    func indexes() {
        let jpg = makeRow(id: "v-jpg", filepath: "/shoot/v.jpg", assetId: "v")
        let raw = makeRow(id: "v-raw", filepath: "/shoot/v.NEF", assetId: "v")
        let solo = makeRow(id: "solo")

        let byAsset = CullingAssembler.photosByAssetIndex([jpg, raw, solo])
        #expect(byAsset.count == 1)
        #expect(byAsset["v"]?.map(\.id) == ["v-jpg", "v-raw"])

        let byXmp = CullingAssembler.linkedByXmpIndex([jpg, raw, solo])
        #expect(byXmp["/shoot/v.xmp"]?.map(\.id) == ["v-jpg", "v-raw"])
        #expect(byXmp["/shoot/solo.xmp"]?.map(\.id) == ["solo"])
        #expect(byXmp.count == 2)
    }

    @Test("state：决策行优先，cache 兜底，非法 rating/label 归一化")
    func stateFallback() {
        // 无决策行：rating/label 取 cache，source=imported，revision=0。
        let cache = makeCache(photoId: "p1", rating: 4, label: "Green")
        let noRow = CullingAssembler.state(photoId: "p1", decision: nil, cache: cache)
        #expect(noRow.pickState == .unreviewed)
        #expect(noRow.rating == 4)
        #expect(noRow.colorLabel == .green)
        #expect(noRow.source == .imported)
        #expect(noRow.revision == 0)
        #expect(noRow.updatedAt == "")

        // 决策行优先（rating 原样透出；source 合法值透传）。
        let row = makeDecision(
            photoId: "p1", decision: "keep", rating: 5,
            colorLabel: "Red", decisionSource: "ai", revision: 3
        )
        let withRow = CullingAssembler.state(photoId: "p1", decision: row, cache: cache)
        #expect(withRow.pickState == .picked)
        #expect(withRow.rating == 5)
        #expect(withRow.colorLabel == .red)
        #expect(withRow.source == .ai)
        #expect(withRow.revision == 3)
        #expect(withRow.updatedAt == "2026-01-01T00:00:00.000Z")

        // 非法 cache label → none；越界 cache rating → 0。
        let bad = CullingAssembler.state(
            photoId: "p2", decision: nil,
            cache: makeCache(photoId: "p2", rating: 9, label: "Chartreuse")
        )
        #expect(bad.rating == 0)
        #expect(bad.colorLabel == .none)

        // 决策行存在但 label/source 非法 → none / manual。
        let badRow = CullingAssembler.state(
            photoId: "p3",
            decision: makeDecision(
                photoId: "p3", decision: "weird", colorLabel: "", decisionSource: "bogus"
            ),
            cache: nil
        )
        #expect(badRow.pickState == .unreviewed)
        #expect(badRow.colorLabel == .none)
        #expect(badRow.source == .manual)

        // 无行无 cache 的裸状态。
        let bare = CullingAssembler.state(photoId: "p4", decision: nil, cache: nil)
        #expect(bare.rating == 0)
        #expect(bare.colorLabel == .none)
    }

    @Test("pickState/legacyDecision/fields/patch/matchesSnapshot 辅助")
    func patchHelpers() {
        #expect(CullingAssembler.pickState("keep") == .picked)
        #expect(CullingAssembler.pickState("reject") == .rejected)
        #expect(CullingAssembler.pickState("pending") == .unreviewed)
        #expect(CullingAssembler.pickState(nil) == .unreviewed)
        #expect(CullingAssembler.pickState(LegacyCullingDecision.keep) == .picked)
        #expect(CullingAssembler.pickState(LegacyCullingDecision.reject) == .rejected)
        #expect(CullingAssembler.pickState(LegacyCullingDecision.pending) == .unreviewed)
        #expect(CullingAssembler.legacyDecision(.picked) == .keep)
        #expect(CullingAssembler.legacyDecision(.rejected) == .reject)
        #expect(CullingAssembler.legacyDecision(.unreviewed) == .pending)

        let patch = CullingUpdatePatch(rating: 4, colorLabel: .blue)
        #expect(CullingAssembler.fields(patch) == [.rating, .colorLabel])
        #expect(CullingAssembler.fields(CullingUpdatePatch()).isEmpty)

        let snapshot = CullingStateSnapshot(pickState: .picked, rating: 4, colorLabel: .blue)
        let rebuilt = CullingAssembler.patch(fields: [.pickState, .colorLabel], snapshot: snapshot)
        #expect(rebuilt.rating == nil)
        #expect(rebuilt.pickState == .picked)
        #expect(rebuilt.colorLabel == .blue)

        let state = AssetCullingState(
            photoId: "p1", pickState: .picked, rating: 4, colorLabel: .blue,
            source: .manual, revision: 1, updatedAt: ""
        )
        #expect(CullingAssembler.matchesSnapshot(state: state, snapshot: snapshot, field: .pickState))
        #expect(CullingAssembler.matchesSnapshot(state: state, snapshot: snapshot, field: .rating))
        #expect(CullingAssembler.matchesSnapshot(state: state, snapshot: snapshot, field: .colorLabel))

        let diverged = CullingStateSnapshot(pickState: .rejected, rating: 0, colorLabel: .none)
        #expect(!CullingAssembler.matchesSnapshot(state: state, snapshot: diverged, field: .pickState))
        #expect(!CullingAssembler.matchesSnapshot(state: state, snapshot: diverged, field: .rating))
        #expect(!CullingAssembler.matchesSnapshot(state: state, snapshot: diverged, field: .colorLabel))
    }

    @Test("parseJSONRecord / parseTotalGroups 损坏输入退化")
    func parseDegrades() {
        #expect(CullingAssembler.parseJSONRecord("not json").isEmpty)
        #expect(CullingAssembler.parseJSONRecord("[1,2]").isEmpty)

        // 多 MB groups_json 只为旧行解析；stats_json 优先、越界/非整数退化。
        #expect(CullingAssembler.parseTotalGroups(
            makeResult(statsJson: #"{"totalGroups":4}"#, groupsJson: #"{"groups":[{},{}]}"#)
        ) == 4)
        #expect(CullingAssembler.parseTotalGroups(
            makeResult(statsJson: #"{"totalGroups":2.5}"#)
        ) == 0)
        #expect(CullingAssembler.parseTotalGroups(
            makeResult(statsJson: #"{"totalGroups":-1}"#)
        ) == 0)
        #expect(CullingAssembler.parseTotalGroups(
            makeResult(statsJson: #"{"totalGroups":"3"}"#)
        ) == 0)
    }
}

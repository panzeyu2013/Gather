// desktop/native/gather-core/Tests/GatherCoreTests/Face/FaceMarginDecisionTests.swift
// C 组（相近身份 + face_match_margin）**生产路径**验证：FaceKwService.analyze →
// matchClustersAgainstLibrary → face_clusters.matched_person_id。
//
// 背景（R2 阻断 2）：旧版在 FaceClusteringAccuracyTests.swift 里复刻了一份
// bindByMargin 判定（人物级 best/亚军），只测了「测试自己写的规则」，没测生产决策。
// 本文件改为：用真实 FaceKwService 夹具（注入推理 embedding + personRepo.saveEmbeddings
// 播种人物库 + analyze）跑出真实 matched_person_id，再统计错绑/正确绑定/歧义/精度。
// 本文件**不复制** margin 判定；只用生产同一函数 FaceMatcher.bestScoresPerPerson 复算
// 「人物级亚军 gap」以标注未绑定的原因（歧义 vs 低于阈值），并断言该复算与生产落库
// 结果一致（ruleMismatches == 0），证明落库数字确实来自文档化规则。
//
// ── 阈值常量来源（ruleMismatches == 0 不能替代这项）──────────────────
// - threshold = 0.6（见下方 let threshold）：**本测试选定**的匹配合格线，显式写进
//   persons.match_threshold；它不是生产默认值，也不是调优结论。
// - 生产给「人脸 person」的 match_threshold 兜底值是 0.65
//   （FaceKwService.defaultPersonMatchThreshold = 0.65，与 persons.match_threshold
//   列默认值 0.65 一致；只在人物没有自己的阈值时生效）。
// - 因此本文件 ruleMismatches == 0 只证明「生产落库决策与用同一 0.6 复算的文档化
//   规则一致」，**不等于验证了生产阈值来源本身**：0.65 兜底路径、阈值该取多少、
//   真实素材上的合格线都未被本文件覆盖（下方只额外断言兜底常量的值，不覆盖其行为）。
//
// ── 诚实性边界（必读） ──────────────────────────────────────────────
// 1. 单 seed（20_260_941/942）、固定 48 条合成查询、库为 6 身份 × 4 条合成 embedding。
//    合成 embedding 层不等于真实人脸识别精度；本文件不能替代 Stretch 门。
// 2. 结论只对「本次合成观测集」成立：真实库的样本数、类间分布、质量分布都不同，
//    默认 margin=0.01 是否合适必须由真实标注素材验收。本文件只证明
//      (a) 生产路径确实按文档化规则做人物级 margin 决策（ruleMismatches == 0）；
//      (b) 在本分布上 margin 的 错绑/歧义/覆盖率 取舍曲线（含默认 0.01）；
//      (c) 「少绑定」不被冒充成「更准」：同覆盖率 precision@K 单独一列。
// 3. 每个查询用 2 张照片承载同一 embedding（各 1 条观测）⇒ minPts=2 必成 2 点簇，
//    簇与查询一一对应（mergedClusters 断言防意外合并）；analyze 用 eps=0.99，保证
//    不同查询之间不会连成同簇（0.99 高于本分布任意两查询的余弦）。

import Foundation
import Testing

@testable import GatherCore

// MARK: - 生产 margin 夹具

/// 单位化（本文件只需要这一个向量工具，避免依赖其他测试文件的私有实现）。
private func normalizedFloats(_ vector: [Float]) -> [Float] {
    var sumSquares = 0.0
    for value in vector { sumSquares += Double(value) * Double(value) }
    let norm = sumSquares.squareRoot()
    guard norm > 0 else { return vector }
    return vector.map { Float(Double($0) / norm) }
}

/// 构造 1 条「近并列」查询：取库中身份 0/1 各一条样本，查询 = 两样本之和 + 微小偏置
/// （偏向身份 1）。两侧人物级最佳相差 ~1e-5 量级 ⇒ margin ≥ 0.005 起即判为歧义
/// （专用于让 margin 路径，含出货默认 0.01，真正被触发）；标签按身份 0 记账——它是
/// 真实歧义样本：margin=0 时被强制绑定到身份 1（记为错绑），margin>0 时应拒绑。
/// 只放 1 条：这类查询彼此余弦 ≈ 1，多于 1 条会在 eps=0.99 下自聚成一个跨查询簇，
/// 破坏「簇 ↔ 查询」一一对应。
private func makeNearTieQuery(
    library: [(identityIndex: Int, embedding: [Float])]
) -> [(identityIndex: Int, embedding: [Float])] {
    guard let row0 = library.first(where: { $0.identityIndex == 0 })?.embedding,
        let row1 = library.first(where: { $0.identityIndex == 1 })?.embedding,
        row0.count == row1.count
    else { return [] }
    let bias: Float = 2e-4
    var sum = [Float](repeating: 0, count: row0.count)
    for k in 0..<row0.count { sum[k] = row0[k] + row1[k] + bias * row1[k] }
    return [(identityIndex: 0, embedding: normalizedFloats(sum))]
}

/// 一条已绑定决策（全部由 face_clusters.matched_person_id / match_confidence 折出）。
private struct BoundDecision {
    let queryIndex: Int
    let expectedPersonId: String
    let personId: String
    let confidence: Double

    var isCorrect: Bool { expectedPersonId == personId }
}

/// 一次生产 analyze 的绑定统计。
private struct ProductionMarginRun {
    let margin: Double
    let queryCount: Int
    let clusterCount: Int
    let memberCount: Int
    let correctBinds: Int
    let wrongBinds: Int
    /// 未绑定且「有 ≥2 个达阈人物、冠军与人物级亚军差距 < margin」。
    let ambiguous: Int
    /// 未绑定且「无任何达阈人物」。
    let belowThreshold: Int
    let unbound: Int
    /// 未绑定但复算规则说应当绑定（生产与规则不一致的异常，必须为 0）。
    let unexpectedUnbound: Int
    /// 一个簇映射到多个查询（意外的簇合并，必须为 0）。
    let mergedClusters: Int
    /// 生产落库决定与复算规则不一致的簇数（必须为 0）。
    let ruleMismatches: Int
    /// 已绑定查询的决策明细。
    let bound: [BoundDecision]
    /// 错误绑定时的「冠军 − 人物级亚军」差距。
    let wrongBindGaps: [Double]

    var coverage: Double { queryCount == 0 ? 0 : Double(bound.count) / Double(queryCount) }
    var bindingPrecision: Double {
        bound.isEmpty ? 0 : Double(correctBinds) / Double(bound.count)
    }

    /// 已绑定决策按 match_confidence 降序、queryIndex 升序（破平局）的稳定排序。
    var boundByConfidence: [BoundDecision] {
        bound.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.queryIndex < $1.queryIndex
        }
    }

    /// 按 confidence 降序取前 k 个已绑定查询的 queryIndex 集合（k ≤ 0 → 空集）。
    /// 用途：由 base 轮（margin=0）一次性固定 precision@K 的**查询集合**；若各轮各自
    /// 取前 K，集合会随各轮绑定数漂移，两个 precision@K 就不可比。
    func topBoundQueryIndices(_ k: Int) -> Set<Int> {
        guard k > 0 else { return [] }
        return Set(boundByConfidence.prefix(k).map(\.queryIndex))
    }

    /// 固定查询集合上的 precision@K：分母 = 集合内本轮的绑定数，分子 = 其中正确数。
    /// 未绑定不计入分母（不把「拒绑」当「错绑」）；集合内无绑定 → 0，调用方断言
    /// "不得低于 base"时该退化情形会直接失败，不会静默通过。
    func precision(onQueryIndices queryIndices: Set<Int>) -> Double {
        let inSet = bound.filter { queryIndices.contains($0.queryIndex) }
        guard !inSet.isEmpty else { return 0 }
        return Double(inSet.filter(\.isCorrect).count) / Double(inSet.count)
    }

    /// 该固定集合内本轮的绑定数（打印用：区分「精度提升」与「集合内几乎没绑定」）。
    func boundCount(onQueryIndices queryIndices: Set<Int>) -> Int {
        bound.reduce(0) { count, decision in
            count + (queryIndices.contains(decision.queryIndex) ? 1 : 0)
        }
    }
}

/// 用真实 FaceKwService 跑一次 analyze，返回生产落库的绑定统计。
/// - library：库样本（identityIndex 对应 personNames 下标）。
/// - queries：每个查询 2 张照片（同一 embedding），保证 minPts=2 成簇。
/// - threshold：写进 persons.match_threshold（生产匹配合格线）。
/// - margin：注入 face_match_margin 设置。
private func runProductionMargin(
    libraryConfigSeed: UInt64,
    personNames: [String],
    library: [(identityIndex: Int, embedding: [Float])],
    queries: [(identityIndex: Int, embedding: [Float])],
    threshold: Double,
    margin: Double
) async throws -> ProductionMarginRun {
    let db = try makeMigratedDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "MarginRun-\(libraryConfigSeed)", source: "folder")
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    // 独立人物库会话和可追溯观测，禁止使用无模型来源的向量。
    let librarySession = try sessionRepo.create(name: "Library", source: "folder")
    try insertPhoto(
        db, id: "library-photo", sessionId: librarySession.id,
        filepath: try writeTempFile(in: dir, name: "library.jpg"))

    var pathToEmbedding: [String: [Double]] = [:]
    var photoIdToQueryIndex: [String: Int] = [:]
    for (index, query) in queries.enumerated() {
        for copy in 0..<2 {
            let path = try writeTempFile(in: dir, name: "q\(index)-\(copy).jpg")
            let photoId = "photo-\(index)-\(copy)"
            try insertPhoto(db, id: photoId, sessionId: session.id, filepath: path)
            pathToEmbedding[path] = query.embedding.map(Double.init)
            photoIdToQueryIndex[photoId] = index
        }
    }

    let personRepo = PersonRepo(connection: db)
    var personIds: [String] = []
    for name in personNames {
        let personId = try personRepo.create(name: name)
        _ = try personRepo.update(
            id: personId, fields: PersonUpdateFields(matchThreshold: threshold))
        personIds.append(personId)
    }
    let model = try FaceEmbeddingModelFactory.spec(modelPath: "", modelVersion: "")
    let signature = "{\"embeddingSpec\":\"\(model.signature)\"}"
    let observationIds = try FaceRepo(connection: db).replaceObservationsByPhoto(
        sessionId: librarySession.id, photoId: "library-photo", observations: library.map { item in
            FaceObservationInput(photoId: "library-photo", bboxX: 0.1, bboxY: 0.1, bboxW: 0.2, bboxH: 0.3,
                embedding: item.embedding, confidence: 1, analysisSignature: signature, quality: 1)
        })
    try personRepo.saveEmbeddings(embeddings: library.enumerated().map { index, item in
        SaveEmbeddingInput(personId: personIds[item.identityIndex], embedding: item.embedding,
            photoId: "library-photo", sessionId: librarySession.id, faceObservationId: observationIds[index],
            faceBbox: [0.1, 0.1, 0.2, 0.3], quality: 1)
    })

    let faceRepo = FaceRepo(connection: db)
    let service = FaceKwService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        faceRepo: faceRepo,
        personRepo: personRepo,
        connection: db,
        getNumber: { key, defaultValue in
            key == "face_match_margin" ? margin : defaultValue
        },
        getString: { _, defaultValue in defaultValue },
        decodeProvider: { path, _ in Data(path.utf8) },
        inferenceProvider: { images, _, _ in
            images.map { data in
                let path = String(decoding: data, as: UTF8.self)
                guard let embedding = pathToEmbedding[path] else {
                    return FaceInferenceItem(observations: [])
                }
                return FaceInferenceItem(observations: [
                    FaceInferenceObservation(
                        bbox: [10, 20, 30, 40], confidence: 0.95, embedding: embedding,
                        quality: 1.0, faceSizePx: 40, rollDegrees: 0)
                ])
            }
        })

    _ = try await service.analyze(
        sessionId: session.id, detectorPath: "det.onnx", encoderPath: "enc.onnx",
        eps: 0.99, minPts: 2)

    let libraryRows = library.map {
        LibraryEmbedding(personId: personIds[$0.identityIndex], embedding: $0.embedding)
    }
    let clusters = try faceRepo.getClusters(session.id, includeMembers: true)

    var correctBinds = 0
    var wrongBinds = 0
    var ambiguous = 0
    var belowThreshold = 0
    var unexpectedUnbound = 0
    var mergedClusters = 0
    var ruleMismatches = 0
    var memberCount = 0
    var bound: [BoundDecision] = []
    var wrongBindGaps: [Double] = []

    for cluster in clusters {
        let members = cluster.members ?? []
        memberCount += members.count
        let queryIndices = Set(members.compactMap { photoIdToQueryIndex[$0.photoId] })
        guard queryIndices.count == 1, let queryIndex = queryIndices.first else {
            mergedClusters += 1
            continue
        }
        let expectedPersonId = personIds[queries[queryIndex].identityIndex]

        // 复算文档化规则，用生产同一函数求人物级最佳/亚军（不复制 margin 判定本身）。
        let scores = try FaceMatcher.bestScoresPerPerson(
            query: queries[queryIndex].embedding, library: libraryRows)
        let ranked = scores
            .filter { $0.value >= threshold }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
        let topScore = ranked.first?.value ?? -Double.infinity
        let winners = Set(ranked.filter { $0.value == topScore }.map(\.key))
        let gap = ranked.count > 1 ? ranked[0].value - ranked[1].value : Double.infinity
        let ruleSaysBound = !ranked.isEmpty && (ranked.count == 1 || gap >= margin)
        let ruleSaysAmbiguous = ranked.count > 1 && gap < margin

        if let matchedPersonId = cluster.matchedPersonId {
            bound.append(
                BoundDecision(
                    queryIndex: queryIndex, expectedPersonId: expectedPersonId,
                    personId: matchedPersonId, confidence: cluster.matchConfidence ?? 0))
            if matchedPersonId == expectedPersonId {
                correctBinds += 1
            } else {
                wrongBinds += 1
                wrongBindGaps.append(gap)
            }
            if !ruleSaysBound || !winners.contains(matchedPersonId) { ruleMismatches += 1 }
        } else {
            if ranked.isEmpty {
                belowThreshold += 1
            } else if ruleSaysAmbiguous {
                ambiguous += 1
            } else {
                unexpectedUnbound += 1
            }
            if ruleSaysBound { ruleMismatches += 1 }
        }
    }

    return ProductionMarginRun(
        margin: margin,
        queryCount: queries.count,
        clusterCount: clusters.count,
        memberCount: memberCount,
        correctBinds: correctBinds,
        wrongBinds: wrongBinds,
        ambiguous: ambiguous,
        belowThreshold: belowThreshold,
        unbound: bound.count == 0 ? queries.count : queries.count - bound.count,
        unexpectedUnbound: unexpectedUnbound,
        mergedClusters: mergedClusters,
        ruleMismatches: ruleMismatches,
        bound: bound,
        wrongBindGaps: wrongBindGaps)
}

// MARK: - C 组：margin 扫描（生产路径）

struct FaceMarginDecisionTests {
    /// 相近身份（中心余弦 0.93）+ 大噪声查询 ⇒ margin=0 时出现错误绑定；
    /// margin 扫描必须覆盖出货默认 0.01，并给出 错绑/正确/歧义/精度 完整曲线。
    /// 证伪条件：margin=0 的错误绑定必须 ≥2（否则无从观察 margin 的作用）。
    @Test func marginSweepUsesProductionBindingDecisions() async throws {
        var libraryConfig = SyntheticDatasetConfig(
            seed: 20_260_930, dim: 24, identityCount: 6, highQualityPerIdentity: 4,
            intraNoise: 0.3, maxCenterCosine: 0.4)
        libraryConfig.closePairCosine = 0.93
        let dataset = makeSyntheticDataset(libraryConfig)

        let closeQueries = makeQuerySamples(
            centers: dataset.centers, identityIndices: [0, 1], perIdentity: 12, noise: 0.8,
            seed: 20_260_941)
        let distantQueries = makeQuerySamples(
            centers: dataset.centers, identityIndices: [2, 3, 4, 5], perIdentity: 6, noise: 0.3,
            seed: 20_260_942)
        let library = dataset.samples.map {
            (identityIndex: $0.identityIndex, embedding: $0.embedding)
        }
        // 近并列靶样本：保证 margin（含默认 0.01）真的拦下 ≥1 条查询，而不是空跑。
        let queries = closeQueries + distantQueries + makeNearTieQuery(library: library)
        let personNames = (0..<dataset.identityCount).map { "P\($0)" }
        // threshold=0.6 是**本测试选定**的合格线（显式写入 persons.match_threshold）；
        // 生产兜底 0.65 见 FaceKwService.defaultPersonMatchThreshold（文件头"阈值常量
        // 来源"）。本用例验证的是"给定阈值下的 margin 决策"，不是阈值来源/调优。
        let threshold = 0.6
        let centerCosine = cosineFloats(dataset.centers[0], dataset.centers[1])

        // 出货默认 margin 必须取自设置默认值表（SettingsService.swift:40）。
        let shippedDefault = Double(SettingsService.getDefaults()["face_match_margin"] ?? "") ?? -1
        #expect(shippedDefault == 0.01, "出货默认 margin 必须是 0.01（设置默认值表）")
        // 阈值兜底常量护栏：文档写的 0.65 必须与生产代码一致（防注释漂移）。注意这仍
        // **不**验证兜底路径的行为——本夹具给每个 person 都显式写了 match_threshold=0.6。
        #expect(
            FaceKwService.defaultPersonMatchThreshold == 0.65,
            "生产人脸 person 的 match_threshold 兜底值必须与文档一致（0.65）")
        let margins: [Double] = [0, 0.005, shippedDefault, 0.02, 0.04, 0.06, 0.10]

        var runs: [ProductionMarginRun] = []
        for margin in margins {
            runs.append(
                try await runProductionMargin(
                    libraryConfigSeed: libraryConfig.seed, personNames: personNames,
                    library: library, queries: queries, threshold: threshold, margin: margin))
        }

        let base = runs[0]
        let defaultRun = runs[margins.firstIndex(of: shippedDefault)!]
        // precision@K 的 K 集合只由 base 轮（margin=0）决定：取 base 前 K 个绑定
        // （confidence 降序、queryIndex 破平局），K = base 的绑定数（该轮覆盖率 == 1.0，
        // 见下方断言 ⇒ 集合 = base 绑定的全部查询）。各轮都在**同一查询集合**上评估；
        // 旧口径 k = 各轮绑定数最小值 + 各轮"各自取前 k"既非同一集合，又使
        // "defaultRun.bound.count >= k" 恒真（已删除）。
        let k = base.bound.count
        let fixedTopK = base.topBoundQueryIndices(k)
        let curve = runs.map { run in
            String(
                format:
                    "    margin=%.3f | 绑定=%2d 正确=%2d 错误=%d 歧义=%d 低于阈值=%d | 绑定精度=%.4f 覆盖率=%.4f | 固定K集内绑定=%2d 精度@K=%.4f",
                run.margin, run.bound.count, run.correctBinds, run.wrongBinds, run.ambiguous,
                run.belowThreshold, run.bindingPrecision, run.coverage,
                run.boundCount(onQueryIndices: fixedTopK),
                run.precision(onQueryIndices: fixedTopK))
        }.joined(separator: "\n")
        print(
            """
            [C 生产路径 margin] 库 \(library.count) 条（\(dataset.identityCount) 身份 × 4 样本，身份0/1 中心余弦=\(String(format: "%.4f", centerCosine))）查询 \(queries.count) 条（相近身份 0/1 各 12 条 σ=0.8 + 身份 2..5 各 6 条 σ=0.3）；每查询 2 张照片（同一 embedding，各 1 观测）⇒ 每轮 analyze \(queries.count * 2) 观测
              参数: analyze(eps=0.99, minPts=2) threshold=\(String(format: "%.2f", threshold))（persons.match_threshold）face_match_margin 由设置注入
              生产落库: 簇数=\(base.clusterCount) 成员行=\(base.memberCount)（规则不一致簇=\(runs.map(\.ruleMismatches).max() ?? -1)，意外合并簇=\(runs.map(\.mergedClusters).max() ?? -1)）
              margin=0 时错误绑定 gap: [\(base.wrongBindGaps.map { String(format: "%.4f", $0) }.joined(separator: ", "))]
              margin 扫描（全部数字来自 face_clusters.matched_person_id；固定 K 集合 = base 轮前 K=\(k) 个绑定，各轮同一查询集合）:
            \(curve)
              注: 单 seed(20_260_941/942)；合成 embedding 不代表真实识别精度；结论只对本合成观测集成立；不得替代 Stretch 门。
            """)

        // 生产路径确实按文档化规则决策（决定与唯一复算路径一致）。
        #expect(
            runs.allSatisfy { $0.ruleMismatches == 0 && $0.unexpectedUnbound == 0 },
            "生产落库决定必须与文档化 margin 规则一致（ruleMismatches/unexpectedUnbound = 0）")
        #expect(
            runs.allSatisfy { $0.mergedClusters == 0 && $0.clusterCount == queries.count },
            "簇必须与查询一一对应（每查询 2 张照片成 1 簇）")
        #expect(base.memberCount == queries.count * 2, "每簇 2 个成员行")
        // 证伪条件：margin=0 必须真的出现错误绑定。
        #expect(base.wrongBinds >= 2, "margin=0 必须真的出现错误绑定（本组证伪条件）")
        #expect(base.coverage == 1.0, "margin=0 时不应有低于阈值的查询（否则 margin 作用被混淆）")
        // 扫描序列的结构不变量：margin 只可能把绑定改成不绑定（不会新增绑定）。
        let sweepWrong = runs.map(\.wrongBinds)
        let sweepUnbound = runs.map(\.unbound)
        #expect(
            zip(sweepWrong, sweepWrong.dropFirst()).allSatisfy { $0 >= $1 },
            "错误绑定数必须随 margin 单调不增")
        #expect(
            zip(sweepUnbound, sweepUnbound.dropFirst()).allSatisfy { $0 <= $1 },
            "未绑定数必须随 margin 单调不减")
        // 默认 0.01：错绑下降、歧义拦下近并列查询；且「更准」不是靠少绑定冒充——
        // 在 base 固定的同一 K 集合上 precision@K 不得下降（见下）。
        #expect(defaultRun.margin == 0.01 && defaultRun.wrongBinds < base.wrongBinds, "默认 margin=0.01 必须减少错绑")
        #expect(defaultRun.ambiguous > 0, "默认 margin=0.01 必须真的拦下近并列查询（歧义 > 0）")
        // K 集合固定自 base 轮：非空、且正好是 base 的绑定集合（每簇唯一查询）。
        #expect(k > 0, "base 轮必须真的绑定（否则固定 K 集合无从确定）")
        #expect(
            fixedTopK.count == k && base.boundCount(onQueryIndices: fixedTopK) == k,
            "固定 K 集合必须正好覆盖 base 轮的全部绑定（每簇唯一查询、一簇一查询）")
        // 存在性护栏：在 base 决定、各轮共用的同一 K 集合上，默认 margin 的 precision@K
        // 不得低于 base 的 precision@K。可证伪：若 margin=0.01 拒掉的是正确绑定、留下
        // 的是错绑定，该式立即失败；旧断言（bound >= min(各轮绑定数)）恒真、无信息量。
        #expect(
            defaultRun.precision(onQueryIndices: fixedTopK)
                >= base.precision(onQueryIndices: fixedTopK),
            "同一 K 集合上默认 margin 的 precision@K 不得低于 base（排除「少绑定冒充更准」）")
        // 非空护栏：默认 margin 在固定集合内必须仍有绑定（与 base 精度 > 0 一起挡住
        // "集合内全拒绑 → 分母 0 → 恒 0"的退化通过路径）。
        #expect(
            defaultRun.boundCount(onQueryIndices: fixedTopK) > 0,
            "默认 margin 在固定 K 集合内必须仍有绑定")
    }
}

// desktop/native/gather-core/Sources/GatherTriageEval/SimilarityEvalCommand.swift
// Wave3 / task-19：`gather-triage-eval similarity-eval` 子命令——给 ROADMAP 决策 A
// 产出可复现的评估结论（是否值得立项 embedding、阈值、失败类型）。
//
// 只读本地图片、不写库、不改产品行为；输出 markdown（人看）+ JSON（机器/回归用）。
// 评估口径见 SimilarityMetrics.swift 头注释（pair 二分类 + 阈值曲线 + 聚类过度合并）。
import Foundation
import Dispatch
import os
import GatherApplication

enum SimilarityEvalCLIError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)
    case unsupportedVision

    var description: String {
        switch self {
        case .usage(let message): message
        case .io(let message): message
        case .unsupportedVision: "本机 Vision 不可用：featureprint 通道无法评估（可改用 --source dhash）"
        }
    }
}

struct SimilarityEvalOptions {
    var annotationsPath = ""
    var source: SimilarityVectorSource = .featureprint
    var thresholds: [Double]?
    var minPrecision = 0.95
    var limitPairs: Int?
    var jsonOut: String?
    var markdownOut: String?
    var withBaseline = true
    var selfTest = false
}

/// 一对失败样例（FP = 过度合并，FN = 漏合并）。
struct SimilarityFailureSample {
    let kind: SimilarityAnnotationClass
    let similarity: Double
    let crossGroup: Bool
    let pathA: String
    let pathB: String
}

/// 基线在"产品当前口径"下的工作点（k = 允许的汉明位数）。
struct SimilarityProductionPoint {
    let bits: Int
    let note: String
    let point: SimilarityOperatingPoint
}

struct SimilarityBaselineReport {
    let sourceLabel: String
    let thresholds: [Double]
    let curve: [SimilarityOperatingPoint]
    let recommended: SimilarityOperatingPoint?
    /// 与主通道同口径的 pair 数（两侧可因缺向量不同；报告必须显示才可比）。
    let pairCount: Int
    let skippedPairCount: Int
    let minPrecision: Double
    /// k<=4（重复检测）与 k<=10（相似页分组的默认阈值）两档都报，避免只挑最弱基线。
    let productionPoints: [SimilarityProductionPoint]
    let clusters: SimilarityClusterEvaluation
}

struct SimilarityEvalReport {
    let annotationsPath: String
    let datasetHash: String
    let source: SimilarityVectorSource
    let groupCount: Int
    let photoCount: Int
    let pairCount: Int
    let positivePairCount: Int
    let crossGroupPairCount: Int
    /// 缺少向量被跳过的 pair 数（评估透明度：样本不能静默丢）。
    let skippedPairCount: Int
    let vectorFailures: [String]
    let thresholds: [Double]
    let curve: [SimilarityOperatingPoint]
    let recommended: SimilarityOperatingPoint?
    let minPrecision: Double
    let clusters: SimilarityClusterEvaluation
    let breakdown: [SimilarityClassBreakdown]
    let falsePositives: [SimilarityFailureSample]
    let falseNegatives: [SimilarityFailureSample]
    let baseline: SimilarityBaselineReport?
}

enum SimilarityEvalCLI {
    static let usage = """
    gather-triage-eval similarity-eval --annotations <json|csv> [options]

      --annotations <path>   标注集（.json 或 .csv；格式见 95-similarity-eval-design.md）
      --source featureprint|dhash   向量通道（默认 featureprint；dhash = 产品基线）
      --thresholds <list>    逗号列表或 start:end:step（默认 fp 0.70:0.99:0.01）
      --min-precision <p>    推荐工作点的精确率目标（默认 0.95）
      --limit-pairs <n>      评估 pair 上限（防大标注集 O(n^2)；组内 pair 恒保留）
      --json <path>          写机器可读报告
      --markdown <path>      写 markdown 报告（stdout 同时打印）
      --no-baseline          不额外跑 dHash 基线对照
      --self-test            只跑纯逻辑自检（不需要图片），失败 exit 1

    数据集格式（JSON）：
      {"version":1,"groups":[{"id":"g001","class":"burst","groundTruth":"merge","photos":["/abs/a.CR3"]}]}
    CSV 行：group_id,class,ground_truth,photo_path
    """

    static func run(arguments: [String]) throws -> Int32 {
        let options = try parse(arguments)
        if options.selfTest { return try runSelfTest() }
        return try runEvaluation(options)
    }

    // MARK: - 参数解析

    private static func parse(_ arguments: [String]) throws -> SimilarityEvalOptions {
        var options = SimilarityEvalOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--annotations":
                index += 1
                guard index < arguments.count else {
                    throw SimilarityEvalCLIError.usage("--annotations needs a path")
                }
                options.annotationsPath = arguments[index]
            case "--source":
                index += 1
                guard index < arguments.count,
                      let source = SimilarityVectorSource(rawValue: arguments[index]) else {
                    throw SimilarityEvalCLIError.usage("--source must be featureprint|dhash")
                }
                options.source = source
            case "--thresholds":
                index += 1
                guard index < arguments.count else {
                    throw SimilarityEvalCLIError.usage("--thresholds needs a value")
                }
                options.thresholds = try parseThresholds(arguments[index])
            case "--min-precision":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      value > 0, value <= 1 else {
                    throw SimilarityEvalCLIError.usage("--min-precision must be in (0, 1]")
                }
                options.minPrecision = value
            case "--limit-pairs":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw SimilarityEvalCLIError.usage("--limit-pairs must be positive")
                }
                options.limitPairs = value
            case "--json":
                index += 1
                guard index < arguments.count else {
                    throw SimilarityEvalCLIError.usage("--json needs a path")
                }
                options.jsonOut = arguments[index]
            case "--markdown":
                index += 1
                guard index < arguments.count else {
                    throw SimilarityEvalCLIError.usage("--markdown needs a path")
                }
                options.markdownOut = arguments[index]
            case "--no-baseline":
                options.withBaseline = false
            case "--self-test":
                options.selfTest = true
            case "--help", "-h":
                throw SimilarityEvalCLIError.usage(usage)
            default:
                throw SimilarityEvalCLIError.usage("unknown argument \(arguments[index])")
            }
            index += 1
        }
        if !options.selfTest && options.annotationsPath.isEmpty {
            throw SimilarityEvalCLIError.usage("--annotations is required")
        }
        return options
    }

    private static func parseThresholds(_ raw: String) throws -> [Double] {
        if raw.contains(":") {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3, parts[2] > 0, parts[0] <= parts[1] else {
                throw SimilarityEvalCLIError.usage("--thresholds 区间格式为 start:end:step（start<=end）")
            }
            var values: [Double] = []
            var current = parts[0]
            while current <= parts[1] + parts[2] / 10 {
                values.append((current * 10_000).rounded() / 10_000)
                current += parts[2]
            }
            return values
        }
        let values = raw.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard !values.isEmpty else {
            throw SimilarityEvalCLIError.usage("--thresholds 无法解析")
        }
        return values.sorted()
    }

    // MARK: - 自检

    private static func runSelfTest() throws -> Int32 {
        do {
            try SimilarityMetrics.selfTest()
            try selfTestAnnotationDecoder()
            try selfTestPairBuildParity()
            try selfTestVectorMath()
        } catch {
            print("similarity-eval self-test: FAIL — \(error)")
            return 1
        }
        print("similarity-eval self-test: PASS（pair 指标 / 阈值曲线 / 聚类过度合并 / 分类表现 / 标注解码 / pair 构建口径 / 向量数学）")
        return 0
    }

    private static func selfTestAnnotationDecoder() throws {
        let json = """
        {"version":1,"groups":[
          {"id":"g1","class":"burst","groundTruth":"merge","photos":["/tmp/a.CR3","/tmp/b.CR3"]},
          {"id":"g2","class":"same_scene_different_people","ground_truth":"separate",
           "photos":["/tmp/c.CR3","/tmp/d.CR3"]}
        ]}
        """
        let envelope = try JSONDecoder().decode(
            SimilarityAnnotationJSONEnvelope.self, from: Data(json.utf8))
        guard envelope.groups.count == 2,
              envelope.groups[0].kind == .burst,
              envelope.groups[0].groundTruth == .merge,
              envelope.groups[1].kind == .sameSceneDifferentPeople,
              envelope.groups[1].groundTruth == .separate else {
            throw SimilarityEvalCLIError.io("annotation JSON 解码自检失败")
        }
        let csv = """
        group_id,class,ground_truth,photo_path
        g1,burst,merge,/tmp/a.CR3
        g1,burst,merge,/tmp/b.CR3
        g2,different_client_similar_composition,separate,/tmp/c.CR3
        g2,different_client_similar_composition,separate,/tmp/d.CR3
        """
        let set = try SimilarityAnnotationSet.parseCSV(text: csv, separator: ",")
        guard set.groups.count == 2, set.photoCount == 4 else {
            throw SimilarityEvalCLIError.io("annotation CSV 解码自检失败")
        }
        try set.validate()

        // 负例 1（P2）：同一张照片出现在两个组 → 校验必须显式失败（ground truth 会互相覆盖）。
        let duplicateAcrossGroups = SimilarityAnnotationSet(
            version: SimilarityAnnotationSet.currentVersion,
            generatedBy: "self-test",
            groups: [
                SimilarityAnnotationGroup(
                    id: "g1", kind: .burst, groundTruth: .merge,
                    photos: ["/tmp/a.CR3", "/tmp/b.CR3"]),
                SimilarityAnnotationGroup(
                    id: "g2", kind: .sameSceneDifferentPeople, groundTruth: .separate,
                    photos: ["/tmp/b.CR3", "/tmp/c.CR3"]),
            ])
        var duplicateRejected = false
        do {
            try duplicateAcrossGroups.validate()
        } catch {
            duplicateRejected = true
        }
        guard duplicateRejected else {
            throw SimilarityEvalCLIError.io("跨组重复照片未被校验拦截")
        }

        // 负例 2（P2）：CSV 坏行（只有 3 列）不能静默跳过。
        let badCSV = """
        group_id,class,ground_truth,photo_path
        g1,burst,merge,/tmp/a.CR3
        g1,burst,/tmp/b.CR3
        """
        var badRowRejected = false
        do {
            _ = try SimilarityAnnotationSet.parseCSV(text: badCSV, separator: ",")
        } catch {
            badRowRejected = true
        }
        guard badRowRejected else {
            throw SimilarityEvalCLIError.io("CSV 坏行未被校验拦截")
        }

        // datasetHash 稳定性（Wave4b）：同内容 → 同 hash（组顺序/解码入口无关）；
        // kind/version 变化必须变 hash（报告"结论对应哪份标注"才可信）。
        let hashA = set.datasetHash()
        guard try SimilarityAnnotationSet.parseCSV(text: csv, separator: ",").datasetHash()
            == hashA else {
            throw SimilarityEvalCLIError.io("datasetHash 对同内容不稳定")
        }
        let reordered = SimilarityAnnotationSet(
            version: SimilarityAnnotationSet.currentVersion,
            generatedBy: "self-test",
            groups: Array(set.groups.reversed()))
        guard reordered.datasetHash() == hashA else {
            throw SimilarityEvalCLIError.io("datasetHash 不应随组顺序变化")
        }
        let changedKind = SimilarityAnnotationSet(
            version: SimilarityAnnotationSet.currentVersion,
            generatedBy: "self-test",
            groups: [
                SimilarityAnnotationGroup(
                    id: set.groups[0].id, kind: .sameSceneDifferentPeople,
                    groundTruth: set.groups[0].groundTruth, photos: set.groups[0].photos),
                set.groups[1],
            ])
        guard changedKind.datasetHash() != hashA else {
            throw SimilarityEvalCLIError.io("datasetHash 未包含 class（标注变了 hash 没变）")
        }
        let changedVersion = SimilarityAnnotationSet(
            version: SimilarityAnnotationSet.currentVersion + 1,
            generatedBy: set.generatedBy,
            groups: set.groups)
        guard changedVersion.datasetHash() != hashA else {
            throw SimilarityEvalCLIError.io("datasetHash 未包含 version")
        }
    }

    /// primary/baseline pair 构建口径（Wave4b）：两条通道共用 `buildPairs`，向量齐全时
    /// pair 数必须一致；缺向量必须进 `skipped` 而不是静默消失（报告因此可比）。
    private static func selfTestPairBuildParity() throws {
        let groups = [
            ResolvedGroup(
                id: "g1", kind: .burst, groundTruth: .merge,
                photos: ["a", "b", "c"]),
            ResolvedGroup(
                id: "g2", kind: .sameSceneDifferentPeople, groundTruth: .separate,
                photos: ["d", "e"]),
        ]
        var full = LoadedVectors()
        full.feature = [
            "a": [1, 0], "b": [0.9, 0.1], "c": [1, 0.2],
            "d": [0.1, 1], "e": [0.2, 1],
        ]
        let built = buildPairs(
            groups: groups, vectors: full, source: .featureprint, limitPairs: nil)
        // g1 内 3 对 + g2 内 1 对 + 跨组 3×2=6 对。
        guard built.pairs.count == 10, built.skipped == 0 else {
            throw SimilarityEvalCLIError.io(
                "pair 构建数量不对：\(built.pairs.count)（skipped \(built.skipped)）")
        }
        guard built.kindByPhoto["e"] == .sameSceneDifferentPeople else {
            throw SimilarityEvalCLIError.io("kindByPhoto 未覆盖全部照片（分类视图会丢类）")
        }
        let again = buildPairs(
            groups: groups, vectors: full, source: .featureprint, limitPairs: nil)
        guard again.pairs.count == built.pairs.count, again.skipped == 0 else {
            throw SimilarityEvalCLIError.io("同一输入两次 pair 构建不一致（报告不可复现）")
        }
        // 缺一张向量：命中 a 的 2 个组内 pair + 2 个跨组 pair 必须进 skipped。
        var missing = full
        missing.feature["a"] = nil
        let partial = buildPairs(
            groups: groups, vectors: missing, source: .featureprint, limitPairs: nil)
        guard partial.pairs.count == 6, partial.skipped == 4 else {
            throw SimilarityEvalCLIError.io(
                "缺向量时 pair 计数不对：\(partial.pairs.count)（skipped \(partial.skipped)）")
        }
        // 另一条通道（dHash）在向量齐全时 pair 数必须与 primary 一致，基线才可比。
        var hashes = LoadedVectors()
        hashes.hash = ["a": 0, "b": 0, "c": 0, "d": UInt64.max, "e": UInt64.max]
        let baseline = buildPairs(
            groups: groups, vectors: hashes, source: .dhash, limitPairs: nil)
        guard baseline.pairs.count == built.pairs.count, baseline.skipped == 0 else {
            throw SimilarityEvalCLIError.io(
                "baseline 与 primary 的 pair 数不一致：\(baseline.pairs.count) vs \(built.pairs.count)")
        }
        // 跨组预算不足时只截断跨组 pair，组内 pair 不丢。
        let capped = buildPairs(
            groups: groups, vectors: full, source: .featureprint, limitPairs: 2)
        guard capped.pairs.allSatisfy({ !$0.crossGroup }) else {
            throw SimilarityEvalCLIError.io("limitPairs 不足时不应保留跨组 pair")
        }
    }

    private static func selfTestVectorMath() throws {
        // cosine 的累加在 Float 里做（与线上 SemanticIndex 同精度），期望值必须给 Float 级容差：
        //   sqrt(2f)=1.4142135f → 1/√2 在 Float 下 ≈ 0.70710677，与 Double 真值差 ~1.2e-8。
        guard abs(SimilarityVectors.cosine([1, 0], [1, 1]) - 0.7071067811865475) < 1e-6 else {
            throw SimilarityEvalCLIError.io("cosine 自检失败")
        }
        guard SimilarityVectors.hamming(0b1010, 0b0011) == 2 else {
            throw SimilarityEvalCLIError.io("hamming 自检失败")
        }
        guard abs(SimilarityVectors.similarity(hammingDistance: 4) - 0.9375) < 1e-9 else {
            throw SimilarityEvalCLIError.io("dHash 相似度换算自检失败")
        }
        guard SimilarityVectors.cosine([], []) == -1 else {
            throw SimilarityEvalCLIError.io("空向量应返回 -1")
        }
    }

    // MARK: - 评估主流程

    private struct ResolvedGroup {
        let id: String
        let kind: SimilarityAnnotationClass
        let groundTruth: SimilarityGroundTruth
        let photos: [String]
    }

    /// 加载后的向量：featureprint 与 dhash 二选一（另一侧为空）。
    private struct LoadedVectors {
        var feature: [String: [Float]] = [:]
        var hash: [String: UInt64] = [:]
        var failures: [String] = []

        func similarity(a: String, b: String, source: SimilarityVectorSource) -> Double? {
            switch source {
            case .featureprint:
                guard let left = feature[a], let right = feature[b] else { return nil }
                let value = SimilarityVectors.cosine(left, right)
                return value < -0.5 ? nil : value
            case .dhash:
                guard let left = hash[a], let right = hash[b] else { return nil }
                return SimilarityVectors.similarity(
                    hammingDistance: SimilarityVectors.hamming(left, right))
            }
        }
    }

    private static func runEvaluation(_ options: SimilarityEvalOptions) throws -> Int32 {
        let set = try SimilarityAnnotationSet.load(path: options.annotationsPath)
        try set.validate()
        let baseDirectory = (options.annotationsPath as NSString).deletingLastPathComponent
        let groups = resolveGroups(set: set, baseDirectory: baseDirectory)
        let photos = Array(Set(groups.flatMap(\.photos))).sorted()
        guard !photos.isEmpty else {
            throw SimilarityEvalCLIError.io("标注集没有照片")
        }
        FileHandle.standardError.write(Data((
            "similarity-eval: \(groups.count) 组 / \(photos.count) 张，通道 = "
            + "\(options.source.rawValue)\n").utf8))

        let primary = try loadVectors(source: options.source, photos: photos)
        let built = buildPairs(
            groups: groups, vectors: primary, source: options.source,
            limitPairs: options.limitPairs)
        guard !built.pairs.isEmpty else {
            throw SimilarityEvalCLIError.io(
                "没有可评估的 pair（向量全部失败？失败 \(primary.failures.count) 张）")
        }
        let thresholds: [Double] = options.thresholds ?? defaultThresholds(
            source: options.source)
        let curve = SimilarityMetrics.curve(pairs: built.pairs, thresholds: thresholds)
        let recommended = SimilarityMetrics.recommendedPoint(
            curve: curve, minPrecision: options.minPrecision)
        let threshold = recommended?.threshold ?? (thresholds.first ?? 0.9)
        let truth = truthPartition(groups: groups)
        let clusters = SimilarityMetrics.clusterEvaluation(
            truthGroupByPhoto: truth, pairs: built.pairs, threshold: threshold)
        let breakdown = SimilarityMetrics.breakdown(
            pairs: built.pairs, threshold: threshold, classByPhoto: built.kindByPhoto)
        let failures = failureSamples(pairs: built.pairs, threshold: threshold)

        var baseline: SimilarityBaselineReport?
        if options.source == .featureprint, options.withBaseline {
            baseline = try buildBaseline(
                groups: groups, photos: photos, limitPairs: options.limitPairs,
                minPrecision: options.minPrecision)
        }

        let report = SimilarityEvalReport(
            annotationsPath: options.annotationsPath,
            datasetHash: set.datasetHash(),
            source: options.source,
            groupCount: groups.count,
            photoCount: photos.count,
            pairCount: built.pairs.count,
            positivePairCount: built.pairs.filter(\.shouldMerge).count,
            crossGroupPairCount: built.pairs.filter(\.crossGroup).count,
            skippedPairCount: built.skipped,
            vectorFailures: primary.failures,
            thresholds: thresholds,
            curve: curve,
            recommended: recommended,
            minPrecision: options.minPrecision,
            clusters: clusters,
            breakdown: breakdown,
            falsePositives: failures.falsePositives,
            falseNegatives: failures.falseNegatives,
            baseline: baseline)

        let markdown = renderMarkdown(report)
        print(markdown)
        if let path = options.markdownOut {
            try write(markdown, to: path, description: "markdown")
        }
        if let path = options.jsonOut {
            let data = try renderJSON(report)
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                throw SimilarityEvalCLIError.io("写 json 失败（\(path)）: \(error)")
            }
            FileHandle.standardError.write(Data("wrote json -> \(path)\n".utf8))
        }
        return 0
    }

    // MARK: - 数据准备

    private static func resolveGroups(
        set: SimilarityAnnotationSet, baseDirectory: String
    ) -> [ResolvedGroup] {
        set.groups.map { group in
            let photos = group.photos.map { path -> String in
                if path.hasPrefix("/") { return (path as NSString).standardizingPath }
                let joined = (baseDirectory as NSString).appendingPathComponent(path)
                return (joined as NSString).standardizingPath
            }
            return ResolvedGroup(
                id: group.id, kind: group.kind, groundTruth: group.groundTruth, photos: photos)
        }
    }

    private static func defaultThresholds(source: SimilarityVectorSource) -> [Double] {
        switch source {
        case .featureprint:
            var values: [Double] = []
            var current = 0.70
            while current <= 0.991 {
                values.append((current * 100).rounded() / 100)
                current += 0.01
            }
            return values
        case .dhash:
            return SimilarityVectors.dHashThresholds().sorted()
        }
    }

    private static func loadVectors(
        source: SimilarityVectorSource, photos: [String]
    ) throws -> LoadedVectors {
        var loaded = LoadedVectors()
        switch source {
        case .featureprint:
            guard SimilarityVectors.isFeaturePrintSupported else {
                throw SimilarityEvalCLIError.unsupportedVision
            }
            for (index, path) in photos.enumerated() {
                if index > 0 && index % 25 == 0 {
                    FileHandle.standardError.write(Data(
                        "similarity-eval: featureprint \(index)/\(photos.count)\n".utf8))
                }
                if let vector = SimilarityVectors.featurePrint(path: path) {
                    loaded.feature[path] = vector
                } else {
                    loaded.failures.append(path)
                }
            }
        case .dhash:
            let hashes = awaitHashes(paths: photos)
            for path in photos {
                if let hash = hashes[path] {
                    loaded.hash[path] = hash
                } else {
                    loaded.failures.append(path)
                }
            }
        }
        return loaded
    }

    /// 把 async 的 dHash 计算收敛成同步调用点（工具是单线程 CLI）。
    private static func awaitHashes(paths: [String]) -> [String: UInt64] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = HashResultBox()
        Task {
            let hashes = await SimilarityVectors.dHashes(paths: paths)
            box.set(hashes)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private struct PairBuild {
        let pairs: [SimilarityPairSample]
        /// photoId → 所属标注组类别（分类视图的负数来源；E1）。
        let kindByPhoto: [String: SimilarityAnnotationClass]
        /// 因缺向量被跳过的 pair 数（必须进报告：评估不能静默丢样本）。
        let skipped: Int
    }

    private static func buildPairs(
        groups: [ResolvedGroup],
        vectors: LoadedVectors,
        source: SimilarityVectorSource,
        limitPairs: Int?
    ) -> PairBuild {
        var pairs: [SimilarityPairSample] = []
        var skipped = 0
        var withinCount = 0
        var kindByPhoto: [String: SimilarityAnnotationClass] = [:]
        for group in groups {
            let photos = group.photos
            for photo in photos { kindByPhoto[photo] = group.kind }
            guard photos.count >= 2 else { continue }
            for first in 0..<(photos.count - 1) {
                for second in (first + 1)..<photos.count {
                    withinCount += 1
                    if let similarity = vectors.similarity(
                        a: photos[first], b: photos[second], source: source) {
                        pairs.append(SimilarityPairSample(
                            idA: photos[first], idB: photos[second],
                            similarity: similarity,
                            shouldMerge: group.groundTruth == .merge,
                            kind: group.kind))
                    } else {
                        skipped += 1
                    }
                }
            }
        }
        // 跨组 pair 全是负样本：主收益是度量"过度合并"（不同客户构图撞车）。
        // 同组 pair 恒保留，跨组按上限截断（确定性：按组序/张序）。
        let crossBudget: Int
        if let limitPairs {
            crossBudget = max(0, min(limitPairs, limitPairs - withinCount))
        } else {
            crossBudget = max(4_000, withinCount * 10)
        }
        var crossCount = 0
        outer: for firstGroup in 0..<groups.count {
            for secondGroup in (firstGroup + 1)..<groups.count {
                let leftGroup = groups[firstGroup]
                let rightGroup = groups[secondGroup]
                for left in leftGroup.photos {
                    for right in rightGroup.photos {
                        guard crossCount < crossBudget else { break outer }
                        if let similarity = vectors.similarity(a: left, b: right, source: source) {
                            pairs.append(SimilarityPairSample(
                                idA: left, idB: right,
                                similarity: similarity,
                                shouldMerge: false,
                                kind: leftGroup.kind,
                                crossGroup: true))
                            crossCount += 1
                        } else {
                            skipped += 1
                        }
                    }
                }
            }
        }
        return PairBuild(pairs: pairs, kindByPhoto: kindByPhoto, skipped: skipped)
    }

    /// 聚类级评估的 ground truth 分区：merge 组共享 id；separate 组每张独立。
    private static func truthPartition(groups: [ResolvedGroup]) -> [String: String] {
        var partition: [String: String] = [:]
        for group in groups {
            switch group.groundTruth {
            case .merge:
                for photo in group.photos {
                    partition[photo] = "merge:" + group.id
                }
            case .separate:
                for (index, photo) in group.photos.enumerated() {
                    partition[photo] = "separate:" + group.id + ":" + String(index)
                }
            }
        }
        return partition
    }

    private struct FailureSet {
        let falsePositives: [SimilarityFailureSample]
        let falseNegatives: [SimilarityFailureSample]
    }

    private static func failureSamples(
        pairs: [SimilarityPairSample], threshold: Double
    ) -> FailureSet {
        var positives: [SimilarityFailureSample] = []
        var negatives: [SimilarityFailureSample] = []
        for pair in pairs {
            let sample = SimilarityFailureSample(
                kind: pair.kind, similarity: pair.similarity,
                crossGroup: pair.crossGroup, pathA: pair.idA, pathB: pair.idB)
            if pair.shouldMerge && pair.similarity < threshold {
                negatives.append(sample)
            } else if !pair.shouldMerge && pair.similarity >= threshold {
                positives.append(sample)
            }
        }
        return FailureSet(
            falsePositives: Array(
                positives.sorted { $0.similarity > $1.similarity }.prefix(5)),
            falseNegatives: Array(
                negatives.sorted { $0.similarity < $1.similarity }.prefix(5)))
    }

    private static func buildBaseline(
        groups: [ResolvedGroup], photos: [String], limitPairs: Int?, minPrecision: Double
    ) throws -> SimilarityBaselineReport {
        var loaded = LoadedVectors()
        let hashes = awaitHashes(paths: photos)
        for path in photos {
            if let hash = hashes[path] { loaded.hash[path] = hash }
        }
        let built = buildPairs(
            groups: groups, vectors: loaded, source: .dhash, limitPairs: limitPairs)
        guard !built.pairs.isEmpty else {
            throw SimilarityEvalCLIError.io("dHash 基线没有可评估 pair")
        }
        let thresholds = SimilarityVectors.dHashThresholds()
        let curve = SimilarityMetrics.curve(pairs: built.pairs, thresholds: thresholds)
        // 与主通道同目标精确率（E2/P2：不能一边 0.95 一边用户目标，否则推荐点不可比）。
        let recommended = SimilarityMetrics.recommendedPoint(
            curve: curve, minPrecision: minPrecision)
        // 产品口径有两档，都要报（只报 k<=4 会把基线挑成最弱的一档）：
        // - k<=4：重复检测（DuplicateService 默认视觉重复阈值）；
        // - k<=10：相似页分组默认阈值（WorkflowRegistry 的 similarity.analyze 缺省）。
        let productionPoints = [
            SimilarityProductionPoint(
                bits: 4, note: "重复检测默认阈值（DuplicateService）",
                point: SimilarityMetrics.operatingPoint(
                    pairs: built.pairs,
                    threshold: SimilarityVectors.similarity(hammingDistance: 4))),
            SimilarityProductionPoint(
                bits: 10, note: "相似页分组默认阈值（similarity.analyze）",
                point: SimilarityMetrics.operatingPoint(
                    pairs: built.pairs,
                    threshold: SimilarityVectors.similarity(hammingDistance: 10))),
        ]
        let truth = truthPartition(groups: groups)
        let fallbackThreshold = recommended?.threshold
            ?? SimilarityVectors.similarity(hammingDistance: 4)
        let clusters = SimilarityMetrics.clusterEvaluation(
            truthGroupByPhoto: truth, pairs: built.pairs,
            threshold: fallbackThreshold)
        return SimilarityBaselineReport(
            sourceLabel: "dHash（汉明距离；产品基线两档 k<=4 / k<=10）",
            thresholds: thresholds,
            curve: curve,
            recommended: recommended,
            pairCount: built.pairs.count,
            skippedPairCount: built.skipped,
            minPrecision: minPrecision,
            productionPoints: productionPoints,
            clusters: clusters)
    }

    // MARK: - 渲染

    private static func format(_ value: Double?, digits: Int = 4) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    private static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f%%", value * 100)
    }

    private static func renderMarkdown(_ report: SimilarityEvalReport) -> String {
        var lines: [String] = []
        lines.append("# 相似/重复感知级评估（\(report.source.chineseLabel)）")
        lines.append("")
        lines.append("- 标注集：`\(report.annotationsPath)`")
        lines.append("- 数据集指纹（sha256）：`\(report.datasetHash)`")
        lines.append("- 组 / 照片 / pair：\(report.groupCount) / \(report.photoCount) / \(report.pairCount)"
            + "（正样本 \(report.positivePairCount)，跨组负样本 \(report.crossGroupPairCount)）")
        lines.append("- 向量失败（解码/Vision/超时）：\(report.vectorFailures.count) 张；"
            + "缺向量被跳过的 pair：\(report.skippedPairCount)")
        if !report.vectorFailures.isEmpty {
            let firstFailed = report.vectorFailures.prefix(5)
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: "、")
            lines.append("  - 前 5 张：\(firstFailed)")
        }
        lines.append("")
        lines.append("> 口径：groundTruth=merge 的组内 pair 为正样本；separate 组内与跨组 pair 为负样本。"
            + "过度合并率 = FP/(TP+FP)。")
        lines.append("")
        lines.append("## 阈值曲线")
        lines.append("")
        lines.append("| 阈值 | precision | recall | F1 | 过度合并率 | TP | FP | FN | TN |")
        lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for point in report.curve {
            lines.append("| \(format(point.threshold, digits: 4)) | \(format(point.precision))"
                + " | \(format(point.recall)) | \(format(point.f1))"
                + " | \(formatPercent(point.overMergeRate)) | \(point.confusion.truePositive)"
                + " | \(point.confusion.falsePositive) | \(point.confusion.falseNegative)"
                + " | \(point.confusion.trueNegative) |")
        }
        lines.append("")
        lines.append("## 推荐工作点")
        lines.append("")
        if let recommended = report.recommended {
            let meetsTarget = (recommended.precision ?? 0) >= report.minPrecision
            lines.append("- 阈值 **\(format(recommended.threshold, digits: 4))**"
                + "（目标 precision ≥ \(formatPercent(report.minPrecision))"
                + (meetsTarget ? "，已达标）" : "，**未达标**：回退到 F1 最大点）"))
            lines.append("- precision \(format(recommended.precision)) / recall \(format(recommended.recall))"
                + " / F1 \(format(recommended.f1)) / 过度合并率 \(formatPercent(recommended.overMergeRate))")
        } else {
            lines.append("- 无法给出推荐工作点（样本不足或全部同分）。")
        }
        lines.append("")
        lines.append("## 聚类级（过度合并的用户可见形态）")
        lines.append("")
        lines.append("| 指标 | 值 |")
        lines.append("|---|---:|")
        lines.append("| ARI（真分区 vs 预测分区） | \(format(report.clusters.adjustedRandIndex)) |")
        lines.append("| 被连成一片的真组（过度合并） | \(report.clusters.overMergedTruthClusters) |")
        lines.append("| 被拆开的真组（漏合并） | \(report.clusters.underMergedTruthClusters) |")
        lines.append("| 完全一致的真组 | \(report.clusters.exactTruthClusters) |")
        lines.append("")
        lines.append("## 分类表现（推荐阈值）")
        lines.append("")
        lines.append("| 类别 | precision | recall | 过度合并率 | predicted | TP | FP | FN |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for item in report.breakdown {
            // E1：只输出有定义的量——没有正样本的类（separate 类）不显示 recall（不当 0）。
            let recallCell = item.hasPositivePairs ? format(item.point.recall) : "n/a（无应合并样本）"
            let precisionCell = item.hasPredictedMerges ? format(item.point.precision) : "n/a"
            lines.append("| \(item.kind.chineseLabel) | \(precisionCell)"
                + " | \(recallCell) | \(formatPercent(item.point.overMergeRate))"
                + " | \(item.point.confusion.predictedPositive)"
                + " | \(item.point.confusion.truePositive) | \(item.point.confusion.falsePositive)"
                + " | \(item.point.confusion.falseNegative) |")
        }
        lines.append("")
        lines.append("> 分类口径：每类 = 类内 pair + 任一侧属于该类的跨类 pair（负样本来源）。"
            + "merge 类看 recall/precision；separate 类没有\"应合并\"样本，recall 无定义，看过度合并率即可。")
        lines.append("")
        lines.append("## 失败样例（前 5）")
        lines.append("")
        lines.append("过度合并（FP）：")
        lines.append("")
        if report.falsePositives.isEmpty {
            lines.append("- 无")
        }
        for sample in report.falsePositives {
            lines.append("- \(sample.kind.chineseLabel)\(sample.crossGroup ? "（跨组）" : "")"
                + " sim=\(format(sample.similarity))：`\(lastName(sample.pathA))` ↔ `\(lastName(sample.pathB))`")
        }
        lines.append("")
        lines.append("漏合并（FN）：")
        lines.append("")
        if report.falseNegatives.isEmpty {
            lines.append("- 无")
        }
        for sample in report.falseNegatives {
            lines.append("- \(sample.kind.chineseLabel) sim=\(format(sample.similarity))："
                + "`\(lastName(sample.pathA))` ↔ `\(lastName(sample.pathB))`")
        }
        lines.append("")
        if let baseline = report.baseline {
            lines.append("## 基线对照（\(baseline.sourceLabel)）")
            lines.append("")
            lines.append("- baseline pair 数：\(baseline.pairCount)（跳过 \(baseline.skippedPairCount)）；"
                + "推荐目标 precision ≥ \(formatPercent(baseline.minPrecision))")
            lines.append("")
            lines.append("| 工作点 | precision | recall | F1 | 过度合并率 |")
            lines.append("|---|---:|---:|---:|---:|")
            for production in baseline.productionPoints {
                lines.append("| \(production.note)（k<=\(production.bits)）"
                    + " | \(format(production.point.precision))"
                    + " | \(format(production.point.recall))"
                    + " | \(format(production.point.f1))"
                    + " | \(formatPercent(production.point.overMergeRate)) |")
            }
            if let best = baseline.recommended {
                lines.append("| dHash 最佳 F1（阈值 \(format(best.threshold))）"
                    + " | \(format(best.precision)) | \(format(best.recall))"
                    + " | \(format(best.f1)) | \(formatPercent(best.overMergeRate)) |")
            }
            if let primary = report.recommended {
                lines.append("| 本通道推荐阈值 | \(format(primary.precision))"
                    + " | \(format(primary.recall)) | \(format(primary.f1))"
                    + " | \(formatPercent(primary.overMergeRate)) |")
            }
            lines.append("")
            lines.append("- dHash 基线 ARI \(format(baseline.clusters.adjustedRandIndex))"
                + "，过度合并真组 \(baseline.clusters.overMergedTruthClusters)"
                + "，漏合并真组 \(baseline.clusters.underMergedTruthClusters)")
            lines.append("")
        }
        lines.append("## 复现")
        lines.append("")
        lines.append("```")
        lines.append("swift run --package-path desktop/native/gather-core gather-triage-eval \\")
        lines.append("  similarity-eval --annotations \(report.annotationsPath)"
            + " --source \(report.source.rawValue) \\")
        lines.append("  --min-precision \(report.minPrecision) --json /tmp/similarity-eval.json")
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    private static func lastName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func renderJSON(_ report: SimilarityEvalReport) throws -> Data {
        func optionalNumber(_ value: Double?) -> Any {
            if let value { return value }
            return NSNull()
        }
        func point(_ value: SimilarityOperatingPoint) -> [String: Any] {
            [
                "threshold": value.threshold,
                "precision": optionalNumber(value.precision),
                "recall": optionalNumber(value.recall),
                "f1": optionalNumber(value.f1),
                "overMergeRate": optionalNumber(value.overMergeRate),
                "truePositive": value.confusion.truePositive,
                "falsePositive": value.confusion.falsePositive,
                "falseNegative": value.confusion.falseNegative,
                "trueNegative": value.confusion.trueNegative,
            ]
        }
        func optionalPoint(_ value: SimilarityOperatingPoint?) -> Any {
            guard let value else { return NSNull() }
            return point(value)
        }
        var object: [String: Any] = [
            "annotationsPath": report.annotationsPath,
            "datasetHash": report.datasetHash,
            "source": report.source.rawValue,
            "groupCount": report.groupCount,
            "photoCount": report.photoCount,
            "pairCount": report.pairCount,
            "positivePairCount": report.positivePairCount,
            "crossGroupPairCount": report.crossGroupPairCount,
            "skippedPairCount": report.skippedPairCount,
            "vectorFailureCount": report.vectorFailures.count,
            "vectorFailures": report.vectorFailures,
            "minPrecision": report.minPrecision,
            "curve": report.curve.map(point),
            "clusters": [
                "adjustedRandIndex": report.clusters.adjustedRandIndex,
                "overMergedTruthClusters": report.clusters.overMergedTruthClusters,
                "underMergedTruthClusters": report.clusters.underMergedTruthClusters,
                "exactTruthClusters": report.clusters.exactTruthClusters,
            ] as [String: Any],
            "breakdown": report.breakdown.map { item in
                [
                    "class": item.kind.rawValue,
                    "hasPositivePairs": item.hasPositivePairs,
                    "precision": optionalNumber(item.point.precision),
                    // 无正样本的类 recall 无定义 → null（不是 0）。
                    "recall": item.hasPositivePairs
                        ? optionalNumber(item.point.recall) : NSNull(),
                    "overMergeRate": optionalNumber(item.point.overMergeRate),
                    "predictedMerges": item.point.confusion.predictedPositive,
                    "truePositive": item.point.confusion.truePositive,
                    "falsePositive": item.point.confusion.falsePositive,
                    "falseNegative": item.point.confusion.falseNegative,
                    "threshold": item.point.threshold,
                ] as [String: Any]
            },
        ]
        if let recommended = report.recommended {
            object["recommended"] = point(recommended)
        }
        if let baseline = report.baseline {
            var baselineObject: [String: Any] = [
                "source": baseline.sourceLabel,
                "pairCount": baseline.pairCount,
                "skippedPairCount": baseline.skippedPairCount,
                "minPrecision": baseline.minPrecision,
                "curve": baseline.curve.map(point),
                "productionPoints": baseline.productionPoints.map { production in
                    [
                        "bits": production.bits,
                        "note": production.note,
                        "point": point(production.point),
                    ] as [String: Any]
                },
                "clusters": [
                    "adjustedRandIndex": baseline.clusters.adjustedRandIndex,
                    "overMergedTruthClusters": baseline.clusters.overMergedTruthClusters,
                    "underMergedTruthClusters": baseline.clusters.underMergedTruthClusters,
                ] as [String: Any],
            ]
            baselineObject["recommended"] = optionalPoint(baseline.recommended)
            object["baseline"] = baselineObject
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw SimilarityEvalCLIError.io("json 编码失败: \(error)")
        }
    }

    private static func write(_ text: String, to path: String, description: String) throws {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw SimilarityEvalCLIError.io("写 \(description) 失败（\(path)）: \(error)")
        }
        FileHandle.standardError.write(Data("wrote \(description) -> \(path)\n".utf8))
    }
}

/// `awaitHashes` 的线程安全搬运盒（CLI 单线程，但 Task 在别的线程完成）。
/// 用 OSAllocatedUnfairLock（本身 Sendable）承载结果，避免新增逃逸口注解。
private final class HashResultBox: Sendable {
    private let lock = OSAllocatedUnfairLock<[String: UInt64]>(initialState: [:])

    func set(_ value: [String: UInt64]) {
        lock.withLock { $0 = value }
    }

    var value: [String: UInt64] { lock.withLock { $0 } }
}

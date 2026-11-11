// desktop/native/gather-core/Sources/GatherTriageEval/SimilarityAnnotation.swift
// Wave3 / task-19：感知级相似/重复标注集的读写与校验（评估任务，不改产品行为）。
//
// 标注集是"可复现评估物"的输入：每组照片 = 一个待判的相似组，人工给出
// `class`（属于四类中的哪一类）与 `groundTruth`（这组应当合并成一张逻辑资产，
// 还是应当保持独立）。评估工具把组内/组间的每一对照片当成二分类样本：
// - groundTruth == merge 的组：组内 pair 为正样本；
// - 其余 pair（separate 组内、任意跨组）为负样本。
// 这样"过度合并"就是 FP，"漏合并"就是 FN，与 ROADMAP 决策 A 的四个问题一一对应。
import Foundation
import GatherPersistence

/// 四类标注（对应 ROADMAP §六 的四个待验证假设）。
enum SimilarityAnnotationClass: String, Codable, CaseIterable {
    /// 连拍：同一瞬间的连续帧，通常应合并（保留最佳帧）。
    case burst
    /// 同场景不同时刻：同一地点/光线但不同瞬间，通常不应合并。
    case sameSceneDifferentTime = "same_scene_different_time"
    /// 同场景不同人物：构图近似但被摄主体不同，通常不应合并。
    case sameSceneDifferentPeople = "same_scene_different_people"
    /// 客户不同但构图相似：跨会话的构图撞车，不应合并（也不能跨会话合并）。
    case differentClientSimilarComposition = "different_client_similar_composition"

    var chineseLabel: String {
        switch self {
        case .burst: "连拍"
        case .sameSceneDifferentTime: "同场景不同时刻"
        case .sameSceneDifferentPeople: "同场景不同人物"
        case .differentClientSimilarComposition: "客户不同但构图相似"
        }
    }
}

enum SimilarityGroundTruth: String, Codable {
    case merge
    case separate

    var chineseLabel: String { self == .merge ? "应合并" : "不应合并" }
}

/// 标注集 JSON 外壳（version/generatedBy 可选；groups 必填）。
struct SimilarityAnnotationJSONEnvelope: Decodable {
    let version: Int?
    let generatedBy: String?
    let groups: [SimilarityAnnotationGroup]
}

enum SimilarityAnnotationError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalidGroup(String, String)
    case unsupportedFormat(String)

    var description: String {
        switch self {
        case .unreadable(let message): "SIMILARITY_ANNOTATION_UNREADABLE: \(message)"
        case .invalidGroup(let groupId, let reason):
            "SIMILARITY_ANNOTATION_INVALID: group \(groupId): \(reason)"
        case .unsupportedFormat(let path):
            "SIMILARITY_ANNOTATION_FORMAT: \(path)（只支持 .json / .csv）"
        }
    }
}

struct SimilarityAnnotationGroup: Decodable {
    let id: String
    let kind: SimilarityAnnotationClass
    let groundTruth: SimilarityGroundTruth
    /// 绝对路径或相对标注文件所在目录的路径（评估工具自行解析）。
    let photos: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case kind = "class"
        case groundTruth
        case groundTruthSnake = "ground_truth"
        case photos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        photos = try container.decode([String].self, forKey: .photos)
        let kindRaw: String?
        if container.contains(.kind) {
            kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)
        } else {
            kindRaw = nil
        }
        guard let kindRaw, let parsedKind = SimilarityAnnotationClass(rawValue: kindRaw) else {
            throw SimilarityAnnotationError.invalidGroup(
                id, "class 缺失或不是四类之一（burst/same_scene_different_time/"
                    + "same_scene_different_people/different_client_similar_composition）")
        }
        kind = parsedKind
        let truthRaw: String?
        if container.contains(.groundTruth) {
            truthRaw = try container.decodeIfPresent(String.self, forKey: .groundTruth)
        } else if container.contains(.groundTruthSnake) {
            truthRaw = try container.decodeIfPresent(String.self, forKey: .groundTruthSnake)
        } else {
            truthRaw = nil
        }
        guard let truthRaw, let parsedTruth = SimilarityGroundTruth(rawValue: truthRaw) else {
            throw SimilarityAnnotationError.invalidGroup(
                id, "groundTruth 缺失（采样脚本产出 `null`，需人工填 merge/separate）")
        }
        groundTruth = parsedTruth
    }

    init(id: String, kind: SimilarityAnnotationClass, groundTruth: SimilarityGroundTruth, photos: [String]) {
        self.id = id
        self.kind = kind
        self.groundTruth = groundTruth
        self.photos = photos
    }
}

struct SimilarityAnnotationSet {
    static let currentVersion = 1

    let version: Int
    let generatedBy: String?
    let groups: [SimilarityAnnotationGroup]

    var photoCount: Int {
        Set(groups.flatMap(\.photos)).count
    }

    /// 数据自检：重复 id、空组、单张组、重复路径（同组内）都要显式失败，
    /// 不能"静默少算"（评估物的第一要求是可复现）。
    func validate() throws {
        var seenGroups = Set<String>()
        // P2/E1 前置：同一张照片出现在两个组会让 truthPartition 后写覆盖先写，
        // ground truth 被静默改写 → 必须显式失败。
        var photoOwner: [String: String] = [:]
        for group in groups {
            guard seenGroups.insert(group.id).inserted else {
                throw SimilarityAnnotationError.invalidGroup(group.id, "group id 重复")
            }
            for photo in group.photos {
                let key = (photo as NSString).standardizingPath
                if let owner = photoOwner[key], owner != group.id {
                    throw SimilarityAnnotationError.invalidGroup(
                        group.id, "照片同时出现在组 \(owner) 与本组（ground truth 会互相覆盖）")
                }
                photoOwner[key] = group.id
            }
            guard !group.photos.isEmpty else {
                throw SimilarityAnnotationError.invalidGroup(group.id, "photos 为空")
            }
            guard group.photos.count >= 2 else {
                throw SimilarityAnnotationError.invalidGroup(
                    group.id, "至少需要 2 张照片才有 pair 可评估")
            }
            guard Set(group.photos).count == group.photos.count else {
                throw SimilarityAnnotationError.invalidGroup(group.id, "同一组内照片路径重复")
            }
        }
        guard !groups.isEmpty else {
            throw SimilarityAnnotationError.unreadable("groups 为空")
        }
    }

    /// 数据集指纹（同内容 → 同 hash），用于报告里声明"这份结论对应哪份标注"。
    func datasetHash() -> String {
        var canonical = "version=\(version)\n"
        for group in groups.sorted(by: { $0.id < $1.id }) {
            let photos = group.photos.map { ($0 as NSString).standardizingPath }.sorted()
            canonical += "\(group.id)|\(group.kind.rawValue)|\(group.groundTruth.rawValue)|"
                + photos.joined(separator: ",") + "\n"
        }
        let digest = SHA256.hash(Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 读取

    static func load(path: String) throws -> SimilarityAnnotationSet {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "json":
            return try loadJSON(path: path)
        case "csv", "tsv":
            return try loadCSV(path: path, separator: ext == "tsv" ? "\t" : ",")
        default:
            throw SimilarityAnnotationError.unsupportedFormat(path)
        }
    }

    private static func loadJSON(path: String) throws -> SimilarityAnnotationSet {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SimilarityAnnotationError.unreadable("读不到 \(path): \(error)")
        }
        let decoder = JSONDecoder()
        let envelope: SimilarityAnnotationJSONEnvelope
        do {
            envelope = try decoder.decode(SimilarityAnnotationJSONEnvelope.self, from: data)
        } catch let error as SimilarityAnnotationError {
            throw error
        } catch {
            throw SimilarityAnnotationError.unreadable("JSON 解析失败: \(error)")
        }
        return SimilarityAnnotationSet(
            version: envelope.version ?? currentVersion,
            generatedBy: envelope.generatedBy,
            groups: envelope.groups)
    }

    private static func loadCSV(path: String, separator: String) throws -> SimilarityAnnotationSet {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SimilarityAnnotationError.unreadable("读不到 \(path): \(error)")
        }
        return try parseCSV(text: text, separator: separator, origin: path)
    }

    /// CSV：`group_id,class,ground_truth,photo_path`（表头可选；# 开头为注释）。
    /// 组顺序按首次出现；同一 group_id 的 groundTruth/class 必须一致（显式失败）。
    /// internal：`--self-test` 直接喂字符串验解码（不需要落盘）。
    static func parseCSV(
        text: String, separator: String, origin: String = "<memory>"
    ) throws -> SimilarityAnnotationSet {
        var order: [String] = []
        var kindById: [String: SimilarityAnnotationClass] = [:]
        var truthById: [String: SimilarityGroundTruth] = [:]
        var photosById: [String: [String]] = [:]
        // 坏行不能静默丢（会悄悄改变 ground truth 的组/样本量）：先计数，最后整体失败。
        var badLines: [Int] = []
        for (lineIndex, rawLine) in text
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cells = line.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if cells.count < 4 {
                badLines.append(lineIndex + 1)
                continue
            }
            if cells[0].lowercased() == "group" || cells[0].lowercased() == "group_id" { continue }
            let groupId = cells[0]
            let kindRaw = cells[1]
            let truthRaw = cells[2]
            let photoPath = cells[3]
            guard let kind = SimilarityAnnotationClass(rawValue: kindRaw) else {
                throw SimilarityAnnotationError.invalidGroup(groupId, "class 无法识别: \(kindRaw)")
            }
            guard let truth = SimilarityGroundTruth(rawValue: truthRaw) else {
                throw SimilarityAnnotationError.invalidGroup(
                    groupId, "ground_truth 无法识别（应为 merge/separate）: \(truthRaw)")
            }
            if let existing = kindById[groupId], existing != kind {
                throw SimilarityAnnotationError.invalidGroup(groupId, "同一组出现不同 class")
            }
            if let existing = truthById[groupId], existing != truth {
                throw SimilarityAnnotationError.invalidGroup(groupId, "同一组出现不同 ground_truth")
            }
            if kindById[groupId] == nil { order.append(groupId) }
            kindById[groupId] = kind
            truthById[groupId] = truth
            photosById[groupId, default: []].append(photoPath)
        }
        if !badLines.isEmpty {
            let preview = badLines.prefix(5).map(String.init).joined(separator: "、")
            throw SimilarityAnnotationError.unreadable(
                "CSV 有 \(badLines.count) 行格式不合法（需要 4 列；行号 \(preview)"
                    + (badLines.count > 5 ? "…" : "") + "）: \(origin)")
        }
        guard !order.isEmpty else {
            throw SimilarityAnnotationError.unreadable(
                "CSV 没有有效数据行（需要 4 列）: \(origin)")
        }
        let groups = order.compactMap { groupId -> SimilarityAnnotationGroup? in
            guard let kind = kindById[groupId],
                  let truth = truthById[groupId],
                  let photos = photosById[groupId] else { return nil }
            return SimilarityAnnotationGroup(id: groupId, kind: kind, groundTruth: truth, photos: photos)
        }
        return SimilarityAnnotationSet(
            version: currentVersion,
            generatedBy: "csv:" + (origin as NSString).lastPathComponent,
            groups: groups)
    }
}

// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/OutputPresentationRepo.swift
// P1 下一波：交付展示元数据的一次性取数（联系表 / 画廊 / 校样共用）。
//
// 一条 JOIN 取全批：photos ⨝ photo_metadata_cache ⨝ culling_decisions ⨝ triage_suggestions。
// 逐张查会退化成 N+1（2k 张 ≈ 6k 次 prepare/query，交付主线程观感明显）。
//
// 三条硬约束：
// 1. **评分/色标的唯一真相源是 photo_metadata_cache**（见 CullingDecisionRepo 文件头注），
//    所以这里读 pmc.rating / pmc.label，绝不读 culling_decisions 的镜像列；
//    culling_decisions 只贡献 decision（keep/reject/pending）。
// 2. 缺行一律降级：LEFT JOIN + COALESCE，缺缓存/缺决策/缺 triage 的照片照样出行，
//    由调用方按默认值渲染（导出绝不能因为"没扫元数据"而失败）。
// 3. 只读、显式列清单、? 绑定，分批 800（低于 SQLite 参数上限）。

import Foundation
import GatherProtocol

/// 单张照片的展示元数据（缺行时全部取默认值）。
public struct OutputPresentationRow: Equatable, Sendable {
    public let photoId: String
    /// IPTC dc:title（photo_metadata_cache.iptc_json）；缺省 nil。
    public let title: String?
    /// IPTC dc:description（用户填的说明；不是文件名）。
    public let caption: String?
    /// 0…5。
    public let rating: Int
    /// "" | Red | Green | …（None 归一成 ""）。
    public let label: String
    public let keywords: [String]
    /// pmc.date_taken 原样字符串（ISO 或 EXIF 文本，不在这里重排）。
    public let captureTime: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// culling_decisions.decision：keep/reject/pending（缺行 nil）。
    public let decision: String?
    public let triageVerdict: String?
    /// 是否有 photo_metadata_cache 行（false = 元数据缺失，用于 metadataMissing 计数）。
    public let hasMetadata: Bool

    public init(row: DBRow) {
        // 列序见 OutputPresentationRepo.presentations 的显式 SELECT。
        photoId = row[0].textValue ?? ""
        rating = Int(row[1].intValue ?? 0)
        let rawLabel = row[2].textValue ?? ""
        label = rawLabel.caseInsensitiveCompare("None") == .orderedSame ? "" : rawLabel
        keywords = OutputPresentationRow.decodeKeywords(row[3].textValue ?? "[]")
        captureTime = row[4].textValue
        pixelWidth = Int(row[5].intValue ?? 0)
        pixelHeight = Int(row[6].intValue ?? 0)
        decision = row[7].textValue
        triageVerdict = row[8].textValue
        hasMetadata = row[10].intValue != nil
        let descriptive = OutputPresentationRow.decodeDescriptive(row[9].textValue ?? "{}")
        title = descriptive.title?.isEmpty == false ? descriptive.title : nil
        caption = descriptive.caption?.isEmpty == false ? descriptive.caption : nil
    }

    /// 测试/降级构造（无 DB 行）。
    public init(
        photoId: String,
        title: String? = nil,
        caption: String? = nil,
        rating: Int = 0,
        label: String = "",
        keywords: [String] = [],
        captureTime: String? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        decision: String? = nil,
        triageVerdict: String? = nil,
        hasMetadata: Bool = false
    ) {
        self.photoId = photoId
        self.title = title
        self.caption = caption
        self.rating = rating
        self.label = label
        self.keywords = keywords
        self.captureTime = captureTime
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.decision = decision
        self.triageVerdict = triageVerdict
        self.hasMetadata = hasMetadata
    }

    /// culling_decisions.decision（keep/reject/pending）→ PickState。
    public var pickState: PickState {
        switch decision {
        case "keep": .picked
        case "reject": .rejected
        default: .unreviewed
        }
    }

    /// triage 建议（未知/缺行 → nil）。
    public var triage: TriageVerdict? {
        guard let triageVerdict else { return nil }
        return TriageVerdict(rawValue: triageVerdict)
    }

    static func decodeKeywords(_ json: String) -> [String] {
        do {
            let value = try JSONValue.parse(json)
            // arrayValue 是 [String]? 便捷版（见 Core.swift / RepositorySupport.swift）。
            return value.arrayValue ?? []
        } catch {
            // 坏 JSON = 没有关键词（导入期的坏行不该让交付失败）。
            return []
        }
    }

    static func decodeDescriptive(_ json: String) -> DescriptiveMetadata {
        do {
            let value = try JSONValue.parse(json)
            return try value.decode(DescriptiveMetadata.self)
        } catch {
            return DescriptiveMetadata()
        }
    }
}

/// 交付展示元数据仓储（只读、无状态；只持有连接，故可 Sendable）。
public struct OutputPresentationRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 批量取展示元数据。返回顺序**不保证**与入参一致（调用方按 photoId 建索引）。
    /// 一次 JOIN；每 800 个 id 一批（SQLite 参数上限）。
    public func presentations(sessionId: String, photoIds: [String]) throws -> [OutputPresentationRow] {
        if photoIds.isEmpty { return [] }
        var result: [OutputPresentationRow] = []
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            var values: [DBValue?] = [.text(sessionId)]
            values.append(contentsOf: chunk.map { .text($0) })
            let rows = try connection.prepare("""
                SELECT p.id,
                       pmc.rating, pmc.label, pmc.keywords, pmc.date_taken,
                       pmc.width, pmc.height,
                       cd.decision, t.verdict,
                       pmc.iptc_json, pmc.id
                FROM photos p
                LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
                LEFT JOIN culling_decisions cd
                       ON cd.photo_id = p.id AND cd.session_id = p.session_id
                LEFT JOIN triage_suggestions t ON t.photo_id = p.id
                WHERE p.session_id = ? AND p.id IN (\(placeholders))
              """).query(values)
            result.append(contentsOf: rows.map { OutputPresentationRow(row: $0) })
        }
        return result
    }
}

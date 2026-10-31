// desktop/native/gather-core/Sources/GatherApplication/Services/Output/ClientSelection.swift
// 客户校样回传：解析 proof.html 下载的 selection.json。
//
// 两种格式都要认（客户可能用旧版校样页）：
//   v1: {"version":1,"title":"…","picks":[{"id":"…","name":"…","pick":true}]}
//   v2: {"version":2,"title":"…","submittedAt":"…",
//        "items":[{"id":"…","name":"…","pick":true,"rating":4,"label":"Green","comment":"…"}]}
//
// 解析规则（与 proof.js 同源）：
// - 只认 id；pick=false 的条目不进 pickedPhotoIds（但它的评分/评论仍然有效）；
// - 重复 id 去重（保持首次出现顺序），重复计数单独给出（诊断用，不静默丢）；
// - rating 夹到 0…5；label 归一成 8 色规范名，未知色标按"无"处理；
// - 空 comment 不发（避免给每张都塞一条空评论）。

import Foundation
import GatherProtocol

public enum ClientSelectionError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case unsupportedVersion(Int)

    /// 复用已登记错误码（不新增全局码）。
    public var code: String { GatherErrorCode.INVALID_PARAM.rawValue }

    public var description: String {
        switch self {
        case .invalidJSON(let reason):
            code + ": selection.json 无法解析（" + reason + "）"
        case .unsupportedVersion(let version):
            code + ": selection.json 版本不支持（version=" + String(version) + "）"
        }
    }

    /// API 边界用：把解析失败落成可本地化的 INVALID_PARAM。
    public var gatherError: GatherError {
        switch self {
        case .invalidJSON(let reason):
            GatherError(code: .INVALID_PARAM, params: [
                "field": "selection.json", "reason": reason,
            ])
        case .unsupportedVersion(let version):
            GatherError(code: .INVALID_PARAM, params: [
                "field": "version", "reason": String(version),
            ])
        }
    }
}

/// 解析后的校样回传（v1/v2 统一形态）。
public struct ParsedClientSelection: Equatable, Sendable {
    public var version: Int
    public var title: String?
    public var submittedAt: String?
    /// 去重后的全部条目（含 pick=false / 只评分 / 只评论的）。
    public var items: [ClientFeedbackItem]
    /// 被勾选的 photoId（去重、保持首次出现顺序）。
    public var pickedPhotoIds: [String]
    /// 重复 id 的条数（诊断用）。
    public var duplicateCount: Int
    /// 空/无效条目被丢弃的条数。
    public var invalidCount: Int

    public init(
        version: Int = 1,
        title: String? = nil,
        submittedAt: String? = nil,
        items: [ClientFeedbackItem] = [],
        pickedPhotoIds: [String] = [],
        duplicateCount: Int = 0,
        invalidCount: Int = 0
    ) {
        self.version = version
        self.title = title
        self.submittedAt = submittedAt
        self.items = items
        self.pickedPhotoIds = pickedPhotoIds
        self.duplicateCount = duplicateCount
        self.invalidCount = invalidCount
    }
}

public enum ClientSelectionParser {
    /// 兼容入口（LiveCullingAPI 仍用它）：返回被勾选的 photoId。
    public static func pickedPhotoIds(from data: Data) throws -> [String] {
        try parse(data).pickedPhotoIds
    }

    /// v1/v2 统一解析。
    public static func parse(_ data: Data) throws -> ParsedClientSelection {
        let raw: RawSelectionFile
        do {
            raw = try JSONDecoder().decode(RawSelectionFile.self, from: data)
        } catch {
            throw ClientSelectionError.invalidJSON(String(describing: error))
        }
        let version = raw.version ?? 1
        guard version == 1 || version == 2 else {
            throw ClientSelectionError.unsupportedVersion(version)
        }
        let combined = (raw.items ?? []) + (raw.picks ?? [])
        var seen = Set<String>()
        var duplicateCount = 0
        var invalidCount = 0
        var items: [ClientFeedbackItem] = []
        var picked: [String] = []
        for var item in combined {
            let id = item.photoId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                invalidCount += 1
                continue
            }
            guard seen.insert(id).inserted else {
                duplicateCount += 1
                continue
            }
            item.photoId = id
            item.name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            item.rating = Self.clampRating(item.rating)
            item.label = Self.normalizeLabel(item.label)
            let comment = item.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            item.comment = comment.isEmpty ? nil : comment
            items.append(item)
            // pick 缺省视为勾选（v1 老文件的语义：出现在 picks 里就是选了）。
            if item.pick != false { picked.append(id) }
        }
        return ParsedClientSelection(
            version: version,
            title: raw.title,
            submittedAt: raw.submittedAt,
            items: items,
            pickedPhotoIds: picked,
            duplicateCount: duplicateCount,
            invalidCount: invalidCount)
    }

    /// 0…5 夹取；nil 保持 nil（"没打分"与"打 0 分"要能区分）。
    static func clampRating(_ rating: Int?) -> Int? {
        guard let rating else { return nil }
        return max(0, min(5, rating))
    }

    /// C1 色标规范名（大小写不敏感）；未知/空/None → nil。
    static func normalizeLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = ["Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple"]
        for name in canonical where name.caseInsensitiveCompare(trimmed) == .orderedSame {
            return name
        }
        return nil
    }

    /// v2 允许 items / v1 允许 picks；两个键都可能缺失，所以不能直接用
    /// ClientFeedbackFile（它的 items 是非可选数组）。
    private struct RawSelectionFile: Decodable {
        var version: Int?
        var title: String?
        var submittedAt: String?
        var items: [ClientFeedbackItem]?
        var picks: [ClientFeedbackItem]?
    }
}

// desktop/native/gather-core/Sources/GatherCore/Metadata/MetadataMutationPlan.swift
// TS 源: desktop/src/main/services/metadata/metadata-contract.ts（逐字移植，纯逻辑）
// 契约校验层：patch 规范化 / 关键词规范化。错误消息与 TS
// 逐字一致（CustomStringConvertible）。

import Foundation

/// TS: metadata-contract.ts 抛出的全部错误码。
public enum MetadataContractError: Error, Equatable, CustomStringConvertible {
    case keywordsInvalid // METADATA_KEYWORDS_INVALID
    case patchInvalid // METADATA_PATCH_INVALID
    case ratingInvalid // METADATA_RATING_INVALID
    case labelInvalid // METADATA_LABEL_INVALID
    case keywordsOpInvalid // METADATA_KEYWORDS_OP_INVALID
    case patchEmpty // METADATA_PATCH_EMPTY
    case unsupportedSource(String) // `Unsupported metadata mutation source: ${source}`

    public var description: String {
        switch self {
        case .keywordsInvalid: "METADATA_KEYWORDS_INVALID"
        case .patchInvalid: "METADATA_PATCH_INVALID"
        case .ratingInvalid: "METADATA_RATING_INVALID"
        case .labelInvalid: "METADATA_LABEL_INVALID"
        case .keywordsOpInvalid: "METADATA_KEYWORDS_OP_INVALID"
        case .patchEmpty: "METADATA_PATCH_EMPTY"
        case .unsupportedSource(let source): "Unsupported metadata mutation source: \(source)"
        }
    }
}

/// TS: LABELS —— 合法 Capture One 颜色标签值集。
private let metadataLabels: Set<String> = [
    "", "None", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple",
]

/// TS: normalizeKeywords —— 非数组抛 METADATA_KEYWORDS_INVALID；
/// 字符串化、trim、去空、按首次出现顺序去重。TS 的 filter(type guard)
/// 静默丢弃非字符串元素，此处同样不抛错。
public func normalizeKeywords(_ values: [JSONValue]) throws -> [String] {
    // TS 入参是 unknown 的 values；此处接受 JSONValue 数组（宿主已按 unknown 语义传入）。
    let strings = values.compactMap { $0.stringValue }
    var seen = Set<String>()
    return strings
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

/// TS: normalizeKeywords —— 字符串数组直传（queueMutation 的 patch.keywords 已是 string[]）。
public func normalizeKeywords(_ values: [String]) throws -> [String] {
    var seen = Set<String>()
    return values
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

/// TS: validateMetadataPatch —— 逐字段校验并规范化；空 patch 抛 METADATA_PATCH_EMPTY。
public func validateMetadataPatch(_ patch: MetadataPatch) throws -> MetadataPatch {
    var normalized = MetadataPatch()
    if let rating = patch.rating {
        // TS: op !== 'set' || !Number.isInteger(value) || value < 0 || value > 5
        guard rating.op == .set,
              !rating.value.isNaN, !rating.value.isInfinite,
              rating.value.rounded() == rating.value,
              rating.value >= 0, rating.value <= 5 else {
            throw MetadataContractError.ratingInvalid
        }
        normalized.rating = MetadataRatingPatch(op: .set, value: rating.value)
    }
    if let label = patch.label {
        guard label.op == .set, metadataLabels.contains(label.value) else {
            throw MetadataContractError.labelInvalid
        }
        normalized.label = MetadataLabelPatch(op: .set, value: label.value)
    }
    if let keywords = patch.keywords {
        switch keywords.op {
        case .append, .replace, .remove:
            break
        default:
            throw MetadataContractError.keywordsOpInvalid
        }
        normalized.keywords = MetadataKeywordsPatch(
            op: keywords.op,
            values: try normalizeKeywords(keywords.values)
        )
    }
    if normalized.rating == nil && normalized.label == nil && normalized.keywords == nil {
        throw MetadataContractError.patchEmpty
    }
    return normalized
}

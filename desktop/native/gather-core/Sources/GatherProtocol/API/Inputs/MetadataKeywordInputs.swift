// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/MetadataKeywordInputs.swift
// P0 / K0：关键词预览/写入输入。校验在构造期完成，解码后走同一路径。
import Foundation

private func validateKeywordEdit(
    photoIds: [String],
    added: [String],
    removed: [String]
) throws -> ([String], [String], [String]) {
    _ = try APIValidation.nonEmpty(photoIds, field: "photoIds", maxCount: 500)
    var seen = Set<String>()
    var uniqueIds: [String] = []
    for (index, id) in photoIds.enumerated() {
        _ = try APIValidation.nonBlank(id, field: "photoIds[\(index)]", maxLength: 128)
        if seen.insert(id).inserted { uniqueIds.append(id) }
    }
    let normalizedAdded = try added.enumerated().map { index, value -> String in
        guard let normalized = KeywordNormalizer.normalize(value) else {
            throw GatherError.invalidParameter(field: "addedKeywords[\(index)]", reason: "invalid keyword")
        }
        return normalized
    }
    let normalizedRemoved = try removed.enumerated().map { index, value -> String in
        guard let normalized = KeywordNormalizer.normalize(value) else {
            throw GatherError.invalidParameter(field: "removedKeywords[\(index)]", reason: "invalid keyword")
        }
        return normalized
    }
    let addedKeys = Set(normalizedAdded.map { KeywordNormalizer.fold($0) })
    for keyword in normalizedRemoved where addedKeys.contains(KeywordNormalizer.fold(keyword)) {
        throw GatherError.invalidParameter(
            field: "removedKeywords",
            reason: "same keyword cannot be added and removed: \(keyword)"
        )
    }
    // 限额按归一化去重后的净编辑数计，重复词不能挤占 100 条配额。
    let uniqueAdded = KeywordNormalizer.unique(normalizedAdded)
    let uniqueRemoved = KeywordNormalizer.unique(normalizedRemoved)
    guard uniqueAdded.count + uniqueRemoved.count <= 100 else {
        throw GatherError.invalidParameter(field: "keywords", reason: "at most 100 edits per request")
    }
    guard !uniqueAdded.isEmpty || !uniqueRemoved.isEmpty else {
        throw GatherError.invalidParameter(field: "keywords", reason: "no keyword changes")
    }
    return (uniqueIds, uniqueAdded, uniqueRemoved)
}

public struct MetadataPreviewInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]
    public let addedKeywords: [String]
    public let removedKeywords: [String]

    public init(
        photoIds: [String],
        addedKeywords: [String] = [],
        removedKeywords: [String] = []
    ) throws {
        let validated = try validateKeywordEdit(
            photoIds: photoIds, added: addedKeywords, removed: removedKeywords)
        self.photoIds = validated.0
        self.addedKeywords = validated.1
        self.removedKeywords = validated.2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoIds: try container.decode([String].self, forKey: .photoIds),
            addedKeywords: try container.decodeIfPresent([String].self, forKey: .addedKeywords) ?? [],
            removedKeywords: try container.decodeIfPresent([String].self, forKey: .removedKeywords) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case photoIds, addedKeywords, removedKeywords
    }
}

public struct MetadataKeywordApplyInput: Decodable, Sendable, Equatable {
    public let photoIds: [String]
    public let addedKeywords: [String]
    public let removedKeywords: [String]

    public init(
        photoIds: [String],
        addedKeywords: [String] = [],
        removedKeywords: [String] = []
    ) throws {
        let validated = try validateKeywordEdit(
            photoIds: photoIds, added: addedKeywords, removed: removedKeywords)
        self.photoIds = validated.0
        self.addedKeywords = validated.1
        self.removedKeywords = validated.2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            photoIds: try container.decode([String].self, forKey: .photoIds),
            addedKeywords: try container.decodeIfPresent([String].self, forKey: .addedKeywords) ?? [],
            removedKeywords: try container.decodeIfPresent([String].self, forKey: .removedKeywords) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case photoIds, addedKeywords, removedKeywords
    }
}

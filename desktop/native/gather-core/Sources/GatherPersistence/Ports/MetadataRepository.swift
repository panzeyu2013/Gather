// desktop/native/gather-core/Sources/GatherPersistence/Ports/MetadataRepository.swift
// WP3b-1：Metadata cache 仓储端口（只含 Application 实际调用的方法）。
import Foundation
import GatherProtocol

public protocol MetadataRepository {
    func upsert(photoId: String, sessionId: String, data: MetadataCacheInput) throws
    func get(_ photoId: String) throws -> MetadataCacheRow?
    func getBatch(_ photoIds: [String]) throws -> [MetadataCacheRow]
    func deleteBySession(_ sessionId: String) throws
    func updateRating(photoId: String, rating: Int64) throws
    func updateLabel(photoId: String, label: String) throws
    func updateKeywords(photoId: String, keywords: [String]) throws
    /// P1 / IPTC：描述性元数据写盘后的投影刷新。
    func updateDescriptive(photoId: String, descriptive: DescriptiveMetadata) throws
}

extension MetadataCacheRepo: MetadataRepository {}

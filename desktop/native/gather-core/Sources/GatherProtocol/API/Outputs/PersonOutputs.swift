// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/PersonOutputs.swift
// Cut 1 / 阶段 1A：PersonAPI 的结果类型。
//
// 职责：
// - PersonCreateResult：person.create 的 {id}；
// - PersonPhotosResult：person.search_photos 的 {photos, total}。
// 校验归属：无（纯输出）。

import Foundation

public struct PersonCreateResult: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct PersonPhotosResult: Codable, Equatable, Sendable {
    public let photos: [PersonPhotoItem]
    public let total: Int

    public init(photos: [PersonPhotoItem], total: Int) {
        self.photos = photos
        self.total = total
    }
}

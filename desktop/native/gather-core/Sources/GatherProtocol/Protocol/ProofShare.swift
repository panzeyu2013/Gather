// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ProofShare.swift
// P1 下一波：客户校样反馈 v2 + 分享策略。

import Foundation

/// selection.json v2 的单项。v1 的 {id,name,pick} 仍可解码（pick 为 Bool）。
public struct ClientFeedbackItem: Codable, Equatable, Sendable {
    public var photoId: String
    public var name: String?
    public var pick: Bool?
    public var rating: Int?
    public var label: String?
    public var comment: String?

    public init(
        photoId: String,
        name: String? = nil,
        pick: Bool? = nil,
        rating: Int? = nil,
        label: String? = nil,
        comment: String? = nil
    ) {
        self.photoId = photoId
        self.name = name
        self.pick = pick
        self.rating = rating
        self.label = label
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {
        case photoId = "id"
        case name, pick, rating, label, comment
    }
}

public struct ProofFeedbackConflict: Codable, Equatable, Sendable {
    public var photoId: String
    public var localRating: Int
    public var localLabel: String
    public var clientRating: Int?
    public var clientLabel: String?

    public init(
        photoId: String,
        localRating: Int,
        localLabel: String,
        clientRating: Int?,
        clientLabel: String?
    ) {
        self.photoId = photoId
        self.localRating = localRating
        self.localLabel = localLabel
        self.clientRating = clientRating
        self.clientLabel = clientLabel
    }
}

public struct ClientFeedbackImportResult: Codable, Equatable, Sendable {
    public var picked: Int
    public var skipped: Int
    public var failed: Int
    public var conflicts: [ProofFeedbackConflict]
    public var comments: Int
    public var alreadyImported: Bool

    public init(
        picked: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        conflicts: [ProofFeedbackConflict] = [],
        comments: Int = 0,
        alreadyImported: Bool = false
    ) {
        self.picked = picked
        self.skipped = skipped
        self.failed = failed
        self.conflicts = conflicts
        self.comments = comments
        self.alreadyImported = alreadyImported
    }
}

public struct OutputShareOptions: Codable, Equatable, Sendable {
    /// false = 只上传 thumbs/proof，不上传 large 与成片。
    public var allowDownload: Bool
    /// ISO-8601；advisory + 到期撤销 job。
    public var expiresAt: String?
    /// 把整个 bundle 打成加密 DMG（密码存 Keychain）。
    public var encryptBundle: Bool
    public var remoteSubfolder: String

    public init(
        allowDownload: Bool = false,
        expiresAt: String? = nil,
        encryptBundle: Bool = false,
        remoteSubfolder: String = ""
    ) {
        self.allowDownload = allowDownload
        self.expiresAt = expiresAt
        self.encryptBundle = encryptBundle
        self.remoteSubfolder = remoteSubfolder
    }
}


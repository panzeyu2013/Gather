// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SessionIngestInputs.swift
// P1 / D：摄取（复制/重命名/校验 → 登记进会话）。
//
// 与 session.add_photos 的分工：add_photos 只登记"已经在位的文件"；ingest 先把文件
// 搬到目标位置（可选第二目的地）并校验，再用同一套 add_photos 语义登记，
// 因此 RAW/JPEG 配对、去重、校验和回填都不在这里重复实现。
import Foundation

public struct SessionIngestInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// 源：单个文件或目录（目录只扫一层，不递归子目录）。
    public let sourcePaths: [String]
    public let destinationRoot: String
    /// 重命名模板，如 {yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}。
    public let renameTemplate: String
    public let secondDestinationRoot: String?
    public let verifyChecksum: Bool

    public init(
        sessionId: String,
        sourcePaths: [String],
        destinationRoot: String,
        renameTemplate: String = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
        secondDestinationRoot: String? = nil,
        verifyChecksum: Bool = true
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.sourcePaths = try APIValidation.nonEmpty(sourcePaths, field: "sourcePaths")
        self.destinationRoot = try APIValidation.path(destinationRoot, field: "destinationRoot")
        self.renameTemplate = try APIValidation.nonBlank(renameTemplate, field: "renameTemplate", maxLength: 256)
        self.secondDestinationRoot = try secondDestinationRoot.map {
            try APIValidation.path($0, field: "secondDestinationRoot")
        }
        self.verifyChecksum = verifyChecksum
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            sourcePaths: try container.decode([String].self, forKey: .sourcePaths),
            destinationRoot: try container.decode(String.self, forKey: .destinationRoot),
            renameTemplate: try container.decodeIfPresent(String.self, forKey: .renameTemplate)
                ?? "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
            secondDestinationRoot: try container.decodeIfPresent(String.self, forKey: .secondDestinationRoot),
            verifyChecksum: try container.decodeIfPresent(Bool.self, forKey: .verifyChecksum) ?? true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, sourcePaths, destinationRoot, renameTemplate, secondDestinationRoot, verifyChecksum
    }
}

public struct SessionIngestResult: Codable, Equatable, Sendable {
    /// 成功复制并已登记的照片数。
    public var registered: Int
    /// 已复制但登记失败（路径仍在，重试 add_photos 即可）。
    public var copiedButUnregistered: [String]
    public var skipped: [String]
    /// 计划阶段被拒绝的源（不可读、或重命名模板越界被拦）。
    public var unreadable: [String]
    public var failed: [MetadataApplyFailureDTO]
    public init(registered: Int, copiedButUnregistered: [String], skipped: [String],
                unreadable: [String] = [], failed: [MetadataApplyFailureDTO]) {
        self.registered = registered
        self.copiedButUnregistered = copiedButUnregistered
        self.skipped = skipped
        self.unreadable = unreadable
        self.failed = failed
    }
}

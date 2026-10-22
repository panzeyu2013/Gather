// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/SessionInputs.swift
// Cut 1 / 阶段 1A：SessionAPI 输入（session.* + workspace.status）。
//
// 对应命令：session.create / create_from_directory（M1 合并）、session.add_photos、
// session.delete(_many)（M2 合并）、session.update、session.get/list、workspace.status。
// 校验归属：
// - name/sessionId/filepaths 的形状与长度在 init/init(from:) 校验；
// - sourcePath 的目录准入（禁根、主目录祖先）与“公共父目录”规则属于会话域，
//   由 1B 的 SessionAPI 实现调用 SessionService/ScanPath 完成，输入类型不碰文件系统；
// - 破坏性删除由 Confirmed<SessionDeleteInput> 承载，API 不再接收裸 Bool。
// 复用：session.update 直接使用 Protocol/Session.swift 的 SessionUpdateParams。

import Foundation

/// session.create / session.create_from_directory 的统一输入（M1）。
/// 分流规则（由 1B 实现）：
/// - filepaths 非空 -> 建会话 + addPhotos + metadataScan job；
/// - filepaths 为空且 sourcePath 非空 -> createFromDirectory；
/// - 两者都为空 -> 仅建空会话。
public struct SessionCreateInput: Decodable, Sendable, Equatable {
    public let name: String
    /// 旧契约是自由字符串（缺省 "manual"）；G10 的枚举化留给后续契约版本。
    public let source: String
    public let sourcePath: String?
    public let filepaths: [String]
    public let truncatedImport: Bool

    public init(
        name: String,
        source: String = "manual",
        sourcePath: String? = nil,
        filepaths: [String] = [],
        truncatedImport: Bool = false
    ) throws {
        self.name = try APIValidation.nonBlank(name, field: "name")
        self.source = try APIValidation.bounded(source, field: "source", maxLength: 128, allowEmpty: true)
        self.sourcePath = sourcePath
        for (index, path) in filepaths.enumerated() {
            _ = try APIValidation.path(path, field: "filepaths[\(index)]")
        }
        self.filepaths = filepaths
        self.truncatedImport = truncatedImport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        let sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        let filepaths = try container.decodeIfPresent([String].self, forKey: .filepaths) ?? []
        let truncatedImport = try container.decodeIfPresent(Bool.self, forKey: .truncatedImport) ?? false
        try self.init(
            name: name,
            source: source,
            sourcePath: sourcePath,
            filepaths: filepaths,
            truncatedImport: truncatedImport
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, source, sourcePath, filepaths, truncatedImport
    }
}

/// session.delete / session.delete_many 的载荷（M2 合并）。
public struct SessionDeleteInput: Decodable, Sendable, Equatable {
    public let sessionIds: [String]

    public init(sessionIds: [String]) throws {
        guard !sessionIds.isEmpty else {
            throw GatherError(code: .SESSION_IDS_REQUIRED, params: ["field": "sessionIds"])
        }
        for (index, id) in sessionIds.enumerated() {
            _ = try APIValidation.nonBlank(id, field: "sessionIds[\(index)]", maxLength: 128)
        }
        self.sessionIds = sessionIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionIds: try container.decode([String].self, forKey: .sessionIds))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionIds
    }
}

/// session.add_photos 的输入（source 缺省 "import"）。
public struct SessionAddPhotosInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let filepaths: [String]
    public let source: String

    public init(sessionId: String, filepaths: [String], source: String = "import") throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.filepaths = try APIValidation.nonEmpty(filepaths, field: "filepaths")
        for (index, path) in self.filepaths.enumerated() {
            _ = try APIValidation.path(path, field: "filepaths[\(index)]")
        }
        self.source = try APIValidation.bounded(source, field: "source", maxLength: 128, allowEmpty: true)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionId = try container.decode(String.self, forKey: .sessionId)
        let filepaths = try container.decode([String].self, forKey: .filepaths)
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? "import"
        try self.init(sessionId: sessionId, filepaths: filepaths, source: source)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, filepaths, source
    }
}

/// 只携带 sessionId 的破坏性/会话级操作载荷（culling/face/sim 的确认入口复用）。
public struct SessionReference: Decodable, Sendable, Equatable {
    public let sessionId: String

    public init(sessionId: String) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sessionId: try container.decode(String.self, forKey: .sessionId))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
    }
}

// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/FaceInputs.swift
// Cut 1 / 阶段 1A：FaceAPI 输入（fkw.* 13 条 + face.models_status -> 13 个方法）。
//
// 对应命令：fkw.clusters / bind / merge / remove_member / analyze / recluster /
// cancel_analysis / unbind / preview / writeback / confirm_sync / cleanup
// （confirm_cleanup 已按 M4 合并）、face.models_status。
// 校验归属：
// - eps 0...1、minSamples 1...1_000_000 在输入构造期显式失败（FACE_EPS_INVALID /
//   FACE_MIN_CLUSTER_INVALID），不再走 optionalNumber 静默 nil；
// - 破坏性入口 unbind/writeback/cleanup 使用 Confirmed<T>；
// - 聚类/写回的业务校验（簇归属、自合并、写回提供者）留在服务层，1B 只做边界映射。

import Foundation

/// fkw.bind 的输入（roleName 非空白；keywords 元素类型由 [String] 保证）。
public struct FaceBindInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int
    public let roleName: String
    public let keywords: [String]

    public init(sessionId: String, clusterId: Int, roleName: String, keywords: [String]) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.clusterId = try APIValidation.nonNegative(clusterId, field: "clusterId")
        self.roleName = try APIValidation.nonBlank(roleName, field: "roleName", maxLength: 1024)
        self.keywords = keywords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            clusterId: try container.decode(Int.self, forKey: .clusterId),
            roleName: try container.decode(String.self, forKey: .roleName),
            keywords: try container.decode([String].self, forKey: .keywords)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, clusterId, roleName, keywords
    }
}

/// fkw.merge 的输入。
public struct FaceMergeInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let source: Int
    public let target: Int

    public init(sessionId: String, source: Int, target: Int) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.source = try APIValidation.nonNegative(source, field: "source")
        self.target = try APIValidation.nonNegative(target, field: "target")
        guard source != target else {
            throw GatherError(code: .FACE_SELF_MERGE, params: ["field": "source"])
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            source: try container.decode(Int.self, forKey: .source),
            target: try container.decode(Int.self, forKey: .target)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, source, target
    }
}

/// fkw.remove_member 的输入。
public struct FaceRemoveMemberInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int
    public let memberId: Int

    public init(sessionId: String, clusterId: Int, memberId: Int) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.clusterId = try APIValidation.nonNegative(clusterId, field: "clusterId")
        self.memberId = try APIValidation.nonNegative(memberId, field: "memberId")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            clusterId: try container.decode(Int.self, forKey: .clusterId),
            memberId: try container.decode(Int.self, forKey: .memberId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, clusterId, memberId
    }
}

/// fkw.analyze 的输入（eps/minSamples 缺省由实现读取设置）。
public struct FaceAnalyzeInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let eps: Double?
    public let minSamples: Int?
    public let detectorPath: String?
    public let encoderPath: String?

    public init(
        sessionId: String,
        eps: Double? = nil,
        minSamples: Int? = nil,
        detectorPath: String? = nil,
        encoderPath: String? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let eps {
            guard eps.isFinite, (0.0...1.0).contains(eps) else {
                throw GatherError(code: .FACE_EPS_INVALID, params: ["field": "eps"])
            }
        }
        self.eps = eps
        if let minSamples {
            _ = try APIValidation.integerInRange(minSamples, field: "minSamples", 2...1_000_000)
        }
        self.minSamples = minSamples
        self.detectorPath = detectorPath
        self.encoderPath = encoderPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            eps: try container.decodeIfPresent(Double.self, forKey: .eps),
            minSamples: try container.decodeIfPresent(Int.self, forKey: .minSamples),
            detectorPath: try container.decodeIfPresent(String.self, forKey: .detectorPath),
            encoderPath: try container.decodeIfPresent(String.self, forKey: .encoderPath)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, eps, minSamples, detectorPath, encoderPath
    }
}

/// fkw.recluster 的输入（只重聚类，不重推理）。
public struct FaceReclusterInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let eps: Double?
    public let minSamples: Int?

    public init(sessionId: String, eps: Double? = nil, minSamples: Int? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        if let eps {
            guard eps.isFinite, (0.0...1.0).contains(eps) else {
                throw GatherError(code: .FACE_EPS_INVALID, params: ["field": "eps"])
            }
        }
        self.eps = eps
        if let minSamples {
            _ = try APIValidation.integerInRange(minSamples, field: "minSamples", 2...1_000_000)
        }
        self.minSamples = minSamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            eps: try container.decodeIfPresent(Double.self, forKey: .eps),
            minSamples: try container.decodeIfPresent(Int.self, forKey: .minSamples)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, eps, minSamples
    }
}

/// fkw.unbind 的载荷（Confirmed<FaceUnbindInput>）。
public struct FaceUnbindInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let clusterId: Int

    public init(sessionId: String, clusterId: Int) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.clusterId = try APIValidation.nonNegative(clusterId, field: "clusterId")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            clusterId: try container.decode(Int.self, forKey: .clusterId)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, clusterId
    }
}

/// fkw.preview 的输入（options 缺省时由写回服务按默认策略处理）。
public struct FacePreviewInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let options: WritebackOptions?

    public init(sessionId: String, options: WritebackOptions? = nil) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            options: try container.decodeIfPresent(WritebackOptions.self, forKey: .options)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, options
    }
}

/// fkw.writeback 的载荷（Confirmed<FaceWritebackInput>；items 缺省 = 全量）。
public struct FaceWritebackInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let items: [WritebackItem]

    public init(sessionId: String, items: [WritebackItem] = []) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            items: try container.decodeIfPresent([WritebackItem].self, forKey: .items) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, items
    }
}

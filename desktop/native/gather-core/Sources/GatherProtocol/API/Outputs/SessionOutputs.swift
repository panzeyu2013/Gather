// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/SessionOutputs.swift
// Cut 1 / 阶段 1A：SessionAPI 的结果类型。
//
// 职责：统一 session.create 的两种历史返回形状（SessionData / {session, added,
// skipped, failedFiles}）——M1 之后调用方只面对一个 SessionCreateResult。
// 校验归属：无（纯输出）。

import Foundation

public struct SessionCreateResult: Codable, Equatable, Sendable {
    public let session: SessionData
    public let added: Int
    public let skipped: Int
    public let failedFiles: [String]

    public init(session: SessionData, added: Int = 0, skipped: Int = 0, failedFiles: [String] = []) {
        self.session = session
        self.added = added
        self.skipped = skipped
        self.failedFiles = failedFiles
    }
}

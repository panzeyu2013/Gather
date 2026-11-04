// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/JobInputs.swift
// Cut 1 / 阶段 1A：JobAPI 输入（jobs.* 4 条 + index.scan -> 5 个方法）。
//
// 对应命令：jobs.list / cancel / retry / clear_completed、index.scan。
// 复用：JobRequest 直接复用 Protocol/Jobs.swift 的 JobCreateParams
// （它是 99 个 *Params 中唯一有真实调用方的类型；形状与 JobService.create 一致）。
// 校验归属：
// - jobs.list 的 includeCheckpoint 缺省 true（旧命令只读取 bool，非 bool 视为 true）；
// - jobs.clear_completed 为破坏性入口，使用 Confirmed<ClearCompletedInput>；
// - index.scan 不再有独立方法：调用方用 start(JobCreateParams.metadataScan(...))。
//   R1 P1-3：dedupeKey/checkpoint 是 Job 去重与续跑的服务端私有规则，
//   只能由本文件的工厂定义；UI/Host 只传 sessionId + 业务扫描范围。

import Foundation

/// JobAPI.start 的请求类型（设计里的 JobRequest；复用既有 JobCreateParams）。
public typealias JobRequest = JobCreateParams

// MARK: - metadata.scan（旧 index.scan）唯一构造入口

extension JobCreateParams {
    /// metadata.scan 的 dedupeKey 规则：JobService 按它做活跃任务去重，
    /// WorkspaceStatusService 也按同一键读取终态行（续跑基线）。
    public static func metadataScanDedupeKey(sessionId: String) -> String {
        "metadata.scan:\(sessionId)"
    }

    /// metadata.scan checkpoint 的扫描集合键，必须与执行器
    /// （GatherApplication WorkflowRegistry 的 metadata.scan）读取的键逐字一致。
    public static let metadataScanRequestedPathsKey = "requestedPaths"

    /// 扫描范围 → checkpoint：nil/空 = 目录全树作用域（空对象；JobService
    /// 仍会按 dedupeKey 继承最近终态行的键做续跑）；非空 = 显式集合作用域。
    public static func metadataScanCheckpoint(
        requestedPaths: [String]?
    ) -> [String: JSONValue] {
        guard let requestedPaths, !requestedPaths.isEmpty else { return [:] }
        return [metadataScanRequestedPathsKey: .array(requestedPaths.map { .string($0) })]
    }

    /// 旧 index.scan 的建任务语义在此单源：type=.metadataScan、
    /// scopeType=session、scopeId=sessionId、dedupeKey、requestedPaths checkpoint。
    /// 调用方不得再自行拼 dedupeKey 或 checkpoint。
    public static func metadataScan(
        sessionId: String,
        requestedPaths: [String]?
    ) -> JobCreateParams {
        JobCreateParams(
            type: .metadataScan,
            scopeType: "session",
            scopeId: sessionId,
            dedupeKey: metadataScanDedupeKey(sessionId: sessionId),
            checkpoint: metadataScanCheckpoint(requestedPaths: requestedPaths)
        )
    }

    /// ingest.run checkpoint 的请求键，必须与 Host 执行器读取的键一致。
    public static let ingestRunRequestKey = "request"

    /// 摄取 Job 的唯一构造入口：完整请求编码进 checkpoint，执行器按同一形状解码。
    /// P2：dedupeKey 带请求指纹；同会话换来源再摄取不得复用旧 job（否则返回
    /// 上一次请求的结果）。完全相同的请求仍复用活跃 job。
    public static func ingestRun(_ input: SessionIngestInput) throws -> JobCreateParams {
        let data = try JSONEncoder().encode(input)
        let json = String(decoding: data, as: UTF8.self)
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for byte in json.utf8 {
            fingerprint = (fingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
        // 复用 checksum.backfill 作为 Job 载体：analysis_jobs.type 的 CHECK 约束
        // 不含 ingest.run，且本设计明确不改 schema；执行器按 operation 分派。
        return JobCreateParams(
            type: .checksumBackfill,
            scopeType: "session",
            scopeId: input.sessionId,
            dedupeKey: "ingest.run:\(input.sessionId):\(String(fingerprint, radix: 16))",
            checkpoint: [
                "operation": .string("ingest"),
                ingestRunRequestKey: .string(json),
            ]
        )
    }
}

/// jobs.list 的过滤条件。
public struct JobListFilter: Decodable, Sendable, Equatable {
    public let includeCheckpoint: Bool

    public init(includeCheckpoint: Bool = true) {
        self.includeCheckpoint = includeCheckpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.includeCheckpoint = try container.decodeIfPresent(Bool.self, forKey: .includeCheckpoint) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case includeCheckpoint
    }
}

/// jobs.clear_completed 的载荷（Confirmed<ClearCompletedInput>）。
public struct ClearCompletedInput: Decodable, Sendable, Equatable {
    /// false = 只清成功终态（默认，保护阶段证据）；true = 只清失败/中断/取消。
    public let includeFailed: Bool

    public init(includeFailed: Bool = false) {
        self.includeFailed = includeFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.includeFailed = try container.decodeIfPresent(Bool.self, forKey: .includeFailed) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case includeFailed
    }
}

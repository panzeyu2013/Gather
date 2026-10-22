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
    /// （GatherHost ExecutorRegistry 的 metadata.scan）读取的键逐字一致。
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
    public init() {}

    public init(from decoder: Decoder) throws {
        // 无字段；保留显式 init 以便未来扩展（如 dryRun）。
        _ = decoder
    }
}

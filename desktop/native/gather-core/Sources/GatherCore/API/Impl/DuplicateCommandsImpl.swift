// API/Impl/DuplicateCommandsImpl.swift
// R5 命令层接线：duplicate 域实现（批次 B5，R5 最后一个未实现域）。
// 逻辑来源：宿主路由层 dup.* 分支；错误码字符串/门控/返回形状/缺省逐字保留：
// - scan：建 duplicate.scan 作业（dedupeKey / checkpoint 逐字沿用旧分支）→ 等结果；
//   空结果按旧分支抛 JobRunnerError.jobFailed（"empty duplicate.scan result"）；
// - groups：同步读取该会话全部重复组（JSON 形状由 DTO 决定）；
// - resolve（破坏性）：confirmed 门控（DUP_RESOLVE_CONFIRM_REQUIRED）后调用运行时；
// - resolve_member（破坏性）：confirmed 门控（DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED）
//   后调用运行时；isKept 由入参显式携带（协议约定取代旧分支的缺省 true）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// duplicate 域命令实现：注入重复运行时与作业运行器。
public actor DuplicateCommandsImpl: DuplicateCommands {
    private let duplicate: DuplicateRuntime
    private let jobs: JobRunner

    public init(duplicate: DuplicateRuntime, jobs: JobRunner) {
        self.duplicate = duplicate
        self.jobs = jobs
    }

    // MARK: - scan

    /// 旧命令：`dup.scan`。visualThreshold 缺省 → "default" / null（与旧分支
    /// 逐字一致）；start 幂等，保证宿主/测试直调时作业不会永久 queued；
    /// 空作业结果以 jobFailed 失败（消息逐字沿用旧分支）。
    public func scan(_ params: DupScanParams) async throws -> DuplicateScanResult {
        let visualThreshold = params.visualThreshold
        _ = await jobs.start()
        let job = try await jobs.create(JobCreateParams(
            type: .duplicateScan,
            scopeType: "session",
            scopeId: params.sessionId,
            dedupeKey: "duplicate.scan:\(params.sessionId):\(visualThreshold.map { "\($0)" } ?? "default")",
            checkpoint: [
                "visualThreshold": visualThreshold.map { .number($0) } ?? .null,
            ]
        ))
        guard let result: DuplicateScanResult = try await jobs.waitForResult(jobId: job.id) else {
            throw JobRunnerError.jobFailed(job.id, "empty duplicate.scan result")
        }
        return result
    }

    // MARK: - groups

    /// 旧命令：`dup.groups`。返回该会话全部重复组（组序/成员序由运行时保证）。
    public func groups(_ params: DupGroupsParams) async throws -> [DuplicateGroup] {
        try await duplicate.getGroups(sessionId: params.sessionId)
    }

    // MARK: - resolve

    /// 旧命令：`dup.resolve`（破坏性）。confirmed 门控通过后执行组决议；
    /// resolution 只认 keep_one / keep_all（由类型化 DTO 保证）。
    public func resolve(_ params: DupResolveParams) async throws {
        guard params.confirmed else {
            throw DuplicateCommandsError.resolveConfirmRequired
        }
        try await duplicate.resolveGroup(groupId: params.groupId, resolution: params.resolution)
    }

    // MARK: - resolve_member

    /// 旧命令：`dup.resolve_member`（破坏性）。confirmed 门控通过后执行单成员
    /// 决议；成员不存在由运行时抛 memberNotFound。
    public func resolveMember(_ params: DupResolveMemberParams) async throws {
        guard params.confirmed else {
            throw DuplicateCommandsError.resolveMemberConfirmRequired
        }
        try await duplicate.resolveMember(memberId: params.memberId, isKept: params.isKept)
    }
}

/// duplicate 域命令边界错误（错误码字符串与旧宿主路由层分支逐字一致）。
public enum DuplicateCommandsError: Error, Equatable {
    /// 旧响应 error 串：`DUP_RESOLVE_CONFIRM_REQUIRED`。
    case resolveConfirmRequired
    /// 旧响应 error 串：`DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED`。
    case resolveMemberConfirmRequired
}

extension DuplicateCommandsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .resolveConfirmRequired: "DUP_RESOLVE_CONFIRM_REQUIRED"
        case .resolveMemberConfirmRequired: "DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED"
        }
    }
}

extension DuplicateCommandsError {
    /// 桥接层序列化用。
    public var gatherCode: GatherErrorCode? {
        switch self {
        case .resolveConfirmRequired: .DUP_RESOLVE_CONFIRM_REQUIRED
        case .resolveMemberConfirmRequired: .DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED
        }
    }
}

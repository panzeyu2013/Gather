// desktop/native/gather-app/Sources/GatherHost/APIs/LiveDuplicateAPI.swift
// Cut 1 / B5a：DuplicateAPI 的 Live 实现（4 个方法）。
//
// 对应命令（4 条）：dup.scan / dup.groups / dup.resolve / dup.resolve_member。
//
// 校验归属：
// - DuplicateScanInput 已在输入类型完成 sessionId 非空白、visualThreshold
//   0...64 整数校验（DUP_THRESHOLD_INVALID，拒绝小数/越界/NaN），本实现不
//   重复解析 JSON、也不做静默截断；
// - DuplicateResolveInput / DuplicateResolveMemberInput 已在输入类型完成
//   groupId/memberId 非负校验（INVALID_PARAM），resolution 由 DupResolution
//   枚举保证 keep_one/keep_all；
// - 只接收 sessionId 的 groups 在这里补“非空白 + 长度上限”校验（对齐
//   LiveAPIInput.requireSessionId），失败统一 GatherError.invalidParameter；
// - 两个破坏性入口只接收 Confirmed<T>（resolve / resolveMember），内部固定
//   传 confirmed 语义：类型层面已经保证“没有确认弹窗就写不出调用点”，
//   实现不再解析 Bool、也不自行补确认（D-011）。
//
// 任务语义（沿用旧命令面 的 dup.scan 分支）：
// - scan：JobService.create(.duplicateScan) → waitForResult，dedupeKey 与
//   checkpoint 逐字保留（visualThreshold 缺省写 null，键尾为 default）；
//   空结果视为 job 失败（empty duplicate.scan result），与旧命令面 的
//   JobServiceError.jobFailed 一致；
// - 扫描单飞（DUPLICATE_SCAN_BUSY）、阈值复核、组/成员归属与照片状态重算
//   仍由 DuplicateService / duplicate.scan executor 负责，本文件不复制规则；
// - groups/resolve/resolveMember 直接委托 DuplicateService 现有接缝，不写
//   第二套 SQL。
//
// 错误映射：DuplicateServiceError 有专用码的 scanBusy/thresholdInvalid 收敛
// 成 GatherError；groupNotFound/memberNotFound 没有协议码，保留原错误（与旧
// 旧实现的普通 Error 语义一致，D-030：非域错误不伪造业务码）。executor
// 失败落库的 message 若本身就是错误码（如 DUPLICATE_SCAN_BUSY），由
// JobServiceError.jobFailed 还原成带码的 GatherError。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveDuplicateAPI: DuplicateAPI {
    private let duplicateService: DuplicateService
    private let jobService: JobService

    /// Sendable 由协议继承显式声明，且类为 final、两个依赖都是构造后不再
    /// 变更的 Sendable let（DuplicateService 的单飞状态由内部 NSLock 串行化，
    /// JobService 的任务表同样由内部锁保护），故无需 @unchecked；此点由编译器检查。
    public init(duplicateService: DuplicateService, jobService: JobService) {
        self.duplicateService = duplicateService
        self.jobService = jobService
    }

    // MARK: - 扫描

    /// dup.scan：建 job + 等待结果（旧命令在 Task 内完成同样的建单/等待）。
    public func scan(_ input: DuplicateScanInput) async throws -> DuplicateScanResult {
        // 旧命令面 对 Double 阈值用 String(Double) 落键（"8.0"），输入类型
        // 已规整为 Int；这里还原同一字形，保证旧 job 的去重键继续命中。
        let thresholdKey = input.visualThreshold.map { String(Double($0)) } ?? "default"
        let job = try map {
            try jobService.create(JobCreateParams(
                type: .duplicateScan,
                scopeType: "session",
                scopeId: input.sessionId,
                dedupeKey: "duplicate.scan:\(input.sessionId):\(thresholdKey)",
                checkpoint: [
                    "visualThreshold": input.visualThreshold.map { .number(Double($0)) } ?? .null,
                ]
            ))
        }
        let result: DuplicateScanResult? = try await mapAsync {
            try await jobService.waitForResult(jobId: job.id)
        }
        guard let result else {
            throw JobServiceError.jobFailed(job.id, "empty duplicate.scan result")
        }
        return result
    }

    // MARK: - 分组读取

    /// dup.groups：按 group_type, id 读取当前会话的重复组。
    public func groups(_ sessionId: String) async throws -> [DuplicateGroup] {
        let id = try LiveAPIInput.requireSessionId(sessionId)
        return try map { try duplicateService.getGroups(sessionId: id) }
    }

    // MARK: - 处置（Confirmed<T>）

    /// dup.resolve：keep_one 按 (size*1000 + mtime) 取最优保留，keep_all 全保留。
    public func resolve(_ input: Confirmed<DuplicateResolveInput>) async throws -> Bool {
        let payload = input.value
        return try map {
            try duplicateService.resolveGroup(
                groupId: payload.groupId,
                resolution: payload.resolution
            )
            return true
        }
    }

    /// dup.resolve_member：单成员保留/移除；resolution 只在未定（NULL）时写。
    public func resolveMember(_ input: Confirmed<DuplicateResolveMemberInput>) async throws -> Bool {
        let payload = input.value
        return try map {
            try duplicateService.resolveMember(
                memberId: payload.memberId,
                isKept: payload.isKept
            )
            return true
        }
    }

    // MARK: - 校验与错误映射

    private func map<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    private func mapAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.translate(error)
        }
    }

    /// 域臂：DuplicateServiceError（有码转码，无码原样）；通用臂见 translateCommon。
    private static func translate(_ error: Error) -> Error {
        if let common = LiveAPIErrorMapping.translateCommon(error) { return common }
        guard let duplicate = error as? DuplicateServiceError else { return error }
        if let code = duplicate.gatherCode {
            return GatherError(code: code, underlying: duplicate.description)
        }
        return duplicate
    }
}

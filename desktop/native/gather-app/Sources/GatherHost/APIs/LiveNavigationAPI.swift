// desktop/native/gather-app/Sources/GatherHost/APIs/LiveNavigationAPI.swift
// Cut 1 / B2：NavigationAPI 的 Live 实现（4 个方法）。
//
// 对应命令（4 条）：navigation.list / split / merge / analyze。
//
// 校验归属：
// - sessionId / groupId / beforePhotoId 在 API 边界做非空白校验（D-012）；
// - 组数 ≥2、同类型、组归属、beforePhoto 属于组等语义仍由 NavigationService
//   负责（NAV_* 错误码原样收敛为 GatherError，不复制业务规则）；
// - analyze 的 burstGapSeconds/sceneGapSeconds 缺省 2/1800、dryRun 缺省 false
//   在实现内补，范围校验仍由 validateNavigationParameters 完成。
//
// WP4b：同步核心（listSync/splitSync/…）已删除；协议方法直接调用
// NavigationService（校验/错误映射语义不变）。

import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

public final class LiveNavigationAPI: NavigationAPI, @unchecked Sendable {
    private let navigationService: NavigationService

    /// @unchecked Sendable 依据：navigationService 为构造后不可变的 let，底层连接
    /// 由 DBConnection 的递归锁串行化。
    public init(navigationService: NavigationService) {
        self.navigationService = navigationService
    }

    // MARK: - NavigationAPI

    public func list(_ sessionId: String) async throws -> [NavigationGroup] {
        let id = try requireNonBlank(sessionId, field: "sessionId")
        return try LiveAPIErrorMapping.map {
            try navigationService.list(sessionId: id)
        }
    }

    public func split(_ input: NavigationSplitParams) async throws -> [NavigationGroup] {
        let sessionId = try requireNonBlank(input.sessionId, field: "sessionId")
        let groupId = try requireNonBlank(input.groupId, field: "groupId")
        let beforePhotoId = try requireNonBlank(input.beforePhotoId, field: "beforePhotoId")
        return try LiveAPIErrorMapping.map {
            try navigationService.split(
                sessionId: sessionId,
                groupId: groupId,
                beforePhotoId: beforePhotoId
            )
        }
    }

    public func merge(_ input: NavigationMergeParams) async throws -> [NavigationGroup] {
        let sessionId = try requireNonBlank(input.sessionId, field: "sessionId")
        // 组数下限/同类型由 NavigationService 校验（NAV_MERGE_MIN_TWO /
        // NAV_MERGE_TYPE_MISMATCH），API 不重复判定。
        return try LiveAPIErrorMapping.map {
            try navigationService.merge(sessionId: sessionId, groupIds: input.groupIds)
        }
    }

    public func analyze(_ input: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        let sessionId = try requireNonBlank(input.sessionId, field: "sessionId")
        return try LiveAPIErrorMapping.map {
            try navigationService.analyze(
                sessionId: sessionId,
                burstGapSeconds: input.burstGapSeconds ?? 2,
                sceneGapSeconds: input.sceneGapSeconds ?? 1_800,
                dryRun: input.dryRun ?? false
            )
        }
    }

    // MARK: - 内部

    private func requireNonBlank(
        _ value: String,
        field: String,
        maxLength: Int = 4096
    ) throws -> String {
        guard value.count <= maxLength else {
            throw GatherError.invalidParameter(
                field: field,
                reason: "length must be at most \(maxLength)"
            )
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatherError.invalidParameter(field: field, reason: "must not be blank")
        }
        return trimmed
    }
}

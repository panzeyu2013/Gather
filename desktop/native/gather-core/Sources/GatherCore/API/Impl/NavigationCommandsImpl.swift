// API/Impl/NavigationCommandsImpl.swift
// R5 命令层接线：navigation 域实现（批次 B3）。
// 逻辑来源：宿主路由层 navigation.analyze / list / split / merge 分支；
// 缺省值（burstGapSeconds 2 / sceneGapSeconds 1800 / dryRun false）、顺序 await
// 与错误语义不变：split 先取组再按 beforePhotoId 切分（越界 NAV_SPLIT_OUT_OF_GROUP、
// 组不存在 NAV_GROUP_NOT_FOUND），merge 由运行时重校验组数（NAV_MERGE_MIN_TWO）
// 与同类型（NAV_MERGE_TYPE_MISMATCH）（ADR-017）。
// 本文件只新增实现类型：不改宿主路由，切换留待 W5-4 逐域剪除时进行。
import Foundation

/// navigation 域命令实现：注入导航运行时（actor，串行化命令入口）。
public actor NavigationCommandsImpl: NavigationCommands {
    private let navigation: NavigationRuntime

    public init(navigation: NavigationRuntime) {
        self.navigation = navigation
    }

    /// 旧命令：`navigation.analyze`。旧分支缺省 2 / 1800 / false；
    /// 参数合法性由运行时校验（NAV_BURST_GAP_INVALID / NAV_SCENE_GAP_INVALID）。
    public func analyze(_ params: NavigationAnalyzeParams) async throws -> [NavigationGroup] {
        try await navigation.analyze(
            sessionId: params.sessionId,
            burstGapSeconds: params.burstGapSeconds ?? 2,
            sceneGapSeconds: params.sceneGapSeconds ?? 1_800,
            dryRun: params.dryRun ?? false
        )
    }

    /// 旧命令：`navigation.list`。组 <2 张由运行时过滤。
    public func list(_ params: NavigationListParams) async throws -> [NavigationGroup] {
        try await navigation.list(sessionId: params.sessionId)
    }

    /// 旧命令：`navigation.split`。顺序 await：查组 → 定位切分下标 → 持久化 →
    /// 回读（返回切分后的全部分组）。
    public func split(_ params: NavigationSplitParams) async throws -> [NavigationGroup] {
        try await navigation.split(
            sessionId: params.sessionId,
            groupId: params.groupId,
            beforePhotoId: params.beforePhotoId
        )
    }

    /// 旧命令：`navigation.merge`。顺序 await：去重校验 → 查组 → 同类型校验 →
    /// 合并持久化 → 回读（ADR-017 的组数/同类型重校验在运行时）。
    public func merge(_ params: NavigationMergeParams) async throws -> [NavigationGroup] {
        try await navigation.merge(sessionId: params.sessionId, groupIds: params.groupIds)
    }
}

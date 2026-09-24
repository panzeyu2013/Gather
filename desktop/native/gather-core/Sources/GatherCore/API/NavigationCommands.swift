// API/NavigationCommands.swift
// R5 类型化 async 域协议：navigation 域。
// 旧实现来源：gather-app/Sources/GatherApp/Host/路由层.swift 的 navigation.*
// 分支（每条方法的注释标注对应旧命令名）。
// 约定：全部 async throws、只用 Protocol/ 既有 DTO、无同步重载。
// 本文件只声明接口：不实现、不接线、不触碰路由与 app。
import Foundation

/// navigation 域命令（4 条）。
///
/// 旧命令清单：`navigation.analyze`、`navigation.list`、`navigation.split`、
/// `navigation.merge`。
///
/// 契约差异（须在 W5-2 实现前裁决）：
/// - 旧 `navigation.analyze` 对 burstGapSeconds / sceneGapSeconds 的缺省值为
///   2 / 1800，dryRun 缺省 false；DTO 中为 nil 时由实现套用这些缺省。
/// - 旧 `navigation.merge` 在服务层重校验组数不少于 2 且同类型（ADR-017）。
public protocol NavigationCommands: Sendable {
    /// 旧命令：`navigation.analyze`。
    /// 分析会话并返回落库后的分组（TS 源 navigation.ipc.ts；旧实现内同步执行）。
    func analyze(_ params: NavigationAnalyzeParams) async throws -> [NavigationGroup]

    /// 旧命令：`navigation.list`。
    /// 返回该会话的全部分组，元素为 Protocol/Navigation.swift 的 NavigationGroup。
    func list(_ params: NavigationListParams) async throws -> [NavigationGroup]

    /// 旧命令：`navigation.split`。
    /// 在 beforePhotoId 前切分指定分组，返回切分后的全部分组。
    func split(_ params: NavigationSplitParams) async throws -> [NavigationGroup]

    /// 旧命令：`navigation.merge`。
    /// 合并 groupIds 指定的多个分组，返回合并后的全部分组。
    func merge(_ params: NavigationMergeParams) async throws -> [NavigationGroup]
}

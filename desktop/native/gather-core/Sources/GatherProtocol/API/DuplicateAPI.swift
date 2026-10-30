// desktop/native/gather-core/Sources/GatherProtocol/API/DuplicateAPI.swift
// Cut 1 / 阶段 1A：重复检测域协议（4 个方法）。
//
// 职责：重复扫描、分组读取、组级/成员级处置。
// 对应命令（4 条）：dup.scan / groups / resolve / resolve_member。
// 校验归属：
// - visualThreshold 0...64 整数在输入类型（DUP_THRESHOLD_INVALID）；
// - resolve/resolveMember 使用 Confirmed<T>；
// - 扫描单飞/繁忙（DUPLICATE_SCAN_BUSY）与成员归属由 DuplicateService 负责。
//
// P1 下一波 §3.8.3（2026-10-30）：跨工作区重复（只读）挂在**本域**而不是新增
// 第 17 个协议——它读的还是 photos.checksum / similarity_hashes，和会话内重复
// 是同一批数据的另一种分组。默认实现抛 INVALID_PARAM，既有 Stub 与 Preview
// 实现（B5bDuplicateAPIStub / PreviewDuplicateAPI）不因新方法而编译失败；
// LiveDuplicateAPI 覆写为真实实现。

import Foundation

public protocol DuplicateAPI: Sendable {
    func scan(_ input: DuplicateScanInput) async throws -> DuplicateScanResult
    func groups(_ sessionId: String) async throws -> [DuplicateGroup]
    func resolve(_ input: Confirmed<DuplicateResolveInput>) async throws -> Bool
    func resolveMember(_ input: Confirmed<DuplicateResolveMemberInput>) async throws -> Bool
    /// 组级“恢复未处理”：清空组 resolution、全部成员恢复保留。
    func resetGroup(_ input: Confirmed<DuplicateResetGroupInput>) async throws -> Bool
    /// 跨工作区重复/相似（**只读**）：精确 checksum 分组 + 视觉 hash 桶内汉明比较。
    ///
    /// 不做跨工作区删除——删除语义涉及两个工作区的可见性，风险高于价值（§3.8.3）。
    func globalDuplicates(_ input: GlobalDuplicateScanInput) async throws -> GlobalDuplicateScanResult
}

public extension DuplicateAPI {
    /// 默认实现：显式"未实现"，沿用 INVALID_PARAM，不新增错误码。
    func globalDuplicates(_ input: GlobalDuplicateScanInput) async throws -> GlobalDuplicateScanResult {
        throw GatherError.invalidParameter(
            field: "globalDuplicates",
            reason: "cross-workspace duplicate scan is not implemented by this DuplicateAPI implementation"
        )
    }
}

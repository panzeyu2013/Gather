// desktop/native/gather-core/Sources/GatherProtocol/API/DuplicateAPI.swift
// Cut 1 / 阶段 1A：重复检测域协议（4 个方法）。
//
// 职责：重复扫描、分组读取、组级/成员级处置。
// 对应命令（4 条）：dup.scan / groups / resolve / resolve_member。
// 校验归属：
// - visualThreshold 0...64 整数在输入类型（DUP_THRESHOLD_INVALID）；
// - resolve/resolveMember 使用 Confirmed<T>；
// - 扫描单飞/繁忙（DUPLICATE_SCAN_BUSY）与成员归属由 DuplicateService 负责。

import Foundation

public protocol DuplicateAPI: Sendable {
    func scan(_ input: DuplicateScanInput) async throws -> DuplicateScanResult
    func groups(_ sessionId: String) async throws -> [DuplicateGroup]
    func resolve(_ input: Confirmed<DuplicateResolveInput>) async throws -> Bool
    func resolveMember(_ input: Confirmed<DuplicateResolveMemberInput>) async throws -> Bool
}

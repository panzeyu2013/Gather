// desktop/native/gather-app/Sources/GatherUI/Support/DomainErrorPorts.swift
// Cut 3 / 3b-3（E-19 相邻）：UI 侧的两个「错误语义」端口。
//
// WP4b：原 LiveSyncPorts.swift 的 4 个同步能力端口（18 个方法）已删除；
// 这里只保留与同步无关、生产仍在使用的能力面，文件名随内容收窄。
import Foundation
import GatherProtocol

/// 任务取消标记端口（E-19 相邻）：UI 需要把「任务被取消」与真实失败区分
/// （取消是正常终态，不落红色错误条）。实现：GatherHost 为 Domain 的
/// JobCancelledError 提供空 conformance。
public protocol JobCancellationMarker {}

/// 域错误原文端口（E-19 相邻修复）：UI 的 rawMessage 曾 `as?` Domain 的
/// JobServiceError / FaceKwServiceError 取原始文案；拆 target 后改由 Host
/// 以 extension 暴露同一语义（Live API 已优先收敛为 GatherError，这里只是
/// 兜底分支，不改变正常路径）。
public protocol DomainErrorMessaging {
    /// 可展示的原始错误文案；nil = 该错误没有更具体的原文。
    var rawErrorMessage: String? { get }
}

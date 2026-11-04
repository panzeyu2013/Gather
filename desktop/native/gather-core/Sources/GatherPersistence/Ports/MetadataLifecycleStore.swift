// desktop/native/gather-core/Sources/GatherPersistence/Ports/MetadataLifecycleStore.swift
// 元数据交付生命周期的两个窄端口（#8：把 Application 从 DBConnection 上摘下来）。
//
// 为什么按消费者切成 2 个而不是 1 个 11 方法镜像：两个端口各有唯一消费者，
// 且没有任何方法在消费者两侧都用得上——镜像端口会让每个消费者看见自己不能用的
// 方法（那才是 god protocol 的定义）。ADR-032 #4 要求新增窄端口在本 ADR 追加一行。
//
// 实现契约（改动前必须读）：
// - sessionId 的 nil 语义必须保留并**下推到 SQL**（nil = 全库，非 nil = 只含该会话
//   关联的交付）；在 Application 侧过滤会重新引入"被别的会话候选饿死"的老问题；
// - referencedBackupPaths() 不接受 sessionId：备份 GC 必须看全库引用，作用域会误删；
// - deleteRowIfEmpty / deleteVanishedRow 是**单事务内复核后删**（repo:300 / :317），
//   拆成"先查后删"会丢 B6 的 TOCTOU 保护；
// - linkedSessions 回答"全部关联会话"，不能被作用域读取替代（reload-ack 门禁要看全量）。
import Foundation

/// 交付生命周期读取（消费者：MetadataDeliveryService 的 state/backup 路径）。
public protocol MetadataDeliveryReading: Sendable {
    /// 各交付的 status/backup_path 投影（state 的读取来源）。
    func projections(sessionId: String) throws -> [MetadataLifecycleProjection]
    /// 备份路径（nil = 全库：备份统计与 retention 的引用集）。
    func backupPaths(sessionId: String?) throws -> [String]
}

/// 保留期回收（消费者：MetadataRetentionService 的 5 个阶段）。
///
/// 名字用 Store 而不是 Reading：它含两个写入口（deleteRowIfEmpty / deleteVanishedRow），
/// 且写入口自带事务与复核语义。
public protocol MetadataRetentionStore: Sendable {
    func adoptionCandidates(limit: Int, sessionId: String?) throws -> [MetadataLifecycleRow]
    func expiredCandidates(
        cutoff: String, limit: Int, sessionId: String?) throws -> [MetadataLifecycleRow]
    func emptyCandidates(
        cutoff: String, limit: Int, sessionId: String?) throws -> [MetadataLifecycleRow]
    func vanishedCandidates(limit: Int, sessionId: String?) throws -> [MetadataLifecycleRow]
    /// 空父目录候选（只读；调用方还要判定"是否已空"）。
    func orphanRoots(sessionId: String?) throws -> [String]
    /// 仍被任何交付引用的备份路径（全库；不接受作用域）。
    func referencedBackupPaths() throws -> Set<String>
    /// 某交付的全部关联会话与确认态（reload-ack 门禁的事实来源）。
    func linkedSessions(deliveryId: Int64) throws -> [(id: String, acked: Bool)]
    /// 零 item 且超龄的孤儿行：事务内复核后删除；返回 false = 复核不通过（skipped）。
    func deleteRowIfEmpty(id: Int64, xmpPath: String) throws -> Bool
    /// 文件已消失、无租约的交付行：同上，事务内复核。
    func deleteVanishedRow(id: Int64, xmpPath: String) throws -> Bool
}

// 实现侧：MetadataLifecycleRepo 是唯一实现，conformance 写在本文件（NarrowStores 的既有做法，
// check-no-legacy 禁止在 GatherHost 之外新建 *Adapter* 文件）。
extension MetadataLifecycleRepo: MetadataDeliveryReading {}
extension MetadataLifecycleRepo: MetadataRetentionStore {}

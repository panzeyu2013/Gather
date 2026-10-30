// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataFileSession.swift
// P1 下一波：内嵌写回的"一次打开、一次遍历"会话端口。
//
// 目的：把"指纹 / 备份 / 读属性 / 写盘 / 写后校验 / 写后回读"从 6–8 次整文件读
// 收敛为 2 次顺序遍历；实现（JPEG 段布局、原子替换）留在 Host，Delivery 只依赖本协议。

import Foundation

/// 一次写回的结果（供 deliveries.base_fingerprint / backup_path 落库）。
public struct MetadataRewriteReport: Codable, Equatable, Sendable {
    public var bytesBefore: Int64
    public var bytesAfter: Int64
    /// "size:mtimeMs:sha256" —— 与 MetadataFingerprint 同格式。
    public var fingerprintAfter: String
    /// 写后扫描段 SHA-256（写前/写后必须相等）。
    public var scanDigest: String
    public var touchedIIM: Bool
    public var headerBackupPath: String

    public init(
        bytesBefore: Int64,
        bytesAfter: Int64,
        fingerprintAfter: String,
        scanDigest: String,
        touchedIIM: Bool,
        headerBackupPath: String
    ) {
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.fingerprintAfter = fingerprintAfter
        self.scanDigest = scanDigest
        self.touchedIIM = touchedIIM
        self.headerBackupPath = headerBackupPath
    }
}

/// 一个已经打开的内嵌目标。生命周期：open → (optional backup) → commit/abort。
public protocol MetadataRewriteSession: AnyObject, Sendable {
    /// 打开时的 "size:mtimeMs:sha256"（一次遍历算出）。
    var fingerprintBefore: String { get }
    /// 盘上当前属性（XMP + IIM，sidecar 覆盖规则由实现决定）。
    var attributes: MetadataWriteAttributes { get }
    /// 头部字节数（诊断/预算用）。
    var headerByteCount: Int { get }
    /// 写头部备份（幂等：重复调用返回同一路径）。
    func writeHeaderBackup() async throws -> String
    /// 提交（写临时文件 → 替换前校验 → 原子替换）。
    func commit(_ attributes: MetadataWriteAttributes) async throws -> MetadataRewriteReport
    /// 放弃（关闭句柄/清临时文件）。
    func abort() async
}

/// 内嵌目标的会话工厂。返回 nil = 不是内嵌目标或不支持（sidecar/RAW/fake）。
public protocol MetadataRewriteSessionFactory: Sendable {
    func open(photoPath: String) async throws -> (any MetadataRewriteSession)?
}

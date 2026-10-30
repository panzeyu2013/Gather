// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataDelivery.swift
// P1 下一波：metadata/template 交付的生命周期投影（confirm / finalize / 备份统计）。

import Foundation

public struct MetadataDeliveryRow: Codable, Equatable, Sendable, Identifiable {
    public var xmpPath: String
    public var status: String
    public var modules: [String]
    public var backupBytes: Int
    public var updatedAt: String

    public var id: String { xmpPath }

    public init(
        xmpPath: String,
        status: String,
        modules: [String],
        backupBytes: Int = 0,
        updatedAt: String = ""
    ) {
        self.xmpPath = xmpPath
        self.status = status
        self.modules = modules
        self.backupBytes = backupBytes
        self.updatedAt = updatedAt
    }
}

public struct MetadataDeliveryState: Codable, Equatable, Sendable {
    public var pending: Int
    public var written: Int
    public var synced: Int
    public var failed: Int
    public var conflict: Int
    public var backupCount: Int
    public var backupBytes: Int64
    public var requiresReloadAck: Bool
    public var rows: [MetadataDeliveryRow]
    /// 逐条失败/跳过原因（finalize/confirm 的 XMP_* 码）；UI 直接展示。
    public var notices: [String]

    public init(
        pending: Int = 0,
        written: Int = 0,
        synced: Int = 0,
        failed: Int = 0,
        conflict: Int = 0,
        backupCount: Int = 0,
        backupBytes: Int64 = 0,
        requiresReloadAck: Bool = false,
        rows: [MetadataDeliveryRow] = [],
        notices: [String] = []
    ) {
        self.pending = pending
        self.written = written
        self.synced = synced
        self.failed = failed
        self.conflict = conflict
        self.backupCount = backupCount
        self.backupBytes = backupBytes
        self.requiresReloadAck = requiresReloadAck
        self.rows = rows
        self.notices = notices
    }
}

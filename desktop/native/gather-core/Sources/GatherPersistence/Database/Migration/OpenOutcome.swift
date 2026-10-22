// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/OpenOutcome.swift
// WP6a：Database.open 的可观测结果（设计 §5.1）。用 extension 挂在 Database 下，
// 保持 `Database.OpenOutcome` / `Database.ResetReason` 的调用面，同时让 Database.swift
// 只保留 open 状态机本身（行数目标 ≤520）。
//
// .migrated 在 WP6a 的 production 目录（current=.v1、迁移表为空）不可达；字段先冻结，
// WP6b 备份完成后填 backup 路径。
public extension Database {
    /// 开发重置的原因（OpenOutcome.reset 的可读标签）。
    enum ResetReason: Sendable, Equatable, CustomStringConvertible {
        case notADatabase
        case legacyPreV1
        case shapeMismatch(version: Int)
        case unreadableVersion
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notADatabase:
                return "不是 SQLite 文件"
            case .legacyPreV1:
                return "V1 之前的旧库"
            case .shapeMismatch(let version):
                return "user_version=\(version) 但列形不符"
            case .unreadableVersion:
                return "user_version 读不出"
            case .newerVersion(let version):
                return "库版本 \(version) 高于本构建"
            }
        }
    }

    /// 本次 open 实际做了什么（启动日志/测试断言用；设计 §5.1）。
    enum OpenOutcome: Sendable, Equatable {
        case created(SchemaVersion)
        case opened(SchemaVersion)
        /// WP6a 的 production 目录没有迁移，此分支尚不可达；WP6b 备份完成后填 backup。
        case migrated(from: SchemaVersion, to: SchemaVersion, backup: String?)
        case reset(reason: ResetReason, previousVersion: Int?, backup: String)
    }
}

// desktop/native/gather-core/Sources/GatherPersistence/Database/Migration/OpenOutcome.swift
// Database.open 的可观测结果。只有三种：新建 / 打开当前库 / 开发重置。
public extension Database {
    /// 开发重置的原因（OpenOutcome.reset 的可读标签）。
    enum ResetReason: Sendable, Equatable, CustomStringConvertible {
        case notADatabase
        case legacyPreV1
        /// 旧版本库（V1/V2）：不再迁移，默认 fail closed。
        case oldVersion(Int)
        case shapeMismatch(version: Int)
        case unreadableVersion
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notADatabase: return "不是 SQLite 文件"
            case .legacyPreV1: return "V1 之前的旧库"
            case .oldVersion(let version): return "旧版本库 user_version=\(version)"
            case .shapeMismatch(let version): return "user_version=\(version) 但列形不符"
            case .unreadableVersion: return "user_version 读不出"
            case .newerVersion(let version): return "库版本 \(version) 高于本构建"
            }
        }
    }

    enum OpenOutcome: Sendable, Equatable {
        case created(Int)
        case opened(Int)
        case reset(reason: ResetReason, previousVersion: Int?, backup: String)
    }
}

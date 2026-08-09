import Foundation

// TODO(1.2): 接入 SQLite.swift（schema/migrations/repos）后移除本文件。
public enum DatabaseStatus: Equatable {
    case notInitialized
    case ready
}

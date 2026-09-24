// desktop/native/gather-core/Sources/GatherCore/Runtime/Indexer/IndexerRuntime.swift
// idx2a：IndexerRuntime actor 最小骨架（本步骤只签署接口，不迁移任何行为）。
//
// 边界（后续步骤逐步填充）：
// - 可变状态仅 cancelledSessions：cancel(sessionId:) 幂等登记；扫描实现迁入后
//   读取并清理。本文件零 SQL、零锁、不触碰 Store 实现。
// - 依赖经 Dependencies 值类型注入；SessionStore / PhotoStore 协议继承 Sendable，
//   SQLiteDatabase 为 actor，因此 Dependencies 可安全跨 actor 边界传递。
// - 契约类型复用 Protocol/Indexer.swift 的真实定义（IndexScanParams /
//   IndexScanResult），不在此重复声明。错误用本文件新增的最小
//   IndexerRuntimeError：旧 Services/IndexerService.swift 的 IndexerServiceError
//   只有 sessionNotFound / noSourcePath，无骨架所需的 notImplemented 类目。

import Foundation
import SQLite3

/// 索引器运行时错误（骨架期占位；实现迁入后按需增删）。
public enum IndexerRuntimeError: Error, Equatable {
    case notImplemented(sessionId: String)
}

public actor IndexerRuntime {
    /// 运行时依赖（idx2b1 扩容：对齐旧 IndexerService 全集；引用为 Sendable
    /// 值语义，闭包为 @Sendable，可跨 actor 边界传递）。
    public struct Dependencies: Sendable {
        public let sessionStore: any SessionStore
        public let photoStore: any PhotoStore
        public let assetStore: any AssetStore
        public let database: SQLiteDatabase
        /// 图片尺寸读取（旧 IndexerService.DimensionsProvider；默认走 RAWDecoder）。
        public let getDimensions: @Sendable (String) throws -> (width: Int, height: Int)
        /// 设置读取（旧 IndexerService.SettingReader；默认回退 defaultValue）。
        public let getSetting: @Sendable (String, String) -> String
        /// stat 测试接缝（等价旧 IndexerService.stat；默认 IndexerService.defaultStat）。
        public var stat: @Sendable (String) throws -> IndexerService.FileStat
        /// checksum 计算接缝（等价旧 IndexerService.fileHasher；默认 IndexerService.sha256File）。
        public var fileHasher: @Sendable (String) async throws -> String

        public init(
            sessionStore: any SessionStore,
            photoStore: any PhotoStore,
            assetStore: any AssetStore,
            database: SQLiteDatabase,
            getDimensions: @escaping @Sendable (String) throws -> (width: Int, height: Int) = { try IndexerService.defaultDimensions($0) },
            getSetting: @escaping @Sendable (String, String) -> String = { _, defaultValue in defaultValue },
            stat: @escaping @Sendable (String) throws -> IndexerService.FileStat = { try IndexerService.defaultStat($0) },
            fileHasher: @escaping @Sendable (String) async throws -> String = { try IndexerService.sha256File($0) }
        ) {
            self.sessionStore = sessionStore
            self.photoStore = photoStore
            self.assetStore = assetStore
            self.database = database
            self.getDimensions = getDimensions
            self.getSetting = getSetting
            self.stat = stat
            self.fileHasher = fileHasher
        }
    }

    private let deps: Dependencies

    /// 已请求取消的 session（骨架期只登记；扫描实现随后续步骤消费并清理）。
    private var cancelledSessions: Set<String> = []

    public init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    /// 扫描（骨架：真实扫描逻辑随后续步骤自 Services/IndexerService 迁入）。
    /// 注：options 复用协议层真实的 IndexScanParams（其自带 sessionId 字段，与入参
    /// sessionId 重复，属契约原样复用）；后续步骤可决定是否折叠为单参数。
    public func scan(sessionId: String, options: IndexScanParams) async throws -> IndexScanResult {
        throw IndexerRuntimeError.notImplemented(sessionId: sessionId)
    }

    /// 请求取消（幂等）。
    public func cancel(sessionId: String) {
        cancelledSessions.insert(sessionId)
    }
}

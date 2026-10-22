// desktop/native/gather-app/Sources/GatherHost/Composition/Runtime.swift
// WP4c / 组合根阶段 2：运行时装配 + 组合根入口。
//
// CompositionRuntime 是 executorDeps 与 AppRuntime 的唯一构造点：不得在此
// new 任何业务服务（execute 注册表、db、JobService、DeliveryCoordinator 都来自
// CompositionCore 的同一批实例）。CompositionRoot 只按阶段串联
// Core → Runtime → AppComposition，AppComposition.make 是它的公开门面。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherApplication

/// 运行时装配：8 个 executor 依赖 + AppRuntime（组合根唯一构造点）。
enum CompositionRuntime {
    static func make(core: CompositionCore) -> AppRuntime {
        // executorDeps 与 runtime 的唯一构造点；参数顺序与拆分前逐字一致。
        let executorDeps = ExecutorRegistry.Dependencies(
            similarityService: core.similarityService,
            duplicateService: core.duplicateService,
            faceKwService: core.faceKwService,
            qualityService: core.qualityService,
            indexerService: core.indexerService,
            metadataService: core.metadataService,
            photoRepo: core.photoRepo,
            assetRepo: core.assetRepo,
            imagePreloadService: core.imagePreloadService,
            exportService: core.exportService
        )
        return AppRuntime(
            db: core.db,
            database: core.database,
            jobService: core.jobService,
            delivery: core.deliveryCoordinator,
            executorDeps: executorDeps
        )
    }
}

/// 组合根入口：服务图 → 运行时 → 根对象（AppComposition 逐字段转发 Core）。
enum CompositionRoot {
    /// 生产装配：接收 `Database.open(at:)` 的门面。
    static func make(
        database: Database,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> AppComposition {
        make(
            db: database.connection,
            database: database,
            xmpProvider: xmpProvider,
            metadataWriteDebounceMs: metadataWriteDebounceMs,
            faceKwService: faceKwService
        )
    }

    /// 测试接缝：只接收裸连接（测试夹具没有 Database 门面）。
    /// 生产不得调用——生产必须走 `make(database:)`，由 runtime 负责 close 门面。
    static func make(
        db: DBConnection,
        database: Database? = nil,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> AppComposition {
        let core = CompositionCore.make(
            db: db,
            database: database,
            xmpProvider: xmpProvider,
            metadataWriteDebounceMs: metadataWriteDebounceMs,
            faceKwService: faceKwService
        )
        let runtime = CompositionRuntime.make(core: core)
        return AppComposition(core: core, runtime: runtime)
    }
}

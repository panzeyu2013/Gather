// desktop/native/gather-app/Sources/GatherHost/AppBootstrap.swift
// Cut 3 / 3b-1：宿主启动装配（从 GatherApp.swift 抽出）。
//
// 职责边界（只做装配与生命周期，不含页面/业务逻辑）：
// - 应用数据目录与库文件权限 → Database.open（SchemaCurrent）→ AppComposition.make；
// - AppServices.live 十六域装配；AppRuntime.start() / shutdown() 生命周期；
// - 冷启动语言、jobs:progress 事件总线、原生 embedding 一次性迁移；
// - 页面 provider、CaptureOneBridge 与 AppDelegate 回调接线；
// - 把窗口/场景渲染所需状态一次性发布为 `scene`，SwiftUI 只读、不持有服务。
//
// 不改变 AppComposition/AppRuntime 的 API：组合根仍唯一由 AppComposition.make
// 构造，运行时仍是 composition.runtime，不存在第二套 db/JobService/executor。
//
// 可测入口：`startup(delegate:applicationSupportDirectory:)` / `shutdown()` 均为
// internal，且 `applicationSupportDirectory` 可指向临时目录（nil = 生产路径）。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import Observation
import GatherUI

@MainActor
@Observable
package final class AppBootstrap {
    /// Cut 4 / 4a-3a：界面语言的**唯一写入入口**（审计 §1.6 的 4 个载体 +
    /// 4 个重复写点收敛到这里）。
    ///
    /// 由装配层而不是场景持有：`.commands` 在 `scene` 发布前就要读菜单语言。
    /// 冷启动时 `makeScene` 用持久化的 `settings.ui_language` 调 `seed`，
    /// 随 `SceneState.languageStore` 发布给 RootView / SettingsView。
    package let languageStore: LanguageStore

    /// Phase 4：菜单/快捷键的唯一命令通道。RootView 在 onAppear 安装 handler，
    /// `.commands` 只调 `perform`，不再 post 通知（也没有 AppKit 菜单兜底）。
    package let commandCenter: AppCommandCenter
    /// B0：日志 sink 必须持有；install 返回的实例被丢弃会让
    /// GatherLogger.output 里的 weak self 立刻失效，文件日志实际不落盘。
    /// 安装发生在 static makeScene，故用 MainActor 静态存储保活。
    private static var logSink: LogFileSink?

    package init() {
        self.languageStore = LanguageStore()
        self.commandCenter = AppCommandCenter()
    }

    /// 场景渲染所需的全部引用（bootstrap 成功后一次性发布）。
    package struct SceneState {
        package let appServices: AppServices
        /// Cut 3 / 3b-3（E-17）：宿主 Settings 场景显式注入 C1 桥（协议面），
        /// 页面不再自建 CaptureOneBridge。
        package let captureOneBridge: any CaptureOneBridging
        /// Cut 4 / 4a-2a-1 装配、4a-2a-2 起使用：壳层依赖包（§4.6）。
        /// GatherApp 以 `RootView(deps: scene.rootDeps, …)` 注入，RootView 不再
        /// 持有 AppServices/provider。
        package let rootDeps: RootShellDependencies
        /// Cut 4 / 4a-2a-1 装配、4a-2a-2 起使用：活动工作区表（工厂注入 7 个
        /// VM/workspace，capacity 6 + LRU）。启动时不建 workspace；首次
        /// `activate/workspace(for:)` 才由工厂构造。
        package let sessionStore: SessionStore
        /// Cut 4 / 4a-3a：语言唯一写入口（与 AppBootstrap.languageStore 同一实例）。
        /// 场景只读它的 language/l10n；写入只经 SettingsViewModel.setLanguage。
        package let languageStore: LanguageStore
        package let commandCenter: AppCommandCenter
        /// B0：取消尚未 swap 的恢复（设置页“待完成恢复”区）。
        package let cancelPendingRestore: () async -> Bool
    }

    /// 场景状态；nil = 未就绪（初始化中或失败）。
    package private(set) var scene: SceneState?
    /// 失败态文案（经 APIErrorPresentation 统一转换）；nil = 未失败。
    package private(set) var errorMessage: String?

    /// 启动重入保护（不参与场景刷新）。
    @ObservationIgnored private var isStarting = false
    /// 唯一运行时（`shutdown()` 的停机入口；与 scene.appServices.runtime 同一实例）。
    @ObservationIgnored private var runtime: AppRuntime?
    /// P0 / B0：维护服务（自动备份调度器随启动/停机接线；与 scene 同一实例）。
    @ObservationIgnored private var maintenanceService: MaintenanceService?

    /// 启动装配。顺序与拆分前 `GatherApp.bootstrap` 逐行一致：
    /// 目录 → 库 → 组合根 → AppServices → 冷启动语言 → runtime.start →
    /// 事件总线 → embedding 迁移 → provider → C1 桥/Delegate 回调 → 发布场景。
    ///
    /// - Parameters:
    ///   - delegate: 生产恒为 `GatherAppDelegate`；nil 仅用于测试（不接线）。
    ///   - applicationSupportDirectory: 应用数据根目录；nil = 生产路径。
    package func startup(
        delegate: GatherAppDelegate? = nil,
        applicationSupportDirectory: URL? = nil
    ) async {
        guard scene == nil, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            let (state, runtime, maintenance) = try await Self.makeScene(
                delegate: delegate,
                applicationSupportDirectory: applicationSupportDirectory,
                // 4a-3a：语言唯一写入口由装配层持有，冷启动在这里播种。
                languageStore: languageStore,
                commandCenter: commandCenter
            )
            self.runtime = runtime
            self.maintenanceService = maintenance
            self.scene = state
            // B0：按 backup_auto 启停调度器（off 时 startScheduler 自身 no-op）。
            await maintenance.startScheduler()
            // ADR-023 + B0：退出前优雅停机 —— 停自动备份调度器、等备份收尾、排空写回、关库。
            // 必须经 bootstrap.shutdown()：只调 runtime.shutdown() 会跳过 stopScheduler/
            // waitForBackup，退出时备份被半途掐断并累计 autoPaused。
            if let delegate {
                delegate.onPrepareForTermination = { [weak self] in
                    await self?.shutdown()
                }
            }
        } catch {
            GatherLogger.log("bootstrap failed: \(error)", level: .error)
            // 旧库/损坏库给可执行的归档指引；其余错误仍走统一漏斗。
            if let unrecoverable = error as? RestoreUnrecoverableError {
                self.errorMessage = languageStore.l10n.errorText(
                    GatherErrorCode.RESTORE_FAILED.rawValue
                ) + "：" + unrecoverable.failure.message
            } else if let dbError = error as? DatabaseError, case .corrupt = dbError {
                self.errorMessage = languageStore.l10n(
                    "数据库版本不受支持或已损坏。请将 ~/Library/Application Support/Gather/gather.sqlite 及 -wal/-shm 移走备份后重试。")
            } else {
                // Cut 4 / 4b-1：启动失败文案按装配层已播种的界面语言解析（场景尚未
                // 发布，没有 View 的 environment 可用，语言源仍是同一个 store）。
                self.errorMessage = APIErrorPresentation.userFacingMessage(
                    for: error, with: languageStore.l10n)
            }
        }
    }

    /// 优雅停机（ADR-023）：委托唯一 AppRuntime（幂等）。
    /// 启动未完成/失败时为 no-op（与拆分前「Delegate 回调未挂载」语义一致）。
    package func shutdown() async {
        if let maintenanceService {
            await maintenanceService.stopScheduler()
            await maintenanceService.waitForBackup(timeout: 15)
        }
        await runtime?.shutdown()
    }

    // MARK: - 装配

    private static func makeScene(
        delegate: GatherAppDelegate?,
        applicationSupportDirectory: URL?,
        languageStore: LanguageStore,
        commandCenter: AppCommandCenter
    ) async throws -> (SceneState, AppRuntime, MaintenanceService) {
        let applicationSupport: URL
        if let applicationSupportDirectory {
            applicationSupport = applicationSupportDirectory
        } else {
            applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let appDir = applicationSupport.appendingPathComponent("Gather", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        // 审计 P2-安全：库内含照片路径 + 人脸特征，目录 755/SQLite 0644
        // 过宽 → 收紧为仅当前用户（700/600）。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: appDir.path)
        let dbURL = appDir.appendingPathComponent("gather.sqlite")
        // A-3：打开持久化缩略图缓存（测试默认关闭）。
        ThumbnailDiskCache.isEnabled = true
        // Cut 3 / 3b-3（E-04）：注册页面解码端口（RAWDecoder 在 GatherAnalysis，
        // GatherUI 只能经 ImageDecoderPort 拿到；重复注册按后者生效）。
        ImageDecodingRegistry.install(RAWImageDecoder())
        // R7（refactor）：导入路径规则与 C1 同步状态判定已下沉 GatherProtocol，
        // UI 直调纯函数，不再有端口/registry/Host 适配器。
        // B0：文件日志 sink（启动早期安装，Database.open 的失败也能落盘）。
        Self.logSink = LogFileSink.install(
            directory: appDir.appendingPathComponent("Logs", isDirectory: true))

        // B0：跨进程恢复。journal 存在时先拿恢复锁，在 Database.open 前 swap；
        // 成功 open 后 finalize，失败回滚旧库。
        var didRestore = false
        let restoreLock: RestoreLock?
        if RestoreCoordinator.hasPending(dbPath: dbURL.path) {
            restoreLock = try RestoreLock.acquire(at: appDir)
            let outcome = try RestoreCoordinator.applyPendingIfNeeded(dbPath: dbURL.path)
            switch outcome {
            case .applied:
                didRestore = true
            case .rolledBack(let failure):
                GatherLogger.log(
                    "restore rolled back: \(failure.code) \(failure.message)", level: .warn)
            case .unrecoverable(let failure):
                // 不能继续 open：空库重建会掩盖数据丢失，且会禁用一次 delivery 回放的语义。
                GatherLogger.log(
                    "restore unrecoverable: \(failure.code) \(failure.message)", level: .error)
                throw RestoreUnrecoverableError(failure: failure)
            case .none:
                break
            }
        } else {
            restoreLock = nil
        }
        defer { restoreLock?.release() }

        // 复审 P2（C5）：Database.open 会做 schema inspect/assertReady（并可能迁移/恢复），
        // 是启动期最重的同步 IO；放到 detached 任务，主线程可继续绘制“初始化中…”。
        // Database/DBConnection 均为 @unchecked Sendable（句柄访问由 connectionLock 串行）。
        let openDatabase: @Sendable () async throws -> Database = {
            try await Task.detached(priority: .userInitiated) {
                try Database.open(at: dbURL.path)
            }.value
        }
        let database: Database
        if didRestore {
            do {
                database = try await openDatabase()
            } catch {
                GatherLogger.log(
                    "Database.open after restore failed; rolling back: \(error)", level: .error)
                let rolledBack = BestEffort.attempt("rollback restore on open failure") {
                    try RestoreCoordinator.rollbackToPrevious(dbPath: dbURL.path)
                }
                guard rolledBack else {
                    // 回滚失败 = 现场不可安全继续：fail closed。绝不能按「未恢复」继续启动，
                    // 否则会在旧库被覆盖后照常回放 delivery（B0 §3.5 明令禁止的路径）。
                    GatherLogger.log(
                        "restore rollback failed; failing closed: \(error)", level: .error)
                    throw error
                }
                database = try await openDatabase()
                didRestore = false
            }
            if didRestore {
                BestEffort.attempt("finalize restore") {
                    try RestoreCoordinator.finalizeOpened(dbPath: dbURL.path)
                }
            }
        } else {
            database = try await openDatabase()
        }
        let db = database.connection
        // 审计 P2-安全：库内含照片路径 + 人脸特征，库文件只给当前用户读写。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
        // F-5：让 db_synchronous / db_cache_size_mb 设置真正生效（DB 层不反向
        // 依赖 Services，这里注入一个只读的设置读取钩子；注入即重放 PRAGMA）。
        // 复审 P2：此前 [weak settingsRepo] 捕获的是局部实例，makeScene 返回即释放，
        // provider 之后恒 nil（db_synchronous/db_cache_size_mb 改了要重启才生效）。
        // 这里每次读时临时构造 Repo，避免为 provider 制造 db→repo→db 的持有环；
        // 只在 PRAGMA 应用时调用，频率极低。
        db.settingsProvider = { [weak db] key in
            guard let db else { return nil }
            return (try? SettingsRepo(connection: db).get(key: key))?.value
        }

        // Cut 1 / B8.3b-2a/B8.3b-2b：组合根只构造一次（24 个服务/Repo +
        // 唯一 AppRuntime）。宿主、AppServices、页面 provider、Capture One
        // 桥与导入路径全部从同一个 composition 取实例。
        let composition = AppComposition.make(database: database)
        let runtime = composition.runtime
        // B8.3b-2a：十六个 Live API 全部由组合根装配（禁止在这里 new 服务）。
        let appServices = AppServices.live(composition: composition)
        // 冷启动应用持久化界面语言：settings.ui_language 是唯一真相源；
        // 未设置时保持系统语言检测（不再「设置显示中文、界面是英文」）。
        // 4a-3a：写入口是 LanguageStore.seed（同步旧全局但不广播——启动阶段
        // 还没有订阅方，持久化也早已完成，不应触发一次假的「设置页切换」）。
        if let stored = await storedInterfaceLanguage(using: appServices.settings) {
            languageStore.seed(L10n.Language(rawLanguage: stored))
        }
        // B8.3b-1：注册 8 个 executor 并启动 JobService（start 在已启动时幂等、
        // shutdown 后失败可见）。start 之后还会在后台回放未完成的
        // delivery_intents（不阻塞 UI；失败写 runtime.deliveryReplayFailure）。
        // 复审 C5：start 内部会查库（recoverStale/resumeInterrupted）并注册 executor，
        // 放到 detached 执行；AppRuntime 是 @unchecked Sendable（内部 NSLock 保护生命周期）。
        // B0：刚完成跨进程恢复时不再回放 pending delivery（恢复前的语义已由 journal 承接）。
        let replayPendingDeliveries = !didRestore
        try await Task.detached(priority: .userInitiated) {
            try runtime.start(replayPendingDeliveries: replayPendingDeliveries)
        }.value
        // UI 对齐（§十一 11.9-1）：jobs:progress 事件总线接线。
        GatherEventCenter.shared.wire(jobEvents: runtime.jobService)
        await AppImport.prepareNativeEmbeddingRerun(
            composition: composition,
            settings: appServices.settings,
            databasePath: dbURL.path
        )

        // 3.2/3.3 页面 provider：全部域都走 AppServices 的 typed API；
        // provider 只做渲染形状适配，不再持有字符串命令面。
        let provider = LiveDashboardDataProvider(
            sessionAPI: appServices.session,
            jobAPI: appServices.job
        )
        let libraryProvider = LiveLibraryDataProvider(
            session: appServices.session,
            photo: appServices.photo,
            asset: appServices.asset,
            album: appServices.album,
            metadata: appServices.metadata
        )
        let galleryProvider = LiveGalleryDataProvider(
            photo: appServices.photo,
            session: appServices.session,
            settings: appServices.settings
        )

        // Capture One reload ack 走唯一 runtime（采集成功前不写持久标记）。
        let captureOneBridge = CaptureOneBridge(recordReloadAck: { sessionId in
            try runtime.recordReloadAck(sessionId: sessionId)
        })
        CaptureOneBridge.shared = captureOneBridge

        wire(
            delegate: delegate,
            composition: composition,
            sessionAPI: appServices.session,
            runtime: runtime,
            captureOneBridge: captureOneBridge,
            // Cut 4 / 4b-3：语言唯一来源随装配交给 Delegate（导入面板
            // 没有 environment，只能在动作发生时读同一个 store）。
            languageStore: languageStore
        )

        // Cut 4 / 4a-2a-1：壳层依赖包 + 工作区工厂（只装配引用，不 new 服务）。
        // 放在既有启动步骤之后，原有顺序逐行不变；rootDeps 的每个字段都来自
        // 上面的同一份组合根/AppServices/provider。SessionStore 只是登记表，
        // workspace 在首次 workspace(for:)/activate 时才由 SessionWorkspaceFactory
        // 构造（本步 RootView 尚未调用）。
        let rootDeps = RootShellDependencies(
            session: appServices.session,
            job: appServices.job,
            settings: appServices.settings,
            culling: appServices.culling,
            navigation: appServices.navigation,
            metadata: appServices.metadata,
            photo: appServices.photo,
            quality: appServices.quality,
            face: appServices.face,
            similarity: appServices.similarity,
            duplicate: appServices.duplicate,
            export: appServices.export,
            person: appServices.person,
            captureOne: captureOneBridge,
            libraryProvider: libraryProvider,
            galleryProvider: galleryProvider,
            dashboardProvider: provider,
            // Phase 4 收口：菜单/页面入口只经 typed 闭包调用宿主动作，
            // 不再有 commandCenter → Notification → Delegate 的第二跳。
            importFiles: { files in
                delegate?.onImportFiles?(files)
            },
            chooseImportFolder: {
                guard let delegate else { return .cancelled }
                return await delegate.chooseImportFolder()
            },
            captureOneImport: {
                guard let delegate else { return }
                await delegate.captureOneImport()
            }
        )
        let workspaceFactory = SessionWorkspaceFactory(deps: rootDeps)
        let sessionStore = SessionStore(make: workspaceFactory.makeWorkspace)

        return (
            // 4a-2c：删除 provider/libraryProvider/galleryProvider 三个未被场景
            // 消费的字段——它们已随 rootDeps 注入 workspace 工厂，SceneState 只
            // 保留 appServices / C1 桥 / 壳层依赖包 / workspace 表。
            SceneState(
                appServices: appServices,
                captureOneBridge: captureOneBridge,
                rootDeps: rootDeps,
                sessionStore: sessionStore,
                languageStore: languageStore,
                commandCenter: commandCenter,
                cancelPendingRestore: {
                    do {
                        try await composition.maintenanceService.cancelPendingRestore()
                        return true
                    } catch {
                        GatherLogger.log(
                            "cancel pending restore failed: \(error)", level: .warn)
                        return false
                    }
                }
            ),
            runtime,
            composition.maintenanceService
        )
    }

    /// Delegate 回调接线：菜单/C1/deep-link 与退出停机都落到同一
    /// composition/runtime。必须在发布 `scene` 之前完成（与拆分前顺序一致），
    /// 否则场景出现后再触发 C1 导入会误报 GATHER_BOOTSTRAPPING。
    private static func wire(
        delegate: GatherAppDelegate?,
        composition: AppComposition,
        sessionAPI: any SessionAPI,
        runtime: AppRuntime,
        captureOneBridge: CaptureOneBridge,
        languageStore: LanguageStore
    ) {
        guard let delegate else { return }
        // Cut 4 / 4b-3：界面语言源注入 Delegate（导入面板文案在动作发生时读它）；
        // 导入闭包同样在**动作发生时**取 store.l10n，不缓存字符串。
        delegate.languageStore = languageStore
        delegate.onImportFiles = { files in
            let l10n = languageStore.l10n
            Task {
                await AppImport.importFiles(
                    files,
                    sessionAPI: sessionAPI,
                    l10n: l10n
                )
            }
        }
        delegate.onCaptureOneImportFiles = { files in
            // 对齐旧版 App.tsx c1:plugin-import：C1 导入保留
            // capture-one 来源标记与「C1 导入 M/D H:mm」命名。
            let l10n = languageStore.l10n
            Task {
                await AppImport.importFiles(
                    files,
                    sessionAPI: sessionAPI,
                    source: "capture-one",
                    sourceLabel: l10n("Capture One 文件"),
                    l10n: l10n
                )
            }
        }
        delegate.onCaptureOneImport = {
            try await captureOneBridge.selectedPhotoPaths()
        }
    }

    // MARK: - 冷启动语言

    /// 读取持久化的界面语言（settings.ui_language 是唯一真相源）。
    /// 未设置 / 空串 / 读取失败都返回 nil = 保持系统语言检测（启动不能因为
    /// 设置读取失败而卡住）；调用方只负责把返回值经 LanguageStore.seed 应用到
    /// 唯一语言源（不再写 GatherLocalization 进程全局）。
    ///
    /// internal（非 private）：GatherAppTests（StartupLanguageTests）直接断言
    /// 启动路径经 SettingsAPI，而不是旧命令面的 settings.get /
    /// applyStoredInterfaceLanguage。
    package static func storedInterfaceLanguage(using settings: any SettingsAPI) async -> String? {
        do {
            let stored = try await settings.get(SettingsKey("ui_language"))
            return stored.isEmpty ? nil : stored
        } catch {
            return nil
        }
    }
}

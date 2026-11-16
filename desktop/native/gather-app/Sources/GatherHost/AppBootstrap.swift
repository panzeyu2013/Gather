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

    /// 旧库归档现场（`Database.open` 的 `.reset` outcome）：启动后用一次性提示告知
    /// 用户备份在哪、原版本是多少，避免「数据凭空消失」的误解。
    package struct ArchivedDatabase: Sendable, Equatable {
        package let backup: String
        package let previousVersion: Int?
    }

    /// 场景状态；nil = 未就绪（初始化中或失败）。
    package private(set) var scene: SceneState?
    /// 关闭一次性提示（目前只有「旧库已归档」）。
    package func dismissNotice() { noticeMessage = nil }

    /// 失败态文案（经 APIErrorPresentation 统一转换）；nil = 未失败。
    package private(set) var errorMessage: String?
    /// 一次性提示（非错误）：目前只有「旧库已归档并重建」。可关闭，不阻断使用。
    package private(set) var noticeMessage: String?

    /// 启动重入保护（不参与场景刷新）。
    @ObservationIgnored private var isStarting = false
    /// 唯一运行时（`shutdown()` 的停机入口；与 scene.appServices.runtime 同一实例）。
    @ObservationIgnored private var runtime: AppRuntime?
    /// P0 / B0：维护服务（自动备份调度器随启动/停机接线；与 scene 同一实例）。
    @ObservationIgnored private var maintenanceService: MaintenanceService?
    /// Wave4c / task-48：C1 判断 pending 重放器（扫描失败/超时后自动补落库）。
    @ObservationIgnored private var c1PendingReplay: C1PendingJudgementReplay?

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
        noticeMessage = nil
        defer { isStarting = false }
        do {
            let (state, runtime, maintenance, archived, c1PendingReplay) = try await Self.makeScene(
                delegate: delegate,
                applicationSupportDirectory: applicationSupportDirectory,
                // 4a-3a：语言唯一写入口由装配层持有，冷启动在这里播种。
                languageStore: languageStore,
                commandCenter: commandCenter
            )
            self.runtime = runtime
            self.maintenanceService = maintenance
            self.scene = state
            self.c1PendingReplay = c1PendingReplay
            // Wave4c / task-48：状态条"重试同步"按钮 → pending 重放器（同一 apply 口径）。
            C1PendingJudgementStore.shared.onRetry = { sessionId in
                await c1PendingReplay.retry(sessionId: sessionId)
            }
            if let archived {
                noticeMessage = languageStore.l10n.format(
                    "旧数据库已归档到 %@（原版本 %@），已重建空库。备份可随时移回。",
                    archived.backup,
                    archived.previousVersion.map(String.init) ?? "?")
            }
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
            // 装配失败时清掉预设桥，避免指向半初始化的 SettingsService。
            IngestPresetBridge.settings = nil
            GatherLogger.log("bootstrap failed: \(error)", level: .error)
            // 旧库/损坏库给可执行的归档指引；其余错误仍走统一漏斗。
            if let unrecoverable = error as? RestoreUnrecoverableError {
                self.errorMessage = languageStore.l10n.errorText(
                    GatherErrorCode.RESTORE_FAILED.rawValue
                ) + "：" + unrecoverable.failure.message
            } else if let dbError = error as? DatabaseError,
                      case .corrupt = dbError {
                self.errorMessage = languageStore.l10n(
                    "数据库版本不受支持或已损坏。请将 ~/Library/Application Support/Gather/gather.sqlite 及 -wal/-shm 移走备份后重试。")
            } else if let dbError = error as? DatabaseError,
                      case .versionUnsupported = dbError {
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
        // Wave4c / task-48：先停 pending 重放（避免停机后仍尝试写库），再清 UI 计数。
        await c1PendingReplay?.shutdown()
        c1PendingReplay = nil
        C1PendingJudgementStore.shared.onRetry = nil
        C1PendingJudgementStore.shared.reset()
        // Wave5 batch2：自动初审的 UI 桥与状态卡是进程内投影 —— 停机必须清空，
        // 否则静态闭包会指向已 shutdown 的 JobService，状态也会残留到下一次启动。
        AITriageUIBridge.onSessionCreated = nil
        AITriageStatusStore.shared.reset()
        // Wave5 batch3：预设桥同样不能指向已 shutdown 的 SettingsService。
        IngestPresetBridge.settings = nil
        SessionDirectoryMonitor.shared.stopAll()
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
    ) async throws -> (
        SceneState, AppRuntime, MaintenanceService, ArchivedDatabase?, C1PendingJudgementReplay
    ) {
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
        // P1：直方图/合焦/AF 的纯函数端口（页面只经 GatherUI 注册表读取）。
        PreviewAnalysisRegistry.install(PreviewAnalysisAdapter())
        // Wave3 / task-20：打印渲染端口（版面/PDF 在 GatherApplication，
        // GatherUI 只经 PrintRenderingRegistry 拿能力；重复注册按后者生效）。
        PrintRenderingRegistry.install(LivePrintRenderer())
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
                var openOptions = Database.Options.default
                // schema v1：旧库（v5 及更早）显式归档为 .incompatible-* 后重建，
                // 与 ADR-036「放弃兼容、单版本一次成型」一致；未来版本的库仍 fail closed。
                openOptions.resetPolicy = .renameOlderOnly
                return try Database.open(at: dbURL.path, options: openOptions)
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
        // 旧库被归档重建时记下现场，启动完成后给一次性提示；
        // 否则用户升级首启动只会看到「会话/照片/评分全空」而以为数据丢了。
        var archivedDatabase: ArchivedDatabase?
        if case .reset(_, let previousVersion, let backup) = database.outcome {
            archivedDatabase = ArchivedDatabase(backup: backup, previousVersion: previousVersion)
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
        db.settingsReader = ClosureSettingsReader { [weak db] key in
            guard let db else { return nil }
            return (try? SettingsRepo(connection: db).get(key: key.rawValue))?.value
        }

        // Cut 1 / B8.3b-2a/B8.3b-2b：组合根只构造一次（24 个服务/Repo +
        // 唯一 AppRuntime）。宿主、AppServices、页面 provider、Capture One
        // 桥与导入路径全部从同一个 composition 取实例。
        let composition = AppComposition.make(database: database)
        let runtime = composition.runtime
        // B8.3b-2a：十六个 Live API 全部由组合根装配（禁止在这里 new 服务）。
        let appServices = AppServices.live(composition: composition)
        // Wave5 batch3（task-19）：摄取面板的预设持久化接缝（GatherUI 不能 import
        // GatherHost，也不该为一个面板改 CullingViewModel 的 30+ 测试构造点）。
        IngestPresetBridge.settings = appServices.settings
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
        // start 返回本次恢复的 job 类型列表，这里不需要（恢复结果由 runtime 内部落库）。
        _ = try await Task.detached(priority: .userInitiated) {
            try runtime.start(replayPendingDeliveries: replayPendingDeliveries)
        }.value
        // P1：后台维护（元数据备份 GC + 关键词回填），不阻塞启动。
        scheduleBackgroundMaintenance(composition: composition)
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

        // P2（Wave4b）：自动 reload 前先 select「本次写盘」的照片，否则 C1 选中项通常
        // 不在这些照片上 → reload 必然 .noSelection 并被失败抑制（回路断点）。路径来自
        // delivery 行（status=written）→ DeliveryRepo.photoPath；读取失败/未接线时返回
        // 空数组，bridge 退回旧行为（直接 reload）。
        let writtenPhotoPaths: (String) throws -> [String] = { sessionId in
            let lifecycle = MetadataLifecycleRepo(connection: runtime.db)
            let deliveries = DeliveryRepo(connection: runtime.db)
            var paths: [String] = []
            var seen = Set<String>()
            for row in try lifecycle.projections(sessionId: sessionId)
            where row.status == DeliveryStatus.written.rawValue {
                guard let delivery = try deliveries.get(row.xmpPath),
                      !delivery.photoPath.isEmpty else { continue }
                if seen.insert(delivery.photoPath).inserted {
                    paths.append(delivery.photoPath)
                }
            }
            return paths
        }
        // Capture One reload ack 走唯一 runtime（采集成功前不写持久标记）。
        let captureOneBridge = CaptureOneBridge(
            recordReloadAck: { sessionId in
                try runtime.recordReloadAck(sessionId: sessionId)
            },
            writtenPhotoPaths: writtenPhotoPaths)
        CaptureOneBridge.shared = captureOneBridge
        // P1：自动 reload 协调器（手动/自动共用串行队列；C1 未运行时 preflight 会跳过）。
        // P1-10：再注入"本机是否装了 C1"（与组合根门禁同一份 C1Installation 判定）。
        // 事件源（CullingViewModel.refreshSyncStatus）在每轮 writeback 收敛后都会通知，
        // 没装 C1 的用户原本会一路走到 bridge.preflight()（spawn osascript 做
        // System Events 探测）→ 非预期的自动化授权弹窗。有了这道短路，
        // c1_auto_reload 保持默认 "1" 也不会对没装 C1 的机器发起任何子进程。
        let c1RoundTrip = C1RoundTripCoordinator(
            bridge: captureOneBridge,
            syncStatus: { try await appServices.culling.syncStatus($0) },
            isC1Installed: { C1Installation.isInstalled() },
            settings: {
                C1AutoReloadSettings(
                    enabled: composition.settingsService.bool(.c1AutoReload))
            },
            extras: C1RoundTripExtras(
                select: { try await captureOneBridge.selectVariants(paths: $0) },
                hints: { captureOneBridge.adjustmentHints(paths: $0) }))
        // Wave3：UI 侧门面 = 协调器（reload/选中）+ 具体桥（变体级写回）。
        // rootDeps.captureOne 换成门面后，UI 的 as? C1RoundTripReloading/Extending
        // 仍成立（门面同时实现两个端口），写回走具体桥。
        let c1BridgeFacade = CaptureOneBridgeFacade(
            coordinator: c1RoundTrip, bridge: captureOneBridge)

        // Wave5 batch2（E1/E2）：自动初审的统一调度器 —— 五个导入入口共用同一份
        // 依赖与开关语义（此前只有菜单/Finder 与 C1 文件导入接了 afterCreate）。
        // 人脸前置只做"是否有观测"的轻量查询（face_observations 有行），
        // 缺观测时入队一次 face.analyze 但不等它（不阻塞本次建议生成）。
        let triageDatabase = composition.db
        let photoRepo = composition.photoRepo
        let triageFaceAPI = appServices.face
        // Wave5 batch6（E3）：初审前分组产物（duplicate.scan + navigation.analyze）。
        // duplicate.scan 走 JobService 现有 job 类型；navigation.analyze 无 job 类型，
        // 直接调现有 NavigationAPI（不新增 job 类型/schema）。
        // 只捕获 Sendable 服务句柄（不把整个组合根拖进 @Sendable 闭包）。
        let triageJobService = composition.jobService
        let triageNavigationAPI = appServices.navigation
        let triageGroupArtifacts = AITriageGroupArtifactsCoordinator(
            deps: AITriageGroupArtifactsCoordinator.Dependencies(
                listJobs: { try triageJobService.list(status: nil, includeCheckpoint: false) },
                enqueueDuplicateScan: { sessionId in
                    // dedupeKey 带批次 nonce：终态同 key 默认 inheritCheckpoint，
                    // 会把上一批 photoIds 合并进来（与 quality dedupeKey 同一理由）。
                    try triageJobService.create(JobCreateParams(
                        type: .duplicateScan,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "duplicate.scan:\(sessionId):default:auto-import-triage:"
                            + UUID().uuidString,
                        checkpoint: ["visualThreshold": .null]))
                },
                waitDuplicateScan: { jobId, timeoutMs in
                    // 有界等待：60s 到点只停止等待、不取消 job（job 可后台跑完）。
                    let _: DuplicateScanResult? = try await triageJobService
                        .waitForResult(jobId: jobId, timeoutMs: timeoutMs)
                },
                hasNavigationGroups: { sessionId in
                    // 已有组不重算（任务边界：只补缺失的组，不动已有结果）。
                    let groups = try NavigationRepo(connection: triageDatabase)
                        .listGroups(sessionId: sessionId)
                    return !groups.isEmpty
                },
                analyzeNavigation: { sessionId in
                    _ = try await triageNavigationAPI.analyze(
                        NavigationAnalyzeParams(sessionId: sessionId))
                },
                now: { Date() },
                log: { message in
                    GatherLogger.log(message, level: .info)
                }))
        let autoTriageScheduler = AITriageAutoScheduler(
            jobService: composition.jobService,
            database: triageDatabase,
            settings: composition.settingsService,
            hasFaceObservations: { sessionId in
                let photoIds = try photoRepo.getBySessionProjection(sessionId: sessionId)
                    .filter { $0.status != "missing" }
                    .map(\.id)
                guard !photoIds.isEmpty else { return false }
                let faceRepo = FaceRepo(connection: triageDatabase)
                let boxes = try faceRepo.faceBoxes(sessionId: sessionId, photoIds: photoIds)
                return !boxes.isEmpty
            },
            enqueueFaceAnalysis: { sessionId in
                Task.detached(priority: .utility) {
                    do {
                        let input = try FaceAnalyzeInput(sessionId: sessionId)
                        _ = try await triageFaceAPI.analyze(input)
                    } catch {
                        GatherLogger.log(
                            "ai.auto-triage face.analyze enqueue failed: \(error)",
                            level: .warn)
                    }
                }
            },
            ensureGroupArtifacts: { sessionId in
                await triageGroupArtifacts.run(sessionId: sessionId)
            })
        // Wave5 batch3（E1 的第七个入口）：摄取面板走 SessionAPI.ingest，
        // 宿主把 UI 依赖里的 session 包一层：job 终态成功后调度自动初审
        // （与其它六个导入入口同语义；失败/取消照原样抛出，不影响摄取）。
        let sessionAPIForUI = TriageSchedulingSessionAPI(
            base: appServices.session,
            onIngestSucceeded: { sessionId in
                Task { @MainActor in
                    autoTriageScheduler.schedule(sessionId: sessionId)
                }
            })
        // Wave3 / task-21：Shortcuts / App Intents 运行时（只包既有 typed API；
        // scene 发布前安装，未完成启动时 intents 显式报 runtimeUnavailable）。
        let automationRuntime = GatherAutomationRuntime(
            createWorkspaceAndImport: { name, filepaths in
                let normalized = normalizeImportFilepaths(filepaths)
                guard !normalized.isEmpty else { throw GatherAutomationError.noFiles }
                let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = trimmed.isEmpty ? Self.automationImportName() : trimmed
                let input = try SessionCreateInput(
                    name: resolved, source: "shortcuts", filepaths: normalized)
                let created = try await appServices.session.create(input)
                // Wave5 batch2：Shortcuts 建库也是导入入口（此前只有 AppImport 菜单路径）。
                Task { @MainActor in
                    autoTriageScheduler.schedule(sessionId: created.session.id)
                }
                return created.session.id
            },
            exportSession: { sessionId, destination, formatRaw, quality, maxDimension in
                guard let format = ExportFormat(rawValue: formatRaw) else {
                    throw GatherAutomationError.unsupportedFormat(formatRaw)
                }
                let options = ExportOptions(
                    scope: .session,
                    variantPolicy: .preferred,
                    format: format,
                    quality: quality,
                    maxDimension: maxDimension,
                    naming: ExportNaming(pattern: "{orig}"),
                    includeXmp: false,
                    destination: destination)
                let input = try ExportInput(sessionId: sessionId, options: options)
                return try await appServices.export.execute(
                    Confirmed(input, source: .automation))
            },
            writebackMetadata: { sessionId, targetRaw in
                guard let target = CullingWritebackTarget(rawValue: targetRaw) else {
                    throw GatherAutomationError.unsupportedTarget(targetRaw)
                }
                let input = try CullingWritebackInput(sessionId: sessionId, target: target)
                let result = try await appServices.culling.writeback(
                    Confirmed(input, source: .automation))
                return GatherAutomationWritebackSummary(
                    sessionId: sessionId, target: targetRaw,
                    written: result.written, failed: result.failed, skipped: result.skipped)
            },
            sessionStatus: { sessionId in
                let session = try await appServices.session.get(sessionId)
                let sync = try await appServices.culling.syncStatus(sessionId)
                return GatherAutomationSessionStatus(
                    sessionId: session.id, name: session.name, photoCount: session.photoCount,
                    pendingXmp: sync.summary.pending, writtenXmp: sync.summary.written,
                    failedXmp: sync.summary.failed, conflictXmp: sync.summary.conflict,
                    reloadAckedAt: sync.reloadAckedAt)
            },
            // Wave5 batch5：查询照片（只读）。走既有检索（PhotoAPI.search），
            // 过滤条件由 GatherAutomationPhotoQuery.criteria 映射到 FilterEngine，
            // 不新造查询语言。
            queryPhotos: { query in
                // 会话必须存在：检索 API 对未知 session 返回 0 张，脚本会误以为
                // "这个工作区是空的"而不是"工作区 ID 写错了"。
                _ = try await appServices.session.get(query.sessionId)
                let result = try await appServices.photo.search(
                    try PhotoQuery(
                        criteria: query.criteria,
                        sessionId: query.sessionId,
                        limit: query.limit))
                return GatherAutomationPhotoQueryResult(
                    sessionId: query.sessionId,
                    photoIds: result.photos.map(\.photoId),
                    total: result.total,
                    samples: result.photos.map {
                        GatherAutomationPhotoSample(photoId: $0.photoId, filename: $0.filename)
                    })
            },
            // Wave5 batch5：写判断（rating / 色标 / pick）。与 gather://rate 共用
            // 同一个实现（applyAutomationDecisions），避免两条入口语义分叉。
            applyDecisions: { sessionId, photoIds, patch in
                try await Self.applyAutomationDecisions(
                    culling: appServices.culling,
                    sessionId: sessionId, photoIds: photoIds, patch: patch)
            })
        GatherAutomationRuntimeRegistry.current = automationRuntime

        let c1PendingReplay = wire(
            delegate: delegate,
            composition: composition,
            sessionAPI: appServices.session,
            jobAPI: appServices.job,
            runtime: runtime,
            captureOneBridge: c1RoundTrip,
            // Wave5 batch2：五个导入入口共享的自动初审调度器。
            autoTriageScheduler: autoTriageScheduler,
            // Wave2 / G3：判断数据要读具体桥（C1SelectionSnapshot 只在 CaptureOneBridge
            // 上；协议面只管 UI 既有能力，不把导入专用读取扩进 CaptureOneBridging）。
            captureOneJudgements: { try await captureOneBridge.selectedVariantSnapshot() },
            // Wave3 / task-21：gather://photo/<id> 的 session 归属（只读查询）。
            // 只捕获 Sendable 的 PhotoRepo，不把整个组合根拖进 @Sendable 闭包。
            resolvePhotoSession: { photoId in
                do { return try photoRepo.getLookupByIds([photoId]).first?.sessionId } catch {
                    return nil
                }
            },
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
            // Wave5 batch3：UI 侧 session 用装饰器（摄取成功后调度 AI 初审）。
            session: sessionAPIForUI,
            job: appServices.job,
            settings: appServices.settings,
            culling: appServices.culling,
            navigation: appServices.navigation,
            metadata: appServices.metadata,
            photo: appServices.photo,
            album: appServices.album,
            quality: appServices.quality,
            face: appServices.face,
            similarity: appServices.similarity,
            duplicate: appServices.duplicate,
            export: appServices.export,
            person: appServices.person,
            captureOne: c1BridgeFacade,
            // Wave3（task-24）：维护域（目录包导出/导入 + 外部 XMP 迁移）入口装配。
            maintenance: appServices.maintenance,
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
                let selection = await delegate.chooseImportFolder()
                // Wave3 / G6：C1 Session 根目录 → 只扫 Capture（Trash 不复活、Selects 不重复扫）。
                return C1SessionDirectoryImport.redirect(selection)
            },
            captureOneImport: {
                guard let delegate else { return }
                await delegate.captureOneImport()
            }
        )
        let workspaceFactory = SessionWorkspaceFactory(deps: rootDeps)
        let sessionStore = SessionStore(make: workspaceFactory.makeWorkspace)
        // P1 / D：LRU 淘汰/删除会话时停掉该会话的 FSEvents 监听，避免关闭后仍建扫描 job。
        sessionStore.onWorkspaceClosed = { sessionId in
            SessionDirectoryMonitor.shared.stop(sessionId: sessionId)
        }

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
            composition.maintenanceService,
            archivedDatabase,
            c1PendingReplay
        )
    }

    /// Delegate 回调接线：菜单/C1/deep-link 与退出停机都落到同一
    /// composition/runtime。必须在发布 `scene` 之前完成（与拆分前顺序一致），
    /// 否则场景出现后再触发 C1 导入会误报 GATHER_BOOTSTRAPPING。
    /// P1：元数据保留期 GC（启动 30s 后一次 + 24h 周期）与关键词索引回填（断点续跑）。
    private static func scheduleBackgroundMaintenance(composition: AppComposition) {
        let db = composition.db
        let coordinator = composition.deliveryCoordinator
        let settings = composition.settingsService
        Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            let retention = MetadataRetentionService(
                lifecycle: MetadataLifecycleRepo(connection: db), coordinator: coordinator)
            while !Task.isCancelled {
                let policy = MetadataRetentionPolicy.fromSettings(settings)
                _ = await retention.run(policy: policy)
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
            }
        }
        Task.detached(priority: .utility) {
            let sync = KeywordIndexSync(
                index: KeywordRepo(connection: db),
                metadata: MetadataCacheRepo(connection: db))
            var cursor: String?
            while !Task.isCancelled {
                let step: KeywordBackfillStep
                do { step = try sync.backfillStep(after: cursor, batchSize: 5_000) }
                catch { break }
                guard !step.isDone else { break }
                cursor = step.nextCursor
                await Task.yield()
            }
        }
    }

    private static func wire(
        delegate: GatherAppDelegate?,
        composition: AppComposition,
        sessionAPI: any SessionAPI,
        jobAPI: any JobAPI,
        runtime: AppRuntime,
        captureOneBridge: any CaptureOneBridging,
        autoTriageScheduler: AITriageAutoScheduler,
        captureOneJudgements: @escaping @Sendable () async throws -> C1SelectionSnapshot,
        resolvePhotoSession: @escaping @Sendable (String) -> String?,
        languageStore: LanguageStore
    ) -> C1PendingJudgementReplay {
        // Wave4c / task-48（A2 半修）：扫描非 succeeded 时登记 pending，下一次成功/手动
        // 重试时自动重放；计数经 onStateChange 广播给 UI 状态条（GatherUI/Metadata）。
        // 只捕获 Sendable 的 DBConnection（不把整个组合根拖进 @Sendable 闭包）。
        let replayDatabase = composition.db
        let c1PendingReplay = C1PendingJudgementReplay(
            apply: { sessionId, judgements in
                let service = C1JudgementImport.makeService(database: replayDatabase)
                return await service.applyAfterIndexing(
                    sessionId: sessionId,
                    judgements: judgements,
                    scanStatus: C1JudgementImport.scanStatusProvider(
                        database: replayDatabase),
                    // 重试路径的等待上限压到 60s：状态条"重试同步"不应被一次长扫描
                    // 卡住 10 分钟；仍未成功就保留 pending 等下一次。
                    timeout: .seconds(60))
            },
            onStateChange: { sessionId, count in
                Task { @MainActor in
                    C1PendingJudgementStore.shared.setCount(
                        sessionId: sessionId, count: count)
                }
            })
        guard let delegate else { return c1PendingReplay }
        // Cut 4 / 4b-3：界面语言源注入 Delegate（导入面板文案在动作发生时读它）；
        // 导入闭包同样在**动作发生时**取 store.l10n，不缓存字符串。
        delegate.languageStore = languageStore
        // Wave3 / task-21：gather:// 深链路由（session/photo/import-into-session）。
        // 事件名与 userInfo 键在 GatherUI/GatherAppNotification 单源定义。
        delegate.onImportFilesIntoSession = { files, sessionId in
            let l10n = languageStore.l10n
            Task {
                await AppImport.importFiles(
                    files, into: sessionId,
                    sessionAPI: sessionAPI, jobAPI: jobAPI,
                    source: "shortcuts", sourceLabel: "Shortcut", l10n: l10n,
                    afterAdd: { addedSessionId in
                        // Wave5 batch2：加照片到已有工作区也触发自动初审
                        //（此前只有"新建工作区"的导入入口接了这个钩子）。
                        autoTriageScheduler.schedule(sessionId: addedSessionId)
                    })
            }
        }
        // Wave5 batch2（E1）：Dashboard「新建工作区」→ 自动初审。
        // UI 侧只发 sessionId（GatherUI 不能 import GatherHost），宿主在此注入处理；
        // 停机时清空，避免静态闭包指向已 shutdown 的 JobService。
        AITriageUIBridge.onSessionCreated = { sessionId in
            autoTriageScheduler.schedule(sessionId: sessionId)
        }
        delegate.onOpenSession = { sessionId in
            NotificationCenter.default.post(
                name: GatherAppNotification.deepLinkSession, object: sessionId)
        }
        delegate.onOpenPhoto = { sessionId, photoId in
            NotificationCenter.default.post(
                name: GatherAppNotification.deepLinkPhoto, object: nil,
                userInfo: [
                    GatherAppDeepLinkUserInfoKey.sessionId: sessionId,
                    GatherAppDeepLinkUserInfoKey.photoId: photoId,
                ])
        }
        delegate.onResolvePhotoSession = resolvePhotoSession
        delegate.onDeepLinkError = { error in
            GatherLogger.log("deep link rejected: \(error.description)", level: .warn)
        }
        // Wave5 batch5：gather://rate —— 无 UI 直接写评级/色标/保留。
        //
        // 走注册表里的**同一个** runtime（与 Shortcuts/App Intents 完全同一条实现），
        // 不另开一条写入路径；runtime 未安装时按既有语义报 runtimeUnavailable。
        //
        // 为什么必须给可见错误：URL scheme 没有调用栈可以把错误还给脚本；失败若只写日志，
        // 用户/Siri 看到的是"什么都没发生"。用错误 toast + 日志兜底（成功也给一条计数 toast，
        // 让"写了多少张"可见）。
        delegate.onApplyDecisions = { sessionId, photoIds, patch in
            let l10n = languageStore.l10n
            Task { @MainActor in
                do {
                    guard let runtime = GatherAutomationRuntimeRegistry.current else {
                        throw GatherAutomationError.runtimeUnavailable
                    }
                    let summary = try await runtime.applyDecisions(
                        sessionId, photoIds, patch)
                    GatherToastCenter.shared.show(
                        type: .success,
                        message: l10n.format(
                            "已更新 %lld 张照片的评级/标记", summary.written))
                } catch {
                    GatherLogger.log(
                        "deeplink.rate failed session=\(sessionId) photos=\(photoIds.count): \(error)",
                        level: .error)
                    // 自动化面错误自己带可读原因（参数非法/runtime 未就绪）：直接展示，
                    // 不要经 errorText 码表漏斗——它只认错误码，会把原因换成通用文案。
                    let reason: String
                    if let automation = error as? GatherAutomationError {
                        reason = automation.errorDescription ?? String(describing: automation)
                    } else {
                        reason = APIErrorPresentation.message(for: error, with: l10n)
                    }
                    GatherToastCenter.shared.show(
                        type: .error,
                        message: l10n.format("写评级/标记失败：%@", reason))
                }
            }
        }
        // Wave2 / task-14：导入完成后的自动初审接线（quality.score → triage.generate）。
        // Wave5 batch2：依赖收进 AITriageAutoScheduler（六个入口共用同一份开关/人脸
        // 前置语义），不再在这里逐个拼 JobService/DB/Settings。
        delegate.onImportFiles = { files in
            let l10n = languageStore.l10n
            Task {
                await AppImport.importFiles(
                    files,
                    sessionAPI: sessionAPI,
                    l10n: l10n,
                    afterCreate: { result in
                        // 钩子只调度、不等待：导入返回速度不变，失败不影响导入结果。
                        autoTriageScheduler.schedule(sessionId: result.session.id)
                    }
                )
            }
        }
        // Wave2 / G3：C1 判断数据的待应用队列（导入成功后按路径集合取回）。
        // 为什么按路径集合做 key 而不是单个 pending：两次 C1 导入可能在 await 之间
        // 交错（各自独立 Task），只存一份会把 A 的判断应用到 B 的新会话；
        // 两个回调都在 MainActor 上执行，同文件集共用同一份快照（内容一致、幂等）。
        let pendingJudgements = C1PendingJudgements()

        delegate.onCaptureOneImportFiles = { files in
            // 对齐旧版 App.tsx c1:plugin-import：C1 导入保留
            // capture-one 来源标记与「C1 导入 M/D H:mm」命名。
            let l10n = languageStore.l10n
            // 快照在这里同步取回：AppImport 的 onCaptureOneImport 一定先于本回调执行。
            let judgements = pendingJudgements.take(paths: files)
            let database = composition.db
            Task {
                await AppImport.importFiles(
                    files,
                    sessionAPI: sessionAPI,
                    source: "capture-one",
                    sourceLabel: l10n("Capture One 文件"),
                    l10n: l10n,
                    afterCreate: { result in
                        // Wave2 / task-14：C1 导入同样接自动初审（与菜单导入同一语义）。
                        autoTriageScheduler.schedule(sessionId: result.session.id)
                        // 钩子必须立即返回：真正落库在后台 Task 里（要先等 metadata.scan
                        // 终态，否则扫描把 photo_metadata_cache 的 rating/关键词覆盖回 XMP 值）。
                        guard !judgements.isEmpty else { return }
                        C1JudgementImport.scheduleApply(
                            database: database,
                            sessionId: result.session.id,
                            judgements: judgements,
                            onSkipped: { report in
                                // Wave4c：扫描失败/超时/取消不再是"静默跳过"——登记 pending，
                                // 状态条可见且可重试；自动重试由 replay 的后台 watcher 负责。
                                let reason = report.skippedReason ?? "unknown"
                                Task {
                                    await c1PendingReplay.register(
                                        sessionId: result.session.id,
                                        judgements: judgements,
                                        skippedReason: reason)
                                }
                            })
                    }
                )
            }
        }
        delegate.onCaptureOneImport = {
            do {
                let snapshot = try await captureOneJudgements()
                // P2（Wave4b）：畸形行不再静默丢弃（契约漂移要能在日志里看见）。
                if snapshot.malformedLines > 0 {
                    GatherLogger.log(
                        "c1.judgements parse malformedLines=\(snapshot.malformedLines)"
                            + " paths=\(snapshot.paths.count)（可能 C1 字典/脚本契约变化）",
                        level: .warn)
                }
                pendingJudgements.store(snapshot.paths, judgements: snapshot.judgements)
                return snapshot.paths
            } catch {
                // G3 降级：判断数据是可选增强，绝不能让"读不到判断"变成"导入失败"。
                // 退回旧行为（只按文件导入），并用独立错误码提示未能读取判断数据。
                do {
                    let paths = try await captureOneBridge.selectedPhotoPaths()
                    NotificationCenter.default.post(
                        name: GatherAppNotification.captureOneError,
                        object: GatherErrorCode.C1_JUDGEMENTS_UNAVAILABLE.rawValue)
                    return paths
                } catch {
                    throw error
                }
            }
        }
        return c1PendingReplay
    }

    // MARK: - 冷启动语言

    /// Wave3 / task-21：Shortcuts 未命名导入的默认工作区名（写入 sessions.name）。
    ///
    /// nonisolated：App Intents 的 @Sendable 闭包在非 MainActor 上下文调用它；
    /// 只用 DateFormatter 与 Date，无共享状态。
    nonisolated private static func automationImportName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Shortcuts 导入 " + formatter.string(from: Date())
    }

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
            let stored = try await settings.get(SettingsKeyInput("ui_language"))
            return stored.isEmpty ? nil : stored
        } catch {
            return nil
        }
    }
}

// MARK: - C1 判断数据导入（Wave2 / G3）

/// C1 判断快照的待应用队列：按「归一化路径集合」暂存，等 onCaptureOneImportFiles 取回。
///
/// key 用路径集合而不是 sessionId：读快照时还没有 session（新建工作区），而两次 C1
/// 导入可能在 await 之间交错（各自独立 Task）；按文件集关联，A 的判断不会被应用到 B 的
/// 新会话。两个回调都在 MainActor 上执行，因此不需要锁；同文件集的并发导入共用同一份
/// 快照（内容一致、幂等）。
@MainActor
final class C1PendingJudgements {
    private var byPathSet: [String: [C1VariantJudgement]] = [:]

    func store(_ paths: [String], judgements: [C1VariantJudgement]) {
        // 上限防御：用户连续取消/失败导入时不留无限增长的残留（超过 8 批直接清空，
        // 代价只是丢掉还没被消费的旧判断——导入仍会正常进行）。
        if byPathSet.count >= 8 { byPathSet.removeAll() }
        byPathSet[Self.key(paths: paths)] = judgements
    }

    func take(paths: [String]) -> [C1VariantJudgement] {
        byPathSet.removeValue(forKey: Self.key(paths: paths)) ?? []
    }

    static func key(paths: [String]) -> String {
        paths.map(ScanPath.canonical).sorted().joined(separator: "\u{1F}")
    }
}

/// C1 判断的落库调度：导入钩子里只调度、不等待（导入返回速度不变）。
enum C1JudgementImport {
    /// 后台等本会话 metadata.scan 终态，再把 C1 rating/色标/pick/关键词写进新会话。
    ///
    /// 为什么不能立即写：metadata.scan 的 MetadataExtractionService 用整行 upsert 覆盖
    /// photo_metadata_cache（XMP 无 rating 时写回 0 / 空关键词），先写的判断会被清掉。
    /// 等待有上限（服务内默认 10 分钟）；仅扫描成功才落库（A2），否则跳过并在日志/report
    /// 记 skippedReason（失败/取消/超时写入会被后续成功扫描的整行 upsert 清掉）。
    /// 与 C1PendingJudgementReplay 共用同一 apply/scan-status 口径。
    static func makeService(database: DBConnection) -> C1ImportJudgementService {
        let cache = MetadataCacheRepo(connection: database)
        return C1ImportJudgementService(
            photos: PhotoRepo(connection: database),
            cache: cache,
            decisions: CullingDecisionRepo(connection: database),
            keywordIndex: KeywordIndexSync(
                index: KeywordRepo(connection: database),
                metadata: cache),
            transactions: database)
    }

    /// metadata.scan 状态读取（等待/重放共用；见 C1ScanJobSelection 的稳定排序）。
    static func scanStatusProvider(
        database: DBConnection
    ) -> @Sendable (String) throws -> String? {
        { id in
            // P2（Wave4b）：latestScanJob 只按 updated_at DESC，同毫秒并列时顺序不定。
            // 轮询阶段先看活跃扫描（廉价、与排序无关）；没有活跃扫描时才做一次
            // (updatedAt, id) 全序选择，避免等错 job 的终态。
            let repo = AnalysisJobRepo(connection: database)
            if try !repo.activeJobIDs(type: .metadataScan, scopeId: id).isEmpty {
                return AnalysisJobStatus.running.rawValue
            }
            let jobs = try repo.list(includeCheckpoint: false)
            return C1ScanJobSelection.latestScanStatus(jobs: jobs, sessionId: id)
        }
    }

    /// 调度落库；`onSkipped` 在扫描非 succeeded 时回调（Wave4c：登记 pending 重放）。
    static func scheduleApply(
        database: DBConnection,
        sessionId: String,
        judgements: [C1VariantJudgement],
        onSkipped: (@MainActor @Sendable (C1ImportJudgementReport) -> Void)? = nil
    ) {
        Task.detached(priority: .utility) {
            let service = Self.makeService(database: database)
            let report = await service.applyAfterIndexing(
                sessionId: sessionId,
                judgements: judgements,
                scanStatus: Self.scanStatusProvider(database: database))
            GatherLogger.log(
                "c1.judgements session=\(sessionId) applied=\(report.applied)"
                    + " missing=\(report.missing) ratings=\(report.ratings)"
                    + " labels=\(report.labels) keeps=\(report.keeps)"
                    + " keywords=\(report.keywords)"
                    + " manualPreserved=\(report.preservedManualDecisions)"
                    + " waited=\(report.waitedForIndexing) timedOut=\(report.indexingTimedOut)"
                    + " skippedReason=\(report.skippedReason ?? "-")"
                    + " errors=\(report.errors.count)",
                level: report.errors.isEmpty && report.skippedReason == nil ? .info : .warn)
            if report.skippedReason != nil, let onSkipped {
                await MainActor.run { onSkipped(report) }
            }
            guard report.applied > 0 else { return }
            await MainActor.run {
                // 广播挑片域变更：已挂载的挑片页/图库据此重拉星级、色标与决策。
                GatherEventCenter.postDomainChange(
                    .culling, sessionId: sessionId, origin: "c1-import-judgements")
            }
        }
    }
}

// MARK: - Wave2 / task-14：导入后自动初审

/// Wave4a / task-39（E4）：把 triage 的 generate/apply 移出 MainActor。
///
/// TriageService 不是 Sendable，且持有 gate 缓存/串行锁；由本 actor **自己**用
/// Sendable 句柄（DBConnection + SettingsService）构造同口径实例，pipeline 只通过
/// actor 方法访问 → 生成/应用在 actor 执行器上跑，不占主线程，也不新增逃逸口注解。
///
/// 注意：这是与组合根不同的第二个实例（只服务导入后自动初审）；gate 缓存 TTL 2s 独立，
/// 影响仅限于"刚生成完页面可能短暂拿旧门控"，随页面重载收敛。
actor AITriageBackgroundWorker {
    private let database: DBConnection
    private let settings: SettingsService
    private var service: TriageService?

    init(database: DBConnection, settings: SettingsService) {
        self.database = database
        self.settings = settings
    }

    private func resolvedService() -> TriageService {
        if let service { return service }
        // 与 CompositionCore 的构造保持同一口径（TriagePolicy.fromSettings + triage_enabled）。
        let created = TriageService(
            repository: TriageRepo(connection: database),
            decisions: CullingDecisionRepo(connection: database),
            history: CullingHistoryRepo(connection: database),
            transactions: database,
            policyProvider: { [settings] in TriagePolicy.fromSettings(settings) },
            enabledProvider: { [settings] in settings.bool(.triageEnabled) },
            feedback: TriageFeedbackRepo(connection: database))
        service = created
        return created
    }

    func generate(sessionId: String) throws -> TriageSummary {
        try resolvedService().generate(sessionId: sessionId)
    }

    func apply(_ input: TriageApplyInput) throws -> TriageApplyResult {
        try resolvedService().apply(Confirmed(input, source: .automation))
    }
}

/// E2 判定结果（Wave5 batch2）：人脸观测是否存在。
enum AITriageFacePrerequisite: Equatable {
    /// 已有人脸观测：闭眼/微笑/人脸合焦/小脸保护都能用。
    case present
    /// 没有观测：本次入队 face.analyze，但**不等待**（先按无脸信号生成建议）。
    case missing
    /// 查询失败：按"有观测"处理，绝不因为前置检查失败阻塞初审。
    case queryFailed
}

/// E2 动作计划：状态卡相位 + 是否入队 face.analyze。
///
/// "不阻塞"是结构性的：入队只发起后台任务，pipeline 立刻继续生成建议（本次按
/// 无脸信号），不会等待 face.analyze 的结果；状态卡保留「待人脸分析」直到本轮结束。
struct AITriageFacePlan: Equatable {
    let phase: AITriageStatusStore.Phase
    let enqueueFaceAnalysis: Bool

    static func make(from state: AITriageFacePrerequisite) -> AITriageFacePlan {
        switch state {
        case .present:
            return AITriageFacePlan(phase: .generating, enqueueFaceAnalysis: false)
        case .missing:
            return AITriageFacePlan(phase: .waitingFace, enqueueFaceAnalysis: true)
        case .queryFailed:
            return AITriageFacePlan(phase: .generating, enqueueFaceAnalysis: false)
        }
    }
}

/// Wave5 batch6（E3）：导入后自动初审前的分组产物准备。
///
/// 为什么需要：triage 的理由码要比较相似/重复/场景组，而三类分组分析一直是手动按钮
/// （50-ai-similarity §3-D）；导入即初审后若没有任何组，建议只能出硬技术失败。
///
/// 边界（与任务一致）：
/// - 复用现有 job 类型 duplicate.scan（JobService）与现有 navigation.analyze（NavigationAPI；
///   该命令没有 job 类型，不新增 job 类型）；
/// - 已有近期成功结果/已有组则跳过，不重算、不重复入队；
/// - 有界等待（默认 60s：poll 预算的一小段），超时只停止等待、**不取消** job；
/// - 任一步失败只记录原因并继续（初审不能被分组拖停）；不自动应用分组建议。
struct AITriageGroupArtifactsCoordinator: Sendable {
    /// duplicate.scan 的决策（纯判定，测试直接驱动）。
    enum DuplicatePlan: Equatable, Sendable {
        /// 近期成功：直接跳过，不重复入队。
        case recentSuccess
        /// 会话已有活跃 job：复用它并做有界等待（不重复入队）。
        case waitActive(String)
        /// 无结果/无活跃：入队并做有界等待。
        case enqueue
    }

    struct Dependencies: Sendable {
        var listJobs: @Sendable () throws -> [AnalysisJobData]
        var enqueueDuplicateScan: @Sendable (String) throws -> AnalysisJobData
        /// 有界等待：超时抛错但**不取消** job（与 quality 等待同一语义）。
        var waitDuplicateScan: @Sendable (String, Int64) async throws -> Void
        var hasNavigationGroups: @Sendable (String) throws -> Bool
        var analyzeNavigation: @Sendable (String) async throws -> Void
        var now: @Sendable () -> Date
        var log: @Sendable (String) -> Void
    }

    let deps: Dependencies
    /// 有界等待预算：任务要求"poll 预算的一小段"，默认 60s；超时只停止等待。
    let duplicateWaitTimeoutMs: Int64
    /// 近期成功窗口：默认 15 分钟内的成功结果视为已就绪，避免重复 dHash 扫描。
    let recentSuccessWindow: TimeInterval

    init(
        deps: Dependencies,
        duplicateWaitTimeoutMs: Int64 = 60_000,
        recentSuccessWindow: TimeInterval = 15 * 60
    ) {
        self.deps = deps
        self.duplicateWaitTimeoutMs = duplicateWaitTimeoutMs
        self.recentSuccessWindow = recentSuccessWindow
    }

    /// 纯判定：活跃 job 优先复用；近期成功跳过；其余入队。
    ///
    /// finishedAt 不可解析（旧行/空）时视为"不可判定近期"→ 重跑：宁可多扫一次，
    /// 也不能把没有组的旧结果当作已就绪（否则 triage 又退化到硬技术信号）。
    static func duplicatePlan(
        jobs: [AnalysisJobData],
        sessionId: String,
        now: Date,
        recentWindow: TimeInterval
    ) -> DuplicatePlan {
        let scans = jobs
            .filter { $0.type == .duplicateScan && $0.scopeId == sessionId }
            .sorted { $0.createdAt < $1.createdAt }
        if let active = scans.last(where: { Self.isActive($0.status) }) {
            return .waitActive(active.id)
        }
        if let succeeded = scans.last(where: { $0.status == .succeeded }),
           let finished = Self.parseTimestamp(succeeded.finishedAt),
           now.timeIntervalSince(finished) <= recentWindow {
            return .recentSuccess
        }
        return .enqueue
    }

    static func isActive(_ status: AnalysisJobStatus) -> Bool {
        switch status {
        case .queued, .running, .cancelling: true
        case .succeeded, .failed, .cancelled, .interrupted: false
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        // 形式：ISO8601（测试夹具为 "2026-11-11T00:00:00Z"；持久行可能带毫秒）。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// 准备分组产物。不抛错：所有失败收敛成 .failed(reason)，交给 pipeline 记日志并继续。
    func run(sessionId: String) async -> AITriageGroupArtifactsOutcome {
        var performed = false
        var failureReason: String?

        // 1) duplicate.scan：与 navigation 互不影响（前者失败不阻止后者）。
        do {
            let jobs = try deps.listJobs()
            switch Self.duplicatePlan(
                jobs: jobs,
                sessionId: sessionId,
                now: deps.now(),
                recentWindow: recentSuccessWindow
            ) {
            case .recentSuccess:
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.duplicate=skip reason=recent-success")
            case .waitActive(let jobId):
                performed = true
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.duplicate=wait-active job=\(jobId)")
                do {
                    try await deps.waitDuplicateScan(jobId, duplicateWaitTimeoutMs)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=ready job=\(jobId)")
                } catch {
                    failureReason = "duplicate-wait: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=failed job=\(jobId) reason=\(error)")
                }
            case .enqueue:
                performed = true
                do {
                    let job = try deps.enqueueDuplicateScan(sessionId)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=enqueued job=\(job.id)")
                    do {
                        try await deps.waitDuplicateScan(job.id, duplicateWaitTimeoutMs)
                        deps.log("ai.auto-triage session=\(sessionId)"
                            + " groups.duplicate=ready job=\(job.id)")
                    } catch {
                        failureReason = "duplicate-wait: \(error)"
                        deps.log("ai.auto-triage session=\(sessionId)"
                            + " groups.duplicate=failed job=\(job.id) reason=\(error)")
                    }
                } catch {
                    failureReason = "duplicate-enqueue: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.duplicate=failed reason=enqueue: \(error)")
                }
            }
        } catch {
            failureReason = "duplicate-list: \(error)"
            deps.log("ai.auto-triage session=\(sessionId)"
                + " groups.duplicate=failed reason=list: \(error)")
        }

        // 2) navigation.analyze：已有组不重算；无 job 类型，直接调用现有 API。
        do {
            if try deps.hasNavigationGroups(sessionId) {
                deps.log("ai.auto-triage session=\(sessionId)"
                    + " groups.navigation=skip reason=already-exists")
            } else {
                performed = true
                do {
                    try await deps.analyzeNavigation(sessionId)
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.navigation=analyzed")
                } catch {
                    failureReason = failureReason ?? "navigation: \(error)"
                    deps.log("ai.auto-triage session=\(sessionId)"
                        + " groups.navigation=failed reason=\(error)")
                }
            }
        } catch {
            failureReason = failureReason ?? "navigation-check: \(error)"
            deps.log("ai.auto-triage session=\(sessionId)"
                + " groups.navigation=failed reason=check: \(error)")
        }

        guard let failureReason else {
            return performed ? .enqueued : .alreadyReady
        }
        return .failed(failureReason)
    }
}

/// 自动初审的宿主调度入口（Wave5 batch2 / E1）。
///
/// 为什么单独成类型：五个导入入口（菜单/Finder、C1 文件、Dashboard 新建、
/// 加照片到已有工作区、Shortcuts 建库）共享同一份依赖与开关语义；
/// 之前只有前两个入口接了调度。类型是 Sendable，`schedule` 必须 MainActor
/// （读设置 + 写 UI 状态卡都要求主线程；真正耗时的 pipeline 仍在 detached 任务）。
struct AITriageAutoScheduler: Sendable {
    let jobService: JobService
    let database: DBConnection
    let settings: SettingsService
    /// E2：该会话是否已有人脸观测（face_observations 有行）。
    let hasFaceObservations: @Sendable (String) throws -> Bool
    /// E2：缺观测时入队一次增量 face.analyze（不等待结果）。
    let enqueueFaceAnalysis: @Sendable (String) -> Void
    /// E3：quality 成功后、生成建议前确保分组产物（duplicate.scan + navigation.analyze）。
    let ensureGroupArtifacts: @Sendable (String) async -> AITriageGroupArtifactsOutcome

    @MainActor
    func schedule(sessionId: String) {
        AITriageImportTrigger.schedule(
            sessionId: sessionId,
            jobService: jobService,
            database: database,
            settings: settings,
            hasFaceObservations: hasFaceObservations,
            enqueueFaceAnalysis: enqueueFaceAnalysis,
            ensureGroupArtifacts: ensureGroupArtifacts)
    }
}

/// 导入完成后调度自动初审（默认关：triage_auto_generate=0 时直接返回，行为与旧版一致）。
///
/// 边界：
/// - 只调度、不等待（Task.detached）；导入 API 的返回时间不变；
/// - 失败/超时只打日志 + 写状态卡，不回写导入状态（增强能力不能把导入变红）；
/// - 进度与取消走既有 JobService：quality.score 是普通 job，控制中心可见可取消；
///   用户取消该 job → pipeline 观察终态后停止，不会继续生成建议；
/// - Wave5 batch2：超时只停止等待、不取消 job；缺人脸观测时入队 face.analyze
///   但不等它（本次按无脸信号先生成，状态卡显示"待人脸分析"）。
/// - Wave5 batch6（E3）：quality 成功后先确保分组产物（duplicate.scan + navigation.analyze，
///   60s 有界等待）；失败只记日志并继续生成建议，不因分组拖停初审。
enum AITriageImportTrigger {
    /// @MainActor：只做调度（读设置 + 建 actor + 起 detached 任务）；
    /// 真正耗时的 generate/apply 在 `AITriageBackgroundWorker` actor 上执行（E4）。
    @MainActor
    static func schedule(
        sessionId: String,
        jobService: JobService,
        database: DBConnection,
        settings: SettingsService,
        hasFaceObservations: (@Sendable (String) throws -> Bool)? = nil,
        enqueueFaceAnalysis: (@Sendable (String) -> Void)? = nil,
        ensureGroupArtifacts: (@Sendable (String) async -> AITriageGroupArtifactsOutcome)? = nil
    ) {
        guard settings.bool(.triageAutoGenerate) else {
            // 未启用也要可见（状态卡 = 用户唯一的"这次导入到底跑没跑 AI 初审"答案）。
            AITriageStatusStore.shared.set(sessionId: sessionId, phase: .notEnabled)
            return
        }
        guard settings.bool(.triageEnabled) else {
            // triage 关闭：整条自动初审（含 quality 入队）直接跳过，不做无用解码。
            // 记一行日志便于排查"开了 auto_generate 却没反应"（triage_enabled 默认 0）。
            AITriageStatusStore.shared.set(sessionId: sessionId, phase: .notEnabled)
            GatherLogger.log(
                "ai.auto-triage session=\(sessionId) stage=skipped reason=triage-disabled",
                level: .info)
            return
        }
        AITriageStatusStore.shared.set(sessionId: sessionId, phase: .waitingIndex)
        let worker = AITriageBackgroundWorker(database: database, settings: settings)
        // Wave4b：一条导入链一个批次 nonce —— dedupeKey 唯一，`AnalysisJobRepo.create` 的
        // 默认 `inheritCheckpoint` 不会命中上一批终态行（旧 photoIds 会只分析旧照片）。
        let batchNonce = UUID().uuidString
        let deps = AITriageAutoPipeline.Dependencies(
            listJobs: { try jobService.list(status: nil, includeCheckpoint: false) },
            enqueueQualityJob: { scopeId in
                // 状态卡：质量分析已入队（复用活跃 job 时本闭包不调用，状态会停在
                // "等待扫描"直到生成阶段——可接受的最小可见性）。
                Task { @MainActor in
                    AITriageStatusStore.shared.set(
                        sessionId: scopeId, phase: .waitingQuality)
                }
                return try jobService.create(JobCreateParams(
                    type: .qualityScore,
                    scopeType: "session",
                    scopeId: scopeId,
                    dedupeKey: AITriageAutoPipeline.qualityJobDedupeKey(
                        scopeId: scopeId, batchNonce: batchNonce)))
            },
            // 生成/应用都在后台 actor 上（E4）；闭包本身是 @Sendable，不占主线程。
            generateTriage: { scopeId in
                // E2：生成前检查人脸观测。缺观测只入队 face.analyze、**不等待**，
                // 状态卡显示"待人脸分析"；本次建议仍按技术质量/审美信号照常生成。
                let facePlan: AITriageFacePlan? = hasFaceObservations.map { probe in
                    AITriageFacePlan.make(from: Self.facePrerequisite(
                        sessionId: scopeId, hasFaceObservations: probe))
                }
                let statusPhase = facePlan?.phase ?? .generating
                await MainActor.run {
                    AITriageStatusStore.shared.set(
                        sessionId: scopeId, phase: statusPhase)
                }
                if facePlan?.enqueueFaceAnalysis == true {
                    enqueueFaceAnalysis?(scopeId)
                }
                return try await worker.generate(sessionId: scopeId)
            },
            applyTriage: { input in
                try await worker.apply(input)
            },
            autoApplyEnabled: { settings.bool(.triageAutoApply) },
            triageEnabled: { settings.bool(.triageEnabled) },
            ensureGroupArtifacts: { scopeId in
                guard let ensureGroupArtifacts else { return .alreadyReady }
                return await ensureGroupArtifacts(scopeId)
            },
            log: { message in
                GatherLogger.log(message, level: .info)
            },
            poll: { try await Task.sleep(for: .milliseconds(500)) }
        )
        let pipeline = AITriageAutoPipeline(deps: deps)
        Task.detached(priority: .utility) {
            let outcome = await pipeline.run(sessionId: sessionId)
            GatherLogger.log(
                "ai.auto-triage session=\(sessionId) stage=\(outcome.stage.rawValue)"
                    + " quality=\(outcome.qualityJobId ?? "-")"
                    + " keep=\(outcome.summary?.counts.keep ?? -1)"
                    + " reject=\(outcome.summary?.counts.reject ?? -1)"
                    + " review=\(outcome.summary?.counts.review ?? -1)"
                    + " applied=\(outcome.applied?.appliedPhotos ?? 0)"
                    + " reason=\(outcome.reason ?? "-")",
                level: .info)
            // Wave5 batch2：终态（含跳过/超时）写进状态卡 —— 失败/跳过不能只进日志。
            await MainActor.run {
                AITriageStatusStore.shared.set(
                    sessionId: sessionId,
                    phase: Self.statusPhase(for: outcome))
            }
            // Wave4b：auto-generate-only（triage_auto_apply=0）也要广播——之前只在
            // appliedPhotos>0 时发，页面看不到"已生成建议"；现在只要生成成功（done）就刷新。
            guard outcome.stage == .done else { return }
            // 已挂载的挑片/图库据此重拉建议与决策（与 C1 判断落库同一广播口径）。
            await MainActor.run {
                GatherEventCenter.postDomainChange(
                    .culling, sessionId: sessionId, origin: "ai-auto-triage")
            }
        }
    }

    /// E2 纯判定：有人脸观测 = present；无 = missing；查询抛错 = queryFailed
    /// （按"有观测"处理——前置检查失败不能阻塞初审）。
    static func facePrerequisite(
        sessionId: String,
        hasFaceObservations: @Sendable (String) throws -> Bool
    ) -> AITriageFacePrerequisite {
        do {
            return try hasFaceObservations(sessionId) ? .present : .missing
        } catch {
            GatherLogger.log(
                "ai.auto-triage face prerequisite query failed: \(error)", level: .warn)
            return .queryFailed
        }
    }

    /// pipeline 结果 → 状态卡相位（Wave5 batch2）。纯映射，供单测直接驱动。
    @MainActor
    static func statusPhase(for outcome: AITriageAutoOutcome) -> AITriageStatusStore.Phase {
        switch outcome.stage {
        case .done:
            let counts = outcome.summary?.counts
            return .done(
                keep: counts?.keep ?? 0,
                reject: counts?.reject ?? 0,
                review: counts?.review ?? 0)
        case .skipped:
            return .skipped(outcome.reason ?? AITriageStopReason.cancelled)
        case .stopped:
            let reason = outcome.reason ?? "stopped"
            // pipeline 的未预期异常收敛成 "failed: ..."（见 AITriageAutoPipeline.run）。
            return reason.hasPrefix("failed:") ? .failed(reason) : .stopped(reason)
        }
    }
}

// MARK: - Wave3：C1 门面 + Session 目录导入（G4/G5/G6）

/// UI 侧 C1 门面：协调器（reload/选中/预检）+ 具体桥（变体级写回）。
///
/// 为什么需要：`RootShellDependencies.captureOne` 既要让 UI 的
/// `as? C1RoundTripReloading / C1RoundTripExtending` 动态派发成立（手动/自动 reload
/// 共用串行队列、在 C1 中显示），又要暴露只有具体桥才有的变体级写回能力。组合根用
/// 一个门面同时委托两者，避免让 coordinator 反向依赖写回实现。
@MainActor
final class CaptureOneBridgeFacade: CaptureOneBridging, C1RoundTripReloading, C1RoundTripExtending {
    private let coordinator: C1RoundTripCoordinator
    private let bridge: CaptureOneBridge
    /// 协议要求是同步 nonisolated 属性；在 MainActor 门面上按 init 时快照实现，
    /// 避免"@MainActor 类型满足非隔离协议要求"触发 ConformanceIsolation。
    private nonisolated let c1InstalledSnapshot: Bool

    init(coordinator: C1RoundTripCoordinator, bridge: CaptureOneBridge) {
        self.coordinator = coordinator
        self.bridge = bridge
        self.c1InstalledSnapshot = bridge.c1Installed
    }

    nonisolated var c1Installed: Bool { c1InstalledSnapshot }

    // MARK: CaptureOneBridging（reloadMetadata 同时满足 C1RoundTripReloading 的同签名要求）

    func selectedPhotoPaths() async throws -> [String] {
        try await coordinator.selectedPhotoPaths()
    }

    func reloadMetadata(sessionId: String) async throws {
        try await coordinator.reloadMetadata(sessionId: sessionId)
    }

    func checkHealth() async -> Result<String, CaptureOneBridgeError> {
        await coordinator.checkHealth()
    }

    func preflight() async -> C1PreflightStatus {
        await coordinator.preflight()
    }

    nonisolated static func documentProbeScript(appName: String) -> String {
        C1RoundTripCoordinator.documentProbeScript(appName: appName)
    }

    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        try await bridge.writeVariantJudgements(sessionId: sessionId, items: items)
    }

    /// P2（Wave4b）：转发具体桥的本机安装判定（Hot Folder 提示 gate）。

    // MARK: C1RoundTripReloading

    func noteDeliveryStateChanged(sessionId: String) {
        coordinator.noteDeliveryStateChanged(sessionId: sessionId)
    }

    func currentAutoReloadFailure() -> C1AutoReloadFailure? {
        coordinator.currentAutoReloadFailure()
    }

    func clearAutoReloadFailure() {
        coordinator.clearAutoReloadFailure()
    }

    // MARK: C1RoundTripExtending

    func selectVariants(paths: [String]) async throws -> C1SelectionOutcome {
        try await coordinator.selectVariants(paths: paths)
    }

    func adjustmentHints(paths: [String]) -> [C1AdjustmentHint] {
        coordinator.adjustmentHints(paths: paths)
    }
}

/// C1 Session 根目录导入的扫描根重定向（Wave3 / G6，A5 起与新建工作区共用同一 helper）。
///
/// C1 Session 根 = Capture（原始）+ Selects（挑中/移动后的文件）+ Trash（淘汰）。
/// 把根当普通目录递归会让 Trash 淘汰件"复活"成普通资产，并在 Capture/Selects 之间
/// 产生重复。这里识别到 session 结构后**只把 Capture 交给后续导入**（会话 source_path
/// = Capture → 监听/摄取也在 Capture 内；Trash 不扫；Selects 因不扫描而不重复）。
/// 识别/重定向规则在 `C1SessionDirectoryResolver.importPlan`（协议层，Host 与
/// GatherUI 的新建工作区面板共用）；本类型只做 ImportFolderSelection 适配。
/// 已知边界：Selects 中与 Capture 不同名的文件（C1 "Move to Selects" 移动过）本次
/// 不会导入——完整覆盖需要索引器支持按目录排除/去重（不在本波范围，见汇报）。
enum C1SessionDirectoryImport {
    static func redirect(_ selection: ImportFolderSelection) -> ImportFolderSelection {
        guard case .directory(let url) = selection else { return selection }
        guard let plan = C1SessionDirectoryResolver.importPlan(root: url.path) else {
            return selection
        }
        GatherLogger.log(
            "c1.session import scanRoot=\(plan.scanRoot)"
                + " originalRoot=\(plan.originalRoot)"
                + " selects=\(plan.layout.selects != nil)"
                + " trash=\(plan.layout.trash != nil)",
            level: .info)
        return .directory(URL(fileURLWithPath: plan.scanRoot))
    }
}

// MARK: - 摄取成功后的 AI 初审调度（Wave5 batch3 / task-19）

/// 摄取成功后的自动初审调度装饰器（导入入口的第六个/第七个）。
///
/// 为什么在 SessionAPI 层装饰：摄取面板（GatherUI）只依赖 SessionAPI，不能 import
/// GatherHost；而自动初审的调度器需要 JobService/DB/Settings。宿主把 UI 依赖里的
/// session 包一层，只有 ingest 成功后触发回调：
/// - **只在 success 且 registered > 0 时调度**：全被跳过（同一张卡重导）不做无用功；
/// - 失败/取消照原样抛出（摄取结果不被调度污染），调度发生在返回之后（不增加延迟）；
/// - 其它方法一律透传，不影响任何既有调用方。
/// 与其它导入入口同语义：只调度、不等待；真正的 pipeline 仍在后台任务里。
struct TriageSchedulingSessionAPI: SessionAPI {
    let base: any SessionAPI
    /// 摄取成功后的副作用（宿主注入 AITriageAutoScheduler.schedule；测试注入记录器）。
    let onIngestSucceeded: @Sendable (String) -> Void

    func list() async throws -> [SessionData] { try await base.list() }

    func get(_ sessionId: String) async throws -> SessionData {
        try await base.get(sessionId)
    }

    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        try await base.create(input)
    }

    func update(_ input: SessionUpdateParams) async throws -> SessionData {
        try await base.update(input)
    }

    func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        try await base.delete(input)
    }

    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        try await base.addPhotos(input)
    }

    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        let result = try await base.ingest(input)
        if result.registered > 0 {
            onIngestSucceeded(input.value.sessionId)
        }
        return result
    }

    func previewIngest(_ input: SessionIngestInput) async throws -> SessionIngestPreview {
        try await base.previewIngest(input)
    }

    func setSourceRoot(
        _ input: Confirmed<SessionSetSourceRootInput>
    ) async throws -> SessionData {
        try await base.setSourceRoot(input)
    }

    func status(_ sessionId: String) async throws -> WorkspaceStatus {
        try await base.status(sessionId)
    }
}

// MARK: - Wave5 batch5：自动化写判断的共享实现

extension AppBootstrap {
    /// 把自动化入口的判断补丁落到挑片决策（gather://rate 与 App Intents 共用）。
    ///
    /// 为什么两条入口必须共用：URL scheme 没有返回值、Shortcuts 有 dialog，但两者
    /// 的合法值集合、计数口径与错误语义必须一致；各写一份迟早分叉。
    ///
    /// 边界：
    /// - 非破坏性：只走 CullingAPI.batchUpdate（与挑片页星级/色标/保留同一路径），
    ///   不删除、不移动、不改文件名；
    /// - 空补丁/空 photoIds 在类型层拒绝（CullingBatchUpdateInput 也会兜底），
    ///   这里提前给出自动化面的可读错误；
    /// - written = 实际更新的照片数（CullingAPI 每个操作目标一条结果），
    ///   skipped = 请求去重后未落库的张数。
    /// nonisolated：批更新是同步 SQLite 事务（LiveCullingAPI 内部再切执行上下文），
    /// 不能让 AppBootstrap 的 @MainActor 推断把它拉到主线程上跑几百张的写入。
    nonisolated static func applyAutomationDecisions(
        culling: any CullingAPI,
        sessionId: String,
        photoIds: [String],
        patch: GatherAutomationDecisionPatch
    ) async throws -> GatherAutomationDecisionSummary {
        guard !photoIds.isEmpty else { throw GatherAutomationError.noPhotoIds }
        guard !patch.isEmpty else {
            throw GatherAutomationError.invalidDecision("至少需要 rating / label / pick 之一")
        }
        let input = try CullingBatchUpdateInput(
            sessionId: sessionId,
            photoIds: photoIds,
            patch: CullingUpdatePatch(
                rating: patch.rating,
                pickState: patch.pickState,
                colorLabel: patch.colorLabel))
        let results = try await culling.batchUpdate(input)
        let requested = Set(photoIds).count
        return GatherAutomationDecisionSummary(
            sessionId: sessionId,
            written: results.count,
            skipped: max(0, requested - results.count))
    }
}

// desktop/native/gather-app/Sources/GatherHost/Startup/SceneAssembly.swift
// M9（Wave5 / task-9）后续：AppBootstrap 的启动阶段装配从主文件搬出。
// 5 个阶段产物 struct + 11 个 static 阶段函数；阶段顺序 / phaseTimings 标签 /
// restore defer / 并行语义仍由 AppBootstrap.makeScene 持有。
//
// 纯搬移：搬移块与拆分前逐字节一致；仅去掉 private 以便跨文件（同 target）访问。
import Dispatch
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import Observation
import GatherUI

extension AppBootstrap {
    /// 阶段 0 的产物：Gather 数据目录与库文件路径（后续所有阶段的共同输入）。
    struct SceneEnvironment {
        let appDir: URL
        let dbURL: URL
    }

    /// restore 阶段产物：是否真的做了跨进程恢复 + 需持有到启动结束的恢复锁。
    struct RestoreStageResult {
        let didRestore: Bool
        let restoreLock: RestoreLock?
    }

    /// dbOpen 阶段产物：已打开（必要时回滚重开）的库 + 回滚后的恢复标记。
    struct DatabaseStageResult {
        let database: Database
        let didRestore: Bool
    }

    /// composition 阶段产物：唯一组合根及其派生的 runtime / AppServices / 归档现场。
    struct CompositionStageResult {
        let composition: AppComposition
        let runtime: AppRuntime
        let appServices: AppServices
        let archivedDatabase: ArchivedDatabase?
    }

    /// wire 前的装配产物：provider 与 C1 / 自动初审 / 自动化运行时依赖（wire 与 rootDeps 共用）。
    struct WiringStageResult {
        let dashboardProvider: LiveDashboardDataProvider
        let libraryProvider: LiveLibraryDataProvider
        let galleryProvider: LiveGalleryDataProvider
        let captureOneBridge: CaptureOneBridge
        let c1RoundTrip: C1RoundTripCoordinator
        let c1BridgeFacade: CaptureOneBridgeFacade
        let autoTriageScheduler: AITriageAutoScheduler
        let sessionAPIForUI: TriageSchedulingSessionAPI
    }

    /// 阶段 0：数据目录 / 库路径 / 缩略图缓存 / 进程级端口 / 文件日志 sink。
    static func makeSceneEnvironment(
        applicationSupportDirectory: URL?
    ) throws -> SceneEnvironment {
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
        // round-3 性能：上次进程可能留下超限缓存；启动时后台清一次，别让枚举目录
        // 的成本落在首屏第一次解码（write+prune）的后台线程上。
        ThumbnailDiskCache.pruneAtStartupIfNeeded()
        // M12（Wave5）：三个进程级端口（解码 / 预览分析 / 打印渲染）一次装齐。
        // 端口实现在 GatherAnalysis / GatherApplication，GatherUI 只经端口契约拿到；
        // 重复注册按后者生效（bootstrap 重试时替换）。单一入口见 GatherUI PortRegistry。
        PortRegistry.install(
            imageDecoder: RAWImageDecoder(),
            previewAnalysis: PreviewAnalysisAdapter(),
            printRendering: LivePrintRenderer())
        // R7（refactor）：导入路径规则与 C1 同步状态判定已下沉 GatherProtocol，
        // UI 直调纯函数，不再有端口/registry/Host 适配器。
        // B0：文件日志 sink（启动早期安装，Database.open 的失败也能落盘）。
        Self.logSink = LogFileSink.install(
            directory: appDir.appendingPathComponent("Logs", isDirectory: true))
        return SceneEnvironment(appDir: appDir, dbURL: dbURL)
    }

    /// restore 阶段：journal 存在时先拿恢复锁并在 Database.open 前 swap（失败 fail closed）。
    static func makeRestoredStorage(
        appDir: URL,
        dbURL: URL
    ) throws -> RestoreStageResult {
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
        return RestoreStageResult(didRestore: didRestore, restoreLock: restoreLock)
    }

    /// dbOpen 阶段：detached 打开库；恢复后打开失败则回滚旧库并 fail closed。
    static func makeDatabase(
        dbURL: URL,
        didRestore: Bool
    ) async throws -> DatabaseStageResult {
        // 复审 P2（C5）：Database.open 会做 schema inspect/assertReady（并可能迁移/恢复），
        // 是启动期最重的同步 IO；放到 detached 任务，主线程可继续绘制“初始化中…”。
        // Database/DBConnection 均为 @unchecked Sendable（句柄访问由 connectionLock 串行）。
        var didRestore = didRestore
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
        return DatabaseStageResult(database: database, didRestore: didRestore)
    }

    /// composition 阶段：归档现场 / 库权限 / 设置钩子 / 唯一组合根与 AppServices。
    static func makeComposition(
        database: Database,
        dbURL: URL
    ) throws -> CompositionStageResult {
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
        return CompositionStageResult(
            composition: composition,
            runtime: runtime,
            appServices: appServices,
            archivedDatabase: archivedDatabase)
    }

    /// runtime.start 阶段：先发射 detached 启动任务，调用方随后与语言播种并行等待。
    static func startRuntime(
        runtime: AppRuntime,
        replayPendingDeliveries: Bool
    ) -> Task<[AnalysisJobType], Error> {
        // B8.3b-1：注册 8 个 executor 并启动 JobService（start 在已启动时幂等、
        // shutdown 后失败可见）。start 之后还会在后台回放未完成的
        // delivery_intents（不阻塞 UI；失败写 runtime.deliveryReplayFailure）。
        // 复审 C5：start 内部会查库（recoverStale/resumeInterrupted）并注册 executor，
        // 放到 detached 执行；AppRuntime 是 @unchecked Sendable（内部 NSLock 保护生命周期）。
        //
        // round-3 性能：runtime.start 先发射，冷启动语言播种与其**并行**（两份都是
        // 异步等待，互不依赖）。并行安全证明：
        //   · 语言播种只读 settings.ui_language（SettingsAPI.get，单条 SELECT）并写
        //     LanguageStore.seed —— MainActor 独占，且 seed 按注释**不广播**（启动
        //     阶段没有订阅方，持久化早已完成）；
        //   · runtime.start 只碰 executor 注册 / JobService.start() / 后台 delivery
        //     回放，不认识 languageStore；两者没有共享可变内存状态。seed 顺带写的
        //     进程级 GatherLocalization.setAppLanguage 只被 UI 文案出口读取，
        //     runtime.start 路径（JobService/AppRuntime/WorkflowRegistry）零引用；
        //   · DB 访问：都经同一个 DBConnection（句柄访问由 connectionLock 串行；
        //     只读池另有小锁），不存在把同一行写出两种值的事务交叉；
        //   · 可观测顺序不变：scene 发布前两者都已 await 完成；语言播种早/晚几十 µs
        //     对用户不可见（首个读 l10n 的视图在 scene 发布后）。
        // 不并行的候选（证据：2026-11-17 性能专项评审记录；该文档已随 2026-11-18 文档清理移除）：
        // AppImport.prepareNativeEmbeddingRerun 会 jobService.create，必须严格在
        // runtime.start（recoverStale/resumeInterrupted）之后，否则恢复与新建的
        // 先后不可证 —— 保持串行。
        let runtimeStartTask = Task.detached(priority: .userInitiated) {
            try runtime.start(replayPendingDeliveries: replayPendingDeliveries)
        }
        return runtimeStartTask
    }

    /// 语言播种阶段：settings.ui_language 是唯一真相源，经 LanguageStore.seed 写入。
    static func makeLanguageSeed(
        appServices: AppServices,
        languageStore: LanguageStore
    ) async {
        // 冷启动应用持久化界面语言：settings.ui_language 是唯一真相源；
        // 未设置时保持系统语言检测（不再「设置显示中文、界面是英文」）。
        // 4a-3a：写入口是 LanguageStore.seed（同步旧全局但不广播——启动阶段
        // 还没有订阅方，持久化也早已完成，不应触发一次假的「设置页切换」）。
        if let stored = await storedInterfaceLanguage(using: appServices.settings) {
            languageStore.seed(L10n.Language(rawLanguage: stored))
        }
    }

    /// embedding 阶段：原生 embedding 一次性迁移（marker 命中时立即返回）。
    static func prepareEmbedding(
        composition: AppComposition,
        appServices: AppServices,
        databasePath: String
    ) async {
        await AppImport.prepareNativeEmbeddingRerun(
            composition: composition,
            settings: appServices.settings,
            databasePath: databasePath
        )
    }

    /// wire 前装配：provider / C1 桥（reload 协调器 + 具体桥 + 门面）/ 自动初审 / 自动化运行时。
    static func makeWiring(
        composition: AppComposition,
        appServices: AppServices,
        runtime: AppRuntime
    ) -> WiringStageResult {
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

        // task-6 / M3：编译期断言——生产门面必须始终满足 GatherUI 的两个 C1 端口。
        // UI 侧用 captureOne as? any C1RoundTripReloading/Extending 做运行时探测（当前 6 处）；
        // 门面一旦漏掉 conformance，探测会静默退化成 nil（能力消失且无编译错误），
        // 这两行赋值把端口一致性变成编译期错误。
        let _: any C1RoundTripReloading = c1BridgeFacade
        let _: any C1RoundTripExtending = c1BridgeFacade

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
        return WiringStageResult(
            dashboardProvider: provider,
            libraryProvider: libraryProvider,
            galleryProvider: galleryProvider,
            captureOneBridge: captureOneBridge,
            c1RoundTrip: c1RoundTrip,
            c1BridgeFacade: c1BridgeFacade,
            autoTriageScheduler: autoTriageScheduler,
            sessionAPIForUI: sessionAPIForUI)
    }

    /// 壳层依赖包：RootView 只经它注入；全部引用来自组合根 / AppServices / provider。
    static func makeRootShellDependencies(
        delegate: GatherAppDelegate?,
        appServices: AppServices,
        wiring: WiringStageResult
    ) -> RootShellDependencies {
        let sessionAPIForUI = wiring.sessionAPIForUI
        let c1BridgeFacade = wiring.c1BridgeFacade
        let libraryProvider = wiring.libraryProvider
        let galleryProvider = wiring.galleryProvider
        let provider = wiring.dashboardProvider
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
        return rootDeps
    }

    /// Delegate 回调接线：菜单/C1/deep-link 与退出停机都落到同一
    /// composition/runtime。必须在发布 `scene` 之前完成（与拆分前顺序一致），
    /// 否则场景出现后再触发 C1 导入会误报 GATHER_BOOTSTRAPPING。
    /// P1：元数据保留期 GC（启动 30s 后一次 + 24h 周期）与关键词索引回填（断点续跑）。
    static func scheduleBackgroundMaintenance(composition: AppComposition) {
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

    static func wire(
        delegate: GatherAppDelegate?,
        composition: AppComposition,
        sessionAPI: any SessionAPI,
        jobAPI: any JobAPI,
        // Wave5 batch7（A2/R5）：Dashboard C1 建库也走统一 C1 导入入口（同一个 provider）。
        dashboardProvider: any DashboardDataProvider,
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
        // Wave5 batch7（A2/R5）：C1 判断数据随导入的统一协调器。
        //
        // 三个 C1 入口（菜单 ⌘⇧I / Dashboard 新建工作区 source=capture-one /
        // gather://import?source=capture-one）共用它：快照 → 按导入路径暂存 →
        // 建库后交给 C1JudgementImport（等 metadata.scan 终态；跳过时登记 pending 重放）。
        // 判断落库失败绝不影响导入结果（协调器/调度器自行收敛）。
        let c1Import = C1ImportCoordinator(
            snapshotProvider: { try await captureOneJudgements() },
            fallbackPathProvider: { try await captureOneBridge.selectedPhotoPaths() },
            scheduleApply: { sessionId, judgements in
                C1JudgementImport.scheduleApply(
                    database: replayDatabase,
                    sessionId: sessionId,
                    judgements: judgements,
                    onSkipped: { report in
                        // Wave4c：扫描失败/超时/取消不再是"静默跳过"——登记 pending，
                        // 状态条可见且可重试；自动重试由 replay 的后台 watcher 负责。
                        let reason = report.skippedReason ?? "unknown"
                        Task {
                            await c1PendingReplay.register(
                                sessionId: sessionId,
                                judgements: judgements,
                                skippedReason: reason)
                        }
                    })
            })
        // Wave5 batch7（A2/R5）：Dashboard「新建工作区（Capture One）」走同一 C1 入口。
        //
        // 为什么经 UI 静态桥：GatherUI 不能 import GatherHost。注入后 Dashboard 的
        // C1 分支与菜单/深链共用同一入口（判断数据 + capture-one 来源标 + 默认命名）；
        // 未接线（单测/预览/停机）时 VM 显式回退 provider 直连（导入照常、无判断数据）。
        C1DashboardImportBridge.defaultCaptureOneName = { l10n in
            AppImport.defaultImportName(source: AppImport.captureOneSource, l10n: l10n)
        }
        C1DashboardImportBridge.createSessionFromSelection = { name, selectedPaths, _ in
            let paths: [String]
            do {
                paths = try await c1Import.capturePaths(expectedPaths: selectedPaths)
            } catch {
                // 快照与 fallback 都失败：仍按 Dashboard 选中路径建库（只少判断数据）。
                GatherLogger.log(
                    "c1.dashboard snapshot failed: \(error)", level: .warn)
                paths = selectedPaths
            }
            let outcome = try await dashboardProvider.createSessionFromFiles(
                name: name, source: AppImport.captureOneSource, filepaths: paths)
            c1Import.finishCreate(sessionId: outcome.session.id, paths: paths)
            return outcome
        }
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
        // Wave5 batch7（A2/R5）：菜单 ⌘⇧I 与 gather://import?source=capture-one 共用
        // AppImport.importCaptureOneFiles（capture-one 来源标 + 判断数据落库）。
        delegate.onCaptureOneImportFiles = { files in
            // 对齐旧版 App.tsx c1:plugin-import：C1 导入保留
            // capture-one 来源标记与「C1 导入 M/D H:mm」命名（统一入口实现）。
            let l10n = languageStore.l10n
            Task {
                await AppImport.importCaptureOneFiles(
                    files,
                    sessionAPI: sessionAPI,
                    coordinator: c1Import,
                    l10n: l10n,
                    afterCreate: { result in
                        // Wave2 / task-14：C1 导入同样接自动初审（与菜单导入同一语义）。
                        autoTriageScheduler.schedule(sessionId: result.session.id)
                    })
            }
        }
        // Wave5 batch7（A2/R5）：插件/脚本显式 source=capture-one 的深链导入。
        // 入口给的路径是权威（期望路径），快照只提供判断；快照失败仍按 capture-one
        // 导入（只少了判断数据），绝不把 C1 语义降级成本地导入。
        delegate.onCaptureOneFilesImport = { files in
            let l10n = languageStore.l10n
            Task {
                let paths: [String]
                do {
                    paths = try await c1Import.capturePaths(expectedPaths: files)
                } catch {
                    // 快照与 fallback 都失败：仍按入口路径导入（只少判断数据，不阻塞）。
                    GatherLogger.log(
                        "c1.deeplink snapshot failed: \(error)", level: .warn)
                    paths = files
                }
                await AppImport.importCaptureOneFiles(
                    paths,
                    sessionAPI: sessionAPI,
                    coordinator: c1Import,
                    l10n: l10n,
                    afterCreate: { result in
                        autoTriageScheduler.schedule(sessionId: result.session.id)
                    })
            }
        }
        delegate.onCaptureOneImport = {
            // 读快照 + 按快照路径暂存判断（失败时协调器退回 selectedPhotoPaths 并广播
            // C1_JUDGEMENTS_UNAVAILABLE）；delegate 只负责拿"要导入的路径"。
            try await c1Import.capturePaths()
        }
        return c1PendingReplay
    }
}

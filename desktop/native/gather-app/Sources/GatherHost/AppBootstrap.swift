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
import Dispatch
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import Observation
import GatherUI

// MARK: - 启动阶段计时（2026-11-17 round-3 perf-runtime）

/// 一次冷启动的阶段耗时。
///
/// 只在 `startup` / `makeScene` 的 MainActor 上下文里累加，不跨任务、不加锁；
/// 每次冷启动只产出**一行** info 日志（阶段数固定 7），常驻成本可忽略。
/// 目的：给「启动慢」一份可复核的阶段拆分（DB open / 组合根 / 语言播种 /
/// 运行时启动 / embedding 迁移 / provider 接线 / 首帧），避免只能猜总时长。
private struct StartupPhaseTimings {
    private(set) var entries: [(label: String, text: String)] = []

    /// 记录一个已完成阶段的耗时；`start` 来自 `startupTicks()`。
    mutating func record(_ label: String, since start: UInt64) {
        entries.append((label, startupMillisecondsText(since: start)))
    }

    /// `restore=0.8ms dbOpen=41.2ms …`（0.1ms 精度，顺序 = 记录顺序）。
    var summary: String {
        entries.map { "\($0.label)=\($0.text)ms" }.joined(separator: " ")
    }
}

/// 启动计时的单调时钟（纳秒）。用 DispatchTime.uptimeNanoseconds 而不是 Date：
/// 不受系统时钟调整影响，阶段差值才有意义。
private func startupTicks() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

/// 从 `start` 到现在，格式化为 0.1ms 精度（无 locale/格式化器依赖）。
private func startupMillisecondsText(since start: UInt64) -> String {
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    let tenths = (elapsed &+ 50_000) / 100_000
    return "\(tenths / 10).\(tenths % 10)"
}

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
    static var logSink: LogFileSink?

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
    /// 目录 → 库 → 组合根 → AppServices → 冷启动语言 ∥ runtime.start →
    /// 事件总线 → embedding 迁移 → provider → C1 桥/Delegate 回调 → 发布场景。
    /// （round-3 起语言播种与 runtime.start 并行；两者互不依赖，见 makeScene 内
    /// 的并行安全证明。冷启动/失败各打一行阶段耗时日志。）
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
        // round-3 性能观测：一次启动的阶段拆分（成功/失败各一行 info/error 日志；
        // 不改变控制流，也不引入任何新状态）。口径见 StartupPhaseTimings。
        let startupStartedAt = startupTicks()
        do {
            let (state, runtime, maintenance, archived, c1PendingReplay, phaseTimings) =
                try await Self.makeScene(
                    delegate: delegate,
                    applicationSupportDirectory: applicationSupportDirectory,
                    // 4a-3a：语言唯一写入口由装配层持有，冷启动在这里播种。
                    languageStore: languageStore,
                    commandCenter: commandCenter
                )
            self.runtime = runtime
            self.maintenanceService = maintenance
            self.scene = state
            // “firstScene”口径 = startup 入口 → scene 首次发布的墙钟（SwiftUI 首帧的
            // 上界；真正 draw call 发生在场景渲染后，本文件观测不到）。
            let firstScene = startupMillisecondsText(since: startupStartedAt)
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
            // 一行/次冷启动：total = 启动入口 → 接线完成；firstScene = 场景首发时刻；
            // 其余为各阶段自耗时（languageSeed 与 runtimeStart 并行，各自计时）。
            GatherLogger.log(
                "startup phases: total=\(startupMillisecondsText(since: startupStartedAt))ms"
                    + " firstScene=\(firstScene)ms \(phaseTimings.summary)",
                level: .info)
        } catch {
            // 装配失败时清掉预设桥，避免指向半初始化的 SettingsService。
            IngestPresetBridge.settings = nil
            GatherLogger.log(
                "bootstrap failed after \(startupMillisecondsText(since: startupStartedAt))ms: \(error)",
                level: .error)
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
        SceneState, AppRuntime, MaintenanceService, ArchivedDatabase?, C1PendingJudgementReplay,
        StartupPhaseTimings
    ) {
        // 阶段计时只在本函数内累加；随返回值交给 startup 统一打一行日志。
        var phaseTimings = StartupPhaseTimings()

        // 阶段 0：数据目录 / 库路径 / 缩略图缓存 / 进程级端口 / 文件日志 sink。
        // 拆分前这段也没有计时标签；产物是下面所有阶段共用的路径。
        let env = try makeSceneEnvironment(
            applicationSupportDirectory: applicationSupportDirectory)

        // B0：跨进程恢复。journal 存在时先拿恢复锁，在 Database.open 前 swap；
        // 成功 open 后 finalize，失败回滚旧库。
        let restoreStartedAt = startupTicks()
        let restored = try makeRestoredStorage(appDir: env.appDir, dbURL: env.dbURL)
        // 恢复锁必须持有到 makeScene 返回（拆分前 defer 注册在同一位置），
        // 释放点是整个装配结束而不是 restore 阶段结束。
        defer { restored.restoreLock?.release() }
        phaseTimings.record(StartupPhase.restore.rawValue, since: restoreStartedAt)

        let dbOpenStartedAt = startupTicks()
        let opened = try await makeDatabase(dbURL: env.dbURL, didRestore: restored.didRestore)
        phaseTimings.record(StartupPhase.dbOpen.rawValue, since: dbOpenStartedAt)

        let compositionStartedAt = startupTicks()
        let composed = try makeComposition(database: opened.database, dbURL: env.dbURL)
        phaseTimings.record(StartupPhase.composition.rawValue, since: compositionStartedAt)
        // 阶段产物的局部别名：保持拆分前 makeScene 内后续行的变量名不变。
        let composition = composed.composition
        let runtime = composed.runtime
        let appServices = composed.appServices
        let archivedDatabase = composed.archivedDatabase
        // B0：刚完成跨进程恢复时不再回放 pending delivery（恢复前的语义已由 journal 承接）。
        let replayPendingDeliveries = !opened.didRestore
        // round-3 性能：runtime.start 先发射，冷启动语言播种与其并行（两份都是
        // 异步等待，互不依赖）。并行安全证明见 startRuntime / makeLanguageSeed。
        let runtimeStartStartedAt = startupTicks()
        let runtimeStartTask = startRuntime(
            runtime: runtime,
            replayPendingDeliveries: replayPendingDeliveries)
        let languageSeedStartedAt = startupTicks()
        await makeLanguageSeed(appServices: appServices, languageStore: languageStore)
        phaseTimings.record(StartupPhase.languageSeed.rawValue, since: languageSeedStartedAt)
        // start 返回本次恢复的 job 类型列表，这里不需要（恢复结果由 runtime 内部落库）。
        // 语言播种已结束；必须等 start 收尾后才能接线事件总线 / embedding 迁移。
        _ = try await runtimeStartTask.value
        phaseTimings.record(StartupPhase.runtimeStart.rawValue, since: runtimeStartStartedAt)
        // P1：后台维护（元数据备份 GC + 关键词回填），不阻塞启动。
        scheduleBackgroundMaintenance(composition: composition)
        // UI 对齐（§十一 11.9-1）：jobs:progress 事件总线接线。
        GatherEventCenter.shared.wire(jobEvents: runtime.jobService)
        // 一次性 migration（每个 DB 只跑一次；marker 命中时立即返回，≈0ms）。
        let embeddingPrepStartedAt = startupTicks()
        await prepareEmbedding(
            composition: composition,
            appServices: appServices,
            databasePath: env.dbURL.path)
        phaseTimings.record(StartupPhase.embeddingPrep.rawValue, since: embeddingPrepStartedAt)

        // 阶段：页面 provider / C1 桥 / 自动初审 / 自动化运行时预装配（无独立计时）。
        let wiring = makeWiring(
            composition: composition,
            appServices: appServices,
            runtime: runtime)
        // 保持拆分前 makeScene 内后续行的变量名：wire 参数与 SceneState 都直接用别名。
        let photoRepo = composition.photoRepo
        let captureOneBridge = wiring.captureOneBridge

        let wireStartedAt = startupTicks()
        let c1PendingReplay = wire(
            delegate: delegate,
            composition: composition,
            sessionAPI: appServices.session,
            jobAPI: appServices.job,
            dashboardProvider: wiring.dashboardProvider,
            runtime: runtime,
            captureOneBridge: wiring.c1RoundTrip,
            // Wave5 batch2：五个导入入口共享的自动初审调度器。
            autoTriageScheduler: wiring.autoTriageScheduler,
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
        phaseTimings.record(StartupPhase.wire.rawValue, since: wireStartedAt)

        // Cut 4 / 4a-2a-1：壳层依赖包 + 工作区工厂（只装配引用，不 new 服务）。
        let rootDeps = makeRootShellDependencies(
            delegate: delegate,
            appServices: appServices,
            wiring: wiring)
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
            c1PendingReplay,
            phaseTimings
        )
    }

    // MARK: - 冷启动语言

    /// Wave3 / task-21：Shortcuts 未命名导入的默认工作区名（写入 sessions.name）。
    ///
    /// nonisolated：App Intents 的 @Sendable 闭包在非 MainActor 上下文调用它；
    /// 只用 DateFormatter 与 Date，无共享状态。
    nonisolated static func automationImportName() -> String {
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

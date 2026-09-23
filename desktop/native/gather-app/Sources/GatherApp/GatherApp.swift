// desktop/native/gather-app/Sources/GatherApp/GatherApp.swift
// Phase 3.0 宿主与桥：App 入口、路由壳、窗口。
// 原始窗口/生命周期实现已迁入本文件。
//
// 当前形态（3.x）：RootView 与所有页面均为 SwiftUI，业务命令在同进程
// 通过 SessionCommandRouter 直连 GatherCore。
// 数据库：Application Support/Gather/gather.sqlite。
// native app 不依赖 renderer 资产。
import SwiftUI
import AppKit
import GatherCore

@main
struct GatherApp: App {
    @NSApplicationDelegateAdaptor(GatherAppDelegate.self) private var appDelegate
    @State private var router: SessionCommandRouter?
    @State private var provider: LiveDashboardDataProvider?
    @State private var libraryProvider: LiveLibraryDataProvider?
    @State private var galleryProvider: LiveGalleryDataProvider?
    @State private var similarityProvider: LiveSimilarityDataProvider?
    @State private var personsProvider: LivePersonsDataProvider?
    /// bootstrap 失败态：展示错误并提供重试（不再永久停留「初始化中…」）。
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let router, let provider, let libraryProvider, let galleryProvider, let similarityProvider, let personsProvider {
                    RootView(
                        router: router,
                        provider: provider,
                        libraryProvider: libraryProvider,
                        galleryProvider: galleryProvider,
                        similarityProvider: similarityProvider,
                        personsProvider: personsProvider
                    )
                } else if let bootstrapError {
                    GatherEmptyState(
                        icon: "exclamationmark.triangle",
                        title: GatherLocalization.l("初始化失败"),
                        message: bootstrapError
                    ) {
                        Button(GatherLocalization.l("重试")) {
                            Task { await bootstrap() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minWidth: 1100, minHeight: 720)
                } else {
                    Text(GatherLocalization.l("初始化中…"))
                        .frame(minWidth: 1100, minHeight: 720)
                }
            }
            .task {
                await bootstrap()
            }
            .onOpenURL { url in
                appDelegate.handle(url)
            }
        }
        .windowStyle(.automatic)
    }

    /// 启动装配：打开/迁移数据库 → 构建服务 → 创建原生路由。
    private func bootstrap() async {
        guard router == nil else { return }
        await MainActor.run { bootstrapError = nil }
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let appDir = applicationSupport.appendingPathComponent("Gather", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            // 审计 P2-安全：库内含照片路径 + 人脸特征，目录 755/SQLite 0644
            // 过宽 → 收紧为仅当前用户（700/600）。
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: appDir.path)
            let dbURL = appDir.appendingPathComponent("gather.sqlite")
            let db = try DBConnection(path: dbURL.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
            try MigrationRunner(databaseFilePath: dbURL.path).migrate(db)

            // R1/R5：设置存储切到 Store + SettingsAPI（同一库文件的新连接，
            // 打开即确保迁移到当前版本；快照供同步世界读取，写路径走异步 API）。
            let storeDatabase = try SQLiteDatabase(path: dbURL.path)
            try await StoreMigrator().migrate(storeDatabase)
            let api = GatherAPI(container: AppContainer(database: storeDatabase))
            let settingsSnapshot = await api.settings.snapshot()

            let router = SessionCommandRouter.makeDefault(
                db: db,
                settings: settingsSnapshot,
                settingsAPI: api.settings,
                templates: api.templates,
                albums: api.albums,
                workspace: api.workspace,
                persons: api.persons,
                personStore: api.container.persons
            )
            router.jobService.start()
            // UI 对齐（§十一 11.9-1）：jobs:progress 事件总线接线。
            GatherEventCenter.shared.wire(jobService: router.jobService)
            await Self.prepareNativeEmbeddingRerun(
                router: router, databasePath: dbURL.path, settingsAPI: api.settings)
            let provider = LiveDashboardDataProvider(
                sessionService: router.sessionService,
                workspace: api.workspace,
                jobService: router.jobService
            )
            // 3.2/3.3 页面 provider：经路由直连（photo.list_page/filter.*/sim.*
            // 装配形状以路由为唯一事实源）。
            let libraryProvider = LiveLibraryDataProvider(router: router)
            let galleryProvider = LiveGalleryDataProvider(router: router)
            let similarityProvider = LiveSimilarityDataProvider(router: router)
            let personsProvider = LivePersonsDataProvider(router: router)
            let captureOneBridge = CaptureOneBridge(router: router)
            // Dashboard 新建工作区（Capture One 来源）经共享实例访问四层预检
            // 与选中照片读取；菜单导入走 appDelegate.onCaptureOneImport。
            CaptureOneBridge.shared = captureOneBridge
            appDelegate.onImportFiles = { files in
                Self.importFiles(files, router: router)
            }
            appDelegate.onCaptureOneImportFiles = { files in
                // 对齐旧版 App.tsx c1:plugin-import：C1 导入保留
                // capture-one 来源标记与「C1 导入 M/D H:mm」命名。
                Self.importFiles(
                    files,
                    router: router,
                    source: "capture-one",
                    sourceLabel: GatherLocalization.l("Capture One 文件")
                )
            }
            appDelegate.onCaptureOneImport = {
                try await captureOneBridge.selectedPhotoPaths()
            }
            // ADR-023：退出前优雅停机（排空写回 + 关闭 SQLite）。
            appDelegate.onPrepareForTermination = {
                await router.prepareForTermination()
            }
            await MainActor.run {
                self.router = router
                self.provider = provider
                self.libraryProvider = libraryProvider
                self.galleryProvider = galleryProvider
                self.similarityProvider = similarityProvider
                self.personsProvider = personsProvider
                self.bootstrapError = nil
            }
        } catch {
            GatherLogger.log("bootstrap failed: \(error)", level: .error)
            let message = NativeCommandClient.message(for: error)
            await MainActor.run {
                self.bootstrapError = message
            }
        }
    }

    /// Phase 4.3 一次性迁移：Vision feature print rev2 为 768 维，不能与
    /// 旧 512 维向量混用。首次启动原生宿主时切换 native
    /// embedding_dim，并为已有工作区排入 face.analyze；JobService 的
    /// dedupe/checkpoint 保证重启可续。真实照片集的 ARI/NMI 仍需发布前离线
    /// 验收，不在启动阶段伪造通过。
    private static func prepareNativeEmbeddingRerun(
        router: SessionCommandRouter,
        databasePath: String,
        settingsAPI: SettingsAPI
    ) async {
        let marker = "vision-feature-print-rev2-768-v1"
        // Scope the marker to the database. A global UserDefaults marker would
        // incorrectly skip the migration when a second library is opened.
        let markerKey = "gather.nativeEmbeddingVersion.\(databasePath)"
        guard UserDefaults.standard.string(forKey: markerKey) != marker else { return }
        do {
            // R5：设置写路径经 SettingsAPI（异步、白名单校验）。
            try await settingsAPI.set("embedding_dim", value: "768")
            for session in try router.sessionService.listSessions() where session.photoCount > 0 {
                _ = try router.jobService.create(JobCreateParams(
                    type: .faceAnalyze,
                    scopeType: "session",
                    scopeId: session.id,
                    dedupeKey: "face.analyze:native-embedding:\(session.id)",
                    checkpoint: [
                        "detectorPath": .string("vision"),
                        "encoderPath": .string("vision-feature-print-rev2"),
                    ]
                ))
            }
            UserDefaults.standard.set(marker, forKey: markerKey)
        } catch {
            GatherLogger.log("native embedding migration deferred: \(error)", level: .warn)
        }
    }

    /// 文件打开、菜单导入和 deep-link 共用同一条原生导入路径：创建工作区、
    /// 写入已选照片、入队 metadata.scan。导入失败的文件保留在结果日志中，
    /// 不会因为单个损坏文件使整个工作区创建失败。
    ///
    /// source/sourceLabel：C1 菜单导入传 "capture-one"/"Capture One 文件"
    /// （对齐旧版 c1:plugin-import 的来源标记与失败提示文案）；其余为
    /// "local"/"文件"。
    ///
    /// 成功建库后统一 post importCompleted（菜单/C1/deep-link 都走到这里），
    /// userInfo 键名见 GatherAppDelegate 的 GatherAppImportUserInfoKey。
    /// internal（非 private）：GatherAppDelegateTests 需要直调以断言通知内容。
    static func importFiles(
        _ files: [String],
        router: SessionCommandRouter,
        source: String = "local",
        sourceLabel: String = ""
    ) {
        let normalized = normalizeImportFilepaths(files)
        guard !normalized.isEmpty else { return }
        do {
            let sourcePath = commonParentDirectory(filepaths: normalized)
            let name: String
            if sourcePath.isEmpty {
                name = URL(fileURLWithPath: normalized[0]).deletingPathExtension().lastPathComponent
            } else {
                name = URL(fileURLWithPath: sourcePath).lastPathComponent
            }
            let session = try router.sessionService.createSession(
                name: name.isEmpty ? Self.defaultImportName(source: source) : name,
                source: source,
                sourcePath: sourcePath
            )
            let result = try router.sessionService.addPhotos(
                sessionId: session.id,
                filepaths: normalized,
                source: "import"
            )
            _ = try router.jobService.create(JobCreateParams(
                type: .metadataScan,
                scopeType: "session",
                scopeId: session.id,
                dedupeKey: "metadata.scan:\(session.id)"
            ))
            if !result.failedFiles.isEmpty {
                GatherLogger.log("import skipped \(result.failedFiles.count) files", level: .warn)
            }
            let examples = result.failedFiles
                .prefix(3)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "、")
            NotificationCenter.default.post(
                name: GatherAppNotification.importCompleted,
                object: nil,
                userInfo: [
                    GatherAppImportUserInfoKey.sessionId: session.id,
                    GatherAppImportUserInfoKey.failedCount: result.failedFiles.count,
                    GatherAppImportUserInfoKey.addedCount: result.added,
                    GatherAppImportUserInfoKey.sourceLabel: sourceLabel,
                    GatherAppImportUserInfoKey.examples: examples,
                ]
            )
        } catch {
            GatherLogger.log("native import failed: \(error)", level: .error)
        }
    }

    /// 对齐旧版 app.c1ImportName：C1 导入无公共父目录时使用
    /// 「C1 导入 M/D H:mm」（分钟补零）；其他来源回退「导入照片」。
    private static func defaultImportName(source: String) -> String {
        guard source == "capture-one" else { return GatherLocalization.l("导入照片") }
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return String(format: GatherLocalization.l("C1 导入 %@"), "\(month)/\(day) \(hour):\(String(format: "%02d", minute))")
    }
}

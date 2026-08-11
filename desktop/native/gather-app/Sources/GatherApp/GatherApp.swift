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
                } else {
                    Text("初始化中…")
                        .frame(minWidth: 1200, minHeight: 800)
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
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let appDir = applicationSupport.appendingPathComponent("Gather", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let dbURL = appDir.appendingPathComponent("gather.sqlite")
            let db = try DBConnection(path: dbURL.path)
            try MigrationRunner(databaseFilePath: dbURL.path).migrate(db)

            let router = SessionCommandRouter.makeDefault(db: db)
            router.jobService.start()
            Self.prepareNativeEmbeddingRerun(router: router, databasePath: dbURL.path)
            let provider = LiveDashboardDataProvider(
                sessionService: router.sessionService,
                workspaceStatusService: router.workspaceStatusService,
                jobService: router.jobService
            )
            // 3.2/3.3 页面 provider：经路由直连（photo.list_page/filter.*/sim.*
            // 装配形状以路由为唯一事实源）。
            let libraryProvider = LiveLibraryDataProvider(router: router)
            let galleryProvider = LiveGalleryDataProvider(router: router)
            let similarityProvider = LiveSimilarityDataProvider(router: router)
            let personsProvider = LivePersonsDataProvider(router: router)
            let captureOneBridge = CaptureOneBridge(router: router)
            appDelegate.onImportFiles = { files in
                Self.importFiles(files, router: router)
            }
            appDelegate.onCaptureOneImport = {
                try await captureOneBridge.selectedPhotoPaths()
            }
            await MainActor.run {
                self.router = router
                self.provider = provider
                self.libraryProvider = libraryProvider
                self.galleryProvider = galleryProvider
                self.similarityProvider = similarityProvider
                self.personsProvider = personsProvider
            }
        } catch {
            GatherLogger.log("bootstrap failed: \(error)", level: .error)
        }
    }

    /// Phase 4.3 一次性迁移：Vision feature print rev2 为 768 维，不能与
    /// 旧 512 维向量混用。首次启动原生宿主时切换 native
    /// embedding_dim，并为已有工作区排入 face.analyze；JobService 的
    /// dedupe/checkpoint 保证重启可续。真实照片集的 ARI/NMI 仍需发布前离线
    /// 验收，不在启动阶段伪造通过。
    private static func prepareNativeEmbeddingRerun(router: SessionCommandRouter, databasePath: String) {
        let marker = "vision-feature-print-rev2-768-v1"
        // Scope the marker to the database. A global UserDefaults marker would
        // incorrectly skip the migration when a second library is opened.
        let markerKey = "gather.nativeEmbeddingVersion.\(databasePath)"
        guard UserDefaults.standard.string(forKey: markerKey) != marker else { return }
        do {
            _ = try router.execute("settings.set", params: [
                "key": .string("embedding_dim"),
                "value": .string("768"),
            ])
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
    private static func importFiles(_ files: [String], router: SessionCommandRouter) {
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
                name: name.isEmpty ? "导入照片" : name,
                source: "local",
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
        } catch {
            GatherLogger.log("native import failed: \(error)", level: .error)
        }
    }
}

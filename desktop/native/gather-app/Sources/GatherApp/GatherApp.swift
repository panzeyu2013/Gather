// desktop/native/gather-app/Sources/GatherApp/GatherApp.swift
// Phase 3.0 宿主与桥：App 入口、路由壳、窗口。
// TS 源: desktop/src/main/index.ts（窗口/生命周期段）+ renderer/App.tsx + main.tsx
//
// 当前形态（3.1）：RootView 逐页切换——Dashboard 为 SwiftUI，其余残余 React
// 页由 WKWebView 托管；3.x 起继续按页替换。
// 数据库：userData/gather.sqlite（等价 Electron app.getPath('userData')）；
// renderer 资产：desktop/dist/renderer（vite build 产物）。
import SwiftUI
import AppKit
import GatherCore

@main
struct GatherApp: App {
    @State private var host: WebViewHost?
    @State private var provider: LiveDashboardDataProvider?
    @State private var dbPath: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let host, let provider {
                    RootView(host: host, provider: provider)
                } else {
                    Text("初始化中…")
                        .frame(minWidth: 1200, minHeight: 800)
                }
            }
            .task {
                await bootstrap()
            }
        }
        .windowStyle(.automatic)
    }

    /// 启动装配：打开/迁移数据库 → 构建服务 → 创建宿主。
    private func bootstrap() async {
        guard host == nil else { return }
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
            let provider = LiveDashboardDataProvider(
                sessionService: router.sessionService,
                workspaceStatusService: router.workspaceStatusService,
                jobService: router.jobService
            )
            let rendererDir = Self.resolveRendererDir()
            let host = WebViewHost(rendererDir: rendererDir, router: router)
            await MainActor.run {
                self.host = host
                self.provider = provider
                self.dbPath = dbURL.path
            }
        } catch {
            GatherLogger.log("bootstrap failed: \(error)", level: .error)
        }
    }

    /// renderer 资产定位：优先环境变量 GATHER_RENDERER_DIR，否则相对本文件
    /// 上溯到 desktop/dist/renderer（仓库开发形态）。
    private static func resolveRendererDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["GATHER_RENDERER_DIR"] {
            return URL(fileURLWithPath: override)
        }
        // Sources/GatherApp/GatherApp.swift → desktop/native/gather-app/Sources/... → desktop/
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        // desktop/
        let candidate = url.appendingPathComponent("desktop/dist/renderer")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // 兜底：native 目录同级无 dist 时用 SPM 上下文环境变量再找一次。
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
}

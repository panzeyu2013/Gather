// desktop/native/gather-app/Sources/GatherApp/Shell/SessionShellView.swift
// R6 会话宿主（步骤四）：一个会话下的 5 个工作区页签
// （controlCenter / faceKeywording / duplicates / culling / export）。
// 只做「按页签 switch + 透传导航闭包」，不创建视图模型、不解释路由；
// 路由层依赖未注入时整页回退占位。浏览/相似度由导航闭包交回外层壳接线。
import SwiftUI

struct SessionShellView: View {
    /// 会话 id：透传给各页签；调用方在会话/页签变化时必须重建本视图。
    let sessionId: String
    /// 当前页签（5 选 1，由外层壳的导航状态驱动）。
    let tab: SessionTab
    /// 会话工作区依赖（可选：nil 时回退占位）。
    let router: CommandRouter?
    /// 返回浏览页（5 个页签共用的 onBack）。
    let onBack: () -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenSimilarity: (String) -> Void
    let onOpenGallery: (String) -> Void
    let onOpenSettings: () -> Void

    init(
        sessionId: String,
        tab: SessionTab = .control,
        router: CommandRouter? = nil,
        onBack: @escaping () -> Void = {},
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.sessionId = sessionId
        self.tab = tab
        self.router = router
        self.onBack = onBack
        self.onOpenTab = onOpenTab
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        if let router {
            tabContent(router: router)
        } else {
            placeholder
        }
    }

    /// 按当前页签渲染对应工作区视图；导航闭包原样透传（不解释目的地）。
    @ViewBuilder
    private func tabContent(router: CommandRouter) -> some View {
        switch tab {
        case .control:
            SessionControlView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        case .faceKw:
            FaceKeywordingView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        case .duplicates:
            DuplicatesView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        case .culling:
            CullingView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        case .export:
            ExportView(
                sessionId: sessionId,
                router: router,
                onBack: onBack,
                onOpenSimilarity: onOpenSimilarity,
                onOpenTab: onOpenTab,
                onOpenGallery: onOpenGallery,
                onOpenSettings: onOpenSettings
            )
        }
    }

    /// 依赖未注入时的占位：保留页签名，提示缺少会话工作区依赖。
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tabTitle)
                .font(.title3.weight(.semibold))
            Text(GatherLocalization.l("会话工作区依赖未注入。"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    /// 页签显示名：沿用页签栏既有文案，不新造术语。
    private var tabTitle: String {
        switch tab {
        case .control: return GatherLocalization.l("控制中心")
        case .faceKw: return GatherLocalization.l("人脸")
        case .duplicates: return GatherLocalization.l("重复")
        case .culling: return GatherLocalization.l("挑片")
        case .export: return GatherLocalization.l("导出")
        }
    }
}

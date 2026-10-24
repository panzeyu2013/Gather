// 工作台首屏（无工作区时）。
//
// 设计参考：
// - Apple HIG Onboarding：短、可跳过、聚焦“开始使用”，不要做营销长页；
// - Apple HIG Layout：按重要性从左上到右下排列，用容器与留白表达层级；
// - Apple HIG Materials：内容层用标准材质，Liquid Glass 只留给按钮/工具栏等功能层。
//
// 结果：左上 hero（产品预览 + 单一主 CTA），下方三张可扫读的快捷卡，
// 不再把一个小空态丢进整块画布中央。
import SwiftUI
import AppKit

struct DashboardFirstRunView: View {
    let onImportFolder: () -> Void
    let onCreateWorkspace: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.languageStore) private var languageStore
    @State private var heroHovered = false

    var body: some View {
        ZStack(alignment: .top) {
            GatherTheme.canvas
            RadialGradient(
                colors: [GatherTheme.accent.opacity(0.10), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 560
            )
            .frame(height: 620)
            .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.xl) {
                    hero
                    quickGrid
                    privacyNote
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, GatherMetrics.Space.xxl)
                .padding(.top, 36)
                .padding(.bottom, GatherMetrics.Space.xxxl)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: GatherMetrics.Space.xxl) {
                heroCopy
                Spacer(minLength: 0)
                DashboardHeroCollage()
                    .frame(width: 280, height: 210)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 760)

            VStack(alignment: .leading, spacing: GatherMetrics.Space.xl) {
                heroCopy
                DashboardHeroCollage()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .accessibilityHidden(true)
            }
        }
        .padding(GatherMetrics.Space.xxl)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.hero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [GatherTheme.surface, GatherTheme.accent.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.hero, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 1)
        )
        .shadow(
            color: GatherTheme.shadowHero,
            radius: heroHovered ? 26 : 18,
            x: 0,
            y: heroHovered ? 12 : 8
        )
        .animation(reduceMotion ? nil : .easeOut(duration: GatherMetrics.Motion.standard), value: heroHovered)
        .onHover { hovering in
            heroHovered = hovering
        }
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.l) {
            HStack(alignment: .center, spacing: GatherMetrics.Space.m) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text("GATHER")
                        .font(GatherFont.eyebrow)
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                    Text(l10n("导入你的第一个工作区"))
                        .font(GatherFont.hero)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(l10n("从文件夹或 Capture One 导入；照片不会被移动。"))
                .font(GatherFont.heroSubtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: GatherMetrics.Space.s) {
                featureChip(l10n("本地文件夹"), systemImage: "internaldrive")
                featureChip("RAW + JPEG", systemImage: "photo.stack")
                featureChip("Capture One", systemImage: "camera.aperture")
            }

            HStack(spacing: GatherMetrics.Space.m) {
                Button(action: onImportFolder) {
                    Label(l10n("导入文件夹"), systemImage: "folder")
                        .frame(minWidth: 108)
                }
                .controlSize(.large)
                .gatherPrimaryActionButton()

                Button(action: onCreateWorkspace) {
                    Label(l10n("新建工作区"), systemImage: "plus")
                }
                .controlSize(.large)
                .gatherSecondaryActionButton()
            }
            .padding(.top, GatherMetrics.Space.xs)
        }
        .frame(maxWidth: 500, alignment: .leading)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "camera.aperture")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GatherTheme.accent)
                .frame(width: 52, height: 52)
                .background(GatherTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func featureChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(GatherFont.label)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(GatherTheme.surfaceMuted))
            .overlay(Capsule().strokeBorder(GatherTheme.hairline, lineWidth: 1))
    }

    // MARK: - Quick cards

    private var quickGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: GatherMetrics.Space.l)],
            spacing: GatherMetrics.Space.l
        ) {
            DashboardQuickCard(
                title: "Capture One",
                detail: l10n("连接后可直接读取选片与写回 XMP。"),
                systemImage: "camera.aperture",
                tint: GatherTheme.accent,
                actionLabel: l10n("设置"),
                action: onOpenSettings
            )
            DashboardQuickCard(
                title: l10n("三步工作流"),
                detail: l10n("1 选择来源  ·  2 建立索引  ·  3 挑片 / 写回"),
                systemImage: "square.stack.3d.up",
                tint: GatherTheme.info,
                actionLabel: nil,
                action: nil
            )
            DashboardQuickCard(
                title: l10n("最近使用"),
                detail: l10n("暂无工作区"),
                systemImage: "clock.arrow.circlepath",
                tint: GatherTheme.success,
                actionLabel: l10n("新建工作区"),
                action: onCreateWorkspace
            )
        }
    }

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
            Text(l10n("所有处理都在本地完成；照片不会被移动。"))
        }
        .font(GatherFont.secondary)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var l10n: L10n {
        languageStore?.l10n ?? L10n(language: .zhCN)
    }
}

// MARK: - Hero collage

private struct DashboardHeroCollage: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(GatherTheme.accent.opacity(0.16))
                .frame(width: 180, height: 180)
                .blur(radius: 46)
                .offset(x: 20, y: -8)

            photoCard(
                angle: -9,
                offset: CGSize(width: -70, height: 18),
                colors: [GatherTheme.surfaceMuted, GatherTheme.accent.opacity(0.30)],
                selected: false,
                badge: "03"
            )
            photoCard(
                angle: 7,
                offset: CGSize(width: 64, height: -4),
                colors: [GatherTheme.surfaceMuted, GatherTheme.accent.opacity(0.18)],
                selected: false,
                badge: "02"
            )
            photoCard(
                angle: 0,
                offset: CGSize(width: 0, height: 28),
                colors: [GatherTheme.accent.opacity(0.26), GatherTheme.accent.opacity(0.62)],
                selected: true,
                badge: "01"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func photoCard(
        angle: Double,
        offset: CGSize,
        colors: [Color],
        selected: Bool,
        badge: String
    ) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 152, height: 190)
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.88))
            )
            .overlay(alignment: .bottomLeading) {
                PhotoOverlayChip(text: badge, systemImage: nil)
                    .padding(9)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? GatherTheme.selection : Color.white.opacity(0.22), lineWidth: selected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, GatherTheme.selection)
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 9)
            .rotationEffect(.degrees(angle))
            .offset(offset)
    }
}

// MARK: - Quick card

private struct DashboardQuickCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let actionLabel: String?
    let action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer(minLength: 0)
            }
            Text(title)
                .font(GatherFont.cardTitle)
            Text(detail)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionLabel, let action {
                Button {
                    action()
                } label: {
                    Text(actionLabel)
                        .font(GatherFont.secondaryStrong)
                        .foregroundStyle(GatherTheme.accent)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.tile, style: .continuous)
                .fill(GatherTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.tile, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 1)
        )
        .shadow(
            color: isHovered ? GatherTheme.shadowCard : .clear,
            radius: 10,
            y: 4
        )
        .animation(.easeOut(duration: GatherMetrics.Motion.hover), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

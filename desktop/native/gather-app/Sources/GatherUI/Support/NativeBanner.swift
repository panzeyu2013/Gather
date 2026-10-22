// desktop/native/gather-app/Sources/GatherUI/Support/NativeBanner.swift
// Cut 3 / 3b-3：页面级内联提示条。
//
// 3b-2 前声明在 GatherHost/RootView.swift；Dashboard/Culling/Library/Gallery/
// Settings 等 10+ 个 GatherUI 页面都在用，拆 target 后上移到 UI。
import SwiftUI

// MARK: - 错误载体 → 渲染期文案（Cut 4 / 4a-3b-1）

/// `CommandError` → 当前语言文案。**只在渲染期调用**：VM 只搬运码/参数/诊断，
/// 文案在这里按语言解析，切语言后已落进 VM 的错误不再残留旧语言字符串
/// （审计 P0-2：旧实现把本地化字符串存进 7 个 VM，靠 `.id(languageVersion)`
/// 整树重建掩盖）。
///
/// 解析顺序（沿用 `L10n.errorText` 的既有语义，只多一条「界面本地文案」分支）：
/// 1. 已知错误码（含 `CODE::p1::p2` 与 `CODE: 参数`）→ 码表模板 + `{{param}}` 插值；
/// 2. **VM 本地校验**（origin == .localValidation；`code` 即本地化表 key，本仓
///    约定中文原文为 key）→ 按 key 本地化后顺序插入参数（`%lld/%d` 先归一成
///    `%@`，避免 `String(format:)` 的参数类型错配导致运行时崩溃）；
/// 3. 其余（未知码 / 英文诊断 / **API 的中文散文**）→「发生未知错误」通用回退，
///    诊断只进 tooltip/日志。
///
/// Cut 4 / 4a-3b-2b 政策：第 2 条只对 VM 本地校验开放。API/核心错误的散文
/// （无论中英文）在 `CommandError.init` 里已落到 diagnostic（code 留空），
/// 这里再用 origin 兜一层——绝不能把 API 中文诊断直接铺到界面上。
enum CommandErrorText {
    static func resolve(_ error: CommandError, with l10n: L10n) -> String {
        let localized = l10n.errorText(error)
        guard error.origin == .localValidation,
              localized == l10n(L10n.unknownErrorKey),
              isLocalCopy(error.code) else {
            return localized
        }
        let template = l10n(error.code)
        // 无参数时不走 String(format:)：诊断里可能带裸 '%'（路径/百分比），
        // 会被当成格式说明符；只把已知占位符清空（与旧插值语义一致）。
        guard !error.params.isEmpty else {
            return template
                .replacingOccurrences(of: "%lld", with: "")
                .replacingOccurrences(of: "%d", with: "")
                .replacingOccurrences(of: "%@", with: "")
        }
        return String(
            format: template
                .replacingOccurrences(of: "%lld", with: "%@")
                .replacingOccurrences(of: "%d", with: "%@"),
            arguments: error.params
        )
    }

    /// 本地文案 key 判定：中文原文 key（CJK）才按 key 上屏；纯英文诊断不算
    /// （与 FaceKeywordingViewModel.analysisFailure 的既有判定同一口径）。
    private static func isLocalCopy(_ code: String) -> Bool {
        code.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)     // CJK 标点
                || (0x3400...0x9FFF).contains(scalar.value)  // 汉字（含扩展 A）
                || (0xFF00...0xFFEF).contains(scalar.value)  // 全角形式
        }
    }
}

// MARK: - 页面内联提示条（原生）

/// 页面级内联提示：SF Symbol + 文字 + 语义色底，取代旧版裸色块横幅。
public struct NativeBanner: View {
    public let text: String
    public var color: Color = GatherTheme.error
    public var systemImage: String?
    public var onDismiss: (() -> Void)?

    public init(text: String, color: Color = GatherTheme.error, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.color = color
        self.systemImage = nil
        self.onDismiss = onDismiss
    }

    public init(text: String, systemImage: String, color: Color = GatherTheme.error, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
        self.onDismiss = onDismiss
    }

    /// Cut 4 / 4b-2l：关闭按钮 tooltip 在渲染期解析（胶囊文案本身由调用方传入）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var resolvedImage: String {
        if let systemImage { return systemImage }
        return color == GatherTheme.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: resolvedImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(l10n("关闭"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

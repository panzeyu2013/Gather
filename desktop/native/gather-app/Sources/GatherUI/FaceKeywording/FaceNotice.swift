// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceNotice.swift
// Cut 4 / 4c-2b：从 FaceKeywordingView.swift 817-853 行移出的页面提示（逐字搬移）。
// 与 CullingNotice 同构：动作本身也是 key + 参数，渲染期才解析（切语言即换文案）。
import Foundation

// MARK: - 页面提示（Cut 4 / 4b-2b）

/// 人脸页的可见提示：普通单句，或「已取消“<动作>”，未执行任何更改」。
///
/// 与 CullingNotice 同构：动作本身也是 key + 参数（带 `#%lld` / 文件名），
/// 存成 `LocalizedText` 而不是已解析文案——渲染期才查表，切语言即换文案，
/// 也不会把 `%lld` 原样漏到界面上。
public struct FaceNotice: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case text(LocalizedText)
        case cancelled(LocalizedText)
    }

    let payload: Payload

    public init(_ key: String, params: [String] = []) {
        payload = .text(LocalizedText(key, params: params))
    }

    public init(_ text: LocalizedText) {
        payload = .text(text)
    }

    public init(cancelled action: LocalizedText) {
        payload = .cancelled(action)
    }

    /// 渲染期解析（与 `L10n.resolve(_:)` 同源；未知 key 原样透传）。
    public func resolve(with l10n: L10n) -> String {
        switch payload {
        case .text(let text):
            return l10n.resolve(text)
        case .cancelled(let action):
            return l10n.format("已取消“%@”，未执行任何更改", l10n.resolve(action))
        }
    }
}

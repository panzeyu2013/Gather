// desktop/native/gather-app/Sources/GatherUI/Culling/CullingNotice.swift
// Cut 4 / 4c-2a：从 CullingView.swift 第 28-81 行原样移出（唯一改动是文件边界）。
// Culling 页的提示文案载体：只存本地化 key / 参数 / 计数，渲染期由 View 的 L10n 解析。
import Foundation
import GatherProtocol

/// Cut 4 / 4b-2a：Culling 页的提示文案载体。
///
/// 只存本地化 key / 参数 / 计数，**不存任何已格式化字符串**——渲染期由 View 的
/// `L10n` 解析，切语言后同一次重绘即换文案（含计数与目标名）。
/// 为什么不是单个 `LocalizedText`：写回成功提示是「计数句 + 后续指引句」的两段
/// 组合，而 `LocalizedText.params` 只能放字符串；把前一段预先格式化再塞进后一段
/// 会让内层语言冻结（审计 §3.5 R4「多句拼接」）。这里保留结构，渲染期用既有
/// 的两个模板嵌套解析，输出与旧实现逐字一致。
public struct CullingNotice: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case text(LocalizedText)
        /// 写回/重试写回成功：目标（评分/颜色标签/关键字）+ 三项计数 + 指引句。
        case writeback(label: LocalizedText, written: Int, failed: Int, skipped: Int)
        /// 破坏性动作被取消：「已取消：%@」，动作本身也是 key（不是已解析文案）。
        case cancelled(action: LocalizedText)
    }

    let payload: Payload

    /// 单句提示（与 `LocalizedText` 同形：key + 参数）。
    public init(_ key: String, params: [String] = []) {
        payload = .text(LocalizedText(key, params: params))
    }

    public init(_ text: LocalizedText) {
        payload = .text(text)
    }

    /// 写回结果：计数与目标都保留原始值，渲染期再查表。
    public init(writebackLabel label: LocalizedText, written: Int, failed: Int, skipped: Int) {
        payload = .writeback(label: label, written: written, failed: failed, skipped: skipped)
    }

    /// 取消动作：动作以 key 形式保存。
    public init(cancelled action: LocalizedText) {
        payload = .cancelled(action: action)
    }

    /// 渲染期解析（与 `L10n.resolve(_:)` 同源；未知 key 原样透传）。
    public func resolve(with l10n: L10n) -> String {
        switch payload {
        case .text(let text):
            return l10n.resolve(text)
        case .writeback(let label, let written, let failed, let skipped):
            let counts = l10n.format(
                "%@：成功 %lld，失败 %lld，跳过 %lld",
                l10n.resolve(label), written, failed, skipped
            )
            return l10n.format("%@；请让 Capture One 重新加载元数据后确认同步", counts)
        case .cancelled(let action):
            return l10n.format("已取消：%@", l10n.resolve(action))
        }
    }
}

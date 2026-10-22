// desktop/native/gather-app/Sources/GatherUI/Support/LocalizedText.swift
// Cut 4 / 4a-0：延迟本地化文本。
//
// 现状：notice/取消文案/writebackMessage 等"非错误"的提示字符串在事件发生时
// 就被 GatherLocalization.l 解析成当前语言，切语言后不再刷新（§2.4/§3.5）。
// LocalizedText 只存 key + 参数，渲染时用 L10n 查表 + 插值。
//
// Cut 4 / 4a-3b-2b：本类型成为 6 个 notice / Face errorDetail / Similarity
// writebackMessage 的载体。未命中本地化表时回退 key 原文（中文原文即 key，
// 也用于诊断原文的"原样透传"：调用方用 LocalizedText(rawDiagnostic)）。
//
// Cut 4 / 4b-2-prep：补「动态 key」初始化与 `resolve(with:)` 规范入口
// （Hashable/Equatable 语义不变，仍是 key + params 的值语义）。
import Foundation

public struct LocalizedText: Equatable, Hashable, Sendable {
    /// 本地化表 key（zh 表以中文原文为 key，与 GatherLocalization 一致）。
    public let key: String
    /// {{param}} / %@ / %lld 按出现顺序插值。
    public let params: [String]
    /// 计数文案的计数（R5-P1-2）：非 nil 时渲染期按 1/n 选择单复数模板；
    /// params 已包含这个计数的十进制文本（由 plural 工厂追加）。
    public let pluralCount: Int?

    public init(_ key: String, params: [String] = [], pluralCount: Int? = nil) {
        self.key = key
        self.params = params
        self.pluralCount = pluralCount
    }

    /// 计数文案（延迟解析）：count == 1 时英文用 key + "#one" 单数模板，
    /// 其余用 key；zh 无单数条目，回退 key 原文。params 是计数之前的参数，
    /// 计数文本按顺序追加到最后（与 L10n.plural 同一约定）。
    public static func plural(_ key: String, count: Int, params: [String] = []) -> LocalizedText {
        LocalizedText(key, params: params + [String(count)], pluralCount: count)
    }

    /// 动态 key 初始化（Cut 4 / 4b-2）：key 来自运行时变量/静态目录（设置页的
    /// zhLabel/zhDesc、SelectOption 的 labelZh、菜单的显隐标题等），而不是源码
    /// 字面量。语义与 `init(_:params:)` 完全相同（未命中本地化表时回退 key 原文）；
    /// 单独一个标签是为了让 codemod diff 与 parity 扫描能分辨「此处不是字面量」。
    public init(dynamicKey key: String, params: [String] = []) {
        self.init(key, params: params)
    }

    public var isEmpty: Bool { key.isEmpty }

    /// 渲染期解析（Cut 4 / 4b-2 规范入口，与 `L10n.resolve(_:)` 同名、同源）。
    public func resolve(with l10n: L10n) -> String {
        l10n.resolve(self)
    }

    /// 渲染期解析（4a-3b-2b 起的既有入口；`resolve(with:)` 的别名，保留给
    /// 已在用的调用点，避免本次 prep 触碰页面代码）。
    public func resolved(with l10n: L10n) -> String {
        resolve(with: l10n)
    }

    /// 破坏性动作被用户取消时的统一可见文案（Cut 4 / 4b-1）：
    /// 「已取消“%@”，未执行任何更改」。Duplicates / Settings / FaceKeywording /
    /// Similarity 四处此前各自内联同一句；收敛为单一入口后仍只存 key + 参数，
    /// 渲染期由 L10n 解析（切语言后重绘即换文案）。
    /// Culling 的取消句是「已取消：%@」，语义不同，不并入此处。
    public static func cancel(_ action: String) -> LocalizedText {
        LocalizedText("已取消“%@”，未执行任何更改", params: [action])
    }
}

// desktop/native/gather-app/Sources/GatherUI/Support/L10n.swift
// Cut 4 / 4a-0：按"值"而不是进程全局解析文案。
//
// 与 GatherLocalization 的关系：
// - 错误码表仍是 GatherLocalization.errorMessages（179 码唯一来源，不复制）；
// - Delivery P2 的 11 个码不在协议枚举内，单独在 DeliveryErrorPresentation；
//   resolvedTemplate 同时查这两张表（查询顺序：errorMessages → delivery → 冒号尾参）；
// - 双形态解析（CODE::p1::p2 / CODE: 散文）与"插值在本地化之后"的语义与
//   旧 GatherLocalization 出口（B03 已删）逐条一致，但语言由本值的 language
//   决定，不读进程级 appLanguage——切语言时已渲染的 View 直接换 L10n 即可；
// - 不新增可变全局：只有两只不可变的 .lproj Bundle 缓存（与既有实现同因）。
//
// Cut 4 / 4b-2-prep：本文件补上 codemod（1,481 处 l() → l10n）需要的三件事——
//   1. 字符串缓存：按 (language, key) 分键、NSLock 保护，查表结果不再每帧
//      重走 Bundle.localizedString（审计 §3.5 R7）；
//   2. 变参入口：`l10n(key, args)` / `l10n.format(key, args)`，把
//      `String(format: l(key), args)` 收敛成一次调用；
//   3. 参数类型安全的渲染：%lld/%d 与 %@ 按**实参类型**自动配对、裸 % 转义、
//      无参不进 String(format:)，机械替换后不会因类型错配在运行时崩溃。
import Foundation
import GatherProtocol
import os

// MARK: - 字符串缓存（Cut 4 / 4b-2-prep）

/// 本地化字符串缓存：键 =（语言, key），值 = 该语言下的最终文案
/// （未命中时就是 key 原文，负缓存同样生效，不会重复查一个不存在的 key）。
///
/// 为什么需要：`GatherLocalization.l` 每次调用都走 `Bundle.localizedString`
/// （bundle 有缓存，字符串没有）。codemod 后调用次数不变（网格每帧数百次），
/// 这里把「查表结果」缓存下来。
///
/// 为什么按语言分键：一张缓存同时服务 zh/en。语言只出现在键里，**不**缓存
/// "当前语言"——否则切语言后会读到另一种语言的旧值（4a 的核心教训：文案必须
/// 在渲染期按显式语言解析）。
///
/// 线程模型：唯一可变状态（storage/hits/misses/evictions）收在
/// `OSAllocatedUnfairLock<State>` 里，读/写/查表都在 `withLock` 临界区内；
/// `make` 也在锁内执行（只是一次 Bundle 查询，无重入风险），避免同一 key
/// 并发未命中时重复查表、也避免计数错乱。
///
/// 为什么是 os 的互斥锁而不是 NSLock：Swift 6 里「NSLock + 可变字典」的盒子
/// 必须标 `@unchecked Sendable`（本仓 AppLanguageStorage 等的历史写法），会撞
/// `scripts/check-cleanup-ratchet.sh` 的 unchecked_sendable 指标；
/// `OSAllocatedUnfairLock`（macOS 13+）是 SDK 自带 Sendable 的互斥锁，语义
/// 等同（os_unfair_lock，不可重入、无超时），本类因此可以无条件下 `Sendable`，
/// 不需要任何 unsafe 逃生舱。
final class L10nStringCache: Sendable {
    /// 命中/未命中/淘汰统计（`@testable` 测试断言用；生产只写不读）。
    struct Stats: Equatable, Sendable {
        var hits = 0
        var misses = 0
        var evictions = 0
        var count = 0
    }

    private struct Key: Hashable {
        let language: L10n.Language
        let key: String
    }

    /// 锁内状态：全是值类型，可安全地交给锁保管。
    private struct State: Sendable {
        var storage: [Key: String] = [:]
        var hits = 0
        var misses = 0
        var evictions = 0
    }

    /// 进程级共享缓存：`LanguageStore.l10n` / 页面里的 `L10n(language:)`
    /// 是每次渲染都新建的值，缓存必须是共享的才有意义。
    static let shared = L10nStringCache()

    /// 条目上限：≈3 倍 en 表条目（1,313）。正常界面不会触顶；动态 key 若把
    /// 用户文本当 key 使用，触顶时整体清空，保证内存有界（O(1) 淘汰）。
    private let limit: Int
    private let state: OSAllocatedUnfairLock<State>

    init(limit: Int = 4096) {
        self.limit = limit
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    var stats: Stats {
        state.withLock { state in
            Stats(
                hits: state.hits,
                misses: state.misses,
                evictions: state.evictions,
                count: state.storage.count
            )
        }
    }

    func value(for key: String, language: L10n.Language, make: @Sendable () -> String) -> String {
        let cacheKey = Key(language: language, key: key)
        return state.withLock { state in
            if let cached = state.storage[cacheKey] {
                state.hits += 1
                return cached
            }
            state.misses += 1
            let value = make()
            if state.storage.count >= limit {
                state.storage.removeAll(keepingCapacity: true)
                state.evictions += 1
            }
            state.storage[cacheKey] = value
            return value
        }
    }
}

public struct L10n: Equatable, Sendable {
    /// 支持的语言；rawValue 与 settings.ui_language 的持久化值一致。
    public enum Language: String, CaseIterable, Sendable {
        case zhCN = "zh-CN"
        case en = "en"

        /// 日期/数字格式化 locale（与 GatherLocalization.appLanguage 派生的 locale 同语义）。
        public var locale: Locale {
            Locale(identifier: self == .zhCN ? "zh_CN" : "en_US")
        }

        /// 宽松解析：zh* → zh-CN，en* → en，其余 nil（调用方决定回退）。
        public static func parse(_ raw: String) -> Language? {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.hasPrefix("zh") { return .zhCN }
            if normalized.hasPrefix("en") { return .en }
            return nil
        }

        /// 非可选初始化：未识别值回退默认本地化语言（与 Package defaultLocalization 一致）。
        public init(rawLanguage: String) {
            self = Language.parse(rawLanguage) ?? .zhCN
        }
    }

    /// 未知错误码的统一回退 key（en 表已收录，见 Localizable.strings）。
    public static let unknownErrorKey = "发生未知错误，请稍后重试"

    /// 未知进度相位的回退 key（en 表已收录）。
    public static let unknownPhaseKey = "正在处理…"

    public let language: Language

    /// 查表结果缓存（4b-2-prep）：同一 (language, key) 只查一次 Bundle。
    /// 生产恒为 `L10nStringCache.shared`；测试可注入独立实例（见 init(language:cache:)）。
    private let cache: L10nStringCache

    public init(language: Language) {
        self.init(language: language, cache: .shared)
    }

    public init(rawLanguage: String) {
        self.init(language: Language(rawLanguage: rawLanguage))
    }

    /// 注入缓存的初始化（internal）：只有测试会传独立实例，生产一律 shared。
    init(language: Language, cache: L10nStringCache) {
        self.language = language
        self.cache = cache
    }

    /// 相等性只取决于语言（与 4a 相同；缓存实例不参与语义）。
    public static func == (lhs: L10n, rhs: L10n) -> Bool {
        lhs.language == rhs.language
    }

    public var locale: Locale { language.locale }
    public var isChinese: Bool { language == .zhCN }

    // MARK: - 查表

    /// 裸文案：zh 表留空（key 即中文）→ 未命中回退 key；en 表未翻译的 key 同样回退 key。
    /// 结果按 (language, key) 缓存；空 key 直接返回空串（不占缓存）。
    ///
    /// key 可以是源码字面量，也可以是**运行时变量**（4b-2 的 15 处动态 key：
    /// 设置目录的 zhLabel/zhDesc、菜单的显隐标题等）——两种形态走同一条查表路径，
    /// 未命中的动态 key 原样返回，不抛错、不崩溃。
    public func callAsFunction(_ key: String) -> String {
        lookup(key)
    }

    /// 带格式参数的查表（4b-2 的第二种写法：`l10n(key, n)`，key 可含占位符）。
    /// 语义与 `format(_:_:)` 完全相同，二选一只看调用点可读性。
    public func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, arguments: arguments)
    }

    /// 带格式参数的文案（对应 4b 要替换的 `String(format: l(key), args)`）。
    ///
    /// 与旧写法 `String(format: l(key), arguments: args)` 的差异：
    /// 1. **按实参类型**规范化格式串：String 参数遇到 `%lld/%d` → `%@`；
    ///    整数参数遇到 `%@` → `%lld`；`%s/%c/%p` 一律降到 `%@`。旧写法
    ///    下类型错配会读错寄存器/把整数当指针，直接崩溃（审计 §3.5 R2）；
    /// 2. **无参不进入 String(format:)**：模板里可能有裸 `%`（"完成度 100%"、
    ///    路径、正则），无参时原样返回本地化结果（占位符保留）；
    /// 3. 有参但模板里没有可配对的转换符时同样原样返回（不对 `%%` 做二次折叠）。
    ///
    /// 刻意**不传 locale**（不用 `String(format:locale:arguments:)`）：传 locale
    /// 会让 Foundation 给所有整数补千分位（`%lld` 12847 → "12,847"），而现有
    /// 1,481 处 `String(format: l(…))` 都是非 locale 输出（`IndexHeaderCopyTests`
    /// 断言 "已索引 12847 张照片"）。codemod 必须**逐字中性**，否则每页都会文案
    /// 回归。zh/en 共用小数点，locale 对小数没有实际差别；真要千分位或多语言
    /// 小数，单列 Cut 5 统一做并同步改断言。
    public func format(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, arguments: arguments)
    }

    // MARK: - 计数文案（R5-P1-2：英文单复数）

    /// 单数模板 key 后缀：base key 是复数（other）模板，key + "#one" 是单数
    /// （one）模板。zh 表不登记 #one（中文无复数），查不到时回退 base 原文。
    public static let pluralOneSuffix = "#one"

    /// 计数文案：count == 1 用单数模板，其余用复数模板；额外参数（如 "%@ · %lld
    /// 张照片" 里的 %@）放在 count 之前传入。词形选择在查表之前完成，计数本身
    /// 仍走 format 的类型安全插值（不引入千分位）。
    public func plural(_ key: String, count: Int, _ arguments: CVarArg...) -> String {
        formatted(pluralTemplate(for: key, count: count), arguments: arguments + [count])
    }

    /// 选择单复数模板。单数条目缺失（或 zh 表未登记）时回退 base key，
    /// 保证未登记 plural 的模板行为与 format 完全一致。
    func pluralTemplate(for key: String, count: Int) -> String {
        guard count == 1 else { return lookup(key) }
        let oneKey = key + Self.pluralOneSuffix
        let one = lookup(oneKey)
        return one == oneKey ? lookup(key) : one
    }

    /// 延迟文案的便捷渲染（4b-2）：key 可字面量可变量，params 是字符串参数。
    /// 与 `resolve(LocalizedText)` 同源（`%lld/%d` 归一成 `%@` 后按序插入）。
    public func resolvedTemplate(_ key: String, params: [String]) -> String {
        resolve(LocalizedText(key, params: params))
    }

    private func formatted(_ key: String, arguments: [CVarArg]) -> String {
        let template = lookup(key)
        guard !arguments.isEmpty else { return template }
        guard let rendered = Self.render(template: template, arguments: arguments) else {
            return template
        }
        return rendered
    }

    /// 查表 + 缓存：本文件所有文案出口（含 errorText / job* / resolve）都经它，
    /// 因此缓存覆盖全部路径，而不是只有裸 `l()` 那一条。
    private func lookup(_ key: String) -> String {
        guard !key.isEmpty else { return "" }
        let language = self.language
        return cache.value(for: key, language: language) {
            guard let bundle = Self.resourceBundle(for: language) else { return key }
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            return value == key ? key : value
        }
    }

    // MARK: - 错误码

    /// 错误码/散文 → 当前语言文案。未知码统一回退"发生未知错误"（与旧出口一致）。
    public func errorText(_ code: String) -> String {
        resolvedTemplate(for: code) ?? self(Self.unknownErrorKey)
    }

    /// 错误载体 → 当前语言文案；params 参与 {{param}} 插值。
    public func errorText(_ error: CommandError) -> String {
        resolvedTemplate(for: error.code, params: error.params) ?? self(Self.unknownErrorKey)
    }

    // MARK: - 任务/进度文案（Cut 4 / 4b-1：非 l() 调用改为渲染期解析）

    /// 任务状态码 → 当前语言文案；未知状态原样返回（与旧出口一致）。
    /// 码表仍单一来源 GatherLocalization.jobStatusKeys（不在 L10n 复制一份）。
    public func jobStatusText(_ status: String) -> String {
        guard let key = GatherLocalization.jobStatusKeys[status] else { return status }
        return self(key)
    }

    /// 任务类型码 → 当前语言文案；未知类型原样返回。
    public func jobTypeText(_ type: String) -> String {
        guard let key = GatherLocalization.jobTypeKeys[type] else { return type }
        return self(key)
    }

    /// 进度相位码 → 当前语言文案；nil/未知相位回退「正在处理…」。
    public func progressPhaseText(_ phase: String?) -> String {
        // 整套交付的相位是带参数的：output.<recipeIndex>/<recipeCount>。
        // 旧实现只查静态码表，`output.2/3` 不在表里 → 任务行恒显示「正在处理…」。
        if let phase, phase.hasPrefix("output.") {
            let numbers = phase.dropFirst("output.".count).split(separator: "/")
            if numbers.count == 2, let index = Int(numbers[0]), let count = Int(numbers[1]) {
                return format("正在交付：第 %lld/%lld 个配方", index, count)
            }
        }
        guard let phase, let key = GatherLocalization.progressPhaseKeys[phase] else {
            return self(Self.unknownPhaseKey)
        }
        return self(key)
    }

    /// 任务错误消息 → 当前语言文案。仅错误码（含 CODE::p / CODE: 散文形）翻译，
    /// 其余（原始诊断/英文不变量）一律回退通用文案；原文只给 tooltip/日志。
    public func jobErrorMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return self(Self.unknownErrorKey) }
        return resolvedTemplate(for: message) ?? self(Self.unknownErrorKey)
    }

    // MARK: - 提示文案（LocalizedText，Cut 4 / 4a-3b-2b）

    /// 延迟本地化文本的渲染入口：先在当前语言表里查 key（未命中回退 key 原文），
    /// 再按模板形态插值。**只在渲染期调用**，VM 只存 key/params。
    ///
    /// 支持两种模板形态（本仓历史文案并存）：
    /// - {{name}}：错误码表模板（GatherLocalization.errorMessages 的写法）；
    /// - %@ / %lld / %d：界面提示模板（en 表沿用 String(format:) 译文）。
    ///
    /// 4b-2-prep：%-模板分支改走与 `format` 相同的规范化渲染——params 是 String，
    /// 所以 `%lld/%d` 一律归一成 `%@`（旧实现同一语义），另外裸 `%` 会被转义、
    /// 缺参补空串、参数与转换符严格配对；不再直接调 `String(format:)`。
    public func resolve(_ text: LocalizedText) -> String {
        guard !text.isEmpty else { return "" }
        let template = text.pluralCount.map { pluralTemplate(for: text.key, count: $0) }
            ?? self(text.key)
        guard !text.params.isEmpty else { return template }
        if template.contains("{{") {
            return Self.interpolate(template, params: text.params)
        }
        guard let rendered = Self.render(template: template, arguments: text.params) else {
            return template
        }
        return rendered
    }

    /// 码 → 已本地化且已插值的模板；不是已知码返回 nil（调用方回退）。
    ///
    /// 形态一 CODE::p1::p2：按 :: 切分，首段查表，其余按序插值。
    /// 形态二 CODE: 散文：首冒号前段查表，冒号后（trim 后非空）作为单参数。
    public func resolvedTemplate(for code: String, params: [String] = []) -> String? {
        let parts = code.components(separatedBy: "::")
        if let template = GatherLocalization.errorMessages[parts[0]] {
            let inline = Array(parts.dropFirst())
            return Self.interpolate(self(template), params: inline + params)
        }
        // Delivery P2 的 11 个码不在 GatherErrorCode（不能进 errorMessages），
        // 由 DeliveryErrorPresentation 提供模板；解析顺序与 errorMessages 相同。
        if let template = DeliveryErrorPresentation.template(for: parts[0]) {
            let inline = Array(parts.dropFirst())
            return Self.interpolate(self(template), params: inline + params)
        }
        guard let colon = code.firstIndex(of: ":") else { return nil }
        let head = String(code[code.startIndex..<colon])
        let tail = String(code[code.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        if let template = DeliveryErrorPresentation.template(for: head) {
            return Self.interpolate(self(template), params: [tail] + params)
        }
        guard let template = GatherLocalization.errorMessages[head] else { return nil }
        return Self.interpolate(self(template), params: [tail] + params)
    }

    /// {{name}} 按出现顺序替换（对空 params 也执行，与已删的旧出口一致：
    /// 未提供参数时占位符替换为空串）。必须在本地化之后调用。
    public static func interpolate(_ template: String, params: [String]) -> String {
        // 错误码表里仍有历史 %@ 模板（B0/K0 新增 11 条）；{{name}} 优先，其次按序替换 %@。
        if !template.contains("{{"), template.contains("%@"), !params.isEmpty {
            var legacy = template
            for param in params {
                guard let range = legacy.range(of: "%@") else { break }
                legacy.replaceSubrange(range, with: param)
            }
            return legacy
        }
        guard template.contains("{{") else { return template }
        var result = template
        var index = 0
        while let range = result.range(of: #"\{\{[a-zA-Z]+\}\}"#, options: .regularExpression) {
            let replacement = index < params.count ? params[index] : ""
            result.replaceSubrange(range, with: replacement)
            index += 1
        }
        return result
    }

    // MARK: - 格式串规范化（Cut 4 / 4b-2-prep）

    /// 一个 `%` 转换说明的解析结果。
    struct Specifier {
        /// flags + width + precision（不含 `%` 与转换符本身）。
        let prefix: String
        /// 转换符（@ d i u x X o f e g a c s p …）。
        let conversion: Character
        /// 含 `*` 宽度/精度：参数个数不固定，无法静态配对（调用方回退原文）。
        let starred: Bool
        /// 转换符之后的下标。
        let end: String.Index
    }

    /// 把「本地化模板 + 实参」渲染成最终文案。
    ///
    /// 返回 nil 表示**不应**进入 `String(format:)`：模板里没有可配对的转换符
    /// （或有无法静态配对的 `*` 宽度）。调用方原样返回模板。
    ///
    /// 关键保证：返回给 `String(format:)` 的格式串只包含两类内容——字面量
    /// （裸 `%` 已转义成 `%%`）与本函数生成的转换符，因此调用方模板里再离谱的
    /// `%` 也不会让 Foundation 崩；每个转换符都与实参类型严格配对。
    static func render(template: String, arguments: [CVarArg]) -> String? {
        var format = ""
        format.reserveCapacity(template.count + 8)
        var canonical: [CVarArg] = []
        canonical.reserveCapacity(arguments.count)
        var index = template.startIndex
        var consumed = false
        while index < template.endIndex {
            let character = template[index]
            guard character == "%" else {
                format.append(character)
                index = template.index(after: index)
                continue
            }
            let next = template.index(after: index)
            guard next < template.endIndex else {
                // 结尾裸 '%'：转义后 Foundation 才当字面量。
                format.append("%%")
                index = next
                continue
            }
            if template[next] == "%" {
                format.append("%%")
                index = template.index(after: next)
                continue
            }
            guard let specifier = parseSpecifier(template, percent: index) else {
                // 非法转换符（"100% 完成" 里的 '%'）：按字面量转义。
                format.append("%%")
                index = next
                continue
            }
            guard !specifier.starred else { return nil }
            let argument: CVarArg? = canonical.count < arguments.count ? arguments[canonical.count] : nil
            let pair = canonicalize(specifier: specifier, argument: argument)
            format.append(pair.format)
            canonical.append(pair.argument)
            consumed = true
            index = specifier.end
        }
        guard consumed else { return nil }
        return String(format: format, arguments: canonical)
    }

    /// 解析 `%` 起始的转换说明；nil = 不是合法转换符（调用方按字面量处理）。
    static func parseSpecifier(_ template: String, percent: String.Index) -> Specifier? {
        var index = template.index(after: percent)
        var prefix = ""
        while index < template.endIndex, "-+ #0'".contains(template[index]) {
            prefix.append(template[index])
            index = template.index(after: index)
        }
        var starred = false
        if index < template.endIndex, template[index] == "*" {
            starred = true
            prefix.append("*")
            index = template.index(after: index)
        } else {
            while index < template.endIndex, isASCIIDigit(template[index]) {
                prefix.append(template[index])
                index = template.index(after: index)
            }
        }
        if index < template.endIndex, template[index] == "." {
            prefix.append(".")
            index = template.index(after: index)
            if index < template.endIndex, template[index] == "*" {
                starred = true
                prefix.append("*")
                index = template.index(after: index)
            } else {
                while index < template.endIndex, isASCIIDigit(template[index]) {
                    prefix.append(template[index])
                    index = template.index(after: index)
                }
            }
        }
        for length in ["hh", "ll", "h", "l", "q", "L", "z", "t", "j"] {
            if template[index...].hasPrefix(length) {
                index = template.index(index, offsetBy: length.count)
                break
            }
        }
        guard index < template.endIndex else { return nil }
        let conversion = template[index]
        guard conversionCharacters.contains(conversion) else { return nil }
        return Specifier(
            prefix: prefix,
            conversion: conversion,
            starred: starred,
            end: template.index(after: index)
        )
    }

    /// 实参的规范化形态（决定用哪个转换符）。
    enum ArgumentKind {
        case text(String)
        case signed(Int64)
        case unsigned(UInt64)
        case floating(Double)
    }

    /// 按动态类型分类实参。顺序有意为之：String 先于 NSNumber（NSString 也是
    /// NSObject），Swift 数值先于 NSNumber（Swift 数值桥接成 NSNumber 会被误判）。
    static func classify(_ argument: CVarArg?) -> ArgumentKind {
        guard let argument else { return .text("") }
        if type(of: argument) is NSNumber.Type, let number = argument as? NSNumber {
            return .text(number.stringValue)
        }
        // Substring/Character 不实现 CVarArg，无法以 any CVarArg 的形式到达这里；
        // 保留这两个 case 会被编译器判定为永远失败的 cast（且是死分支）。调用方
        // 需要先转成 String——format(...) 的形参本来就是 CVarArg。
        switch argument {
        case let value as String: return .text(value)
        case let value as NSString: return .text(value as String)
        case let value as Bool: return .signed(value ? 1 : 0)
        case let value as Int: return .signed(Int64(value))
        case let value as Int8: return .signed(Int64(value))
        case let value as Int16: return .signed(Int64(value))
        case let value as Int32: return .signed(Int64(value))
        case let value as Int64: return .signed(value)
        case let value as UInt: return .unsigned(UInt64(value))
        case let value as UInt8: return .unsigned(UInt64(value))
        case let value as UInt16: return .unsigned(UInt64(value))
        case let value as UInt32: return .unsigned(UInt64(value))
        case let value as UInt64: return .unsigned(value)
        case let value as Double: return .floating(value)
        case let value as Float: return .floating(Double(value))
        default: return .text(String(describing: argument))
        }
    }

    /// 实参类型 + 原转换符 → 配对的（格式串片段, 实参）。
    ///
    /// 换转换符的规则（目标：任何组合都不崩，且常规写法输出逐字不变）：
    /// - 文本 + 任意数值转换符 → `%@`（审计 §3.5 R2 的 "%lld/%d 归一 %@"）；
    /// - 整数 + `%@` → `%@` + NSNumber；整数 + 数值转换符 → `%lld/%llu`；
    /// - 浮点 + 浮点转换符 → 保留原转换符（`%.1f` 等精度不变）；
    /// - 其余（`%c/%s/%p` 等）一律降级成文本输出。
    static func canonicalize(specifier: Specifier, argument: CVarArg?) -> (format: String, argument: CVarArg) {
        // 前缀含 '%'：返回的是可直接拼接进格式串的完整转换说明。
        let lead = "%" + specifier.prefix
        switch classify(argument) {
        case .text(let value):
            return (lead + "@", value as NSString)
        case .signed(let value):
            if floatConversions.contains(specifier.conversion) {
                return (lead + String(specifier.conversion), Double(value))
            }
            if specifier.conversion == "@" {
                return (lead + "@", NSNumber(value: value))
            }
            if unsignedConversions.contains(specifier.conversion) {
                return (lead + "llu", UInt64(bitPattern: value))
            }
            if signedConversions.contains(specifier.conversion) {
                return (lead + "lld", value)
            }
            return (lead + "@", String(value) as NSString)
        case .unsigned(let value):
            if floatConversions.contains(specifier.conversion) {
                return (lead + String(specifier.conversion), Double(value))
            }
            if specifier.conversion == "@" {
                return (lead + "@", NSNumber(value: value))
            }
            if signedConversions.contains(specifier.conversion) {
                return (lead + "lld", Int64(bitPattern: value))
            }
            if unsignedConversions.contains(specifier.conversion) {
                return (lead + "llu", value)
            }
            return (lead + "@", String(value) as NSString)
        case .floating(let value):
            if floatConversions.contains(specifier.conversion) {
                return (lead + String(specifier.conversion), value)
            }
            if specifier.conversion == "@" {
                return (lead + "@", NSNumber(value: value))
            }
            // 浮点配整数转换符：只在能精确落进整数范围时才转（Int64(Double) 对
            // NaN/inf/超范围会 trap——这里必须退化成文本，绝不能崩）。
            let truncated = value.rounded(.towardZero)
            if signedConversions.contains(specifier.conversion),
               let integer = Int64(exactly: truncated) {
                return (lead + "lld", integer)
            }
            if unsignedConversions.contains(specifier.conversion),
               truncated >= 0, let integer = UInt64(exactly: truncated) {
                return (lead + "llu", integer)
            }
            return (lead + "@", String(value) as NSString)
        }
    }

    private static let conversionCharacters: Set<Character> = [
        "@", "d", "D", "i", "u", "U", "x", "X", "o", "O",
        "f", "F", "e", "E", "g", "G", "a", "A", "c", "C", "s", "S", "p",
    ]
    private static let signedConversions: Set<Character> = ["d", "D", "i"]
    private static let unsignedConversions: Set<Character> = ["u", "U", "x", "X", "o", "O"]
    private static let floatConversions: Set<Character> = ["f", "F", "e", "E", "g", "G", "a", "A"]

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }

    // MARK: - 资源

    private static func resourceBundle(for language: Language) -> Bundle? {
        language == .zhCN ? zhHansBundle : enBundle
    }

    private static let zhHansBundle: Bundle? = localizedBundle(named: "zh-hans")
    private static let enBundle: Bundle? = localizedBundle(named: "en")

    private static func localizedBundle(named name: String) -> Bundle? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "lproj") else {
            return nil
        }
        return Bundle(url: url)
    }
}
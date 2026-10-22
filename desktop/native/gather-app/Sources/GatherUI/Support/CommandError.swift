// desktop/native/gather-app/Sources/GatherUI/Support/CommandError.swift
// Cut 4 / 4a-0：错误载体（VM 只搬运码值，渲染期再解析文案）。
//
// 设计约束（docs/cut4-ui-audit.md §2.4）：本类型**不查表、不格式化**——只搬运
// 码值/参数/诊断。任何"发生未知错误"之类的文案都由 L10n 在渲染期决定；这样
// 错误对象与界面语言解耦，切语言不会把旧语言字符串留在 VM 里。
//
// code 的三种形态（与 L10n.resolvedTemplate 的双形态解析同构，§2.1；B03）：
//   "EXPORT_DIR_INVALID"     普通错误码
//   "CODE::p1::p2"           路由参数形态（参数内联在 code 里）
//   "CODE: 散文"              Core description 形态（单冒号 + 参数）
// 都不是已知码时，code 留空、原文进 diagnostic，由 L10n 回退通用文案。
//
// Cut 4 / 4a-3b-2b（政策）：新增第 5 个字段 origin。CommandErrorText 的中文
// 「本地文案」分支只对 VM 本地校验（.localValidation）开放；API/核心/系统错误
// （.api）的中英文散文只进 diagnostic（tooltip/日志），绝不直接上屏。
import Foundation
import GatherProtocol

public struct CommandError: Error, Equatable, Sendable {
    /// 码/诊断的来源：决定渲染期是否允许把 code 当作本地化表 key 上屏。
    public enum Origin: String, Equatable, Sendable {
        /// API / 核心 / 系统错误：code 只可能是错误码表里的码；散文只进诊断。
        case api
        /// VM 本地校验（参数校验、确认门控、范围提示）：code 是本地化表 key。
        case localValidation
    }

    /// 码值或散文诊断；不做拆分（拆分与查表在 L10n）。
    public let code: String
    /// 模板参数（与 GatherLocalization 的 {{field}}/{{expected}} 占位符按序对应）。
    public let params: [String]
    /// 仅日志/tooltip 的诊断原文；不得直接上屏（沿用 GatherError.underlying 约定）。
    public let diagnostic: String
    /// 是否可重试（保守：只有明确的超时/忙状态）。
    public let retryable: Bool
    /// 第 5 字段：来源（渲染政策门槛，见 4a-3b-2b）。
    public let origin: Origin

    public init(
        code: String,
        params: [String] = [],
        diagnostic: String = "",
        retryable: Bool = false,
        origin: Origin = .api
    ) {
        self.code = code
        self.params = params
        self.diagnostic = diagnostic
        self.retryable = retryable
        self.origin = origin
    }

    /// VM 本地校验文案（key 是本地化表 key，中文原文即 key）。
    /// 只有经本入口构造的错误才允许 CommandErrorText 走「本地文案」分支。
    public static func localized(
        _ key: String,
        params: [String] = [],
        diagnostic: String = ""
    ) -> CommandError {
        CommandError(code: key, params: params, diagnostic: diagnostic, origin: .localValidation)
    }

    /// API 边界返回的原始串（码或散文）：已知码保留在 code，散文只进 diagnostic。
    public init(apiText raw: String, diagnostic: String = "") {
        if Self.isKnownErrorCode(raw) {
            self.init(code: raw, diagnostic: diagnostic)
        } else {
            self.init(code: "", diagnostic: diagnostic.isEmpty ? raw : diagnostic)
        }
    }

    /// 任意错误 → 错误载体。只取码/参数/诊断/重试策略，不查表、不格式化。
    public init(_ error: any Error) {
        if let gather = error as? GatherError {
            self.init(
                code: gather.code.rawValue,
                params: Self.orderedParams(gather.params),
                diagnostic: gather.underlying ?? "",
                retryable: gather.retryable
            )
            return
        }
        // SessionServiceError 不满足 LocalizedError，必须先取 gatherCode，
        // 不能走 NSError 桥接（否则码值丢成通用文案，与 APIErrorPresentation 同因）。
        if let session = error as? SessionServiceError {
            self.init(code: session.gatherCode.rawValue)
            return
        }
        // Capture One 桥错误：description 恒为 GatherErrorCode 的 rawValue；
        // scriptFailed 的底层原因只进 diagnostic（4a-3b-2b 政策）。
        if let c1 = error as? CaptureOneBridgeError {
            var diagnostic = ""
            if case .scriptFailed(let message) = c1 { diagnostic = message }
            self.init(code: c1.description, diagnostic: diagnostic)
            return
        }
        if let api = error as? APIError {
            self.init(apiText: api.description)
            return
        }
        if let router = error as? RouterCommandError {
            self.init(apiText: router.message)
            return
        }
        if let bridge = error as? BridgeError {
            self.init(apiText: bridge.description)
            return
        }
        let native = error as NSError
        let message = native.localizedDescription
        if Self.isKnownErrorCode(message) {
            self.init(code: message, diagnostic: "\(native.domain):\(native.code)")
        } else {
            // 中文/英文散文都只进 diagnostic（4a-3b-2b：API 诊断不直接上屏）。
            self.init(code: "", diagnostic: message)
        }
    }

    /// 码形判定：CODE / CODE::p1 / CODE: 参数 的首段是不是 GatherErrorCode。
    /// 只判定"是否已知码"（语言无关），不查文案表、不产出本地化字符串。
    public static func isKnownErrorCode(
        _ raw: String,
        in table: [String: String] = GatherLocalization.errorMessages
    ) -> Bool {
        guard !raw.isEmpty else { return false }
        let head = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? raw
        let code = head.components(separatedBy: "::")[0]
        return table[code] != nil
    }

    /// 「已知码 + 单冒号参数」形态判定：首冒号前段是错误表收录的码，且其后参数
    /// 非空（与 L10n.resolvedTemplate 的第二分支严格同构：同一冒号切分、同样 trim
    /// 后要求非空，故命中即一定可插值）。
    ///
    /// Cut 4 / 4b-1：从 GatherLocalization 移入本类型（审计 §3.4）。它只做码形判定、
    /// 不查文案、不产出本地化字符串，属于错误载体的职责；Library 的码形门槛用它
    /// 兜住 "XMP_CONFIRM_OTHER_SESSION_PENDING: s1"（只认大写 ASCII 时会误判成散文）。
    public static func isParameterizedErrorCode(
        _ raw: String,
        in table: [String: String] = GatherLocalization.errorMessages
    ) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        let head = String(raw[raw.startIndex..<colon])
        guard table[head] != nil else { return false }
        let tail = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return !tail.isEmpty
    }

    /// GatherError.params 是无序字典；固定"模板占位符顺序"的键优先，其余按字典
    /// 键排序，保证同一错误在多次构造后插值结果稳定（避免随机顺序串参数）。
    ///
    /// Cut 4 / 4a-3b-1：按**前缀**匹配（如 Host 侧的 expectedRevision 命中
    /// expected）——否则渲染期插值会把两个版本号串位（旧漏斗根本不插值，
    /// 这个错位此前不可见）。
    static func orderedParams(_ params: [String: String]) -> [String] {
        let preferredKeys = ["field", "reason", "expected", "current", "session", "version", "value", "name", "path"]
        var used: Set<String> = []
        var ordered: [String] = []
        for preferred in preferredKeys {
            // 精确键优先，其次前缀匹配（Host 侧用 expectedRevision/currentRevision）。
            let match = params[preferred] != nil
                ? preferred
                : params.keys.filter { $0.hasPrefix(preferred) }.sorted().first
            guard let match, !used.contains(match), let value = params[match] else { continue }
            used.insert(match)
            ordered.append(value)
        }
        let rest = params.keys
            .filter { !used.contains($0) }
            .sorted()
            .compactMap { params[$0] }
        return ordered + rest
    }
}

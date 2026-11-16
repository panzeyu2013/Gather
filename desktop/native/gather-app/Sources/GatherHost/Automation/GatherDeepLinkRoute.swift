// desktop/native/gather-app/Sources/GatherHost/Automation/GatherDeepLinkRoute.swift
// Wave3 / task-21：URL scheme 的类型化解析（gather://…）。
//
// 已支持：
//   gather://import?file=<path>[&file=…]                  → 新建工作区并导入（旧行为）
//   gather://import?session=<id>[&file=…]                 → 加入已有工作区
//   gather://session/<id>                                 → 打开工作区
//   gather://photo/<id>                                   → 打开照片（宿主解析 session 后落图库）
//
// Wave5 batch5（task-24，复核报告 05 §2 / F3 自动化第二层）新增：
//   gather://rate?session=<id>&photo=<id>[&photo=…]
//                 [&rating=0..5][&label=none|red|orange|yellow|green|blue|pink|purple]
//                 [&pick=keep|reject]                     → 无 UI 直接写评级/色标/保留
//   语义约束：三个判断字段至少给一个；photo 可重复（去重保序，上限 maxRatePhotoIds）；
//   这不是删除/移动等破坏性动作，与 gather://import 一样只写用户显式给的判断值。
//
// 解析结果是类型化 enum（route / invalid）而不是“返回可选数组 + 静默丢弃”：
// 错误有稳定 code（DEEPLINK_*），宿主可日志/提示，测试可逐条断言。
import Foundation

/// 深链目标。
public enum GatherDeepLinkRoute: Equatable, Sendable {
    /// 旧导入语义：以文件集合新建工作区。
    case importFiles(files: [String])
    /// 加入已有工作区（files 非空）；files 为空时退化为 .openSession。
    case importIntoSession(sessionId: String, files: [String])
    case openSession(sessionId: String)
    case openPhoto(photoId: String)
    /// Wave5 batch5：写评级/色标/保留（photoIds 至少 1 个；patch 保证非空）。
    case rate(sessionId: String, photoIds: [String], patch: GatherAutomationDecisionPatch)
}

/// 解析结果（成功/失败都是值）。
public enum GatherDeepLinkParseResult: Equatable, Sendable {
    case route(GatherDeepLinkRoute)
    case invalid(GatherDeepLinkError)
}

/// 深链解析错误（稳定 code；不新增 GatherErrorCode，避免污染错误码表）。
public enum GatherDeepLinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedScheme(String?)
    case unknownHost(String)
    case missingSessionId
    case invalidPhotoId
    case noFiles
    /// Wave5 batch5：gather://rate 没有 photo 参数。
    case missingPhotoIds
    /// Wave5 batch5：gather://rate 的 photo 数量超过上限。
    case tooManyPhotoIds
    /// Wave5 batch5：rating/label/pick 非法或三者全空（reason 是可读原因，失败原因不吞）。
    case invalidDecision(String)

    /// 稳定码（日志/提示用；UI 文案可按码映射，缺省回 description）。
    public var code: String {
        switch self {
        case .unsupportedScheme: return "DEEPLINK_UNSUPPORTED_SCHEME"
        case .unknownHost: return "DEEPLINK_UNKNOWN_HOST"
        case .missingSessionId: return "DEEPLINK_MISSING_SESSION_ID"
        case .invalidPhotoId: return "DEEPLINK_INVALID_PHOTO_ID"
        case .noFiles: return "DEEPLINK_NO_FILES"
        case .missingPhotoIds: return "DEEPLINK_MISSING_PHOTO_ID"
        case .tooManyPhotoIds: return "DEEPLINK_TOO_MANY_PHOTO_IDS"
        case .invalidDecision: return "DEEPLINK_INVALID_DECISION"
        }
    }

    public var description: String {
        switch self {
        case .unsupportedScheme(let scheme):
            return code + ": scheme=" + (scheme ?? "<nil>")
        case .unknownHost(let host):
            return code + ": host=" + host
        case .missingSessionId:
            return code + ": session id is required"
        case .invalidPhotoId:
            return code + ": photo id is empty or too long"
        case .noFiles:
            return code + ": no supported files in url"
        case .missingPhotoIds:
            return code + ": at least one photo id is required"
        case .tooManyPhotoIds:
            return code + ": too many photo ids (max \(GatherDeepLinkParser.maxRatePhotoIds))"
        case .invalidDecision(let reason):
            return code + ": " + reason
        }
    }
}

/// gather:// 解析器（纯函数，可单测；不触网、不读写文件系统，但会调
/// GatherDeepLink.importFiles 做“路径存在 + 扩展名”过滤——这是导入入口既有契约）。
public enum GatherDeepLinkParser {
    /// 与 SessionReference/PhotoAPI 的 id 长度上限一致。
    static let maxIdentifierLength = 128
    /// gather://rate 的 photo 上限：URL 长度约束下的一次合理批量（远小于
    /// culling.batch_update 的 1 万；更大批量应走 Shortcuts/App Intents 的 runtime 面）。
    public static let maxRatePhotoIds = 100

    public static func parse(_ url: URL) -> GatherDeepLinkParseResult {
        if url.isFileURL {
            let files = GatherDeepLink.importFiles(from: url)
            return files.isEmpty ? .invalid(.noFiles) : .route(.importFiles(files: files))
        }
        guard url.scheme?.lowercased() == "gather" else {
            return .invalid(.unsupportedScheme(url.scheme))
        }
        switch (url.host ?? "").lowercased() {
        case "session":
            guard let id = pathIdentifier(url) else {
                return .invalid(.missingSessionId)
            }
            return .route(.openSession(sessionId: id))
        case "photo":
            guard let id = pathIdentifier(url), id.count <= maxIdentifierLength else {
                return .invalid(.invalidPhotoId)
            }
            return .route(.openPhoto(photoId: id))
        case "rate":
            return parseRate(url)
        case "import":
            let files = GatherDeepLink.importFiles(from: url)
            if let sessionId = queryValue(url, name: "session"),
               !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard sessionId.count <= maxIdentifierLength else {
                    return .invalid(.missingSessionId)
                }
                if files.isEmpty {
                    // gather://import?session=<id> 单独出现 = 打开该工作区（编辑器/快捷指令友好）。
                    return .route(.openSession(sessionId: sessionId))
                }
                return .route(.importIntoSession(sessionId: sessionId, files: files))
            }
            guard !files.isEmpty else { return .invalid(.noFiles) }
            return .route(.importFiles(files: files))
        case let host:
            return .invalid(.unknownHost(host))
        }
    }

    /// gather://rate 的解析：session 必填、photo 至少 1 个、判断字段至少 1 个。
    ///
    /// 选择把判断参数校验委托给 GatherAutomationDecisionPatch.parse：URL scheme 与
    /// Shortcuts/App Intents 必须共用同一份归一化（否则两套入口会给出不同的合法值集合）。
    private static func parseRate(_ url: URL) -> GatherDeepLinkParseResult {
        guard let rawSession = queryValue(url, name: "session") else {
            return .invalid(.missingSessionId)
        }
        let sessionId = rawSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, sessionId.count <= maxIdentifierLength else {
            return .invalid(.missingSessionId)
        }
        var seen = Set<String>()
        var photoIds: [String] = []
        for raw in queryValues(url, name: "photo") {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空串 = 没给 photo（与缺参同一语义，DEEPLINK_MISSING_PHOTO_ID）；
            // 只有"给了非空但超长"才是 invalidPhotoId。
            if id.isEmpty { continue }
            guard id.count <= maxIdentifierLength else {
                return .invalid(.invalidPhotoId)
            }
            guard seen.insert(id).inserted else { continue }
            photoIds.append(id)
        }
        guard !photoIds.isEmpty else { return .invalid(.missingPhotoIds) }
        guard photoIds.count <= maxRatePhotoIds else { return .invalid(.tooManyPhotoIds) }
        do {
            let patch = try GatherAutomationDecisionPatch.parse(
                rating: queryValue(url, name: "rating") ?? "",
                label: queryValue(url, name: "label") ?? "",
                pick: queryValue(url, name: "pick") ?? "")
            return .route(.rate(sessionId: sessionId, photoIds: photoIds, patch: patch))
        } catch let error as GatherAutomationError {
            if case .invalidDecision(let reason) = error {
                return .invalid(.invalidDecision(reason))
            }
            return .invalid(.invalidDecision(String(describing: error)))
        } catch {
            return .invalid(.invalidDecision(String(describing: error)))
        }
    }

    /// 快捷入口：成功路由，否则 nil（旧调用点可用）。
    public static func route(_ url: URL) -> GatherDeepLinkRoute? {
        guard case .route(let route) = parse(url) else { return nil }
        return route
    }

    static func pathIdentifier(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxIdentifierLength else { return nil }
        return trimmed
    }

    static func queryValue(_ url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    /// 同名 query 参数的全部取值（顺序保留；gather://rate 支持重复 photo）。
    static func queryValues(_ url: URL, name: String) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == name }
            .compactMap(\.value) ?? []
    }
}

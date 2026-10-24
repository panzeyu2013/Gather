import Foundation

/// 应用级目的地：全局页或工作区页面。
public enum AppRoute: Hashable, Codable, Sendable {
    case dashboard
    case library
    case persons
    case session(sessionId: String, page: SessionPage)

    public var sessionId: String? {
        if case .session(let id, _) = self { return id }
        return nil
    }

    public var page: SessionPage? {
        if case .session(_, let page) = self { return page }
        return nil
    }

    public var isSession: Bool { sessionId != nil }
}

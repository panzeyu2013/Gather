// Native command boundary shared by SwiftUI pages and the legacy bridge tests.
// It deliberately has no WebKit dependency so the app can build without a
// renderer host.
import Foundation
import GatherCore

public struct WebResponse: Codable, Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let data: GatherCore.JSONValue?
    public let error: String?

    public init(id: String, ok: Bool, data: GatherCore.JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
    }
}

public protocol CommandRouter {
    func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue
    func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    )
}

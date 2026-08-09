import Foundation

public enum ProtocolVersion {
    public static let current = 1
}

public protocol GatherProtocolVersioned {
    static var protocolVersion: Int { get }
}

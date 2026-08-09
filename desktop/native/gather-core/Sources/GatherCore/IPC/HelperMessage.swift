import Foundation

public struct HelperRequest: Codable, Equatable {
    public let id: String
    public let command: String
    public let payload: Data?

    public init(id: String, command: String, payload: Data? = nil) {
        self.id = id
        self.command = command
        self.payload = payload
    }
}

public struct HelperResponse: Codable, Equatable {
    public let id: String
    public let ok: Bool
    public let payload: Data?
    public let error: String?

    public init(id: String, ok: Bool, payload: Data? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public enum HelperWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

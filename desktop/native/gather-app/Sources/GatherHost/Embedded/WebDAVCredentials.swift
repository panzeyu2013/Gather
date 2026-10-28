// desktop/native/gather-app/Sources/GatherHost/Embedded/WebDAVCredentials.swift
// WebDAV 凭据与会话传输：密码只进 Keychain（kSecClassInternetPassword），
// 不写 settings、不进日志、不进 job checkpoint。
import Foundation
import Security
import GatherApplication

enum WebDAVKeychainError: Error, CustomStringConvertible {
    case status(OSStatus)

    var description: String {
        switch self {
        case .status(let code): "WEBDAV_KEYCHAIN_FAILED: \(code)"
        }
    }
}

enum WebDAVCredentialStore {
    private static let service = "app.gather.webdav"

    static func save(server: URL, username: String, password: String) throws {
        let base = server.absoluteString
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.host ?? base,
            kSecAttrAccount as String: base + "#" + username,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: "Gather WebDAV",
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw WebDAVKeychainError.status(updateStatus) }
            return
        }
        var create = query
        create.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(create as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw WebDAVKeychainError.status(addStatus) }
    }

    static func password(server: URL, username: String) -> String? {
        let base = server.absoluteString
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.host ?? base,
            kSecAttrAccount as String: base + "#" + username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(server: URL, username: String) {
        let base = server.absoluteString
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.host ?? base,
            kSecAttrAccount as String: base + "#" + username,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// URLSession 实现：不做流式上传（交付文件通常 < 50MB），失败交给 publisher 重试。
struct URLSessionWebDAVTransport: WebDAVTransport {
    private let session: URLSession

    init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    func send(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return WebDAVResponse(status: http.statusCode)
    }
}

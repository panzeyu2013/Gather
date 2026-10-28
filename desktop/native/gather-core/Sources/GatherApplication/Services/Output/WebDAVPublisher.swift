// desktop/native/gather-core/Sources/GatherApplication/Services/Output/WebDAVPublisher.swift
// WebDAV 发布：把交付目录（成片或画廊）上传到用户自备的 WebDAV 服务器。
//
// 设计取舍：
// - 传输层是端口（WebDAVTransport），生产用 URLSession，测试用假实现；
// - 目录用 MKCOL 逐级创建（405 = 已存在，视为成功）；文件用 PUT；
// - 瞬态失败（网络错误/5xx）指数退避重试，401/403 立即中止（凭据问题重试无意义）；
// - 不记录密码、不打印 Authorization 头。
import Foundation
import GatherProtocol

public struct WebDAVConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String
    public var remoteFolder: String

    public init(baseURL: URL, username: String, password: String, remoteFolder: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.remoteFolder = remoteFolder
    }
}

public enum WebDAVMethod: String, Equatable, Sendable {
    case mkcol = "MKCOL"
    case put = "PUT"
}

public struct WebDAVRequest: Equatable, Sendable {
    public var method: WebDAVMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: WebDAVMethod, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct WebDAVResponse: Equatable, Sendable {
    public var status: Int

    public init(status: Int) {
        self.status = status
    }

    public var isSuccess: Bool { (200...299).contains(status) }
    /// 目录已存在（MKCOL 对已存在资源返回 405）。
    public var isAlreadyExists: Bool { status == 405 }
    /// 只有 401 中止整批；403 常见于“目录已存在/无权限”，按单文件失败处理。
    public var isAuthFailure: Bool { status == 401 }
    public var isTransient: Bool { status == 408 || status == 429 || (500...599).contains(status) }
}

public protocol WebDAVTransport: Sendable {
    func send(_ request: WebDAVRequest) async throws -> WebDAVResponse
}

public struct WebDAVPublishFailure: Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct WebDAVPublishResult: Equatable, Sendable {
    public var uploaded: Int
    public var failed: [WebDAVPublishFailure]
    public var remoteRoot: String
    public var abortedOnAuth: Bool

    public init(uploaded: Int, failed: [WebDAVPublishFailure], remoteRoot: String, abortedOnAuth: Bool) {
        self.uploaded = uploaded
        self.failed = failed
        self.remoteRoot = remoteRoot
        self.abortedOnAuth = abortedOnAuth
    }

    public var isSuccess: Bool { failed.isEmpty && !abortedOnAuth }
}

public enum WebDAVError: Error, Equatable, CustomStringConvertible, CodedError {
    case invalidBaseURL(String)
    case localPathMissing(String)
    case noMatchingFiles

    public var code: GatherErrorCode {
        switch self {
        case .invalidBaseURL: .WEBDAV_URL_INVALID
        case .localPathMissing: .WEBDAV_LOCAL_MISSING
        case .noMatchingFiles: .WEBDAV_NO_MATCHING_FILES
        }
    }

    public var description: String {
        switch self {
        case .invalidBaseURL(let value): code.rawValue + ": " + value
        case .localPathMissing(let path): code.rawValue + ": " + path
        case .noMatchingFiles: code.rawValue
        }
    }
}

public final class WebDAVPublisher: Sendable {
    private let transport: any WebDAVTransport
    private let maxAttempts: Int
    /// 重试等待（测试注入 0，生产用指数退避）。
    private let sleep: @Sendable (Int) async -> Void

    public init(
        transport: any WebDAVTransport,
        maxAttempts: Int = 3,
        sleep: @escaping @Sendable (Int) async -> Void = { attempt in
            let nanoseconds = UInt64(max(1, attempt)) * 500_000_000
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
        }
    ) {
        self.transport = transport
        self.maxAttempts = max(1, maxAttempts)
        self.sleep = sleep
    }

    /// 上传本地文件/目录到 <base>/<remoteFolder>。
    public func publish(
        localPath: String,
        configuration: WebDAVConfiguration,
        includePrefixes: [String]? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> WebDAVPublishResult {
        guard configuration.baseURL.scheme?.hasPrefix("http") == true else {
            throw WebDAVError.invalidBaseURL(configuration.baseURL.absoluteString)
        }
        var files = try Self.collectFiles(at: localPath)
        if let includePrefixes, !includePrefixes.isEmpty {
            let normalized = includePrefixes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            files = files.filter { file in
                normalized.contains { file.relative == $0 || file.relative.hasPrefix($0 + "/") }
            }
            // 白名单与目录不匹配时不能“成功上传 0 个文件”：那是静默失败。
            guard !files.isEmpty else { throw WebDAVError.noMatchingFiles }
        }
        let root = Self.joinRemote(configuration.baseURL, configuration.remoteFolder)
        var uploaded = 0
        var failures: [WebDAVPublishFailure] = []
        var directoryCache = Set<String>()

        for (index, file) in files.enumerated() {
            // 取消立即止损：之前 catch 会把取消记成「单文件失败」继续传完剩下的文件，
            // 用户在面板上点取消后服务器仍会收到半套文件。
            try Task.checkCancellation()
            let remoteDirectory = Self.joinRemote(root, (file.relative as NSString).deletingLastPathComponent)
            if !directoryCache.contains(remoteDirectory.path) {
                // 逐级 MKCOL：深层目录的父目录可能不存在（409），一次 MKCOL 深路径会失败。
                switch await ensureDirectoryChain(
                    to: remoteDirectory, configuration: configuration,
                    created: &directoryCache) {
                case .created:
                    break
                case .failed(let reason):
                    failures.append(WebDAVPublishFailure(path: remoteDirectory.path, reason: reason))
                    continue
                case .authFailure:
                    failures.append(WebDAVPublishFailure(
                        path: remoteDirectory.path, reason: "HTTP 401/403"))
                    return WebDAVPublishResult(
                        uploaded: uploaded, failed: failures,
                        remoteRoot: root.path, abortedOnAuth: true)
                }
            }
            let remoteFile = Self.joinRemote(remoteDirectory, (file.relative as NSString).lastPathComponent)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file.local))
                let response = try await putWithRetry(
                    url: remoteFile, data: data, path: file.relative, configuration: configuration)
                if response.isSuccess {
                    uploaded += 1
                    onProgress?(index + 1, files.count)
                } else if response.isAuthFailure {
                    failures.append(WebDAVPublishFailure(path: file.relative, reason: "HTTP \(response.status)"))
                    return WebDAVPublishResult(
                        uploaded: uploaded, failed: failures, remoteRoot: root.path, abortedOnAuth: true)
                } else {
                    failures.append(WebDAVPublishFailure(
                        path: file.relative, reason: "HTTP \(response.status)"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(WebDAVPublishFailure(path: file.relative, reason: String(describing: error)))
            }
        }
        return WebDAVPublishResult(
            uploaded: uploaded, failed: failures, remoteRoot: root.path, abortedOnAuth: false)
    }

    private enum DirectoryResult: Equatable {
        case created
        case authFailure
        case failed(String)
    }

    /// 从 baseURL 逐级建到 target（已存在的层级跳过；失败的层级明确报错）。
    private func ensureDirectoryChain(
        to target: URL,
        configuration: WebDAVConfiguration,
        created: inout Set<String>
    ) async -> DirectoryResult {
        let basePath = configuration.baseURL.pathComponents
        let targetPath = target.pathComponents
        guard targetPath.starts(with: basePath) else {
            let result = await ensureDirectory(target, configuration: configuration)
            if case .created = result { created.insert(target.path) }
            return result
        }
        let steps: [URL] = {
            var urls: [URL] = [configuration.baseURL]
            var url = configuration.baseURL
            for component in targetPath.dropFirst(basePath.count) {
                url.appendPathComponent(component)
                urls.append(url)
            }
            return urls
        }()
        for url in steps where !created.contains(url.path) {
            let result = await ensureDirectory(url, configuration: configuration)
            switch result {
            case .created:
                created.insert(url.path)
            case .authFailure:
                return .authFailure
            case .failed(let reason):
                return .failed(reason)
            }
        }
        return .created
    }

    private func ensureDirectory(
        _ url: URL, configuration: WebDAVConfiguration
    ) async -> DirectoryResult {
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            do {
                let response = try await transport.send(WebDAVRequest(
                    method: .mkcol, url: url,
                    headers: Self.headers(configuration: configuration)))
                if response.isSuccess || response.isAlreadyExists { return .created }
                if response.isAuthFailure { return .authFailure }
                if response.isTransient, attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
                return .failed("HTTP \(response.status)")
            } catch {
                if attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
                return .failed(String(describing: error))
            }
        }
        return .failed("retry exhausted")
    }

    private func putWithRetry(
        url: URL, data: Data, path: String, configuration: WebDAVConfiguration
    ) async throws -> WebDAVResponse {
        var attempt = 0
        var lastError: (any Error)?
        while attempt < maxAttempts {
            attempt += 1
            do {
                let response = try await transport.send(WebDAVRequest(
                    method: .put, url: url,
                    headers: Self.headers(configuration: configuration, contentType: Self.contentType(path)),
                    body: data))
                if response.isSuccess || response.isAuthFailure { return response }
                if response.isTransient, attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
                return response
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
            }
        }
        throw lastError ?? WebDAVError.invalidBaseURL(url.absoluteString)
    }

    // MARK: - 纯函数

    static func headers(
        configuration: WebDAVConfiguration, contentType: String? = nil
    ) -> [String: String] {
        var headers = ["Accept": "*/*"]
        if !configuration.username.isEmpty {
            let token = Data("\(configuration.username):\(configuration.password)".utf8)
                .base64EncodedString()
            headers["Authorization"] = "Basic " + token
        }
        if let contentType { headers["Content-Type"] = contentType }
        return headers
    }

    static func joinRemote(_ base: URL, _ component: String) -> URL {
        let trimmed = component.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return base }
        var url = base
        for part in trimmed.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
        }
        return url
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "tif", "tiff": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    struct LocalFile: Equatable {
        var local: String
        var relative: String
    }

    /// 收集文件（目录递归；单文件时 relative = 文件名）。
    static func collectFiles(at path: String) throws -> [LocalFile] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw WebDAVError.localPathMissing(path)
        }
        if !isDirectory.boolValue {
            return [LocalFile(local: path, relative: (path as NSString).lastPathComponent)]
        }
        // 枚举返回的 URL 可能是 /private/var/...，而调用方给的是 /var/...：
        // 用解析后的 pathComponents 求相对路径，字符串替换会失配并把绝对路径当相对名。
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [LocalFile] = []
        while let url = enumerator.nextObject() as? URL {
            let isDir: Bool
            do {
                isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            } catch {
                isDir = false
            }
            if isDir { continue }
            let components = url.resolvingSymlinksInPath().pathComponents
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            guard !relative.isEmpty else { continue }
            files.append(LocalFile(local: url.path, relative: relative))
        }
        return files.sorted { $0.relative < $1.relative }
    }
}

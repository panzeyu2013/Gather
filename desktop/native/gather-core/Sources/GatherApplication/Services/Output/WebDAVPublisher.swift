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
    /// Wave3：发布前可写探测用（PUT 探针对象后 DELETE 掉，不在服务器留垃圾）。
    case delete = "DELETE"
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
    ///
    /// 分享策略（share != nil = "严格发布模式"）：
    /// - `includePrefixes` 为空时按**交付产物清单**收窄（manifest / share / 联系表 /
    ///   画廊入口 / thumbs），**绝不回退成"上传整个目录"**；
    /// - `allowDownload == false`：`large/` 与成片一律不上传（客户只能看缩略图，
    ///   灯箱按 gallery.js 的 data-thumb 回退）；
    /// - 发布包内额外写一份 `share.json`（createdAt/expiresAt/allowDownload/itemCount），
    ///   proof.js 读它来判断是否过期 —— 不在本地目录里留文件。
    /// share == nil 时保持旧行为（既有测试/旧调用点不变）。
    public func publish(
        localPath: String,
        configuration: WebDAVConfiguration,
        includePrefixes: [String]? = nil,
        share: OutputShareOptions? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> WebDAVPublishResult {
        guard configuration.baseURL.scheme?.hasPrefix("http") == true else {
            throw WebDAVError.invalidBaseURL(configuration.baseURL.absoluteString)
        }
        let strict = share != nil
        let allowDownload = share?.allowDownload ?? true
        var files = try Self.collectFiles(at: localPath)
        if let includePrefixes, !includePrefixes.isEmpty {
            let normalized = includePrefixes.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            files = files.filter { file in
                normalized.contains { file.relative == $0 || file.relative.hasPrefix($0 + "/") }
            }
        } else if strict {
            files = files.filter { Self.isShareArtifact($0.relative, allowDownload: allowDownload) }
        }
        if strict, !allowDownload {
            // 成片目录永不默认上传；不允许下载时 large/ 也不传。
            files = files.filter { !Self.requiresDownload($0.relative) }
        }
        if strict || (includePrefixes?.isEmpty == false) {
            // 白名单与目录不匹配时不能"成功上传 0 个文件"：那是静默失败。
            guard !files.isEmpty else { throw WebDAVError.noMatchingFiles }
        }
        let root = Self.joinRemote(configuration.baseURL, configuration.remoteFolder)
        var uploaded = 0
        var failures: [WebDAVPublishFailure] = []
        var directoryCache = Set<String>()

        // Wave3：严格发布模式先做强校验（到期必须晚于现在 / 口令长度 / 远端子目录）
        // 与"目标可写探测"——网络/凭据问题在传任何文件之前就暴露，并给出分类。
        if let share {
            if let issue = share.validationIssue() {
                let field: String
                switch issue {
                case .expiresAtInvalid, .expiresAtInPast:
                    field = "share.expiresAt"
                case .passwordLengthInvalid:
                    field = "share.password"
                case .remoteSubfolderInvalid:
                    field = "share.remoteSubfolder"
                }
                throw GatherError(
                    code: .EXPORT_PARAMS_INVALID,
                    params: ["field": field, "reason": issue.rawValue])
            }
            switch await probeWritable(root: root, configuration: configuration) {
            case .created:
                break
            case .authFailure:
                return WebDAVPublishResult(
                    uploaded: 0,
                    failed: [WebDAVPublishFailure(path: "write-probe", reason: "HTTP 401/403")],
                    remoteRoot: root.path, abortedOnAuth: true)
            case .failed(let reason):
                return WebDAVPublishResult(
                    uploaded: 0,
                    failed: [WebDAVPublishFailure(path: "write-probe", reason: reason)],
                    remoteRoot: root.path, abortedOnAuth: false)
            }
        }

        // 分享清单：随包上传一份（proof.js 读 expiresAt 决定是否还能提交）。
        if let share {
            let remoteDirectory = root
            switch await ensureDirectoryChain(
                to: remoteDirectory, configuration: configuration, created: &directoryCache) {
            case .created:
                break
            case .failed(let reason):
                failures.append(WebDAVPublishFailure(
                    path: remoteDirectory.path, reason: reason))
            case .authFailure:
                return WebDAVPublishResult(
                    uploaded: uploaded, failed: failures, remoteRoot: root.path, abortedOnAuth: true)
            }
            let shareURL = Self.joinRemote(remoteDirectory, "share.json")
            do {
                let response = try await putWithRetry(
                    url: shareURL,
                    data: Self.shareManifestJSON(share: share, itemCount: files.count),
                    path: "share.json", configuration: configuration)
                if response.isSuccess {
                    uploaded += 1
                } else if response.isAuthFailure {
                    failures.append(WebDAVPublishFailure(
                        path: "share.json", reason: "HTTP \(response.status)"))
                    return WebDAVPublishResult(
                        uploaded: uploaded, failed: failures, remoteRoot: root.path,
                        abortedOnAuth: true)
                } else {
                    // Wave4a-C1（fail-closed）：share.json 写失败时绝不能继续传
                    // 校样页/画廊 —— 否则客户端拿不到口令/到期配置，proof 页会
                    // 退回“无门槛”放行。这里直接中止，整个发布判失败。
                    failures.append(WebDAVPublishFailure(
                        path: "share.json", reason: "HTTP \(response.status)"))
                    return WebDAVPublishResult(
                        uploaded: uploaded, failed: failures,
                        remoteRoot: root.path, abortedOnAuth: false)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(WebDAVPublishFailure(
                    path: "share.json", reason: String(describing: error)))
                return WebDAVPublishResult(
                    uploaded: uploaded, failed: failures,
                    remoteRoot: root.path, abortedOnAuth: false)
            }
        }

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

    /// Wave3：发布前可写探测——在目标目录 PUT 一个随机探针对象再 DELETE。
    ///
    /// 只用 target 根目录：不创建深层子目录（真实上传仍按文件路径逐级 MKCOL），
    /// 探针对象名随机，成功路径上服务器不留垃圾；失败分类与上传一致
    /// （authFailure = 401/403，failed = HTTP 状态或网络错误描述）。
    private func probeWritable(
        root: URL, configuration: WebDAVConfiguration
    ) async -> DirectoryResult {
        var created = Set<String>()
        switch await ensureDirectoryChain(
            to: root, configuration: configuration, created: &created) {
        case .authFailure:
            return .authFailure
        case .failed(let reason):
            return .failed(reason)
        case .created:
            break
        }
        let probeName = ".gather-write-probe-" + UUID().uuidString.lowercased() + ".txt"
        let probeURL = Self.joinRemote(root, probeName)
        do {
            let response = try await putWithRetry(
                url: probeURL, data: Data("gather".utf8),
                path: probeName, configuration: configuration)
            if response.isAuthFailure { return .authFailure }
            guard response.isSuccess else { return .failed("HTTP \(response.status)") }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch {
            return .failed(String(describing: error))
        }
        do {
            let response = try await transport.send(WebDAVRequest(
                method: .delete, url: probeURL,
                headers: Self.headers(configuration: configuration)))
            // 探针删除失败不阻塞发布（对象名随机、无内容），只记录；404 = 已被服务器清理。
            if !response.isSuccess && !response.isAuthFailure && response.status != 404 {
                GatherLogger.log(
                    "webdav write-probe cleanup HTTP \(response.status)", level: .warn)
            }
        } catch {
            GatherLogger.log(
                "webdav write-probe cleanup failed: \(error)", level: .warn)
        }
        return .created
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

    /// 白名单外的文件不得因为"前缀匹配不上"而回落成整目录上传。
    ///
    /// 严格模式（有分享策略）下只认这些交付产物：
    /// - 任意层级的 `thumbs/` 图片；
    /// - `large/` 图片（仅 allowDownload）；
    /// - 根层/画廊层的 manifest / share / 联系表 / 画廊入口（html/css/js/json/pdf）。
    public static func isShareArtifact(_ relative: String, allowDownload: Bool) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let parents = parts.dropLast()
        if parents.contains("thumbs") {
            return ["jpg", "jpeg", "png", "webp"].contains(ext)
        }
        if parents.contains("large") {
            return allowDownload && ["jpg", "jpeg", "png", "webp"].contains(ext)
        }
        guard ["html", "css", "js", "json", "pdf"].contains(ext) else { return false }
        // Wave4b：manifest-* 永不进分享产物（含本机绝对路径/审计信息；白名单缺失时
        // 也绝不能把它当"可公开产物"上传）。share.json / 联系表仍属于分享产物。
        if name == "share.json" || name.hasPrefix("contact-sheet-") {
            return true
        }
        let galleryLevel = parents.isEmpty || parents == ["gallery"]
        guard galleryLevel else { return false }
        return ["index.html", "gallery.css", "gallery.js", "data.json", "proof.html", "proof.js"]
            .contains(name)
    }

    /// 需要"允许下载"才能发布的文件：大图与成片（thumbs 之外的一切图片）。
    public static func requiresDownload(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "webp", "tif", "tiff"].contains(ext) else { return false }
        return !parts.dropLast().contains("thumbs")
    }

    /// 随包上传的 share.json（proof.js 读它显示/禁用过期提交）。
    public static func shareManifestJSON(
        share: OutputShareOptions, itemCount: Int, createdAt: String? = nil
    ) -> Data {
        // Wave3：WebDAV 与 S3 共用一份实现（字段只增不改；无口令时不写口令字段）。
        OutputShareManifest.json(share: share, itemCount: itemCount, createdAt: createdAt)
    }

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

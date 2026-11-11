// desktop/native/gather-core/Sources/GatherApplication/Services/Output/S3ShareTransport.swift
// Wave3：S3 兼容对象存储发布（SigV4 头签名；纯逻辑 + 可注入 HTTP 传输，单测不连网络）。
//
// 边界与安全：
// - 只做对象写入（PUT）/清理（DELETE），不做分片/预签名 URL；
// - 对象默认私有：不写 ACL/public-read，不开启公开读；
// - 凭据（accessKeyID/secretAccessKey）由 Host 从 Keychain 查出来，仅在本层内存中使用，
//   不落盘、不进错误串/日志；
// - 失败分类：401/403 → auth（立即中止）；404 → notFound（桶不存在/无权限的典型信号）；
//   408/429/5xx 与网络错误 → 可重试；其余 4xx → 单文件失败。
import CryptoKit
import Foundation
import GatherProtocol

/// S3 HTTP 层（可在单测里注入假实现）。
public protocol S3HTTPTransport: Sendable {
    func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse
}

public struct S3HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct S3HTTPResponse: Equatable, Sendable {
    public var status: Int

    public init(status: Int) {
        self.status = status
    }

    public var isSuccess: Bool { (200...299).contains(status) }
    public var isAuthFailure: Bool { status == 401 || status == 403 }
    public var isNotFound: Bool { status == 404 }
    public var isTransient: Bool { status == 408 || status == 429 || (500...599).contains(status) }
}

/// 生产实现：URLSession（macOS Foundation）。不改全局 URLSession 配置。
public struct URLSessionS3HTTPTransport: S3HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    public func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return S3HTTPResponse(status: http.statusCode)
    }
}

/// AWS Signature Version 4（S3 服务；纯逻辑，固定向量可测）。
public enum S3SigV4 {
    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let service = "s3"
    /// 需要参与签名的头（顺序在实现里排序；Content-Type 不上签）。
    public static let signedHeaderNames = ["host", "x-amz-content-sha256", "x-amz-date"]

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// 派生签名密钥：kSecret → kDate → kRegion → kService → kSigning。
    public static func signingKey(
        secretAccessKey: String, date: String, region: String, service: String = S3SigV4.service
    ) -> Data {
        var key = hmacSHA256(
            key: Data("AWS4\(secretAccessKey)".utf8), data: Data(date.utf8))
        key = hmacSHA256(key: key, data: Data(region.utf8))
        key = hmacSHA256(key: key, data: Data(service.utf8))
        return hmacSHA256(key: key, data: Data("aws4_request".utf8))
    }

    public static func scope(date: String, region: String, service: String = S3SigV4.service) -> String {
        "\(date)/\(region)/\(service)/aws4_request"
    }

    public static func canonicalRequest(
        method: String,
        canonicalURI: String,
        canonicalQueryString: String = "",
        headers: [String: String],
        signedHeaders: [String] = signedHeaderNames,
        payloadHash: String
    ) -> String {
        let names = signedHeaders.map { $0.lowercased() }.sorted()
        let canonicalHeaders = names.map { name in
            let value = canonicalHeaderValue(headers[name] ?? "")
            return "\(name):\(value)\n"
        }.joined()
        return [
            method.uppercased(), canonicalURI, canonicalQueryString,
            canonicalHeaders, names.joined(separator: ";"), payloadHash,
        ].joined(separator: "\n")
    }

    /// AWS SigV4 canonical header 值归一：去首尾空白 + 连续空白折叠成单个空格。
    ///
    /// 规范要求对每个参与签名的 header 做 trim + 顺序空白压缩；我们自己的请求头
    /// 都不含内部空白，但公开的签名 API 必须按规范归一，否则外部调用方传入
    /// 带多余空白的值会出现「本地能签、服务器拒签」的隐蔽不一致。
    public static func canonicalHeaderValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = ""
        var pendingSpace = false
        for character in trimmed {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                pendingSpace = true
                continue
            }
            if pendingSpace, !output.isEmpty { output.append(" ") }
            pendingSpace = false
            output.append(character)
        }
        return output
    }

    public static func stringToSign(
        timestamp: String, scope: String, canonicalRequestHash: String
    ) -> String {
        [algorithm, timestamp, scope, canonicalRequestHash].joined(separator: "\n")
    }

    /// 完整签名（hex）。
    public static func signature(
        secretAccessKey: String,
        date: String,
        region: String,
        timestamp: String,
        method: String,
        canonicalURI: String,
        headers: [String: String],
        signedHeaders: [String] = signedHeaderNames,
        payloadHash: String,
        service: String = S3SigV4.service
    ) -> String {
        let request = canonicalRequest(
            method: method, canonicalURI: canonicalURI, headers: headers,
            signedHeaders: signedHeaders, payloadHash: payloadHash)
        let requestHash = sha256Hex(Data(request.utf8))
        let toSign = stringToSign(
            timestamp: timestamp, scope: scope(date: date, region: region, service: service),
            canonicalRequestHash: requestHash)
        let signingKey = signingKey(
            secretAccessKey: secretAccessKey, date: date, region: region, service: service)
        return hmacSHA256(key: signingKey, data: Data(toSign.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func authorizationHeader(
        accessKeyID: String, scope: String, signature: String,
        signedHeaders: [String] = signedHeaderNames
    ) -> String {
        let names = signedHeaders.map { $0.lowercased() }.sorted().joined(separator: ";")
        return "\(algorithm) Credential=\(accessKeyID)/\(scope), "
            + "SignedHeaders=\(names), Signature=\(signature)"
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    public static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

public struct S3Configuration: Equatable, Sendable {
    public var endpoint: String
    public var bucket: String
    public var region: String?
    public var accessKeyID: String
    public var secretAccessKey: String
    public var keyPrefix: String
    /// 可选 STS/Session Token；存在时作为 x-amz-security-token 交给签名。
    public var sessionToken: String?

    public init(
        endpoint: String, bucket: String, region: String?,
        accessKeyID: String, secretAccessKey: String, keyPrefix: String,
        sessionToken: String? = nil
    ) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.keyPrefix = keyPrefix
        self.sessionToken = sessionToken
    }
}

public final class S3ShareTransport: OutputShareTransport {
    public let kind: OutputShareTransportKind = .s3
    private let transport: any S3HTTPTransport
    private let maxAttempts: Int
    private let sleep: @Sendable (Int) async -> Void

    public init(
        transport: any S3HTTPTransport = URLSessionS3HTTPTransport(),
        maxAttempts: Int = 3,
        sleep: @escaping @Sendable (Int) async -> Void = { attempt in
            let nanoseconds = UInt64(max(1, attempt)) * 500_000_000
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
        }
    ) {
        self.transport = transport
        self.maxAttempts = max(1, maxAttempts)
        self.sleep = sleep
    }

    public func publish(
        _ request: OutputSharePublishRequest,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> OutputSharePublishResult {
        let configuration = try Self.configuration(from: request)
        // 与 WebDAV 同一口径的发布前强校验（LiveExportAPI 直接走本通道时也必须拦）。
        if let share = request.share, let issue = share.validationIssue() {
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
        guard let prefix = S3ShareAddressing.sanitizedKeyPrefix(configuration.keyPrefix) else {
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "remoteFolder", "reason": "pathTraversal"])
        }
        let strict = request.share != nil
        let allowDownload = request.share?.allowDownload ?? true
        var files = try WebDAVPublisher.collectFiles(at: request.localPath)
        if let includePrefixes = request.includePrefixes, !includePrefixes.isEmpty {
            let normalized = includePrefixes.map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            files = files.filter { file in
                normalized.contains { file.relative == $0 || file.relative.hasPrefix($0 + "/") }
            }
        } else if strict {
            files = files.filter {
                WebDAVPublisher.isShareArtifact($0.relative, allowDownload: allowDownload)
            }
        }
        if strict {
            files = files.filter { !WebDAVPublisher.requiresDownload($0.relative) || allowDownload }
        }
        if strict || (request.includePrefixes?.isEmpty == false) {
            guard !files.isEmpty else {
                throw GatherError(
                    code: .EXPORT_PARAMS_INVALID,
                    params: ["field": "includePrefixes", "reason": "noMatchingFiles"])
            }
        }
        let rootLabel = Self.rootLabel(configuration)
        var uploaded = 0
        var failures: [OutputSharePublishFailure] = []

        // 发布前可写探测：PUT/DELETE 一个随机探针对象；失败分类后再决定是否继续。
        switch await probe(configuration: configuration, prefix: prefix) {
        case .ok:
            break
        case .auth:
            return OutputSharePublishResult(
                uploaded: 0,
                failed: [OutputSharePublishFailure(
                    path: "write-probe", reason: "HTTP 401/403")],
                remoteRoot: rootLabel, abortedOnAuth: true)
        case .failed(let reason):
            return OutputSharePublishResult(
                uploaded: 0,
                failed: [OutputSharePublishFailure(path: "write-probe", reason: reason)],
                remoteRoot: rootLabel, abortedOnAuth: false)
        }

        // 分享清单：随包上传（proof.js 读 expiresAt/口令哈希）。
        if let share = request.share {
            let key = Self.joinKey(prefix, "share.json")
            let data = OutputShareManifest.json(share: share, itemCount: files.count)
            do {
                let response = try await putWithRetry(
                    configuration: configuration, key: key, data: data,
                    contentType: "application/json", path: "share.json")
                if response.isAuthFailure {
                    failures.append(OutputSharePublishFailure(
                        path: "share.json", reason: "HTTP \(response.status)"))
                    return OutputSharePublishResult(
                        uploaded: uploaded, failed: failures,
                        remoteRoot: rootLabel, abortedOnAuth: true)
                }
                if response.isSuccess {
                    uploaded += 1
                } else {
                    // Wave4a-C1（fail-closed）：share.json 写失败即中止，
                    // 不把校样页/画廊传到“无口令/无到期配置”的服务器状态。
                    failures.append(OutputSharePublishFailure(
                        path: "share.json", reason: "HTTP \(response.status)"))
                    return OutputSharePublishResult(
                        uploaded: uploaded, failed: failures,
                        remoteRoot: rootLabel, abortedOnAuth: false)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(OutputSharePublishFailure(
                    path: "share.json", reason: Self.failureReason(for: error)))
                return OutputSharePublishResult(
                    uploaded: uploaded, failed: failures,
                    remoteRoot: rootLabel, abortedOnAuth: false)
            }
        }

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let key = Self.joinKey(prefix, file.relative)
            // Wave4b：本地文件读取失败必须报 LOCAL_IO（不是 NETWORK、不重试），
            // 与真实网络错误分开，避免把"文件没了"误诊成网络抖动。
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file.local))
            } catch {
                failures.append(OutputSharePublishFailure(
                    path: file.relative, reason: Self.localReadFailureReason(error)))
                continue
            }
            do {
                let response = try await putWithRetry(
                    configuration: configuration, key: key,
                    data: data,
                    contentType: WebDAVPublisher.contentType(file.relative),
                    path: file.relative)
                if response.isSuccess {
                    uploaded += 1
                    onProgress?(index + 1, files.count)
                } else if response.isAuthFailure {
                    failures.append(OutputSharePublishFailure(
                        path: file.relative, reason: "HTTP \(response.status)"))
                    return OutputSharePublishResult(
                        uploaded: uploaded, failed: failures,
                        remoteRoot: rootLabel, abortedOnAuth: true)
                } else if response.isNotFound {
                    failures.append(OutputSharePublishFailure(
                        path: file.relative, reason: "HTTP \(response.status)"))
                } else {
                    failures.append(OutputSharePublishFailure(
                        path: file.relative, reason: "HTTP \(response.status)"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(OutputSharePublishFailure(
                    path: file.relative, reason: Self.failureReason(for: error)))
            }
        }
        return OutputSharePublishResult(
            uploaded: uploaded, failed: failures,
            remoteRoot: rootLabel, abortedOnAuth: false)
    }

    // MARK: - 请求构造与重试

    static func configuration(from request: OutputSharePublishRequest) throws -> S3Configuration {
        let bucket = (request.bucket ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "bucket", "reason": "s3BucketMissing"])
        }
        let region = (request.region ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return S3Configuration(
            endpoint: request.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket, region: region.isEmpty ? nil : region,
            accessKeyID: request.accessKeyID, secretAccessKey: request.secret,
            keyPrefix: request.remoteFolder, sessionToken: request.sessionToken)
    }

    private static func rootLabel(_ configuration: S3Configuration) -> String {
        let endpoint = S3ShareAddressing.canonicalEndpoint(
            baseURL: configuration.endpoint, bucket: configuration.bucket,
            region: configuration.region)
        let prefix = S3ShareAddressing.sanitizedKeyPrefix(configuration.keyPrefix) ?? ""
        return prefix.isEmpty ? endpoint : endpoint + "/" + prefix
    }

    private static func joinKey(_ prefix: String, _ relative: String) -> String {
        let normalized = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? normalized : prefix + "/" + normalized
    }

    private func signedRequest(
        configuration: S3Configuration,
        method: String,
        key: String,
        body: Data,
        contentType: String?,
        now: Date = Date()
    ) throws -> S3HTTPRequest {
        guard let address = S3ShareAddressing.address(
            baseURL: configuration.endpoint, bucket: configuration.bucket,
            region: configuration.region, key: key) else {
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "endpoint", "reason": "s3EndpointInvalid"])
        }
        let payloadHash = S3SigV4.sha256Hex(body)
        let timestamp = S3SigV4.timestamp(now)
        let date = S3SigV4.dateStamp(now)
        var headers: [String: String] = [
            "host": address.host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": timestamp,
        ]
        // Wave4a-C4：临时凭据（STS/Session Token）必须显式上送并参与签名；
        // 没有 token 时签名头集合保持旧的三项（旧行为逐字节不变）。
        var signedHeaders = S3SigV4.signedHeaderNames
        if let token = configuration.sessionToken, !token.isEmpty {
            headers["x-amz-security-token"] = token
            signedHeaders.append("x-amz-security-token")
        }
        let effectiveRegion = configuration.region ?? S3ShareAddressing.defaultRegion
        let scope = S3SigV4.scope(date: date, region: effectiveRegion)
        let signature = S3SigV4.signature(
            secretAccessKey: configuration.secretAccessKey,
            date: date, region: effectiveRegion, timestamp: timestamp,
            method: method, canonicalURI: address.canonicalURI,
            headers: headers, signedHeaders: signedHeaders,
            payloadHash: payloadHash)
        var requestHeaders = headers
        requestHeaders["Authorization"] = S3SigV4.authorizationHeader(
            accessKeyID: configuration.accessKeyID, scope: scope,
            signature: signature, signedHeaders: signedHeaders)
        if let contentType { requestHeaders["Content-Type"] = contentType }
        return S3HTTPRequest(
            method: method, url: address.url, headers: requestHeaders, body: body)
    }

    private func putWithRetry(
        configuration: S3Configuration,
        key: String,
        data: Data,
        contentType: String?,
        path: String
    ) async throws -> S3HTTPResponse {
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            do {
                let request = try signedRequest(
                    configuration: configuration, method: "PUT",
                    key: key, body: data, contentType: contentType)
                let response = try await transport.send(request)
                if response.isSuccess || response.isAuthFailure || response.isNotFound {
                    return response
                }
                if response.isTransient, attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch let configError as GatherError {
                // 配置/参数错误（endpoint 非法等）重试无意义，直接抛给调用方分类。
                throw configError
            } catch {
                if attempt < maxAttempts {
                    await sleep(attempt)
                    continue
                }
                throw error
            }
        }
        return S3HTTPResponse(status: 0)
    }

    private enum ProbeResult: Equatable {
        case ok
        case auth
        case failed(String)
    }

    private func probe(
        configuration: S3Configuration, prefix: String
    ) async -> ProbeResult {
        let probeKey = Self.joinKey(
            prefix, ".gather-write-probe-" + UUID().uuidString.lowercased() + ".txt")
        let body = Data("gather".utf8)
        do {
            let putResponse = try await putWithRetry(
                configuration: configuration, key: probeKey,
                data: body, contentType: "text/plain", path: "write-probe")
            if putResponse.isAuthFailure { return .auth }
            if putResponse.isNotFound { return .failed("HTTP 404") }
            guard putResponse.isSuccess else {
                return .failed("HTTP \(putResponse.status)")
            }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch {
            return .failed(Self.failureReason(for: error))
        }
        do {
            let request = try signedRequest(
                configuration: configuration, method: "DELETE",
                key: probeKey, body: Data(), contentType: nil)
            let deleteResponse = try await transport.send(request)
            if !deleteResponse.isSuccess && !deleteResponse.isNotFound {
                GatherLogger.log(
                    "s3 write-probe cleanup HTTP \(deleteResponse.status)", level: .warn)
            }
        } catch {
            GatherLogger.log("s3 write-probe cleanup failed", level: .warn)
        }
        return .ok
    }

    /// 统一错误分类（Wave4b）：配置错误 → INVALID、本地读 → LOCAL_IO、
    /// 其余视为网络/传输错误 → NETWORK（保留真实网络错误，不能被吞成通用失败）。
    static func failureReason(for error: any Error) -> String {
        if let gather = error as? GatherError {
            let reason = gather.params["reason"] ?? ""
            return reason.isEmpty
                ? "INVALID: \(gather.code.rawValue)"
                : "INVALID: \(gather.code.rawValue) (\(reason))"
        }
        if let urlError = error as? URLError {
            return "NETWORK: \(urlError.code.rawValue) \(urlError.localizedDescription)"
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return localReadFailureReason(error)
        }
        return sanitizedNetworkReason(error)
    }

    /// 本地文件读取失败：带 LOCAL_IO 前缀，供分类器映射到 .localIO。
    static func localReadFailureReason(_ error: any Error) -> String {
        "LOCAL_IO: \(String(describing: error))"
    }

    /// 网络错误串只保留错误描述（可能含 URL，但不含 Authorization/secret）。
    private static func sanitizedNetworkReason(_ error: any Error) -> String {
        let text = String(describing: error)
        if text.contains("AWS4-HMAC-SHA256") || text.contains("Signature=") {
            return "NETWORK: request failed"
        }
        return "NETWORK: " + String(text.prefix(240))
    }
}

// desktop/native/gather-core/Sources/GatherApplication/Services/Output/S3ShareTransport.swift
// Wave3：S3 兼容对象存储发布（SigV4 头签名；纯逻辑 + 可注入 HTTP 传输，单测不连网络）。
//
// 边界与安全：
// - 对象写入（PUT）/清理（DELETE）走头签名；Wave5 起额外生成**只读**的
//   query-string 预签名 GET URL（客户入口链接；不写 ACL、不改对象可见性）；
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

    /// 签名密钥派生的中间值（Wave4c：给 AWS 向量做逐步断言）。
    public struct SigningKeySteps: Equatable, Sendable {
        public var dateKey: Data
        public var regionKey: Data
        public var serviceKey: Data
        public var signingKey: Data

        public init(dateKey: Data, regionKey: Data, serviceKey: Data, signingKey: Data) {
            self.dateKey = dateKey
            self.regionKey = regionKey
            self.serviceKey = serviceKey
            self.signingKey = signingKey
        }
    }

    /// 请求校验失败原因（Wave4c：clock skew/重复头等失败用例可测）。
    public enum ValidationFailure: String, Codable, Equatable, Sendable {
        case invalidTimestamp
        case clockSkew
        case emptySignedHeader
        case duplicateSignedHeader
        case uppercaseSignedHeader
    }

    /// 派生签名密钥的每一步：kSecret → kDate → kRegion → kService → kSigning。
    public static func signingKeySteps(
        secretAccessKey: String, date: String, region: String,
        service: String = S3SigV4.service
    ) -> SigningKeySteps {
        let dateKey = hmacSHA256(
            key: Data("AWS4\(secretAccessKey)".utf8), data: Data(date.utf8))
        let regionKey = hmacSHA256(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmacSHA256(key: regionKey, data: Data(service.utf8))
        let signingKey = hmacSHA256(key: serviceKey, data: Data("aws4_request".utf8))
        return SigningKeySteps(
            dateKey: dateKey, regionKey: regionKey,
            serviceKey: serviceKey, signingKey: signingKey)
    }

    /// 派生签名密钥：kSecret → kDate → kRegion → kService → kSigning。
    public static func signingKey(
        secretAccessKey: String, date: String, region: String, service: String = S3SigV4.service
    ) -> Data {
        signingKeySteps(
            secretAccessKey: secretAccessKey, date: date,
            region: region, service: service).signingKey
    }

    /// 签名请求的前置校验：时间戳可解析且在允许偏差内、SignedHeaders 非空/
    /// 小写/无重复。nil = 合法。
    ///
    /// 生产请求的时间戳由本机生成，正常不会失败；该 API 供外部调用方与测试显式
    /// 覆盖 clock skew/重复头等失败用例（而不是让失败在服务器侧才暴露）。
    public static func validationFailure(
        timestamp: String,
        signedHeaders: [String] = signedHeaderNames,
        now: Date = Date(),
        toleranceSeconds: TimeInterval = 900
    ) -> ValidationFailure? {
        if signedHeaders.isEmpty { return .emptySignedHeader }
        var seen = Set<String>()
        for header in signedHeaders {
            if header.isEmpty { return .emptySignedHeader }
            if header != header.lowercased() { return .uppercaseSignedHeader }
            if !seen.insert(header).inserted { return .duplicateSignedHeader }
        }
        guard let parsed = parseTimestamp(timestamp) else { return .invalidTimestamp }
        if abs(parsed.timeIntervalSince(now)) > toleranceSeconds { return .clockSkew }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value)
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

    // MARK: - Wave5：query-string 预签名（GET）

    /// 预签名 GET 的载荷哈希占位符（AWS 规范：预签名 URL 不签 body）。
    static let presignedPayloadHash = "UNSIGNED-PAYLOAD"
    /// SigV4 预签名 URL 的最长有效期（AWS 上限 7 天）。
    static let maximumPresignExpirySeconds = 604_800

    /// 生成 AWS SigV4 **query-string 预签名 GET URL**。
    ///
    /// 与头签名共用 canonical request / 签名密钥实现；差异只在：
    /// - 认证参数全部进 query（X-Amz-Algorithm/Credential/Date/Expires/SignedHeaders，
    ///   临时凭据再追加 X-Amz-Security-Token）；
    /// - SignedHeaders 只有 host，payload 固定 `UNSIGNED-PAYLOAD`；
    /// - 最后追加 X-Amz-Signature。
    ///
    /// 纯函数（除 `now` 外无外部状态，不触网）；无效输入返回 nil，由调用方
    /// 降级成"不提供链接"，绝不生成一个看似可用的坏链接。
    ///
    /// 空间/斜杠等按 RFC 3986 百分号编码（SigV4 口径）：Credential 里的
    /// `/` 必须是 %2F（官方固定向量测试覆盖）。
    ///
    /// 官方示例（GET Object，20130524/us-east-1/86400）：
    /// https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
    static func presignedGETURL(
        url: URL,
        host: String,
        canonicalURI: String,
        accessKeyID: String,
        secretAccessKey: String,
        region: String,
        sessionToken: String? = nil,
        expiresInSeconds: Int,
        now: Date = Date()
    ) -> URL? {
        guard !accessKeyID.isEmpty, !secretAccessKey.isEmpty,
              !host.isEmpty, !region.isEmpty,
              (1...maximumPresignExpirySeconds).contains(expiresInSeconds),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let timestamp = timestamp(now)
        let date = dateStamp(now)
        let credentialScope = scope(date: date, region: region)
        let credential = accessKeyID + "/" + credentialScope
        var query: [(String, String)] = [
            ("X-Amz-Algorithm", algorithm),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", timestamp),
            ("X-Amz-Expires", String(expiresInSeconds)),
        ]
        if let token = sessionToken, !token.isEmpty {
            query.append(("X-Amz-Security-Token", token))
        }
        query.append(("X-Amz-SignedHeaders", "host"))
        // canonical query 必须按参数名排序（同名再按值），并与最终 URL 逐字一致。
        query.sort { $0.0 < $1.0 }
        let canonicalQuery = query
            .map { uriEncode($0.0) + "=" + uriEncode($0.1) }
            .joined(separator: "&")
        let request = canonicalRequest(
            method: "GET",
            canonicalURI: canonicalURI,
            canonicalQueryString: canonicalQuery,
            headers: ["host": host],
            signedHeaders: ["host"],
            payloadHash: presignedPayloadHash)
        let requestHash = sha256Hex(Data(request.utf8))
        let toSign = stringToSign(
            timestamp: timestamp, scope: credentialScope, canonicalRequestHash: requestHash)
        let key = signingKey(secretAccessKey: secretAccessKey, date: date, region: region)
        let signature = hmacSHA256(key: key, data: Data(toSign.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var signed = components
        signed.percentEncodedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        return signed.url
    }

    /// RFC 3986 百分号编码（SigV4 的 URI/query 编码口径：unreserved 之外全部转义）。
    static func uriEncode(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var output = ""
        for byte in value.utf8 {
            let scalar = Character(UnicodeScalar(byte))
            if unreserved.contains(scalar) {
                output.append(scalar)
            } else {
                output += String(format: "%%%02X", Int(byte))
            }
        }
        return output
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
    /// Wave5：预签名客户链接的有效期（24 小时；AWS 预签名上限 7 天）。
    static let entryURLExpiresInSeconds = 86_400

    private let transport: any S3HTTPTransport
    private let maxAttempts: Int
    private let sleep: @Sendable (Int) async -> Void
    /// Wave5：时钟接缝（预签名链接的 X-Amz-Date/Expires 用它，固定向量测试可注入）。
    private let now: @Sendable () -> Date

    public init(
        transport: any S3HTTPTransport = URLSessionS3HTTPTransport(),
        maxAttempts: Int = 3,
        sleep: @escaping @Sendable (Int) async -> Void = { attempt in
            let nanoseconds = UInt64(max(1, attempt)) * 500_000_000
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.maxAttempts = max(1, maxAttempts)
        self.sleep = sleep
        self.now = now
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
        /// Wave5：成功上传的相对路径（只有入口文件真的传上去才给客户链接）。
        var uploadedRelatives = Set<String>()
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
            var data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file.local))
            } catch {
                failures.append(OutputSharePublishFailure(
                    path: file.relative, reason: Self.localReadFailureReason(error)))
                continue
            }
            if request.share != nil {
                data = OutputShareProofPage.declaringSharePolicy(
                    data, relativePath: file.relative)
            }
            do {
                let response = try await putWithRetry(
                    configuration: configuration, key: key,
                    data: data,
                    contentType: WebDAVPublisher.contentType(file.relative),
                    path: file.relative)
                if response.isSuccess {
                    uploaded += 1
                    uploadedRelatives.insert(file.relative)
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
        // Wave5：客户入口 = 画廊 index.html 的预签名 GET（对象仍默认私有；
        // 入口没传成功就不给链接，避免"发布成功但客户打开 404"）。
        let entry = Self.entryLink(
            configuration: configuration, prefix: prefix,
            files: files, uploaded: uploadedRelatives, now: now())
        return OutputSharePublishResult(
            uploaded: uploaded, failed: failures,
            remoteRoot: rootLabel, abortedOnAuth: false,
            entryURL: entry?.url, entryURLExpiresAt: entry?.expiresAt)
    }

    /// Wave5：入口文件 → SigV4 预签名 GET URL + 到期时间（ISO-8601）。
    ///
    /// 只做链接生成：不写 ACL、不改对象可见性、不把 secret 拼进任何字符串。
    private static func entryLink(
        configuration: S3Configuration,
        prefix: String,
        files: [WebDAVPublisher.LocalFile],
        uploaded: Set<String>,
        now: Date
    ) -> (url: String, expiresAt: String)? {
        guard let relative = WebDAVPublisher.entryRelativePath(in: files),
              uploaded.contains(relative) else { return nil }
        let key = joinKey(prefix, relative)
        guard let address = S3ShareAddressing.address(
            baseURL: configuration.endpoint, bucket: configuration.bucket,
            region: configuration.region, key: key) else { return nil }
        let effectiveRegion = configuration.region ?? S3ShareAddressing.defaultRegion
        guard let url = S3SigV4.presignedGETURL(
            url: address.url, host: address.host, canonicalURI: address.canonicalURI,
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            region: effectiveRegion,
            sessionToken: configuration.sessionToken,
            expiresInSeconds: entryURLExpiresInSeconds,
            now: now) else { return nil }
        let expiresAt = now.addingTimeInterval(TimeInterval(entryURLExpiresInSeconds))
        return (url.absoluteString, OutputShareManifest.iso8601Now(expiresAt))
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

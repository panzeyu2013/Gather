// desktop/native/gather-core/Tests/GatherCoreTests/Services/OutputShareTests.swift
// Wave3 / task-17：交付分享（S3 兼容传输 + 口令/到期）的纯逻辑与传输分派测试。
//
// 全部离线：SigV4 固定向量 / PBKDF2 固定向量 / 假 HTTP 传输；
// 不连真实网络、不依赖 Keychain（凭据在测试里直接注入）。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

// MARK: - 假传输

private actor FakeS3Transport: S3HTTPTransport {
    private(set) var requests: [S3HTTPRequest] = []
    private var responses: [Result<S3HTTPResponse, Error>]

    init(_ responses: [Result<S3HTTPResponse, Error>] = []) {
        self.responses = responses
    }

    func send(_ request: S3HTTPRequest) async throws -> S3HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { return S3HTTPResponse(status: 200) }
        switch responses.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

private actor FakeWebDAVTransport: WebDAVTransport {
    private(set) var requests: [WebDAVRequest] = []
    private var responses: [Result<WebDAVResponse, Error>]

    init(_ responses: [Result<WebDAVResponse, Error>] = []) {
        self.responses = responses
    }

    func send(_ request: WebDAVRequest) async throws -> WebDAVResponse {
        requests.append(request)
        guard !responses.isEmpty else { return WebDAVResponse(status: 200) }
        switch responses.removeFirst() {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// 通道分派用的记录型传输（actor 天然 Sendable，不用 @unchecked）。
private actor RecordingShareTransport: OutputShareTransport {
    private(set) var requests: [OutputSharePublishRequest] = []

    func publish(
        _ request: OutputSharePublishRequest,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> OutputSharePublishResult {
        requests.append(request)
        return OutputSharePublishResult(
            uploaded: 1, failed: [], remoteRoot: "fake", abortedOnAuth: false)
    }
}

// MARK: - 测试

@Suite("Wave3 交付分享（S3 传输 / 口令 / 到期）")
struct OutputShareTests {
    private func makeTree() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try Data("index".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("thumb".utf8).write(to: root.appendingPathComponent("thumbs/0001.jpg"))
        return root.path
    }

    private func futureExpiry() -> String {
        OutputShareManifest.iso8601Now(Date().addingTimeInterval(7 * 24 * 3600))
    }

    // MARK: 口令哈希 / 校验（PBKDF2-HMAC-SHA256）

    @Test("PBKDF2-HMAC-SHA256：RFC 8018 固定向量 + 错误口令被拒")
    func pbkdf2VectorsAndVerify() throws {
        let salt = Data("salt".utf8)
        let one = OutputSharePassword.pbkdf2SHA256(
            password: "password", salt: salt, iterations: 1)
        #expect(OutputSharePassword.hex(one)
                == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let two = OutputSharePassword.pbkdf2SHA256(
            password: "password", salt: salt, iterations: 2)
        #expect(OutputSharePassword.hex(two)
                == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")

        let derived = OutputSharePassword.derive(password: "wedding-2026")
        #expect(derived.algorithm == "pbkdf2-sha256")
        #expect(derived.saltHex.count == 32)
        #expect(derived.hashHex.count == 64)
        #expect(derived.iterations == OutputSharePassword.defaultIterations)
        #expect(OutputSharePassword.verify(password: "wedding-2026", derived: derived))
        #expect(!OutputSharePassword.verify(password: "wedding-2027", derived: derived))
        // 盐/哈希的 hex 解析必须拒绝奇数长度与非法字符。
        #expect(OutputSharePassword.data(fromHex: "abc") == nil)
        #expect(OutputSharePassword.data(fromHex: "zz") == nil)
    }

    // MARK: 分享参数强校验

    @Test("到期边界：到期必须晚于现在；格式非法单独报")
    func expiryValidationBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let future = OutputShareOptions(
            expiresAt: formatter.string(from: now.addingTimeInterval(1)))
        #expect(future.validationIssue(now: now) == nil)
        let exact = OutputShareOptions(expiresAt: formatter.string(from: now))
        #expect(exact.validationIssue(now: now) == .expiresAtInPast)
        let past = OutputShareOptions(
            expiresAt: formatter.string(from: now.addingTimeInterval(-60)))
        #expect(past.validationIssue(now: now) == .expiresAtInPast)
        let invalid = OutputShareOptions(expiresAt: "2026-13-01")
        #expect(invalid.validationIssue(now: now) == .expiresAtInvalid)
        let empty = OutputShareOptions(expiresAt: "   ")
        #expect(empty.validationIssue(now: now) == nil)
    }

    @Test("口令长度 4-128；远端目录拒绝绝对路径/穿越/空段")
    func passwordAndSubfolderValidation() {
        #expect(OutputShareOptions(password: "abc").validationIssue() == .passwordLengthInvalid)
        #expect(OutputShareOptions(password: String(repeating: "a", count: 129))
            .validationIssue() == .passwordLengthInvalid)
        #expect(OutputShareOptions(password: "abcd").validationIssue() == nil)
        #expect(OutputShareOptions(remoteSubfolder: "/abs").validationIssue()
            == .remoteSubfolderInvalid)
        #expect(OutputShareOptions(remoteSubfolder: "a/../b").validationIssue()
            == .remoteSubfolderInvalid)
        #expect(OutputShareOptions(remoteSubfolder: "a//b").validationIssue()
            == .remoteSubfolderInvalid)
        #expect(OutputShareOptions(remoteSubfolder: "client/wedding").validationIssue() == nil)
    }

    // MARK: S3 SigV4 纯逻辑

    @Test("SigV4：空载荷哈希 / 签名密钥链 / AWS 文档完整签名向量 / Authorization 头格式")
    func sigV4Vectors() {
        #expect(S3SigV4.sha256Hex(Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // 签名密钥派生（独立参考实现计算：HMAC 链 kSecret→kDate→kRegion→kService→kSigning）。
        let key = S3SigV4.signingKey(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            date: "20130524", region: "us-east-1", service: "s3")
        // 期望值是签名密钥本身的十六进制（不是它的 sha256）：
        // HMAC 链 kSecret→kDate→kRegion→kService→kSigning 的终值。
        let signingKeyHex = key.map { String(format: "%02x", $0) }.joined()
        #expect(signingKeyHex
                == "dbb893acc010964918f1fd433add87c70e8b0db6be30c1fbeafefa5ec6ba8378")

        let headers = [
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": S3SigV4.sha256Hex(Data()),
            "x-amz-date": "20261111T000000Z",
        ]
        let scope = S3SigV4.scope(date: "20261111", region: "us-east-1")
        let signature = S3SigV4.signature(
            secretAccessKey: "secret", date: "20261111", region: "us-east-1",
            timestamp: "20261111T000000Z", method: "PUT",
            canonicalURI: "/test.txt", headers: headers,
            payloadHash: S3SigV4.sha256Hex(Data()))
        #expect(signature.count == 64)
        #expect(signature.allSatisfy { $0.isHexDigit })
        let header = S3SigV4.authorizationHeader(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE", scope: scope, signature: signature)
        #expect(header == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/"
                + "20261111/us-east-1/s3/aws4_request, SignedHeaders="
                + "host;x-amz-content-sha256;x-amz-date, Signature=" + signature)
        // AWS 文档 "Example: GET Object" 完整固定向量（host/range/x-amz-* 参与签名）。
        let awsHeaders = [
            "host": "examplebucket.s3.amazonaws.com",
            "range": "bytes=0-9",
            "x-amz-content-sha256": S3SigV4.sha256Hex(Data()),
            "x-amz-date": "20130524T000000Z",
        ]
        let awsSignature = S3SigV4.signature(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            date: "20130524", region: "us-east-1",
            timestamp: "20130524T000000Z", method: "GET",
            canonicalURI: "/test.txt", headers: awsHeaders,
            signedHeaders: ["host", "range", "x-amz-content-sha256", "x-amz-date"],
            payloadHash: S3SigV4.sha256Hex(Data()))
        #expect(awsSignature
                == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")

        // 同一输入稳定，换载荷/密钥必须变。
        let sameAgain = S3SigV4.signature(
            secretAccessKey: "secret", date: "20261111", region: "us-east-1",
            timestamp: "20261111T000000Z", method: "PUT",
            canonicalURI: "/test.txt", headers: headers,
            payloadHash: S3SigV4.sha256Hex(Data()))
        #expect(sameAgain == signature)
        let different = S3SigV4.signature(
            secretAccessKey: "secret", date: "20261111", region: "us-east-1",
            timestamp: "20261111T000000Z", method: "PUT",
            canonicalURI: "/test.txt", headers: headers,
            payloadHash: S3SigV4.sha256Hex(Data("x".utf8)))
        #expect(different != signature)
    }

    @Test("S3 寻址：显式 endpoint 走 path-style；空 endpoint 走 AWS 虚拟主机默认")
    func s3Addressing() throws {
        let explicit = try #require(S3ShareAddressing.address(
            baseURL: "https://minio.local:9000", bucket: "photos",
            region: "us-east-1", key: "client/wedding/0001.jpg"))
        #expect(explicit.url.absoluteString
                == "https://minio.local:9000/photos/client/wedding/0001.jpg")
        #expect(explicit.host == "minio.local:9000")
        #expect(explicit.canonicalURI == "/photos/client/wedding/0001.jpg")
        #expect(explicit.endpoint == "https://minio.local:9000")

        let derived = try #require(S3ShareAddressing.address(
            baseURL: "", bucket: "photos", region: nil, key: "a b.jpg"))
        #expect(derived.url.absoluteString
                == "https://photos.s3.us-east-1.amazonaws.com/a%20b.jpg")
        #expect(derived.canonicalURI == "/a%20b.jpg")

        #expect(S3ShareAddressing.sanitizedKeyPrefix("/a//b/") == "a/b")
        #expect(S3ShareAddressing.sanitizedKeyPrefix("a/../b") == nil)
        #expect(S3ShareAddressing.sanitizedKeyPrefix("  ") == "")
        #expect(S3ShareAddressing.canonicalEndpoint(
            baseURL: "", bucket: "photos", region: nil)
                == "https://photos.s3.us-east-1.amazonaws.com")
    }

    // MARK: S3 发布

    @Test("S3 发布：先探针后 share.json/文件；Authorization/哈希头正确；manifest 不落明文口令")
    func s3PublishUploadsWithSignedRequests() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        let transport = FakeS3Transport()
        let publisher = S3ShareTransport(transport: transport, sleep: { _ in })
        let share = OutputShareOptions(
            allowDownload: false, expiresAt: futureExpiry(),
            remoteSubfolder: "client/wedding", password: "wedding-pass")
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "",
            accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "TOP-SECRET-KEY",
            remoteFolder: "client/wedding", bucket: "photos", region: nil,
            includePrefixes: ["thumbs"], share: share)
        let result = try await publisher.publish(request, onProgress: nil)
        #expect(result.isSuccess)
        #expect(result.uploaded == 2, "share.json + thumbs/0001.jpg")

        let requests = await transport.requests
        let methods = requests.map(\.method)
        #expect(Array(methods.prefix(2)) == ["PUT", "DELETE"], "先发可写探针，再清理")
        let puts = requests.filter { $0.method == "PUT" }
        #expect(puts.count == 3, "探针 + share.json + 1 个文件")
        for put in puts {
            #expect(put.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=")
                    == true)
            #expect(put.headers["x-amz-content-sha256"] != nil)
            #expect(put.headers["x-amz-date"] != nil)
            #expect(put.headers["host"] != nil)
        }
        let manifestPut = try #require(puts.first {
            $0.url.absoluteString.hasSuffix("/share.json")
        })
        let manifestText = try #require(
            manifestPut.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(manifestText.contains("\"passwordHash\""))
        #expect(manifestText.contains("\"passwordSalt\""))
        #expect(manifestText.contains("\"passwordIterations\""))
        #expect(!manifestText.contains("wedding-pass"), "share.json 绝不能出现明文口令")
        #expect(!manifestText.contains("TOP-SECRET-KEY"), "share.json 绝不能出现 secret")
        #expect(manifestText.contains("client/wedding"))
        // 对象默认私有：不携带 ACL/public-read。
        for put in puts {
            #expect(put.headers["x-amz-acl"] == nil)
        }
    }

    @Test("S3 失败分类：403 立即中止为 auth；404 为 notFound；5xx 可重试")
    func s3FailureClassification() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        // 探针 PUT/DELETE 成功 → share.json 成功 → 文件 PUT 返回 403。
        let authTransport = FakeS3Transport([
            .success(S3HTTPResponse(status: 201)),
            .success(S3HTTPResponse(status: 204)),
            .success(S3HTTPResponse(status: 200)),
            .success(S3HTTPResponse(status: 403)),
        ])
        let authPublisher = S3ShareTransport(transport: authTransport, sleep: { _ in })
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "https://s3.example.com",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let authResult = try await authPublisher.publish(request, onProgress: nil)
        #expect(authResult.abortedOnAuth)
        #expect(authResult.failed.first?.category == .auth)

        // 探针返回 404 → 发布前中止，且分类为目标不存在。
        let notFoundTransport = FakeS3Transport([
            .success(S3HTTPResponse(status: 404)),
        ])
        let notFoundPublisher = S3ShareTransport(transport: notFoundTransport, sleep: { _ in })
        let notFoundResult = try await notFoundPublisher.publish(request, onProgress: nil)
        #expect(!notFoundResult.abortedOnAuth)
        #expect(notFoundResult.uploaded == 0)
        #expect(notFoundResult.failed.first?.category == .notFound)

        // 探针 503 → 503 → 201：按可重试语义成功。
        let retryTransport = FakeS3Transport([
            .success(S3HTTPResponse(status: 503)),
            .success(S3HTTPResponse(status: 201)),
            .success(S3HTTPResponse(status: 204)),
            .success(S3HTTPResponse(status: 200)),
            .success(S3HTTPResponse(status: 200)),
        ])
        let retryPublisher = S3ShareTransport(transport: retryTransport, sleep: { _ in })
        let retryResult = try await retryPublisher.publish(request, onProgress: nil)
        #expect(retryResult.isSuccess, "503 应重试而不是立刻失败")
        #expect(retryResult.uploaded == 2)
    }

    // MARK: 通道分派

    @Test("OutputSharePublisher：按 transport 分派；分享参数非法/缺 bucket 时拒绝")
    func publisherDispatchesAndValidates() async throws {
        let webdav = RecordingShareTransport()
        let s3 = RecordingShareTransport()
        let publisher = OutputSharePublisher(transports: [.webdav: webdav, .s3: s3])
        let request = OutputSharePublishRequest(
            localPath: "/tmp", transport: .s3, endpoint: "",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: nil, includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        _ = try await publisher.publish(request, onProgress: nil)
        #expect(await s3.requests.count == 1)
        #expect(await webdav.requests.isEmpty)

        var pastRequest = request
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        pastRequest.share = OutputShareOptions(
            expiresAt: formatter.string(from: Date().addingTimeInterval(-3600)))
        do {
            _ = try await publisher.publish(pastRequest, onProgress: nil)
            Issue.record("过期时间必须被拒绝")
        } catch let error as GatherError {
            #expect(error.params["field"] == "share.expiresAt")
            #expect(error.params["reason"] == "expiresAtInPast")
        }

        var missingBucket = request
        missingBucket.bucket = "  "
        do {
            _ = try await publisher.publish(missingBucket, onProgress: nil)
            Issue.record("S3 缺 bucket 必须被拒绝")
        } catch let error as GatherError {
            #expect(error.params["field"] == "bucket")
        }
    }

    @Test("WebDAV 适配：失败原因映射到分类（401/403 = auth）")
    func webDAVAdapterMapsCategories() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        // 探针 PUT 403：WebDAVPublisher 视为非认证中止 but failure reason "HTTP 403"。
        // 逐级 MKCOL 各一次（base / client / Wedding），随后探针 PUT 返回 403。
        let transport = FakeWebDAVTransport([
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 201)),
            .success(WebDAVResponse(status: 403)),
        ])
        let webdavPublisher = WebDAVPublisher(transport: transport, sleep: { _ in })
        let adapter = WebDAVShareTransport(publisher: webdavPublisher)
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .webdav,
            endpoint: "https://dav.example.com/dav/",
            accessKeyID: "alice", secret: "secret", remoteFolder: "client/Wedding",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let result = try await adapter.publish(request, onProgress: nil)
        #expect(result.uploaded == 0)
        let failure = try #require(result.failed.first)
        #expect(failure.category == .auth, "reason: \(failure.reason)")
    }

    @Test("S3：share.json 写失败即中止，不再上传文件（Wave4a-C1 fail-closed）")
    func s3ShareManifestFailureAbortsUpload() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        // 探针 PUT 201 → DELETE 204 → share.json 500（maxAttempts=2，重试一次后返回）。
        let transport = FakeS3Transport([
            .success(S3HTTPResponse(status: 201)),
            .success(S3HTTPResponse(status: 204)),
            .success(S3HTTPResponse(status: 500)),
            .success(S3HTTPResponse(status: 500)),
        ])
        let publisher = S3ShareTransport(
            transport: transport, maxAttempts: 2, sleep: { _ in })
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "https://s3.example.com",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let result = try await publisher.publish(request, onProgress: nil)
        #expect(result.uploaded == 0)
        #expect(!result.abortedOnAuth)
        #expect(result.failed.contains { $0.path == "share.json" })
        let requests = await transport.requests
        #expect(requests.count == 4, "只应有探针 PUT/DELETE + share.json 两次重试")
        #expect(!requests.contains { $0.url.absoluteString.contains("/thumbs/") },
                "share.json 失败后不得上传任何文件")
        let puts = requests.filter { $0.method == "PUT" }
        #expect(puts.allSatisfy {
            $0.url.absoluteString.contains("share.json")
                || $0.url.absoluteString.contains(".gather-write-probe")
        }, "share.json 失败后不得出现任何成片/画廊 PUT")
    }

    @Test("S3 STS：session token 参与签名并作为 x-amz-security-token 上送（Wave4a-C4）")
    func s3SessionTokenParticipatesInSignature() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        let transport = FakeS3Transport()
        let publisher = S3ShareTransport(transport: transport, sleep: { _ in })
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            sessionToken: "TOKEN-XYZ",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        _ = try await publisher.publish(request, onProgress: nil)
        let puts = await transport.requests.filter { $0.method == "PUT" }
        #expect(!puts.isEmpty)
        for put in puts {
            #expect(put.headers["x-amz-security-token"] == "TOKEN-XYZ")
            let authorization = put.headers["Authorization"] ?? ""
            #expect(authorization.contains("x-amz-security-token"),
                    "SignedHeaders 必须包含 session token: \(authorization)")
        }
        // 固定输入下：带 token 的签名与不带 token 的签名不同（token 确实参与计算）。
        let headers = [
            "host": "photos.s3.us-east-1.amazonaws.com",
            "x-amz-content-sha256": S3SigV4.sha256Hex(Data()),
            "x-amz-date": "20261111T000000Z",
        ]
        var tokenHeaders = headers
        tokenHeaders["x-amz-security-token"] = "TOKEN-XYZ"
        let baseSignature = S3SigV4.signature(
            secretAccessKey: "SK", date: "20261111", region: "us-east-1",
            timestamp: "20261111T000000Z", method: "PUT",
            canonicalURI: "/p/share.json", headers: headers,
            payloadHash: S3SigV4.sha256Hex(Data()))
        let tokenSignature = S3SigV4.signature(
            secretAccessKey: "SK", date: "20261111", region: "us-east-1",
            timestamp: "20261111T000000Z", method: "PUT",
            canonicalURI: "/p/share.json", headers: tokenHeaders,
            signedHeaders: S3SigV4.signedHeaderNames + ["x-amz-security-token"],
            payloadHash: S3SigV4.sha256Hex(Data()))
        #expect(baseSignature != tokenSignature)
    }

    @Test("SigV4：canonical header 去首尾/折叠连续空白（Wave4a-C4 规范对齐）")
    func sigV4CanonicalHeaderWhitespace() {
        #expect(S3SigV4.canonicalHeaderValue("  a   b  ") == "a b")
        #expect(S3SigV4.canonicalHeaderValue("a\tb\nc") == "a b c")
        let cleanHost = "examplebucket.s3.amazonaws.com"
        let spacedHost = "  examplebucket.s3.amazonaws.com  "
        let payloadHash = S3SigV4.sha256Hex(Data())
        let cleanHeaders = [
            "host": cleanHost,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": "20261111T000000Z",
        ]
        var spacedHeaders = cleanHeaders
        spacedHeaders["host"] = spacedHost
        let cleanRequest = S3SigV4.canonicalRequest(
            method: "GET", canonicalURI: "/test.txt", headers: cleanHeaders,
            payloadHash: payloadHash)
        let spacedRequest = S3SigV4.canonicalRequest(
            method: "GET", canonicalURI: "/test.txt", headers: spacedHeaders,
            payloadHash: payloadHash)
        #expect(cleanRequest.contains("host:\(cleanHost)\n"))
        #expect(cleanRequest == spacedRequest, "首尾空白必须归一后再参与签名")
    }

    @Test("S3 显式 endpoint（path-style）：canonical URI 含 bucket/前缀，签名可复算（Wave4b）")
    func s3ExplicitEndpointSignatureRoundTrip() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        let transport = FakeS3Transport()
        let publisher = S3ShareTransport(transport: transport, sleep: { _ in })
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3,
            endpoint: "https://minio.example.com:9000",
            accessKeyID: "AK", secret: "SK", remoteFolder: "client/wedding",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        _ = try await publisher.publish(request, onProgress: nil)
        let requests = await transport.requests
        let puts = requests.filter { $0.method == "PUT" }
        #expect(!puts.isEmpty)
        for put in puts {
            #expect(put.url.absoluteString
                    .hasPrefix("https://minio.example.com:9000/photos/client/wedding/"))
            #expect(put.headers["host"] == "minio.example.com:9000")
            let authorization = try #require(put.headers["Authorization"])
            let timestamp = try #require(put.headers["x-amz-date"])
            let payloadHash = try #require(put.headers["x-amz-content-sha256"])
            let date = String(timestamp.prefix(8))
            let signature = S3SigV4.signature(
                secretAccessKey: "SK", date: date, region: "us-east-1",
                timestamp: timestamp, method: "PUT",
                canonicalURI: put.url.path, headers: put.headers,
                payloadHash: payloadHash)
            let expected = S3SigV4.authorizationHeader(
                accessKeyID: "AK",
                scope: S3SigV4.scope(date: date, region: "us-east-1"),
                signature: signature)
            #expect(authorization == expected,
                    "显式 endpoint 的签名必须可按实际请求复算：\(authorization)")
        }
    }

    @Test("S3 错误分类：非法 endpoint→INVALID 不重试；真实网络错误→NETWORK 不被吞（Wave4b）")
    func s3FailureClassificationKeepsNetworkErrors() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        // 1) 非法 endpoint：配置错误（不重试，requests 保持 0）。
        let badTransport = FakeS3Transport()
        let badPublisher = S3ShareTransport(transport: badTransport, sleep: { _ in })
        let badRequest = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "ftp://bad-endpoint",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let badResult = try await badPublisher.publish(badRequest, onProgress: nil)
        let badFailure = try #require(badResult.failed.first)
        #expect(badFailure.reason.hasPrefix("INVALID:"), "reason: \(badFailure.reason)")
        #expect(badFailure.category == .validation)
        #expect(await badTransport.requests.isEmpty, "配置错误不应发起网络请求")

        // 2) 真实网络错误：探针重试后仍按 NETWORK 上报（不能被吞成通用/本地错误）。
        let offline = URLError(.notConnectedToInternet)
        let netTransport = FakeS3Transport([
            .failure(offline), .failure(offline),
        ])
        let netPublisher = S3ShareTransport(
            transport: netTransport, maxAttempts: 2, sleep: { _ in })
        let netRequest = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "https://s3.example.com",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let netResult = try await netPublisher.publish(netRequest, onProgress: nil)
        let netFailure = try #require(netResult.failed.first)
        #expect(netFailure.reason.hasPrefix("NETWORK:"), "reason: \(netFailure.reason)")
        #expect(netFailure.category == .network)
        #expect(await netTransport.requests.count == 2, "真实网络错误应按重试策略尝试")
    }

    @Test("S3 本地文件读失败：LOCAL_IO 而不是 NETWORK，且不重试/不上传（Wave4b）")
    func s3LocalReadFailureIsLocalIO() async throws {
        let tree = try makeTree()
        defer {
            do { try FileManager.default.removeItem(atPath: tree) } catch {
                // 清理失败不影响断言。
            }
        }
        // 用"存在但不可读"的文件（权限 000）构造本地读失败：文件系统枚举仍能列出它，
        // 读取时才失败 → LOCAL_IO，而不是像坏符号链接那样在收集阶段被跳过。
        let broken = URL(fileURLWithPath: tree)
            .appendingPathComponent("thumbs/0001.jpg")
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: broken.path)
        } catch {
            Issue.record("构造不可读文件失败：\(error)")
            return
        }
        defer {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: broken.path)
            } catch {
                // 恢复失败只影响临时目录清理。
            }
        }
        let transport = FakeS3Transport()
        let publisher = S3ShareTransport(transport: transport, sleep: { _ in })
        let request = OutputSharePublishRequest(
            localPath: tree, transport: .s3, endpoint: "https://s3.example.com",
            accessKeyID: "AK", secret: "SK", remoteFolder: "p",
            bucket: "photos", region: "us-east-1",
            includePrefixes: ["thumbs"],
            share: OutputShareOptions(expiresAt: futureExpiry()))
        let result = try await publisher.publish(request, onProgress: nil)
        let failure = try #require(result.failed.first)
        #expect(failure.reason.hasPrefix("LOCAL_IO:"), "reason: \(failure.reason)")
        #expect(failure.category == .localIO, "actual=\(failure.category.rawValue) reason=\(failure.reason)")
        let requests = await transport.requests
        let filePuts = requests.filter { $0.method == "PUT" && $0.url.absoluteString.contains("/thumbs/") }
        #expect(filePuts.isEmpty, "本地读失败不得上传该文件")
    }

    // MARK: AWS 官方固定向量 + clock skew/重复头失败用例（Wave4c / task-51）

    @Test("SigV4：AWS 官方 PUT Object 固定向量（canonical request / 签名密钥逐步 / 签名）")
    func sigV4AWSPutObjectFixedVector() {
        let payloadHash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let headers = [
            "date": "Fri, 24 May 2013 00:00:00 GMT",
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": "20130524T000000Z",
            "x-amz-storage-class": "REDUCED_REDUNDANCY",
        ]
        let signedHeaders = [
            "date", "host", "x-amz-content-sha256", "x-amz-date", "x-amz-storage-class",
        ]
        let expectedCanonical = #"""
PUT
/test%24file.text

date:Fri, 24 May 2013 00:00:00 GMT
host:examplebucket.s3.amazonaws.com
x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
x-amz-date:20130524T000000Z
x-amz-storage-class:REDUCED_REDUNDANCY

date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
"""#
        let canonical = S3SigV4.canonicalRequest(
            method: "PUT", canonicalURI: "/test%24file.text",
            headers: headers, signedHeaders: signedHeaders, payloadHash: payloadHash)
        #expect(canonical == expectedCanonical)
        #expect(S3SigV4.sha256Hex(Data(canonical.utf8))
                == "9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d")

        let steps = S3SigV4.signingKeySteps(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            date: "20130524", region: "us-east-1", service: "s3")
        func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }
        #expect(hex(steps.dateKey)
                == "68896419206d6240ad4cd7dc8ba658efbf3b43b53041950083a10833824fcfbb")
        #expect(hex(steps.regionKey)
                == "0506335cc36b4a971f6beddf0adbd976ee71222cb42c131487e0c12c5c47a025")
        #expect(hex(steps.serviceKey)
                == "05602c14e8b6aad30e7f6dec4b544071f6e4a742934bc5e36415733c47a67d44")
        #expect(hex(steps.signingKey)
                == "dbb893acc010964918f1fd433add87c70e8b0db6be30c1fbeafefa5ec6ba8378")

        let signature = S3SigV4.signature(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            date: "20130524", region: "us-east-1",
            timestamp: "20130524T000000Z", method: "PUT",
            canonicalURI: "/test%24file.text", headers: headers,
            signedHeaders: signedHeaders, payloadHash: payloadHash)
        #expect(signature
                == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test("SigV4：x-amz-security-token + header 空白折叠固定向量（Wave4c）")
    func sigV4TokenWhitespaceFixedVector() {
        let payloadHash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let headers = [
            "host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": "20130524T000000Z",
            "x-amz-security-token": "TOKEN-EXAMPLE-123",
            "x-amz-storage-class": "  REDUCED   REDUNDANCY  ",
        ]
        let signedHeaders = [
            "host", "x-amz-content-sha256", "x-amz-date",
            "x-amz-security-token", "x-amz-storage-class",
        ]
        #expect(S3SigV4.canonicalHeaderValue("  a   b  ") == "a b")
        #expect(S3SigV4.canonicalHeaderValue("  REDUCED   REDUNDANCY  ")
                == "REDUCED REDUNDANCY")
        let expectedCanonical = #"""
PUT
/test%24file.text

host:examplebucket.s3.amazonaws.com
x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
x-amz-date:20130524T000000Z
x-amz-security-token:TOKEN-EXAMPLE-123
x-amz-storage-class:REDUCED REDUNDANCY

host;x-amz-content-sha256;x-amz-date;x-amz-security-token;x-amz-storage-class
44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
"""#
        let canonical = S3SigV4.canonicalRequest(
            method: "PUT", canonicalURI: "/test%24file.text",
            headers: headers, signedHeaders: signedHeaders, payloadHash: payloadHash)
        #expect(canonical == expectedCanonical)
        #expect(S3SigV4.sha256Hex(Data(canonical.utf8))
                == "74599c6f94ad77a462abf520fafa6517387d0846846b505d694d95924e63a53d")
        let signature = S3SigV4.signature(
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            date: "20130524", region: "us-east-1",
            timestamp: "20130524T000000Z", method: "PUT",
            canonicalURI: "/test%24file.text", headers: headers,
            signedHeaders: signedHeaders, payloadHash: payloadHash)
        #expect(signature
                == "d63da51aa08b7349b33cdc14fcf6e6b86302982035c2559ac7863551e39deecd")
    }

    @Test("SigV4：clock skew / 重复头 / 非法时间戳失败用例（Wave4c）")
    func sigV4ValidationFailures() {
        let now = Date()
        let fresh = S3SigV4.timestamp(now)
        #expect(S3SigV4.validationFailure(timestamp: fresh, now: now) == nil)
        #expect(S3SigV4.validationFailure(
            timestamp: "2026-11-11T00:00:00Z", now: now) == .invalidTimestamp)
        #expect(S3SigV4.validationFailure(
            timestamp: S3SigV4.timestamp(now.addingTimeInterval(3600)),
            now: now) == .clockSkew)
        #expect(S3SigV4.validationFailure(
            timestamp: fresh, signedHeaders: ["host", "host"],
            now: now) == .duplicateSignedHeader)
        #expect(S3SigV4.validationFailure(
            timestamp: fresh, signedHeaders: [], now: now) == .emptySignedHeader)
        #expect(S3SigV4.validationFailure(
            timestamp: fresh, signedHeaders: ["host", ""],
            now: now) == .emptySignedHeader)
        #expect(S3SigV4.validationFailure(
            timestamp: fresh, signedHeaders: ["Host"],
            now: now) == .uppercaseSignedHeader)
    }
}

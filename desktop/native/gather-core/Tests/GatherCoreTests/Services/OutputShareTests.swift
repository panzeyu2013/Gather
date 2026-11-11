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
        defer { try? FileManager.default.removeItem(atPath: tree) }
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
        defer { try? FileManager.default.removeItem(atPath: tree) }
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
        defer { try? FileManager.default.removeItem(atPath: tree) }
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
}

// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputShareTransport.swift
// Wave3：发布传输抽象（OutputShareTransport）+ 通道分派（OutputSharePublisher）。
//
// 设计：
// - WebDAV 保留既有 WebDAVPublisher（上传/重试/认证中止语义不动），这里只做适配；
// - S3 兼容存储用 S3ShareTransport（SigV4 签名，纯逻辑可单测）；
// - 两条通道都返回同一份 OutputSharePublishResult，失败带分类（auth/notFound/
//   network/server/validation/localIO/unknown），供 UI 报告与排查；
// - 发布前的分享参数强校验（到期/口令/子目录）集中在 OutputSharePublisher，
//   保证 WebDAV 与 S3 口径一致；
// - secret 只来自 Keychain（入口在 Host），本层不落盘、不拼进错误串/日志。
import Foundation
import GatherProtocol

/// 一次发布请求（两条通道共用）。secret 只在内存中存在。
public struct OutputSharePublishRequest: Equatable, Sendable {
    public var localPath: String
    public var transport: OutputShareTransportKind
    /// WebDAV baseURL / S3 endpoint（S3 允许空 = 由 bucket+region 推 AWS 默认）。
    public var endpoint: String
    /// WebDAV username / S3 accessKeyID。
    public var accessKeyID: String
    /// WebDAV password / S3 secretAccessKey（仅内存）。
    public var secret: String
    /// WebDAV 远端目录 / S3 key 前缀。
    public var remoteFolder: String
    public var bucket: String?
    public var region: String?
    /// S3 可选 STS/Session Token（WebDAV 忽略；只来自 Keychain/内存）。
    public var sessionToken: String?
    public var includePrefixes: [String]?
    public var share: OutputShareOptions?

    public init(
        localPath: String,
        transport: OutputShareTransportKind,
        endpoint: String,
        accessKeyID: String,
        secret: String,
        remoteFolder: String,
        bucket: String? = nil,
        region: String? = nil,
        sessionToken: String? = nil,
        includePrefixes: [String]? = nil,
        share: OutputShareOptions? = nil
    ) {
        self.localPath = localPath
        self.transport = transport
        self.endpoint = endpoint
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.remoteFolder = remoteFolder
        self.bucket = bucket
        self.region = region
        self.sessionToken = sessionToken
        self.includePrefixes = includePrefixes
        self.share = share
    }
}

public struct OutputSharePublishFailure: Equatable, Sendable {
    public var path: String
    public var reason: String
    public var category: OutputShareFailureCategory

    public init(path: String, reason: String, category: OutputShareFailureCategory) {
        self.path = path
        self.reason = reason
        self.category = category
    }

    public init(path: String, reason: String) {
        self.init(
            path: path, reason: reason,
            category: OutputShareFailureCategory.infer(fromReason: reason))
    }
}

public struct OutputSharePublishResult: Equatable, Sendable {
    public var uploaded: Int
    public var failed: [OutputSharePublishFailure]
    public var remoteRoot: String
    public var abortedOnAuth: Bool

    public init(
        uploaded: Int, failed: [OutputSharePublishFailure],
        remoteRoot: String, abortedOnAuth: Bool
    ) {
        self.uploaded = uploaded
        self.failed = failed
        self.remoteRoot = remoteRoot
        self.abortedOnAuth = abortedOnAuth
    }

    public var isSuccess: Bool { failed.isEmpty && !abortedOnAuth }

    /// 失败分类计数（报告用）。
    public var failureCategories: [OutputShareFailureCategory: Int] {
        var counts: [OutputShareFailureCategory: Int] = [:]
        for failure in failed { counts[failure.category, default: 0] += 1 }
        return counts
    }
}

public protocol OutputShareTransport: Sendable {
    /// 上传本地目录；实现内部负责"发布前可写探测"与失败分类。
    func publish(
        _ request: OutputSharePublishRequest,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> OutputSharePublishResult
}

/// 通道分派 + 分享参数强校验（WebDAV/S3 同一口径）。
public final class OutputSharePublisher: Sendable {
    private let transports: [OutputShareTransportKind: any OutputShareTransport]

    public init(transports: [OutputShareTransportKind: any OutputShareTransport]) {
        self.transports = transports
    }

    /// 单测/调试用入口。
    public func transport(for kind: OutputShareTransportKind) -> (any OutputShareTransport)? {
        transports[kind]
    }

    public func publish(
        _ request: OutputSharePublishRequest,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> OutputSharePublishResult {
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
        if request.transport == .s3,
           (request.bucket ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "bucket", "reason": "s3BucketMissing"])
        }
        guard let transport = transports[request.transport] else {
            throw GatherError(
                code: .EXPORT_PARAMS_INVALID,
                params: ["field": "transport", "reason": "unsupported"])
        }
        return try await transport.publish(request, onProgress: onProgress)
    }
}

/// WebDAV 适配：不复制上传逻辑，直接复用 WebDAVPublisher（含严格模式校验/可写探测）。
public struct WebDAVShareTransport: OutputShareTransport {
    public let kind: OutputShareTransportKind = .webdav
    private let publisher: WebDAVPublisher

    public init(publisher: WebDAVPublisher) {
        self.publisher = publisher
    }

    public func publish(
        _ request: OutputSharePublishRequest,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> OutputSharePublishResult {
        guard let baseURL = URL(string: request.endpoint),
              baseURL.scheme?.hasPrefix("http") == true else {
            throw WebDAVError.invalidBaseURL(request.endpoint)
        }
        let configuration = WebDAVConfiguration(
            baseURL: baseURL, username: request.accessKeyID,
            password: request.secret, remoteFolder: request.remoteFolder)
        let result = try await publisher.publish(
            localPath: request.localPath, configuration: configuration,
            includePrefixes: request.includePrefixes, share: request.share,
            onProgress: onProgress)
        return OutputSharePublishResult(
            uploaded: result.uploaded,
            failed: result.failed.map {
                OutputSharePublishFailure(path: $0.path, reason: $0.reason)
            },
            remoteRoot: result.remoteRoot,
            abortedOnAuth: result.abortedOnAuth)
    }
}

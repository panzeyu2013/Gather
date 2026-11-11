// desktop/native/gather-core/Sources/GatherProtocol/Protocol/ProofShare.swift
// P1 下一波：客户校样反馈 v2 + 分享策略。

import Foundation

/// selection.json v2 的单项。v1 的 {id,name,pick} 仍可解码（pick 为 Bool）。
public struct ClientFeedbackItem: Codable, Equatable, Sendable {
    public var photoId: String
    public var name: String?
    public var pick: Bool?
    public var rating: Int?
    public var label: String?
    public var comment: String?

    public init(
        photoId: String,
        name: String? = nil,
        pick: Bool? = nil,
        rating: Int? = nil,
        label: String? = nil,
        comment: String? = nil
    ) {
        self.photoId = photoId
        self.name = name
        self.pick = pick
        self.rating = rating
        self.label = label
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {
        case photoId = "id"
        case name, pick, rating, label, comment
    }
}

public struct ProofFeedbackConflict: Codable, Equatable, Sendable {
    public var photoId: String
    public var localRating: Int
    public var localLabel: String
    public var clientRating: Int?
    public var clientLabel: String?

    public init(
        photoId: String,
        localRating: Int,
        localLabel: String,
        clientRating: Int?,
        clientLabel: String?
    ) {
        self.photoId = photoId
        self.localRating = localRating
        self.localLabel = localLabel
        self.clientRating = clientRating
        self.clientLabel = clientLabel
    }
}

/// Wave3：发布/分享通道（WebDAV = 用户自备服务器；S3 = S3 兼容对象存储）。
/// 通道字段在 WebDAVPublishInput.transport（可选，默认 webdav），旧调用逐字兼容。
public enum OutputShareTransportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case webdav
    case s3
}

/// Wave3：分享参数校验问题（发布前强校验；UI 与服务共用同一份纯逻辑）。
public enum OutputShareValidationIssue: String, Codable, Equatable, Sendable {
    /// expiresAt 不是合法 ISO-8601。
    case expiresAtInvalid
    /// expiresAt 早于/等于当前时间（"到期必须晚于现在"）。
    case expiresAtInPast
    /// 校样页口令长度不在 4-128。
    case passwordLengthInvalid
    /// 远端子目录含绝对路径/路径穿越/空段。
    case remoteSubfolderInvalid
}

/// Wave3：发布失败分类（报告用；不新增 GatherErrorCode，避免动 Core.swift 穷尽枚举）。
public enum OutputShareFailureCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case auth
    case notFound
    case network
    case server
    case validation
    case localIO
    case unknown
}

public extension OutputShareFailureCategory {
    /// 从发布失败原因串推断分类（WebDAV/S3 的 reason 都是 "HTTP 403" / "URL ..." 这类）。
    ///
    /// 只做**报告分类**，不改变中止/重试语义（语义仍在 publisher 里）。
    static func infer(fromReason reason: String) -> OutputShareFailureCategory {
        let text = reason.uppercased()
        if text.contains("401") || text.contains("403")
            || text.contains("AUTH") || text.contains("UNAUTHORIZED")
            || text.contains("FORBIDDEN") || text.contains("KEYCHAIN") {
            return .auth
        }
        if text.contains("HTTP 404") || text.contains("NOSUCHBUCKET")
            || text.contains("NO SUCH BUCKET") || text.contains("NOT FOUND") {
            return .notFound
        }
        if text.contains("HTTP 5") || text.contains("RETRY EXHAUSTED")
            || text.contains("HTTP 429") || text.contains("HTTP 408") {
            return .server
        }
        if text.contains("NSURLERROR") || text.contains("URLERROR")
            || text.contains("NETWORK") || text.contains("TIMED OUT")
            || text.contains("OFFLINE") || text.contains("CONNECTION") {
            return .network
        }
        if text.contains("EXPORT_PARAMS_INVALID") || text.contains("SHARE_")
            || text.contains("INVALID") || text.contains("MISSING")
            || text.contains("NO MATCHING") {
            return .validation
        }
        if text.contains("LOCAL") || text.contains("FILE") || text.contains("READ")
            || text.contains("WRITE") || text.contains("DISK") {
            return .localIO
        }
        return .unknown
    }
}

public struct OutputShareOptions: Codable, Equatable, Sendable {
    /// false = 只上传 thumbs/proof，不上传 large 与成片。
    public var allowDownload: Bool
    /// ISO-8601；Wave3 起**发布前强校验**（必须晚于现在），proof.js 到期后禁止提交。
    /// 注意：静态托管的文件不会被删除（没有服务端），到期只是"页面拒收 + 提示"。
    public var expiresAt: String?
    public var remoteSubfolder: String
    /// Wave3：校样页口令（**仅内存传输**；发布时派生 salt+PBKDF2 哈希写进 share.json，
    /// 明文不落盘/不进 settings/不进日志）。纯前端门槛，不是加密。
    public var password: String?

    public init(
        allowDownload: Bool = false,
        expiresAt: String? = nil,
        remoteSubfolder: String = "",
        password: String? = nil
    ) {
        self.allowDownload = allowDownload
        self.expiresAt = expiresAt
        self.remoteSubfolder = remoteSubfolder
        self.password = password
    }
}


/// Wave3：S3 兼容存储的寻址（纯字符串/URL 逻辑；UI、Host、服务共用一份实现）。
///
/// 两种寻址：
/// - endpoint 显式给出（MinIO/Ceph/自建网关）→ path-style：<endpoint>/<bucket>/<key>；
/// - endpoint 为空 → AWS 默认 → virtual-hosted：https://<bucket>.s3.<region>.amazonaws.com/<key>。
/// 默认 region = us-east-1。对象一律**默认私有**（不写 ACL/public-read）。
public struct S3ObjectAddress: Equatable, Sendable {
    /// 实际请求 URL（已百分号编码 key）。
    public let url: URL
    /// 签名 Host（含端口，如非默认端口）。
    public let host: String
    /// 签名 CanonicalURI（"/" 开头；path-style 含 bucket 前缀，不含 endpoint 的 path 前缀）。
    public let canonicalURI: String
    /// 规范化 service endpoint（凭据存取的稳定键）。
    public let endpoint: String
}

public enum S3ShareAddressing {
    public static let defaultRegion = "us-east-1"

    /// 规范化 service endpoint（Keychain 凭据键、签名 Host 基准）。
    public static func canonicalEndpoint(
        baseURL: String, bucket: String, region: String?
    ) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var text = trimmed
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        let safeRegion = normalizedRegion(region)
        return "https://\(safeBucket(bucket)).s3.\(safeRegion).amazonaws.com"
    }

    /// 解析一次上传/删除请求的寻址（nil = endpoint/bucket 非法）。
    ///
    /// 注意：URL 用 percent-encoded 路径；但 SigV4 的 CanonicalURI 必须基于**未编码**
    /// 的原始段再做一次规范编码，否则会出现 %25 双重转义导致签名与服务器不一致。
    public static func address(
        baseURL: String, bucket: String, region: String?, key: String
    ) -> S3ObjectAddress? {
        let normalizedBucket = safeBucket(bucket)
        guard !normalizedBucket.isEmpty else { return nil }
        let rawKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedKey = normalizedKeyPath(key)
        let explicit = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            var endpoint = explicit
            while endpoint.hasSuffix("/") { endpoint.removeLast() }
            guard let base = URL(string: endpoint),
                  let scheme = base.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let baseHost = base.host else { return nil }
            let prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pathComponent = prefix.isEmpty ? "" : "/" + prefix
            let fullPath = pathComponent + "/" + normalizedBucket
                + (encodedKey.isEmpty ? "" : "/" + encodedKey)
            guard let url = URL(string: endpoint + fullPath) else { return nil }
            var host = baseHost
            if let port = base.port { host += ":\(port)" }
            let rawPath = pathComponent + "/" + normalizedBucket
                + (rawKey.isEmpty ? "" : "/" + rawKey)
            return S3ObjectAddress(
                url: url, host: host, canonicalURI: canonicalURI(rawPath), endpoint: endpoint)
        }
        let safeRegion = normalizedRegion(region)
        let host = "\(normalizedBucket).s3.\(safeRegion).amazonaws.com"
        let fullPath = "/" + (encodedKey.isEmpty ? "" : encodedKey)
        guard let url = URL(string: "https://" + host + fullPath) else { return nil }
        let rawPath = "/" + (rawKey.isEmpty ? "" : rawKey)
        return S3ObjectAddress(
            url: url, host: host, canonicalURI: canonicalURI(rawPath),
            endpoint: "https://s3.\(safeRegion).amazonaws.com")
    }

    /// 远端前缀/对象 key 归一：去首尾 "/"、折叠空段、拒绝 ". / .."（返回 nil = 非法）。
    public static func sanitizedKeyPrefix(_ prefix: String) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        var result: [String] = []
        for segment in segments {
            let value = String(segment)
            if value == "." || value == ".." { return nil }
            result.append(value)
        }
        return result.joined(separator: "/")
    }

    static func normalizedRegion(_ region: String?) -> String {
        let trimmed = (region ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultRegion : trimmed
    }

    static func safeBucket(_ bucket: String) -> String {
        bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// key 路径归一：逐段 percent-encode（RFC3986 unreserved 之外全部转义）。
    static func normalizedKeyPath(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map { canonicalURIComponent(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalURI(_ path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if trimmed.isEmpty { return "/" }
        return "/" + trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map { canonicalURIComponent(String($0)) }
            .joined(separator: "/")
    }

    static func canonicalURIComponent(_ value: String) -> String {
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

public extension OutputShareOptions {
    /// 口令最短长度（纯前端门槛；不是加密）。
    static let minimumPasswordLength = 4
    /// 口令最长长度（避免误贴长文本导致页面哈希成本异常）。
    static let maximumPasswordLength = 128

    /// 发布前强校验：nil = 合法。
    ///
    /// 口径（task-17）：到期时间必须能解析且晚于 now；口令长度 4-128；
    /// 远端子目录不得绝对/穿越/空段；S3 通道必须给 bucket+region。
    func validationIssue(now: Date = Date()) -> OutputShareValidationIssue? {
        if let expiresAt, !expiresAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let date = Self.parseISO8601(expiresAt) else { return .expiresAtInvalid }
            if date <= now { return .expiresAtInPast }
        }
        if let password, !password.isEmpty {
            if password.count < Self.minimumPasswordLength
                || password.count > Self.maximumPasswordLength {
                return .passwordLengthInvalid
            }
        }
        let subfolder = remoteSubfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subfolder.isEmpty {
            if subfolder.hasPrefix("/") || subfolder.contains("\\")
                || subfolder.contains("\0") {
                return .remoteSubfolderInvalid
            }
            let segments = subfolder.split(separator: "/", omittingEmptySubsequences: false)
            if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                return .remoteSubfolderInvalid
            }
        }
        return nil
    }

    /// 解析后的到期时间（ISO-8601；nil = 未设置或格式非法）。
    var parsedExpiresAt: Date? {
        guard let expiresAt else { return nil }
        return Self.parseISO8601(expiresAt)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}


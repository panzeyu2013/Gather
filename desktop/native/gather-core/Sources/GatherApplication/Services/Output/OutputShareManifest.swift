// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputShareManifest.swift
// Wave3：分享清单（share.json）的唯一写入实现，WebDAV 与 S3 两个通道共用。
// Wave5：同文件追加「发布记录」读写（.gather-share-publish.json：HEAD 差分/发布历史）。
//
// 兼容：字段只增不改——version 仍为 1，旧 proof.js 读到未知字段会忽略；
// 编码口径：目标 macOS 的 JSONEncoder 默认会转义 "/"，本 writer 显式
// withoutEscapingSlashes（remoteSubfolder 含 "/" 时与旧输出字节不同，语义一致；
// 新参数未开启时其余字段/顺序不变，供审计对照）。
// 没有口令时**不写**口令字段（旧分享包字节不变）。
// 安全：只写口令派生结果（algorithm/salt/iterations/hash），绝不写明文；
// 也不写 accessKey/secret（凭据只在 Keychain）。
import Foundation
import GatherProtocol

public enum OutputShareManifest {
    /// share.json 的 JSON 字节（sortedKeys + prettyPrinted：与旧输出逐字兼容）。
    public static func json(
        share: OutputShareOptions,
        itemCount: Int,
        createdAt: String? = nil
    ) -> Data {
        var payload: [String: JSONValue] = [:]
        payload["version"] = .number(1)
        payload["createdAt"] = .string(createdAt ?? Self.iso8601Now())
        payload["itemCount"] = .number(Double(itemCount))
        payload["allowDownload"] = .bool(share.allowDownload)
        payload["remoteSubfolder"] = .string(share.remoteSubfolder)
        if let expiresAt = share.expiresAt, !expiresAt.isEmpty {
            payload["expiresAt"] = .string(expiresAt)
        }
        // 口令门：只存派生结果的盐/迭代次数/哈希；明文永不落盘。
        if let password = share.password, !password.isEmpty {
            let derived = OutputSharePassword.derive(password: password)
            payload["passwordAlgorithm"] = .string(derived.algorithm)
            payload["passwordSalt"] = .string(derived.saltHex)
            payload["passwordIterations"] = .number(Double(derived.iterations))
            payload["passwordHash"] = .string(derived.hashHex)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(payload)
        } catch {
            // 编码失败（理论上不会）时退回最小合法 JSON，保证发布流程可继续。
            return Data("{\"version\":1,\"itemCount\":\(itemCount)}".utf8)
        }
    }

    public static func iso8601Now(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Wave5：发布记录（HEAD 差分 / 发布历史）

/// 发布记录里的单个文件：本地 stat（size/mtime）+ 可选远端 ETag。
///
/// 只用于「远端是否还是上次那份」的判定；不含内容哈希（HEAD 差分不需要）。
public struct OutputSharePublishFileRecord: Codable, Equatable, Sendable {
    public var relative: String
    /// 本地文件大小（字节）。
    public var size: Int64
    /// 本地修改时间（Unix 秒；Double 避免亚秒精度丢失导致误判）。
    public var mtime: Double
    /// 远端 ETag（S3 PUT/HEAD 或支持 ETag 的 WebDAV 服务器；可能为 nil）。
    public var etag: String?

    public init(relative: String, size: Int64, mtime: Double, etag: String? = nil) {
        self.relative = relative
        self.size = size
        self.mtime = mtime
        self.etag = etag
    }
}

/// 一次发布的历史条目（写进交付目录的发布记录；跨重启可见）。
///
/// 安全：不存 secret / accessKeyID / URL userinfo / 本机绝对路径；
/// `endpointSummary` 只保留 scheme+host+port+path。
public struct OutputSharePublishEntry: Codable, Equatable, Sendable {
    public var publishedAt: String
    public var transport: OutputShareTransportKind
    public var endpointSummary: String
    public var remoteFolder: String
    public var bucket: String?
    public var entryURL: String?
    public var uploaded: Int
    public var skipped: Int
    public var failed: Int
    public var files: [OutputSharePublishFileRecord]

    public init(
        publishedAt: String,
        transport: OutputShareTransportKind,
        endpointSummary: String,
        remoteFolder: String,
        bucket: String? = nil,
        entryURL: String? = nil,
        uploaded: Int,
        skipped: Int,
        failed: Int,
        files: [OutputSharePublishFileRecord]
    ) {
        self.publishedAt = publishedAt
        self.transport = transport
        self.endpointSummary = endpointSummary
        self.remoteFolder = remoteFolder
        self.bucket = bucket
        self.entryURL = entryURL
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
        self.files = files
    }

    public func fileRecord(_ relative: String) -> OutputSharePublishFileRecord? {
        files.first { $0.relative == relative }
    }
}

/// 发布记录文件内容（version 只增不改；history 最新在前，最多 5 条）。
public struct OutputSharePublishRecord: Codable, Equatable, Sendable {
    public var version: Int
    public var history: [OutputSharePublishEntry]

    public init(version: Int = 1, history: [OutputSharePublishEntry] = []) {
        self.version = version
        self.history = history
    }
}

/// 发布记录读写（存在交付目录里的隐藏文件；失败不阻塞发布）。
public enum OutputSharePublishRecordStore {
    public static let fileName = ".gather-share-publish.json"
    public static let historyLimit = 5

    public static func fileURL(atDirectory directory: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(fileName)
    }

    /// 本地路径 → 记录目录（目录=自身，文件=父目录）。
    public static func directory(forLocalPath path: String) -> String {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// 读取记录；文件不存在/损坏/版本未知 → nil（保守走全量发布，不误跳过）。
    public static func load(atDirectory directory: String) -> OutputSharePublishRecord? {
        let url = fileURL(atDirectory: directory)
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(OutputSharePublishRecord.self, from: data)
            return record.version >= 1 ? record : nil
        } catch {
            return nil
        }
    }

    /// 追加一条历史（最新在前，截断到 limit），原子写入。
    public static func append(
        _ entry: OutputSharePublishEntry,
        atDirectory directory: String,
        limit: Int = historyLimit
    ) throws {
        var record = load(atDirectory: directory) ?? OutputSharePublishRecord()
        record.history.insert(entry, at: 0)
        if record.history.count > max(1, limit) {
            record.history = Array(record.history.prefix(max(1, limit)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        try data.write(to: fileURL(atDirectory: directory), options: .atomic)
    }

    /// 找到与本次发布目标匹配的最近一条记录（transport + 远端根 + 前缀 + bucket）。
    public static func matchingEntry(
        in record: OutputSharePublishRecord?,
        transport: OutputShareTransportKind,
        endpointSummary: String,
        remoteFolder: String,
        bucket: String?
    ) -> Optional<OutputSharePublishEntry> {
        guard let record else { return nil }
        let folder = normalizedRemoteFolder(remoteFolder)
        let bucketValue = normalizedBucket(bucket)
        return record.history.first { entry in
            entry.transport == transport
                && entry.endpointSummary == endpointSummary
                && normalizedRemoteFolder(entry.remoteFolder) == folder
                && normalizedBucket(entry.bucket) == bucketValue
        }
    }

    /// endpoint 摘要：去掉 URL 的 userinfo / query / fragment（绝不让凭据进记录）。
    public static func endpointSummary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var text = components.string ?? trimmed
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func normalizedRemoteFolder(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    static func normalizedBucket(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// HEAD 差分判定（纯函数，单测可直接覆盖）。
public enum OutputSharePublishDiff {
    /// 本地文件 stat → 记录条目（读不到 = nil，调用方按"无记录"全量上传）。
    public static func localFileRecord(
        relative: String,
        filePath: String
    ) -> OutputSharePublishFileRecord? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return OutputSharePublishFileRecord(
                relative: relative, size: size, mtime: mtime)
        } catch {
            return nil
        }
    }

    /// 是否可跳过上传：
    /// 1) 本地 size+mtime 与上次记录一致（本地没变）；
    /// 2) 远端 HEAD 与记录一致（远端没变）——优先 ETag，其次 Content-Length。
    public static func shouldSkip(
        previous: OutputSharePublishFileRecord,
        local: OutputSharePublishFileRecord,
        remoteContentLength: Int64?,
        remoteETag: String?
    ) -> Bool {
        guard previous.size == local.size,
              abs(previous.mtime - local.mtime) < 0.001
        else { return false }
        let previousTag = normalizedETag(previous.etag)
        let remoteTag = normalizedETag(remoteETag)
        if let previousTag, let remoteTag {
            return previousTag == remoteTag
        }
        if let remoteContentLength {
            return remoteContentLength == local.size
        }
        return false
    }

    /// ETag 归一：去引号/空白（S3/WebDAV 返回 `"abc"` 或 W/`"abc"`）。
    public static func normalizedETag(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("W/") { value.removeFirst(2) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty ? nil : value
    }
}

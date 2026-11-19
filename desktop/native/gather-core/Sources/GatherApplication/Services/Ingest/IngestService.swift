// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/IngestService.swift
// P1 / D：摄取（计划 → 执行 → 校验），文件落地与库登记分离。
//
// 边界（重要）：本服务**只搬文件**，不写 photos/assets 表。登记统一交给
// IndexerService 扫描目标目录，避免把 RAW/JPEG 配对、volume/file_identity、
// checksum 回填这套语义复制成第二份实现。
//
// 安全原则：
// - 先计划后执行：plan 阶段完成重名检测、{seq} 一次性分配、去重判定；
// - 执行时先写 .gather-part 临时文件，校验通过后 rename（半成品不会顶着正式文件名）；
// - 第二目的地只在主目的地校验通过后才复制；任何一步失败都记进结果，不抛出中断整批；
// - 单张原子性：主副本落地后任一步失败（sidecar/第二目的地）都会把这张已落地的文件
//   回滚，避免同一张同时出现在 copied（被登记）与 failed（用户以为没摄进来）。
// M14a：实现按职责拆到 IngestTypes.swift / IngestService+Plan.swift /
// IngestService+Execution.swift（纯搬移，参数/行为/注释零变化）。
import Foundation
import CryptoKit
import GatherProtocol

public final class IngestService: @unchecked Sendable {
    let fileManager: FileManager
    let now: @Sendable () -> Date
    /// P0 / C1：EXIF 读取端口（宿主注入 ImageIO 实现）。nil = 只按 mtime/now 命名。
    let exif: (any ExifProvider)?

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        exif: (any ExifProvider)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.exif = exif
    }

    /// 目标是否在根目录内：**解析 symlink 后**再做前缀比较（计划与 execute 前各查一次，
    /// 防止计划后有人在目的地里建 symlink 把写入带出根目录）。
    static func isWithin(_ path: String, root: String) -> Bool {
        // 目的地可能有 symlink 子目录：解析后再做前缀比较，避免写到根外。
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard !base.isEmpty else { return false }
        return target.hasPrefix(base + "/")
    }

    public enum IngestError: Error, Equatable, CustomStringConvertible, CodedError {
        case checksumMismatch(String)
        case destinationExists(String)
        case outsideDestinationRoot(String)
        /// 上次 replace 中途崩溃遗留的备份：拒绝覆盖并要求人工确认（绝不静默删除）。
        case leftoverReplaceBackup(String)
        public var code: GatherErrorCode {
            switch self {
            case .checksumMismatch: .INGEST_CHECKSUM_MISMATCH
            case .destinationExists: .INGEST_DESTINATION_EXISTS
            case .outsideDestinationRoot: .INGEST_PATH_INVALID
            case .leftoverReplaceBackup: .INGEST_TRANSFER_FAILED
            }
        }

        public var description: String {
            switch self {
            case .checksumMismatch(let path): "校验失败（复制后内容不一致）：\(path)"
            case .destinationExists(let path): "目标已存在，拒绝覆盖：\(path)"
            case .outsideDestinationRoot(let path): "目标不在目的地根目录下：\(path)"
            case .leftoverReplaceBackup(let path):
                "发现上次替换遗留的备份，可能是您的原片，请人工确认后再重试：\(path)"
            }
        }
    }

    /// 流式 SHA-256（大文件不整块进内存）。
    public func checksum(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 << 20)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/IngestTypes.swift
// M14a：摄取的公共 DTO / 重命名模板 / 不支持格式统计（自 IngestService.swift 纯搬移；
// 类型可见性、注释与逻辑逐字节未改）。
import Foundation
import Synchronization
import GatherProtocol

// MARK: - 不支持格式统计（摄取与索引扫描共用）

/// 「不支持格式」统计的噪音过滤：这些文件不是用户想导入的照片，不能计入
/// "跳过 N 个不支持格式"（否则一张卡的 .DS_Store/.xmp 会淹没真实信号）。
enum UnsupportedFileReport {
    /// 与照片同名的附属文件：XMP sidecar、Apple 调整文件、DxO sidecar。
    static let auxiliaryExtensions: Set<String> = ["xmp", "aae", "dop"]

    static func isAuxiliary(named name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if name.hasSuffix(".gather-part") || name.contains(".gather-prev-") { return true }
        return auxiliaryExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 日志用的一行摘要：`gif×3, mov×1; e.g. IMG_1.gif`。
    static func describe(_ formats: IngestUnsupportedFormats) -> String {
        guard formats.count > 0 else { return "" }
        let groups = formats.extensions.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
        let samples = formats.samplePaths.prefix(3)
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: ", ")
        return samples.isEmpty ? groups : "\(groups); e.g. \(samples)"
    }
}

/// 线程安全的「不支持格式」收集器。
///
/// 摄取是单线程顺序枚举，索引扫描的生产者/消费者是并发任务；统一用锁保护，
/// 两条路径共用同一套噪音过滤与样例上限，避免结果口径漂移。
final class UnsupportedFormatTally: Sendable {
    /// 统计里保留的样例上限（只看"哪些文件没进来"，不做清单搬运）。
    static let sampleLimit = 5

    // 索引扫描的生产者任务与摄取顺序路径共用；用 Mutex 而不是 @unchecked Sendable，
    // 让"锁保护可变状态"由类型系统表达（cleanup ratchet 不再新增 unchecked 计数）。
    private let state = Mutex(IngestUnsupportedFormats())

    func record(filepath: String) {
        let name = (filepath as NSString).lastPathComponent
        guard !UnsupportedFileReport.isAuxiliary(named: name) else { return }
        let ext = (filepath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return }
        state.withLock { formats in
            formats.extensions[ext, default: 0] += 1
            if formats.samplePaths.count < Self.sampleLimit {
                formats.samplePaths.append(filepath)
            }
        }
    }

    func snapshot() -> IngestUnsupportedFormats {
        state.withLock { $0 }
    }

    func logSummary(_ prefix: String) {
        let snapshot = snapshot()
        guard snapshot.count > 0 else { return }
        GatherLogger.log(
            "\(prefix): skipped \(snapshot.count) unsupported file(s) [\(UnsupportedFileReport.describe(snapshot))]",
            level: .info)
    }
}

// MARK: - 模板

public enum IngestRenameTemplate {
    /// 支持 {yyyy} {MM} {dd} {HH} {mm} {ss} {orig} {ext} {seq:4} {camera}
    /// 未知占位符原样保留（用户能从结果看出哪里写错了，而不是静默吞掉）。
    public static func expand(
        _ pattern: String,
        originalName: String,
        date: Date,
        sequence: Int,
        cameraModel: String?
    ) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            guard let value else { return "" }
            return String(format: "%0\(width)d", value)
        }
        var result = pattern
        let replacements: [(String, String)] = [
            ("{yyyy}", pad(parts.year, 4)),
            ("{MM}", pad(parts.month, 2)),
            ("{dd}", pad(parts.day, 2)),
            ("{HH}", pad(parts.hour, 2)),
            ("{mm}", pad(parts.minute, 2)),
            ("{ss}", pad(parts.second, 2)),
            ("{orig}", base),
            ("{ext}", ext),
            ("{camera}", sanitize(cameraModel ?? "")),
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        // {seq:N} 支持任意宽度，且模板里可以出现多处（不同宽度各自成形）：
        // 替换后该 token 不再匹配，循环必然收敛。
        while let range = result.range(of: "\\{seq:[0-9]+\\}", options: .regularExpression) {
            let token = String(result[range])
            let width = Int(token.dropFirst(5).dropLast()) ?? 4
            result = result.replacingOccurrences(of: token, with: pad(sequence, width))
        }
        result = result.replacingOccurrences(of: "{seq}", with: pad(sequence, 4))
        return result
    }

    /// 模板是否用到了日期/相机占位符（决定摄取时要不要读 EXIF）。
    /// 只用 {orig}/{ext}/{seq} 的模板无需为每张照片做一次 EXIF 解析。
    public static func usesCaptureMetadata(_ pattern: String) -> Bool {
        ["{yyyy}", "{MM}", "{dd}", "{HH}", "{mm}", "{ss}", "{camera}"]
            .contains { pattern.contains($0) }
    }

    /// 路径分隔符与平台保留字符替换成下划线（模板里写 {camera} 时尤其需要）。
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 计划

public struct IngestItem: Equatable, Sendable {
    public var sourcePath: String
    public var destPath: String
    /// 已存在同名文件且校验和不同 → 冲突，执行时跳过并上报。
    public var conflict: Bool
    public var size: Int
    /// 与照片同名的 XMP sidecar（存在才搬；否则移动照片会把元数据留在卡上）。
    public var sidecarPath: String?
    /// Wave2（task-15）：replace 策略下**覆盖库内已登记照片的原路径**。
    /// 为 true 时 destPath 就是库内那条照片的路径，执行阶段先备份原文件再覆盖。
    public var replaceExisting: Bool
    public init(sourcePath: String, destPath: String, conflict: Bool, size: Int,
                sidecarPath: String? = nil, replaceExisting: Bool = false) {
        self.sourcePath = sourcePath
        self.destPath = destPath
        self.conflict = conflict
        self.size = size
        self.sidecarPath = sidecarPath
        self.replaceExisting = replaceExisting
    }

    /// sidecar 在目标目录的同名路径（照片扩展名换成 .xmp）。兄弟共用目标 stem，
    /// 因此同一个 (目录, stem) 组里的照片推导出同一个 sidecar 路径。
    public var destSidecarPath: String {
        (destPath as NSString).deletingPathExtension + ".xmp"
    }
}

public struct IngestPlan: Equatable, Sendable {
    public var items: [IngestItem]
    public var skipped: [String]
    public var unreadable: [String]
    /// 目标已存在且内容与源一致：本次不复制，但调用方必须登记这些**目标路径**。
    /// 崩溃恢复时这批文件是最容易漏登记的一类（源 checksum 不在库里，plan 又会
    /// 因目标已存在而跳过；只登记 copied 会让它们永久停留在 _ingest）。
    public var alreadyPresent: [String]
    /// Wave2（task-15）：命中**全库**（跨工作区）已登记照片的源文件（无论策略）。
    /// 预览据此给「库内重复」计数；实际动作由 duplicatePolicy 决定。
    public var libraryDuplicates: [String]
    /// Wave2：因库内重复被**跳过**的源文件（skip 策略，或 replace 不可用时退化）。
    public var librarySkipped: [String]
    /// Wave2：按 replace 策略覆盖写入的源文件。
    public var replaced: [String]
    /// Wave5（F4）：源里被跳过的「不支持格式」（按归一化扩展名分组 + 样例路径）。
    public var unsupportedFormats: IngestUnsupportedFormats
    public init(
        items: [IngestItem], skipped: [String], unreadable: [String],
        alreadyPresent: [String] = [],
        libraryDuplicates: [String] = [],
        librarySkipped: [String] = [],
        replaced: [String] = [],
        unsupportedFormats: IngestUnsupportedFormats = IngestUnsupportedFormats()
    ) {
        self.items = items
        self.skipped = skipped
        self.unreadable = unreadable
        self.alreadyPresent = alreadyPresent
        self.libraryDuplicates = libraryDuplicates
        self.librarySkipped = librarySkipped
        self.replaced = replaced
        self.unsupportedFormats = unsupportedFormats
    }
    public var conflictCount: Int { items.filter(\.conflict).count }
}

public struct IngestOptions: Equatable, Sendable {
    public var destinationRoot: String
    public var renameTemplate: String
    public var secondDestinationRoot: String?
    public var verifyChecksum: Bool
    public var moveInsteadOfCopy: Bool
    /// Wave2（task-15）：跨工作区重复的处置策略。
    public var duplicatePolicy: IngestDuplicatePolicy
    /// Wave2：目标会话 id / 源根。replace 策略要求库内目标与当前会话语义一致
    /// （同一工作区）且原路径在源根内，否则退化为跳过——不在「用新文件覆盖
    /// 别的会话登记路径」这件事上做猜测。
    public var sessionId: String
    public var sessionSourceRoot: String
    /// Wave4a-F2：预检（previewIngest）走只读路径——不写 checksum 回填、不产生副作用。
    public var previewOnly: Bool

    public init(destinationRoot: String, renameTemplate: String = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
                secondDestinationRoot: String? = nil, verifyChecksum: Bool = true,
                moveInsteadOfCopy: Bool = false,
                duplicatePolicy: IngestDuplicatePolicy = .skip,
                sessionId: String = "", sessionSourceRoot: String = "",
                previewOnly: Bool = false) {
        self.destinationRoot = destinationRoot
        self.renameTemplate = renameTemplate
        self.secondDestinationRoot = secondDestinationRoot
        self.verifyChecksum = verifyChecksum
        self.moveInsteadOfCopy = moveInsteadOfCopy
        self.duplicatePolicy = duplicatePolicy
        self.sessionId = sessionId
        self.sessionSourceRoot = sessionSourceRoot
        self.previewOnly = previewOnly
    }
}

public struct IngestFailure: Equatable, Sendable {
    public var sourcePath: String
    public var message: String
    /// 稳定错误码（GatherErrorCode.rawValue）；空串 = 未编码错误。
    public var code: String
    public var retryable: Bool
    public init(sourcePath: String, message: String, code: String = "", retryable: Bool = true) {
        self.sourcePath = sourcePath
        self.message = message
        self.code = code
        self.retryable = retryable
    }
}

public struct IngestResult: Equatable, Sendable {
    public var copied: [String]
    public var skipped: [String]
    /// 计划阶段拒绝的源（不可读/路径越界）。
    public var unreadable: [String]
    public var secondCopied: [String]
    public var failed: [IngestFailure]
    /// 目标已存在且内容一致（plan 阶段判定）；这些路径也必须登记。
    public var alreadyPresent: [String]
    /// Wave2（task-15）：命中全库重复的源（分类计数，供预览/结果展示）。
    public var libraryDuplicates: [String]
    /// Wave2：因库内重复被跳过的源（skip 策略或 replace 退化）。
    public var librarySkipped: [String]
    /// Wave2：按 replace 策略覆盖写入的目标路径。
    public var replaced: [String]
    /// Wave4a-F4：replace 项在第二目的地被跳过（replace 目标是库内原路径，
    /// 不在 destinationRoot 内，无法按相对路径镜像；显式报告而不是静默少一份）。
    public var secondSkipped: [String]
    /// Wave5（F4）：源里被跳过的「不支持格式」（plan 阶段收集，执行期原样带出）。
    public var unsupportedFormats: IngestUnsupportedFormats
    public init(copied: [String], skipped: [String], unreadable: [String] = [],
                secondCopied: [String], failed: [IngestFailure],
                alreadyPresent: [String] = [],
                libraryDuplicates: [String] = [],
                librarySkipped: [String] = [],
                replaced: [String] = [],
                secondSkipped: [String] = [],
                unsupportedFormats: IngestUnsupportedFormats = IngestUnsupportedFormats()) {
        self.copied = copied
        self.skipped = skipped
        self.unreadable = unreadable
        self.secondCopied = secondCopied
        self.failed = failed
        self.alreadyPresent = alreadyPresent
        self.libraryDuplicates = libraryDuplicates
        self.librarySkipped = librarySkipped
        self.replaced = replaced
        self.secondSkipped = secondSkipped
        self.unsupportedFormats = unsupportedFormats
    }
    /// 登记阶段要扫描的目录（等于成功落地的父目录集合）。
    public var registeredDirectories: [String] {
        Array(Set((copied + alreadyPresent).map { ($0 as NSString).deletingLastPathComponent })).sorted()
    }
}

/// 单张源文件的拍摄元数据（摄取重命名模板的输入）。
public struct IngestCaptureMetadata: Equatable, Sendable {
    /// EXIF DateTimeOriginal（缺失时回退文件 mtime；仍缺失则由调用方用 now()）。
    public var date: Date?
    /// 相机型号（{camera} 占位符）；缺失为 nil。
    public var cameraModel: String?

    public init(date: Date? = nil, cameraModel: String? = nil) {
        self.date = date
        self.cameraModel = cameraModel
    }
}

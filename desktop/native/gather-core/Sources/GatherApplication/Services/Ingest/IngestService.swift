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
// - 第二目的地只在主目的地校验通过后才复制；任何一步失败都记进结果，不抛出中断整批。
import Foundation
import CryptoKit
import GatherProtocol

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
        // {seq:N} 支持任意宽度
        if let range = result.range(of: "\\{seq:[0-9]+\\}", options: .regularExpression) {
            let token = String(result[range])
            let width = Int(token.dropFirst(5).dropLast()) ?? 4
            result = result.replacingOccurrences(of: token, with: pad(sequence, width))
        }
        result = result.replacingOccurrences(of: "{seq}", with: pad(sequence, 4))
        return result
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
    /// 与照片同名的 XMP 侧车（存在才搬；否则移动照片会把元数据留在卡上）。
    public var sidecarPath: String?
    /// 共享侧车（RAW+JPEG 同 stem）的第二张必须复用第一张的目标侧车，
    /// 不能各自按目标 stem 再生成一份。
    public var destSidecarOverride: String?
    public init(sourcePath: String, destPath: String, conflict: Bool, size: Int,
                sidecarPath: String? = nil, destSidecarPath: String? = nil) {
        self.sourcePath = sourcePath
        self.destPath = destPath
        self.conflict = conflict
        self.size = size
        self.sidecarPath = sidecarPath
        self.destSidecarOverride = destSidecarPath
    }

    /// 侧车在目标目录的同名路径（照片扩展名换成 .xmp）。
    public var destSidecarPath: String {
        destSidecarOverride ?? ((destPath as NSString).deletingPathExtension + ".xmp")
    }
}

public struct IngestPlan: Equatable, Sendable {
    public var items: [IngestItem]
    public var skipped: [String]
    public var unreadable: [String]
    public init(items: [IngestItem], skipped: [String], unreadable: [String]) {
        self.items = items
        self.skipped = skipped
        self.unreadable = unreadable
    }
    public var conflictCount: Int { items.filter(\.conflict).count }
}

public struct IngestOptions: Equatable, Sendable {
    public var destinationRoot: String
    public var renameTemplate: String
    public var secondDestinationRoot: String?
    public var verifyChecksum: Bool
    public var moveInsteadOfCopy: Bool

    public init(destinationRoot: String, renameTemplate: String = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
                secondDestinationRoot: String? = nil, verifyChecksum: Bool = true,
                moveInsteadOfCopy: Bool = false) {
        self.destinationRoot = destinationRoot
        self.renameTemplate = renameTemplate
        self.secondDestinationRoot = secondDestinationRoot
        self.verifyChecksum = verifyChecksum
        self.moveInsteadOfCopy = moveInsteadOfCopy
    }
}

public struct IngestFailure: Equatable, Sendable {
    public var sourcePath: String
    public var message: String
    public init(sourcePath: String, message: String) {
        self.sourcePath = sourcePath
        self.message = message
    }
}

public struct IngestResult: Equatable, Sendable {
    public var copied: [String]
    public var skipped: [String]
    /// 计划阶段拒绝的源（不可读/路径越界）。
    public var unreadable: [String]
    public var secondCopied: [String]
    public var failed: [IngestFailure]
    public init(copied: [String], skipped: [String], unreadable: [String] = [],
                secondCopied: [String], failed: [IngestFailure]) {
        self.copied = copied
        self.skipped = skipped
        self.unreadable = unreadable
        self.secondCopied = secondCopied
        self.failed = failed
    }
    /// 登记阶段要扫描的目录（等于成功落地的父目录集合）。
    public var registeredDirectories: [String] {
        Array(Set(copied.map { ($0 as NSString).deletingLastPathComponent })).sorted()
    }
}

// MARK: - 服务

public final class IngestService: @unchecked Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileManager = fileManager
        self.now = now
    }

    /// 计划：扫描源目录（不递归子目录之外的东西，不碰库）。
    public func plan(
        sourcePaths: [String],
        options: IngestOptions,
        extensions: Set<String> = [
            "cr3", "cr2", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw",
            "jpg", "jpeg", "tif", "tiff", "png", "webp", "heic", "heif", "psd",
        ],
        existingChecksums: [String: String] = [:]
    ) throws -> IngestPlan {
        var items: [IngestItem] = []
        var skipped: [String] = []
        var unreadable: [String] = []
        var sequence = 1
        var usedDestinations = Set<String>()
        var seenSources = Set<String>()
        var sharedSidecarDestinations: [String: String] = [:]

        for source in sourcePaths {
            // 同一目录与其子项一起传入时只处理一次，避免同文件两份拷贝。
            let sourceKey = (source as NSString).standardizingPath
            guard seenSources.insert(sourceKey).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else {
                unreadable.append(source)
                continue
            }
            let files: [String]
            if isDirectory.boolValue {
                // 卡片根/DCIM 的照片常在子目录：递归枚举，避免"选目录却 0 张"。
                var found: [String] = []
                if let enumerator = fileManager.enumerator(atPath: source) {
                    for case let relative as String in enumerator {
                        let full = (source as NSString).appendingPathComponent(relative)
                        var childIsDir: ObjCBool = false
                        if fileManager.fileExists(atPath: full, isDirectory: &childIsDir),
                           !childIsDir.boolValue {
                            found.append(full)
                        }
                    }
                }
                files = found.sorted()
            } else {
                files = [source]
            }
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
                let attrs = try? fileManager.attributesOfItem(atPath: file)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let name = (file as NSString).lastPathComponent
                // 已有照片校验和命中 → 已导入过，跳过（不重复占盘）。
                if !existingChecksums.isEmpty, let sum = try? checksum(file),
                   existingChecksums[sum] != nil {
                    skipped.append(file)
                    continue
                }
                let relative = IngestRenameTemplate.expand(
                    options.renameTemplate, originalName: name, date: now(), sequence: sequence, cameraModel: nil
                )
                let dest = (options.destinationRoot as NSString).appendingPathComponent(relative)
                // 模板是自由文本：{orig}/手写 ../ 都可能把文件送出目的地根目录。
                guard Self.isWithin(dest, root: options.destinationRoot) else {
                    unreadable.append(file)
                    continue
                }

                if usedDestinations.contains(dest) {
                    skipped.append(file)   // 模板里没有 {seq}/{orig} 时的自撞
                    continue
                }
                usedDestinations.insert(dest)

                var conflict = false
                if fileManager.fileExists(atPath: dest) {
                    // 同名但内容一致 → 跳过；不一致 → 冲突（绝不覆盖）。
                    let sourceSum = try? checksum(file)
                    let destSum = try? checksum(dest)
                    if let sourceSum, let destSum, sourceSum == destSum {
                        skipped.append(file)
                        continue
                    }
                    conflict = true
                }
                sequence += 1
                let sidecar = TSPath.xmpSidecarPath(file)
                let sidecarPath = fileManager.fileExists(atPath: sidecar) ? sidecar : nil
                var destSidecar: String?
                if let sidecarPath {
                    let key = (sidecarPath as NSString).standardizingPath
                    if let existing = sharedSidecarDestinations[key] {
                        destSidecar = existing
                    } else {
                        let created = TSPath.xmpSidecarPath(dest)
                        sharedSidecarDestinations[key] = created
                        destSidecar = created
                    }
                }
                items.append(IngestItem(
                    sourcePath: file, destPath: dest, conflict: conflict, size: size,
                    sidecarPath: sidecarPath, destSidecarPath: destSidecar))
            }
        }
        return IngestPlan(items: items, skipped: skipped, unreadable: unreadable)
    }

    /// 执行：临时文件 → 校验 → rename → 第二目的地。
    public func execute(_ plan: IngestPlan, options: IngestOptions) -> IngestResult {
        var copied: [String] = []
        var skipped: [String] = []
        var secondCopied: [String] = []
        var failed: [IngestFailure] = []

        for item in plan.items {
            if item.conflict {
                skipped.append(item.sourcePath)
                continue
            }
            do {
                // 防御性复核：计划之后路径仍不得逃逸目的地根目录。
                guard Self.isWithin(item.destPath, root: options.destinationRoot) else {
                    throw IngestError.outsideDestinationRoot(item.destPath)
                }
                let parent = (item.destPath as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try transfer(
                    item.sourcePath, to: item.destPath,
                    move: options.moveInsteadOfCopy, verify: options.verifyChecksum)
                copied.append(item.destPath)

                if let sidecar = item.sidecarPath,
                   fileManager.fileExists(atPath: sidecar) {
                    // 共享侧车：同批 RAW/JPEG 的第一张已把 <stem>.xmp 移走，第二张
                    // 看到源不存在是正常情况，不是失败。
                    let destSidecar = item.destSidecarPath
                    if fileManager.fileExists(atPath: destSidecar) {
                        // 共享侧车（RAW+JPEG 同批）第二张会看到第一张已复制好的目标；
                        // 内容相同 → 正常跳过；不同 → 绝不覆盖并报失败。
                        var sameContent = false
                        do {
                            sameContent = try checksum(sidecar) == checksum(destSidecar)
                        } catch {
                            sameContent = false
                        }
                        if sameContent {
                            // 已随兄弟照片复制完成。
                        } else {
                            failed.append(IngestFailure(
                                sourcePath: sidecar,
                                message: "destination sidecar already exists: \(destSidecar)"))
                        }
                    } else {
                        try fileManager.createDirectory(
                            atPath: (destSidecar as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true)
                        do {
                            try transfer(
                                sidecar, to: destSidecar,
                                move: options.moveInsteadOfCopy, verify: options.verifyChecksum)
                        } catch {
                            // 侧车失败 → 回滚已落地的照片，避免"照片进库、元数据留卡"。
                            if fileManager.fileExists(atPath: item.destPath) {
                                if options.moveInsteadOfCopy {
                                    do {
                                        try fileManager.moveItem(
                                            atPath: item.destPath, toPath: item.sourcePath)
                                    } catch {}
                                } else {
                                    do { try fileManager.removeItem(atPath: item.destPath) } catch {}
                                }
                            }
                            if copied.last == item.destPath { copied.removeLast() }
                            throw error
                        }
                    }
                }

                if let second = options.secondDestinationRoot {
                    let secondPath = try secondDestinationPath(
                        for: item.destPath, destinationRoot: options.destinationRoot, secondRoot: second)
                    try fileManager.createDirectory(
                        atPath: (secondPath as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: secondPath) {
                        throw IngestError.destinationExists(secondPath)
                    }
                    try fileManager.copyItem(atPath: item.destPath, toPath: secondPath)
                    secondCopied.append(secondPath)
                    if let sidecar = item.sidecarPath {
                        let destSidecar = item.destSidecarPath
                        if fileManager.fileExists(atPath: destSidecar) {
                            let secondSidecar = (secondPath as NSString).deletingPathExtension + ".xmp"
                            try fileManager.copyItem(atPath: destSidecar, toPath: secondSidecar)
                        }
                    }
                }
            } catch {
                failed.append(IngestFailure(sourcePath: item.sourcePath, message: String(describing: error)))
            }
        }
        return IngestResult(
            copied: copied, skipped: skipped + plan.skipped,
            unreadable: plan.unreadable, secondCopied: secondCopied, failed: failed)
    }

    /// 单文件落地：临时文件 → 校验 → 原子 rename。
    /// 移动模式下先算源校验和再移动；校验失败必须把文件放回源路径（绝不删唯一副本）。
    private func transfer(_ source: String, to dest: String, move: Bool, verify: Bool) throws {
        let temp = dest + ".gather-part"
        if fileManager.fileExists(atPath: temp) { try? fileManager.removeItem(atPath: temp) }
        guard !fileManager.fileExists(atPath: dest) else {
            throw IngestError.destinationExists(dest)
        }
        if move {
            let expected = verify ? try checksum(source) : nil
            try fileManager.moveItem(atPath: source, toPath: temp)
            do {
                if let expected {
                    let actual = try checksum(temp)
                    guard actual == expected else {
                        throw IngestError.checksumMismatch(source)
                    }
                }
            } catch {
                if !fileManager.fileExists(atPath: source) {
                    try? fileManager.moveItem(atPath: temp, toPath: source)
                }
                throw error
            }
            try fileManager.moveItem(atPath: temp, toPath: dest)
        } else {
            try fileManager.copyItem(atPath: source, toPath: temp)
            if verify {
                let sourceSum = try checksum(source)
                let tempSum = try checksum(temp)
                guard sourceSum == tempSum else {
                    try? fileManager.removeItem(atPath: temp)
                    throw IngestError.checksumMismatch(source)
                }
            }
            try fileManager.moveItem(atPath: temp, toPath: dest)
        }
    }

    /// 目标是否在根目录内（词法归一化；仅用于计划/执行的路径边界，不解析 symlink）。
    static func isWithin(_ path: String, root: String) -> Bool {
        // 目的地可能有 symlink 子目录：解析后再做前缀比较，避免写到根外。
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard !base.isEmpty else { return false }
        return target.hasPrefix(base + "/")
    }

    /// 第二目的地路径：按"相对主目的地的路径"拼接，禁止用字符串替换
    /// （根目录是另一路径的子串时会把目录结构拼坏）。
    private func secondDestinationPath(
        for dest: String, destinationRoot: String, secondRoot: String
    ) throws -> String {
        let root = (destinationRoot as NSString).standardizingPath
        let target = (dest as NSString).standardizingPath
        guard target.hasPrefix(root + "/") else {
            throw IngestError.outsideDestinationRoot(dest)
        }
        let relative = String(target.dropFirst(root.count + 1))
        return (secondRoot as NSString).appendingPathComponent(relative)
    }

    public enum IngestError: Error, Equatable, CustomStringConvertible {
        case checksumMismatch(String)
        case destinationExists(String)
        case outsideDestinationRoot(String)
        public var description: String {
            switch self {
            case .checksumMismatch(let path): "校验失败（复制后内容不一致）：\(path)"
            case .destinationExists(let path): "目标已存在，拒绝覆盖：\(path)"
            case .outsideDestinationRoot(let path): "目标不在目的地根目录下：\(path)"
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

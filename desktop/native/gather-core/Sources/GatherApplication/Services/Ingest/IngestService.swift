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
    public init(
        items: [IngestItem], skipped: [String], unreadable: [String],
        alreadyPresent: [String] = [],
        libraryDuplicates: [String] = [],
        librarySkipped: [String] = [],
        replaced: [String] = []
    ) {
        self.items = items
        self.skipped = skipped
        self.unreadable = unreadable
        self.alreadyPresent = alreadyPresent
        self.libraryDuplicates = libraryDuplicates
        self.librarySkipped = librarySkipped
        self.replaced = replaced
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

    public init(destinationRoot: String, renameTemplate: String = "{yyyy}/{MM}/{dd}/{orig}-{seq:4}.{ext}",
                secondDestinationRoot: String? = nil, verifyChecksum: Bool = true,
                moveInsteadOfCopy: Bool = false,
                duplicatePolicy: IngestDuplicatePolicy = .skip,
                sessionId: String = "", sessionSourceRoot: String = "") {
        self.destinationRoot = destinationRoot
        self.renameTemplate = renameTemplate
        self.secondDestinationRoot = secondDestinationRoot
        self.verifyChecksum = verifyChecksum
        self.moveInsteadOfCopy = moveInsteadOfCopy
        self.duplicatePolicy = duplicatePolicy
        self.sessionId = sessionId
        self.sessionSourceRoot = sessionSourceRoot
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
    public init(copied: [String], skipped: [String], unreadable: [String] = [],
                secondCopied: [String], failed: [IngestFailure],
                alreadyPresent: [String] = [],
                libraryDuplicates: [String] = [],
                librarySkipped: [String] = [],
                replaced: [String] = []) {
        self.copied = copied
        self.skipped = skipped
        self.unreadable = unreadable
        self.secondCopied = secondCopied
        self.failed = failed
        self.alreadyPresent = alreadyPresent
        self.libraryDuplicates = libraryDuplicates
        self.librarySkipped = librarySkipped
        self.replaced = replaced
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

public final class IngestService: @unchecked Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// P0 / C1：EXIF 读取端口（宿主注入 ImageIO 实现）。nil = 只按 mtime/now 命名。
    private let exif: (any ExifProvider)?

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        exif: (any ExifProvider)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.exif = exif
    }

    /// EXIF 时间戳是"相机本地时间"，不带时区：按当前时区解释（与 Lightroom/Bridge 一致）。
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// 递归枚举目录下的普通文件（不跟随符号链接目录，排序保证计划确定性）。
    private func enumerateFiles(under root: String) -> [String] {
        var found: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: root) else { return found }
        for case let relative as String in enumerator {
            let full = (root as NSString).appendingPathComponent(relative)
            var childIsDir: ObjCBool = false
            if fileManager.fileExists(atPath: full, isDirectory: &childIsDir),
               !childIsDir.boolValue {
                found.append(full)
            }
        }
        return found.sorted()
    }

    /// 读取单张源文件的拍摄日期/相机型号。
    ///
    /// 优先级：DateTimeOriginal → DateTimeDigitized → 文件 mtime → nil（调用方用 now()）。
    /// 解析失败只降级、不抛错：一张损坏的 EXIF 不能让整批摄取失败。
    private func captureMetadata(
        for file: String,
        attributes: [FileAttributeKey: Any]?
    ) async -> IngestCaptureMetadata {
        var result = IngestCaptureMetadata()
        if let exif {
            let isJpeg = ["jpg", "jpeg"].contains((file as NSString).pathExtension.lowercased())
            if let parsed = try? await exif.parse(filePath: file, isJpeg: isJpeg) {
                let rawDate = parsed.exif?["DateTimeOriginal"]?.stringValue
                    ?? parsed.exif?["DateTimeDigitized"]?.stringValue
                if let rawDate {
                    result.date = Self.exifDateFormatter.date(from: rawDate)
                }
                result.cameraModel = parsed.ifd0?["Model"]?.stringValue
                    ?? parsed.exif?["Model"]?.stringValue
            }
        }
        if result.date == nil {
            result.date = attributes?[.modificationDate] as? Date
        }
        return result
    }

    /// 摄取去重的 size 预筛：列出本次源文件的大小集合（目录递归同 plan）。
    /// 只 stat，不读内容；用于避免对整库未回填照片逐张 SHA-256。
    public func sourceSizes(sourcePaths: [String]) -> Set<Int> {
        var sizes = Set<Int>()
        for source in sourcePaths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else { continue }
            let files = isDirectory.boolValue ? enumerateFiles(under: source) : [source]
            for file in files {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: file)
                    if let size = (attrs[.size] as? NSNumber)?.intValue {
                        sizes.insert(size)
                    }
                } catch {
                    continue
                }
            }
        }
        return sizes
    }

    /// 计划：扫描源目录（不递归子目录之外的东西，不碰库）。
    public func plan(
        sourcePaths: [String],
        options: IngestOptions,
        extensions: Set<String> = [
            "cr3", "cr2", "nef", "arw", "raf", "orf", "rw2", "dng", "pef", "srw",
            "jpg", "jpeg", "tif", "tiff", "png", "webp", "heic", "heif", "psd",
        ],
        existingChecksums: [String: String] = [:],
        libraryDuplicates: [String: SessionService.LibraryDuplicateTarget] = [:]
    ) async throws -> IngestPlan {
        var items: [IngestItem] = []
        var skipped: [String] = []
        var unreadable: [String] = []
        var alreadyPresent: [String] = []
        // Wave2（task-15）：跨工作区重复的分类账（与策略无关）。
        var libraryDuplicatePaths: [String] = []
        var librarySkippedPaths: [String] = []
        var replacedSources: [String] = []
        var sequence = 1
        var usedDestinations = Set<String>()
        var usedDestinationsFolded = Set<String>()
        var seenSources = Set<String>()
        /// (源目录, 源 stem) → 第一张的目标 stem（相对目的地根、不含扩展名）。
        /// 兄弟必须复用同一 stem：sidecar 按 stem 推导，stem 不同会让第二张解析到不存在的
        /// .xmp，RAW/JPEG 的配对键（stem）也会一起失配。
        var sharedStems: [String: String] = [:]
        /// 每项所属的 stem 组（与 items 平行）；冲突传播在收集结束后统一做。
        var stemKeys: [String] = []

        for source in sourcePaths {
            // 同一目录与其子项一起传入时只处理一次，避免同文件两份拷贝。
            // 去重只按“最终文件”做：直接传入的文件此前若先插入 sourceKey，
            // 内层对同一路径的 insert 会失败，导致单文件 plan 静默为空。
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source, isDirectory: &isDirectory) else {
                unreadable.append(source)
                continue
            }
            // 卡片根/DCIM 的照片常在子目录：递归枚举，避免"选目录却 0 张"。
            // NSEnumerator 的迭代器在 async 上下文不可用，枚举本身放进同步方法。
            let files = isDirectory.boolValue ? enumerateFiles(under: source) : [source]
            for file in files {
                // 目录与其内文件同时传入时，枚举结果也要进去重集合（否则会复制两份）。
                guard seenSources.insert((file as NSString).standardizingPath).inserted else { continue }
                let ext = (file as NSString).pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
                let attrs = try? fileManager.attributesOfItem(atPath: file)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let name = (file as NSString).lastPathComponent
                // Wave2（task-15）：先去重再读 EXIF（重导同一张卡时，被跳过的文件
                // 不必做 ImageIO 解析）。
                // 优先级：全库（跨工作区）索引 > 会话内索引。两者都只比较 SHA-256。
                let probedChecksum: String? = {
                    guard !libraryDuplicates.isEmpty || !existingChecksums.isEmpty else {
                        return nil
                    }
                    return try? checksum(file)
                }()
                if let sum = probedChecksum {
                    if !libraryDuplicates.isEmpty, let target = libraryDuplicates[sum] {
                        libraryDuplicatePaths.append(file)
                        switch options.duplicatePolicy {
                        case .skip:
                            librarySkippedPaths.append(file)
                            continue
                        case .coexist:
                            // 显式选择并存：照常复制并登记（目标重名由既有唯一化处理）。
                            break
                        case .replace:
                            // 只覆盖"同一工作区 + 原路径在源根内"的登记文件；其余退化跳过，
                            // 绝不跨工作区改写别人登记的路径。
                            guard target.sessionId == options.sessionId,
                                  !options.sessionSourceRoot.isEmpty,
                                  Self.isWithin(
                                    target.filepath, root: options.sessionSourceRoot)
                            else {
                                librarySkippedPaths.append(file)
                                continue
                            }
                            let replaceSidecarCandidate = TSPath.xmpSidecarPath(file)
                            let replaceSidecar: String? =
                                fileManager.fileExists(atPath: replaceSidecarCandidate)
                                    ? replaceSidecarCandidate : nil
                            replacedSources.append(file)
                            items.append(IngestItem(
                                sourcePath: file,
                                destPath: target.filepath,
                                conflict: false,
                                size: size,
                                sidecarPath: replaceSidecar,
                                replaceExisting: true))
                            continue
                        }
                    } else if libraryDuplicates.isEmpty, existingChecksums[sum] != nil {
                        // Wave2 之前的老路径：只做会话内去重（保留给旧调用/测试）。
                        skipped.append(file)
                        continue
                    }
                }
                // P0 / C1：命名模板的日期/相机来自 EXIF，不是导入时间。
                // P2：模板没用到日期/相机时不读 EXIF（大卡导入少一轮 IO）。
                let capture = IngestRenameTemplate.usesCaptureMetadata(options.renameTemplate)
                    ? await captureMetadata(for: file, attributes: attrs)
                    : IngestCaptureMetadata()
                let sidecarCandidate = TSPath.xmpSidecarPath(file)
                let sidecarPath: String? = fileManager.fileExists(atPath: sidecarCandidate)
                    ? sidecarCandidate : nil
                // 兄弟判定按 (源目录, 源 stem)——与 RAW/JPEG 配对键同源（AssetRepo+Scan
                // 按 stem 分组）。sidecar 只决定"要不要跟着搬"，不能拿它当归组键：没有 .xmp
                // 的 RAW+JPEG 同样必须落在同一目标 stem，否则配对候选一条都生成不了。
                // 目录保持原样：大小写敏感卷上 A/ 与 a/ 是不同目录，不能并组。
                let stemKey = TSPath.dirname(file) + "\u{0}"
                    + TSPath.stem(name).lowercased()
                let relative: String
                if let sharedStem = sharedStems[stemKey] {
                    // 兄弟沿用第一张的 stem，只保留自己的扩展名。
                    relative = sharedStem + "." + ext
                } else {
                    relative = IngestRenameTemplate.expand(
                        options.renameTemplate, originalName: name,
                        date: capture.date ?? now(),
                        sequence: sequence, cameraModel: capture.cameraModel)
                }
                let dest = (options.destinationRoot as NSString).appendingPathComponent(relative)
                // 模板是自由文本：{orig}/手写 ../ 都可能把文件送出目的地根目录。
                guard Self.isWithin(dest, root: options.destinationRoot) else {
                    unreadable.append(file)
                    continue
                }

                // 大小写不敏感卷上 "IMG_1.CR3" 与 "img_1.cr3" 是同一个目标：
                // 只按原串去重会让第二张到执行期才撞 destinationExists 并回滚。
                let destKey = dest.precomposedStringWithCanonicalMapping.lowercased()
                if usedDestinations.contains(dest) || usedDestinationsFolded.contains(destKey) {
                    skipped.append(file)   // 模板里没有 {seq}/{orig} 时的自撞
                    continue
                }
                usedDestinations.insert(dest)
                usedDestinationsFolded.insert(destKey)

                var conflict = false
                if fileManager.fileExists(atPath: dest) {
                    // 同名但内容一致 → 跳过；不一致 → 冲突（绝不覆盖）。
                    let sourceSum = try? checksum(file)
                    let destSum = try? checksum(dest)
                    if let sourceSum, let destSum, sourceSum == destSum {
                        // 目标已存在且内容一致：不复制，但必须让调用方登记目标路径。
                        alreadyPresent.append(dest)
                        continue
                    }
                    conflict = true
                }
                // 冲突项也占序号：同名模板（{seq}）下不占位会与后续照片撞名。
                if sharedStems[stemKey] == nil {
                    sequence += 1
                    sharedStems[stemKey] = (relative as NSString).deletingPathExtension
                }
                stemKeys.append(stemKey)
                items.append(IngestItem(
                    sourcePath: file, destPath: dest, conflict: conflict, size: size,
                    sidecarPath: sidecarPath))
            }
        }
        // 冲突传播（整组）：同 stem 兄弟只要有一张与既有文件内容不同，整组都不能落地，
        // 否则会出现"RAW 落地 + 既有异内容 JPEG 同 stem"的假配对候选。这里做后处理，
        // 因为先出现的项当时还不知道后面的兄弟会冲突。
        var conflicted = Set<String>()
        for (index, key) in stemKeys.enumerated() where items[index].conflict {
            conflicted.insert(key)
        }
        if !conflicted.isEmpty {
            for index in items.indices where conflicted.contains(stemKeys[index]) {
                items[index].conflict = true
            }
        }
        return IngestPlan(
            items: items, skipped: skipped, unreadable: unreadable,
            alreadyPresent: alreadyPresent,
            libraryDuplicates: libraryDuplicatePaths,
            librarySkipped: librarySkippedPaths,
            replaced: replacedSources)
    }

    /// 执行：临时文件 → 校验 → rename → 第二目的地；单张失败整体回滚（见文件头）。
    public func execute(
        _ plan: IngestPlan,
        options: IngestOptions,
        shouldCancel: () -> Bool = { false },
        onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) -> IngestResult {
        var copied: [String] = []
        var skipped: [String] = []
        var secondCopied: [String] = []
        var failed: [IngestFailure] = []
        /// Wave2（task-15）：replace 策略下实际覆盖写入的目标路径。
        var replacedDestinations: [String] = []

        for item in plan.items {
            // P1-3：Job 取消时在文件边界停下，已完成的文件保持已落地/可登记状态。
            if shouldCancel() {
                break
            }
            if item.conflict {
                skipped.append(item.sourcePath)
                onProgress(copied.count + skipped.count + failed.count, plan.items.count)
                continue
            }
            // 单张原子性：只回滚这张自己产出的文件。
            // - mainCreated 只在 transfer 成功后置位：目标已存在（并发/重复 execute）时
            //   绝不能把别人已落地的文件删掉；
            // - 共享 sidecar 可能由兄弟创建，也不能因为后一张失败就删兄弟的 xmp。
            var mainCreated = false
            var sidecarMovedFrom: String?
            var sidecarCreated: String?
            var secondPath: String?
            var secondCopyStarted = false
            /// Wave2：replace 策略的旧文件备份路径（失败时原样还原）。
            var replaceBackup: String?
            do {
                // 防御性复核：计划之后路径仍不得逃逸目的地根目录。
                // Wave2：replace 项的目标是**库内已有照片的原路径**，允许落在
                // destinationRoot 之外，但仍必须在本会话源根内（plan 已校验，
                // 这里是执行期第二道闸）。
                if item.replaceExisting {
                    guard !options.sessionSourceRoot.isEmpty,
                          Self.isWithin(item.destPath, root: options.sessionSourceRoot) else {
                        throw IngestError.outsideDestinationRoot(item.destPath)
                    }
                } else {
                    guard Self.isWithin(item.destPath, root: options.destinationRoot) else {
                        throw IngestError.outsideDestinationRoot(item.destPath)
                    }
                }
                let parent = (item.destPath as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                if item.replaceExisting {
                    // 先把旧文件挪到同目录备份名（原子 rename），再走同一条
                    // 临时文件 → 校验 → rename 路径写新文件；成功后删备份。
                    let backup = item.destPath + ".gather-prev"
                    if fileManager.fileExists(atPath: backup) {
                        try? fileManager.removeItem(atPath: backup)
                    }
                    try fileManager.moveItem(atPath: item.destPath, toPath: backup)
                    replaceBackup = backup
                }
                try transfer(
                    item.sourcePath, to: item.destPath,
                    move: options.moveInsteadOfCopy, verify: options.verifyChecksum)
                mainCreated = true

                if let sidecar = item.sidecarPath,
                   fileManager.fileExists(atPath: sidecar) {
                    // 共享 sidecar：同批 RAW/JPEG 的第一张已把 <stem>.xmp 移走，第二张
                    // 看到源不存在是正常情况，不是失败。
                    let destSidecar = item.destSidecarPath
                    if fileManager.fileExists(atPath: destSidecar) {
                        // 共享 sidecar（RAW+JPEG 同批）第二张会看到第一张已落地的目标；
                        // 内容相同 → 正常复用；不同 → 绝不覆盖，整张失败并回滚。
                        guard try checksum(sidecar) == checksum(destSidecar) else {
                            throw IngestError.destinationExists(destSidecar)
                        }
                    } else {
                        try fileManager.createDirectory(
                            atPath: (destSidecar as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true)
                        try transfer(
                            sidecar, to: destSidecar,
                            move: options.moveInsteadOfCopy, verify: options.verifyChecksum)
                        if options.moveInsteadOfCopy {
                            sidecarMovedFrom = sidecar
                        } else {
                            sidecarCreated = destSidecar
                        }
                    }
                }

                if let second = options.secondDestinationRoot {
                    let target = try secondDestinationPath(
                        for: item.destPath, destinationRoot: options.destinationRoot, secondRoot: second)
                    try fileManager.createDirectory(
                        atPath: (target as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    guard !fileManager.fileExists(atPath: target) else {
                        throw IngestError.destinationExists(target)
                    }
                    // 用 transfer（<dest>.gather-part → rename）而不是裸 copyItem：
                    // 半成品只可能落在我们自己的临时文件名上，目标路径出现即代表成功，
                    // 回滚标记只在成功后置位（不会删掉并发写者刚建好的文件）。
                    try transfer(item.destPath, to: target, move: false, verify: false)
                    secondPath = target
                    secondCopyStarted = true
                    if item.sidecarPath != nil {
                        let destSidecar = item.destSidecarPath
                        if fileManager.fileExists(atPath: destSidecar) {
                            let secondSidecar = (target as NSString).deletingPathExtension + ".xmp"
                            if fileManager.fileExists(atPath: secondSidecar) {
                                // 兄弟已把它复制过去（共享 sidecar + 共享 stem）：内容一致就复用，
                                // 不一致绝不覆盖。不判存在会让每对里的第二张 100% 假失败。
                                guard try checksum(destSidecar) == checksum(secondSidecar) else {
                                    throw IngestError.destinationExists(secondSidecar)
                                }
                            } else {
                                // 这是第二目的地里最后一个可失败步骤：transfer 失败时
                                // 半成品只落在 .gather-part 且由 transfer 清理，无需回滚。
                                try transfer(
                                    destSidecar, to: secondSidecar, move: false, verify: false)
                            }
                        }
                    }
                    secondCopied.append(target)
                }
                if let backup = replaceBackup {
                    // 所有步骤（照片 + sidecar + 第二副本）都成功后才丢弃旧文件备份。
                    try? fileManager.removeItem(atPath: backup)
                    replacedDestinations.append(item.destPath)
                }
                copied.append(item.destPath)
            } catch {
                // 回滚本张产物（与落地顺序相反）：第二副本 → sidecar → 照片。
                // 回滚本身失败不能静默：把需人工确认的路径写进失败原因。
                var rollbackErrors: [String] = []
                func note(_ action: () throws -> Void, _ label: String) {
                    do { try action() } catch { rollbackErrors.append("\(label): \(error)") }
                }
                if secondCopyStarted, let secondPath,
                   fileManager.fileExists(atPath: secondPath) {
                    note({ try fileManager.removeItem(atPath: secondPath) }, secondPath)
                }
                if let sidecarCreated,
                   fileManager.fileExists(atPath: sidecarCreated) {
                    note({ try fileManager.removeItem(atPath: sidecarCreated) }, sidecarCreated)
                }
                if let sidecarMovedFrom,
                   fileManager.fileExists(atPath: item.destSidecarPath) {
                    note({ try fileManager.moveItem(
                        atPath: item.destSidecarPath, toPath: sidecarMovedFrom) },
                         "\(item.destSidecarPath) -> \(sidecarMovedFrom)")
                }
                if mainCreated, fileManager.fileExists(atPath: item.destPath) {
                    if options.moveInsteadOfCopy {
                        note({ try fileManager.moveItem(
                            atPath: item.destPath, toPath: item.sourcePath) },
                             "\(item.destPath) -> \(item.sourcePath)")
                    } else {
                        note({ try fileManager.removeItem(atPath: item.destPath) },
                             item.destPath)
                    }
                }
                // Wave2：replace 策略的回滚最后做——先清掉本次写入的新文件，
                // 再把旧文件备份改回原路径；顺序反了会把旧文件覆盖掉。
                if let replaceBackup, fileManager.fileExists(atPath: replaceBackup) {
                    if fileManager.fileExists(atPath: item.destPath) {
                        try? fileManager.removeItem(atPath: item.destPath)
                    }
                    note({ try fileManager.moveItem(
                        atPath: replaceBackup, toPath: item.destPath) },
                         "\(replaceBackup) -> \(item.destPath)")
                }
                var message = String(describing: error)
                if !rollbackErrors.isEmpty {
                    message += "；回滚失败（文件可能留在目的地，需人工确认）："
                        + rollbackErrors.joined(separator: " | ")
                }
                let code = (error as? any CodedError)?.code.rawValue
                    ?? GatherErrorCode.INGEST_TRANSFER_FAILED.rawValue
                let retryable: Bool
                switch error {
                case IngestError.destinationExists, IngestError.outsideDestinationRoot:
                    retryable = false
                default:
                    retryable = true
                }
                failed.append(IngestFailure(
                    sourcePath: item.sourcePath, message: message,
                    code: code, retryable: retryable))
            }
            onProgress(copied.count + skipped.count + failed.count, plan.items.count)
        }
        // 已存在的主副本不走 items 循环；第二目的地可能仍缺（崩溃恢复常见）。
        // 补拷失败必须进 failed，不能让 job 以“全部成功”收尾。
        if let second = options.secondDestinationRoot {
            for dest in plan.alreadyPresent {
                do {
                    let target = try secondDestinationPath(
                        for: dest, destinationRoot: options.destinationRoot, secondRoot: second)
                    if !fileManager.fileExists(atPath: target) {
                        try fileManager.createDirectory(
                            atPath: (target as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true)
                        try transfer(dest, to: target, move: false, verify: false)
                        secondCopied.append(target)
                    }
                    let destSidecar = (dest as NSString).deletingPathExtension + ".xmp"
                    if fileManager.fileExists(atPath: destSidecar) {
                        let targetSidecar = (target as NSString).deletingPathExtension + ".xmp"
                        if fileManager.fileExists(atPath: targetSidecar) {
                            guard try checksum(destSidecar) == checksum(targetSidecar) else {
                                throw IngestError.destinationExists(targetSidecar)
                            }
                        } else {
                            try fileManager.createDirectory(
                                atPath: (targetSidecar as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
                            try transfer(destSidecar, to: targetSidecar, move: false, verify: false)
                        }
                    }
                } catch {
                    failed.append(IngestFailure(
                        sourcePath: dest,
                        message: "第二目的地补拷失败：\(error)",
                        code: (error as? any CodedError)?.code.rawValue
                            ?? GatherErrorCode.INGEST_TRANSFER_FAILED.rawValue,
                        retryable: true))
                }
            }
        }
        let result = IngestResult(
            copied: copied, skipped: skipped + plan.skipped,
            unreadable: plan.unreadable, secondCopied: secondCopied, failed: failed,
            alreadyPresent: plan.alreadyPresent,
            libraryDuplicates: plan.libraryDuplicates,
            librarySkipped: plan.librarySkipped,
            replaced: replacedDestinations)
        // 自动初审的唯一触发点在 WorkflowRegistry（GatherApplication）（ingest 完整收尾后入队），
        // 本服务只负责复制/登记，不持有 job/会话依赖。
        return result
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
            do {
                try fileManager.moveItem(atPath: temp, toPath: dest)
            } catch {
                // 源已搬到 temp：rename 失败时必须先移回源，否则唯一副本留在
                // .gather-part（下一次同目标摄取会把它当残留删掉）。
                if !fileManager.fileExists(atPath: source) {
                    do { try fileManager.moveItem(atPath: temp, toPath: source) } catch {}
                }
                throw error
            }
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

    /// 目标是否在根目录内：**解析 symlink 后**再做前缀比较（计划与 execute 前各查一次，
    /// 防止计划后有人在目的地里建 symlink 把写入带出根目录）。
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

    public enum IngestError: Error, Equatable, CustomStringConvertible, CodedError {
        case checksumMismatch(String)
        case destinationExists(String)
        case outsideDestinationRoot(String)
        public var code: GatherErrorCode {
            switch self {
            case .checksumMismatch: .INGEST_CHECKSUM_MISMATCH
            case .destinationExists: .INGEST_DESTINATION_EXISTS
            case .outsideDestinationRoot: .INGEST_PATH_INVALID
            }
        }

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

// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/IngestService+Plan.swift
// M14a：IngestService 按职责纯搬移拆分（方法体/注释/可见性逐字未改；随搬移的 private
// 成员保持文件级可见性）。角色：计划阶段（目录枚举 / EXIF 拍摄元数据 / size 预筛 / plan）。
import Foundation
import GatherProtocol

extension IngestService {

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
        /// 受支持扩展名（dotless、小写）。Wave5 / F4：默认值 = 统一白名单
        /// `PhotoFileTypes.supportedExtensions`（RAW + 位图 + 渲染位图的并集），
        /// 不再维护第二张字面量表；参数保留给测试注入更窄的白名单。
        extensions: Set<String> = Set(
            PhotoFileTypes.supportedExtensions.map { String($0.dropFirst()) }),
        existingChecksums: [String: String] = [:],
        libraryDuplicates: [String: SessionService.LibraryDuplicateTarget] = [:],
        /// Wave4a-F2：库内候选的大小集合。非空时只有 size 命中的源才值得 SHA-256
        /// （预检不再对整卡逐张哈希；大小不同必不是同内容）。
        libraryCandidateSizes: Set<Int> = []
    ) async throws -> IngestPlan {
        var items: [IngestItem] = []
        var skipped: [String] = []
        var unreadable: [String] = []
        var alreadyPresent: [String] = []
        // Wave2（task-15）：跨工作区重复的分类账（与策略无关）。
        var libraryDuplicatePaths: [String] = []
        var librarySkippedPaths: [String] = []
        var replacedSources: [String] = []
        // Wave5（F4）：不支持格式不再静默跳过——按扩展名分组累积，进预检/结果。
        let unsupportedTally = UnsupportedFormatTally()
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
                let name = (file as NSString).lastPathComponent
                let ext = (file as NSString).pathExtension.lowercased()
                guard extensions.contains(ext) else {
                    // Wave5（F4）：不支持格式（GIF/视频/未知 RAW 等）计入统计，
                    // 由预检与结果区显示"跳过 N 个（按扩展名）"，不再无声消失。
                    unsupportedTally.record(filepath: file)
                    continue
                }
                let attrs = try? fileManager.attributesOfItem(atPath: file)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                // Wave2（task-15）：先去重再读 EXIF（重导同一张卡时，被跳过的文件
                // 不必做 ImageIO 解析）。
                // 优先级：全库（跨工作区）索引 > 会话内索引。两者都只比较 SHA-256。
                // Wave4a-F2：预检只对「size 命中库内候选」的源做哈希（原实现只要库内
                // 有指纹就整卡逐张 SHA-256，预检成本≈复制）。会话内索引没有大小表，
                // 保留旧口径（existingChecksums 非空才哈希）。
                let needsProbe: Bool = {
                    guard !libraryDuplicates.isEmpty || !existingChecksums.isEmpty else {
                        return false
                    }
                    if !libraryDuplicates.isEmpty,
                       !libraryCandidateSizes.isEmpty,
                       !libraryCandidateSizes.contains(size) {
                        return !existingChecksums.isEmpty
                    }
                    return true
                }()
                let probedChecksum: String? = needsProbe ? (try? checksum(file)) : nil
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
            replaced: replacedSources,
            unsupportedFormats: unsupportedTally.snapshot())
    }
}

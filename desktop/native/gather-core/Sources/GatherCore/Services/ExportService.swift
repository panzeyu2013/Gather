// desktop/native/gather-core/Sources/GatherCore/Services/ExportService.swift
// Phase 3.6：原生导出管线。
//
// 该服务刻意保持在 GatherCore：预览、文件规划、断点续作、原图复制、
// ImageIO 转码与报告生成必须由同一条受控路径完成，不能让 WebView 直接
// 访问任意文件系统路径。命令层只负责参数解码和 JobService 编排。

import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

public struct NativeExportProgress: Equatable, Sendable {
    public let sessionId: String
    public let current: Int
    public let total: Int
    public let fileName: String
    public let bytesWritten: Int
    public let status: String
    public let errorMessage: String?

    public init(
        sessionId: String,
        current: Int,
        total: Int,
        fileName: String,
        bytesWritten: Int,
        status: String,
        errorMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.current = current
        self.total = total
        self.fileName = fileName
        self.bytesWritten = bytesWritten
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct NativeExportResumeState {
    public var destinations: [String: String]
    public var completedPhotoIds: Set<String>
    /// 每张已完成照片**当时**的边车版本（问题 1，第三轮审查）：只记录
    /// completedPhotoIds 无法区分「目标 XMP 已存在」与「目标 XMP 仍是最新」——
    /// 源 XMP 改过之后必须重新交付，而不是静默跳过。
    public var sidecarVersions: [String: String]
    public var onPlanned: ((String, String) -> Void)?
    public var onPlanReady: (() -> Void)?
    public var onCompleted: ((String, String) -> Void)?

    public init(
        destinations: [String: String] = [:],
        completedPhotoIds: Set<String> = [],
        sidecarVersions: [String: String] = [:],
        onPlanned: ((String, String) -> Void)? = nil,
        onPlanReady: (() -> Void)? = nil,
        onCompleted: ((String, String) -> Void)? = nil
    ) {
        self.destinations = destinations
        self.completedPhotoIds = completedPhotoIds
        self.sidecarVersions = sidecarVersions
        self.onPlanned = onPlanned
        self.onPlanReady = onPlanReady
        self.onCompleted = onCompleted
    }
}

public enum ExportServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case destinationInvalid
    case destinationAbsoluteRequired
    case destinationRootForbidden
    case destinationInsideSession
    case formatInvalid
    case variantPolicyInvalid
    case originalTransformNotAllowed
    case namingEmpty
    case namingInvalidCharacters
    case qualityInvalid
    case maxDimensionInvalid
    case startIndexInvalid
    case watermarkTypeUnsupported
    case watermarkTextEmpty
    case watermarkOpacityInvalid
    case watermarkFontSizeInvalid
    case scopeUnsupported
    case sessionNotFound
    case sourceMissing(String)
    /// 源文件存在但不可读（权限 / 卷离线）：计划诊断与执行共用同一码（P2-9 审计 3）。
    case sourceUnreadable(String)
    case exportPathInvalid
    case formatUnsupported
    case rawConvertUnsupported
    case xmpConflict
    case cancelled
    /// 本次交付零成功且存在失败项（审查 D02）：执行器原先正常返回，JobService 因此
    /// 记 succeeded、工作区推导出「已导出」——全失败被当成交付完成。
    case allFilesFailed(Int)

    public var description: String {
        switch self {
        case .destinationInvalid: return "EXPORT_DIR_INVALID"
        case .destinationAbsoluteRequired: return "EXPORT_DIR_ABSOLUTE_REQUIRED"
        case .destinationRootForbidden: return "EXPORT_DIR_ROOT_FORBIDDEN"
        case .destinationInsideSession: return "EXPORT_DIR_INSIDE_SESSION"
        case .formatInvalid: return "EXPORT_FORMAT_INVALID"
        case .variantPolicyInvalid: return "EXPORT_VARIANT_POLICY_INVALID"
        case .originalTransformNotAllowed: return "EXPORT_ORIGINAL_NO_TRANSFORM"
        case .namingEmpty: return "EXPORT_NAMING_EMPTY"
        case .namingInvalidCharacters: return "EXPORT_NAMING_INVALID_CHARS"
        case .qualityInvalid: return "EXPORT_JPEG_QUALITY_INVALID"
        case .maxDimensionInvalid: return "EXPORT_MAX_DIMENSION_INVALID"
        case .startIndexInvalid: return "EXPORT_START_INDEX_INVALID"
        case .watermarkTypeUnsupported: return "EXPORT_WATERMARK_TYPE_UNSUPPORTED"
        case .watermarkTextEmpty: return "EXPORT_WATERMARK_TEXT_EMPTY"
        case .watermarkOpacityInvalid: return "EXPORT_WATERMARK_OPACITY_INVALID"
        case .watermarkFontSizeInvalid: return "EXPORT_WATERMARK_FONT_SIZE_INVALID"
        case .scopeUnsupported: return "EXPORT_SCOPE_UNSUPPORTED"
        case .sessionNotFound: return "SESSION_NOT_FOUND"
        case .sourceMissing: return "EXPORT_SOURCE_MISSING"
        case .sourceUnreadable: return "EXPORT_SOURCE_UNREADABLE"
        case .exportPathInvalid: return "EXPORT_PATH_INVALID"
        case .formatUnsupported: return "EXPORT_FORMAT_UNSUPPORTED"
        case .rawConvertUnsupported: return "EXPORT_RAW_CONVERT_UNSUPPORTED"
        case .xmpConflict: return "EXPORT_XMP_CONFLICT"
        case .cancelled: return "CANCELLED"
        case .allFilesFailed: return "EXPORT_ALL_FAILED"
        }
    }

    public var errorDescription: String? { description }
}

/// 导出服务：原图安全复制、JPEG/TIFF 转码、断点续作和报告。
public final class ExportService {
    private let photoRepo: PhotoRepo
    private let sessionRepo: SessionRepo
    private let connection: DBConnection
    private let cancelLock = NSLock()
    /// 取消状态按**每次执行**（runId）而不是按会话（问题 2，第三轮审查）：
    /// 旧实现把取消位挂在 sessionId 上，同一会话并行导出两个目录时，
    /// B 开始会清掉 A 的取消位、取消 A 又会中断 B。
    private var cancelledRuns = Set<String>()
    /// sessionId → 该会话当前在跑的 runId（供「取消本会话全部导出」使用）。
    private var sessionRuns: [String: Set<String>] = [:]

    public init(photoRepo: PhotoRepo, sessionRepo: SessionRepo, connection: DBConnection) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.connection = connection
    }

    /// 只取消指定 run（问题 2 的验收：同会话并行导出时，取消 A 不得影响 B）。
    public func cancel(runId: String) {
        cancelLock.lock()
        cancelledRuns.insert(runId)
        cancelLock.unlock()
    }

    public func cancel(sessionId: String) {
        cancelLock.lock()
        // 会话级取消 = 枚举该会话当前在跑的所有 run（调度器语义）。
        for runId in sessionRuns[sessionId] ?? [] {
            cancelledRuns.insert(runId)
        }
        cancelLock.unlock()
    }

    /// 计划项（内部）：照片 + 解析后的输出名 + 目标 URL + 诊断。
    struct PlannedOutput {
        var photo: PhotoProjectionRow
        var name: String
        var url: URL
        var includesXmp: Bool
        var issue: String?
        /// 续跑已完成且文件仍在 → 本次会跳过并计成功（不应标成「会失败」）。
        var willSkip: Bool = false
    }

    /// 计划构建（唯一实现，D09）：预览与执行都调用它，命名规则不可能漂移。
    ///
    /// - Parameters:
    ///   - resumedNames: 断点续跑已确定的目标名（photoId -> name）。
    ///   - completedPhotoIds: 已完成且文件仍在的照片（决定是否能复用旧名）。
    ///   - onPlanned: 新确定名字时回调（执行路径借此写入 checkpoint）。
    /// - Returns: 计划项（顺序 = 照片顺序）与全部解析出的名字（供续跑状态持久化）。
    private func buildPlan(
        photos: [PhotoProjectionRow],
        options: ExportOptions,
        sessionName: String,
        destination: URL,
        resumedNames: [String: String],
        completedPhotoIds: Set<String>,
        onPlanned: ((String, String) -> Void)? = nil
    ) -> (items: [PlannedOutput], resolvedNames: [String: String]) {
        var usedNames = Set<String>()
        var resolved: [String: String] = [:]
        var items: [PlannedOutput] = []
        // P2-12（审计 3）：目标目录**枚举一次**建集合，代替逐张照片的多次 fileExists
        //（1 万张时旧实现约 5 万次 syscall，这里降到 1 次枚举 + O(1) 查表）。
        // 计划阶段只看快照；写入阶段仍按每个文件实时 exists 判定（见 execute）。
        let existingTargets = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        )
        // E-3：每次计划一份时间 formatter（循环内复用，不跨线程共享）。
        let timeFormatter = DateFormatter()
        for (index, photo) in photos.enumerated() {
            var name = resumedNames[photo.id]
            let resumedFileExists = name.map {
                completedPhotoIds.contains(photo.id) && existingTargets.contains($0)
            } ?? false
            let targetTaken = name.map { existingTargets.contains($0) } ?? false
            if name == nil || (!resumedFileExists && targetTaken) {
                name = resolveName(
                    photo: photo,
                    options: options,
                    counter: (options.naming.counterStart ?? 1) + index,
                    sessionName: sessionName,
                    timeFormatter: timeFormatter
                )
                name = uniqueName(
                    name ?? photo.filename,
                    usedNames: &usedNames,
                    destination: destination,
                    existingTargets: existingTargets
                )
                onPlanned?(photo.id, name ?? photo.filename)
            } else {
                usedNames.insert((name ?? "").lowercased())
            }
            let outputName = name ?? photo.filename
            resolved[photo.id] = outputName
            let outputURL = destination.appendingPathComponent(outputName)
            // 目标 sidecar 三态判定（P1-3 → 问题 1 验收后修订）：执行改为
            // 「新交付覆盖目标边车」（原子写），因此冲突不再是错误；三态仍用于
            // 续跑跳过判定（见 shouldSkipCompleted）与物理文件计数。
            var includesXmp = false
            let issue = sourceIssue(for: photo.filepath)
            if options.includeXmp, sidecarExists(forSource: photo.filepath) {
                switch destinationSidecarState(sourcePath: photo.filepath, outputURL: outputURL) {
                case .absent:
                    includesXmp = true
                case .identical:
                    // 执行确实不会再写（copyXMPIfPresent 内容相同即 return）。
                    includesXmp = false
                case .conflicting:
                    // 问题 1 验收后的语义：目标边车与源不同 → 本次会**覆盖**它
                    //（与照片文件的覆盖语义一致）。不再标记为会失败，否则预览说
                    // 失败、执行却成功（P1-3 当年要解决的正是这种不一致）。
                    includesXmp = true
                }
            }
            items.append(PlannedOutput(
                photo: photo,
                name: outputName,
                url: outputURL,
                includesXmp: includesXmp,
                issue: issue,
                // P2-2（审计 3）：已完成且文件仍在的续跑项会被跳过并计成功，
                // 不能标成「导出时会失败」。
                willSkip: resumedFileExists
            ))
        }
        return (items, resolved)
    }

    /// 源文件可执行性诊断（D09/P2-9 审计 3）：nil = 可正常导出。
    /// 用错误码枚举的 description，而不是裸字符串——改名/删码能被编译器发现。
    private func sourceIssue(for path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return ExportServiceError.sourceMissing(path).description
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return ExportServiceError.sourceUnreadable(path).description
        }
        return nil
    }

    /// 目标同名 .xmp 的状态（P1-3 审计 3）。
    private enum SidecarState {
        case absent
        case identical
        case conflicting
    }

    private func destinationSidecarState(sourcePath: String, outputURL: URL) -> SidecarState {
        let sourceSidecar = sidecarURL(forSource: sourcePath)
        let destinationSidecar = outputURL.deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: destinationSidecar.path) else { return .absent }
        // 内容相同 → 执行不写（copyXMPIfPresent 直接 return）；不同 → 执行会抛冲突。
        guard let sourceData = try? Data(contentsOf: sourceSidecar),
              let destinationData = try? Data(contentsOf: destinationSidecar) else {
            return .conflicting
        }
        return sourceData == destinationData ? .identical : .conflicting
    }

    private func sidecarURL(forSource path: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 统一输出计划（D09）：预览与执行必须描述同一份产物。
    ///
    /// 命名完全复用执行路径的同一套规则（resolveName + 重名后缀），因此这里的
    /// outputName 就是执行时会写出的名字；sidecar 只按源侧真实存在计数（与
    /// copyXMPIfPresent 的判定一致）；源文件不可读时给出逐项诊断而不是静默 0 字节。
    public func outputPlan(
        sessionId: String,
        options: ExportOptions,
        resumedNames: [String: String] = [:],
        completedPhotoIds: Set<String> = []
    ) throws -> [ExportPreviewFile] {
        let photos = try filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try sessionRepo.get(id: sessionId)?.name ?? sessionId
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL
        // 与 execute 调用同一个 buildPlan：名字、边车判定、诊断三项都不会漂移。
        let built = buildPlan(
            photos: photos,
            options: options,
            sessionName: sessionName,
            destination: destination,
            resumedNames: resumedNames,
            completedPhotoIds: completedPhotoIds
        )
        return built.items.map { item in
            let sourceURL = URL(fileURLWithPath: item.photo.filepath)
            let size = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)
                .map { Int($0.int64Value) } ?? 0
            return ExportPreviewFile(
                photoId: item.photo.id,
                filename: item.photo.filename,
                fileSize: size,
                outputName: item.name,
                format: options.format.rawValue,
                includesXmp: item.includesXmp,
                issue: item.issue,
                // 转码输出（jpeg/tiff）无法在不解码的情况下精确预测体积：按估算标注。
                isSizeEstimate: options.format != .original,
                willSkip: item.willSkip
            )
        }
    }

    /// 预览（D09）。
    ///
    /// - Parameters:
    ///   - resumedNames / completedPhotoIds: 断点续跑基线。传入后预览展示的就是
    ///     续跑执行**实际会写**的名字（否则只能按"全新交付"计算，遇到已存在的
    ///     目标文件会显示改名后缀，而真正的续跑会复用旧名）。
    public func preview(
        sessionId: String,
        options: ExportOptions,
        resumedNames: [String: String] = [:],
        completedPhotoIds: Set<String> = []
    ) throws -> ExportPreview {
        try validate(options)
        try assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        // D09：计划描述输出（目标名/格式/sidecar/逐项诊断），不再是源文件清单。
        let files = try outputPlan(
            sessionId: sessionId,
            options: options,
            resumedNames: resumedNames,
            completedPhotoIds: completedPhotoIds
        )
        let total = files.reduce(0) { $0 + $1.fileSize }
        // P1-2（审计 3）：按**目标 sidecar 路径去重**计数。
        // RAW/JPEG 兄弟变体共享同一个 c.xmp：两个输出名不同、sidecar 目标却是同一个，
        // 旧实现直接 filter{includesXmp}.count 会把物理文件数多算一个。
        let sidecarTargets = Set(
            files.filter { $0.includesXmp }.map { file in
                URL(fileURLWithPath: file.outputName).deletingPathExtension().path
            }
        )
        let sidecars = sidecarTargets.count
        return ExportPreview(
            totalFiles: files.count,
            totalSizeBytes: total,
            freeSpaceBytes: freeSpace(at: options.destination),
            files: files,
            photoCount: files.count,
            sidecarCount: sidecars,
            physicalFileCount: files.count + sidecars,
            issueCount: files.filter { $0.issue != nil }.count
        )
    }

    /// 源侧是否存在与照片同名的 sidecar（与 copyXMPIfPresent 的判定保持一致）。
    /// 边车版本（问题 1）：不存在 = "none"；存在 = 毫秒 mtime + size。
    /// 只做一次 stat，但足以让「改了 XMP」变成新交付。
    private func sidecarVersion(forSource path: String) -> String {
        let sidecar = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("xmp")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sidecar.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let mtime = attributes[.modificationDate] as? Date else { return "none" }
        return "\(Int64(mtime.timeIntervalSince1970 * 1000)):\(size)"
    }

    /// 目标边车是否存在（问题 1 的续跑校验）。
    /// 续跑跳过判定（问题 1 验收）。只有同时满足下列条件才复用完成记录：
    /// 目标照片存在；且（不需要边车，或）目标边车与源**内容一致**并且交付记录里
    /// 的边车版本与当前源一致。目标边车缺失（.absent）/ 内容不同（.conflicting）
    /// 都视为不可信 → 重新交付（会覆盖）。
    private func shouldSkipCompleted(
        plan: PlannedOutput,
        options: ExportOptions,
        state: NativeExportResumeState
    ) -> Bool {
        guard options.includeXmp, sidecarExists(forSource: plan.photo.filepath) else { return true }
        switch destinationSidecarState(sourcePath: plan.photo.filepath, outputURL: plan.url) {
        case .identical:
            // 内容一致本身即交付证明；但若存在交付版本记录，仍要求它与当前源一致
            //（防止「目标被外部改成与源相同、而记录是更早版本」这类边界）。
            if let recorded = state.sidecarVersions[plan.photo.id] {
                return recorded == sidecarVersion(forSource: plan.photo.filepath)
            }
            return true
        case .absent, .conflicting:
            return false
        }
    }

    /// 一次「安装文件」的可回滚凭据（D1）。
    ///
    /// 覆盖既有文件前把旧文件复制到目标目录内的隐藏备份；提交时删除备份，
    /// 回滚时用备份恢复（本次新建的文件则直接删除，不留半套产物）。
    final class FileInstallToken {
        let destination: URL
        private var backup: URL?
        private var sidecarDestination: URL?
        private var sidecarBackup: URL?
        init(destination: URL, backup: URL?, sidecarDestination: URL? = nil, sidecarBackup: URL? = nil) {
            self.destination = destination
            self.backup = backup
            self.sidecarDestination = sidecarDestination
            self.sidecarBackup = sidecarBackup
        }

        /// 已在目标目录留底的旧照片（同目录，保证同卷）。
        var photoBackup: URL? { backup }

        /// 写边车前留底：目标边车已存在才复制。
        func backupSidecar() {
            let sidecar = destination.deletingPathExtension().appendingPathExtension("xmp")
            sidecarDestination = sidecar
            guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
            let backupURL = sidecar.deletingLastPathComponent()
                .appendingPathComponent(".\(sidecar.lastPathComponent).gather-prev-\(UUID().uuidString)")
            try? FileManager.default.removeItem(at: backupURL)
            if (try? FileManager.default.copyItem(at: sidecar, to: backupURL)) != nil {
                sidecarBackup = backupURL
            }
        }

        func commit() {
            if let backup { try? FileManager.default.removeItem(at: backup) }
            if let sidecarBackup { try? FileManager.default.removeItem(at: sidecarBackup) }
            backup = nil
            sidecarBackup = nil
        }

        func rollback() {
            let fm = FileManager.default
            if let backup {
                try? fm.removeItem(at: destination)
                try? fm.moveItem(at: backup, to: destination)
            } else {
                try? fm.removeItem(at: destination)
            }
            backup = nil
            if let sidecarBackup, let sidecarDestination {
                try? fm.removeItem(at: sidecarDestination)
                try? fm.moveItem(at: sidecarBackup, to: sidecarDestination)
            }
            sidecarBackup = nil
        }
    }

    /// 把文件安装到目标位置：目标已存在时用临时文件 + 原子替换，并返回回滚凭据。
    private func installFile(from sourceURL: URL, to destinationURL: URL) throws -> FileInstallToken {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: destinationURL.path)
        var backup: URL?
        if existed {
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).gather-prev-\(UUID().uuidString)")
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: destinationURL, to: backupURL)
            backup = backupURL
        }
        do {
            if existed {
                let temporary = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(destinationURL.lastPathComponent).gather-replace-\(UUID().uuidString)")
                try fm.copyItem(at: sourceURL, to: temporary)
                defer { try? fm.removeItem(at: temporary) }
                _ = try fm.replaceItemAt(destinationURL, withItemAt: temporary)
            } else {
                try fm.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            if let backup { try? fm.removeItem(at: backup) }
            throw error
        }
        return FileInstallToken(destination: destinationURL, backup: backup)
    }

    private func destinationSidecarExists(forOutput outputURL: URL) -> Bool {
        let sidecar = outputURL.deletingPathExtension().appendingPathExtension("xmp")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    private func sidecarExists(forSource path: String) -> Bool {
        let sidecar = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("xmp")
        return FileManager.default.fileExists(atPath: sidecar.path)
    }

    public func execute(
        sessionId: String,
        options: ExportOptions,
        runId: String? = nil,
        onProgress: ((NativeExportProgress) -> Void)? = nil,
        resume: NativeExportResumeState? = nil
    ) throws -> ExportResult {
        try validate(options)
        try assertDestinationOutsideSource(sessionId: sessionId, destination: options.destination)
        // 问题 2：每次执行独立取消位；入口不再清任何公共标志。
        // runId 由调用方（任务 id）传入时，取消信号可精确到这一次执行。
        let runId = registerRun(sessionId: sessionId, preferredRunId: runId)
        defer { unregisterRun(sessionId: sessionId, runId: runId) }

        let photos = try filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try sessionRepo.get(id: sessionId)?.name ?? sessionId
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var state = resume ?? NativeExportResumeState()
        // D09：执行消费与预览**同一份** buildPlan（命名/重名/边车判定唯一实现）。
        // 旧实现把命名循环写在 execute 里，preview 另抄一份 → 两处规则可能漂移
        //（预览显示的名字与真正写出的名字不一致）。
        let built = buildPlan(
            photos: photos,
            options: options,
            sessionName: sessionName,
            destination: destination,
            resumedNames: state.destinations,
            completedPhotoIds: state.completedPhotoIds,
            onPlanned: { photoId, name in
                state.destinations[photoId] = name
                state.onPlanned?(photoId, name)
            }
        )
        // 保持原语义：解析出的名字写回续跑状态（检查点据此持久化）。
        for (photoId, name) in built.resolvedNames {
            state.destinations[photoId] = name
        }
        let plans = built.items
        state.onPlanReady?()

        var exported = 0
        var failed = 0
        var skipped = 0
        var completed = 0
        var errors: [String] = []
        // E-3：目标目录的 canonical 路径只解析一次（循环内是同一常量）。
        let canonicalDestination = canonicalPath(destination.path)

        for plan in plans {
            if isCancelled(runId) {
                skipped += 1
                continue
            }
            if state.completedPhotoIds.contains(plan.photo.id),
               FileManager.default.fileExists(atPath: plan.url.path),
               shouldSkipCompleted(plan: plan, options: options, state: state) {
                exported += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: 0, status: "done"))
                continue
            }

            // D1（深审）：安装回滚凭据 —— 覆盖既有文件前先留底，后续任一步失败
            // 都把旧照片/旧边车恢复回来（旧实现按 created 无条件删除目标，
            // 会把用户此前的交付删掉）。
            var installToken: FileInstallToken?
            do {
                try assertDestinationPath(plan.url, canonicalRoot: canonicalDestination)
                if options.format == .original {
                    installToken = try installFile(from: URL(fileURLWithPath: plan.photo.filepath), to: plan.url)
                } else {
                    let temporary = destination.appendingPathComponent(
                        ".\(plan.name).gather-export-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
                    )
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try convert(source: plan.photo.filepath, destination: temporary, options: options)
                    installToken = try installFile(from: temporary, to: plan.url)
                }
                if options.includeXmp {
                    installToken?.backupSidecar()
                    try copyXMPIfPresent(sourcePath: plan.photo.filepath, destinationPath: plan.url.path)
                }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: plan.url.path)[.size] as? NSNumber)
                    .map { Int($0.int64Value) } ?? 0
                // 整套产物（照片 + 边车）都写成了才丢弃备份：完成检查点也在此之后写入。
                installToken?.commit()
                exported += 1
                completed += 1
                state.completedPhotoIds.insert(plan.photo.id)
                state.onCompleted?(plan.photo.id, sidecarVersion(forSource: plan.photo.filepath))
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.name, bytesWritten: bytes, status: "done"))
            } catch ExportServiceError.cancelled {
                skipped += 1
            } catch {
                // D1：失败 = 本次没有完成；恢复覆盖前的旧文件（本次新建则删除半成品）。
                installToken?.rollback()
                let message = error is ExportServiceError ? String(describing: error) : (error as NSError).localizedDescription
                errors.append("\(plan.photo.filename): \(message)")
                failed += 1
                completed += 1
                onProgress?(NativeExportProgress(
                    sessionId: sessionId, current: completed, total: plans.count,
                    fileName: plan.photo.filename, bytesWritten: 0,
                    status: "error", errorMessage: message))
            }
        }

        return ExportResult(
            totalFiles: plans.count,
            exported: exported,
            failed: failed,
            skipped: skipped,
            errors: errors
        )
    }

    public func generateReport(
        sessionId: String,
        reportType: String,
        format: String? = nil
    ) throws -> ReportData {
        let requested = format == "md" ? ReportFormat.md : ReportFormat.csv
        switch reportType {
        case "session_summary":
            let rows = try connection.prepare(
                "SELECT filename, filepath, status FROM photos WHERE session_id = ? ORDER BY rowid"
            ).query([.text(sessionId)])
            if requested == .csv {
                var content = "filename,filepath,status\n"
                content += rows.map {
                    [($0[0].textValue ?? ""), ($0[1].textValue ?? ""), ($0[2].textValue ?? "")]
                        .map(Self.csvField).joined(separator: ",")
                }.joined(separator: "\n")
                return ReportData(path: "", content: content, format: .csv)
            }
            var content = "# Session summary\n\n"
            content += "Total photos: \(rows.count)\n\n"
            content += "| # | Filename | Path | Status |\n|---:|---|---|---|\n"
            for (index, row) in rows.enumerated() {
                content += "| \(index + 1) | \(Self.mdField(row[0].textValue ?? "")) | \(Self.mdField(row[1].textValue ?? "")) | \(Self.mdField(row[2].textValue ?? "")) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "person":
            // 成员数唯一真相 = COUNT(face_cluster_members)（face_clusters.member_count
            // 只是派生缓存，可能与实时成员表漂移）；与 FaceRepo 同一口径。
            let rows = try connection.prepare(
                """
                SELECT rb.role_name, rb.keywords, fc.label,
                       (SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = fc.id) AS member_count
                FROM role_bindings rb
                JOIN face_clusters fc ON rb.cluster_id = fc.id
                WHERE rb.session_id = ? ORDER BY rb.role_name
                """
            ).query([.text(sessionId)])
            var content = "# Person report\n\nBindings: \(rows.count)\n\n"
            content += "| Role | Keywords | Cluster | Members |\n|---|---|---|---:|\n"
            for row in rows {
                let keywords = (try? JSONValue.parse(row[1].textValue ?? "[]"))?.arrayValue?.joined(separator: ", ") ?? ""
                content += "| \(Self.mdField(row[0].textValue ?? "")) | \(Self.mdField(keywords)) | \(Self.mdField(row[2].textValue ?? "")) | \(row[3].intValue ?? 0) |\n"
            }
            return ReportData(path: "", content: content, format: .md)

        case "keyword":
            let rows = try connection.prepare(
                "SELECT DISTINCT keywords FROM role_bindings WHERE session_id = ? AND keywords != '[]'"
            ).query([.text(sessionId)])
            var keywords = Set<String>()
            for row in rows {
                keywords.formUnion((try? JSONValue.parse(row[0].textValue ?? "[]"))?.arrayValue ?? [])
            }
            let culling = try connection.prepare(
                "SELECT DISTINCT decision FROM culling_decisions WHERE session_id = ? AND decision != 'pending'"
            ).query([.text(sessionId)])
            for row in culling {
                if row[0].textValue == "keep" { keywords.insert("culling:keep") }
                if row[0].textValue == "reject" { keywords.insert("culling:reject") }
            }
            var content = "# Keyword report\n\n"
            content += keywords.sorted().map { "- \(Self.mdField($0))" }.joined(separator: "\n")
            if !keywords.isEmpty { content += "\n" }
            return ReportData(path: "", content: content, format: .md)

        default:
            return ReportData(path: "", content: "", format: requested)
        }
    }

    // MARK: - Validation and planning

    private func validate(_ options: ExportOptions) throws {
        guard !options.destination.isEmpty else { throw ExportServiceError.destinationInvalid }
        guard options.destination.hasPrefix("/") else { throw ExportServiceError.destinationAbsoluteRequired }
        let destination = URL(fileURLWithPath: options.destination).standardizedFileURL.path
        guard destination != "/" else { throw ExportServiceError.destinationRootForbidden }
        guard ExportFormat.allCases.contains(options.format) else { throw ExportServiceError.formatInvalid }
        if let policy = options.variantPolicy, !ExportVariantPolicy.allCases.contains(policy) {
            throw ExportServiceError.variantPolicyInvalid
        }
        if options.format == .original, options.maxDimension != nil || options.watermark != nil {
            throw ExportServiceError.originalTransformNotAllowed
        }
        guard !options.naming.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExportServiceError.namingEmpty
        }
        if options.naming.pattern.contains("/") || options.naming.pattern.contains("\\") || options.naming.pattern.contains("\0") {
            throw ExportServiceError.namingInvalidCharacters
        }
        if let quality = options.quality, quality.rounded() != quality || quality < 1 || quality > 100 {
            throw ExportServiceError.qualityInvalid
        }
        if let maxDimension = options.maxDimension, maxDimension < 1 {
            throw ExportServiceError.maxDimensionInvalid
        }
        if let start = options.naming.counterStart, start < 0 {
            throw ExportServiceError.startIndexInvalid
        }
        if let watermark = options.watermark {
            guard watermark.type == .text else { throw ExportServiceError.watermarkTypeUnsupported }
            guard !watermark.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExportServiceError.watermarkTextEmpty
            }
            guard watermark.opacity.isFinite, watermark.opacity >= 0, watermark.opacity <= 1 else {
                throw ExportServiceError.watermarkOpacityInvalid
            }
            if let fontSize = watermark.fontSize, !fontSize.isFinite || fontSize < 1 || fontSize > 1000 {
                throw ExportServiceError.watermarkFontSizeInvalid
            }
        }
    }

    private func assertDestinationOutsideSource(sessionId: String, destination: String) throws {
        guard let session = try sessionRepo.get(id: sessionId) else { throw ExportServiceError.sessionNotFound }
        guard !session.sourcePath.isEmpty else { return }
        let dest = canonicalPath(destination)
        let source = canonicalPath(session.sourcePath)
        if dest == source || isPathInside(dest, source) {
            throw ExportServiceError.destinationInsideSession
        }
    }

    /// 导出范围内的照片：预览、确认张数、实际写出的文件**唯一**的范围来源
    /// （F04：三处必须同源，不允许 UI 自己算一份）。
    ///
    /// 范围语义：
    /// - scope == .session：工作区全部照片（排除 status == "removed" 的记录，保持原行为）；
    /// - scope == .filtered：**保留片**——挑片决策为 keep 的照片。挑片决策的唯一真相源是
    ///   culling_decisions（见 CullingDecisionRepo 头注），这里只读它，不读镜像列；
    /// - scope == .selected：原生端没有跨页选择集契约，显式拒绝而不是静默降级成整个工作区
    ///   （静默降级正是 F04 要修的那类「承诺与结果不符」）。
    /// 交付身份指纹（审查 D01）：完整输出参数 + 本次实际参与导出的照片集合。
    ///
    /// 用途是把「同一次交付的断点续跑」与「一次新的交付」分开：
    /// - 指纹相同 → 复用同一任务身份，允许继承已完成清单（跳过已写文件 = 真续跑）；
    /// - 指纹不同（改命名/格式/尺寸/水印/XMP/范围/目录，或照片集合变化）→
    ///   全新交付身份，**不得**继承旧的 destinations / completedPhotoIds。
    ///
    /// 旧实现只用工作区级 dedupeKey（export.execute:<session>）：任务仓库把最近一次
    /// 终态任务的 checkpoint 补齐到新任务上，于是改了命名或开启 XMP 后，执行器看到
    /// 旧 photoId 已完成且旧文件仍在，直接算成功——用户拿到 exported=1，
    /// 却既没有新名字的文件，也没有新要求的 .xmp。
    public func deliveryFingerprint(sessionId: String, options: ExportOptions) throws -> String {
        let photos = try filteredPhotos(sessionId: sessionId, options: options)
        let sessionName = try sessionRepo.get(id: sessionId)?.name ?? sessionId
        // 必须是**规范化**编码：.sortedKeys 固定键序（同一请求必须恒得同一串，
        // 否则真续跑永远复用不了完成记录——有不变量断言守着）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let optionsJSON = String(decoding: try encoder.encode(options), as: UTF8.self)
        // F4（审计 1）：把「命名的求值输入」与「源内容身份」也纳入指纹。
        // 旧实现只有 options + photoId：
        //  (a) 命名含 {date}/{time}/{session}：隔天或改会话名后用同一预设再导会被判成
        //      同一次交付 → 继承 completedPhotoIds 且文件仍在 → 一个新文件都不写却报成功；
        //  (b) 源文件在 Capture One 里改过（photoId/选项都没变）同样被跳过，目标目录里
        //      留的还是旧内容。
        // 这里用「本次会算出的输出名（未做重名唯一化，因此不依赖目录当前内容）」
        // 覆盖 {date}/{time}/{session}，用照片行里的 checksum/size/mtime 覆盖源内容变化
        // ——都取自已有数据，不额外多做一次全量 stat。
        var rows: [String] = []
        rows.reserveCapacity(photos.count)
        // E-3 闭环（第二轮验证）：指纹路径同样每请求跑一次全量循环，
        // 这里也复用一份 formatter（局部量，不跨线程）。
        let timeFormatter = DateFormatter()
        for (index, photo) in photos.enumerated() {
            let planned = resolveName(
                photo: photo,
                options: options,
                counter: (options.naming.counterStart ?? 1) + index,
                sessionName: sessionName,
                timeFormatter: timeFormatter
            )
            // 问题 5（第三轮审查）：原为字面量 "(photo.id)"（漏插值），不同照片会
            // 产生相同指纹 → 任务去重身份碰撞。同时补边车版本（问题 1）：源 XMP 变了
            // 必须形成**新交付**，否则续跑会沿用旧元数据。
            rows.append("\(photo.id)|\(photo.checksum)|\(photo.checksumFileSize)|\(photo.checksumFileMtimeMs)|\(planned)|\(sidecarVersion(forSource: photo.filepath))")
        }
        let payload = [optionsJSON, sessionName, rows.joined(separator: "\n")].joined(separator: "\n---\n")
        return SHA256.hash(Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func filteredPhotos(sessionId: String, options: ExportOptions) throws -> [PhotoProjectionRow] {
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
        let scoped: [PhotoProjectionRow]
        switch options.scope {
        case .session:
            scoped = photos.filter { $0.status != "removed" }
        case .filtered:
            let decisions = try CullingDecisionRepo(connection: connection).getDecisions(sessionId)
            let keptPhotoIds = Set(
                decisions
                    .filter { $0.decision == CullingDecisionValue.keep.rawValue }
                    .map(\.photoId)
            )
            scoped = photos.filter { $0.status != "removed" && keptPhotoIds.contains($0.id) }
        case .selected:
            throw ExportServiceError.scopeUnsupported
        }
        let policy = options.variantPolicy ?? .preferred
        if policy == .all { return scoped }

        // RAW 判定复用全仓唯一真相源 AssetRepo.rawExtensions：media_type 分类、
        // RAW+JPEG 配对候选、相似度逻辑资产折叠（PhotoAssets）与图库/挑片的代表行
        // （PhotoRepo.preferredRowOrderSQL）全部引用本清单。此处原先内联的第三份
        // 字面量已漂移：.eip/.mef/.kdc/.mrw/.erf 被判成非 RAW（.preferred 误选
        // JPEG），.gpr/.raw/.rwl/.sr2 被判成 RAW（选出全仓其余规则都不承认的
        // "RAW"，且 RAWDecoder 也不支持这些扩展名 → jpeg/tiff 转换直接失败）。
        let rawExtensions = AssetRepo.rawExtensions
        let jpegExtensions: Set<String> = [".jpg", ".jpeg"]
        // 组顺序 = 导入序（资产首次出现），与 TS 的 Map 插入序一致。Swift
        // Dictionary 的遍历顺序随进程哈希种子变化，直接遍历 .values 会让
        // {counter} 命名与导出计划每次运行都不同（counter = counterStart + 计划下标）。
        var groups: [String: [PhotoProjectionRow]] = [:]
        var assetOrder: [String] = []
        for photo in scoped {
            let key = photo.assetId ?? photo.id
            if groups[key] == nil { assetOrder.append(key) }
            groups[key, default: []].append(photo)
        }
        // 扩展名取法与上方原实现逐字相同（URL.pathExtension 去前导点后补 '.'，
        // 无扩展名 → 空串），只把「表」换成共享清单。
        let extensionWithDot: (String) -> String = { filename in
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            return ext.isEmpty ? "" : ".\(ext)"
        }
        return assetOrder.compactMap { key -> PhotoProjectionRow? in
            guard let variants = groups[key] else { return nil }
            // policy == .all 已被上方早退覆盖，故这里只有三个可达分支
            //（原 switch 的 .all 分支不可达，已删除）。
            if policy == .raw {
                return variants.first { rawExtensions.contains(extensionWithDot($0.filename)) }
            }
            if policy == .jpeg {
                return variants.first { jpegExtensions.contains(extensionWithDot($0.filename)) }
            }
            return variants.first { rawExtensions.contains(extensionWithDot($0.filename)) }
                ?? variants.first { jpegExtensions.contains(extensionWithDot($0.filename)) }
                ?? variants.first
        }
    }

    /// - Parameter timeFormatter: 每次**计划**一份（E-3 性能审计）：旧实现每张照片
    ///   新建 DateFormatter（1 万张 × 3 遍交付 ≈ 3 万个）。仍不跨线程共享，
    ///   保持原先「静态 formatter 有数据竞争」的修复意图。
    private func resolveName(
        photo: PhotoProjectionRow,
        options: ExportOptions,
        counter: Int,
        sessionName: String,
        timeFormatter: DateFormatter? = nil
    ) -> String {
        let filename = URL(fileURLWithPath: photo.filename).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        let base = sanitize(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
        let session = sanitize(sessionName)
        let date = Date()
        let dateFormat = options.naming.dateFormat ?? "YYYY-MM-DD"
        let dateString = dateFormat
            .replacingOccurrences(of: "YYYY", with: String(Calendar.current.component(.year, from: date)))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", Calendar.current.component(.month, from: date)))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", Calendar.current.component(.day, from: date)))
        // {time} 固定 HH-mm-ss（24h 制）：localizedString(.medium) 在 12h locale
        // 下产出 "3-45-30 PM"（含空格 + AM/PM），与 ExportView 预览的 HH-mm-ss
        // 不符。与 TS 的差异：TS 两端统一 24h 制，此处对齐该语义。
        // 审计 P1：静态 DateFormatter 被 worker 线程（并发导出）与主线程共用
        // 存在数据竞争，改为函数内新建（格式化成本可忽略）。
        let formatter = timeFormatter ?? DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        let time = formatter.string(from: date)
        var pattern = options.naming.pattern
        pattern = pattern.replacingOccurrences(of: "{date}", with: dateString)
        pattern = pattern.replacingOccurrences(of: "{time}", with: time)
        pattern = pattern.replacingOccurrences(of: "{counter}", with: String(format: "%04d", counter))
        pattern = pattern.replacingOccurrences(of: "{original}", with: base)
        // Older UI versions exposed {filename}; keep it as a compatibility
        // alias so an existing saved preset never exports a literal token.
        pattern = pattern.replacingOccurrences(of: "{filename}", with: base)
        pattern = pattern.replacingOccurrences(of: "{session}", with: session)
        let targetExt = options.format == .jpeg ? "jpg" : options.format == .tiff ? "tiff" : ext
        return "\(pattern).\(targetExt.isEmpty ? "jpg" : targetExt)"
    }

    /// 重名唯一化。
    /// - Parameter existingTargets: 目标目录的**快照**（P2-12 审计 3：一次枚举代替逐名
    ///   fileExists）。nil 时退回实时查询（调用方没有目录快照的场景）。
    private func uniqueName(
        _ input: String,
        usedNames: inout Set<String>,
        destination: URL,
        existingTargets: Set<String>? = nil
    ) -> String {
        let url = URL(fileURLWithPath: input)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var candidate = input
        var index = 2
        func targetTaken(_ name: String) -> Bool {
            if let existingTargets { return existingTargets.contains(name) }
            return FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path)
        }
        while usedNames.contains(candidate.lowercased()) || targetTaken(candidate) {
            candidate = "\(base)_\(index)\(ext)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    /// - Parameter canonicalRoot: 目标目录的 canonical 路径（E-3：旧实现每个文件都
    ///   重新解析一次符号链，1 万张 ≈2 万次 resolvingSymlinksInPath，而目录是常量）。
    private func assertDestinationPath(_ url: URL, canonicalRoot: String) throws {
        let candidate = canonicalPath(url.path)
        let root = canonicalRoot
        guard candidate == root || isPathInside(candidate, root) else { throw ExportServiceError.exportPathInvalid }
    }

    private func isPathInside(_ candidate: String, _ directory: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: candidate).pathComponents
        let directoryComponents = URL(fileURLWithPath: directory).pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return Array(candidateComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func sanitize(_ value: String) -> String {
        let replaced = value.replacingOccurrences(of: "[<>:\"/\\\\|?*]", with: "_", options: .regularExpression)
        return URL(fileURLWithPath: replaced).lastPathComponent
    }

    private func freeSpace(at path: String) -> Int {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? -1
    }

    // MARK: - Files and image conversion

    private func copyXMPIfPresent(sourcePath: String, destinationPath: String) throws {
        let source = URL(fileURLWithPath: sourcePath).deletingPathExtension().appendingPathExtension("xmp")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = URL(fileURLWithPath: destinationPath).deletingPathExtension().appendingPathExtension("xmp")
        if FileManager.default.fileExists(atPath: destination.path) {
            let sourceData = try Data(contentsOf: source)
            let destinationData = try Data(contentsOf: destination)
            if sourceData == destinationData { return }
            // 问题 1（第三轮审查）验收：XMP 更新必须形成**新交付** —— 目标边车内容
            // 与源不同时覆盖（原子写），而不是抛冲突或静默跳过。
            try sourceData.write(to: destination, options: .atomic)
            return
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func convert(source: String, destination: URL, options: ExportOptions) throws {
#if canImport(ImageIO)
        let decoded: RAWDecodeResult
        do {
            decoded = try RAWDecoder.getPreview(
                path: source,
                maxDimension: options.maxDimension ?? Int.max,
                quality: 1
            )
        } catch {
            throw ExportServiceError.rawConvertUnsupported
        }
        guard let sourceRef = CGImageSourceCreateWithData(decoded.buffer as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil) else {
            throw ExportServiceError.rawConvertUnsupported
        }
        let outputImage = try applyingWatermark(image, watermark: options.watermark)
        let type: CFString = options.format == .jpeg ? "public.jpeg" as CFString : "public.tiff" as CFString
        let properties: [CFString: Any]
        if options.format == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: (options.quality ?? 85) / 100]
        } else {
            let compression: Int
            switch options.tiffCompression ?? .lzw {
            case .none: compression = 1
            case .lzw: compression = 5
            case .deflate: compression = 8
            }
            properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: compression] as CFDictionary]
        }
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw ExportServiceError.formatUnsupported
        }
        CGImageDestinationAddImage(destinationRef, outputImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw ExportServiceError.formatUnsupported }
#else
        _ = source
        _ = destination
        _ = options
        throw ExportServiceError.formatUnsupported
#endif
    }

#if canImport(ImageIO)
    private func applyingWatermark(_ image: CGImage, watermark: ExportWatermark?) throws -> CGImage {
        guard let watermark else { return image }
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportServiceError.formatUnsupported }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(CGFloat(watermark.opacity))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let font = CGFont("Helvetica" as CFString)
        let size = CGFloat(watermark.fontSize ?? 24)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font?.postScriptName ?? "Helvetica" as CFString, size, nil),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(watermark.content.prefix(256)), attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let margin = CGFloat(max(16, width / 40))
        let x: CGFloat
        let y: CGFloat
        switch watermark.position {
        case .center:
            x = (CGFloat(width) - bounds.width) / 2
            y = (CGFloat(height) - bounds.height) / 2
        case .bottomRight:
            x = CGFloat(width) - bounds.width - margin
            y = margin
        case .bottomLeft:
            x = margin
            y = margin
        }
        context.textPosition = CGPoint(x: max(0, x), y: max(0, y))
        CTLineDraw(line, context)
        return context.makeImage() ?? image
    }
#endif

    /// 登记一次执行（返回 runId）。execute 入口调用。
    private func registerRun(sessionId: String, preferredRunId: String?) -> String {
        let runId = preferredRunId ?? UUID().uuidString
        cancelLock.lock()
        sessionRuns[sessionId, default: []].insert(runId)
        cancelLock.unlock()
        return runId
    }

    private func unregisterRun(sessionId: String, runId: String) {
        cancelLock.lock()
        sessionRuns[sessionId]?.remove(runId)
        if sessionRuns[sessionId]?.isEmpty == true { sessionRuns[sessionId] = nil }
        cancelledRuns.remove(runId)
        cancelLock.unlock()
    }

    private func isCancelled(_ runId: String) -> Bool {
        cancelLock.lock()
        let cancelled = cancelledRuns.contains(runId)
        cancelLock.unlock()
        return cancelled
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func mdField(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}

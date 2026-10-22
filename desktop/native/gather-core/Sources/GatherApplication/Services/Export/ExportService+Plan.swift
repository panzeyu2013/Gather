// desktop/native/gather-core/Sources/GatherApplication/Services/Export/ExportService+Plan.swift
// P1-4 收口：ExportService 按角色拆分（纯移动——方法体/错误/事务边界/顺序逐字未改）。
// 角色：输出计划/预览/命名/路径校验/范围过滤/交付指纹（预览与执行共用同一份计划）。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreText
#endif

extension ExportService {

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
    func buildPlan(
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
    func sidecarVersion(forSource path: String) -> String {
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
    func shouldSkipCompleted(
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

    // MARK: - Validation and planning

    func validate(_ options: ExportOptions) throws {
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

    func assertDestinationOutsideSource(sessionId: String, destination: String) throws {
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

    func filteredPhotos(sessionId: String, options: ExportOptions) throws -> [PhotoProjectionRow] {
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
        let scoped: [PhotoProjectionRow]
        switch options.scope {
        case .session:
            scoped = photos.filter { $0.status != "removed" }
        case .filtered:
            let keptPhotoIds = try reports.keptPhotoIds(sessionId: sessionId)
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
        let rawExtensions = PhotoFileTypes.rawExtensions
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
    func assertDestinationPath(_ url: URL, canonicalRoot: String) throws {
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

    func canonicalPath(_ path: String) -> String {
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
}

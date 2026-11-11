// desktop/native/gather-core/Sources/GatherApplication/Services/FileOps/PhotoFileOpsService.swift
// Wave5（Batch4 / task-19）：照片级批量重命名 + 移动到文件夹。
//
// 与 RejectedMover（淘汰移出）同一套安全模型：
// - 写盘与改库分两步，但**按资产组**成组提交：任一环失败 → 该组文件与已提交的库路径
//   全部回滚，绝不留下"文件改了名、库还指旧路径"的半截状态；
// - sidecar（<stem>.xmp）必须随行：同 stem 还有兄弟留在库里 → 复制（兄弟的元数据不能丢）；
//   整组都改名/移走 → 移动一次，其余成员按"共享 sidecar"复制绑定
//   （relocate(sharesSidecar: true) → AssetRepo.copySidecarBindingForVariant）；
// - 交付备份（<xmp>.gather-backup-*）跟随 sidecar 一起改名/移动（否则 cleanup/finalize
//   会因备份落在旧 xmp 旁边判 invalidBackup 并永久滞留）；
// - replace 策略不直接覆盖：先把既有目标改名成 `<name>.gather-replaced-<uuid>` 备份，
//   组成功后删除备份；失败则恢复，绝不静默丢用户文件；
// - 绝不覆盖**同批选中的其它照片**：同批目标冲突一律失败（duplicateTarget），不看策略。
//
// 边界：不做删除、不重命名文件夹、不改派生分析；缩略图缓存失效与域事件由 UI 层在成功后处理。
// FileManager 用 `FileManager.default` 而非注入：FileManager 不是 Sendable，塞进 Sendable
// 结构会逼出 @unchecked（cleanup ratchet 预算）；测试直接建真实临时目录即可。
import Foundation
import GatherProtocol
import GatherPersistence

/// 盘上拍摄元数据（重命名 token 的日期/相机来源）。
public struct PhotoCaptureMetadata: Equatable, Sendable {
    public var date: Date?
    public var cameraModel: String?

    public init(date: Date? = nil, cameraModel: String? = nil) {
        self.date = date
        self.cameraModel = cameraModel
    }
}

/// 非 Sendable（与 CullingSyncService 同一口径）：relocate 闭包捕获宿主的
/// AssetRepo（非 Sendable），塞进 Sendable 结构会逼出 @unchecked 并抬高 ratchet 预算。
/// 生产宿主（LivePhotoAPI）本身是 @unchecked Sendable，构造后不可变地持有本服务。
public struct PhotoFileOpsService {
    /// 路径迁移（photos.filepath/filename + sidecar 绑定 + 交付/关键词来源 + asset_files）
    /// 由宿主在**一个事务**内完成（生产 = AssetRepo.relocatePhotoPathsAfterMove）。
    public typealias Relocate = (_ photoId: String, _ oldPath: String, _ newPath: String, _ sharesSidecar: Bool) throws -> Void
    /// EXIF 拍摄元数据读取接缝（生产 = ImageIO；测试注入固定值）。
    public typealias CaptureMetadataReader = @Sendable (_ filePath: String) async -> PhotoCaptureMetadata?

    /// 单批上限：一次误选不该把 UI 卡成分钟级（与 C1 变体写回同口径）。
    public static let maxItems = 500

    private let photoRepo: any PhotoRepository
    private let relocate: Relocate?
    private let captureMetadata: CaptureMetadataReader

    public init(
        photoRepo: any PhotoRepository,
        relocate: Relocate? = nil,
        captureMetadata: @escaping CaptureMetadataReader = { _ in nil }
    ) {
        self.photoRepo = photoRepo
        self.relocate = relocate
        self.captureMetadata = captureMetadata
    }

    // MARK: - 模板校验（纯函数，可测）

    /// 已知 token（不含花括号）；{seq:N} 单独按宽度校验。
    public static let knownTokens: Set<String> = [
        "yyyy", "MM", "dd", "HH", "mm", "ss", "orig", "ext", "camera", "seq",
    ]

    /// 模板里无法识别的 token（去重保序）；空数组 = 可执行。未闭合的 `{` 也计入。
    public static func invalidTokens(in template: String) -> [String] {
        var issues: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            guard let open = template[index...].firstIndex(of: "{") else { break }
            guard let close = template[open...].firstIndex(of: "}") else {
                let rest = String(template[open...])
                if !issues.contains(rest) { issues.append(rest) }
                break
            }
            let token = String(template[open...close])
            let body = String(template[template.index(after: open)..<close])
            let valid: Bool
            if body.hasPrefix("seq:") {
                let width = body.dropFirst(4)
                valid = !width.isEmpty && width.allSatisfy(\.isNumber)
                    && Int(width) != nil && width.count <= 3
            } else {
                valid = knownTokens.contains(body)
            }
            if !valid, !issues.contains(token) { issues.append(token) }
            index = template.index(after: close)
        }
        return issues
    }

    /// 重命名模板的路径安全：不允许目录分隔符/冒号（改名不是移动）。
    ///
    /// 冒号只检查 token 之外：{seq:3} 的冒号是 token 语法，不是路径分隔符。
    public static func isPathSafeTemplate(_ template: String) -> Bool {
        var inToken = false
        for character in template {
            switch character {
            case "{":
                inToken = true
            case "}":
                inToken = false
            case "/", "\\":
                return false
            case ":":
                if !inToken { return false }
            default:
                continue
            }
        }
        return true
    }

    // MARK: - 预览（只读）

    public func previewRename(_ input: PhotoRenamePreviewInput) async throws -> PhotoRenamePreview {
        let plan = try await renamePlan(input)
        return PhotoRenamePreview(
            sessionId: input.sessionId,
            items: plan.items.map(\.preview),
            invalidTokens: plan.invalidTokens,
            conflicts: plan.items.filter { $0.conflict != .none }.count,
            renameable: plan.items.filter { $0.conflict == .none }.count)
    }

    // MARK: - 重命名（写盘 + 改库）

    public func renamePhotos(_ input: PhotoRenameInput) async throws -> PhotoRenameResult {
        guard !input.photoIds.isEmpty else { return PhotoRenameResult() }
        try validateBatch(count: input.photoIds.count)
        let plan = try await renamePlan(PhotoRenamePreviewInput(
            sessionId: input.sessionId, photoIds: input.photoIds, template: input.template))
        guard plan.invalidTokens.isEmpty else {
            throw GatherError.invalidParameter(
                field: "template",
                reason: "unknown rename token(s): \(plan.invalidTokens.joined(separator: ", "))")
        }
        var report = PhotoRenameResult()
        var transfers: [PlannedTransfer] = []
        for item in plan.items {
            switch item.conflict {
            case .notInSession, .missingSource, .invalidToken:
                report.failed.append(item.failure(message: item.conflict.rawValue))
            case .duplicateTarget:
                report.failed.append(item.failure(
                    message: "同批照片渲染到同一个目标路径，拒绝覆盖：\(item.newPath)"))
            case .targetExists:
                switch input.conflictPolicy {
                case .skip:
                    report.skipped += 1
                case .coexist:
                    var transfer = item.transfer(target: item.newPath)
                    transfer.targetPath = Self.coexistingPath(target: item.newPath)
                    transfers.append(transfer)
                case .replace:
                    var transfer = item.transfer(target: item.newPath)
                    transfer.replaceExisting = true
                    transfers.append(transfer)
                }
            case .none:
                if Self.normalized(item.newPath) == Self.normalized(item.oldPath) {
                    report.skipped += 1
                } else {
                    transfers.append(item.transfer(target: item.newPath))
                }
            }
        }
        let groups = try sidecarGroups(transfers, sessionId: input.sessionId)
        for group in groups {
            let outcome = apply(group: group)
            report.renamed += outcome.renamed
            report.skipped += outcome.skipped
            report.failed.append(contentsOf: outcome.failed)
            for (photoId, path) in outcome.newPaths { report.newPaths[photoId] = path }
        }
        return report
    }

    // MARK: - 移动（写盘 + 改库）

    public func movePhotos(_ input: PhotoMoveInput) async throws -> PhotoMoveResult {
        guard !input.photoIds.isEmpty else { return PhotoMoveResult() }
        try validateBatch(count: input.photoIds.count)
        let destination = try Self.validatedDestination(input.destinationRoot)
        let resolved = try resolvedPhotos(input.photoIds, sessionId: input.sessionId)
        var report = PhotoMoveResult()
        report.failed.append(contentsOf: resolved.failures)
        var transfers: [PlannedTransfer] = []
        var plannedTargets = Set<String>()
        for row in resolved.rows {
            let oldPath = row.oldPath
            guard FileManager.default.fileExists(atPath: oldPath) else {
                report.failed.append(PhotoFileOpFailure(
                    photoId: row.photoId, path: oldPath, message: "源文件不存在"))
                continue
            }
            let filename = (oldPath as NSString).lastPathComponent
            var target = (destination as NSString).appendingPathComponent(filename)
            if Self.normalized(target) == Self.normalized(oldPath) {
                report.skipped += 1
                continue
            }
            // 同批内部撞名（不同源目录的同名文件）一律失败，不看策略：
            // 同批两条照片不能互相覆盖（replace 只针对"磁盘上既有的其它文件"）。
            if plannedTargets.contains(Self.normalized(target)) {
                report.failed.append(PhotoFileOpFailure(
                    photoId: row.photoId, path: oldPath,
                    message: "同批照片的目标文件名相同，拒绝互相覆盖：\(target)"))
                continue
            }
            let collides = FileManager.default.fileExists(atPath: target)
            if collides {
                switch input.conflictPolicy {
                case .skip:
                    report.skipped += 1
                    continue
                case .coexist:
                    target = Self.coexistingPath(target: target, alsoTaken: plannedTargets)
                case .replace:
                    break
                }
            }
            plannedTargets.insert(Self.normalized(target))
            var transfer = PlannedTransfer(
                photoId: row.photoId, sourcePath: oldPath, targetPath: target)
            transfer.replaceExisting = collides && input.conflictPolicy == .replace
            transfers.append(transfer)
        }
        let groups = try sidecarGroups(transfers, sessionId: input.sessionId)
        for group in groups {
            let outcome = apply(group: group)
            report.moved += outcome.renamed
            report.skipped += outcome.skipped
            report.failed.append(contentsOf: outcome.failed)
            for (photoId, path) in outcome.newPaths { report.newPaths[photoId] = path }
        }
        return report
    }

    // MARK: - 规划

    private struct ResolvedPhoto {
        let photoId: String
        let oldPath: String
    }

    private struct ResolvedPhotos {
        let rows: [ResolvedPhoto]
        let failures: [PhotoFileOpFailure]
    }

    private struct RenamePlanItem {
        let photoId: String
        let oldPath: String
        let oldFilename: String
        var newPath: String
        var newFilename: String
        var conflict: PhotoRenameConflict
        var sidecarPath: String?
        var newSidecarPath: String?

        var preview: PhotoRenamePreviewItem {
            PhotoRenamePreviewItem(
                photoId: photoId, oldPath: oldPath, oldFilename: oldFilename,
                newPath: newPath, newFilename: newFilename, conflict: conflict,
                sidecarPath: sidecarPath, newSidecarPath: newSidecarPath)
        }

        func failure(message: String) -> PhotoFileOpFailure {
            PhotoFileOpFailure(photoId: photoId, path: oldPath, message: message)
        }

        func transfer(target: String) -> PlannedTransfer {
            PlannedTransfer(photoId: photoId, sourcePath: oldPath, targetPath: target)
        }
    }

    private struct RenamePlan {
        let items: [RenamePlanItem]
        let invalidTokens: [String]
    }

    private func renamePlan(_ input: PhotoRenamePreviewInput) async throws -> RenamePlan {
        let template = input.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            throw GatherError.invalidParameter(field: "template", reason: "rename template is empty")
        }
        let tokens = Self.invalidTokens(in: template)
        guard Self.isPathSafeTemplate(template) else {
            return RenamePlan(items: [], invalidTokens: tokens + ["<路径分隔符>"])
        }
        let resolved = try resolvedPhotos(input.photoIds, sessionId: input.sessionId)
        let batchSources = Set(resolved.rows.map { Self.normalized($0.oldPath) })
        var items: [RenamePlanItem] = []
        for (index, row) in resolved.rows.enumerated() {
            let filename = (row.oldPath as NSString).lastPathComponent
            var item = RenamePlanItem(
                photoId: row.photoId, oldPath: row.oldPath, oldFilename: filename,
                newPath: "", newFilename: "", conflict: .none,
                sidecarPath: nil, newSidecarPath: nil)
            let metadata = await captureMetadata(row.oldPath)
            let date = metadata?.date ?? Self.fileModificationDate(row.oldPath) ?? Date()
            var rendered = IngestRenameTemplate.expand(
                template, originalName: filename, date: date,
                sequence: index + 1, cameraModel: metadata?.cameraModel)
            rendered = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalExt = (filename as NSString).pathExtension
            let renderedExt = (rendered as NSString).pathExtension
            if renderedExt.isEmpty {
                if !originalExt.isEmpty { rendered += "." + originalExt }
            } else if renderedExt.caseInsensitiveCompare(originalExt) != .orderedSame {
                item.conflict = .invalidToken
            }
            let directory = (row.oldPath as NSString).deletingLastPathComponent
            let target = (directory as NSString).appendingPathComponent(rendered)
            item.newPath = target
            item.newFilename = rendered
            let sourceExists = FileManager.default.fileExists(atPath: row.oldPath)
            if !sourceExists {
                item.conflict = .missingSource
            } else if item.conflict == .none {
                if rendered.isEmpty || rendered == "." || rendered == ".."
                    || rendered.utf8.count > 255 || rendered.contains("/") {
                    item.conflict = .invalidToken
                } else if FileManager.default.fileExists(atPath: target),
                          !batchSources.contains(Self.normalized(target)) {
                    item.conflict = .targetExists
                }
            }
            let sidecar = TSPath.xmpSidecarPath(row.oldPath)
            if FileManager.default.fileExists(atPath: sidecar) {
                item.sidecarPath = sidecar
                item.newSidecarPath = TSPath.xmpSidecarPath(target)
            }
            items.append(item)
        }
        // 同批撞目标：两条都记 duplicateTarget（模板缺 {seq}/{orig} 之类的区分项）。
        var owners: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where !item.newPath.isEmpty {
            owners[Self.normalized(item.newPath), default: []].append(index)
        }
        for (_, indices) in owners where indices.count > 1 {
            for index in indices where items[index].conflict == .none {
                items[index].conflict = .duplicateTarget
            }
        }
        if !tokens.isEmpty {
            for index in items.indices { items[index].conflict = .invalidToken }
        }
        for failure in resolved.failures {
            items.append(RenamePlanItem(
                photoId: failure.photoId, oldPath: failure.path, oldFilename: "",
                newPath: "", newFilename: "", conflict: .notInSession,
                sidecarPath: nil, newSidecarPath: nil))
        }
        return RenamePlan(items: items, invalidTokens: tokens)
    }

    /// 输入 photoIds → 库内行（保序）。缺行/跨会话：失败项，不猜路径。
    private func resolvedPhotos(
        _ photoIds: [String], sessionId: String
    ) throws -> ResolvedPhotos {
        let unique = Self.unique(photoIds)
        guard !unique.isEmpty else { return ResolvedPhotos(rows: [], failures: []) }
        let rows = try photoRepo.getLookupByIds(unique)
        var byID: [String: PhotoLookupRow] = [:]
        for row in rows { byID[row.id] = row }
        var resolved: [ResolvedPhoto] = []
        var failures: [PhotoFileOpFailure] = []
        for photoId in unique {
            guard let row = byID[photoId] else {
                failures.append(PhotoFileOpFailure(
                    photoId: photoId, path: "", message: "照片不在库内"))
                continue
            }
            guard row.sessionId == sessionId else {
                failures.append(PhotoFileOpFailure(
                    photoId: photoId, path: row.filepath, message: "照片不属于该工作区"))
                continue
            }
            guard (row.filepath as NSString).isAbsolutePath else {
                failures.append(PhotoFileOpFailure(
                    photoId: photoId, path: row.filepath, message: "登记路径不是绝对路径"))
                continue
            }
            resolved.append(ResolvedPhoto(photoId: photoId, oldPath: row.filepath))
        }
        return ResolvedPhotos(rows: resolved, failures: failures)
    }

    // MARK: - 执行（按 sidecar 组提交）

    private struct PlannedTransfer {
        let photoId: String
        let sourcePath: String
        var targetPath: String
        var replaceExisting: Bool = false
        var sidecarAction: SidecarAction = .none
        var sharesSidecar: Bool = false
        /// 组成功后应删除的旧 sidecar（复制路线且已无兄弟消费时；nil = 保留）。
        var staleSidecarPath: String? = nil
    }

    private enum SidecarAction: Equatable {
        case none
        /// 移动 sidecar（组内最后一个消费旧 xmp 的成员；DB 走 relocate 语义）。
        case move
        /// 复制 sidecar（还有兄弟/其它成员消费旧 xmp；DB 走 copy binding 语义）。
        case copy
    }

    private struct GroupOutcome {
        var renamed = 0
        var skipped = 0
        var failed: [PhotoFileOpFailure] = []
        var newPaths: [String: String] = [:]
    }

    /// 盘上副作用（回滚按 isCopy 逆操作）。
    private struct FileAction {
        let source: String
        let target: String
        let isCopy: Bool
    }

    /// 库内同 stem 的照片 id 索引（判断 sidecar 是否仍有**不在本批**的兄弟消费）。
    private func sessionStemIndex(sessionId: String) throws -> [String: Set<String>] {
        let rows = try photoRepo.getBySessionProjection(sessionId: sessionId)
        var index: [String: Set<String>] = [:]
        for row in rows {
            index[Self.stemKey(of: row.filepath), default: []].insert(row.id)
        }
        return index
    }

    private func sidecarGroups(
        _ transfers: [PlannedTransfer], sessionId: String
    ) throws -> [[PlannedTransfer]] {
        guard !transfers.isEmpty else { return [] }
        let stemIndex = try sessionStemIndex(sessionId: sessionId)
        let batchIDs = Set(transfers.map(\.photoId))
        func hasOutsideSibling(_ path: String) -> Bool {
            guard let ids = stemIndex[Self.stemKey(of: path)] else { return false }
            return !ids.subtracting(batchIDs).isEmpty
        }
        var groups: [[PlannedTransfer]] = []
        var indexBySidecar: [String: Int] = [:]
        for transfer in transfers {
            let oldSidecar = TSPath.xmpSidecarPath(transfer.sourcePath)
            guard FileManager.default.fileExists(atPath: oldSidecar) else {
                groups.append([transfer])
                continue
            }
            let key = Self.normalized(oldSidecar)
            if let existing = indexBySidecar[key] {
                groups[existing].append(transfer)
            } else {
                indexBySidecar[key] = groups.count
                groups.append([transfer])
            }
        }
        for groupIndex in groups.indices {
            let group = groups[groupIndex]
            let outside = group.contains { hasOutsideSibling($0.sourcePath) }
            let newStems = Set(group.map {
                Self.stemKey(of: TSPath.xmpSidecarPath($0.targetPath))
            })
            if !outside, group.count == 1 {
                groups[groupIndex][0].sidecarAction = .move
                groups[groupIndex][0].sharesSidecar = false
            } else if !outside, newStems.count == 1 {
                // 同 stem 兄弟一起改到同一个新 stem：移动一次，其余复制绑定。
                for memberIndex in groups[groupIndex].indices {
                    if memberIndex == 0 {
                        groups[groupIndex][memberIndex].sidecarAction = .move
                        groups[groupIndex][memberIndex].sharesSidecar = false
                    } else {
                        groups[groupIndex][memberIndex].sidecarAction = .copy
                        groups[groupIndex][memberIndex].sharesSidecar = true
                    }
                }
            } else {
                // 有兄弟留下 / 成员被改到不同新 stem：全部复制（旧 xmp 不能整份搬走）。
                for memberIndex in groups[groupIndex].indices {
                    groups[groupIndex][memberIndex].sidecarAction = .copy
                    groups[groupIndex][memberIndex].sharesSidecar = true
                }
                if !outside {
                    // 无外部兄弟 → 复制完成后旧 xmp 已无人消费，可删（避免孤儿 sidecar）。
                    groups[groupIndex][0].staleSidecarPath = TSPath.xmpSidecarPath(
                        groups[groupIndex][0].sourcePath)
                }
            }
        }
        return groups
    }

    private func apply(group: [PlannedTransfer]) -> GroupOutcome {
        var outcome = GroupOutcome()
        guard !group.isEmpty else { return outcome }
        var actions: [FileAction] = []
        var replacedBackups: [(backup: String, target: String)] = []
        var completed: [PlannedTransfer] = []
        var oldSidecarsToDelete: [String] = []
        do {
            oldSidecarsToDelete = group.compactMap(\.staleSidecarPath)
            for transfer in group {
                let directory = (transfer.sourcePath as NSString).deletingLastPathComponent
                let temp = (directory as NSString).appendingPathComponent(
                    ".gather-renaming-\(newUUIDString())")
                try FileManager.default.moveItem(atPath: transfer.sourcePath, toPath: temp)
                let moveIndex = actions.count
                actions.append(FileAction(
                    source: transfer.sourcePath, target: temp, isCopy: false))
                if transfer.replaceExisting,
                   FileManager.default.fileExists(atPath: transfer.targetPath) {
                    let backup = transfer.targetPath + ".gather-replaced-\(newUUIDString())"
                    try FileManager.default.moveItem(atPath: transfer.targetPath, toPath: backup)
                    replacedBackups.append((backup: backup, target: transfer.targetPath))
                    // 被替换目标的 sidecar 也要一起备份：否则随后的 sidecar 移动会
                    // 直接撞上既有文件（moveItem 抛错）或覆盖掉它（用户旧元数据）。
                    let targetSidecar = TSPath.xmpSidecarPath(transfer.targetPath)
                    if FileManager.default.fileExists(atPath: targetSidecar) {
                        let sidecarBackup = targetSidecar + ".gather-replaced-\(newUUIDString())"
                        try FileManager.default.moveItem(
                            atPath: targetSidecar, toPath: sidecarBackup)
                        replacedBackups.append((backup: sidecarBackup, target: targetSidecar))
                    }
                }
                try FileManager.default.moveItem(atPath: temp, toPath: transfer.targetPath)
                actions[moveIndex] = FileAction(
                    source: transfer.sourcePath, target: transfer.targetPath, isCopy: false)
                switch transfer.sidecarAction {
                case .none:
                    break
                case .move:
                    let oldSidecar = TSPath.xmpSidecarPath(transfer.sourcePath)
                    let newSidecar = TSPath.xmpSidecarPath(transfer.targetPath)
                    if FileManager.default.fileExists(atPath: oldSidecar),
                       Self.normalized(oldSidecar) != Self.normalized(newSidecar) {
                        try FileManager.default.moveItem(atPath: oldSidecar, toPath: newSidecar)
                        actions.append(FileAction(
                            source: oldSidecar, target: newSidecar, isCopy: false))
                    }
                    actions.append(contentsOf: try moveSidecarBackups(
                        oldPhotoPath: transfer.sourcePath,
                        newPhotoPath: transfer.targetPath))
                case .copy:
                    let oldSidecar = TSPath.xmpSidecarPath(transfer.sourcePath)
                    let newSidecar = TSPath.xmpSidecarPath(transfer.targetPath)
                    if FileManager.default.fileExists(atPath: oldSidecar),
                       Self.normalized(oldSidecar) != Self.normalized(newSidecar),
                       !FileManager.default.fileExists(atPath: newSidecar) {
                        try FileManager.default.copyItem(atPath: oldSidecar, toPath: newSidecar)
                        actions.append(FileAction(
                            source: oldSidecar, target: newSidecar, isCopy: true))
                    }
                }
                if let relocate {
                    try relocate(
                        transfer.photoId, transfer.sourcePath,
                        transfer.targetPath, transfer.sharesSidecar)
                } else {
                    try photoRepo.updateFilepath(
                        photoId: transfer.photoId, filepath: transfer.targetPath)
                }
                completed.append(transfer)
                outcome.renamed += 1
                outcome.newPaths[transfer.photoId] = transfer.targetPath
            }
            for entry in replacedBackups where FileManager.default.fileExists(atPath: entry.backup) {
                do { try FileManager.default.removeItem(atPath: entry.backup) } catch {
                    GatherLogger.log(
                        "file ops: remove replaced backup failed: \(error)", level: .warn)
                }
            }
            for sidecar in oldSidecarsToDelete where FileManager.default.fileExists(atPath: sidecar) {
                do { try FileManager.default.removeItem(atPath: sidecar) } catch {
                    GatherLogger.log(
                        "file ops: remove stale sidecar failed: \(error)", level: .warn)
                }
            }
        } catch {
            var rollbackErrors: [String] = []
            // 1) 先撤文件（后进先出）
            for action in actions.reversed() {
                guard FileManager.default.fileExists(atPath: action.target) else { continue }
                do {
                    if action.isCopy {
                        try FileManager.default.removeItem(atPath: action.target)
                    } else {
                        try FileManager.default.moveItem(atPath: action.target, toPath: action.source)
                    }
                } catch {
                    rollbackErrors.append("\(action.target) → \(action.source): \(error)")
                }
            }
            // 2) 再恢复被替换的既有文件
            for entry in replacedBackups.reversed()
            where FileManager.default.fileExists(atPath: entry.backup) {
                do {
                    try FileManager.default.moveItem(atPath: entry.backup, toPath: entry.target)
                } catch {
                    rollbackErrors.append("\(entry.backup) → \(entry.target): \(error)")
                }
            }
            // 3) 最后把已提交的库路径改回旧路径（否则文件回滚了、DB 还指新名）。
            for transfer in completed.reversed() {
                do {
                    if let relocate {
                        try relocate(
                            transfer.photoId, transfer.targetPath,
                            transfer.sourcePath, transfer.sharesSidecar)
                    } else {
                        try photoRepo.updateFilepath(
                            photoId: transfer.photoId, filepath: transfer.sourcePath)
                    }
                } catch {
                    rollbackErrors.append(
                        "DB rollback \(transfer.photoId): \(error)")
                }
            }
            var message = String(describing: error)
            if !rollbackErrors.isEmpty {
                message += "；回滚失败（需人工恢复）：" + rollbackErrors.joined(separator: " | ")
            }
            outcome.renamed = 0
            outcome.newPaths = [:]
            outcome.failed = group.map {
                PhotoFileOpFailure(
                    photoId: $0.photoId, path: $0.sourcePath, message: message)
            }
        }
        return outcome
    }

    // MARK: - 备份 / sidecar

    /// 把旧 xmp 的 `<xmp>.gather-backup-*` 搬到新 xmp 旁边并改成新名前缀。
    private func moveSidecarBackups(
        oldPhotoPath: String, newPhotoPath: String
    ) throws -> [FileAction] {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        let oldDir = (oldXmp as NSString).deletingLastPathComponent
        let newDir = (newXmp as NSString).deletingLastPathComponent
        let newBase = (newXmp as NSString).lastPathComponent
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: oldDir)
        } catch {
            if FileManager.default.fileExists(atPath: oldDir) { throw error }
            return []
        }
        var actions: [FileAction] = []
        for entry in entries.sorted() {
            guard let suffix = XMPBackupNaming.suffix(
                ofBackupFile: entry, forXMPPath: oldXmp) else { continue }
            let source = (oldDir as NSString).appendingPathComponent(entry)
            let target = (newDir as NSString).appendingPathComponent(
                XMPBackupNaming.make(xmpPath: newBase, suffix: suffix))
            if Self.normalized(source) == Self.normalized(target) { continue }
            guard !FileManager.default.fileExists(atPath: target) else {
                throw GatherError.invalidParameter(
                    field: "destinationRoot", reason: "交付备份目标已存在：\(target)")
            }
            try FileManager.default.moveItem(atPath: source, toPath: target)
            actions.append(FileAction(source: source, target: target, isCopy: false))
        }
        return actions
    }

    // MARK: - 路径与校验工具

    private func validateBatch(count: Int) throws {
        guard count <= Self.maxItems else {
            throw GatherError.invalidParameter(
                field: "photoIds",
                reason: "too many photos in one batch (\(count) > \(Self.maxItems))")
        }
    }

    /// 移动目标目录校验：绝对路径、标准化后存在、非禁根。
    static func validatedDestination(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else {
            throw GatherError.invalidParameter(
                field: "destinationRoot", reason: "a non-empty absolute destination is required")
        }
        let normalized = (trimmed as NSString).standardizingPath
        guard !ScanPath.isForbiddenRoot(normalized) else {
            throw GatherError.invalidParameter(
                field: "destinationRoot", reason: "forbidden destination root: \(normalized)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GatherError.invalidParameter(
                field: "destinationRoot", reason: "destination is not an existing directory")
        }
        return normalized
    }

    /// 撞名共存：`name-2.ext` / `name-3.ext`（同 RejectedMover 口径）。
    static func coexistingPath(
        target: String, alsoTaken: Set<String> = []
    ) -> String {
        let directory = (target as NSString).deletingLastPathComponent
        let filename = (target as NSString).lastPathComponent
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = (directory as NSString).appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate),
               !alsoTaken.contains(normalized(candidate)) {
                return candidate
            }
            index += 1
            if index > 10_000 { return candidate }
        }
    }

    /// 渲染日期回退：EXIF 读不到时用文件修改时间（比"现在"更接近拍摄时刻）。
    static func fileModificationDate(_ path: String) -> Date? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return attributes[.modificationDate] as? Date
        } catch {
            return nil
        }
    }

    static func normalized(_ path: String) -> String {
        TSPath.normalize(path)
    }

    static func stemKey(of path: String) -> String {
        let stem = ((path as NSString).deletingPathExtension as NSString).lastPathComponent
        return stem.lowercased()
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}

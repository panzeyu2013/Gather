// desktop/native/gather-core/Sources/GatherApplication/Services/Ingest/IngestService+Execution.swift
// M14a：IngestService 按职责纯搬移拆分（方法体/注释/可见性逐字未改；随搬移的 private
// 成员保持文件级可见性）。角色：执行阶段（单文件原子落地 / sidecar / 第二目的地 / 回滚）。
import Foundation
import GatherProtocol

extension IngestService {

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
        /// Wave4a-F4：replace 项无法镜像到第二目的地，显式记账。
        var secondSkipped: [String] = []
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
                    //
                    // 备份名必须唯一并保留遗留检查（Review P0）：固定名 ".gather-prev"
                    // 在"上次替换中途崩溃"时会留下用户原件的唯一副本，旧实现下一次
                    // replace 会无条件删掉它 → 原件永久丢失。现在：
                    //   1) 备份名带 UUID，互不覆盖；
                    //   2) 发现任何遗留备份一律拒绝本张并提示人工确认，绝不删除。
                    if let leftover = try firstLeftoverReplaceBackup(for: item.destPath) {
                        throw IngestError.leftoverReplaceBackup(leftover)
                    }
                    let backup = item.destPath + ".gather-prev-" + UUID().uuidString.lowercased()
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
                    // Wave4a-F4：replace 的 destPath 是库内原路径（不在 destinationRoot
                    // 内），第二目的地无法按相对路径镜像；跳过并记录，不按意外路径写。
                    if item.replaceExisting {
                        secondSkipped.append(item.destPath)
                    } else {
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
                    try transfer(item.destPath, to: target, move: false, verify: options.verifyChecksum)
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
                                    destSidecar, to: secondSidecar, move: false, verify: options.verifyChecksum)
                            }
                        }
                    }
                    secondCopied.append(target)
                    }
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
                        try transfer(dest, to: target, move: false, verify: options.verifyChecksum)
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
                            try transfer(destSidecar, to: targetSidecar, move: false, verify: options.verifyChecksum)
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
            replaced: replacedDestinations,
            secondSkipped: secondSkipped,
            unsupportedFormats: plan.unsupportedFormats)
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

    /// 第二目的地路径：按"相对主目的地的路径"拼接，禁止用字符串替换
    /// （根目录是另一路径的子串时会把目录结构拼坏）。
    /// 找出目标路径下遗留的 replace 备份（含历史固定名 ".gather-prev" 与新的 UUID 名）。
    /// 返回绝对路径；没有则 nil。**只读**：绝不删除（可能是用户原片的唯一副本）。
    private func firstLeftoverReplaceBackup(for destPath: String) throws -> String? {
        let dir = (destPath as NSString).deletingLastPathComponent
        let name = (destPath as NSString).lastPathComponent
        let prefix = name + ".gather-prev"
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: dir)
        } catch {
            return nil  // 目录不可读：后续 moveItem 会给出真实错误
        }
        for entry in entries.sorted() where entry.hasPrefix(prefix) {
            return (dir as NSString).appendingPathComponent(entry)
        }
        return nil
    }

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
}

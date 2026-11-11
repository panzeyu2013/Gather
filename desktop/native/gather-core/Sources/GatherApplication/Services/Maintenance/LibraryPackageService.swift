// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/LibraryPackageService.swift
// Wave3（task-24）：可移植目录包的导出/导入（Application 层，不含 SQL）。
//
// 包 = JSON（LibraryPackage）+ 相对路径清单；**不打包原图**：
// - 导出：photos 投影（路径/校验和/尺寸/时间）+ photo_metadata_cache（rating/label/keywords/IPTC）
//   + culling_decisions.decision + 会话内手动集合成员；
// - 导入：按 photoId → checksum 两级去重，冲突策略显式（keepLocal/keepImported/coexist），
//   按 newRoot 重绑定相对路径，评分/关键词/集合成员随行迁移。
//
// 边界：本文件不持 SQL（用 LibraryPackageStore / 既有仓储），也不发 UI 事件；
// 调用方（MaintenanceService → LiveMaintenanceAPI → ControlCenter）负责域广播。
import Foundation
import GatherProtocol
import GatherPersistence

public struct LibraryPackageService: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 导出

    public func exportPackage(_ input: LibraryExportInput) throws -> LibraryExportResult {
        let sessions = SessionRepo(connection: connection)
        guard let session = try sessions.get(id: input.sessionId) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        let store = LibraryPackageStore(connection: connection)
        let rows = try store.exportRows(
            sessionId: input.sessionId, includeArchived: input.includeArchived)
        let sourceRoot = session.sourcePath
        let photos = rows.map { row in
            LibraryPackagePhoto(
                photoId: row.photoId,
                relativePath: Self.relativePath(of: row.filepath, under: sourceRoot),
                filename: row.filename,
                checksum: row.checksum,
                fileSize: row.fileSize,
                fileMtimeMs: row.fileMtimeMs,
                status: row.status,
                rating: row.rating,
                label: row.label,
                decision: row.decision,
                keywords: Self.decodeKeywords(row.keywordsJSON),
                descriptiveJSON: row.descriptiveJSON
            )
        }
        let exportedIDs = Set(photos.map { $0.photoId })
        let collections = CollectionRepo(connection: connection)
        let collectionRows = try collections.list(sessionId: input.sessionId)
        let packageCollections: [LibraryPackageCollection] = try collectionRows.compactMap { collection in
            let members = try collections.memberPhotoIds(collectionId: collection.id)
                .filter { exportedIDs.contains($0) }
            // 空集合也导出（保留"这个集合存在"的信息），成员为空。
            return LibraryPackageCollection(
                id: collection.id,
                name: collection.name,
                sortOrder: collection.sortOrder,
                photoIds: members
            )
        }
        let package = LibraryPackage(
            exportedAt: nowISOString(),
            session: LibraryPackageSession(
                id: session.id,
                name: session.name,
                sourcePath: session.sourcePath,
                createdAt: session.createdAt
            ),
            collections: packageCollections,
            photos: photos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(package)
        let fileURL = try Self.resolvePackageURL(
            destinationPath: input.destinationPath, sessionName: session.name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        let archived = try store.archivedCount(sessionId: input.sessionId)
        return LibraryExportResult(
            packagePath: fileURL.path,
            photoCount: photos.count,
            collectionCount: packageCollections.count,
            skippedArchivedCount: input.includeArchived ? 0 : archived
        )
    }

    // MARK: - 导入

    public func importPackage(_ input: LibraryImportInput) throws -> LibraryImportReport {
        let data = try Data(contentsOf: URL(fileURLWithPath: input.packagePath))
        let decoder = JSONDecoder()
        let package: LibraryPackage
        do {
            package = try decoder.decode(LibraryPackage.self, from: data)
        } catch {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "package is not a valid Gather library package")
        }
        // 更高版本包可能带当前无法解释的字段：显式失败，不静默丢数据。
        guard package.formatVersion <= 1 else {
            throw GatherError.invalidParameter(
                field: "formatVersion",
                reason: "unsupported package format version \(package.formatVersion)")
        }
        let sessionName = Self.resolvedSessionName(
            explicit: input.sessionName, fallback: package.session.name)
        let sessions = SessionRepo(connection: connection)
        let newSession = try sessions.create(
            name: sessionName, source: "migration", sourcePath: input.newRoot)

        let store = LibraryPackageStore(connection: connection)
        let metadata = MetadataCacheRepo(connection: connection)
        let decisions = CullingDecisionRepo(connection: connection)
        let existingIDs = try store.existingPhotoIDs(package.photos.map { $0.photoId })
        let checksumOwners = try store.checksumOwners(package.photos.map { $0.checksum })
        var ownerByChecksum: [String: String] = [:]
        for owner in checksumOwners where ownerByChecksum[owner.checksum] == nil {
            ownerByChecksum[owner.checksum] = owner.photoId
        }

        var report = LibraryImportReport(sessionId: newSession.id)
        // 包内 photoId → 新库 photoId（集合成员映射用）。
        var idMap: [String: String] = [:]

        for photo in package.photos {
            let absolute = Self.absolutePath(
                relativePath: photo.relativePath, newRoot: input.newRoot)
            let fileExists = FileManager.default.fileExists(atPath: absolute)
            if !fileExists {
                report.missingFiles.append(absolute)
            }
            var targetId = photo.photoId
            var shouldImport = true
            var rebindExisting = false
            if existingIDs.contains(photo.photoId) {
                report.dedupedByPhotoID += 1
                switch input.conflictPolicy {
                case .keepLocal:
                    report.conflictsKeptLocal += 1
                    shouldImport = false
                    targetId = photo.photoId
                case .keepImported:
                    report.conflictsKeptImported += 1
                    rebindExisting = true
                case .coexist:
                    report.coexisted += 1
                    targetId = newUUIDString()
                }
            } else if !photo.checksum.isEmpty, let owner = ownerByChecksum[photo.checksum] {
                report.dedupedByChecksum += 1
                switch input.conflictPolicy {
                case .keepLocal:
                    report.conflictsKeptLocal += 1
                    shouldImport = false
                    targetId = owner
                case .keepImported, .coexist:
                    // 同内容在别的行上：不改写那条记录的路径（可能属于别的工作区），
                    // 统一按"并存"插入新行；报告里区分计数。
                    report.coexisted += 1
                    targetId = newUUIDString()
                }
            }

            if shouldImport {
                if rebindExisting {
                    _ = try store.rebindImportedPhoto(
                        photoId: photo.photoId,
                        filepath: absolute,
                        filename: photo.filename,
                        checksum: photo.checksum,
                        fileSize: photo.fileSize,
                        fileMtimeMs: photo.fileMtimeMs
                    )
                } else {
                    let inserted = try store.insertImportedPhoto(
                        id: targetId,
                        sessionId: newSession.id,
                        filepath: absolute,
                        filename: photo.filename,
                        checksum: photo.checksum,
                        fileSize: photo.fileSize,
                        fileMtimeMs: photo.fileMtimeMs,
                        status: photo.status.isEmpty ? "pending" : photo.status
                    )
                    if !inserted {
                        // id 竞争（并发导入）：退化为新 id 并存，绝不覆盖。
                        targetId = newUUIDString()
                        _ = try store.insertImportedPhoto(
                            id: targetId,
                            sessionId: newSession.id,
                            filepath: absolute,
                            filename: photo.filename,
                            checksum: photo.checksum,
                            fileSize: photo.fileSize,
                            fileMtimeMs: photo.fileMtimeMs,
                            status: photo.status.isEmpty ? "pending" : photo.status
                        )
                        report.coexisted += 1
                    }
                }
                report.importedPhotos += 1
                // 缺失文件仍登记为 pending：下次索引扫描才会把它标成 missing/ready。
                if !fileExists { report.pendingCount += 1 }
                // keepImported 回绑的是**既有照片行**：元数据/决策必须写回该行原会话，
                // 否则 photo_metadata_cache.session_id 与 photos.session_id 不一致，
                // 按会话 join 的读面会漏行。
                let metadataSessionId: String
                if rebindExisting {
                    metadataSessionId = try store.sessionIdOfPhoto(photo.photoId) ?? newSession.id
                } else {
                    metadataSessionId = newSession.id
                }
                // 元数据：rating/label/keywords 走 photo_metadata_cache（真相源）。
                if input.importRatings || input.importKeywords {
                    let cacheInput = MetadataCacheInput(
                        sessionId: metadataSessionId,
                        rating: input.importRatings ? photo.rating.map(Int64.init) : nil,
                        label: input.importRatings ? photo.label : nil,
                        keywords: input.importKeywords ? photo.keywords : nil,
                        descriptive: Self.decodeDescriptive(photo.descriptiveJSON)
                    )
                    try metadata.upsert(
                        photoId: targetId, sessionId: metadataSessionId, data: cacheInput)
                    if input.importRatings, photo.rating != nil { report.importedRatings += 1 }
                    if input.importKeywords, !photo.keywords.isEmpty {
                        report.importedKeywords += 1
                    }
                }
                if let decision = photo.decision, !decision.isEmpty {
                    try decisions.upsertState(
                        sessionId: metadataSessionId,
                        photoId: targetId,
                        groupId: "migration",
                        state: CullingDecisionStateInput(
                            decision: decision,
                            rating: Int64(photo.rating ?? 0),
                            colorLabel: photo.label ?? "None",
                            revision: 1,
                            source: "migration"
                        )
                    )
                }
            }
            idMap[photo.photoId] = targetId
        }

        // 集合：新建并保留成员（成员映射到目标 photoId，含"保留本地"命中的本地 id）。
        let collections = CollectionRepo(connection: connection)
        for packageCollection in package.collections {
            let memberIds = packageCollection.photoIds.compactMap { idMap[$0] }
            let resolvedName = try Self.uniqueCollectionName(
                base: packageCollection.name, sessionId: newSession.id, repo: collections)
            let created = try collections.create(
                sessionId: newSession.id, name: resolvedName, sortOrder: nil)
            if !memberIds.isEmpty {
                _ = try collections.appendItems(collectionId: created.id, photoIds: memberIds)
            }
            report.collectionIDMap[packageCollection.id] = created.id
            report.importedCollections += 1
        }
        _ = try sessions.refreshPhotoCount(id: newSession.id)
        return report
    }

    // MARK: - 路径与名称

    /// 包内相对路径：源根前缀内则去掉前缀，否则退化为文件名（跨根搬迁仍能重绑定到新根同名位置）。
    static func relativePath(of filepath: String, under sourceRoot: String) -> String {
        let root = (sourceRoot as NSString).standardizingPath
        let path = (filepath as NSString).standardizingPath
        guard !root.isEmpty, path.hasPrefix(root + "/") else {
            return (filepath as NSString).lastPathComponent
        }
        return String(path.dropFirst(root.count + 1))
    }

    /// 相对路径 + 新根 → 绝对路径（newRoot 为空 = 沿用导出时记录的原路径语义：退化为文件名）。
    static func absolutePath(relativePath: String, newRoot: String) -> String {
        let root = (newRoot as NSString).standardizingPath
        guard !root.isEmpty else { return relativePath }
        return (root as NSString).appendingPathComponent(relativePath)
    }

    static func resolvePackageURL(destinationPath: String, sessionName: String) throws -> URL {
        let path = (destinationPath as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            return URL(fileURLWithPath: path)
                .appendingPathComponent(Self.fileName(for: sessionName))
        }
        if path.hasSuffix(".gatherlib.json") {
            return URL(fileURLWithPath: path)
        }
        // 不存在的路径：按目录处理（创建目录 + 默认文件名）。
        return URL(fileURLWithPath: path).appendingPathComponent(Self.fileName(for: sessionName))
    }

    private static func fileName(for sessionName: String) -> String {
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "library" : trimmed
        let sanitized = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(sanitized).gatherlib.json"
    }

    static func resolvedSessionName(explicit: String, fallback: String) -> String {
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let inherited = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        // 同名工作区是允许的（sessions.name 无唯一约束）；空名兜底成"导入的工作区"。
        return inherited.isEmpty ? "导入的工作区" : "\(inherited)（导入）"
    }

    private static func uniqueCollectionName(
        base: String, sessionId: String, repo: CollectionRepo
    ) throws -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "导入的集合" : trimmed
        var candidate = resolved
        var index = 2
        while try repo.nameExists(sessionId: sessionId, name: candidate, excluding: nil) {
            candidate = "\(resolved)（导入 \(index)）"
            index += 1
            if index > 50 { break }
        }
        return candidate
    }

    static func decodeKeywords(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            GatherLogger.log("package keywords decode failed: \(error)", level: .debug)
            return []
        }
    }

    static func decodeDescriptive(_ json: String) -> DescriptiveMetadata? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(DescriptiveMetadata.self, from: data)
        } catch {
            GatherLogger.log("package descriptive decode failed: \(error)", level: .debug)
            return nil
        }
    }
}

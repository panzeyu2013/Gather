// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/LibraryPackageService.swift
// Wave3（task-24）：可移植目录包的导出/导入（Application 层，不含 SQL）。
//
// 包 = JSON（LibraryPackage）+ 相对路径清单；**不打包原图**：
// - 导出：photos 投影（路径/校验和/尺寸/时间）+ photo_metadata_cache（rating/label/keywords/IPTC）
//   + culling_decisions.decision + 会话内手动集合成员；
// - 导入：按 photoId → checksum 两级去重，冲突策略显式（keepLocal/keepImported/coexist），
//   按 newRoot 重绑定相对路径，评分/关键词/集合成员随行迁移。
//
// Wave5（Batch3 / task-20）：包格式 v2 带**组织资产**（见 MaintenanceAPI 的段 DTO）：
// - 导出：stacks（StackRepo）/ smartAlbums（SmartAlbumRepo）/ savedSearches（SavedSearchRepo）
//   / personBindings、duplicateGroups（LibraryPackageStore 的显式列投影）；
// - 导入：堆栈/智能相册/保存查询/人物绑定按 photoId 映射重建（容器引用 collection/stack
//   规则重写新 id）；重复组是派生数据**不重建**（报告标注 skipped）；映射不到的条目进
//   skippedUnmappedItems，不猜不静默丢；
// - 收尾：路径重绑定或有待索引照片时自动入队 metadata.scan（enqueueScan 接缝可注入）。
//
// 边界：本文件不持 SQL（用 LibraryPackageStore / 既有仓储），也不发 UI 事件；
// 调用方（MaintenanceService → LiveMaintenanceAPI → ControlCenter）负责域广播。
import Foundation
import GatherProtocol
import GatherPersistence

/// 导入后入队 metadata.scan 的接缝（测试注入记录器；nil = 用 AnalysisJobRepo 真实入队）。
public typealias LibraryScanEnqueuer = @Sendable (_ sessionId: String, _ requestedPaths: [String]) throws -> String

public struct LibraryPackageService: Sendable {
    private let connection: DBConnection
    /// 导入成功后的索引扫描入队接缝（nil = 生产实现）。
    private let enqueueScan: LibraryScanEnqueuer?

    public init(connection: DBConnection, enqueueScan: LibraryScanEnqueuer? = nil) {
        self.connection = connection
        self.enqueueScan = enqueueScan
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
        // Wave5（Batch3 / task-20）：组织资产段。全部按**显式列**读（不 SELECT *），
        // 只写入包内存在的 photoId（归档/未导出成员不写入，避免导入后指向虚空）。
        let stacks = try Self.exportStacks(
            sessionId: input.sessionId, exportedIDs: exportedIDs, repo: StackRepo(connection: connection))
        let smartAlbums = try Self.exportSmartAlbums(repo: SmartAlbumRepo(connection: connection))
        let savedSearches = try Self.exportSavedSearches(
            sessionId: input.sessionId, repo: SavedSearchRepo(connection: connection))
        let personBindings = try Self.exportPersonBindings(
            sessionId: input.sessionId, exportedIDs: exportedIDs, store: store)
        let duplicateGroups = try Self.exportDuplicateGroups(
            sessionId: input.sessionId, exportedIDs: exportedIDs, store: store)
        let package = LibraryPackage(
            exportedAt: nowISOString(),
            session: LibraryPackageSession(
                id: session.id,
                name: session.name,
                sourcePath: session.sourcePath,
                createdAt: session.createdAt
            ),
            collections: packageCollections,
            photos: photos,
            stacks: stacks,
            smartAlbums: smartAlbums,
            savedSearches: savedSearches,
            personBindings: personBindings,
            duplicateGroups: duplicateGroups
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
            skippedArchivedCount: input.includeArchived ? 0 : archived,
            stackCount: stacks.count,
            smartAlbumCount: smartAlbums.count,
            savedSearchCount: savedSearches.count,
            personBindingCount: personBindings.count,
            duplicateGroupCount: duplicateGroups.count
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
        // Wave5：当前格式 = 2（组织资产段）；v1 旧包照常导入（缺段按空处理，见
        // LibraryPackage.init(from:)），只有真正更高的版本才拒绝。
        guard package.formatVersion <= 2 else {
            throw GatherError.invalidParameter(
                field: "formatVersion",
                reason: "unsupported package format version \(package.formatVersion)")
        }
        let sessionName = Self.resolvedSessionName(
            explicit: input.sessionName, fallback: package.session.name)
        // P1（task-31 review）：newRoot 空 = 沿用包内记录的原路径已不再是"相对路径"
        // 语义；用包 session.sourcePath 解析成绝对路径，避免把相对路径写进 photos。
        let effectiveRoot = Self.effectiveRoot(
            newRoot: input.newRoot, packageSourcePath: package.session.sourcePath)
        let sessions = SessionRepo(connection: connection)
        let newSession = try sessions.create(
            name: sessionName, source: "migration", sourcePath: effectiveRoot)

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
        // 包内 photoId → 新库 photoId（集合/堆栈/人物成员映射用）。
        var idMap: [String: String] = [:]
        // 本次真正写入/回绑的绝对路径（组织资产导入后决定 metadata.scan 的扫描范围）。
        var importedPaths: [String] = []

        for photo in package.photos {
            let absolute = try Self.absolutePath(
                relativePath: photo.relativePath, newRoot: effectiveRoot)
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
                importedPaths.append(absolute)
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
                //
                // P0（task-31 review）：keepImported 回绑的是**既有行**，不能整行 upsert。
                // 目录包不携带 date_taken/相机/GPS/宽高/尺寸等 EXIF/指纹列，整行 upsert
                // 会把它们写成 NULL；未勾选的 rating/keywords 也会被空值覆盖。既有行只走
                // 窄更新：rating 仅 `>0` 且勾选时写、keywords 仅非空且勾选时写、label/
                // descriptive 仅包里有值时写；其余列一律保持原值。
                let importedDescriptive = Self.decodeDescriptive(photo.descriptiveJSON)
                if rebindExisting {
                    let ratingToImport: Int64? = {
                        guard input.importRatings, let rating = photo.rating, rating > 0
                        else { return nil }
                        return Int64(rating)
                    }()
                    let labelToImport = Self.nonEmptyLabel(photo.label)
                    let keywordsToImport: [String]? =
                        input.importKeywords && !photo.keywords.isEmpty ? photo.keywords : nil
                    if ratingToImport != nil || labelToImport != nil
                        || keywordsToImport != nil || importedDescriptive != nil {
                        try metadata.updateMigrationFields(
                            photoId: targetId,
                            rating: ratingToImport,
                            label: labelToImport,
                            keywords: keywordsToImport,
                            descriptive: importedDescriptive)
                    }
                    if ratingToImport != nil { report.importedRatings += 1 }
                    if keywordsToImport != nil { report.importedKeywords += 1 }
                } else if input.importRatings || input.importKeywords {
                    // 新行没有既有 EXIF 可保；保留整行 upsert 以建立首份缓存。
                    let cacheInput = MetadataCacheInput(
                        sessionId: metadataSessionId,
                        rating: input.importRatings ? photo.rating.map(Int64.init) : nil,
                        label: input.importRatings ? photo.label : nil,
                        keywords: input.importKeywords ? photo.keywords : nil,
                        descriptive: importedDescriptive
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
        // MARK: Wave5（Batch3 / task-20）：组织资产导入
        //
        // 统一口径：
        // - 成员/引用一律经 idMap（包内 photoId → 新库 photoId，含 keepLocal 命中的本地 id）
        //   重绑；映射不到的条目进 skippedUnmappedItems（不猜、不静默丢弃）；
        // - 集合/堆栈的容器 id 导入后会变：智能相册/保存查询里 collection/stack 规则的
        //   value 按 collectionIDMap / stackIDMap 重写（FilterGroup 是结构化 JSON，可安全遍历）；
        // - face cluster id / role_bindings / 人脸向量不迁移（跨库不可靠，见 DTO 注释）。

        let stacksRepo = StackRepo(connection: connection)
        var stackIDMap: [String: String] = [:]
        for packageStack in package.stacks {
            let memberIds = packageStack.photoIds.compactMap { idMap[$0] }
            report.skippedUnmappedItems += packageStack.photoIds.count - memberIds.count
            guard !memberIds.isEmpty else {
                report.skippedStacks += 1
                continue
            }
            let created = try stacksRepo.create(
                sessionId: newSession.id,
                name: packageStack.name,
                // 封面只在包内成员里取；封面映射不到时交给 StackRepo 取首成员。
                coverPhotoId: packageStack.coverPhotoId.flatMap { idMap[$0] },
                photoIds: memberIds)
            stackIDMap[packageStack.id] = created.id
            report.importedStacks += 1
        }

        // 智能相册（库级资产，无 sessionId）：同名按冲突策略处理，criteria 重写容器 id。
        let smartAlbumRepo = SmartAlbumRepo(connection: connection)
        var albumsByName: [String: SmartAlbumRow] = [:]
        for album in try smartAlbumRepo.list() where albumsByName[album.name] == nil {
            albumsByName[album.name] = album
        }
        for packageAlbum in package.smartAlbums {
            guard let criteria = Self.decodeFilterGroup(packageAlbum.criteriaJSON) else {
                report.skippedBrokenCriteria += 1
                continue
            }
            let remapped = Self.remapCriteria(
                criteria,
                collectionIDMap: report.collectionIDMap,
                stackIDMap: stackIDMap)
            switch (albumsByName[packageAlbum.name], input.conflictPolicy) {
            case (.some, .keepLocal):
                report.skippedSmartAlbums += 1
            case (.some(let row), .keepImported):
                try smartAlbumRepo.update(id: row.id, data: SmartAlbumUpdateData(
                    description: packageAlbum.description,
                    filterCriteria: remapped,
                    sortBy: packageAlbum.sortBy,
                    sortOrder: packageAlbum.sortOrder,
                    icon: packageAlbum.icon))
                report.importedSmartAlbums += 1
            default:
                // 无同名（或 coexist 撞名）：新建；coexist 加后缀，避免用户看到两个同名条目。
                let name = albumsByName[packageAlbum.name] == nil
                    ? packageAlbum.name
                    : Self.uniqueOrganizationName(
                        base: packageAlbum.name, taken: Set(albumsByName.keys))
                let created = try smartAlbumRepo.create(data: SmartAlbumCreateData(
                    name: name,
                    description: packageAlbum.description,
                    filterCriteria: remapped,
                    sortBy: packageAlbum.sortBy,
                    sortOrder: packageAlbum.sortOrder,
                    icon: packageAlbum.icon))
                albumsByName[created.name] = created
                report.importedSmartAlbums += 1
            }
        }

        // 保存查询：包内全局查询按作用域还原；撞名按冲突策略（coexist 落新工作区作用域）。
        let savedSearchRepo = SavedSearchRepo(connection: connection)
        var globalSearchNames = Set(try savedSearchRepo.list(sessionId: nil).map(\.name))
        for packageSearch in package.savedSearches {
            guard let criteria = Self.decodeFilterGroup(packageSearch.criteriaJSON) else {
                report.skippedBrokenCriteria += 1
                continue
            }
            let remapped = Self.remapCriteria(
                criteria,
                collectionIDMap: report.collectionIDMap,
                stackIDMap: stackIDMap)
            if packageSearch.isGlobal {
                if globalSearchNames.contains(packageSearch.name) {
                    switch input.conflictPolicy {
                    case .keepLocal:
                        report.skippedSavedSearches += 1
                        continue
                    case .keepImported:
                        _ = try savedSearchRepo.upsert(
                            name: packageSearch.name, sessionId: nil, criteria: remapped)
                    case .coexist:
                        // 不覆盖别人的全局查询：撞名的全局查询落到新工作区作用域（加后缀）。
                        let name = Self.uniqueOrganizationName(
                            base: packageSearch.name, taken: globalSearchNames)
                        _ = try savedSearchRepo.upsert(
                            name: name, sessionId: newSession.id, criteria: remapped)
                        report.importedSavedSearches += 1
                        continue
                    }
                } else {
                    _ = try savedSearchRepo.upsert(
                        name: packageSearch.name, sessionId: nil, criteria: remapped)
                    globalSearchNames.insert(packageSearch.name)
                }
            } else {
                // 工作区作用域的保存查询随包迁移到新工作区（作用域不变）。
                _ = try savedSearchRepo.upsert(
                    name: packageSearch.name, sessionId: newSession.id, criteria: remapped)
            }
            report.importedSavedSearches += 1
        }

        // 人物绑定：身份按「包内 personId → 同名身份 → 新建」三级解析，照片经 idMap 映射。
        // 不迁移 face cluster id / 人脸向量：那属跨库不可靠映射（见 DTO 注释）。
        let personsRepo = PersonRepo(connection: connection)
        var personIDByName: [String: String] = [:]
        for person in try personsRepo.list() where personIDByName[person.name] == nil {
            personIDByName[person.name] = person.id
        }
        var photosByPersonID: [String: [PersonPhotoInput]] = [:]
        for binding in package.personBindings {
            guard let targetPhotoId = idMap[binding.photoId] else {
                report.skippedUnmappedItems += 1
                continue
            }
            let name = binding.personName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                report.skippedUnmappedItems += 1
                continue
            }
            let targetPersonId: String
            if (try personsRepo.get(id: binding.personId)) != nil {
                targetPersonId = binding.personId
            } else if let existingID = personIDByName[name] {
                targetPersonId = existingID
            } else {
                targetPersonId = try personsRepo.upsertByName(name: name)
                personIDByName[name] = targetPersonId
            }
            photosByPersonID[targetPersonId, default: []].append(
                PersonPhotoInput(
                    photoId: targetPhotoId, faceBbox: [], confidence: binding.confidence))
            report.importedPersonBindings += 1
        }
        for (personId, personPhotos) in photosByPersonID.sorted(by: { $0.key < $1.key }) {
            try personsRepo.addPhotos(
                personId: personId, sessionId: newSession.id, photos: personPhotos)
        }

        // 重复组：派生数据不重建（见 LibraryPackageDuplicateGroup 注释），只在报告标注。
        report.skippedDuplicateGroups = package.duplicateGroups.count

        _ = try sessions.refreshPhotoCount(id: newSession.id)
        // Wave5（B13）：导入后自动重索引 —— 路径重绑定（newRoot ≠ 包内 sourcePath）
        // 或有待索引照片（missing → pending）时入队 metadata.scan。
        // 入队失败只记日志：导入已落库，不因扫描任务失败而回滚。
        let pathsChanged = effectiveRoot != package.session.sourcePath
        if !importedPaths.isEmpty, pathsChanged || report.pendingCount > 0 {
            do {
                report.scanJobId = try Self.enqueueMetadataScan(
                    sessionId: newSession.id,
                    requestedPaths: Self.scanRoots(of: importedPaths),
                    connection: connection,
                    injected: enqueueScan)
            } catch {
                GatherLogger.log(
                    "library package import: enqueue metadata.scan failed: \(error)",
                    level: .warn)
            }
        }
        return report
    }

    // MARK: - 组织资产导出（Wave5 / Batch3）

    /// 堆栈：只导出包内存在的成员（归档/未导出成员不写）；成员全不在包里 → 不导出。
    static func exportStacks(
        sessionId: String,
        exportedIDs: Set<String>,
        repo: StackRepo
    ) throws -> [LibraryPackageStack] {
        try repo.list(sessionId: sessionId).compactMap { row in
            let memberIds = try repo.members(stackId: row.id)
                .map(\.photoId)
                .filter { exportedIDs.contains($0) }
            guard !memberIds.isEmpty else { return nil }
            let cover = row.coverPhotoId.flatMap { exportedIDs.contains($0) ? $0 : nil }
            return LibraryPackageStack(
                id: row.id, name: row.name, coverPhotoId: cover, photoIds: memberIds)
        }
    }

    /// 智能相册（库级）：criteria 原样搬运为 JSON 文本（导入侧再解码/重映射）。
    static func exportSmartAlbums(repo: SmartAlbumRepo) throws -> [LibraryPackageSmartAlbum] {
        try repo.list().map { row in
            LibraryPackageSmartAlbum(
                id: row.id,
                name: row.name,
                description: row.description,
                criteriaJSON: row.filterCriteria,
                sortBy: row.sortBy,
                sortOrder: row.sortOrder,
                icon: row.icon)
        }
    }

    /// 保存查询：全局（session_id IS NULL）+ 本工作区；criteria 编码成 JSON 文本。
    static func exportSavedSearches(
        sessionId: String,
        repo: SavedSearchRepo
    ) throws -> [LibraryPackageSavedSearch] {
        try repo.list(sessionId: sessionId).map { row in
            LibraryPackageSavedSearch(
                id: row.id,
                name: row.name,
                criteriaJSON: Self.encodeFilterGroup(row.criteria),
                isGlobal: row.sessionId == nil)
        }
    }

    /// 人物绑定：只导**可移植部分**（person 名 + photoId + 置信度）。
    static func exportPersonBindings(
        sessionId: String,
        exportedIDs: Set<String>,
        store: LibraryPackageStore
    ) throws -> [LibraryPackagePersonBinding] {
        try store.personBindingRows(sessionId: sessionId).compactMap { row in
            guard exportedIDs.contains(row.photoId), !row.personName.isEmpty else { return nil }
            return LibraryPackagePersonBinding(
                photoId: row.photoId,
                personId: row.personId,
                personName: row.personName,
                confidence: row.confidence)
        }
    }

    /// 重复组：只导出留档（导入不重建）；成员同样只取包内照片。
    static func exportDuplicateGroups(
        sessionId: String,
        exportedIDs: Set<String>,
        store: LibraryPackageStore
    ) throws -> [LibraryPackageDuplicateGroup] {
        let groups = try store.duplicateGroupRows(sessionId: sessionId)
        let memberRows = try store.duplicateGroupMemberRows(sessionId: sessionId)
        var membersByGroup: [Int64: [LibraryPackageDuplicateMember]] = [:]
        for row in memberRows where exportedIDs.contains(row.photoId) {
            membersByGroup[row.groupId, default: []].append(
                LibraryPackageDuplicateMember(
                    photoId: row.photoId, isKept: row.isKept, resolution: row.resolution))
        }
        return groups.compactMap { group in
            guard let members = membersByGroup[group.id], !members.isEmpty else { return nil }
            return LibraryPackageDuplicateGroup(
                groupType: group.groupType,
                checksum: group.checksum,
                hashHex: group.hashHex,
                members: members)
        }
    }

    // MARK: - 组织资产导入工具（Wave5 / Batch3）

    static func encodeFilterGroup(_ group: FilterGroup) -> String {
        do {
            let data = try JSONEncoder().encode(group)
            return String(decoding: data, as: UTF8.self)
        } catch {
            GatherLogger.log(
                "library package: encode filter criteria failed: \(error)", level: .debug)
            return "{}"
        }
    }

    /// 解码 criteria JSON；空/非法返回 nil（调用方计入 skippedBrokenCriteria，不建坏相册）。
    static func decodeFilterGroup(_ json: String) -> FilterGroup? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(FilterGroup.self, from: data)
        } catch {
            GatherLogger.log(
                "library package: decode filter criteria failed: \(error)", level: .debug)
            return nil
        }
    }

    /// 容器引用重映射：collection/stack 规则的 value（字符串或数组）里的包内 id 换新 id。
    ///
    /// 只改这两个字段：其它字段（评级/日期/关键词/色标…）本身就是可移植值，原样保留。
    static func remapCriteria(
        _ group: FilterGroup,
        collectionIDMap: [String: String],
        stackIDMap: [String: String]
    ) -> FilterGroup {
        FilterGroup(
            logic: group.logic,
            conditions: group.conditions.map { condition in
                switch condition {
                case .group(let nested):
                    return .group(remapCriteria(
                        nested, collectionIDMap: collectionIDMap, stackIDMap: stackIDMap))
                case .rule(let rule):
                    let map: [String: String]
                    switch rule.field {
                    case FilterFields.collection: map = collectionIDMap
                    case FilterFields.stack: map = stackIDMap
                    default: return .rule(rule)
                    }
                    return .rule(FilterRule(
                        field: rule.field,
                        operator: rule.operator,
                        value: Self.remapJSONValue(rule.value, map: map)))
                }
            })
    }

    static func remapJSONValue(_ value: JSONValue, map: [String: String]) -> JSONValue {
        switch value {
        case .string(let raw):
            if let mapped = map[raw] { return .string(mapped) }
            return value
        case .array(let items):
            return .array(items.map { remapJSONValue($0, map: map) })
        default:
            return value
        }
    }

    /// 组织资产撞名时的后缀命名（智能相册/保存查询共用一套，便于用户识别来源）。
    static func uniqueOrganizationName(base: String, taken: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "导入的组织" : trimmed
        var candidate = "\(resolved)（导入）"
        var index = 2
        while taken.contains(candidate) {
            candidate = "\(resolved)（导入 \(index)）"
            index += 1
            if index > 50 { break }
        }
        return candidate
    }

    // MARK: - 导入后重索引（Wave5 / B13）

    /// 索引扫描范围：导入照片的父目录去重排序（不把整个新根当作用域，避免重扫无关文件）。
    static func scanRoots(of filepaths: [String]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for path in filepaths {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, seen.insert(parent).inserted else { continue }
            roots.append(parent)
        }
        return roots.sorted()
    }

    /// 入队 metadata.scan：注入优先（测试），否则走 AnalysisJobRepo 的真实建任务。
    ///
    /// 为什么直接建 job 而不持 JobService：本服务是 Application 层的纯函数式服务，
    /// 不拥有执行器注册表；新 job 由常驻 JobService 的 watchdog（5s）pump 领取，
    /// 与其它入口同一条队列/去重语义。新工作区的 dedupeKey 全新，不会继承别的
    /// 会话的 checkpoint（继承只在同 dedupeKey 的历史终态行之间发生）。
    static func enqueueMetadataScan(
        sessionId: String,
        requestedPaths: [String],
        connection: DBConnection,
        injected: LibraryScanEnqueuer?
    ) throws -> String {
        if let injected {
            return try injected(sessionId, requestedPaths)
        }
        let params = JobCreateParams.metadataScan(
            sessionId: sessionId,
            requestedPaths: requestedPaths.isEmpty ? nil : requestedPaths)
        return try AnalysisJobRepo(connection: connection).create(params).id
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

    /// 有效导入根：显式 newRoot 优先；空串回退到包内工作区 sourcePath（P1：
    /// 原实现空根直接把 relativePath 当 filepath 落库，变成相对路径）。
    static func effectiveRoot(newRoot: String, packageSourcePath: String) -> String {
        let candidate = newRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? packageSourcePath : candidate
    }

    /// 相对路径 + 新根 → 绝对路径。
    ///
    /// P1（task-31 review）：包内 relativePath 是不可信输入——拒绝绝对路径与任何
    /// `..` 段；standardize 后必须仍落在 root 内，否则抛 INVALID_PARAM，导入事务
    /// 整体回滚（调用方 MaintenanceService 的 database.write）。
    static func absolutePath(relativePath: String, newRoot: String) throws -> String {
        let root = (newRoot as NSString).standardizingPath
        guard !root.isEmpty, (root as NSString).isAbsolutePath else {
            throw GatherError.invalidParameter(
                field: "newRoot", reason: "a non-empty absolute root is required")
        }
        let raw = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "photo relativePath is empty")
        }
        guard !(raw as NSString).isAbsolutePath else {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "absolute photo path is not allowed")
        }
        // 先拒绝原始 `..`（不依赖 standardize，保留显式报警），standardize 后再检查一次。
        let rawSegments = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawSegments.contains("..") else {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "photo path must not contain '..'")
        }
        let standardized = (raw as NSString).standardizingPath
        guard standardized != ".", !standardized.hasPrefix("../"),
              !standardized.split(separator: "/").contains(".."),
              !(standardized as NSString).isAbsolutePath else {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "photo path escapes the package root")
        }
        let joined = (root as NSString).appendingPathComponent(standardized)
        let normalized = (joined as NSString).standardizingPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard normalized.hasPrefix(prefix), normalized.count > prefix.count else {
            throw GatherError.invalidParameter(
                field: "packagePath", reason: "photo path escapes the new root")
        }
        return normalized
    }

    private static func nonEmptyLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

// desktop/native/gather-core/Sources/GatherApplication/Services/Maintenance/LibraryPackageService.swift
// Wave3（task-24）：可移植目录包的导出/导入（Application 门面：包格式 + 文件 IO）。
//
// 包 = JSON（LibraryPackage）+ 相对路径清单；**不打包原图**：
// - 导出：photos 投影（路径/校验和/尺寸/时间）+ photo_metadata_cache（rating/label/keywords/IPTC）
//   + culling_decisions.decision + 会话内手动集合成员；
// - 导入：按 photoId → checksum 两级去重，冲突策略显式（keepLocal/keepImported/coexist），
//   按 newRoot 重绑定相对路径，评分/关键词/集合成员随行迁移。
//
// Wave5（Batch3 / task-20）：包格式 v2 带**组织资产**（见 MaintenanceAPI 的段 DTO）：
// - 导出：stacks / smartAlbums / savedSearches / personBindings、duplicateGroups（留档）；
// - 导入：堆栈/智能相册/保存查询/人物绑定按 photoId 映射重建（容器引用规则重写新 id）；
//   重复组是派生数据**不重建**（报告标注 skipped）；映射不到的条目进 skippedUnmappedItems；
// - 收尾：路径重绑定或有待索引照片时自动入队 metadata.scan（enqueueScan 接缝可注入）。
//
// R1（2026-11-18 Wave 4）：库访问全部下沉到 GatherPersistence 的
// LibraryPackageSnapshotting 窄端口（LibraryPackageStore+Snapshot.swift）；本文件只保留
// 包 JSON 编解码、版本校验、路径/文件 IO 与名称规则，**不再持 DBConnection**、不建仓储。
// 调用方（MaintenanceService → LiveMaintenanceAPI → ControlCenter）负责域广播。
import Foundation
import GatherProtocol
import GatherPersistence

/// 导入后入队 metadata.scan 的接缝（测试注入记录器；nil = 由持久化端口走 AnalysisJobRepo 真实入队）。
public typealias LibraryScanEnqueuer = @Sendable (_ sessionId: String, _ requestedPaths: [String]) throws -> String

public struct LibraryPackageService: Sendable {
    /// R1：目录包导出/导入的持久化快照端口（实现与 SQL 都在 GatherPersistence）。
    private let store: any LibraryPackageSnapshotting
    /// 导入成功后的索引扫描入队接缝（nil = 生产实现）。
    private let enqueueScan: LibraryScanEnqueuer?

    public init(store: any LibraryPackageSnapshotting, enqueueScan: LibraryScanEnqueuer? = nil) {
        self.store = store
        self.enqueueScan = enqueueScan
    }

    // MARK: - 导出

    public func exportPackage(_ input: LibraryExportInput) throws -> LibraryExportResult {
        guard let package = try store.exportSnapshot(
            sessionId: input.sessionId, includeArchived: input.includeArchived
        ) else {
            throw GatherError(code: .SESSION_NOT_FOUND)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(package)
        let fileURL = try Self.resolvePackageURL(
            destinationPath: input.destinationPath, sessionName: package.session.name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        let archived = try store.archivedCount(sessionId: input.sessionId)
        return LibraryExportResult(
            packagePath: fileURL.path,
            photoCount: package.photos.count,
            collectionCount: package.collections.count,
            skippedArchivedCount: input.includeArchived ? 0 : archived,
            stackCount: package.stacks.count,
            smartAlbumCount: package.smartAlbums.count,
            savedSearchCount: package.savedSearches.count,
            personBindingCount: package.personBindings.count,
            duplicateGroupCount: package.duplicateGroups.count
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
        return try store.importPackage(
            package,
            input: input,
            sessionName: sessionName,
            effectiveRoot: effectiveRoot,
            enqueueScan: enqueueScan)
    }

    // MARK: - 包路径与名称（纯文件 IO / 名称规则，不触库）

    /// 有效导入根：显式 newRoot 优先；空串回退到包内工作区 sourcePath（P1：
    /// 原实现空根直接把 relativePath 当 filepath 落库，变成相对路径）。
    static func effectiveRoot(newRoot: String, packageSourcePath: String) -> String {
        let candidate = newRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? packageSourcePath : candidate
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
}

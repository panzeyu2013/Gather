// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputService.swift
// 整套交付：逐配方导出 → 可选联系表 → 可选画廊 → manifest。纯编排，不做图像处理。
//
// 约定：
// - 每个配方独立走 ExportService.execute（它自带断点续跑与覆盖回滚），失败不阻断其它配方；
// - 配方目标目录在开始前统一解析（占位符/绝对化/同名冲突检测），冲突显式报错；
// - 联系表与画廊只用**导出产物**（失败/缺文件不入册），保证客户看到的就是交付的东西；
// - isCancelled 在配方之间、联系表/画廊之前检查，取消尽快生效。
import Foundation
import GatherProtocol

public struct OutputProgress: Equatable, Sendable {
    public var recipeIndex: Int
    public var recipeCount: Int
    public var recipeName: String
    public var current: Int
    public var total: Int

    public init(
        recipeIndex: Int, recipeCount: Int, recipeName: String, current: Int, total: Int
    ) {
        self.recipeIndex = recipeIndex
        self.recipeCount = recipeCount
        self.recipeName = recipeName
        self.current = current
        self.total = total
    }
}

public enum OutputServiceError: Error, Equatable, CustomStringConvertible {
    case noRecipes
    case invalidRoot(String)
    case invalidDestination(String)
    case recipeConflict(String)
    case manifestFailed(String)

    public var code: String {
        switch self {
        case .noRecipes: "OUTPUT_NO_RECIPES"
        case .invalidRoot: "OUTPUT_ROOT_INVALID"
        case .invalidDestination: "OUTPUT_DESTINATION_INVALID"
        case .recipeConflict: "OUTPUT_RECIPE_CONFLICT"
        case .manifestFailed: "OUTPUT_MANIFEST_FAILED"
        }
    }

    public var description: String {
        switch self {
        case .noRecipes: "OUTPUT_NO_RECIPES"
        case .invalidRoot(let reason): "OUTPUT_ROOT_INVALID: " + reason
        case .invalidDestination(let reason): "OUTPUT_DESTINATION_INVALID: " + reason
        case .recipeConflict(let name): "OUTPUT_RECIPE_CONFLICT: " + name
        case .manifestFailed(let reason): "OUTPUT_MANIFEST_FAILED: " + reason
        }
    }
}

public final class OutputService: @unchecked Sendable {
    private let exportService: ExportService

    public init(exportService: ExportService) {
        self.exportService = exportService
    }

    /// 逐配方执行。失败只记在该配方的 errors 里，不中断后续配方与 manifest。
    public func run(
        input: OutputRunInput,
        runId: String? = nil,
        isCancelled: () -> Bool = { false },
        resume: [String: OutputRecipeResume] = [:],
        onRecipeResume: ((String, OutputRecipeResume) -> Void)? = nil,
        onProgress: ((OutputProgress) -> Void)? = nil
    ) throws -> OutputRunSummary {
        guard !input.recipes.isEmpty else { throw OutputServiceError.noRecipes }
        guard !input.destinationRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.destinationRoot.hasPrefix("/") else {
            throw OutputServiceError.invalidRoot(input.destinationRoot)
        }
        let root = URL(fileURLWithPath: input.destinationRoot).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runId = runId ?? UUID().uuidString.lowercased()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let destinations = try resolveDestinations(
            recipes: input.recipes, root: root, sessionId: input.sessionId)
        let manifestPath = root.appendingPathComponent("manifest-\(runId).json").path

        var results: [OutputRecipeResult] = []
        var didCancel = false
        // 取消也必须留下「已交付了什么」的记录：成片已经写盘，没有 manifest
        // 就无法审计/续跑。
        defer {
            if didCancel {
                let partial = OutputRunSummary(
                    runId: runId, sessionId: input.sessionId, manifestPath: manifestPath,
                    createdAt: createdAt, recipes: results, cancelled: true)
                do {
                    try writeManifest(partial, to: manifestPath)
                } catch {
                    GatherLogger.log("partial manifest failed after cancel", level: .warn)
                }
            }
        }
        for (index, recipe) in input.recipes.enumerated() {
            if isCancelled() { didCancel = true; throw CancellationError() }
            let destination = destinations[index]
            let options = ExportOptions(
                scope: input.scope,
                variantPolicy: .preferred,
                format: recipe.format,
                quality: recipe.quality,
                maxDimension: recipe.maxDimension,
                tiffCompression: recipe.format == .tiff ? .lzw : nil,
                watermark: recipe.watermark,
                naming: recipe.naming,
                // includeMetadata 目前等价于“把源 sidecar 随成片带过去”，
                // 不能作为死字段：否则批量交付默认 includeXmp=false 会丢 caption/关键词。
                includeXmp: recipe.includeXmp || recipe.includeMetadata,
                destination: destination)
            var exported = 0
            var failed = 0
            var skipped = 0
            var errors: [String] = []
            // 产物清单由 execute 回调给出：不再另建一份计划（两份计划会漂移，
            // 且每张照片多两次 stat）。续跑跳过但文件仍在的也回调，保证画廊完整。
            var written: [(photoId: String, url: URL, name: String)] = []
            // 指纹 = 配方参数（不含 artifacts）+ 范围 + 源内容摘要。
            // 源摘要复用单导出路径的 deliveryFingerprint（含 checksum/size/mtime/命名/sidecar 版本），
            // 否则「改了源片再交付」会因 completedPhotoIds 命中而整批跳过、manifest 谎报成功。
            let sourceDigest = (try? exportService.deliveryFingerprint(
                sessionId: input.sessionId, options: options)) ?? ""
            let recipeFingerprint = Self.recipeFingerprint(
                recipe: recipe, scope: input.scope, sourceDigest: sourceDigest)
            // 参数变更后旧完成清单不可复用（否则会跳过“旧参数产物”并在 manifest 里谎报成功）。
            let seed = resume[recipe.id].flatMap {
                $0.recipeFingerprint == recipeFingerprint ? $0 : nil
            }
            let accumulator = OutputResumeAccumulator(
                recipeId: recipe.id,
                seed: seed,
                recipeFingerprint: recipeFingerprint,
                emit: { recipeId, state in onRecipeResume?(recipeId, state) })
            let resumeState = NativeExportResumeState(
                destinations: accumulator.destinations,
                completedPhotoIds: accumulator.completed,
                sidecarVersions: accumulator.versions,
                onPlanned: { photoId, name in accumulator.planned(photoId, name) },
                onPlanReady: { accumulator.flush() },
                onCompleted: { photoId, version in accumulator.completedPhoto(photoId, version) })
            do {
                let result = try exportService.execute(
                    sessionId: input.sessionId,
                    options: options,
                    runId: runId,
                    onProgress: { progress in
                        onProgress?(OutputProgress(
                            recipeIndex: index, recipeCount: input.recipes.count,
                            recipeName: recipe.name,
                            current: progress.current, total: progress.total))
                    },
                    resume: resumeState,
                    onWritten: { photoId, url in
                        written.append((photoId: photoId, url: url, name: url.lastPathComponent))
                    })
                exported = result.exported
                failed = result.failed
                skipped = result.skipped
                errors += result.errors
            } catch is CancellationError {
                didCancel = true; throw CancellationError()
            } catch {
                failed = 1
                errors = [String(describing: error)]
            }
            accumulator.flush()
            if isCancelled() {
                // 当前配方已写出的部分也要进 partial manifest（否则审计缺一半）。
                results.append(OutputRecipeResult(
                    recipeId: recipe.id, name: recipe.name, destination: destination,
                    exported: exported, failed: failed, skipped: skipped,
                    errors: errors + ["cancelled"]))
                didCancel = true; throw CancellationError()
            }

            // 联系表/画廊只收真正写出的产物（导出失败或文件缺失的照片不入册）。
            let outputs = written.filter { FileManager.default.fileExists(atPath: $0.url.path) }

            var galleryPath: String?
            var galleryItems: Int?
            var gallerySkipped: Int?
            if recipe.artifacts.contains(.gallery), let gallery = input.gallery {
                if outputs.isEmpty {
                    errors.append("gallery: no exported files")
                } else {
                    do {
                        let built = try makeGallery(
                            outputs: outputs, destination: destination,
                            gallery: gallery, isCancelled: isCancelled)
                        galleryPath = built.indexPath
                        galleryItems = built.itemCount
                        gallerySkipped = built.skipped
                    } catch is CancellationError {
                        didCancel = true; throw CancellationError()
                    } catch {
                        errors.append("gallery: " + String(describing: error))
                    }
                }
            }
            if isCancelled() { didCancel = true; throw CancellationError() }

            var contactSheetPath: String?
            var contactSheetFailed: Int?
            if recipe.artifacts.contains(.contactSheet), let sheet = input.contactSheet {
                if outputs.isEmpty {
                    errors.append("contact sheet: no exported files")
                } else {
                    do {
                        let built = try makeContactSheet(
                            outputs: outputs, destination: destination,
                            sheet: sheet, isCancelled: isCancelled)
                        contactSheetPath = built.path
                        contactSheetFailed = built.failedImages
                    } catch is CancellationError {
                        didCancel = true; throw CancellationError()
                    } catch {
                        errors.append("contact sheet: " + String(describing: error))
                    }
                }
            }
            // manifest 的成品清单：名称 + 字节数（不写绝对路径）。
            // 包含成片、联系表与画廊入口，支撑「交付了什么」的离线审计。
            var files = outputs.map { output in
                Self.fileEntry(at: output.url, name: output.name)
            }
            if let contactSheetPath {
                files.append(Self.fileEntry(
                    at: URL(fileURLWithPath: contactSheetPath),
                    name: URL(fileURLWithPath: contactSheetPath).lastPathComponent))
            }
            if let galleryPath {
                files.append(Self.fileEntry(
                    at: URL(fileURLWithPath: galleryPath), name: "gallery/index.html"))
            }
            results.append(OutputRecipeResult(
                recipeId: recipe.id, name: recipe.name, destination: destination,
                exported: exported, failed: failed, skipped: skipped,
                contactSheetPath: contactSheetPath,
                contactSheetFailedImages: contactSheetFailed,
                galleryPath: galleryPath, galleryItems: galleryItems,
                gallerySkipped: gallerySkipped, files: files, errors: errors))
        }

        var manifestError: String?
        let summary = OutputRunSummary(
            runId: runId, sessionId: input.sessionId, manifestPath: manifestPath,
            createdAt: createdAt, recipes: results)
        do {
            try writeManifest(summary, to: manifestPath)
        } catch {
            // 成片已经全部写出：manifest 失败只降级为警告，不把交付判成失败。
            manifestError = String(describing: error)
            GatherLogger.log("output manifest failed: \(manifestError ?? "")", level: .warn)
        }
        return OutputRunSummary(
            runId: summary.runId, sessionId: summary.sessionId,
            manifestPath: summary.manifestPath, createdAt: summary.createdAt,
            recipes: summary.recipes, manifestError: manifestError)
    }

    // MARK: - 目标目录解析

    /// 占位符：{session} 会话 id、{recipe} 配方名、{date} yyyy-MM-dd、{time} HHmmss。
    static func expandPlaceholders(
        _ template: String, sessionId: String, recipeName: String, date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HHmmss"
        let time = formatter.string(from: date)
        return template
            .replacingOccurrences(of: "{session}", with: sessionId)
            .replacingOccurrences(of: "{recipe}", with: sanitize(recipeName))
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)
    }

    /// 配方内容指纹（参数 + 范围 + 源内容摘要）：续跑只复用同一份输入的状态。
    /// artifacts 不进指纹（见 OutputRecipe.withoutArtifacts）。
    static func recipeFingerprint(
        recipe: OutputRecipe, scope: ExportScope, sourceDigest: String
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = RecipeFingerprintPayload(
            recipe: recipe.withoutArtifacts, scope: scope.rawValue, sourceDigest: sourceDigest)
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            return UUID().uuidString.lowercased()
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private struct RecipeFingerprintPayload: Encodable {
        var recipe: OutputRecipe
        var scope: String
        var sourceDigest: String
    }

    private func resolveDestinations(
        recipes: [OutputRecipe], root: URL, sessionId: String
    ) throws -> [String] {
        var seen = Set<String>()
        var resolved: [String] = []
        for recipe in recipes {
            let raw: String
            if recipe.destination.isEmpty {
                raw = root.appendingPathComponent(Self.sanitize(recipe.name)).path
            } else {
                // {date} 已由 expandPlaceholders 按本地日期替换；不再二次替换（死代码）。
                let expanded = Self.expandPlaceholders(
                    recipe.destination, sessionId: sessionId, recipeName: recipe.name)
                guard expanded.hasPrefix("/") else {
                    throw OutputServiceError.invalidDestination(expanded)
                }
                raw = expanded
            }
            let normalized = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard !seen.contains(normalized) else {
                throw OutputServiceError.recipeConflict(recipe.name)
            }
            seen.insert(normalized)
            resolved.append(normalized)
        }
        return resolved
    }

    // MARK: - 联系表 / 画廊

    private func makeContactSheet(
        outputs: [(photoId: String, url: URL, name: String)],
        destination: String,
        sheet: OutputContactSheetOptions,
        isCancelled: () -> Bool
    ) throws -> (path: String, failedImages: Int) {
        let items = outputs.map {
            ContactSheetItem(path: $0.url.path, caption: $0.name)
        }
        let sheetOptions = ContactSheetOptions(
            columns: sheet.columns, rows: sheet.rows,
            title: sheet.title, subtitle: sheet.subtitle, footerText: sheet.footer)
        let name = "contact-sheet-\(Self.timestamp()).pdf"
        let url = URL(fileURLWithPath: destination).appendingPathComponent(name)
        let result = try ContactSheetRenderer.render(
            items: items, options: sheetOptions, to: url, isCancelled: isCancelled)
        return (url.path, result.failedImages)
    }

    private func makeGallery(
        outputs: [(photoId: String, url: URL, name: String)],
        destination: String,
        gallery: OutputGalleryOptions,
        isCancelled: () -> Bool
    ) throws -> GalleryResult {
        let items = outputs.map {
            GalleryItem(id: $0.photoId, path: $0.url.path, name: $0.name, caption: $0.name)
        }
        return try GalleryBuilder.build(
            items: items,
            options: GalleryOptions(
                title: gallery.title.isEmpty ? "Gallery" : gallery.title,
                subtitle: gallery.subtitle,
                footer: gallery.footer,
                thumbnailMaxDimension: gallery.thumbnailMaxDimension,
                largeMaxDimension: gallery.largeMaxDimension),
            destination: URL(fileURLWithPath: destination).appendingPathComponent("gallery"),
            isCancelled: isCancelled)
    }

    // MARK: - 工具

    /// 目录名清洗：只留字母数字与 CJK、- _ 空格；空名回落 output。
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ "))
            .union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        let mapped = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : nil }
        let cleaned = String(mapped.compactMap { $0 })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "output" : cleaned
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func fileEntry(at url: URL, name: String) -> OutputFileEntry {
        let bytes: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            bytes = 0
        }
        return OutputFileEntry(name: name, bytes: bytes)
    }

    private func writeManifest(_ summary: OutputRunSummary, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(summary)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw OutputServiceError.manifestFailed(String(describing: error))
        }
    }
}


/// 收集单个配方的续跑状态并节流回写（execute 的回调是同步单线程，无需加锁）。
private final class OutputResumeAccumulator {
    let recipeId: String
    var destinations: [String: String]
    var completed: Set<String>
    var versions: [String: String]
    private let emit: (String, OutputRecipeResume) -> Void
    private var pendingChanges = 0
    private var lastEmit = Date.distantPast

    private let recipeFingerprint: String

    init(
        recipeId: String,
        seed: OutputRecipeResume?,
        recipeFingerprint: String,
        emit: @escaping (String, OutputRecipeResume) -> Void
    ) {
        self.recipeId = recipeId
        self.destinations = seed?.destinations ?? [:]
        self.completed = Set(seed?.completedPhotoIds ?? [])
        self.versions = seed?.sidecarVersions ?? [:]
        self.recipeFingerprint = recipeFingerprint
        self.emit = emit
    }

    func planned(_ photoId: String, _ name: String) {
        destinations[photoId] = name
        pendingChanges += 1
        maybeEmit()
    }

    func completedPhoto(_ photoId: String, _ version: String) {
        completed.insert(photoId)
        versions[photoId] = version
        pendingChanges += 1
        maybeEmit()
    }

    func flush() {
        pendingChanges = 0
        lastEmit = Date()
        emit(recipeId, snapshot())
    }

    private func maybeEmit() {
        // 每 20 张或 1 秒回写一次 checkpoint；太频繁会拖慢导出，太稀疏会丢进度。
        if pendingChanges >= 20 || Date().timeIntervalSince(lastEmit) >= 1 {
            flush()
        }
    }

    private func snapshot() -> OutputRecipeResume {
        OutputRecipeResume(
            destinations: destinations,
            completedPhotoIds: Array(completed).sorted(),
            sidecarVersions: versions,
            recipeFingerprint: recipeFingerprint)
    }
}


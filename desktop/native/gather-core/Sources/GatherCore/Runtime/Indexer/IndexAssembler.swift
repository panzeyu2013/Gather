// desktop/native/gather-core/Sources/GatherCore/Runtime/Indexer/IndexAssembler.swift
// W2d-5 步骤①：Indexer 纯函数层（Services/IndexerService.swift 的纯逻辑下沉）。
//
// 来源与边界：
// - 逐字移植 IndexerService.swift 中的纯逻辑：支持扩展名集合与常量（SUPPORTED/
//   WALK_CHANNEL_CAPACITY/IN_CHUNK_SIZE/PRUNE_LIKE_PREFILTER_CAP/
//   CHECKSUM_BACKFILL_*/SCAN_BATCH_*）、路径归一化（textualPath/canonicalPath/
//   isWithin 及内联的 normalize+resolve 去重键）、排除根判定、扩展名判定、批分片
//   （chunked）、checksum 回填过滤（needsChecksumBackfill）、内容变化判定
//   （contentChanged）与缺失对账（missingPhotos）。
// - 本文件自身不发起 Store/SQL/文件树遍历：输入均为值类型（String/Set/Int64/
//   PhotoProjection 值袋），只做字符串、路径与数值判定。唯一例外是 canonicalPath
//   依赖 POSIX realpath 的只读路径解析（与旧实现逐字一致；失败仍回退 textualPath）。
// - 设计文档门禁：Runtime/** 内不得出现 SQL 语句文本或数据库连接类型（本文件
//   既不 import C SQLite，也不持有连接）。
//
// 命名注记（设计文档 §2 计划名 vs 本步骤实际）：
// - 设计文档计划把 Indexer 纯逻辑拆为 IndexScanFilter/IndexPathKeys/IndexBatching
//   等容器；本步骤①按任务要求先合并为单一 caseless enum IndexAssembler（对齐
//   Runtime/Export/ExportAssembler.swift 形态），后续如需分域可机械拆分。
//
// 行为保持（审计要点）：
// - 所有函数与旧实现逐字等价，含：walkChannelCapacity=256、inChunkSize=400、
//   scanBatch 并发 4 / 批 32、checksum 回填批 32 / 并发 6 / 页 2000、
//   pruneLikePrefilterCap=200 等常量取值；isWithin 的空相对路径分支；
//   chunked 的 stride 边界；contentChanged 的 mtime 阈值 1（>=1 判变化、
//   <1 判未变）；missingPhotos 的 existing 顺序与 requestedNormalized=nil
//   即全量语义。
// - 服务侧仅把内联表达式改为调用本层函数（不保留第二份实现），调用序与捕获序
//   不变，行为逐字不变。

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// TS: index.service.ts 的纯函数面（Store 写入、目录遍历、事务与取消标记均不在此文件）。
public enum IndexAssembler {

    // MARK: - 常量（旧 IndexerService 静态常量）

    /// TS: SUPPORTED（index.service.ts 顶部）。
    public static let supportedExtensions: Set<String> = [
        ".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif",
        ".nef", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw",
        ".tif", ".tiff", ".psd",
    ]
    /// TS: WALK_CHANNEL_CAPACITY。
    public static let walkChannelCapacity = 256
    /// TS: IN_CHUNK_SIZE。
    public static let inChunkSize = 400
    /// TS: PRUNE_LIKE_PREFILTER_CAP。
    public static let pruneLikePrefilterCap = 200
    /// TS: CHECKSUM_BACKFILL_BATCH / CHECKSUM_BACKFILL_CONCURRENCY /
    /// CHECKSUM_BACKFILL_PAGE_SIZE。
    public static let checksumBackfillBatch = 32
    public static let checksumBackfillConcurrency = 6
    public static let checksumBackfillPageSize = 2000
    /// TS: SCAN_BATCH_CONCURRENCY / SCAN_BATCH_FILES。
    public static let scanBatchConcurrency = 4
    public static let scanBatchFiles = 32

    // MARK: - 路径（旧 IndexerService.textualPath / canonicalPath / isWithin）

    /// TS: textualPath —— 仅解析 macOS 的两个符号链接前缀，避免逐文件 realpath。
    public static func textualPath(_ value: String) -> String {
        let resolved = TSPath.resolve(value)
        if resolved == "/var" || resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        if resolved == "/tmp" || resolved.hasPrefix("/tmp/") {
            return "/private" + resolved
        }
        return resolved
    }

    /// TS: canonicalPath —— realpath，失败回退 textualPath（macOS /var、/tmp 前缀）。
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return textualPath(path)
    }

    /// TS: isWithin —— 候选路径是否落在规范根之内。
    public static func isWithin(candidate: String, canonicalRoot: String) -> Bool {
        let relative = TSPath.relative(canonicalRoot, to: textualPath(candidate))
        return relative == "" || (!relative.hasPrefix("..") && !TSPath.isAbsolute(relative))
    }

    /// 排除根判定（旧 scanSession/walk 三处内联 excludedRoots 判定的统一形态）。
    public static func isExcluded(path: String, excludedRoots: [String]) -> Bool {
        excludedRoots.contains { isWithin(candidate: path, canonicalRoot: $0) }
    }

    /// 去重键 / 索引键归一化（旧内联 TSPath.normalize(TSPath.resolve(value))）。
    public static func normalizedPath(_ value: String) -> String {
        TSPath.normalize(TSPath.resolve(value))
    }

    // MARK: - 扩展名判定（旧内联 supportedExtensions.contains(TSPath.extname(...).lowercased())）

    /// 支持的照片文件判定：扩展名（含点、小写）在 SUPPORTED 集合内。
    public static func isSupportedImage(_ pathOrName: String) -> Bool {
        supportedExtensions.contains(TSPath.extname(pathOrName).lowercased())
    }

    // MARK: - 批分片（旧 IndexerService.chunked）

    /// TS: IN_CHUNK_SIZE 分片（旧私有 chunked 逐字搬迁，IN 子句占位符上限友好）。
    public static func chunked(_ values: [String]) -> [[String]] {
        var chunks: [[String]] = []
        for offset in stride(from: 0, to: values.count, by: inChunkSize) {
            chunks.append(Array(values[offset..<min(offset + inChunkSize, values.count)]))
        }
        return chunks
    }

    // MARK: - 扫描过滤判定

    /// TS: loadPendingBackfill 的 pending 判定（旧内联条件逐字搬迁）：
    /// checksum 缺失（nil 或空串）且状态非 missing。
    public static func needsChecksumBackfill(checksum: String?, status: String) -> Bool {
        (checksum?.isEmpty ?? true) && status != "missing"
    }

    /// TS: scanBatch 内容变化判定（旧内联分支逐字搬迁）：有 asset_files 基线时
    /// 比 size/mtime（|Δmtime| >= 1ms 判变化）；无基线时用照片自身索引 stat
    /// （checksum_file_size/mtime），全等才判未变。
    public static func contentChanged(
        indexedFileSize: Int64?,
        indexedFileMtimeMs: Double?,
        photoChecksumFileSize: Int,
        photoChecksumFileMtimeMs: Double,
        sourceSize: Int64,
        sourceMtimeMs: Double
    ) -> Bool {
        if let indexedFileSize, let indexedFileMtimeMs {
            return indexedFileSize != sourceSize
                || abs(indexedFileMtimeMs - sourceMtimeMs) >= 1
        }
        return !(photoChecksumFileSize > 0
            && Int64(photoChecksumFileSize) == sourceSize
            && abs(photoChecksumFileMtimeMs - sourceMtimeMs) < 1)
    }

    // MARK: - 缺失对账（旧 scanSession 末段内联循环）

    /// 缺失对账：requestedNormalized=nil 表示全量（不做请求集合过滤）；
    /// 对账键为 normalizedPath(filepath)，重链接照片不判缺失；返回顺序与
    /// existing 一致。
    public static func missingPhotos(
        existing: [PhotoProjection],
        requestedNormalized: Set<String>?,
        discoveredSet: Set<String>,
        relinkedPhotoIds: Set<String>
    ) -> [PhotoProjection] {
        var missing: [PhotoProjection] = []
        for photo in existing {
            let normalized = normalizedPath(photo.filepath)
            let inRequested = requestedNormalized.map { $0.contains(normalized) } ?? true
            if inRequested
                && !discoveredSet.contains(normalized)
                && !relinkedPhotoIds.contains(photo.id) {
                missing.append(photo)
            }
        }
        return missing
    }
}

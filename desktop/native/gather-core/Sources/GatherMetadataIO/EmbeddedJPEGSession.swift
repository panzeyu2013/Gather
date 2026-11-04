// desktop/native/gather-core/Sources/GatherMetadataIO/EmbeddedJPEGSession.swift
// 内嵌 JPEG 写回的"一次打开、两次顺序遍历"会话（plan §3.2）。
//
// 旧路径一次写回要读 6–8 遍整文件（写前指纹 / 备份 / ImageIO 读属性 / Data 读全文 /
// 写后校验 / ImageIO 再解析 / 写后指纹 / 写后回读），峰值内存 4–6 × 文件。
// 本会话把它收敛成：
//   快照（open）：1 次顺序遍历 —— 段扫描 + 全文件 SHA-256 + 扫描段 SHA-256 + 读属性
//   提交（commit）：写头部 + 1 次顺序遍历拷贝扫描段（同时算输出 SHA 与扫描 SHA）
// 内存只有：头部（≤4MiB）+ 1MiB 块 + 重建头部，与文件大小无关。
//
// 提交顺序（校验全部前移到替换之前，因此没有回滚路径）：
//   1. 重建头部（与旧路径共用 JPEGMetadataWriter.segmentEdits）
//   2. 同目录临时文件写头部 → 分块拷贝扫描段（同时算两个 hasher）→ fsync
//   3. 替换前校验：扫描摘要一致 + 临时文件 size 正确 + 头部回读跑 XMPPacketReader
//      与 SidecarXMPProvider.verify 逐字段一致 + 原文件 size/mtime 未变
//   4. replaceItemAt（保留权限/ACL/xattr）
//   5. fingerprintAfter = "<新 size>:<新 mtimeMs>:<输出 SHA>"（不重读）
// 任何一步失败：只删临时文件，原片一个字节都没动。
import CryptoKit
import Foundation
import os
import GatherPersistence
import GatherProtocol

/// 观测/故障注入钩子（生产为空；测试用它断言读放大与崩溃点）。
public struct EmbeddedJPEGSessionHooks: Sendable {
    /// 每读到一块字节回调一次（快照与提交两条遍历都算）。
    public var onReadBytes: (@Sendable (Int) -> Void)?
    /// 替换前校验前调用；抛错 = 模拟"校验失败"崩溃点（原文件不得被改）。
    public var beforeVerification: (@Sendable () throws -> Void)?
    /// 原子替换前调用；抛错 = 模拟"替换前失败"崩溃点（原文件不得被改）。
    public var beforeInstall: (@Sendable () throws -> Void)?

    public init(
        onReadBytes: (@Sendable (Int) -> Void)? = nil,
        beforeVerification: (@Sendable () throws -> Void)? = nil,
        beforeInstall: (@Sendable () throws -> Void)? = nil
    ) {
        self.onReadBytes = onReadBytes
        self.beforeVerification = beforeVerification
        self.beforeInstall = beforeInstall
    }
}

/// 快路径的稳定错误码（对齐 EmbeddedJPEGError / SidecarXMPError 的形态）。
enum EmbeddedSessionError: Error, Equatable, CustomStringConvertible, MetadataCodedError {
    case backupFailed(String)
    case atomicWriteFailed(String)
    case verificationFailed(String)
    /// 拷贝扫描段期间源文件被改（扫描摘要不一致 / size·mtime 变化）。
    case externalConflict(String)
    case alreadyClosed

    var code: String {
        switch self {
        case .backupFailed: "EMBEDDED_BACKUP_FAILED"
        case .atomicWriteFailed: "EMBEDDED_ATOMIC_WRITE_FAILED"
        case .verificationFailed: "EMBEDDED_WRITE_VERIFICATION_FAILED"
        case .externalConflict: "XMP_EXTERNAL_EDIT_CONFLICT"
        case .alreadyClosed: "EMBEDDED_SESSION_CLOSED"
        }
    }

    /// 会话不知道交付层用的 xmpPath 键：留空让 MetadataWritebackFailure 用调用方的路径。
    var xmpPath: String { "" }

    var description: String {
        switch self {
        case .backupFailed(let reason):
            "EMBEDDED_BACKUP_FAILED: " + reason
        case .atomicWriteFailed(let reason):
            "EMBEDDED_ATOMIC_WRITE_FAILED: " + reason
        case .verificationFailed(let reason):
            "EMBEDDED_WRITE_VERIFICATION_FAILED: " + reason
        case .externalConflict(let reason):
            "XMP_EXTERNAL_EDIT_CONFLICT: " + reason
        case .alreadyClosed:
            "EMBEDDED_SESSION_CLOSED"
        }
    }
}

/// 内嵌目标的会话工厂。
///
/// 返回 nil = "不是内嵌目标/不支持"：WritebackService 回退旧路径（逐字节不变）。
/// 生产装配（Core.swift）只需要给 isEmbeddedTarget（写目标解析器判 kind == .embedded），
/// 其余收紧条件（非 JPEG / 已存在 sidecar / 非普通文件）由工厂自己判断：
/// - sidecar 存在时旧路径的读取会叠加 .xmp 覆盖（router.readEmbedded 语义），
///   快路径不做这个合并，因此必须交回旧路径，否则读到的基线与旧路径不一致。
public struct EmbeddedJPEGSessionFactory: MetadataRewriteSessionFactory {
    private let isEmbeddedTarget: @Sendable (String) -> Bool
    private let isEnabled: @Sendable () -> Bool
    private let chunkBytes: Int
    private let hooks: EmbeddedJPEGSessionHooks
    private let dcSubjectStyle: KeywordDCSubjectStyle

    public init(
        isEmbeddedTarget: @escaping @Sendable (String) -> Bool,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        chunkBytes: Int = 1 << 20,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf,
        hooks: EmbeddedJPEGSessionHooks = .init()
    ) {
        self.isEmbeddedTarget = isEmbeddedTarget
        self.isEnabled = isEnabled
        self.chunkBytes = chunkBytes
        self.dcSubjectStyle = dcSubjectStyle
        self.hooks = hooks
    }

    public func open(photoPath: String) async throws -> (any MetadataRewriteSession)? {
        guard isEnabled() else { return nil }
        guard MetadataTargetPolicy.isJPEG(photoPath) else { return nil }
        guard isEmbeddedTarget(photoPath) else { return nil }
        guard FileManager.default.fileExists(atPath: photoPath) else { return nil }
        // 已存在 .xmp：读取要叠加 sidecar 覆盖，快路径不合并 → 回旧路径。
        let sidecar = SidecarXMPProvider.resolveSidecarPath(photoPath)
        if FileManager.default.fileExists(atPath: sidecar) { return nil }
        return EmbeddedJPEGSession.open(
            photoPath: photoPath, chunkBytes: chunkBytes,
            dcSubjectStyle: dcSubjectStyle, hooks: hooks)
    }
}

/// 一个已经打开的内嵌目标（快照完成、尚未写盘）。
final class EmbeddedJPEGSession: MetadataRewriteSession, Sendable {
    /// 头部（SOI…SOS）字节上限：超过就不做快路径（旧路径没有这个限制，回退即可）。
    static let headerLimit: Int64 = 4 << 20

    let photoPath: String
    let fingerprintBefore: String
    let attributes: MetadataWriteAttributes
    let headerByteCount: Int
    /// dc:subject 写盘风格（leaf/path），与 sidecar 共用同一设置。
    let dcSubjectStyle: KeywordDCSubjectStyle
    /// lr:hierarchicalSubject（W3 关键词域读取层级；协议面不暴露）。
    let hierarchicalKeywords: [String]

    /// 快照内容（构造后不可变，故 @unchecked Sendable 的并发依据是"除 state 外全 let"）。
    private let segments: [JPEGSegment]
    /// 原始头部字节（备份用；≤4MiB）。
    private let header: Data
    private let scanOffset: Int64
    /// 写前扫描段 SHA-256（写后必须相等）。
    private let scanDigest: String
    private let fileSize: Int64
    private let mtimeRounded: Int64
    private let chunkBytes: Int
    private let hooks: EmbeddedJPEGSessionHooks
    private let state = OSAllocatedUnfairLock<State>(initialState: .open)
    /// 本次会话是否真的新建了 header 备份（复用旧备份时 abort 不能删它）。
    private let createdBackup = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// commit 是否**真的成功**（P1-6）。closed 状态本身不足以区分"已提交"与
    /// "提交失败"：成功之后备份是用户唯一撤销点，失败之后它只是本次会话的垃圾。
    private let committed = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// 会话状态。closed 也要记住备份路径：commit 之后仍要把 headerBackupPath
    /// 带进 report（否则交付行拿不到"首次写前的头备份"）。
    private enum State: Sendable {
        case open
        case backup(String)
        case closed(String)

        var backupPath: String {
            switch self {
            case .open: ""
            case .backup(let path), .closed(let path): path
            }
        }

        var isClosed: Bool {
            if case .closed = self { return true }
            return false
        }
    }

    private init(
        photoPath: String,
        fingerprintBefore: String,
        attributes: MetadataWriteAttributes,
        header: Data,
        segments: [JPEGSegment],
        scanOffset: Int64,
        scanDigest: String,
        fileSize: Int64,
        mtimeRounded: Int64,
        chunkBytes: Int,
        dcSubjectStyle: KeywordDCSubjectStyle,
        hooks: EmbeddedJPEGSessionHooks,
        hierarchicalKeywords: [String]
    ) {
        self.photoPath = photoPath
        self.fingerprintBefore = fingerprintBefore
        self.attributes = attributes
        self.header = header
        self.segments = segments
        self.scanOffset = scanOffset
        self.scanDigest = scanDigest
        self.fileSize = fileSize
        self.mtimeRounded = mtimeRounded
        self.chunkBytes = max(4096, chunkBytes)
        self.dcSubjectStyle = dcSubjectStyle
        self.hooks = hooks
        self.hierarchicalKeywords = hierarchicalKeywords
        self.headerByteCount = Int(scanOffset)
    }

    // MARK: - 快照（一次顺序遍历）

    /// 打开并快照。返回 nil = 这个文件不该走快路径（非 JPEG/截断/头部过大/XMP 包坏），
    /// 由调用方回退旧路径：快路径的任何"不支持"都不得让原本能写成功的写回失败。
    static func open(
        photoPath: String,
        chunkBytes: Int,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf,
        hooks: EmbeddedJPEGSessionHooks
    ) -> EmbeddedJPEGSession? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: photoPath))
        } catch {
            GatherLogger.log(
                "embedded session open failed (path token=\(TSPath.basename(photoPath))): \(error)",
                level: .debug)
            return nil
        }
        defer { closeQuietly(handle) }
        guard let statBefore = fileStat(of: handle), statBefore.size > 0 else { return nil }

        let chunk = max(4096, chunkBytes)
        var scanner = JPEGSegmentScanner()
        var fullHasher = CryptoKit.SHA256()
        var scanHasher: CryptoKit.SHA256?
        var header = Data()
        var readBytes: Int64 = 0
        while true {
            let buffer: Data
            do {
                buffer = try handle.read(upToCount: chunk) ?? Data()
            } catch {
                GatherLogger.log(
                    "embedded session read failed (path token=\(TSPath.basename(photoPath))): \(error)",
                    level: .debug)
                return nil
            }
            if buffer.isEmpty { break }
            fullHasher.update(data: buffer)
            readBytes += Int64(buffer.count)
            hooks.onReadBytes?(buffer.count)
            if scanHasher != nil {
                scanHasher?.update(data: buffer)
                continue
            }
            header.append(buffer)
            do {
                if try scanner.feed(buffer) {
                    guard let offset = scanner.scanOffset, Int64(header.count) >= offset,
                          offset <= headerLimit else {
                        // 头部超过预算：不做快路径（旧路径没有这个上限，回退即可）。
                        return nil
                    }
                    // 头部只保留到 SOS 之前（chunk 里多读的扫描段字节交给 scanRemainder）。
                    header = header.prefix(Int(offset))
                    var hasher = CryptoKit.SHA256()
                    hasher.update(data: scanner.scanRemainder)
                    scanHasher = hasher
                } else if Int64(header.count) > headerLimit {
                    GatherLogger.log(
                        "embedded session skipped: header > 4MiB (path token=\(TSPath.basename(photoPath)))",
                        level: .debug)
                    return nil
                }
            } catch {
                GatherLogger.log(
                    "embedded session layout unsupported (path token=\(TSPath.basename(photoPath))): \(error)",
                    level: .debug)
                return nil
            }
        }
        // 读到 EOF 仍未到达 SOS / 读的字节数与 stat 不一致（读期间被改）→ 回退旧路径。
        guard let scanHasher, readBytes == statBefore.size else { return nil }
        let headerSegments = scanner.segments
        guard let reading = XMPPacketReader.read(
            xmpPacket: headerSegments.first(where: \.isXMP)?.xmpPacket,
            photoshopIRBPayloads: headerSegments.compactMap(\.photoshopIRB)
        ) else {
            // XMP 包不可解析：交给 ImageIO 旧路径（并留痕便于定位异常文件）。
            GatherLogger.log(
                "embedded session fallback: XMP packet unreadable (path token=\(TSPath.basename(photoPath)))",
                level: .debug)
            return nil
        }
        let mtimeRounded = Int64(statBefore.mtimeMs.rounded())
        return EmbeddedJPEGSession(
            photoPath: photoPath,
            fingerprintBefore: "\(statBefore.size):\(mtimeRounded):\(hex(fullHasher.finalize()))",
            attributes: reading.attributes,
            header: header,
            segments: headerSegments,
            scanOffset: Int64(header.count),
            scanDigest: hex(scanHasher.finalize()),
            fileSize: statBefore.size,
            mtimeRounded: mtimeRounded,
            chunkBytes: chunk,
            dcSubjectStyle: dcSubjectStyle,
            hooks: hooks,
            hierarchicalKeywords: reading.hierarchicalKeywords)
    }

    // MARK: - MetadataRewriteSession

    /// 头部备份（幂等）。与旧路径同一个命名前缀（交付层/恢复按前缀认种类）。
    func writeHeaderBackup() async throws -> String {
        let current = state.withLock { $0 }
        if case .backup(let path) = current { return path }
        if current.isClosed { throw EmbeddedSessionError.alreadyClosed }
        let path = photoPath + ".gather-header-" + UUID().uuidString.lowercased()
        do {
            // 原子写：中途失败只留临时文件，不会留下"SOI 开头但被截断"的坏备份
            // 被 restore 当成本次写入的还原点。
            try header.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw EmbeddedSessionError.backupFailed(String(describing: error))
        }
        createdBackup.withLock { $0 = true }
        state.withLock { if case .open = $0 { $0 = .backup(path) } }
        return path
    }

    func commit(_ attributes: MetadataWriteAttributes) async throws -> MetadataRewriteReport {
        // 关闭会话：成功/失败都不再接受第二次 commit（文件已被替换或已放弃）。
        // 注意这里先置 closed 再写盘：所以 closed 不等于"提交成功"，成功与否看
        // committed 标记（abort 的删除判据，P1-6）。
        let backupPath = try state.withLock { state -> String in
            if state.isClosed { throw EmbeddedSessionError.alreadyClosed }
            let path = state.backupPath
            state = .closed(path)
            return path
        }
        let report = try performCommit(attributes, headerBackupPath: backupPath)
        committed.withLock { $0 = true }
        return report
    }

    /// 放弃：不写盘就没有需要撤销的副作用；本次新建的 header 备份要删掉。
    ///
    /// 原实现只判 `state.isClosed`，而 commit 在写盘**之前**就把状态置成 .closed，
    /// 于是 commit 失败后的 abort 直接返回：本次新建的 .gather-header- 备份成了
    /// 孤儿（P1-6）。现在区分两种 closed：
    /// - closed 且 committed = 写盘已成功 → 备份是唯一撤销点，绝不删；
    /// - closed 但没提交（commit 抛错 / 从未 commit）→ 照删不误。
    func abort() async {
        let didCommit = committed.withLock { $0 }
        let backupPath = state.withLock { state -> String in
            if state.isClosed, didCommit { return "" }
            let path = state.backupPath
            state = .closed(path)
            return path
        }
        guard !backupPath.isEmpty, createdBackup.withLock({ $0 }) else { return }
        do {
            try FileManager.default.removeItem(atPath: backupPath)
        } catch {
            GatherLogger.log(
                "embedded header backup cleanup failed: \(error)", level: .debug)
            return
        }
        // 文件已删：状态里不能继续留着这个不存在的路径（commit 之后只剩诊断用途）。
        state.withLock { state in
            if case .closed = state { state = .closed("") }
        }
    }

    // MARK: - 提交（一次写 + 一次顺序遍历）

    private func performCommit(
        _ attributes: MetadataWriteAttributes, headerBackupPath: String
    ) throws -> MetadataRewriteReport {
        // 与旧路径同一个守卫：空属性不写盘（避免写出只有骨架的 XMP）。
        guard !attributes.isEmpty else {
            throw EmbeddedSessionError.verificationFailed("empty attributes")
        }
        let temporary = JPEGMetadataWriter.temporaryPath(for: photoPath)
        var installed = false
        defer {
            if !installed { JPEGMetadataWriter.removeTemporary(temporary) }
        }

        // 1) 新头部（与旧路径共用段编辑逻辑）
        let rebuilt = try JPEGMetadataWriter.rewriteHeader(
            segments: segments, attributes: attributes, target: photoPath,
            dcSubjectStyle: dcSubjectStyle)

        // 2) 临时文件：头部 + 流式拷贝扫描段（同时算输出 SHA 与扫描 SHA）
        let copy = try writeTemporary(
            header: rebuilt.header, scanOffset: scanOffset, to: temporary)

        // 3) 替换前校验（失败只删临时文件）
        try hooks.beforeVerification?()
        let writtenScanDigest = hex(copy.scanHasher.finalize())
        guard writtenScanDigest == scanDigest else {
            throw EmbeddedSessionError.externalConflict("scan bytes changed during copy")
        }
        try verifyTemporary(
            temporary, headerBytes: rebuilt.header.count, scanBytes: copy.scanBytes,
            attributes: attributes)
        guard let statNow = currentFileStat(), statNow.size == fileSize,
              Int64(statNow.mtimeMs.rounded()) == mtimeRounded else {
            throw EmbeddedSessionError.externalConflict("source changed before replace")
        }
        try hooks.beforeInstall?()

        // 4) 原子替换（保留权限/ACL/xattr）。校验全部前移，这里不存在回滚路径。
        do {
            try JPEGMetadataWriter.install(temporary: temporary, at: photoPath)
        } catch {
            throw EmbeddedSessionError.atomicWriteFailed(String(describing: error))
        }
        installed = true

        // 5) 写后指纹：size/mtime 取替换后的 stat，SHA 用第 2 步已算出的输出摘要（不重读）
        let bytesAfter = Int64(rebuilt.header.count) + copy.scanBytes
        let statAfter = currentFileStat()
        let fingerprintAfter: String
        if let statAfter {
            fingerprintAfter = "\(statAfter.size):\(Int64(statAfter.mtimeMs.rounded())):"
                + hex(copy.outputHasher.finalize())
        } else {
            // 替换已成功但 stat 失败：指纹留给调用方回退计算（不谎报大小）。
            fingerprintAfter = ""
        }
        return MetadataRewriteReport(
            bytesBefore: fileSize,
            bytesAfter: statAfter?.size ?? bytesAfter,
            fingerprintAfter: fingerprintAfter,
            scanDigest: scanDigest,
            touchedIIM: rebuilt.touchedIIM,
            headerBackupPath: headerBackupPath)
    }

    private struct CopyResult {
        var outputHasher: CryptoKit.SHA256
        var scanHasher: CryptoKit.SHA256
        var scanBytes: Int64
    }

    /// 写临时文件：头部一次写入，扫描段按块拷贝（源按块读，同时喂两个 hasher）。
    private func writeTemporary(
        header: Data, scanOffset: Int64, to path: String
    ) throws -> CopyResult {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw EmbeddedSessionError.atomicWriteFailed("cannot create temporary file")
        }
        let destination: FileHandle
        let source: FileHandle
        do {
            destination = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            source = try FileHandle(forReadingFrom: URL(fileURLWithPath: photoPath))
        } catch {
            throw EmbeddedSessionError.atomicWriteFailed(String(describing: error))
        }
        defer {
            closeQuietly(destination)
            closeQuietly(source)
        }
        var outputHasher = CryptoKit.SHA256()
        var scanHasher = CryptoKit.SHA256()
        outputHasher.update(data: header)
        var scanBytes: Int64 = 0
        do {
            try destination.write(contentsOf: header)
            try source.seek(toOffset: UInt64(scanOffset))
            while true {
                let buffer = try source.read(upToCount: chunkBytes) ?? Data()
                if buffer.isEmpty { break }
                try destination.write(contentsOf: buffer)
                outputHasher.update(data: buffer)
                scanHasher.update(data: buffer)
                scanBytes += Int64(buffer.count)
                hooks.onReadBytes?(buffer.count)
            }
            try destination.synchronize()
        } catch {
            throw EmbeddedSessionError.atomicWriteFailed(String(describing: error))
        }
        return CopyResult(outputHasher: outputHasher, scanHasher: scanHasher, scanBytes: scanBytes)
    }

    /// 替换前对**临时文件**做三重校验：size、头部回读解析、逐字段比对。
    /// 校验对象必须是落盘字节（不是内存里的那一份），否则"写坏的临时文件"会漏检。
    private func verifyTemporary(
        _ path: String, headerBytes: Int, scanBytes: Int64, attributes: MetadataWriteAttributes
    ) throws {
        guard let stat = tsStat(path), stat.size == Int64(headerBytes) + scanBytes else {
            throw EmbeddedSessionError.verificationFailed("temporary size mismatch")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw EmbeddedSessionError.verificationFailed(String(describing: error))
        }
        defer { closeQuietly(handle) }
        let writtenHeader: Data
        do {
            writtenHeader = try handle.read(upToCount: headerBytes) ?? Data()
        } catch {
            throw EmbeddedSessionError.verificationFailed(String(describing: error))
        }
        guard writtenHeader.count == headerBytes else {
            throw EmbeddedSessionError.verificationFailed("temporary header truncated")
        }
        var scanner = JPEGSegmentScanner()
        do {
            _ = try scanner.feed(writtenHeader)
        } catch {
            throw EmbeddedSessionError.verificationFailed("header reparse failed: \(error)")
        }
        guard scanner.scanOffset == nil else {
            throw EmbeddedSessionError.verificationFailed("header contains SOS marker")
        }
        guard let actual = XMPPacketReader.attributes(segments: scanner.segments) else {
            throw EmbeddedSessionError.verificationFailed("written XMP packet unreadable")
        }
        // 与旧路径同一份逐字段校验（rating/label/keywords/descriptive/triageSignal）。
        try SidecarXMPProvider.verify(
            xmpPath: photoPath, expected: attributes, actual: actual)
    }

    // MARK: - 文件系统助手

    /// fstat 打开的这个句柄（不是 path stat）：确认"正在读的文件"身份。
    private static func fileStat(of handle: FileHandle) -> (size: Int64, mtimeMs: Double)? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        #if canImport(Glibc)
        let mtimeMs = Double(info.st_mtim.tv_sec) * 1000 + Double(info.st_mtim.tv_nsec) / 1_000_000
        #else
        let mtimeMs = Double(info.st_mtimespec.tv_sec) * 1000
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        #endif
        return (Int64(info.st_size), mtimeMs)
    }

    /// 路径当前指向的文件的 size/mtime（替换前的"源文件未变"判定）。
    private func currentFileStat() -> (size: Int64, mtimeMs: Double)? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: photoPath))
        } catch {
            return nil
        }
        defer { closeQuietly(handle) }
        return Self.fileStat(of: handle)
    }
}

// MARK: - 文件内助手

private func hex(_ digest: CryptoKit.SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func closeQuietly(_ handle: FileHandle) {
    do {
        try handle.close()
    } catch {
        GatherLogger.log("embedded session close failed: \(error)", level: .debug)
    }
}

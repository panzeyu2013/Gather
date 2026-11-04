// desktop/native/gather-app/Sources/GatherHost/Embedded/JPEGMetadataWriter.swift
// JPEG 内嵌元数据写入器：XMP（APP1）+ IPTC-IIM（APP13/0x0404）双写，scan 逐字节不动。
//
// 写入序列（每一步失败都不得留下半成品）：
//   读文件 → 段表 → 补丁 XMP → 更新 IIM → 重建 → 头部备份 → 原子替换 → 双读校验
// 校验失败用原字节回滚（备份保留，交付层可重试/审计）。
//
// P1 下一波（plan §3.2.7）：段编辑逻辑抽成 `segmentEdits`，被两条路径共用——
//   - `rewritten(document:)`：纯数据重写（旧路径，语义逐字节不变）；
//   - `rewriteHeader(segments:)`：只重建头部（流式快路径，scan 由调用方分块拷贝）。
// 两者对"改哪几段、IIM 怎么合并"必须完全一致，否则快慢路径会写出不同的文件。
import Foundation
import GatherApplication
import GatherProtocol

struct EmbeddedMetadataWriteReport: Equatable, Sendable {
    let photoPath: String
    let headerBackupPath: String
    let bytesBefore: Int
    let bytesAfter: Int
    let scanDigest: String
    let touchedIIM: Bool
}

enum JPEGMetadataWriterError: Error, Equatable, CustomStringConvertible {
    case backupFailed(String)
    case atomicWriteFailed(String)
    case verificationFailed(String)

    var code: String {
        switch self {
        case .backupFailed: "EMBEDDED_BACKUP_FAILED"
        case .atomicWriteFailed: "EMBEDDED_ATOMIC_WRITE_FAILED"
        case .verificationFailed: "EMBEDDED_WRITE_VERIFICATION_FAILED"
        }
    }

    var description: String {
        switch self {
        case .backupFailed(let reason):
            "EMBEDDED_BACKUP_FAILED: " + reason
        case .atomicWriteFailed(let reason):
            "EMBEDDED_ATOMIC_WRITE_FAILED: " + reason
        case .verificationFailed(let reason):
            "EMBEDDED_WRITE_VERIFICATION_FAILED: " + reason
        }
    }
}

enum JPEGMetadataWriter {

    /// 段编辑结果（XMP 段指令 + APP13 指令 + 是否动过 IIM）。
    /// 两条写盘路径必须从这里取编辑指令，不得各写一份。
    struct SegmentEdits {
        let xmp: JPEGSegmentEdit
        let iptc: JPEGPhotoshopEdit
        let touchedIIM: Bool
    }

    /// 纯数据重写（不做 IO，便于单测与"写到临时文件再校验"的组合）。
    /// 返回新字节与是否动过 IIM。
    static func rewritten(
        data: Data,
        attributes: MetadataWriteAttributes,
        target: String,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf
    ) throws -> (data: Data, touchedIIM: Bool) {
        try rewritten(
            document: JPEGDocument(data: data), attributes: attributes, target: target,
            dcSubjectStyle: dcSubjectStyle)
    }

    /// 已解析文档的重写：写盘路径不必把整份文件解析两遍。
    static func rewritten(
        document: JPEGDocument,
        attributes: MetadataWriteAttributes,
        target: String,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf
    ) throws -> (data: Data, touchedIIM: Bool) {
        let edits = try segmentEdits(
            xmpPacket: document.xmpPacket,
            photoshopIRBPayloads: document.photoshopIRBPayloads,
            attributes: attributes,
            target: target,
            dcSubjectStyle: dcSubjectStyle)
        let rebuilt = try document.rebuilding(xmp: edits.xmp, iptc: edits.iptc)
        return (rebuilt, edits.touchedIIM)
    }

    /// 只重建头部（流式快路径）：输出 SOI…SOS 之前的字节，scan 由调用方分块拷贝。
    /// 与 `rewritten(document:)` 走同一份 `segmentEdits`，差别只在是否拼 scan。
    static func rewriteHeader(
        segments: [JPEGSegment],
        attributes: MetadataWriteAttributes,
        target: String,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf
    ) throws -> (header: Data, touchedIIM: Bool) {
        let edits = try segmentEdits(
            xmpPacket: segments.first(where: \.isXMP)?.xmpPacket,
            photoshopIRBPayloads: segments.compactMap(\.photoshopIRB),
            attributes: attributes,
            target: target,
            dcSubjectStyle: dcSubjectStyle)
        let header = try JPEGHeaderWriter.rebuild(
            segments: segments, xmp: edits.xmp, iptc: edits.iptc)
        return (header, edits.touchedIIM)
    }

    /// 段编辑：XMP 包补丁 + IIM 数据集三态合并。
    /// `xmpPacket` / `photoshopIRBPayloads` 的语义与 `JPEGDocument` 的同名属性一致
    /// （XMP 取首个段、APP13 取全部段）。
    static func segmentEdits(
        xmpPacket: Data?,
        photoshopIRBPayloads: [Data],
        attributes: MetadataWriteAttributes,
        target: String,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf
    ) throws -> SegmentEdits {
        let packet = try XMPPacketStore.patched(
            existing: xmpPacket, attributes: attributes, target: target,
            dcSubjectStyle: dcSubjectStyle)

        let iimUpdates = IPTCIIMMapping.updates(
            for: attributes.descriptive, keywords: attributes.keywords)
        var iptcEdit: JPEGPhotoshopEdit = .keep
        var touchedIIM = false
        if !iimUpdates.isEmpty {
            // 合并**全部** APP13 的资源：Photoshop 在资源区 >64KB 时会拆段，只解析首个
            // 会静默丢资源（缩略图 / 裁剪路径 / 大 IPTC）。任一段解析失败就整块不动：
            // 把"解析不了的 IIM"当成空表重写会删掉别人的 dataset。
            var resources: [PhotoshopIRB]? = []
            for payload in photoshopIRBPayloads {
                do {
                    resources?.append(contentsOf: try PhotoshopIRBList.parse(payload))
                } catch {
                    GatherLogger.log(
                        "embedded APP13 parse failed, keeping IRB untouched: \(error)",
                        level: .warn)
                    resources = nil
                    break
                }
            }
            if var merged = resources {
                // 多个 0x0404 IIM 只可能是外部工具的大 IPTC 拆分。读侧
                // （XMPPacketReader / ImageIO / Bridge）都只认其中一段；如果这里只改首段、
                // 保留其余段，会写出"Gather 看到新值、Bridge 看到旧值"的双真相。
                // 宁可显式拒绝，也不静默做部分更新。
                let iimCount = merged.filter { $0.resourceID == PhotoshopIRB.iptcNAA }.count
                guard iimCount <= 1 else {
                    throw EmbeddedJPEGError.layoutUnsupported(
                        "multiple IPTC IIM resources (\(iimCount)); refusing partial rewrite")
                }
                let iptcIndex = merged.firstIndex { $0.resourceID == PhotoshopIRB.iptcNAA }
                let existingIIM: IPTCIIM
                if let iptcIndex {
                    existingIIM = (try? IPTCIIM.parse(merged[iptcIndex].data)) ?? IPTCIIM()
                } else {
                    existingIIM = IPTCIIM()
                }
                let updated = try existingIIM.replacing(iimUpdates)
                if let iptcIndex {
                    if updated.isEmpty {
                        merged.remove(at: iptcIndex)
                    } else {
                        merged[iptcIndex] = PhotoshopIRB(
                            resourceID: PhotoshopIRB.iptcNAA,
                            name: merged[iptcIndex].name,
                            data: try updated.encoded())
                    }
                } else if !updated.isEmpty {
                    merged.append(PhotoshopIRB(
                        resourceID: PhotoshopIRB.iptcNAA, name: Data(), data: try updated.encoded()))
                }
                iptcEdit = merged.isEmpty ? .remove : .replace(merged)
                touchedIIM = true
            }
        }
        return SegmentEdits(xmp: .replace(packet), iptc: iptcEdit, touchedIIM: touchedIIM)
    }

    /// 写盘：原子替换 + 写后双读校验；校验失败回滚原字节。
    static func write(
        photoPath: String,
        attributes: MetadataWriteAttributes,
        headerBackupPath: String? = nil,
        dcSubjectStyle: KeywordDCSubjectStyle = .leaf
    ) async throws -> EmbeddedMetadataWriteReport {
        guard !attributes.isEmpty else {
            throw JPEGMetadataWriterError.verificationFailed("empty attributes")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: photoPath))
        let document = try JPEGDocument(data: original)
        let rewritten = try rewritten(
            document: document, attributes: attributes, target: photoPath,
            dcSubjectStyle: dcSubjectStyle)

        // 头部备份：只需 SOI…SOS 之前的字节；restore = 旧头部 + 当前 scan。
        let headerLength = original.count - document.scan.count
        let header = original.prefix(headerLength)
        let backupPath = headerBackupPath
            ?? (photoPath + ".gather-header-" + UUID().uuidString.lowercased())
        do {
            // 原子写：磁盘满/中断只留临时文件，不会留下"SOI 开头但被截断"的坏备份
            // 被 restore 当成本次写入的还原点。
            try Data(header).write(to: URL(fileURLWithPath: backupPath), options: .atomic)
        } catch {
            throw JPEGMetadataWriterError.backupFailed(String(describing: error))
        }

        try atomicReplace(path: photoPath, data: rewritten.data)

        do {
            let check = try JPEGDocument(data: Data(contentsOf: URL(fileURLWithPath: photoPath)))
            guard check.scanDigest == document.scanDigest else {
                throw JPEGMetadataWriterError.verificationFailed("scan bytes changed")
            }
            let parsed = try await ImageIOExifProvider().parse(filePath: photoPath, isJpeg: true)
            var actual = parsed.flatMap(MetadataService.embeddedAttributesFromParse)
                ?? MetadataWriteAttributes()
            // gather:Triage 是私有命名空间，embeddedAttributesFromParse 不解析它；
            // 直接从写后的 XMP 包体校验，避免"建议写回必失败并回滚"。
            if let signal = attributes.triageSignal, !signal.isEmpty {
                // 只在写后的 XMP 包体里找私有命名空间值：不再把整份 JPEG（可能几十 MB）
                // 解成 String，避免一次写盘多出一份文件大小的峰值内存。
                let packetText = check.xmpPacket.map { String(decoding: $0, as: UTF8.self) } ?? ""
                guard packetText.contains(signal) else {
                    throw JPEGMetadataWriterError.verificationFailed("triage signal not written")
                }
                actual.triageSignal = signal
            }
            try SidecarXMPProvider.verify(
                xmpPath: photoPath, expected: attributes, actual: actual)
        } catch {
            // 回滚：原字节写回（备份保留，交给交付层清理/审计）。
            do {
                try atomicReplace(path: photoPath, data: original)
            } catch {
                GatherLogger.log(
                    "embedded rollback failed (path token=\(TSPath.basename(photoPath))): \(error)",
                    level: .error)
            }
            if let typed = error as? JPEGMetadataWriterError { throw typed }
            throw JPEGMetadataWriterError.verificationFailed(String(describing: error))
        }

        return EmbeddedMetadataWriteReport(
            photoPath: photoPath,
            headerBackupPath: backupPath,
            bytesBefore: original.count,
            bytesAfter: rewritten.data.count,
            scanDigest: document.scanDigest,
            touchedIIM: rewritten.touchedIIM
        )
    }

    /// 用头部备份还原（scan 取当前文件的，保证只回滚元数据）。
    static func restore(photoPath: String, headerBackupPath: String) throws {
        guard FileManager.default.fileExists(atPath: headerBackupPath) else {
            throw JPEGMetadataWriterError.backupFailed("missing " + headerBackupPath)
        }
        let header = try Data(contentsOf: URL(fileURLWithPath: headerBackupPath))
        // 头部备份必须是 JPEG SOI 开头：错派/损坏的备份不能拼进原片。
        guard header.count >= 2, header[header.startIndex] == 0xFF,
              header[header.startIndex + 1] == 0xD8 else {
            throw JPEGMetadataWriterError.verificationFailed("backup is not a JPEG header")
        }
        let current = try Data(contentsOf: URL(fileURLWithPath: photoPath))
        let document = try JPEGDocument(data: current)
        var restored = header
        restored.append(document.scan)
        // 拼装结果必须仍是结构完整的 JPEG：备份被截断/写坏时解析会失败，
        // 此时绝不覆盖原片（让调用方按「恢复失败」处理，交付行保持 failed 可审计）。
        let candidate = try JPEGDocument(data: restored)
        guard candidate.scan.count == document.scan.count else {
            throw JPEGMetadataWriterError.verificationFailed("restore 改变了 scan 长度")
        }
        try atomicReplace(path: photoPath, data: restored)
    }

    // MARK: - 原子写

    /// 清理临时文件：文件不存在视为成功；其它失败只记日志（不覆盖用户数据）。
    static func removeTemporary(_ path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            return
        } catch {
            GatherLogger.log("embedded temp cleanup failed: \(error)", level: .warn)
        }
    }

    static func atomicReplace(path: String, data: Data) throws {
        let temporary = temporaryPath(for: path)
        do {
            try data.write(to: URL(fileURLWithPath: temporary))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary))
            try handle.synchronize()
            try handle.close()
        } catch {
            removeTemporary(temporary)
            throw JPEGMetadataWriterError.atomicWriteFailed(String(describing: error))
        }
        do {
            try install(temporary: temporary, at: path)
        } catch {
            removeTemporary(temporary)
            throw JPEGMetadataWriterError.atomicWriteFailed(String(describing: error))
        }
    }

    /// 同目录临时文件名：与目标同卷才能原子 rename（跨卷会退化成拷贝+删除）。
    static func temporaryPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (directory as NSString).appendingPathComponent(
            "." + name + ".gather-embedded-" + UUID().uuidString.lowercased())
    }

    /// 把"已经写完并 fsync 过"的临时文件装到目标路径。
    /// 不加 .usingNewMetadataOnly：保留原文件的权限/ACL/扩展属性，只替换内容
    /// （只读介质/受控目录下这一点很关键）。
    static func install(temporary: String, at path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: temporary),
                backupItemName: nil,
                options: [])
        } else {
            try FileManager.default.moveItem(atPath: temporary, toPath: path)
        }
    }
}

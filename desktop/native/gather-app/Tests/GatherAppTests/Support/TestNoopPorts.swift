// desktop/native/gather-app/Tests/GatherAppTests/Support/TestNoopPorts.swift
// app 测试共享夹具：空实现端口（task-36 收口）。
//
// 只用于「装配真实服务但该路径不触盘/不落库」的用例。原先 AppRuntimeTests /
// WorkflowRegistryTests 逐字复制了两个 noop，MetadataEditorTests 又有一份
// 参数化不足的副本；统一为可注入形态：
//   - NoopXMPProvider：读侧快照 + fileExists 可注入（双源冲突用例需要"存在"）；
//   - NoopMetadataMutationPort：xmpPath 形态可注入（接缝断言依赖返回值形状）。
// 有实际记录/建模行为的 XMP/mutation 替身（FaceSim/GeoDate/MetadataTest 等）
// 语义不同，保留在原文件。
import Foundation
import GatherProtocol
import GatherDelivery

/// XMPProvider 的空实现：不读不写文件系统。
struct NoopXMPProvider: XMPProvider {
    /// 读侧快照（nil = 空属性）；readKeywords 取其中的 keywords。
    var attributes: MetadataWriteAttributes?
    /// fileExists 的返回值（默认 false；只读 sidecar 用例注入 true）。
    var existingFiles = false

    init(attributes: MetadataWriteAttributes? = nil, existingFiles: Bool = false) {
        self.attributes = attributes
        self.existingFiles = existingFiles
    }

    func readKeywords(photoPath: String) async throws -> [String] {
        attributes?.keywords ?? []
    }

    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        attributes ?? MetadataWriteAttributes()
    }

    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws {}

    func backup(photoPath: String) async throws -> String { "" }

    func restore(photoPath: String, backupPath: String) async throws {}

    func fileExists(_ path: String) -> Bool { existingFiles }

    func removeFile(_ path: String) async throws {}
}

/// MetadataMutationPort 的空实现：不落库、不写盘，只回最小可用结果。
struct NoopMetadataMutationPort: MetadataMutationPort {
    /// 结果里 xmpPath 的后缀：nil = 空串；非 nil = photoId + 后缀。
    var xmpPathSuffix: String?

    init(xmpPathSuffix: String? = nil) {
        self.xmpPathSuffix = xmpPathSuffix
    }

    func queuePhotoValues(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) throws -> MetadataMutationResult {
        MetadataMutationResult(
            photoId: photoId, xmpPath: xmpPathSuffix.map { photoId + $0 } ?? "",
            dirtyFields: [], revision: 1, status: "pending")
    }
}

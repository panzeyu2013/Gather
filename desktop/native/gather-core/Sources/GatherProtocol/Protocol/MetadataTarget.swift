// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataTarget.swift
// 元数据写目标：一张照片的元数据落在哪个物理文件里。
//
// 规则（MetadataTargetPolicy，纯函数、可单测）：
// - 非 JPEG（RAW/HEIC/TIFF…）→ 侧车（v1 只做 JPEG 内嵌）；
// - 盘上已有同名 .xmp → 侧车（RAW+JPEG 对与外部工具惯例；两个真相源必须避免）；
// - 其余按设置：sidecar=侧车；auto/embedded=内嵌。
import Foundation

public enum MetadataTargetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sidecar
    case embedded
}

public struct MetadataTarget: Equatable, Sendable {
    public var photoPath: String
    public var kind: MetadataTargetKind
    /// 真正的写目标：侧车 = <photo>.xmp；内嵌 = 照片自身。
    public var writePath: String

    public init(photoPath: String, kind: MetadataTargetKind, writePath: String) {
        self.photoPath = photoPath
        self.kind = kind
        self.writePath = writePath
    }
}

public enum MetadataTargetPolicy {
    /// - mode: 设置值（auto / sidecar / embedded），未知值按 sidecar 处理（保守）。
    public static func resolve(
        photoPath: String,
        mode: String,
        sidecarExists: Bool,
        isJPEG: Bool
    ) -> MetadataTargetKind {
        guard isJPEG else { return .sidecar }
        if sidecarExists { return .sidecar }
        switch mode.lowercased() {
        case "embedded", "auto":
            return .embedded
        default:
            return .sidecar
        }
    }

    public static func isJPEG(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }
}

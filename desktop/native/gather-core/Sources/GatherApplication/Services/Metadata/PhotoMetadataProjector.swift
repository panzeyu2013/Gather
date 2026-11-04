// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/PhotoMetadataProjector.swift
// 单张照片的只读元数据投影（#6 S2：从 MetadataService 切出的第三刀）。
//
// 硬约束（原文保留在调用处注释里）：**只读缓存投影，不触发磁盘解析**——
// 面板翻页不得产生 N 次 IO。缓存行缺失时返回空快照与空描述性元数据，
// 而不是抛错（「尚未扫描」是正常态）。
//
// 唯一会碰文件系统的是 `xmp.fileExists(xmpPath)`（只判断存在性，不解析）。
import Foundation
import GatherProtocol
import GatherPersistence

public struct PhotoMetadataProjector: Sendable {
    private let xmp: any XMPProvider
    private let assetResolver: PhotoAssetResolver?
    /// 写目标解析（内嵌模式下写目标就是照片本身；nil = 恒按 sidecar 展示）。
    private let writeTarget: (@Sendable (String) -> MetadataTarget)?

    public init(
        xmp: any XMPProvider,
        assetResolver: PhotoAssetResolver?,
        writeTarget: (@Sendable (String) -> MetadataTarget)?
    ) {
        self.xmp = xmp
        self.assetResolver = assetResolver
        self.writeTarget = writeTarget
    }

    public func project(
        _ lookup: MetadataPhotoLookup,
        row: MetadataCacheRow?
    ) -> PhotoMetadataDetail {
        // asset_read_mode=asset 时写盘/预览都必须用解析后的资产路径；photos.filepath
        // 可能还是旧路径（写回执行器同样经 resolver），否则会读错 sidecar。
        let resolved = try? assetResolver?.resolve(
            sessionId: lookup.sessionId, photoId: lookup.id)
        let filepath = resolved?.filepath ?? lookup.filepath
        let filename = (filepath as NSString).lastPathComponent
        // 写目标优先用注入的解析器：内嵌模式下「写目标」就是照片本身，
        // 面板若仍显示 sidecar 路径，用户会误判写回失败。
        let target = writeTarget?(filepath)
        let xmpPath = target?.writePath ?? resolved?.xmpPath ?? TSPath.xmpSidecarPath(filepath)
        let exif = PhotoExifSnapshot(
            dateTaken: row?.dateTaken,
            cameraMake: row?.cameraMake,
            cameraModel: row?.cameraModel,
            lensModel: row?.lensModel,
            focalLength: row?.focalLength,
            fNumber: row?.fNumber,
            exposureTime: row?.exposureTime,
            iso: row?.iso.map { Int($0) },
            gpsLatitude: row?.gpsLatitude,
            gpsLongitude: row?.gpsLongitude,
            width: row?.width.map { Int($0) },
            height: row?.height.map { Int($0) },
            fileSize: row?.fileSize.map { Int($0) },
            fileMtime: row?.fileMtime,
            rating: Int(row?.rating ?? 0),
            label: row?.label,
            keywords: row?.keywords ?? []
        )
        return PhotoMetadataDetail(
            photoId: lookup.id,
            sessionId: lookup.sessionId,
            filepath: filepath,
            filename: filename,
            xmpPath: xmpPath,
            hasXMP: xmp.fileExists(xmpPath),
            exif: exif,
            descriptive: row?.descriptive ?? DescriptiveMetadata(),
            cachedAt: row?.cachedAt ?? "",
            updatedAt: row?.updatedAt ?? ""
        )
    }
}

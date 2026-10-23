#if DEBUG
import Foundation
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Export.swift
// Cut 4 / 4c-1 Preview 固定样例的纯移动拆分（导出预览）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

extension PreviewData {
    // MARK: 导出（Export）

    static let exportPreview: ExportPreview = {
        let files = (1...8).map { index in
            let path = galleryPaths[index - 1]
            return ExportPreviewFile(
                photoId: "preview-export-\(index)",
                filename: (path as NSString).lastPathComponent,
                fileSize: 24_000_000 + index * 512_000,
                outputName: String(format: "KYOTO_%04d.NEF", index),
                format: "original",
                includesXmp: index <= 2,
                issue: index == 6 ? "EXPORT_SOURCE_MISSING" : nil,
                isSizeEstimate: false,
                willSkip: false
            )
        }
        return ExportPreview(
            totalFiles: files.count,
            totalSizeBytes: 8_400_000_000,
            freeSpaceBytes: 1_200_000_000,
            files: files,
            photoCount: 8,
            sidecarCount: 2,
            physicalFileCount: 10,
            issueCount: 1
        )
    }()
}
#endif

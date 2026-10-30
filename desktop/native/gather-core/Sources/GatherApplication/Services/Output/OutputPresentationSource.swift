// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputPresentationSource.swift
// P1 下一波：交付展示元数据的取数端口。
//
// 为什么是端口：OutputService 在单测里不该连库（既有 OutputServiceTests 用真 DB 但
// 不关心元数据），而且"一次 JOIN"的实现要落在 Persistence 层（仓库层唯一写 SQL 的
// 地方）。端口让编排层只依赖协议：
//   - 生产：DatabaseOutputPresentationSource ← OutputPresentationRepo（一条 JOIN）
//   - 未接线/测试：EmptyOutputPresentationSource（全部降级为默认值）
//
// 约定：
// - 返回项的 **filename/filePath 一律为空**：交付成品名由 OutputService 按"真正写出
//   的文件"填（命名模板、唯一化重命名后的名字才是客户看到的名字）；
// - 顺序与入参 photoIds 一致；缺行降级为默认值并计入 metadataMissing，绝不抛错。

import Foundation
import GatherProtocol
import GatherPersistence

/// 一批照片的展示元数据快照。
public struct OutputPresentationSnapshot: Equatable, Sendable {
    /// 顺序与入参一致；缺行项的 filename/filePath 为空，其余字段取默认值。
    public var items: [DeliveryPresentationItem]
    /// 没有 photo_metadata_cache 行的照片数（诊断/首屏提示用，不影响导出）。
    public var metadataMissing: Int

    public init(items: [DeliveryPresentationItem] = [], metadataMissing: Int = 0) {
        self.items = items
        self.metadataMissing = metadataMissing
    }
}

public protocol OutputPresentationSource: Sendable {
    func presentations(sessionId: String, photoIds: [String]) throws -> OutputPresentationSnapshot
}

/// 未接线/测试用：全部降级为空元数据（输出与升级前一致）。
public struct EmptyOutputPresentationSource: OutputPresentationSource {
    public init() {}

    public func presentations(
        sessionId: String, photoIds: [String]
    ) throws -> OutputPresentationSnapshot {
        OutputPresentationSnapshot(
            items: photoIds.map { DeliveryPresentationItem(photoId: $0, filename: "") },
            metadataMissing: photoIds.count)
    }
}

/// 生产实现：把仓库行映射成展示模型（Application 层不写 SQL）。
public struct DatabaseOutputPresentationSource: OutputPresentationSource {
    private let repo: OutputPresentationRepo

    public init(repo: OutputPresentationRepo) {
        self.repo = repo
    }

    public func presentations(
        sessionId: String, photoIds: [String]
    ) throws -> OutputPresentationSnapshot {
        guard !photoIds.isEmpty else { return OutputPresentationSnapshot() }
        let rows = try repo.presentations(sessionId: sessionId, photoIds: photoIds)
        var byId: [String: OutputPresentationRow] = [:]
        byId.reserveCapacity(rows.count)
        for row in rows { byId[row.photoId] = row }
        var missing = 0
        var items: [DeliveryPresentationItem] = []
        items.reserveCapacity(photoIds.count)
        for photoId in photoIds {
            guard let row = byId[photoId] else {
                missing += 1
                items.append(DeliveryPresentationItem(photoId: photoId, filename: ""))
                continue
            }
            if !row.hasMetadata { missing += 1 }
            items.append(DeliveryPresentationItem(
                photoId: row.photoId,
                filename: "",
                title: row.title,
                caption: row.caption,
                rating: row.rating,
                label: row.label,
                pick: row.pickState,
                keywords: row.keywords,
                triageVerdict: row.triage,
                captureTime: row.captureTime,
                pixelWidth: row.pixelWidth,
                pixelHeight: row.pixelHeight))
        }
        return OutputPresentationSnapshot(items: items, metadataMissing: missing)
    }
}

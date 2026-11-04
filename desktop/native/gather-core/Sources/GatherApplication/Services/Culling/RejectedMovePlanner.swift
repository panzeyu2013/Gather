// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/RejectedMovePlanner.swift
// 淘汰移出的**纯规划**（#2 S3 的可落部分）。
//
// 为什么单独抽：整段 moveRejected 需要 XMPFileLock 的 @Sendable 闭包，而它的依赖
// （any PhotoRepository 等）不是 Sendable，整段下沉会吃掉 @unchecked 预算（当时 60/60
// 已满）。这里先把「不需要锁、不需要写盘」的决策部分抽成纯函数：
// 资产展开、skipped 归因、sharesSidecar 判定、目标目录安全校验。
//
// 收益：这段逻辑第一次能在 core 侧被单测（不需要 DB、不需要真实文件、不需要 app target）。
import Foundation
import GatherProtocol

public enum RejectedMovePlanner {
    /// 规划输入：调用方从仓储读出的行，压成最小快照（不泄漏 PhotoProjectionRow）。
    public struct Candidate: Sendable, Equatable {
        public let photoId: String
        public let filepath: String
        public let assetId: String?
        /// 非 nil = 已移出工作区（文件在 _rejects）。
        public let isArchived: Bool

        public init(photoId: String, filepath: String, assetId: String?, isArchived: Bool) {
            self.photoId = photoId
            self.filepath = filepath
            self.assetId = assetId
            self.isArchived = isArchived
        }
    }

    public struct Plan: Sendable, Equatable {
        public let items: [RejectedMoveItem]
        public let skipped: [CullingMoveRejectedSkip]
        /// 最终落点目录（已拼上 `_rejects`）。
        public let destination: String

        public init(items: [RejectedMoveItem], skipped: [CullingMoveRejectedSkip], destination: String) {
            self.items = items
            self.skipped = skipped
            self.destination = destination
        }
    }

    /// 纯规划：不读库、不碰文件系统（只用 URL 归一化做前缀校验）。
    ///
    /// 语义要点（逐步搬自 LiveCullingAPI.moveRejected）：
    /// - **按资产展开**：挑片决策是资产级，只移代表行会把另一半变体留在工作区；
    /// - **按张过滤**：混进保留件/已移出件时返回 skipped，其余照常移出；
    /// - **sharesSidecar 只按"实际会移动"的行算**：资产展开会带上未淘汰的兄弟，
    ///   把它们算作 moving 会让共享 .xmp 被从留下的兄弟身边搬走（P0/A1 已修过一次）。
    public static func plan(
        requestedIds: [String],
        candidates: [Candidate],
        rejectedIds: Set<String>,
        sessionSourcePath: String?,
        explicitDestinationRoot: String?
    ) throws -> Plan {
        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.photoId, $0) })
        var skipped: [CullingMoveRejectedSkip] = []
        var skippedIds = Set<String>()
        func skip(_ photoId: String, _ reason: String) {
            guard skippedIds.insert(photoId).inserted else { return }
            skipped.append(CullingMoveRejectedSkip(photoId: photoId, reason: reason))
        }

        var requested: [Candidate] = []
        for photoId in requestedIds {
            if let row = byId[photoId] { requested.append(row) } else { skip(photoId, "not_in_session") }
        }

        // 资产展开：保持"请求顺序 → 资产内导入序"的确定性。
        var rowsByAsset: [String: [Candidate]] = [:]
        for row in candidates {
            guard let assetId = row.assetId, !assetId.isEmpty else { continue }
            rowsByAsset[assetId, default: []].append(row)
        }
        var targetIds = Set<String>()
        var orderedIds: [String] = []
        func addTarget(_ photoId: String) {
            if targetIds.insert(photoId).inserted { orderedIds.append(photoId) }
        }
        for row in requested {
            if let assetId = row.assetId, !assetId.isEmpty {
                for variant in rowsByAsset[assetId] ?? [] { addTarget(variant.photoId) }
            } else {
                addTarget(row.photoId)
            }
        }

        var visibleByXmp: [String: [String]] = [:]
        for row in candidates where !row.isArchived {
            let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
            visibleByXmp[key, default: []].append(row.photoId)
        }

        var movingRows: [Candidate] = []
        for photoId in orderedIds {
            guard let row = byId[photoId] else { continue }
            if row.isArchived { skip(photoId, "already_archived"); continue }
            guard rejectedIds.contains(photoId) else { skip(photoId, "not_rejected"); continue }
            movingRows.append(row)
        }
        let movingIds = Set(movingRows.map(\.photoId))
        var items: [RejectedMoveItem] = []
        for row in movingRows {
            let key = TSPath.normalize(TSPath.xmpSidecarPath(row.filepath))
            let siblingsRemain = (visibleByXmp[key] ?? []).contains { !movingIds.contains($0) }
            items.append(RejectedMoveItem(
                photoId: row.photoId, filepath: row.filepath, sharesSidecar: siblingsRemain))
        }

        let root: String
        if let explicit = explicitDestinationRoot {
            // 显式目标只接受会话根目录下的路径：防止把照片搬到任意目录。
            let base = URL(fileURLWithPath: sessionSourcePath ?? "")
                .resolvingSymlinksInPath().path
            let target = URL(fileURLWithPath: explicit).resolvingSymlinksInPath().path
            guard !base.isEmpty, target == base || target.hasPrefix(base + "/") else {
                throw GatherError.invalidParameter(
                    field: "destinationRoot", reason: "must be inside the session source path")
            }
            root = explicit
        } else if let sourcePath = sessionSourcePath, !sourcePath.isEmpty {
            root = sourcePath
        } else {
            root = requested.first.map { ($0.filepath as NSString).deletingLastPathComponent } ?? ""
        }
        return Plan(
            items: items,
            skipped: skipped,
            destination: (root as NSString).appendingPathComponent(RejectedMover.folderName))
    }
}

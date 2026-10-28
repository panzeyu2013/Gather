// desktop/native/gather-core/Sources/GatherApplication/Services/FileOps/RejectedMover.swift
// P1 / D：把淘汰照片移出工作目录（默认 <sessionRoot>/_rejects）。
//
// 安全边界：
// - 只移动、不删除（交付前要可恢复；删文件不可撤销）；
// - 逐张独立执行，失败不中断整批；
// - 移动成功后立刻改写 photos.filepath 并写 archived_at（同一事务由 relocate 闭包负责）。
//
// P0 / A1（2026-10-28）：
// - 同一侧车被多个变体共享（RAW+JPEG 同 stem）：只要还有兄弟留在工作区，侧车与
//   <xmp>.gather-backup-* 必须**复制**过去，绝不能整份搬走——否则留下的文件失去
//   同名 .xmp。全部移出时才移动一次。
// - 回滚要区分 copy / move：复制出来的目标删掉即可，移动过的搬回原路径。
import Foundation
import GatherProtocol
import GatherPersistence

public struct RejectedMoveFailure: Equatable, Sendable {
    public var photoId: String
    public var message: String
    public init(photoId: String, message: String) {
        self.photoId = photoId
        self.message = message
    }
}

public struct RejectedMoveResult: Equatable, Sendable {
    public var moved: [String]
    public var newPaths: [String]
    public var failed: [RejectedMoveFailure]
    public init(moved: [String], newPaths: [String], failed: [RejectedMoveFailure]) {
        self.moved = moved
        self.newPaths = newPaths
        self.failed = failed
    }
}

/// 单张移出输入。sharesSidecar 由调用方按"同 stem 是否还有未移出的兄弟"计算。
public struct RejectedMoveItem: Equatable, Sendable {
    public var photoId: String
    public var filepath: String
    public var sharesSidecar: Bool

    public init(photoId: String, filepath: String, sharesSidecar: Bool) {
        self.photoId = photoId
        self.filepath = filepath
        self.sharesSidecar = sharesSidecar
    }
}

public final class RejectedMover: @unchecked Sendable {
    public static let folderName = "_rejects"
    private let photoRepo: any PhotoRepository
    private let fileManager: FileManager
    /// 路径迁移（photos.filepath + archived_at + deliveries/intents + keyword origins +
    /// sidecar bindings + asset_files）由宿主在**一个事务**内完成；nil = 仅改 filepath
    /// （测试/未接线场景，此时不写 archived_at）。
    /// 参数：photoId, oldPath, newPath, sharesSidecar。
    private let relocate: ((String, String, String, Bool) throws -> Void)?

    public init(
        photoRepo: any PhotoRepository,
        fileManager: FileManager = .default,
        relocate: ((String, String, String, Bool) throws -> Void)? = nil
    ) {
        self.photoRepo = photoRepo
        self.fileManager = fileManager
        self.relocate = relocate
    }

    /// 文件系统副作用（回滚按 isCopy 逆操作）。
    private struct FileAction {
        let source: String
        let target: String
        let isCopy: Bool
    }

    /// photos: 调用方保证这批照片已确认淘汰、且已按资产展开。
    /// 备份文件搬迁失败（目标已存在等）：整张移出按失败回滚，绝不覆盖既有备份。
    public enum MoveError: Error, Equatable, CustomStringConvertible {
        case backupConflict(String)
        public var description: String {
            switch self {
            case .backupConflict(let path):
                return "备份目标已存在，拒绝覆盖：\(path)"
            }
        }
    }

    /// 把旧 xmp 的 <xmp>.gather-backup-* 搬到新 xmp 旁边并改成新名前缀。
    ///
    /// sharesSidecar = true 时**不搬也不复制**：旧 .xmp 仍属留下的兄弟，备份必须
    /// 留在它的交付生命周期里（cleanup/finalize 按旧 xmp 找备份）。复制到 _rejects
    /// 只会产生没有任何 deliveries 引用的孤儿文件。
    private func moveSidecarBackups(
        oldPhotoPath: String,
        newPhotoPath: String,
        sharesSidecar: Bool
    ) throws -> [FileAction] {
        if sharesSidecar { return [] }
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        let oldDir = (oldXmp as NSString).deletingLastPathComponent
        let newDir = (newXmp as NSString).deletingLastPathComponent
        let newBase = (newXmp as NSString).lastPathComponent
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: oldDir)
        } catch {
            // 目录存在却读不到 = 无法确认备份是否已搬：fail-closed（否则 DB 会指向
            // 一个根本没搬走的备份路径）。目录本身不存在时上游搬照片就会先失败。
            if fileManager.fileExists(atPath: oldDir) { throw error }
            return []
        }
        var actions: [FileAction] = []
        for entry in entries.sorted() {
            // 大小写/Unicode 不敏感（盘上可能是 IMG_1.XMP.gather-backup-*）。
            guard let suffix = XMPBackupNaming.suffix(ofBackupFile: entry, forXMPPath: oldXmp)
            else { continue }
            let source = (oldDir as NSString).appendingPathComponent(entry)
            let target = (newDir as NSString).appendingPathComponent(
                XMPBackupNaming.make(xmpPath: newBase, suffix: suffix))
            // 同目录同名的"搬到自己"：跳过，否则 moveItem 会误判冲突让整张失败。
            if (source as NSString).standardizingPath == (target as NSString).standardizingPath {
                continue
            }
            guard !fileManager.fileExists(atPath: target) else {
                throw MoveError.backupConflict(target)
            }
            try fileManager.moveItem(atPath: source, toPath: target)
            actions.append(FileAction(source: source, target: target, isCopy: false))
        }
        return actions
    }

    public func move(items: [RejectedMoveItem], destinationRoot: String) -> RejectedMoveResult {
        var moved: [String] = []
        var newPaths: [String] = []
        var failed: [RejectedMoveFailure] = []
        for item in items {
            var actions: [FileAction] = []
            do {
                try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
                let name = (item.filepath as NSString).lastPathComponent
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                let sidecar = TSPath.xmpSidecarPath(item.filepath)
                let hasSidecar = fileManager.fileExists(atPath: sidecar)
                // 同名冲突：加序号；照片与侧车必须同时可用，绝不覆盖也绝不让
                // 侧车撞名导致照片已移走、元数据留在原地。
                var target = (destinationRoot as NSString).appendingPathComponent(name)
                var index = 2
                while fileManager.fileExists(atPath: target)
                    || (hasSidecar && fileManager.fileExists(
                        atPath: (target as NSString).deletingPathExtension + ".xmp")) {
                    target = (destinationRoot as NSString)
                        .appendingPathComponent(base + "-" + String(index) + "." + ext)
                    index += 1
                }
                try fileManager.moveItem(atPath: item.filepath, toPath: target)
                actions.append(FileAction(source: item.filepath, target: target, isCopy: false))

                // 侧车必须跟着走：只移照片会把 XMP 留在原目录，元数据与照片失联。
                // 共享侧车（兄弟仍在工作区）必须复制：搬走会让留下的 RAW 失去 .xmp，
                // Capture One 读到的是"无元数据"。
                if hasSidecar {
                    let destSidecar = (target as NSString).deletingPathExtension + ".xmp"
                    if item.sharesSidecar {
                        try fileManager.copyItem(atPath: sidecar, toPath: destSidecar)
                    } else {
                        try fileManager.moveItem(atPath: sidecar, toPath: destSidecar)
                    }
                    actions.append(FileAction(
                        source: sidecar, target: destSidecar, isCopy: item.sharesSidecar))
                }

                // 交付备份（<xmp>.gather-backup-*）也要跟着走并改成新名前缀：
                // cleanup/finalize 回放要求备份是新 xmp 的同目录兄弟，留在旧目录会被
                // DeliveryBackupPath 判 invalidBackup 并终态丢弃，备份也永久滞留。
                actions.append(contentsOf: try moveSidecarBackups(
                    oldPhotoPath: item.filepath, newPhotoPath: target,
                    sharesSidecar: item.sharesSidecar))

                if let relocate {
                    try relocate(item.photoId, item.filepath, target, item.sharesSidecar)
                } else {
                    try photoRepo.updateFilepath(photoId: item.photoId, filepath: target)
                }
                moved.append(item.photoId)
                newPaths.append(target)
            } catch {
                // 任一步失败（含侧车/登记）→ 把已产生的副作用全部撤销。
                // 回滚本身失败时不能静默：文件会留在 _rejects、DB 仍指旧路径，
                // 必须把"需人工恢复"的具体路径写进失败原因。
                var rollbackErrors: [String] = []
                for action in actions.reversed() {
                    guard fileManager.fileExists(atPath: action.target) else { continue }
                    do {
                        if action.isCopy {
                            try fileManager.removeItem(atPath: action.target)
                        } else {
                            try fileManager.moveItem(atPath: action.target, toPath: action.source)
                        }
                    } catch {
                        rollbackErrors.append(
                            "\(action.target) -> \(action.isCopy ? "删除副本" : action.source): \(error)")
                    }
                }
                var message = String(describing: error)
                if !rollbackErrors.isEmpty {
                    message += "；回滚失败（文件可能留在 \(Self.folderName)，需人工恢复）："
                        + rollbackErrors.joined(separator: " | ")
                }
                failed.append(RejectedMoveFailure(photoId: item.photoId, message: message))
            }
        }
        return RejectedMoveResult(moved: moved, newPaths: newPaths, failed: failed)
    }
}

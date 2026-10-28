// desktop/native/gather-core/Sources/GatherApplication/Services/FileOps/RejectedMover.swift
// P1 / D：把淘汰照片移出工作目录（默认 <sessionRoot>/_rejects）。
//
// 安全边界：
// - 只移动、不删除（交付前要可恢复；删文件不可撤销）；
// - 逐张独立执行，失败不中断整批；
// - 移动成功后立刻改写 photos.filepath，避免"文件在 _rejects、库里还指老路径"。
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

public final class RejectedMover: @unchecked Sendable {
    public static let folderName = "_rejects"
    private let photoRepo: any PhotoRepository
    private let fileManager: FileManager
    /// 路径迁移（photos + deliveries/intents + keyword origins + sidecar bindings +
    /// asset_files）由宿主在**一个事务**内完成；nil = 仅改 photos.filepath。
    private let relocate: ((String, String, String) throws -> Void)?

    public init(
        photoRepo: any PhotoRepository,
        fileManager: FileManager = .default,
        relocate: ((String, String, String) throws -> Void)? = nil
    ) {
        self.photoRepo = photoRepo
        self.fileManager = fileManager
        self.relocate = relocate
    }

    /// photos: (photoId, 原路径)，调用方保证这批照片已确认淘汰。
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
    /// 返回 (source, target)，由调用方的 movedFiles 统一回滚。
    private func moveSidecarBackups(
        oldPhotoPath: String,
        newPhotoPath: String
    ) throws -> [(source: String, target: String)] {
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
        var moved: [(source: String, target: String)] = []
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
            moved.append((source, target))
        }
        return moved
    }

    public func move(photos: [(photoId: String, filepath: String)], destinationRoot: String) -> RejectedMoveResult {
        var moved: [String] = []
        var newPaths: [String] = []
        var failed: [RejectedMoveFailure] = []
        for photo in photos {
            var movedFiles: [(source: String, target: String)] = []
            do {
                try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
                let name = (photo.filepath as NSString).lastPathComponent
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                let sidecar = TSPath.xmpSidecarPath(photo.filepath)
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
                try fileManager.moveItem(atPath: photo.filepath, toPath: target)
                movedFiles.append((photo.filepath, target))

                // 侧车必须跟着走：只移照片会把 XMP 留在原目录，元数据与照片失联。
                if hasSidecar {
                    let destSidecar = (target as NSString).deletingPathExtension + ".xmp"
                    try fileManager.moveItem(atPath: sidecar, toPath: destSidecar)
                    movedFiles.append((sidecar, destSidecar))
                }

                // 交付备份（<xmp>.gather-backup-*）也要跟着走并改成新名前缀：
                // cleanup/finalize 回放要求备份是新 xmp 的同目录兄弟，留在旧目录会被
                // DeliveryBackupPath 判 invalidBackup 并终态丢弃，备份也永久滞留。
                for backup in try moveSidecarBackups(
                    oldPhotoPath: photo.filepath, newPhotoPath: target) {
                    movedFiles.append(backup)
                }

                if let relocate {
                    try relocate(photo.photoId, photo.filepath, target)
                } else {
                    try photoRepo.updateFilepath(photoId: photo.photoId, filepath: target)
                }
                moved.append(photo.photoId)
                newPaths.append(target)
            } catch {
                // 任一步失败（含侧车/登记）→ 把已移动的文件全部放回。
                // 回滚本身失败时不能静默：文件会留在 _rejects、DB 仍指旧路径，
                // 必须把"需人工恢复"的具体路径写进失败原因。
                var rollbackErrors: [String] = []
                for entry in movedFiles.reversed() {
                    guard fileManager.fileExists(atPath: entry.target) else { continue }
                    do {
                        try fileManager.moveItem(atPath: entry.target, toPath: entry.source)
                    } catch {
                        rollbackErrors.append(
                            "\(entry.target) -> \(entry.source): \(error)")
                    }
                }
                var message = String(describing: error)
                if !rollbackErrors.isEmpty {
                    message += "；回滚失败（文件可能留在 \(Self.folderName)，需人工恢复）："
                        + rollbackErrors.joined(separator: " | ")
                }
                failed.append(RejectedMoveFailure(photoId: photo.photoId, message: message))
            }
        }
        return RejectedMoveResult(moved: moved, newPaths: newPaths, failed: failed)
    }
}

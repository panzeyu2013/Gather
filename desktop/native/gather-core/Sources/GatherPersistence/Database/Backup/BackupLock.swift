// desktop/native/gather-core/Sources/GatherPersistence/Database/Backup/BackupLock.swift
// P0 / B0：跨进程备份互斥锁。与 RestoreLock 分离：备份可并发读，但不能两个进程
// 同时往同一目录写 partial / 最终文件。
import Foundation
import GatherProtocol

public final class BackupLock {
    private let fd: Int32
    private let path: String
    private var released = false

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    public static func acquire(at appDir: URL) throws -> BackupLock {
        let path = appDir.appendingPathComponent(".backup.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw MaintenanceError.backupBusy
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MaintenanceError.backupBusy
        }
        return BackupLock(fd: fd, path: path)
    }

    public func release() {
        // 显式 release + deinit 可能各调一次；重复 close 可能误关复用后的 fd。
        guard !released else { return }
        released = true
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
    }

    deinit { release() }
}

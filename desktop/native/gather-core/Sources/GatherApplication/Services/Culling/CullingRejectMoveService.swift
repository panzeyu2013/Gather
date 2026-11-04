// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingRejectMoveService.swift
// 淘汰移出的**锁内执行**（#2 S3 剩余部分）。
//
// 规划（校验/资产展开/sharesSidecar/目标目录）在 RejectedMovePlanner（纯函数）；
// 这里只做「逐张进 XMPFileLock → RejectedMover.move → 失败隔离 → 重算 photo_count」。
//
// 为什么现在能下沉：之前依赖 `any PhotoRepository` 在 @Sendable 闭包里捕获，
// 而它不是 Sendable，只能给本类型加 @unchecked——预算 60/60 没有余量。
// #6 前置把 PhotoRepository 声明成 Sendable 后（实现只有 connection 一个存储属性），
// 本类型可以是真的 Sendable。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherDelivery

public struct CullingRejectMoveService: Sendable {
    /// 归档后重算 sessions.photo_count（侧栏/控制中心直接显示这个数）。
    private let refreshPhotoCount: @Sendable (String) throws -> Void
    /// 与写回/清理共用的按 xmpPath 文件锁；nil = 测试/未接线（退化为不加锁）。
    private let fileLock: XMPFileLock?

    /// 为什么 mover 是方法参数而不是字段：RejectedMover 存了一个非 Sendable 的
    /// relocate 闭包（它自身已是 @unchecked Sendable，属存量预算）。塞进本类型会逼
    /// 本类型也标 @unchecked——而预算 60/60 没有余量；传参数则由调用方持有。
    public init(
        refreshPhotoCount: @escaping @Sendable (String) throws -> Void,
        fileLock: XMPFileLock?
    ) {
        self.refreshPhotoCount = refreshPhotoCount
        self.fileLock = fileLock
    }

    /// 执行规划结果：逐张加锁搬移，失败隔离（单张失败不中断整批）。
    public func move(
        _ plan: RejectedMovePlanner.Plan,
        mover: RejectedMover,
        sessionId: String
    ) async throws -> CullingMoveRejectedResult {
        var moved: [String] = []
        var newPaths: [String] = []
        var failures: [MetadataApplyFailureDTO] = []
        for item in plan.items {
            let one: RejectedMoveResult
            do {
                one = try await withFileLock(path: TSPath.xmpSidecarPath(item.filepath)) {
                    mover.move(items: [item], destinationRoot: plan.destination)
                }
            } catch {
                failures.append(MetadataApplyFailureDTO(
                    photoId: item.photoId, message: String(describing: error)))
                continue
            }
            moved.append(contentsOf: one.moved)
            newPaths.append(contentsOf: one.newPaths)
            failures.append(contentsOf: one.failed.map {
                MetadataApplyFailureDTO(photoId: $0.photoId, message: $0.message)
            })
        }
        // 有照片移出成功才重算；失败项不改变可见集合。
        // 重算走单条 UPDATE … = (SELECT COUNT(*) …)：算与写原子完成。
        if !moved.isEmpty {
            do {
                try refreshPhotoCount(sessionId)
            } catch {
                GatherLogger.log(
                    "move_rejected: refresh session photo_count failed: \(error)", level: .warn)
            }
        }
        return CullingMoveRejectedResult(
            moved: moved, newPaths: newPaths, skipped: plan.skipped, failed: failures)
    }

    private func withFileLock<T: Sendable>(
        path: String,
        _ body: @Sendable () throws -> T
    ) async throws -> T {
        guard let fileLock else { return try body() }
        return try await fileLock.run(path: path) { try body() }
    }
}

// desktop/native/gather-core/Sources/GatherDelivery/Writeback/WritebackService+Helpers.swift
// 拆分（final-sweep-code P1-1 / 纯移动）：WritebackService 按角色拆分——共享类型 / 路径 / 行映射。
// 源：HEAD ab7752e 的 Writeback/WritebackService.swift；仅调整跨文件访问级与文件头注释。
import Foundation
import GatherPersistence
import GatherProtocol

/// TS: writeback.service.ts 抛出的错误码。
public enum WritebackServiceError: Error, Equatable, CustomStringConvertible {
    case otherModuleActive // WRITEBACK_OTHER_MODULE_ACTIVE
    case failuresPending // WRITEBACK_FAILURES_PENDING
    case undoFaceFailed // WRITEBACK_UNDO_FACE_FAILED
    /// TS: `result?.errorMessage || 'WRITEBACK_UNDO_FACE_FAILED'`（撤销失败的
    /// 具体原因优先，缺失时回退常量码）。
    case undoFaceFailedWithMessage(String)
    case cleanupRequiresLoaded // XMP_CLEANUP_REQUIRES_LOADED（writeback 侧守卫）

    public var description: String {
        switch self {
        case .otherModuleActive: "WRITEBACK_OTHER_MODULE_ACTIVE"
        case .failuresPending: "WRITEBACK_FAILURES_PENDING"
        case .undoFaceFailed: "WRITEBACK_UNDO_FACE_FAILED"
        case .undoFaceFailedWithMessage(let message):
            message.isEmpty ? "WRITEBACK_UNDO_FACE_FAILED" : message
        case .cleanupRequiresLoaded: "XMP_CLEANUP_REQUIRES_LOADED"
        }
    }
}

/// execute Phase 1 并发 body 的收集盒子（prepared/errors/failedItems/failed
/// 串行写入；并发 append 会 SIGSEGV 或静默丢项）。
/// `@unchecked Sendable` 的依据：四个可变字段只在 `lock`（NSLock）临界区内通过
/// 同步方法与快照属性读写；锁内不含 await，并发阶段结束后转单线程消费快照。
final class PhaseOneCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [PreparedEntry] = []
    private var errors: [String] = []
    private var failedItems: [WritebackItem] = []
    private var pathErrors: [String: String] = [:]
    private var failed = 0
    /// 每条交付（xmpPath）在写盘前取得的真实备份路径（S5c-2b-3b-1）。
    private var backups: [String: String] = [:]

    func recordPrepared(_ entry: PreparedEntry) {
        lock.lock()
        defer { lock.unlock() }
        prepared.append(entry)
    }

    func recordFailure(message: String, item: WritebackItem) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(message)
        failedItems.append(item)
        failed += 1
    }

    /// 逐交付首个失败原因（交付行最终标 failed 时用它当 error_message）。
    func recordPathError(path: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        if pathErrors[path] == nil { pathErrors[path] = message }
    }

    /// 同一交付只备份一次（共享侧车的 RAW+JPEG 走同一 xmpPath）。
    func needsBackup(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backups[path] == nil
    }

    func recordBackup(path: String, backupPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if backups[path] == nil { backups[path] = backupPath }
    }

    var preparedSnapshot: [PreparedEntry] {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    var errorsSnapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    var failedItemsSnapshot: [WritebackItem] {
        lock.lock()
        defer { lock.unlock() }
        return failedItems
    }

    var pathErrorsSnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return pathErrors
    }

    var backupsSnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return backups
    }

    var failedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

/// 交付行 + 交付项行的成对视图（execute/preview 的行映射单位）。
///
/// 为什么需要成对：delivery_items 不带 session_id/xmp_path/backup_path，
/// 交付级字段在 deliveries 上；一次 listItems + getMany 组装，避免 N+1。
struct DeliveryWritebackEntry: Sendable {
    let delivery: DeliveryRow
    let item: DeliveryItemRow
}

/// execute 前的 writing 归位结果（P1-2）：崩溃遗留的写租约在本次执行内收敛。
struct LeaseRecoveryResult {
    var written = 0
    var failed = 0
    var errors: [String] = []
}

/// Phase 1 的 prepare 结果（TS 内联对象）。
struct PreparedEntry: Sendable {
    let itemId: Int64
    /// 交付行快照（状态迁移用 xmpPath + revision）。
    let delivery: DeliveryRow
    let persistedItem: WritebackItem
    /// preview 快照里的照片路径（报告/失败信息用）。
    let photoPath: String
    /// execute 时实际写盘的照片路径（资产 relink 后与快照不同）。
    let writePhotoPath: String
    /// 实际写进侧车的完整属性（回读基线失败时的回退值，也供本地投影）。
    let writtenAttributes: MetadataWriteAttributes
    let keywordsBeforeWrite: [String]

    var itemPhotoId: String { persistedItem.photoId }
}

// writeback-planners.ts（writeback-planners.ts 全量）
// ────────────────────────────────────────────────────────────

/// TS: buildSimilarityKeywordPlan —— 相似度分组关键词 → 按侧车聚合 + 受影响路径集。
public func buildSimilarityKeywordPlan(
    groups: [SimilarityGroup],
    assignments: [(groupId: Int, keywords: [String])]
) throws -> (keywordsBySidecar: [String: [String]], affectedPaths: Set<String>) {
    let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    var keywordsBySidecar: [String: [String]] = [:]
    var affectedPaths = Set<String>()
    for assignment in assignments {
        guard let group = groupsById[assignment.groupId] else {
            throw WritebackPlannerError.groupNotInSession
        }
        for image in group.images {
            affectedPaths.insert(image.path)
            let sidecarPath = TSPath.xmpSidecarPath(image.path)
            keywordsBySidecar[sidecarPath] = orderedUnion(
                keywordsBySidecar[sidecarPath] ?? [],
                assignment.keywords
            )
        }
    }
    return (keywordsBySidecar, affectedPaths)
}

/// TS: buildFaceKeywordAdditions —— 人脸簇绑定 → 每照片关键词追加。
/// 实现见 FaceKwService.buildFaceKeywordAdditions（同 TS 源
/// writeback-planners.ts:48，本文件不重复定义）。

public enum WritebackPlannerError: Error, Equatable, CustomStringConvertible {
    case groupNotInSession // WRITEBACK_GROUP_NOT_IN_SESSION

    public var description: String {
        switch self {
        case .groupNotInSession: "WRITEBACK_GROUP_NOT_IN_SESSION"
        }
    }
}

extension WritebackService {
    // MARK: - 私有支撑

    /// 旧写回模块名 → 交付模块（落库值只取 SchemaCurrent 的 CHECK 值）。
    func mapModule(_ module: String) throws -> DeliveryModule {
        guard let mapped = DeliveryModule(writebackModule: module) else {
            // 现有调用方只用 culling / similarity / face_kw（含 "face-keyword" 别名），
            // 未知模块是调用方 bug：显式失败而不是静默落到 .metadata。
            throw DeliveryRepoError.invalidArgument("unsupported writeback module: \(module)")
        }
        return mapped
    }

    /// TS: assertNoActiveOtherModule —— 单写回状态机：另一模块的 written/synced 工作
    /// 必须先确认并清理。读交付项（归属从旧 outbox 的 __owners__ 提升为行）。
    /// culling 是连续同步模块，绝不阻塞其它模块的批量写回，故排除。
    func assertNoActiveOtherModule(sessionId: String, module: String) throws {
        let current = try mapModule(module)
        for row in try deliveryRepo.listItems(sessionId: sessionId) {
            guard row.typedStatus == .written || row.typedStatus == .synced else { continue }
            guard let typed = row.typedModule else {
                // 未知模块串（历史脏数据）按「其它模块」处理，宁可拦下不可覆盖。
                throw WritebackServiceError.otherModuleActive
            }
            // culling 是连续同步模块；metadata/template 是本地显式写入且**没有
            // confirm/cleanup 出口**（MetadataAPI 不提供），若按 written 阻塞会让
            // 一次星级写回永久挡住 culling/face/sim 的所有写回。它们由各自的
            // 批次快照负责撤销，行/备份留给维护清理。
            if typed == current || typed == .culling
                || typed == .metadata || typed == .template {
                continue
            }
            throw WritebackServiceError.otherModuleActive
        }
    }

    /// 一次组装「会话 × 模块」的交付项与其交付行（listItems 一次 + getMany 一次）。
    func loadEntries(
        sessionId: String,
        module: DeliveryModule,
        status: DeliveryItemStatus? = nil
    ) throws -> [DeliveryWritebackEntry] {
        let items = try deliveryRepo.listItems(sessionId: sessionId, module: module, status: status)
        guard !items.isEmpty else { return [] }
        let deliveries = try deliveryRepo.getMany(xmpPaths: items.map(\.xmpPath))
        return try items.map { item in
            guard let delivery = deliveries[TSPath.normalize(item.xmpPath)] else {
                throw DeliveryRepoError.rowNotFound(xmpPath: item.xmpPath)
            }
            return DeliveryWritebackEntry(delivery: delivery, item: item)
        }
    }

    /// TS: rowToItem —— 交付行 + 交付项行 → 协议形状（字段语义与旧 writeback_items 一致）。
    func entryToItem(_ entry: DeliveryWritebackEntry, sessionId: String) -> WritebackItem {
        var attributes: WritebackAttributes? = nil
        if !entry.item.attributesJSON.isEmpty {
            let dict = entry.item.attributes
            attributes = WritebackAttributes(
                keywords: dict["keywords"]?.arrayElements?.compactMap { $0.stringValue },
                rating: dict["rating"]?.numberValue,
                label: dict["label"]?.stringValue
            )
        }
        return WritebackItem(
            id: Int(entry.item.id),
            photoId: entry.item.photoId,
            photoPath: entry.delivery.photoPath,
            sessionId: sessionId,
            module: entry.item.typedModule?.writebackModuleName ?? entry.item.module,
            keywords: entry.item.keywordList,
            attributes: attributes,
            xmpPath: entry.delivery.xmpPath,
            backupPath: entry.delivery.backupPath,
            xmpStatus: entry.item.status,
            errorMessage: entry.item.errorMessage,
            attemptCount: Int(entry.item.attemptCount),
            lastAttemptAt: entry.item.updatedAt
        )
    }


    /// TS: resolvePreviewTargets —— preview 时逐会话一次 resolveMany 批量查询；
    /// 解析器服务不到的项按遗留 filepath/sidecar 兜底；无 resolveMany 时逐项
    /// resolve（保持旧的精确语义）。
    func resolvePreviewTargets(
        sessionId: String,
        photos: [(id: String, filepath: String)]
    ) throws -> [String: (filepath: String, xmpPath: String)] {
        func fallback(_ photo: (id: String, filepath: String)) -> (filepath: String, xmpPath: String) {
            (photo.filepath, TSPath.xmpSidecarPath(photo.filepath))
        }
        var byPhoto: [String: (filepath: String, xmpPath: String)] = [:]
        if let assetResolver {
            let resolved = try assetResolver.resolveMany(sessionId: sessionId, photoIds: photos.map(\.id))
            for photo in photos {
                if let asset = resolved[photo.id] {
                    byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
                } else {
                    byPhoto[photo.id] = fallback(photo)
                }
            }
            return byPhoto
        }
        for photo in photos {
            if let assetResolver, let asset = try? assetResolver.resolve(sessionId: sessionId, photoId: photo.id) {
                byPhoto[photo.id] = (asset.filepath, asset.xmpPath)
            } else {
                byPhoto[photo.id] = fallback(photo)
            }
        }
        return byPhoto
    }

    /// 侧车路径 → 照片路径（xmp 后缀大小写不敏感，与 execute 的回退同口径）。
    static func photoPathFromSidecar(_ xmpPath: String) -> String {
        xmpPath.lowercased().hasSuffix(".xmp") ? String(xmpPath.dropLast(4)) : xmpPath
    }
}

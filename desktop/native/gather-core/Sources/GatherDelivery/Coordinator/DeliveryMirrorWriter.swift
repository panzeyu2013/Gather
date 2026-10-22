// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryMirrorWriter.swift
// WP2b：写回镜像（自 DeliveryCoordinator.swift 抽出，语义逐字保留）。
//
// 把旧 WritebackService 的执行结果镜像进 deliveries / delivery_items / delivery_sessions：
// - 每个 xmpPath 一条 delivery（与旧 outbox 的侧车粒度一致）；同侧车的多张照片
//   （RAW+JPEG）各一条 item；
// - 已有交付收到新输入 → revision + 1、状态回到 pending 再走 writing；
//   旧 revision 的 CAS 写入口因此不会覆盖本轮结果；
// - item 先回 pending 再写目标态，覆盖 synced→pending→written 的合法重开路径；
// - 有任一 written item → delivery=written；全部 failed → delivery=failed；
//   混合时交付保持 written，但 failed item 会让摘要/confirm 门禁看见失败；
// - 失败不抛出（XMP 已落盘）：逐条进 errors，由调用方并入 WritebackResult.errors。
//
// 所有状态写入经 DeliveryStateWriter；镜像只决定「写什么」，不直接调 Repo 的迁移方法。

import Foundation
import GatherPersistence

struct DeliveryMirrorWriter: Sendable {
    let repo: DeliveryRepo
    let writer: DeliveryStateWriter
    /// 本实例的写租约 owner（P1-2）：claim 与 markWritten 必须使用同一身份。
    let leaseOwner: String

    func mirrorWriteback(
        sessionId: String,
        module: DeliveryModule,
        items: [DeliveryWritebackMirrorItem]
    ) throws -> DeliveryMirrorSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        var grouped: [String: [DeliveryWritebackMirrorItem]] = [:]
        var errors: [String] = []
        for item in items {
            let path = TSPath.normalize(item.xmpPath)
            guard !path.isEmpty else {
                errors.append("DELIVERY_MIRROR_INVALID_PATH: photo=\(item.photoId)")
                continue
            }
            guard DeliveryStateMachine.isMirrorableItemStatus(item.status) else {
                errors.append("DELIVERY_MIRROR_INVALID_STATUS: \(path) \(item.status.rawValue)")
                continue
            }
            grouped[path, default: []].append(item)
        }

        var deliveryCount = 0
        var itemCount = 0
        for (path, groupItems) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let first = groupItems.first, !first.photoPath.isEmpty else {
                errors.append("DELIVERY_MIRROR_MISSING_PHOTO_PATH: \(path)")
                continue
            }
            do {
                guard let revision = try writer.openDeliveryForWrite(
                    xmpPath: path,
                    photoPath: first.photoPath,
                    baseFingerprint: first.baseFingerprint,
                    baseValues: first.baseValues
                ) else {
                    errors.append("DELIVERY_MIRROR_TERMINAL_DELIVERY: \(path)")
                    continue
                }
                guard try writer.claimWriting(
                    xmpPath: path, revision: revision, leaseOwner: leaseOwner) != nil else {
                    errors.append("DELIVERY_MIRROR_LEASE_CONFLICT: \(path)")
                    continue
                }
                var writtenItems = 0
                var firstErrorMessage = ""
                for item in groupItems {
                    // 先回 pending：覆盖 synced/written/failed 的合法重开路径
                    //（item 迁移表不允许 synced → written 一步到位）。
                    _ = try writer.upsertItem(
                        xmpPath: path,
                        photoId: item.photoId,
                        module: module,
                        attributes: item.attributes,
                        keywords: item.keywords,
                        status: .pending,
                        errorMessage: ""
                    )
                    let row = try writer.upsertItem(
                        xmpPath: path,
                        photoId: item.photoId,
                        module: module,
                        attributes: item.attributes,
                        keywords: item.keywords,
                        status: item.status,
                        errorMessage: item.errorMessage
                    )
                    itemCount += 1
                    if row.typedStatus == .failed {
                        if firstErrorMessage.isEmpty { firstErrorMessage = item.errorMessage }
                    } else {
                        writtenItems += 1
                    }
                }
                if writtenItems > 0 {
                    guard try writer.markWritten(
                        xmpPath: path,
                        revision: revision,
                        leaseOwner: leaseOwner,
                        baseFingerprint: first.baseFingerprint,
                        baseValues: first.baseValues,
                        backupPath: first.backupPath
                    ) != nil else {
                        errors.append("DELIVERY_MIRROR_WRITE_CAS_FAILED: \(path)")
                        continue
                    }
                } else {
                    guard try writer.markFailed(
                        xmpPath: path,
                        revision: revision,
                        errorMessage: firstErrorMessage.isEmpty ? "WRITEBACK_FAILED" : firstErrorMessage,
                        leaseOwner: leaseOwner
                    ) != nil else {
                        errors.append("DELIVERY_MIRROR_FAIL_CAS_FAILED: \(path)")
                        continue
                    }
                }
                _ = try writer.linkSession(xmpPath: path, sessionId: sessionId)
                deliveryCount += 1
            } catch {
                errors.append(Self.failure("DELIVERY_MIRROR_FAILED", path, error))
            }
        }

        return DeliveryMirrorSummary(
            deliveryCount: deliveryCount,
            itemCount: itemCount,
            errors: errors
        )
    }

    private static func failure(_ code: String, _ xmpPath: String, _ error: Error) -> String {
        "\(code): \(xmpPath) reason=\(String(describing: error))"
    }
}

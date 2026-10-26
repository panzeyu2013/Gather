// desktop/native/gather-core/Sources/GatherDelivery/Writeback/WritebackService+Converge.swift
// 拆分（final-sweep-code P1-1 / 纯移动）：WritebackService 按角色拆分——Phase 2 收敛副作用（通知 / reload-ack / 本地投影）。
// 源：HEAD ab7752e 的 Writeback/WritebackService.swift；仅调整跨文件访问级与文件头注释。
import Foundation
import GatherPersistence
import GatherProtocol

extension WritebackService {
    // MARK: - Phase 2 收敛与镜像（状态落库后的副作用）
    /// 交付状态已变化：通知宿主（sessionId 为空不通知）。
    func emitStateChanged(_ sessionId: String) {
        guard !sessionId.isEmpty, let eventSink else { return }
        eventSink(sessionId)
    }

    /// 新写入让关联会话的 Capture One reload-ack 失效（§5.4-2 门禁的数据侧）。
    ///
    /// 旧协调器在 claim 后按 outbox 关联会话清 ack；执行器直写后由交付的
    /// delivery_sessions 反查同一批会话，保证 confirm/finalize 必须等一次新 reload。
    func clearReloadAck(forXmpPath xmpPath: String) {
        do {
            try SessionReloadAckRepo(connection: connection)
                .clearReloadAcks(forXmpPath: xmpPath, timestamp: nowISOString())
        } catch {
            // 不改变已落盘的 written：ack 清理失败只会让门禁更严格（下次 reload 仍可过）。
            // P2-5：basename#hash + 结构化 reason，完整路径只留在返回的 errors。
            GatherLogger.log(
                "Failed to clear reload-ack for \(DeliveryTrace.pathToken(xmpPath)): "
                    + DeliveryTrace.reason(error, paths: [xmpPath]),
                level: .warn)
        }
    }


    /// 写盘成功后的本地投影刷新（元数据缓存 + 人脸关键词归属）。
    /// XMP 已经落盘，因此投影失败不改判 written，但必须逐条可见（禁止 try? 吞写失败）。
    func updateLocalProjection(entry: PreparedEntry, attrs: [String: JSONValue], module: String) -> [String] {
        var failures: [String] = []
        func record(_ operation: String, _ error: Error) {
            let failure = MetadataWritebackFailure.from(error, xmpPath: entry.delivery.xmpPath)
            failures.append(failure.description + " operation=" + operation)
            // P2-5：失败记录仍带完整路径（返回值可定位），日志只留码 + token + 脱敏原因。
            GatherLogger.log(
                "Writeback projection failed (\(operation)) for "
                    + "\(DeliveryTrace.pathToken(entry.delivery.xmpPath)) "
                    + "code=\(failure.code) "
                    + "reason=\(DeliveryTrace.sanitize(failure.reason, paths: [entry.delivery.xmpPath]))",
                level: .warn)
        }
        if let rating = attrs["rating"]?.numberValue {
            do {
                try metadataCacheRepo.updateRating(photoId: entry.itemPhotoId, rating: Int64(rating))
            } catch {
                record("cache.updateRating", error)
            }
        }
        if let label = attrs["label"]?.stringValue {
            do {
                try metadataCacheRepo.updateLabel(photoId: entry.itemPhotoId, label: label)
            } catch {
                record("cache.updateLabel", error)
            }
        }
        if let keywords = attrs["keywords"]?.arrayElements?.compactMap({ $0.stringValue }) {
            do {
                try metadataCacheRepo.updateKeywords(photoId: entry.itemPhotoId, keywords: keywords)
            } catch {
                record("cache.updateKeywords", error)
            }
            if let source = Self.keywordOriginSource(for: module), let keywordOrigins {
                // keywordsBeforeWrite 是 phase 1 的写前快照：写入前不在文件上的关键词即本模块引入的。
                let existing = Set(entry.keywordsBeforeWrite)
                let final = Set(keywords)
                let introduced = keywords.filter { !existing.contains($0) }
                let removed = existing.subtracting(final)
                do {
                    try keywordOrigins.markIntroduced(
                        xmpPath: entry.delivery.xmpPath, source: source, keywords: introduced)
                    // 词已从文件消失：来源凭据必须同步失效，否则后续别的模块
                    // 重新引入同一个词时会被“仍被本模块拥有”误拦。
                    try keywordOrigins.deactivate(
                        xmpPath: entry.delivery.xmpPath, source: source,
                        keywords: Array(removed))
                } catch {
                    record("origin.update", error)
                }
            }
        }
        return failures
    }

    /// 生成关键词的交付模块 → 来源凭据。metadata 是用户手动词，不记源。
    static func keywordOriginSource(for module: String) -> String? {
        switch module {
        case "face_kw": return "face-keyword"
        case "culling": return "culling"
        case "similarity": return "similarity"
        case "template": return "template"
        default: return nil
        }
    }
}

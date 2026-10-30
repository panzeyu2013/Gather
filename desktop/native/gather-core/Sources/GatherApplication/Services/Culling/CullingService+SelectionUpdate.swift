// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+SelectionUpdate.swift
// P1-7：跨页全选批量。服务端用与 selection 完全相同的查询重算，hash 不符则零写入；
// 按 10k 分块调用既有 batchUpdate，每块一个 history operation。
import Foundation
import GatherProtocol

extension CullingService {
    public func updateSelection(
        _ input: CullingSelectionUpdateInput
    ) throws -> CullingSelectionUpdateResult {
        let query = try CullingSelectionQuery(
            sessionId: input.sessionId,
            scope: input.scope,
            filters: input.filters,
            groupId: input.groupId,
            limit: input.limit
        )
        let selection = try selectableIds(query)
        let actualHash = selection.idsHash ?? CullingSelectionHash.make(ids: selection.ids)
        guard actualHash == input.expectedIdsHash,
              selection.ids.count == input.expectedCount else {
            throw GatherError(code: .CULLING_SELECTION_CHANGED)
        }

        var applied = 0
        var skipped: [CullingBatchSkip] = []
        var failed: [CullingBatchFailure] = []
        var historyOperationIds: [Int] = []
        var states: [AssetCullingState] = []
        var index = 0
        while index < selection.ids.count {
            let end = min(index + Self.batchMax, selection.ids.count)
            let chunk = Array(selection.ids[index..<end])
            do {
                let results = try batchUpdate(
                    sessionId: input.sessionId,
                    photoIds: chunk,
                    patch: input.patch
                )
                let chunkStates = results.flatMap(\.states)
                states.append(contentsOf: chunkStates)
                // applied 按“请求的代表照片”计数：pick 会展开资产变体、rating/label
                // 会联动共享 sidecar，chunkStates 行数可能大于 chunk 行数。
                let written = Set(chunkStates.map(\.photoId))
                applied += chunk.filter { written.contains($0) }.count
                for id in results.compactMap(\.historyOperationId)
                where !historyOperationIds.contains(id) {
                    historyOperationIds.append(id)
                }
                // reason 是机器码（"unchanged"），本地化交给 UI；不把中文散文塞进协议字段。
                skipped.append(contentsOf: chunk
                    .filter { !written.contains($0) }
                    .map { CullingBatchSkip(photoId: $0, reason: "unchanged") })
            } catch {
                // 分块失败：保留已完成块，停止后续块；UI 显示部分结果并提示可再次执行。
                failed.append(CullingBatchFailure(
                    photoId: "",
                    code: (error as? any CodedError)?.code.rawValue ?? "",
                    detail: "第 \(index / Self.batchMax + 1) 块失败，涉及 \(chunk.count) 张；后续块未执行"
                ))
                break
            }
            index = end
        }
        return CullingSelectionUpdateResult(
            requested: selection.ids.count,
            applied: applied,
            skipped: skipped,
            failed: failed,
            historyOperationIds: historyOperationIds,
            truncated: selection.truncated,
            states: states
        )
    }
}

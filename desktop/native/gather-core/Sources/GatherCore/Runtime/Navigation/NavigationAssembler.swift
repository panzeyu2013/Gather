// desktop/native/gather-core/Sources/GatherCore/Runtime/Navigation/NavigationAssembler.swift
// W2d 小步①：NavigationService 纯函数层（Services/NavigationService.swift 的纯逻辑下沉）。
//
// 来源与边界：
// - 逐字搬迁 NavigationService.swift 中不访问持久层的纯逻辑：参数校验
//   （validateNavigationParameters）、burst/scene 分组（group + 文件名序号/汉明
//   距离/目录/ISO 日期解析）、split/merge 的校验与合并规则、lead 选择
//   （withLead）、result_json 解析（safeQuality）、指纹（fingerprintHash）与
//   photoIds JSON 编解码。
// - 本文件无 IO、无查询、无 Store 依赖：输入为行值类型，输出 Protocol 层 DTO
//   （NavigationGroup 等，Protocol/Navigation.swift）。设计文档 §0 门禁：Runtime
//   文件不得出现持久层连接类型或查询文本（本文件只 import Foundation）。
// - NAV_* 错误类型 NavigationError 仍由 Services/NavigationService.swift 声明：
//   设计文档 §0 命名纪律规定公开错误类型只能在删除旧服务文件的同一提交启用；
//   本文件仅引用其 case，抛出条件/顺序与原实现逐条一致。
// - 行类型命名注记：原服务内 file-private struct CaptureRow 随之搬迁，并嵌套为
//   NavigationAssembler.CaptureRow —— Store/NavigationStore.swift 已有顶层
//   NavigationCaptureRow（未解析 quality JSON 的拍摄行），同模块顶层重名会硬报
//   invalid redeclaration，故保持嵌套；字段/语义逐字一致。

import Foundation

/// TS: navigation.service.ts 的纯函数面（captureRows 查询与持久化装配由服务层负责）。
public enum NavigationAssembler {
    /// TS: CaptureRow —— 导航分组的行形状（captureRows 查询 + quality JSON 解析后）。
    public struct CaptureRow: Equatable, Sendable {
        public let id: String
        public let filepath: String
        public let filename: String
        public let capturedAt: String
        public let cameraModel: String
        public let hashHex: String
        public let rating: Double
        public let qualityScore: Double
        public let qualityWarnings: [String]
        public let hasQuality: Bool

        public init(
            id: String,
            filepath: String,
            filename: String,
            capturedAt: String,
            cameraModel: String,
            hashHex: String,
            rating: Double,
            qualityScore: Double,
            qualityWarnings: [String],
            hasQuality: Bool
        ) {
            self.id = id
            self.filepath = filepath
            self.filename = filename
            self.capturedAt = capturedAt
            self.cameraModel = cameraModel
            self.hashHex = hashHex
            self.rating = rating
            self.qualityScore = qualityScore
            self.qualityWarnings = qualityWarnings
            self.hasQuality = hasQuality
        }
    }

    // MARK: - 参数校验

    /// TS: validateNavigationParameters —— 参数非法抛错。
    public static func validateNavigationParameters(burstGapSeconds: Double, sceneGapSeconds: Double) throws {
        if !burstGapSeconds.isFinite || burstGapSeconds < 0.1 || burstGapSeconds > 300 {
            throw NavigationError.burstGapInvalid
        }
        if !sceneGapSeconds.isFinite || sceneGapSeconds < burstGapSeconds || sceneGapSeconds > 86_400 {
            throw NavigationError.sceneGapInvalid
        }
    }

    // MARK: - 分组

    /// TS: group —— 顺序扫描 + 边界判定（见服务文件头红线）。
    public static func group(rows: [CaptureRow], type: NavigationGroupType, gapSeconds: Double) -> [NavigationGroup] {
        var groups: [NavigationGroup] = []
        var current: [CaptureRow] = []
        let flush = {
            if current.count >= 2 {
                groups.append(NavigationGroup(
                    id: UUID().uuidString.lowercased(),
                    type: type,
                    photoIds: current.map { $0.id },
                    startAt: current[0].capturedAt,
                    endAt: current[current.count - 1].capturedAt,
                    explanation: "",
                    source: .automatic
                ))
            }
            current = []
        }
        for row in rows {
            let previous = current.last
            let gap = previous.map { (parseISODate(row.capturedAt) - parseISODate($0.capturedAt)) / 1000 } ?? 0
            let directoryChanged = previous.map { dirname($0.filepath) != dirname(row.filepath) } ?? false
            let sameCamera = previous == nil || previous!.cameraModel.isEmpty || row.cameraModel.isEmpty
                || previous!.cameraModel == row.cameraModel
            let previousSequence = previous.flatMap { filenameSequence($0.filename) }
            let currentSequence = filenameSequence(row.filename)
            let sequential = previousSequence == nil || currentSequence == nil
                || (currentSequence! > previousSequence! && currentSequence! - previousSequence! <= 3)
            let visualDistance = previous.flatMap { hammingDistance($0.hashHex, row.hashHex) }
            let visuallyRelated = visualDistance == nil || visualDistance! <= (type == .burst ? 14 : 24)
            let boundary = previous != nil && (
                !gap.isFinite ||
                gap < 0 ||
                gap > gapSeconds ||
                !sameCamera ||
                (type == .burst && (!sequential || !visuallyRelated)) ||
                (type == .scene && (directoryChanged || !visuallyRelated))
            )
            if boundary { flush() }
            current.append(row)
        }
        flush()
        return groups
    }

    /// TS: withLead —— 见服务文件头红线。
    public static func withLead(group: NavigationGroup, byId: [String: CaptureRow]) -> NavigationGroup {
        let hasAnyQuality = group.photoIds.contains { byId[$0]?.hasQuality == true }
        let ranked = group.photoIds
            .compactMap { byId[$0] }
            .sorted { left, right in
                if !hasAnyQuality { return left.rating > right.rating }
                let hasClosedEyeRisk: ([String]) -> Bool = { warnings in
                    warnings.contains("closed_eye_risk_heuristic") || warnings.contains("closed_eye_risk")
                }
                let leftPenalty = hasClosedEyeRisk(left.qualityWarnings) ? 0.25 : 0
                let rightPenalty = hasClosedEyeRisk(right.qualityWarnings) ? 0.25 : 0
                // TS: (right.score + right.rating*0.08 - rightPenalty) -
                //      (left.score + left.rating*0.08 - leftPenalty) —— 降序。
                return (left.qualityScore + left.rating * 0.08 - leftPenalty)
                    > (right.qualityScore + right.rating * 0.08 - rightPenalty)
            }
        let lead = ranked.first
        let explanation: String
        if lead != nil && hasAnyQuality {
            explanation = "NAV_RECOMMEND_QUALITY"
        } else if let lead, lead.rating > 0 {
            explanation = "NAV_RECOMMEND_RATING"
        } else {
            explanation = "NAV_RECOMMEND_ORDER"
        }
        return NavigationGroup(
            id: group.id,
            type: group.type,
            photoIds: group.photoIds,
            startAt: byId[group.photoIds[0]]?.capturedAt ?? group.startAt,
            endAt: byId[group.photoIds[group.photoIds.count - 1]]?.capturedAt ?? group.endAt,
            leadPhotoId: lead?.id,
            explanation: explanation,
            source: group.source
        )
    }

    // MARK: - split / merge 校验与合并规则

    /// TS: split —— splitIndex 越界抛 NAV_SPLIT_OUT_OF_GROUP（查询前判定）。
    public static func splitIndex(group: NavigationGroup, beforePhotoId: String) throws -> Int {
        let splitIndex = group.photoIds.firstIndex(of: beforePhotoId) ?? -1
        if splitIndex <= 0 || splitIndex >= group.photoIds.count {
            throw NavigationError.splitOutOfGroup
        }
        return splitIndex
    }

    /// TS: split —— 两个新 manual 组（前后半段，id 重新生成，startAt/endAt/
    /// explanation 沿用原组）并逐组重算 lead。
    public static func splitReplacements(group: NavigationGroup, splitIndex: Int, rows: [CaptureRow]) -> [NavigationGroup] {
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return [
            NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: group.type,
                photoIds: Array(group.photoIds[0..<splitIndex]),
                startAt: group.startAt,
                endAt: group.endAt,
                explanation: group.explanation,
                source: .manual
            ),
            NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: group.type,
                photoIds: Array(group.photoIds[splitIndex..<group.photoIds.count]),
                startAt: group.startAt,
                endAt: group.endAt,
                explanation: group.explanation,
                source: .manual
            ),
        ].map { withLead(group: $0, byId: byId) }
    }

    /// TS: merge —— 去重后 <2 组抛 NAV_MERGE_MIN_TWO（查询前判定）。
    public static func mergeUniqueIds(_ groupIds: [String]) throws -> [String] {
        let uniqueIds = Array(Set(groupIds))
        if uniqueIds.count < 2 {
            throw NavigationError.mergeMinTwo
        }
        return uniqueIds
    }

    /// TS: merge —— 全部存在（NAV_GROUP_NOT_FOUND，按去重 id 数对齐）且同类型
    /// （NAV_MERGE_TYPE_MISMATCH）。
    public static func validateMergeSelection(uniqueIds: [String], selected: [NavigationGroup]) throws {
        if selected.count != uniqueIds.count {
            throw NavigationError.groupNotFound
        }
        if Set(selected.map { $0.type }).count != 1 {
            throw NavigationError.mergeTypeMismatch
        }
    }

    /// TS: merge —— 按 captureRows 顺序排序合并且重算 lead。
    public static func mergedGroup(selected: [NavigationGroup], rows: [CaptureRow]) -> NavigationGroup {
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let photoIds = Array(Set(selected.flatMap { $0.photoIds }))
            .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        return withLead(
            group: NavigationGroup(
                id: UUID().uuidString.lowercased(),
                type: selected[0].type,
                photoIds: photoIds,
                startAt: "",
                endAt: "",
                explanation: "",
                source: .manual
            ),
            byId: byId
        )
    }

    // MARK: - 质量解析 / 指纹

    /// TS: safeQuality —— result_json 解析；status != 'failed' 且有 qualityScore
    /// 才算 hasQuality。
    public static func safeQuality(value: String?) -> (qualityScore: Double, warnings: [String], hasQuality: Bool) {
        guard let value, let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (0, [], false)
        }
        let score = (object["qualityScore"] as? NSNumber)?.doubleValue ?? 0
        let warnings = (object["warnings"] as? [Any])?.compactMap { $0 as? String } ?? []
        let status = object["status"] as? String
        let hasQuality = status != "failed" && (object["qualityScore"] as? NSNumber) != nil
        return (score, warnings, hasQuality)
    }

    /// TS: sha256(JSON.stringify([...]))。
    public static func fingerprintHash(burst: Double, scene: Double, rows: [CaptureRow]) -> String {
        let payload: [Any] = [
            burst,
            scene,
            rows.map { row -> [Any] in
                [
                    row.id,
                    row.capturedAt,
                    row.hashHex,
                    row.rating,
                    row.qualityScore,
                    row.qualityWarnings.sorted(),
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return SHA256.hash(Data(data)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 纯辅助（对账友好，独立测试）

    /// TS: filenameSequence —— 文件名尾部数字序列（无数字 → nil）。
    public static func filenameSequence(_ filename: String) -> Int? {
        let basename = (filename as NSString).deletingPathExtension
        let pattern = #"(\d+)(?!.*\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: basename, range: NSRange(location: 0, length: (basename as NSString).length))
        else { return nil }
        let range = match.range(at: 1)
        return Int((basename as NSString).substring(with: range))
    }

    /// TS: hammingDistance —— 16 位 hex 的汉明距离（popcount）。
    public static func hammingDistance(_ left: String, _ right: String) -> Int? {
        if left.isEmpty || right.isEmpty || left.count != right.count { return nil }
        guard let a = UInt64(left, radix: 16), let b = UInt64(right, radix: 16) else { return nil }
        return (a ^ b).nonzeroBitCount
    }

    /// TS: path.dirname。
    public static func dirname(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// TS: Date.parse(ISO string) → 毫秒时间戳。
    public static func parseISODate(_ value: String) -> Double {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        let formatter2 = ISO8601DateFormatter()
        if let date = formatter2.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        return Double.nan
    }

    /// photo_ids_json 解析（损坏退化 nil）。
    public static func parsePhotoIds(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return ids
    }

    /// photo_ids_json 编码。
    public static func photoIdsJSON(_ ids: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ids)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

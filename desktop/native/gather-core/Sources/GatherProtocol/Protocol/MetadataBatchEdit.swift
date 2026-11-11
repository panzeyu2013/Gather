// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataBatchEdit.swift
// Wave2 task-13：多选批量直改字段的"混合值（ambiguous）+ 逐张预检计划"纯逻辑。
//
// 解决的问题：applyDescriptive 只能把**同一份字段补丁**写给一组照片；多选不同值
// 时编辑器必须先算出"哪些字段是混合值（不默认覆盖）"，再按照片分别生成补丁，
// 最后按补丁分组提交（同补丁一组 = 一次 API 调用、一个撤销批次）。
//
// 语义：
// - 字段三态沿用 DescriptiveMetadata：未编辑 = 不触碰；显式清空 = clear；有值 = write；
// - 混合值检测以 **fold 后比较**（XMPFieldValue 本身 Equatable；空串/空数组归一成 nil）；
// - 预检与写入用同一份 plan：plan.patch 就是最终写入载荷，UI 预览与 apply 不会漂移；
// - 外部改动（盘上值 != 缓存投影）在 keepExternal 下转 conflict（不覆盖外部新值）；
// - 变量在任何一次写入前展开；展开不完整（unresolved 非空）时整批 canApply=false，
//   调用方必须拒绝提交，而不是把 {client} 原样写进 XMP；
// - 变量作用域/序号：scope.sequenceStart 起始、按调用方传入 photos 的顺序逐张 +1；
//   引擎本身不排序（UI 用 photoIds 升序传入，语义在 UI 注释里写死）。
import Foundation

/// 用户对某个字段的批量编辑意图。
public enum MetadataBatchFieldEdit: Equatable, Sendable {
    /// 不改这个字段。
    case unchanged
    /// 设为给定值（可含变量占位符；list 字段按元素逐个展开）。
    case set(XMPFieldValue)
    /// 显式清空（目标照片原本没有值 = unchanged，不算破坏性动作）。
    case clear
}

/// 一张目标照片的输入：缓存投影 + 盘上值 + 变量取值。
public struct MetadataBatchPhotoInput: Equatable, Sendable {
    public var photoId: String
    /// 缓存投影（photo_metadata_cache 的 descriptive）。
    public var cache: DescriptiveMetadata
    /// 盘上当前值（含 JPEG 内嵌；读不到时传空结构并置 diskKnown=false）。
    public var disk: DescriptiveMetadata
    /// 是否成功读过盘；false 时外部改动不可判定（按"未知"处理：不产生 conflict）。
    public var diskKnown: Bool
    public var filename: String
    public var camera: String?
    public var dateTaken: String?
    /// 变量 {seq} 的序号（调用方决定排序与起始值）。
    public var sequence: Int

    public init(
        photoId: String,
        cache: DescriptiveMetadata,
        disk: DescriptiveMetadata,
        diskKnown: Bool = true,
        filename: String,
        camera: String? = nil,
        dateTaken: String? = nil,
        sequence: Int
    ) {
        self.photoId = photoId
        self.cache = cache
        self.disk = disk
        self.diskKnown = diskKnown
        self.filename = filename
        self.camera = camera
        self.dateTaken = dateTaken
        self.sequence = sequence
    }

    public var variablePhoto: MetadataVariablePhoto {
        MetadataVariablePhoto(filename: filename, camera: camera, dateTaken: dateTaken)
    }
}

/// 单字段预检动作。
public enum MetadataBatchFieldAction: String, Codable, Equatable, Sendable {
    case write
    case clear
    case unchanged
    /// 盘上被外部改过，按 keepExternal 不覆盖。
    case conflict
}

/// 单字段预检明细（UI 逐张展开用）。
public struct MetadataBatchFieldPlan: Equatable, Sendable {
    public var field: DescriptiveField
    public var action: MetadataBatchFieldAction
    /// 展开后的目标值（nil = 清空/无动作）。
    public var target: XMPFieldValue?

    public init(field: DescriptiveField, action: MetadataBatchFieldAction, target: XMPFieldValue?) {
        self.field = field
        self.action = action
        self.target = target
    }
}

/// 单张照片的预检结果：明细 + 实际补丁（write/clear 的字段集合）。
public struct MetadataBatchPhotoPlan: Equatable, Sendable {
    public var photoId: String
    public var fields: [MetadataBatchFieldPlan]
    public var patch: DescriptiveMetadata

    public init(photoId: String, fields: [MetadataBatchFieldPlan], patch: DescriptiveMetadata) {
        self.photoId = photoId
        self.fields = fields
        self.patch = patch
    }

    public var writeCount: Int { fields.filter { $0.action == .write }.count }
    public var clearCount: Int { fields.filter { $0.action == .clear }.count }
    public var conflictCount: Int { fields.filter { $0.action == .conflict }.count }
    public var changed: Bool { !patch.isEmpty }
}

/// 未解析变量：定位到"哪张照片、哪个字段、缺哪个变量"。
public struct MetadataBatchUnresolved: Equatable, Sendable {
    public var photoId: String
    public var field: DescriptiveField
    public var variable: MetadataVariableUnresolved

    public init(photoId: String, field: DescriptiveField, variable: MetadataVariableUnresolved) {
        self.photoId = photoId
        self.field = field
        self.variable = variable
    }
}

/// 同补丁分组：一次 applyDescriptive 调用 = 一个撤销批次。
public struct MetadataBatchApplyGroup: Equatable, Sendable {
    public var photoIds: [String]
    public var patch: DescriptiveMetadata

    public init(photoIds: [String], patch: DescriptiveMetadata) {
        self.photoIds = photoIds
        self.patch = patch
    }
}

/// 整批预检结果。
public struct MetadataBatchEditPlan: Equatable, Sendable {
    public var photos: [MetadataBatchPhotoPlan]
    public var unresolved: [MetadataBatchUnresolved]
    public var groups: [MetadataBatchApplyGroup]

    public init(
        photos: [MetadataBatchPhotoPlan],
        unresolved: [MetadataBatchUnresolved],
        groups: [MetadataBatchApplyGroup]
    ) {
        self.photos = photos
        self.unresolved = unresolved
        self.groups = groups
    }

    public var writeCount: Int { photos.reduce(0) { $0 + $1.writeCount } }
    public var clearCount: Int { photos.reduce(0) { $0 + $1.clearCount } }
    public var conflictCount: Int { photos.reduce(0) { $0 + $1.conflictCount } }
    /// 有未解析变量或没有任何可写补丁 → 禁止提交。
    public var canApply: Bool { unresolved.isEmpty && !groups.isEmpty }
}

/// 多选字段的混合值检测（不默认覆盖的前提）。
public enum MetadataFieldMix {
    /// 空串/空数组/空联系人归一成 nil（与三态语义一致）。
    public static func normalized(_ value: XMPFieldValue?) -> XMPFieldValue? {
        guard let value, !value.isEmptyValue else { return nil }
        return value
    }

    /// 字段在多张照片之间是否存在差异（全 nil 或全同值 = 不 mixed）。
    public static func isMixed(_ field: DescriptiveField, across photos: [DescriptiveMetadata]) -> Bool {
        var values: [XMPFieldValue] = []
        for photo in photos {
            if let value = normalized(photo.value(for: field)) { values.append(value) }
        }
        guard let first = values.first else { return false }
        return values.contains { $0 != first }
    }

    /// 多张照片的共同值；mixed 或全空返回 nil。
    public static func commonValue(
        _ field: DescriptiveField,
        across photos: [DescriptiveMetadata]
    ) -> XMPFieldValue? {
        var values: [XMPFieldValue] = []
        for photo in photos {
            if let value = normalized(photo.value(for: field)) { values.append(value) }
        }
        guard let first = values.first else { return nil }
        guard values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 编辑器初值展示文本：mixed → nil（UI 显示"多个值"占位）；全空 → ""；
    /// 共同值 → text 原文 / list 用"、"连接 / 联系人摘要。
    public static func commonText(
        _ field: DescriptiveField,
        across photos: [DescriptiveMetadata]
    ) -> String? {
        guard !isMixed(field, across: photos) else { return nil }
        guard let value = commonValue(field, across: photos) else { return "" }
        switch value {
        case .text(let text): return text
        case .list(let items): return items.joined(separator: "、")
        case .contact(_): return nil
        }
    }
}

/// 批量预检 + 补丁分组唯一实现。
public enum MetadataBatchEditPlanner {
    /// 生成逐张预检与写入分组。
    ///
    /// - Parameters:
    ///   - edits: 仅包含用户动过的字段（.unchanged 会被忽略）；
    ///   - photos: 目标照片；顺序决定 {seq} 递增（调用方保证稳定/去重）；
    ///   - scope: client / sequenceStart；
    ///   - policy: 外部改动策略（keepExternal = 冲突不覆盖；overwrite = 覆盖）。
    public static func plan(
        edits: [DescriptiveField: MetadataBatchFieldEdit],
        photos: [MetadataBatchPhotoInput],
        scope: MetadataVariableScope = MetadataVariableScope(),
        policy: MetadataConflictPolicy = .keepExternal
    ) -> MetadataBatchEditPlan {
        var photoPlans: [MetadataBatchPhotoPlan] = []
        var unresolved: [MetadataBatchUnresolved] = []
        var groupIndexBySignature: [String: Int] = [:]
        var groups: [MetadataBatchApplyGroup] = []

        let activeEdits = DescriptiveField.allCases.filter { field in
            guard field != .contactInfo else { return false }
            switch edits[field] ?? .unchanged {
            case .unchanged: return false
            case .set(_), .clear: return true
            }
        }

        for photo in photos {
            var patch = DescriptiveMetadata()
            var fieldPlans: [MetadataBatchFieldPlan] = []
            for field in activeEdits {
                let edit = edits[field] ?? .unchanged
                let expanded = expand(
                    edit, field: field, photo: photo, scope: scope)
                if !expanded.unresolved.isEmpty {
                    for variable in expanded.unresolved {
                        unresolved.append(MetadataBatchUnresolved(
                            photoId: photo.photoId, field: field, variable: variable))
                    }
                    fieldPlans.append(MetadataBatchFieldPlan(
                        field: field, action: .unchanged, target: nil))
                    continue
                }
                let baseline = MetadataFieldMix.normalized(photo.disk.value(for: field))
                let cached = MetadataFieldMix.normalized(photo.cache.value(for: field))
                let target = MetadataFieldMix.normalized(expanded.value)
                let externallyModified = photo.diskKnown && baseline != cached
                let action = resolveAction(
                    target: target, baseline: baseline,
                    externallyModified: externallyModified, policy: policy)
                fieldPlans.append(MetadataBatchFieldPlan(
                    field: field, action: action, target: target))
                switch action {
                case .write:
                    if let target { patch.set(target, for: field) }
                case .clear:
                    patch.clear(field)
                case .unchanged, .conflict:
                    break
                }
            }
            let plan = MetadataBatchPhotoPlan(
                photoId: photo.photoId, fields: fieldPlans, patch: patch)
            photoPlans.append(plan)
            guard plan.changed, let signature = signature(for: patch) else { continue }
            if let index = groupIndexBySignature[signature] {
                groups[index].photoIds.append(photo.photoId)
            } else {
                groupIndexBySignature[signature] = groups.count
                groups.append(MetadataBatchApplyGroup(
                    photoIds: [photo.photoId], patch: patch))
            }
        }

        return MetadataBatchEditPlan(
            photos: photoPlans, unresolved: unresolved, groups: groups)
    }

    // MARK: - 单字段展开

    struct ExpandedEdit {
        var value: XMPFieldValue?
        var unresolved: [MetadataVariableUnresolved]
    }

    static func expand(
        _ edit: MetadataBatchFieldEdit,
        field: DescriptiveField,
        photo: MetadataBatchPhotoInput,
        scope: MetadataVariableScope
    ) -> ExpandedEdit {
        switch edit {
        case .unchanged:
            return ExpandedEdit(value: nil, unresolved: [])
        case .clear:
            return ExpandedEdit(value: nil, unresolved: [])
        case .set(let value):
            return expandValue(value, field: field, photo: photo, scope: scope)
        }
    }

    static func expandValue(
        _ value: XMPFieldValue,
        field: DescriptiveField,
        photo: MetadataBatchPhotoInput,
        scope: MetadataVariableScope
    ) -> ExpandedEdit {
        let variablePhoto = photo.variablePhoto
        switch value {
        case .contact(_):
            return ExpandedEdit(value: nil, unresolved: [])
        case .text(let text):
            let expansion = MetadataVariableEngine.expand(
                text, scope: scope, photo: variablePhoto, sequence: photo.sequence)
            if !expansion.unresolved.isEmpty {
                return ExpandedEdit(value: nil, unresolved: expansion.unresolved)
            }
            return ExpandedEdit(value: .text(expansion.text), unresolved: [])
        case .list(let items):
            var expandedItems: [String] = []
            var unresolved: [MetadataVariableUnresolved] = []
            for item in items {
                let expansion = MetadataVariableEngine.expand(
                    item, scope: scope, photo: variablePhoto, sequence: photo.sequence)
                unresolved.append(contentsOf: expansion.unresolved)
                let trimmed = expansion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { expandedItems.append(trimmed) }
            }
            if !unresolved.isEmpty {
                return ExpandedEdit(value: nil, unresolved: unresolved)
            }
            return ExpandedEdit(value: .list(expandedItems), unresolved: [])
        }
    }

    static func resolveAction(
        target: XMPFieldValue?,
        baseline: XMPFieldValue?,
        externallyModified: Bool,
        policy: MetadataConflictPolicy
    ) -> MetadataBatchFieldAction {
        // 外部改动且本次会写/清：默认不覆盖（与模板 keepExternal 同一语义）。
        let willChange = target != baseline
        if willChange, externallyModified, policy == .keepExternal {
            return .conflict
        }
        guard willChange else { return .unchanged }
        if target == nil { return .clear }
        return .write
    }

    /// 补丁签名（同签名合组）。排序键编码，跨进程/跨调用稳定。
    static func signature(for patch: DescriptiveMetadata) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(patch)
            return data.base64EncodedString()
        } catch {
            return nil
        }
    }
}

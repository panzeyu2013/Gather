// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataTemplateVariables.swift
// Wave2 收尾 task-22：模板侧变量展开（与批量文案共用 MetadataVariableEngine）。
//
// 语义：
// - 只展开 DescriptiveMetadata 的 text/list 字段；contactInfo 是结构，不解析变量；
// - 逐字段检测：某字段只要有一个占位符未解析，该字段整体不写（不写半截文本），
//   并在 issues 里按字段记录（预览逐字段列出、apply 拒绝整批写入）；
// - 空串/空列表保持"显式清空"语义：空文本不含占位符，展开后仍是空；
// - scope 为 nil = 不展开（内联编辑/调用方已展开的路径，如批量直改面板）；
//   模板套用永远传非 nil scope（client 可空，{client} 缺失会进 issues）。
//
// 为什么放在 Application 而不是 UI：preview 与 apply 必须调用**同一个函数**，
// 否则会出现"预览显示展开值、写盘写原文"的漂移（本波的核心验收点）。
import Foundation
import GatherProtocol

/// 某照片某字段的未解析变量（内部计划用；API DTO 见 MetadataTemplateUnresolvedVariable）。
public struct MetadataTemplateVariableIssue: Equatable, Sendable {
    public var field: DescriptiveField
    public var variable: MetadataVariableUnresolved

    public init(field: DescriptiveField, variable: MetadataVariableUnresolved) {
        self.field = field
        self.variable = variable
    }
}

public struct MetadataTemplateVariableExpansion: Equatable, Sendable {
    /// 可安全写入的字段（未解析字段已被剔除）。
    public var fields: DescriptiveMetadata
    public var issues: [MetadataTemplateVariableIssue]

    public init(fields: DescriptiveMetadata, issues: [MetadataTemplateVariableIssue]) {
        self.fields = fields
        self.issues = issues
    }

    public var isResolved: Bool { issues.isEmpty }
}

public enum MetadataTemplateVariables {
    /// 展开模板字段（纯函数；读写同源）。
    public static func expand(
        _ fields: DescriptiveMetadata,
        scope: MetadataVariableScope?,
        photo: MetadataVariablePhoto,
        sequence: Int
    ) -> MetadataTemplateVariableExpansion {
        guard let scope else {
            return MetadataTemplateVariableExpansion(fields: fields, issues: [])
        }
        var output = DescriptiveMetadata()
        var issues: [MetadataTemplateVariableIssue] = []
        for field in fields.explicitlySetFields {
            guard let value = fields.value(for: field) else { continue }
            switch value {
            case .contact(let contact):
                output.set(.contact(contact), for: field)
            case .text(let text):
                let expansion = MetadataVariableEngine.expand(
                    text, scope: scope, photo: photo, sequence: sequence)
                let blocking = blockingVariables(expansion.unresolved)
                if !blocking.isEmpty {
                    issues.append(contentsOf: blocking.map {
                        MetadataTemplateVariableIssue(field: field, variable: $0)
                    })
                    continue
                }
                // 未知名字不算变量：保留原文（旧模板里的 {2026}/{note} 不被误判）。
                output.set(.text(expansion.text), for: field)
            case .list(let items):
                var expandedItems: [String] = []
                var fieldIssues: [MetadataTemplateVariableIssue] = []
                for item in items {
                    let expansion = MetadataVariableEngine.expand(
                        item, scope: scope, photo: photo, sequence: sequence)
                    let blocking = blockingVariables(expansion.unresolved)
                    if !blocking.isEmpty {
                        fieldIssues.append(contentsOf: blocking.map {
                            MetadataTemplateVariableIssue(field: field, variable: $0)
                        })
                        continue
                    }
                    expandedItems.append(expansion.text)
                }
                if !fieldIssues.isEmpty {
                    issues.append(contentsOf: fieldIssues)
                    continue
                }
                output.set(.list(expandedItems), for: field)
            }
        }
        return MetadataTemplateVariableExpansion(fields: output, issues: issues)
    }

    /// 只有"引擎认识但值缺失"的占位符才阻断写入；不认识的 {xxx} 按字面量保留，
    /// 避免旧模板里正文自带的 {2026}/{note} 被误判为变量而拒绝整批套用。
    private static func blockingVariables(
        _ unresolved: [MetadataVariableUnresolved]
    ) -> [MetadataVariableUnresolved] {
        unresolved.filter { MetadataVariableEngine.supportedNames.contains($0.name) }
    }

    /// 供 apply 失败消息使用的稳定前缀；UI 在 MetadataDisplay.localizedFailure 里
    /// 解析 field=...; variable=...; file=... 生成可读文案（不新增错误码）。
    public static let unresolvedMessagePrefix = "METADATA_VARIABLE_UNRESOLVED: "

    public static func unresolvedMessage(
        filename: String, field: DescriptiveField, variable: MetadataVariableUnresolved
    ) -> String {
        return unresolvedMessagePrefix
            + "field=" + field.rawValue + ";"
            + "variable=" + variable.raw + ";"
            + "file=" + filename
    }
}

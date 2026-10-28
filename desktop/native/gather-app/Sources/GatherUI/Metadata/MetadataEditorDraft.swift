// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataEditorDraft.swift
// P0 / B2：单张元数据编辑器的"差异计算"（纯函数，直测）。
//
// 编辑器只提交用户改过的字段：空白 = 显式清空，未改 = 不触碰。把这段语义从
// SwiftUI 视图里抽出来，测试才能覆盖"只写改动字段""空值清空""contact 整块替换"。
import Foundation
import GatherProtocol

enum MetadataEditorDraft {
    /// 改动过的字段数（contact 整块算一次）。
    static func changedFieldCount(
        values: [DescriptiveField: String],
        initial: [DescriptiveField: String],
        contact: DescriptiveContact,
        initialContact: DescriptiveContact
    ) -> Int {
        var count = 0
        for field in DescriptiveField.allCases where field != .contactInfo {
            if normalized(values[field]) != normalized(initial[field]) { count += 1 }
        }
        if contact != initialContact { count += 1 }
        return count
    }

    /// 编辑结果：字段补丁 + 显式清空的联系人成员。
    struct Patch: Equatable {
        var fields: DescriptiveMetadata
        /// 原来有值、现在被用户清空的联系人成员（DescriptiveContact.members 的 key）。
        var clearedContactMembers: [String]
    }

    /// 生成三态补丁；nil = 没有任何改动（调用方禁用以按钮）。
    static func changes(
        values: [DescriptiveField: String],
        initial: [DescriptiveField: String],
        contact: DescriptiveContact,
        initialContact: DescriptiveContact
    ) -> Patch? {
        var edited = DescriptiveMetadata()
        var clearedMembers: [String] = []
        for field in DescriptiveField.allCases where field != .contactInfo {
            let before = normalized(initial[field])
            let after = normalized(values[field])
            if after == before { continue }
            if after.isEmpty {
                edited.clear(field)
            } else if XMPFieldDescriptor.descriptor(for: field)?.isList == true {
                let items = after.split(whereSeparator: { $0 == "、" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                edited.set(.list(items), for: field)
            } else {
                edited.set(.text(after), for: field)
            }
        }
        if contact != initialContact {
            edited.contactInfo = contact
            // contact 结构里 nil 既可能是"清空"也可能是"不触碰"：只有"原本有值、
            // 现在为空"的成员才算显式清空，服务端据此判断 JPEG 内嵌残留。
            clearedMembers = DescriptiveContact.members.map(\.key).filter { key in
                let before = initialContact.memberValue(key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let after = contact.memberValue(key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !before.isEmpty && after.isEmpty
            }
        }
        guard !edited.isEmpty else { return nil }
        return Patch(fields: edited, clearedContactMembers: clearedMembers)
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// desktop/native/gather-core/Sources/GatherProtocol/API/AlbumAPI.swift
// Cut 1 / 阶段 1A：智能相册域协议（5 个方法）。
//
// 职责：相册创建/列表/更新/删除、按相册取照片（详情+分页）。
// 对应命令（6 条）：album.create / list / update / delete / get_photos；
// album.get 已按 R4 删除（get_photos 复用同一详情构造）。
// 校验归属：
// - create/update 复用 AlbumCreateParams/AlbumUpdateParams；criteria 的类型在
//   解码期失败，SQL 可构建性由实现调用 FilterEngine 校验；
// - delete 使用 Confirmed<T>；ALBUM_NOT_FOUND 由实现映射；
// - get_photos 的 limit 1...500 缺省 100 / offset >= 0 由 PageRequest.album 归一化。
//
// P1 下一波 §3.8（2026-10-30）：**不新增协议域**。手动集合与堆栈同属"策展容器"，
// 与 smart_albums 是同一批用户动作（多选 → 存成容器），因此直接挂在 AlbumAPI 上，
// 而不是新增 CollectionAPI / StackAPI（那会让 AppServices 的 16 域、全部 Stub 与
// Preview 实现一起改）。全部新方法在下面的协议扩展里给出默认实现：
//   - 读方法返回空数组；
//   - 写方法抛 INVALID_PARAM（field = 具体入口名）——默认实现是"未实现"的显式
//     失败，不会静默成功；LiveAlbumAPI 全部覆写。
// 这样既有的测试桩 / 预览实现（只需 5 个旧方法）继续编译通过。

import Foundation

public protocol AlbumAPI: Sendable {
    func create(_ input: AlbumCreateParams) async throws -> SmartAlbumDetailData
    func list() async throws -> [SmartAlbumData]
    func update(_ input: AlbumUpdateParams) async throws
    func delete(_ input: Confirmed<AlbumDeleteInput>) async throws
    func photos(_ query: AlbumPhotosQuery) async throws -> GlobalPhotoPage

    // MARK: - 集合（§3.8.1）

    /// 会话内的手动集合列表（按 sort_order, name；itemCount 由实现填充）。
    func collections(_ sessionId: String) async throws -> [CollectionSummary]
    /// 集合成员（按 position 升序；filepath/filename 供网格直接渲染）。
    func collectionItems(_ collectionId: String) async throws -> [CollectionMember]
    /// 建集合；同名（同会话）由实现转 ALBUM_NAME_CONFLICT 语义（INVALID_PARAM + field=name）。
    func createCollection(_ input: CollectionCreateInput) async throws -> CollectionSummary
    func renameCollection(_ input: CollectionRenameInput) async throws
    func deleteCollection(_ input: Confirmed<CollectionDeleteInput>) async throws
    /// 尾部追加（按 photoIds 顺序、去重），返回新增条数。
    func addCollectionItems(_ input: CollectionItemsInput) async throws -> Int
    /// 移除成员，返回实际删除条数。
    func removeCollectionItems(_ input: CollectionItemsInput) async throws -> Int
    /// 显式顺序（写 1..n，事务内一次完成）。
    func reorderCollectionItems(_ input: CollectionReorderInput) async throws
    /// 单行拖拽（position 取前后中点；间隙耗尽才事务内重排）。
    func moveCollectionItem(_ input: CollectionMoveInput) async throws
    /// Wave2（task-15）：并/交/差 —— 新建一个物化集合，成员 = 运算结果。
    /// 破坏性（写库）：调用点用 Confirmed 收口。
    func combineCollections(_ input: Confirmed<CollectionCombineInput>) async throws -> CollectionSummary

    // MARK: - 堆栈（§3.8.2）

    func stacks(_ sessionId: String) async throws -> [StackSummary]
    func stackMembers(_ stackId: String) async throws -> [CollectionMember]
    /// 会话的折叠视图（每个堆栈一条，含按 position 排序的成员）。
    func stackFolds(_ sessionId: String) async throws -> [StackFold]
    func createStack(_ input: StackCreateInput) async throws -> StackSummary
    func updateStack(_ input: StackUpdateInput) async throws
    func deleteStack(_ input: Confirmed<StackDeleteInput>) async throws
    func addStackMembers(_ input: StackMembersInput) async throws -> Int
    func removeStackMembers(_ input: StackMembersInput) async throws -> Int
}

// MARK: - 默认实现（既有 Stub / Preview 不必实现新方法）

public extension AlbumAPI {
    func collections(_ sessionId: String) async throws -> [CollectionSummary] { [] }
    func collectionItems(_ collectionId: String) async throws -> [CollectionMember] { [] }
    func createCollection(_ input: CollectionCreateInput) async throws -> CollectionSummary {
        throw AlbumAPIUnavailable.curationNotImplemented("createCollection")
    }
    func renameCollection(_ input: CollectionRenameInput) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("renameCollection")
    }
    func deleteCollection(_ input: Confirmed<CollectionDeleteInput>) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("deleteCollection")
    }
    func addCollectionItems(_ input: CollectionItemsInput) async throws -> Int {
        throw AlbumAPIUnavailable.curationNotImplemented("addCollectionItems")
    }
    func removeCollectionItems(_ input: CollectionItemsInput) async throws -> Int {
        throw AlbumAPIUnavailable.curationNotImplemented("removeCollectionItems")
    }
    func reorderCollectionItems(_ input: CollectionReorderInput) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("reorderCollectionItems")
    }
    func moveCollectionItem(_ input: CollectionMoveInput) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("moveCollectionItem")
    }
    func combineCollections(
        _ input: Confirmed<CollectionCombineInput>
    ) async throws -> CollectionSummary {
        throw AlbumAPIUnavailable.curationNotImplemented("combineCollections")
    }

    func stacks(_ sessionId: String) async throws -> [StackSummary] { [] }
    func stackMembers(_ stackId: String) async throws -> [CollectionMember] { [] }
    func stackFolds(_ sessionId: String) async throws -> [StackFold] { [] }
    func createStack(_ input: StackCreateInput) async throws -> StackSummary {
        throw AlbumAPIUnavailable.curationNotImplemented("createStack")
    }
    func updateStack(_ input: StackUpdateInput) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("updateStack")
    }
    func deleteStack(_ input: Confirmed<StackDeleteInput>) async throws {
        throw AlbumAPIUnavailable.curationNotImplemented("deleteStack")
    }
    func addStackMembers(_ input: StackMembersInput) async throws -> Int {
        throw AlbumAPIUnavailable.curationNotImplemented("addStackMembers")
    }
    func removeStackMembers(_ input: StackMembersInput) async throws -> Int {
        throw AlbumAPIUnavailable.curationNotImplemented("removeStackMembers")
    }
}

/// 默认实现的"未实现"错误工厂（只沿用既有错误码 INVALID_PARAM，不新增全局码）。
///
/// 单独放一个 enum 而不是在扩展里内联，是为了让文案与 field 命名只有一处，
/// 且能被 LiveAlbumAPI 的域测试直接断言。
public enum AlbumAPIUnavailable {
    public static func curationNotImplemented(_ entry: String) -> GatherError {
        GatherError.invalidParameter(
            field: entry,
            reason: "curation API is not implemented by this AlbumAPI implementation"
        )
    }
}

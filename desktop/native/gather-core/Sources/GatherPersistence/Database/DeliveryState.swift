// desktop/native/gather-core/Sources/GatherPersistence/Database/DeliveryState.swift
// Cut 2 / S2：统一 delivery 模型的**状态机真相源**（draft §4.2 / §5，D-013）。
//
// 分层约定（draft §4.1）：
// - DB 的 CHECK 只兜「非法字符串」（deliveries.status / delivery_items.status / module）；
// - **转移合法性只在这里定义**，Repo 的每个写状态入口都必须先经 canTransition；
//     非法转移抛 DeliveryRepoError.illegalTransition，绝不静默改写。
//
// 与旧 MetadataOutboxStatus 的差异（精简项）：
// 1. 去掉历史遗留的 clean/cleaned 双终态中的 clean；deliveries 只保留 7 值，
//    cleaned 仍保留（CHECK 已允许），但**只有 synced → cleaned** 一条入边，
//    用于将来「软删除/审计型清理」；当前 cleanup 事务仍是物理删除（见 draft §5.5）。
// 2. 不再保留「clean → synced」这类旧数据归一化迁移：V1 是新建库，不迁移旧行。
// 3. written/failed/conflict/synced → pending 保留（D-031）：新输入把旧状态重新打开，
//    否则同一条侧车在第二次编辑时只能新建行，违反 xmp_path UNIQUE；cleaned 是审计终态，
//    不允许回到 pending（要重写就新建行）。

import Foundation

/// deliveries.status 的合法值（与 SchemaV1 的 CHECK 双向一致）。
///
/// 生命周期（正常路径）：
///   pending → writing → written → synced →（cleanup 删除；软删场景为 cleaned）
/// 异常路径：
///   writing → failed（写失败）→ writing（重试）
///   任意活跃态 → conflict（外部改盘）→ pending/writing（裁决后重入队）
public enum DeliveryStatus: String, Codable, CaseIterable, Equatable, Sendable {
    /// 有未落盘的输入，等待写入。
    case pending
    /// 已抢到写租约（非终态；租约恢复必须把它归位）。
    case writing
    /// 文件已写成功，等待所有关联会话确认。
    case written
    /// 所有关联会话已确认（终态，只有新输入能重新打开）。
    case synced
    /// 写入失败（可重试）。
    case failed
    /// 外部修改：本地输入与盘上内容冲突，待裁决。
    case conflict
    /// 清理后的审计终态（当前 cleanup 是物理删除，此值预留）。
    case cleaned

    /// 合法迁移表（唯一真相源）。
    ///
    /// 自迁移（x → x）一律允许：所有写入口都是「带 revision/status CAS 的原子 UPDATE」，
    /// 重放同一请求必须幂等而不是抛错（旧表的语义同样包含自迁移）。
    public func canTransition(to next: DeliveryStatus) -> Bool {
        switch (self, next) {
        // 入队态：可开始写、可被外部改盘、可失败；重复入队幂等。
        case (.pending, .pending), (.pending, .writing), (.pending, .failed), (.pending, .conflict):
            return true
        // 写租约态：成功、失败、冲突、以及「新 revision 到达 → 回到 pending」。
        case (.writing, .writing), (.writing, .written), (.writing, .failed),
             (.writing, .conflict), (.writing, .pending):
            return true
        // 已落盘待确认：可确认、可被新输入重新打开、可冲突。
        case (.written, .written), (.written, .synced), (.written, .pending), (.written, .conflict):
            return true
        // 已确认：新输入重新打开、外部改盘仍是冲突、清理为审计终态。
        case (.synced, .synced), (.synced, .pending), (.synced, .conflict), (.synced, .cleaned):
            return true
        // 失败：重试回 writing、重新入队、再次失败、以及裁决为冲突。
        case (.failed, .failed), (.failed, .writing), (.failed, .pending), (.failed, .conflict):
            return true
        // 冲突裁决：只允许重新入队（pending）或直接重写（writing）。
        case (.conflict, .conflict), (.conflict, .pending), (.conflict, .writing):
            return true
        // 审计终态：不可复活（要重写就新建行）。
        case (.cleaned, .cleaned):
            return true
        default:
            return false
        }
    }

    /// 是否终态（终态不允许被 cleanup 之外的状态入口改写，见上表）。
    public var isTerminal: Bool { self == .synced || self == .cleaned }
}

/// delivery_items.status 的合法值（与 SchemaV1 的 CHECK 双向一致）。
///
/// item 是「某张照片 × 某模块」的交付项：文件写成功后逐项从 pending → written，
/// 会话确认后 written → synced；新输入到达时 synced/written → pending 重新打开。
public enum DeliveryItemStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case written
    case synced
    case failed

    /// 合法迁移表（唯一真相源）；自迁移用于幂等重放。
    public func canTransition(to next: DeliveryItemStatus) -> Bool {
        switch (self, next) {
        case (.pending, .pending), (.pending, .written), (.pending, .failed):
            return true
        // 已写：可确认；新输入可重新打开；写盘复查失败可标 failed。
        case (.written, .written), (.written, .synced), (.written, .pending), (.written, .failed):
            return true
        // 已确认：只有新输入能重新打开（重新排队时会新建/更新同一 UNIQUE 行）。
        case (.synced, .synced), (.synced, .pending):
            return true
        // 失败：可重试（pending/written）或再次失败。
        case (.failed, .failed), (.failed, .pending), (.failed, .written):
            return true
        default:
            return false
        }
    }

    public var isTerminal: Bool { self == .synced }
}

/// delivery_items.module 的合法值（与 SchemaV1 的 CHECK 双向一致）。
///
/// 归属从旧模型的 patch_json.__owners__（字段 → 模块 JSON）提升为**行**：
/// 一个 (delivery, photo, module) 三元组就是一条归属事实（draft §5.3）。
public enum DeliveryModule: String, Codable, CaseIterable, Equatable, Sendable {
    case culling
    case faceKeyword = "face-keyword"
    case similarity
    case template
    case metadata

    // MARK: - 旧写回模块名 → 交付模块（Cut 2 / S5c-2b-2）

    /// 旧写回模块名（WritebackService / writeback_items.module）→ 交付模块。
    ///
    /// 落库值只取 SchemaV1 delivery_items.module CHECK 的真实值
    /// （culling / face-keyword / similarity / template / metadata），不新增非法值。
    /// "face_kw" 是旧写回层的历史别名（TS mutation-source 命名），映射后仍写
    /// "face-keyword"；"face-keyword" 也接受，便于调用方按落库值传入。
    public init?(writebackModule: String) {
        switch writebackModule {
        case "culling": self = .culling
        case "face_kw", "face-keyword": self = .faceKeyword
        case "similarity": self = .similarity
        case "template": self = .template
        case "metadata": self = .metadata
        default: return nil
        }
    }

    /// 反向映射：交付模块 → 旧写回层模块名（日志/过渡适配用）。
    /// faceKeyword 回旧名 "face_kw"；其余与 SchemaV1 的落库值一致。
    public var writebackModuleName: String {
        switch self {
        case .culling: return "culling"
        case .faceKeyword: return "face_kw"
        case .similarity: return "similarity"
        case .template: return "template"
        case .metadata: return "metadata"
        }
    }
}

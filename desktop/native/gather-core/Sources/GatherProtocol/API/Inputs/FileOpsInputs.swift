// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/FileOpsInputs.swift
// Wave5（Batch4 / task-19）：照片文件级操作输入/输出 DTO（批量重命名 + 移动到文件夹）。
//
// 边界（与 30 号 §2.1 F2 / 05 号 §2 一致）：
// - 只做「改名 / 移动」，**不做删除、不做重命名文件夹**；
// - 重命名复用摄取的重命名 token 引擎（{yyyy}/{MM}/{dd}/{HH}/{mm}/{ss}/{orig}/{ext}
//   /{camera}/{seq:N}），本文件只承载形状，不实现渲染（渲染在 Application 层）；
// - 破坏性入口（写盘 + 改 photos.filepath）一律 Confirmed 门禁（photoIds/targetRoot
//   都来自用户显式选择，取消分支不得构造 Confirmed）。
//
// 为什么放进 PhotoAPI 而不是新开第 17 个域：PhotoAPI 已注册在组合根，
// 且这三个命令的读模型（photoId → 路径）就属照片域，末端仍是 photos 行。
import Foundation

// MARK: - 冲突策略（改名/移动共用）

/// 目标已存在时的处置口径。
///
/// - skip：跳过该张（计数进 skipped），不动磁盘；
/// - replace：**覆盖**目标（先把既有目标改名成 `<name>.gather-replaced-<uuid>` 备份，
///   成功收尾后删除；失败恢复原目标。绝不覆盖同批选中的其它照片）；
/// - coexist：目标已存在 → 自动加 `-2`/`-3` 后缀（同 RejectedMover 的撞名策略）。
public enum PhotoFileConflictPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case skip
    case replace
    case coexist
}

// MARK: - 预览（只读）

/// 重命名预览的单项冲突分类。
public enum PhotoRenameConflict: String, Codable, CaseIterable, Equatable, Sendable {
    /// 无冲突：按当前模板可直接改名。
    case none
    /// 目标路径已被磁盘上的其它文件占用（不含本批将被移走的源文件）。
    case targetExists
    /// 本批内两条照片渲染出同一个目标路径（模板缺 {seq}/{orig} 等区分项）。
    case duplicateTarget
    /// 模板里有未知/未闭合 token，或渲染结果不是合法文件名。
    case invalidToken
    /// 源文件不在磁盘 / 路径不是绝对路径（登记缺失）。
    case missingSource
    /// photoId 不属于该工作区。
    case notInSession
}

/// 只读预览请求（不写盘、不改库）。
public struct PhotoRenamePreviewInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]
    /// 重命名模板（摄取同一套 token 引擎）。
    public var template: String

    public init(sessionId: String, photoIds: [String], template: String) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.template = template
    }
}

/// 预览逐项结果：旧 → 新、冲突分类、随行 sidecar（XMP）的新旧路径。
public struct PhotoRenamePreviewItem: Codable, Equatable, Sendable {
    public var photoId: String
    public var oldPath: String
    public var oldFilename: String
    /// 冲突项按空串（没有可信目标）；调用方不得把空串当真实路径用。
    public var newPath: String
    public var newFilename: String
    public var conflict: PhotoRenameConflict
    /// 磁盘上存在同名 sidecar 时才非 nil。
    public var sidecarPath: String?
    public var newSidecarPath: String?

    public init(
        photoId: String,
        oldPath: String,
        oldFilename: String,
        newPath: String = "",
        newFilename: String = "",
        conflict: PhotoRenameConflict = .none,
        sidecarPath: String? = nil,
        newSidecarPath: String? = nil
    ) {
        self.photoId = photoId
        self.oldPath = oldPath
        self.oldFilename = oldFilename
        self.newPath = newPath
        self.newFilename = newFilename
        self.conflict = conflict
        self.sidecarPath = sidecarPath
        self.newSidecarPath = newSidecarPath
    }
}

public struct PhotoRenamePreview: Codable, Equatable, Sendable {
    public var sessionId: String
    public var items: [PhotoRenamePreviewItem]
    /// 模板里无法识别的 token（去重保序）：非空时整批不可执行（宁可不改名也不落错名）。
    public var invalidTokens: [String]
    /// 冲突项数（items 里 conflict != .none 的条数）。
    public var conflicts: Int
    /// 可直接改名的条数（conflict == .none）。
    public var renameable: Int
    /// 非 nil = 该通道未接线（默认实现），UI 明确提示而不是画假成功。
    public var unavailableReason: String?

    public init(
        sessionId: String,
        items: [PhotoRenamePreviewItem] = [],
        invalidTokens: [String] = [],
        conflicts: Int = 0,
        renameable: Int = 0,
        unavailableReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.items = items
        self.invalidTokens = invalidTokens
        self.conflicts = conflicts
        self.renameable = renameable
        self.unavailableReason = unavailableReason
    }
}

// MARK: - 执行（破坏性：写盘 + 改 photos.filepath）

/// 批量重命名请求（调用点必须经 Confirmed 收口）。
public struct PhotoRenameInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]
    public var template: String
    public var conflictPolicy: PhotoFileConflictPolicy

    public init(
        sessionId: String,
        photoIds: [String],
        template: String,
        conflictPolicy: PhotoFileConflictPolicy = .coexist
    ) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.template = template
        self.conflictPolicy = conflictPolicy
    }
}

/// 单条失败原因（逐项可见，绝不静默部分成功）。
public struct PhotoFileOpFailure: Codable, Equatable, Sendable {
    public var photoId: String
    /// 失败涉及的路径（旧路径；替换冲突时会写目标路径）。
    public var path: String
    public var message: String

    public init(photoId: String, path: String, message: String) {
        self.photoId = photoId
        self.path = path
        self.message = message
    }
}

public struct PhotoRenameResult: Codable, Equatable, Sendable {
    public var renamed: Int
    public var skipped: Int
    public var failed: [PhotoFileOpFailure]
    /// photoId → 新绝对路径（仅成功项；UI 就地回显/选中收敛用）。
    public var newPaths: [String: String]

    public init(
        renamed: Int = 0,
        skipped: Int = 0,
        failed: [PhotoFileOpFailure] = [],
        newPaths: [String: String] = [:]
    ) {
        self.renamed = renamed
        self.skipped = skipped
        self.failed = failed
        self.newPaths = newPaths
    }
}

/// 移动到文件夹请求（调用点必须经 Confirmed 收口）。
public struct PhotoMoveInput: Codable, Equatable, Sendable {
    public var sessionId: String
    public var photoIds: [String]
    /// 目标目录（用户经 NSOpenPanel 选的绝对路径；服务端做标准化与禁根校验）。
    public var destinationRoot: String
    public var conflictPolicy: PhotoFileConflictPolicy

    public init(
        sessionId: String,
        photoIds: [String],
        destinationRoot: String,
        conflictPolicy: PhotoFileConflictPolicy = .coexist
    ) {
        self.sessionId = sessionId
        self.photoIds = photoIds
        self.destinationRoot = destinationRoot
        self.conflictPolicy = conflictPolicy
    }
}

public struct PhotoMoveResult: Codable, Equatable, Sendable {
    public var moved: Int
    public var skipped: Int
    public var failed: [PhotoFileOpFailure]
    public var newPaths: [String: String]

    public init(
        moved: Int = 0,
        skipped: Int = 0,
        failed: [PhotoFileOpFailure] = [],
        newPaths: [String: String] = [:]
    ) {
        self.moved = moved
        self.skipped = skipped
        self.failed = failed
        self.newPaths = newPaths
    }
}

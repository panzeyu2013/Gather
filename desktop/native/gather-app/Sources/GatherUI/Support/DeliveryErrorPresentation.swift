// desktop/native/gather-app/Sources/GatherUI/Support/DeliveryErrorPresentation.swift
// Delivery P2：GatherDelivery 新增的 11 个错误码在 UI 侧的唯一映射。
//
// 为什么单独一张表、不并进 GatherLocalization.errorMessages：
// - 这 11 个码没有进 GatherErrorCode（协议层枚举），并进 errorMessages 会被
//   ErrorLocalizationCoverageTests 的「文案表不得含枚举之外的码」判红；
// - 它们只出现在 DeliveryCleanupSummary / DeliveryReplaySummary 的 errors 字符串里，
//   由 CommandError / APIErrorPresentation 的码形漏斗识别，不需要协议枚举。
// L10n.resolvedTemplate 会同时查 errorMessages 与本表，因此所有既有错误文案出口
// （CommandErrorText / APIErrorPresentation / CullingViewModel.funnelErrorText）
// 自动支持这些码，无需各自复制分支。
//
// 文案与恢复动作的边界：invalidBackup 一行不会自动重试成功（fail-closed 是安全
// 方向），所以文案明确写「仅重试不会自愈」+ 修复受控备份命名的步骤；incompleteItems
// 则指向对应模块，处理完未完成项后重试。两者都不是「永久卡死且无说明」。
import Foundation

/// 交付 P2 错误的用户恢复动作。只描述下一步，不直接执行命令。
public enum DeliveryErrorRecovery: String, CaseIterable, Sendable, Equatable {
    /// 修复现场后重试同一操作。
    case retry
    /// 先处理同一交付上未完成/失败/冲突的 XMP 项目，再重试。
    case resolveItems
    /// 另一路 replay 正在处理同一 intent；无需操作，稍后刷新。
    case waitForOtherReplay
    /// 备份路径/文件不符合受控格式；仅重试不会自愈，需先修复备份。
    case repairBackup

    /// 动作标题（渲染期按当前语言解析；供页面按钮/tooltip 使用）。
    public func title(with l10n: L10n) -> String {
        switch self {
        case .retry: return l10n("重试")
        case .resolveItems: return l10n("先处理未完成项")
        case .waitForOtherReplay: return l10n("稍后刷新")
        case .repairBackup: return l10n("检查并修复备份")
        }
    }
}

/// 单个错误码的展示信息。
public struct DeliveryErrorInfo: Sendable, Equatable {
    public let code: String
    /// 中文模板（同时是 en.lproj 的 key；L10n 先按当前语言查表再插值）。
    public let template: String
    public let recovery: DeliveryErrorRecovery
    /// false = 原样重试不会改变结果，页面不应只给一个「重试」按钮。
    public let retryableAsIs: Bool

    public init(
        code: String,
        template: String,
        recovery: DeliveryErrorRecovery,
        retryableAsIs: Bool
    ) {
        self.code = code
        self.template = template
        self.recovery = recovery
        self.retryableAsIs = retryableAsIs
    }
}

public enum DeliveryErrorPresentation {
    /// 6 个 DeliveryBackupPath 细分码 + INVALID 兜底 + cleanup/finalize 包装码 +
    /// finalize 未完成项 + replay 抢占。顺序固定，便于 parity 测试与文档引用。
    public static let allCodes: [String] = [
        "XMP_BACKUP_PATH_EMPTY_XMP",
        "XMP_BACKUP_PATH_TRAVERSAL",
        "XMP_BACKUP_PATH_NOT_SIBLING",
        "XMP_BACKUP_PATH_UNEXPECTED_NAME",
        "XMP_BACKUP_PATH_SYMLINK",
        "XMP_BACKUP_PATH_NOT_REGULAR_FILE",
        "XMP_BACKUP_PATH_INVALID",
        "XMP_CLEANUP_BACKUP_PATH_INVALID",
        "XMP_FINALIZE_BACKUP_PATH_INVALID",
        "XMP_FINALIZE_INCOMPLETE_ITEMS",
        "XMP_CLEANUP_REPLAY_CLAIMED",
    ]

    private static let table: [String: DeliveryErrorInfo] = [
        "XMP_BACKUP_PATH_EMPTY_XMP": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_EMPTY_XMP",
            template: "交付记录缺少 XMP 路径，无法校验备份位置。请重新索引该照片后重试清理；若仍失败，请保留现场并联系支持。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_TRAVERSAL": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_TRAVERSAL",
            template: "备份路径包含上级目录（..），Gather 已拒绝操作。请把备份移回照片所在目录并恢复受控命名后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_NOT_SIBLING": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_NOT_SIBLING",
            template: "备份文件不在照片的 XMP 所在目录，Gather 已拒绝操作。请把备份移回该目录后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_UNEXPECTED_NAME": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_UNEXPECTED_NAME",
            template: "备份文件名不符合 Gather 的受控命名（应为照片的 XMP 文件名加 .gather-backup- 前缀）。请把备份改回该命名后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_SYMLINK": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_SYMLINK",
            template: "备份是符号链接，Gather 不会跟随链接操作。请把链接替换为真实的备份文件后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_NOT_REGULAR_FILE": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_NOT_REGULAR_FILE",
            template: "备份不是常规文件（可能是目录或设备），Gather 已拒绝操作。请恢复为普通备份文件后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_BACKUP_PATH_INVALID": DeliveryErrorInfo(
            code: "XMP_BACKUP_PATH_INVALID",
            template: "备份路径未通过安全校验，Gather 不会操作任何文件。请检查照片旁的 .xmp 与 .gather-backup-* 文件后再试。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_CLEANUP_BACKUP_PATH_INVALID": DeliveryErrorInfo(
            code: "XMP_CLEANUP_BACKUP_PATH_INVALID",
            template: "清理已停止：该交付的备份路径未通过安全校验，Gather 没有恢复或删除任何文件。仅重试不会自愈；请先把备份修复为受控命名并放回照片目录，再重试清理。若无法修复，请保留现场并联系支持。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_FINALIZE_BACKUP_PATH_INVALID": DeliveryErrorInfo(
            code: "XMP_FINALIZE_BACKUP_PATH_INVALID",
            template: "结束同步已停止：该交付的备份路径未通过安全校验，Gather 保留了交付记录与备份文件。仅重试不会自愈；请先把备份修复为受控命名并放回照片目录，再重试结束同步。若无法修复，请保留现场并联系支持。",
            recovery: .repairBackup,
            retryableAsIs: false),
        "XMP_FINALIZE_INCOMPLETE_ITEMS": DeliveryErrorInfo(
            code: "XMP_FINALIZE_INCOMPLETE_ITEMS",
            template: "结束同步已停止：该交付仍有未完成的 XMP 项目。请先在对应模块完成写回或处理冲突，再重试结束同步；重试不会跳过这些项目。",
            recovery: .resolveItems,
            retryableAsIs: false),
        "XMP_CLEANUP_REPLAY_CLAIMED": DeliveryErrorInfo(
            code: "XMP_CLEANUP_REPLAY_CLAIMED",
            template: "另一路清理回放正在处理同一项目，本次已跳过且未产生失败。无需操作；稍后刷新状态，若项目仍停留再重试清理。",
            recovery: .waitForOtherReplay,
            retryableAsIs: true),
    ]

    public static func info(for raw: String) -> DeliveryErrorInfo? {
        guard let code = code(in: raw) else { return nil }
        return table[code]
    }

    /// 从 `CODE` / `CODE: 参数` / `CODE::p1` 形态抽出本表收录的码；不是本表码返回 nil。
    public static func code(in raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let head = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? raw
        let code = head.components(separatedBy: "::")[0]
        return table[code] != nil ? code : nil
    }

    /// 供 L10n 解析：只返回模板，不做本地化/插值。
    static func template(for code: String) -> String? {
        table[code]?.template
    }

    /// 所有模板（中文 key）；LocalizationParityTests 用它登记动态 key。
    public static var messageKeys: [String] {
        allCodes.compactMap { table[$0]?.template }
    }

    public static func recovery(for raw: String) -> DeliveryErrorRecovery? {
        info(for: raw)?.recovery
    }

    public static func isRetryableAsIs(_ raw: String) -> Bool {
        info(for: raw)?.retryableAsIs ?? false
    }
}

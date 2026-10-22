// desktop/native/gather-app/Sources/GatherUI/Support/APIErrorPresentation.swift
// Cut 3 / 3b-0：从 Host/APIs/AppServices.swift 搬出的错误展示唯一漏斗（E-16）。
//
// 为什么在 Support（UI 侧）：11 个 UI 文件都调用它；留在 Host 会让拆分后的
// GatherUI → GatherHost 反向依赖，并与 Host → UI 的本地化依赖成环。它只依赖
// GatherProtocol（GatherError / SessionServiceError）与同 target 的错误载体
// （APIError / RouterCommandError / BridgeError）和 GatherLocalization。
//
// 语义不变：码值错误 → 本地化模板；其余 → 通用文案。它不反向依赖任何字符串
// 命令客户端。
import Foundation
import GatherProtocol

/// API 错误的唯一展示漏斗（UI 侧使用；不改变既有错误载荷的文案矩阵）。
///
/// B8.3b-2b/B8.4：原字符串命令客户端的 message/userFacingMessage 兜底逻辑
/// （码值错误 → 本地化模板；其余 → 通用文案）整体搬到这里；命令客户端删除后
/// 本漏斗是页面错误文案的唯一出口。
public enum APIErrorPresentation {
    /// Cut 4 / 4b-1：语言由调用方在渲染/事件期显式传入（外壳的 LanguageStore），
    /// 本漏斗不再读进程级 GatherLocalization.appLanguage。
    public static func message(for error: Error, with l10n: L10n) -> String {
        if let gather = error as? GatherError {
            return l10n.errorText(gather.code.rawValue)
        }
        // SessionServiceError 不满足 LocalizedError，NSError 桥接会把码值丢成
        // 「The operation couldn't be completed…」，故必须先取 gatherCode。
        if let sessionError = error as? SessionServiceError {
            return l10n.errorText(sessionError.gatherCode.rawValue)
        }
        if let native = error as? APIError {
            return l10n.errorText(native.description)
        }
        if let router = error as? RouterCommandError {
            return l10n.errorText(router.message)
        }
        if let bridge = error as? BridgeError {
            return l10n.errorText(bridge.description)
        }
        return l10n.errorText((error as NSError).localizedDescription)
    }

    /// 页面错误文案的唯一漏斗（与 message(for:) 同义；保留旧调用点名字）。
    public static func userFacingMessage(for error: Error, with l10n: L10n) -> String {
        message(for: error, with: l10n)
    }

    // MARK: - 交付 P2 的恢复动作

    /// 交付错误码的恢复动作；非交付错误返回 nil。
    ///
    /// message(for:) 已经通过 L10n 的同一张表给出文案；本方法把「下一步」
    /// 单独暴露给页面（重试 / 先处理未完成项 / 稍后刷新 / 检查并修复备份），
    /// 避免 invalidBackup 被当成普通可重试失败。
    public static func recovery(for error: Error) -> DeliveryErrorRecovery? {
        for candidate in rawTexts(for: error) {
            if let recovery = DeliveryErrorPresentation.recovery(for: candidate) {
                return recovery
            }
        }
        return nil
    }

    /// 恢复动作的本地化标题；非交付错误返回 nil。
    public static func recoveryTitle(for error: Error, with l10n: L10n) -> String? {
        recovery(for: error)?.title(with: l10n)
    }

    /// 按与 message(for:) 相同的优先级提取可能承载错误码的字符串。
    private static func rawTexts(for error: Error) -> [String] {
        var texts: [String] = []
        if let gather = error as? GatherError {
            texts.append(gather.code.rawValue)
        }
        if let session = error as? SessionServiceError {
            texts.append(session.gatherCode.rawValue)
        }
        if let api = error as? APIError {
            texts.append(api.description)
        }
        if let router = error as? RouterCommandError {
            texts.append(router.message)
        }
        if let bridge = error as? BridgeError {
            texts.append(bridge.description)
        }
        texts.append((error as NSError).localizedDescription)
        texts.append(String(describing: error))
        return texts
    }
}

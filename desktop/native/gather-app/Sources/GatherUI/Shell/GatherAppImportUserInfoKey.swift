// desktop/native/gather-app/Sources/GatherUI/Shell/GatherAppImportUserInfoKey.swift
// WP4a：导入完成通知的 userInfo 契约随 RootShellOverlay 迁入 GatherUI。
//
// 原声明在 GatherHost/GatherAppDelegate.swift；RootView 的 importCompleted
// 处理（现在的 RootShellOverlay）消费这些键，而 GatherUI 不得 import
// GatherHost，因此与 GatherAppNotification 一样上移到 UI，Host 通过
// import GatherUI 复用同一份常量。
import Foundation

/// importCompleted 通知的 userInfo 键名（契约：键名/类型以此为准，勿改）。
public enum GatherAppImportUserInfoKey {
    /// String：新创建的工作区 id。
    public static let sessionId = "sessionId"
    /// Int：导入失败的（无法读尺寸）文件数。
    public static let failedCount = "failedCount"
    /// Int：成功入库的照片数。
    public static let addedCount = "addedCount"
    /// String：失败提示的来源标签（"Capture One 文件"/"文件"），对齐旧版
    /// importFailureMessage 的 source 参数。
    public static let sourceLabel = "sourceLabel"
    /// String：失败文件示例（前 3 个文件名、顿号连接）。
    public static let examples = "examples"
}

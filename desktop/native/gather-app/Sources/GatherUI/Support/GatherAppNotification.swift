// desktop/native/gather-app/Sources/GatherUI/Support/GatherAppNotification.swift
// Cut 3 / 3b-3：宿主通知名。
//
// Phase 4 收口：菜单命令不再有通知名（命令直接走 AppCommandCenter）；
// 这里只剩 UI → 外壳的入口请求与宿主 → UI 的事件（导入完成/C1 错误/语言切换）。
import Foundation

public enum GatherAppNotification {
    /// 「用户要求导入文件夹」入口通知（F02）：任何 UI 入口（侧栏工具栏按钮、
    /// 空图库的导入按钮…）统一 post 本通知；RootView 收到后请宿主打开目录
    /// 选择器，与「文件 ▸ 导入文件夹…」(⌘O) 走同一条流程。
    public static let importFolderRequest = Notification.Name("gather.menu.import-folder-request")
    public static let captureOneError = Notification.Name("gather.capture-one.error")
    /// 设置页语言切换后广播（settings.set_language 命令处理器发出），
    /// AppDelegate 收到后按新语言重建菜单兜底项（对齐旧版 setAppLocale 即时 rebuild）。
    public static let languageChanged = Notification.Name("gather.menu.language-changed")
    /// 导入成功后由 GatherApp.importFiles 统一 post（菜单/C1/deep-link 共用），
    /// RootView 订阅后导航到新工作区并 Toast 失败计数。
    public static let importCompleted = Notification.Name("gather.import.completed")
    /// T0 等设置保存后广播；已打开会话据此重读 enabled/auto 状态。
    public static let settingsChanged = Notification.Name("gather.settings.changed")
}

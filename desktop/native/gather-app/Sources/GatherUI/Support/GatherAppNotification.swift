// desktop/native/gather-app/Sources/GatherUI/Support/GatherAppNotification.swift
// Cut 3 / 3b-3：宿主通知名。
//
// 3b-2 前声明在 GatherHost/GatherAppDelegate.swift；GatherUI 的
// Dashboard/Library/Gallery 页面也会 post/订阅同一批通知名，拆 target 后
// 上移到 UI（Host 通过 import GatherUI 复用同一份常量）。
import Foundation

public enum GatherAppNotification {
    public static let menuNewWorkspace = Notification.Name("gather.menu.new-workspace")
    public static let menuImportFolder = Notification.Name("gather.menu.import-folder")
    /// 「用户要求导入文件夹」入口通知（F02）：任何 UI 入口（侧栏工具栏按钮、
    /// 空图库的导入按钮…）统一 post 本通知；AppDelegate 收到后打开目录选择器，
    /// 与「文件 ▸ 导入文件夹…」(⌘O) 走同一条流程。
    ///
    /// 与 menuImportFolder 的区别（二者不可混用）：
    /// - importFolderRequest：**还没选目录**，只是一个入口请求；载荷恒为 nil。
    /// - menuImportFolder：**已经选好目录但没有可导入的 RAW 文件**，
    ///   载荷必须是非空的目录 URL，接收方据此打开新建工作区表单。
    ///   旧实现里 UI 入口误用了后者并传 nil，接收方要求 URL 于是静默丢弃，
    ///   表现就是「点了导入没反应」。
    public static let importFolderRequest = Notification.Name("gather.menu.import-folder-request")
    /// 「从 Capture One 导入」入口通知（N08）：SwiftUI Commands 的菜单项与
    /// AppKit 菜单共用同一动作，避免两套菜单各自实现一遍。
    public static let captureOneImportRequest = Notification.Name("gather.menu.capture-one-import-request")
    public static let menuToggleSidebar = Notification.Name("gather.menu.toggle-sidebar")
    public static let menuOpenSettings = Notification.Name("gather.menu.open-settings")
    public static let captureOneError = Notification.Name("gather.capture-one.error")
    /// 设置页语言切换后广播（settings.set_language 命令处理器发出），
    /// AppDelegate 收到后按新语言重建菜单（对齐旧版 setAppLocale 即时 rebuild）。
    public static let languageChanged = Notification.Name("gather.menu.language-changed")
    /// 导入成功后由 GatherApp.importFiles 统一 post（菜单/C1/deep-link 共用），
    /// RootView 订阅后导航到新工作区并 Toast 失败计数。
    public static let importCompleted = Notification.Name("gather.import.completed")
}

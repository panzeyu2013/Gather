// desktop/native/gather-app/Sources/GatherUI/Support/SessionPageModel.swift
// WP4d 后续：会话页的生命周期协议（PageVisibility 的完整版）。
//
// 为什么需要：7 个会话页 ViewModel 早已各自实现 setVisible/shutdown，但
// PageVisibility 只声明了 setVisible ——「关闭」与「终态」没有共同契约，
// 于是 SessionWorkspace 只能在三处（会话级 hidden / 页面级 hidden / close）
// 手写 7 行扇出。本协议把这三件事收成一个可放进注册表的类型：
//
//   1. setVisible —— 页面级/会话级可见性唯一入口（继承 PageVisibility）；
//   2. shutdown   —— 关闭终态（各 VM 自己取消长任务，语义不变）；
//   3. isPageVisible / hasShutDown —— 只读真相，给注册表完整性与终态断言用。
//
// 设计取舍：
// - 只读桥（isPageVisible/hasShutDown）不改各 VM 的存储属性与访问级别：
//   Culling 的真相叫 isActive、其余叫 isVisible，且 Gallery 的 isVisible 是
//   跨文件 extension 读写的 internal var —— 直接改名会波及 9 处调用点与
//   2 处测试，收益只是「名字统一」，不值得。
// - 本协议不（含）页面标题/视图构造：那两处 switch 必须保持穷尽（加页面时
//   编译期报错是正确的），表驱动只会把编译期错误换成运行时静默。
import Foundation

/// 一个会话页 ViewModel 的完整生命周期契约。
///
/// 实现要求（与 PageVisibility 的契约一致，另加两条）：
/// - `isPageVisible` 必须反映真实可见性状态，构造后为 false；
/// - `shutdown` 幂等且是终态：之后 `setVisible(true)` 一律 no-op，
///   `hasShutDown` 恒为 true。
@MainActor
public protocol SessionPageModel: PageVisibility {
    /// 当前是否可见（只读真相；Culling 映射 isActive，其余映射 isVisible）。
    var isPageVisible: Bool { get }
    /// 是否已进入关闭终态。
    var hasShutDown: Bool { get }
    /// 关闭：取消本 VM 持有的长生命周期任务；重复调用幂等。
    func shutdown()
}

import SwiftUI

/// 页面从 environment 取路由能力，不再接收 5–9 个导航闭包。
///
/// Optional 是为了预览/布局测试可以脱离 RootView；生产由 RootView 注入。
private struct NavigatorEnvironmentKey: EnvironmentKey {
    static let defaultValue: RootNavigation? = nil
}

package extension EnvironmentValues {
    var navigator: RootNavigation? {
        get { self[NavigatorEnvironmentKey.self] }
        set { self[NavigatorEnvironmentKey.self] = newValue }
    }
}

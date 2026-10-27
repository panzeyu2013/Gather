// Gather 样式角色（字体 / 间距 / 布局 / 动效）。
//
// 页面不再直接挑数值：字号、间距、圆角、动画都从角色的语义名取值。
// 旧代码可以继续用系统样式，但新增 / 改造的视图应优先使用这里的常量。
import SwiftUI

enum GatherFont {
    /// 首屏 hero 标题（26pt）。
    static let hero = Font.largeTitle.weight(.semibold)
    /// hero 副标题（15pt）。
    static let heroSubtitle = Font.title3
    /// 小标题 / eyebrow（11pt semibold）。
    static let eyebrow = Font.subheadline.weight(.semibold)
    /// 弹层 / 详情页主标题（17pt）。
    static let pageTitle = Font.title2.weight(.semibold)
    /// 页面分区 / 卡片分区标题（15pt）。
    static let sectionTitle = Font.title3.weight(.semibold)
    /// 卡片内二级标题（13pt semibold）。
    static let cardTitle = Font.headline
    /// 正文（13pt）。
    static let body = Font.body
    static let bodyStrong = Font.body.weight(.semibold)
    /// 次级正文 / 元数据（12pt）。
    static let secondary = Font.callout
    static let secondaryStrong = Font.callout.weight(.semibold)
    /// 徽标 / 密集标签（11pt）。
    static let label = Font.subheadline.weight(.medium)
    static let labelRegular = Font.subheadline
    /// 统计数字。
    static let stat = Font.title2.weight(.semibold).monospacedDigit()
    static let statCompact = Font.title3.weight(.semibold).monospacedDigit()
    /// 行内数字。
    static let mono = Font.callout.monospacedDigit()
    static let monoBody = Font.body.monospacedDigit()
}

enum GatherMetrics {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        /// 字段图标与文本、紧凑控件内部的通用间距（4 < 6 < 8）。
        static let controlGap: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Layout {
        static let pageGutter: CGFloat = 24
        static let cardPadding: CGFloat = 16
        static let rowGap: CGFloat = 8
        static let sectionGap: CGFloat = 24
        static let maxReadingWidth: CGFloat = 1100
        static let maxFormWidth: CGFloat = 760
    }

    enum Chrome {
        static let tabStrip: CGFloat = 36
        static let infoBar: CGFloat = 32
        static let filmstripExpanded: CGFloat = 140
        static let filmstripCollapsed: CGFloat = 32
    }

    enum Opacity {
        static let hover: CGFloat = 0.04
        static let pressed: CGFloat = 0.08
        static let disabled: CGFloat = 0.50
    }

    enum Motion {
        static let hover: Double = 0.12
        static let standard: Double = 0.18
    }
}

// 跨页面共享的日期解析辅助。
// 合并来源：DashboardView / PersonsView 各自私有的 parseISO8601（×2）。
import Foundation

/// ISO8601 解析：先按带小数秒的互联网日期时间解析，失败回退不带小数秒的同一格式。
func parseISO8601Date(_ iso: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: iso) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: iso)
}

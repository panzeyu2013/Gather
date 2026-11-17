// desktop/native/gather-app/Tests/GatherAppTests/DisplayDateFormattersTests.swift
// 性能审计回归（2026-11-17 perf-ui）：DisplayDateFormatters 把展示层 DateFormatter /
// ISO8601DateFormatter 缓存复用后，输出必须与「每次调用新建 formatter」逐字节一致。
//
// 背景：cache 化的教训是第二轮自查时曾把展示路径换成 Date.FormatStyle，解析等价
// 但 zh 下 timeStyle .shorted 丢了前导零（"9:46" vs "09:46"）。本文件把
// mediumShort / pattern / localizedTemplate / shortShort / ISO-8601 解析全部钉在
// 「新建同配置 formatter」的 oracle 上；固定 locale 与固定 epoch 日期，不读墙钟。
import Foundation
import Testing
@testable import GatherUI

@Suite("DisplayDateFormatters 缓存等价性")
struct DisplayDateFormattersTests {

    private let formatters = DisplayDateFormatters.shared

    /// zh_CN / en_US 覆盖中文与英文的日期顺序、前导零差异。
    private let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

    /// 固定 epoch（与运行机器时区无关的绝对时刻；展示输出在同一进程内比较）。
    private let dates = [
        Date(timeIntervalSince1970: 1_700_000_000),   // 2023-11-14T22:13:20Z
        Date(timeIntervalSince1970: 1_702_595_999),   // 2023-12-11T23:59:59Z
        Date(timeIntervalSince1970: 0),
    ]

    @Test("mediumShort：与新建 medium/short DateFormatter 输出逐字节一致")
    func mediumShortMatchesFreshFormatter() {
        for locale in locales {
            let fresh = DateFormatter()
            fresh.locale = locale
            fresh.dateStyle = .medium
            fresh.timeStyle = .short
            for date in dates {
                #expect(
                    formatters.mediumShort(date, locale: locale) == fresh.string(from: date),
                    "mediumShort 缓存输出漂移：locale=\(locale.identifier) date=\(date)")
            }
        }
    }

    @Test("pattern：固定 pattern（导出命名/胶囊时间）与新建 DateFormatter 逐字节一致")
    func patternMatchesFreshFormatter() {
        for locale in locales {
            for format in ["yyyy-MM-dd HH:mm", "yyyyMMdd-HHmmss"] {
                let fresh = DateFormatter()
                fresh.locale = locale
                fresh.dateFormat = format
                for date in dates {
                    #expect(
                        formatters.pattern(date, format: format, locale: locale)
                            == fresh.string(from: date),
                        "pattern 缓存输出漂移：format=\(format) locale=\(locale.identifier)")
                }
            }
        }
    }

    @Test("localizedTemplate：yMd 短模板与新建 setLocalizedDateFormatFromTemplate 一致")
    func localizedTemplateMatchesFreshFormatter() {
        for locale in locales {
            let fresh = DateFormatter()
            fresh.locale = locale
            fresh.setLocalizedDateFormatFromTemplate("yMd")
            for date in dates {
                #expect(
                    formatters.localizedTemplate(date, template: "yMd", locale: locale)
                        == fresh.string(from: date),
                    "localizedTemplate 缓存输出漂移：locale=\(locale.identifier)")
            }
        }
    }

    @Test("shortShort：与新建 short/short DateFormatter 输出逐字节一致")
    func shortShortMatchesFreshFormatter() {
        for locale in locales {
            let fresh = DateFormatter()
            fresh.locale = locale
            fresh.dateStyle = .short
            fresh.timeStyle = .short
            for date in dates {
                #expect(
                    formatters.shortShort(date, locale: locale) == fresh.string(from: date),
                    "shortShort 缓存输出漂移：locale=\(locale.identifier)")
            }
        }
    }

    @Test("ISO-8601 解析：带/不带小数秒与新建解析器语义一致")
    func iso8601ParsingMatchesFreshFormatters() {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plainInputs = [
            "2026-01-01T00:00:00Z",
            "2023-11-14T22:13:20+00:00",
            "2023-11-14T22:13:20+08:00",
        ]
        for iso in plainInputs {
            let cached = formatters.internetDateTime(iso)
            #expect(cached == plain.date(from: iso), "plain ISO 解析漂移：\(iso)")
            #expect(cached != nil)
        }

        // 带小数秒：专用解析器成功；普通解析器按旧语义失败（调用方走 fallback）。
        let fractionalISO = "2023-11-14T22:13:20.123Z"
        #expect(
            formatters.internetDateTimeWithFractionalSeconds(fractionalISO)
                == fractional.date(from: fractionalISO))
        #expect(formatters.internetDateTime(fractionalISO) == nil)
        #expect(plain.date(from: fractionalISO) == nil)

        // 坏输入：缓存解析器与新建解析器都返回 nil（失败语义一致，不静默造值）。
        for bad in ["", "not-a-date", "2026-13-40T99:99:99Z"] {
            #expect(formatters.internetDateTime(bad) == nil)
            #expect(formatters.internetDateTimeWithFractionalSeconds(bad) == nil)
            #expect(plain.date(from: bad) == nil)
            #expect(fractional.date(from: bad) == nil)
        }
    }

    @Test("parseISO8601Date fallback：先带小数秒、失败回退不带；坏输入 nil")
    func parseFallbackMatchesFormatStyle() throws {
        let fractionalISO = "2023-11-14T22:13:20.500Z"
        let expectedFractional = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(fractionalISO)
        #expect(parseISO8601Date(fractionalISO) == expectedFractional)
        // 缓存的小数秒解析器与 fallback 的首步是同一语义（同一时刻）。
        #expect(formatters.internetDateTimeWithFractionalSeconds(fractionalISO) == expectedFractional)

        let plainISO = "2023-11-14T22:13:20Z"
        let expectedPlain = try Date.ISO8601FormatStyle().parse(plainISO)
        #expect(parseISO8601Date(plainISO) == expectedPlain)
        #expect(formatters.internetDateTime(plainISO) == expectedPlain)

        #expect(parseISO8601Date("not-a-date") == nil)
        #expect(parseISO8601Date("") == nil)
    }
}

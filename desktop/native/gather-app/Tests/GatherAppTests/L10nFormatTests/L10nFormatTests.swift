// desktop/native/gather-app/Tests/GatherAppTests/L10nFormatTests/L10nFormatTests.swift
// Cut 4 / 4b-2-prep：L10n 的字符串缓存、变参入口（callAsFunction/format）、
// 延迟文案入口（resolve/resolvedTemplate）与动态 key。
//
// 这组用例只读产品代码、不改页面；覆盖 4b-2 codemod 的 5 个高危点
// （审计 §3.5 R1/R2/R7）：
//   1. 缓存按 (语言, key) 分键——切语言不会读到另一种语言的旧值；
//   2. 缓存命中——同一 key 第二次不再走 Bundle，且 format 与裸查表共用缓存；
//   3. 参数顺序——`String(format: l("… %lld …"), …)` 换成 `l10n.format` 后
//      多参数不错位、`%lld %@` 混排仍按占位符顺序；
//   4. 参数类型错配——String 传到 %lld/%d 归一成 %@，整数传到 %@ 归一成 %lld，
//      旧写法会崩的组合这里必须出正确文案；
//   5. 裸 % —— 模板里的 "100%" / 结尾 % / "%%" 不进入（或安全进入）
//      String(format:)，不崩、不吞字。
import Foundation
import Testing
@testable import GatherUI

@Suite("L10n 格式化与缓存（4b-2-prep）")
struct L10nFormatTests {
    // MARK: - 缓存

    @Test("缓存：同语言同 key 第二次直接命中，负缓存也不再查表")
    func cacheHitsForSameLanguageAndKey() {
        let cache = L10nStringCache()
        let l10n = L10n(language: .en, cache: cache)

        #expect(l10n("工作区不存在") == "Workspace not found")
        #expect(cache.stats.misses == 1)
        #expect(cache.stats.hits == 0)

        #expect(l10n("工作区不存在") == "Workspace not found")
        #expect(cache.stats.misses == 1)
        #expect(cache.stats.hits == 1)

        // 未命中本地化表的 key 同样缓存（结果是 key 原文），不会每帧重新查一次。
        #expect(l10n("NOT_A_LOCALIZED_KEY") == "NOT_A_LOCALIZED_KEY")
        #expect(l10n("NOT_A_LOCALIZED_KEY") == "NOT_A_LOCALIZED_KEY")
        #expect(cache.stats.misses == 2)
        #expect(cache.stats.hits == 2)

        // 页面每次渲染都新建 L10n 值；共享缓存必须跨实例命中（生产走 .shared）。
        let another = L10n(language: .en, cache: cache)
        #expect(another("工作区不存在") == "Workspace not found")
        #expect(cache.stats.hits == 3)
        #expect(cache.stats.count == 2)
    }

    @Test("缓存：format 与裸查表共用同一份缓存，不重复查表")
    func formatSharesLookupCache() {
        let cache = L10nStringCache()
        let l10n = L10n(language: .en, cache: cache)

        #expect(l10n("已保存 %@") == "%@ saved")
        #expect(l10n.format("已保存 %@", "缩略图尺寸") == "缩略图尺寸 saved")
        #expect(cache.stats.misses == 1)
        #expect(cache.stats.hits == 1)

        #expect(l10n("已保存 %@", "缩略图尺寸") == "缩略图尺寸 saved")
        #expect(cache.stats.hits == 2)
    }

    @Test("缓存：zh/en 分键，切语言不读到另一种语言的旧值")
    func cacheIsolatedPerLanguage() {
        let cache = L10nStringCache()
        let zh = L10n(language: .zhCN, cache: cache)
        let en = L10n(language: .en, cache: cache)

        #expect(zh("工作区不存在") == "工作区不存在")
        #expect(en("工作区不存在") == "Workspace not found")
        // 反过来再查一遍：zh 条目不会被 en 覆盖（或反之）。
        #expect(zh("工作区不存在") == "工作区不存在")
        #expect(en("工作区不存在") == "Workspace not found")
        #expect(cache.stats.misses == 2)
        #expect(cache.stats.hits == 2)

        // 切换后的新值（LanguageStore.set 后 l10n 是新建的值）仍按新语言解析。
        #expect(L10n(language: .en, cache: cache)("已取消") == "Canceled")
        #expect(L10n(language: .zhCN, cache: cache)("已取消") == "已取消")
    }

    @Test("缓存：空 key 直接返回空串且不占缓存；超上限整体清空（内存有界）")
    func emptyKeyAndEviction() {
        let cache = L10nStringCache(limit: 2)
        let l10n = L10n(language: .en, cache: cache)
        #expect(l10n("") == "")
        #expect(cache.stats.count == 0)

        _ = l10n("工作区不存在")
        _ = l10n("已取消")
        #expect(cache.stats.count == 2)
        #expect(cache.stats.evictions == 0)

        _ = l10n("照片不存在或无权访问。")
        #expect(cache.stats.evictions == 1)
        #expect(cache.stats.count == 1)
    }

    @Test("L10n 相等性只看语言（缓存实例不参与语义）")
    func equalityIgnoresCacheInstance() {
        #expect(L10n(language: .en, cache: L10nStringCache()) == L10n(language: .en))
        #expect(L10n(language: .en) != L10n(language: .zhCN))
        #expect(L10n(language: .zhCN) == L10n(rawLanguage: "zh-Hans"))
    }

    // MARK: - format：参数顺序

    @Test("format：多参数按占位符顺序插值，三个 %lld 不错位")
    func formatKeepsArgumentOrder() {
        let key = "将写入 %lld 张照片 + %lld 个 XMP 附属文件，共 %lld 个文件。"
        #expect(L10n(language: .en).format(key, 1, 2, 3)
            == "Will write 1 photos + 2 XMP sidecars, 3 files in total.")
        #expect(L10n(language: .zhCN).format(key, 1, 2, 3)
            == "将写入 1 张照片 + 2 个 XMP 附属文件，共 3 个文件。")
    }

    @Test("format：%@ 与 %lld 混排时按顺序配对（文本/整数/浮点）")
    func formatPairsMixedArgumentKindsInOrder() {
        let zh = L10n(language: .zhCN)
        #expect(zh.format("%@ · 置信度 %lld%%", "人脸", 87) == "人脸 · 置信度 87%")
        #expect(zh.format("%lld → %@ → %d", 1, "中", 3) == "1 → 中 → 3")

        let en = L10n(language: .en)
        #expect(en.format("%@ · 置信度 %lld%%", "Face", 87) == "Face · confidence 87%")
        #expect(en.format("%.1f MB", 3.5) == "3.5 MB")
        // 小数 + %@：旧写法 String(format: "%@", 3.5) 直接把 double 当指针读，会崩。
        #expect(en.format("%@", 3.5) == "3.5")
    }

    // MARK: - format：类型安全（4b-2 的 R2）

    @Test("format：String 配 %lld/%d 归一成 %@，与整数参数输出逐字一致")
    func stringArgumentsForIntegerPlaceholdersAreNormalized() {
        let en = L10n(language: .en)
        let key = "其中 %lld 项存在问题，导出时会失败。"
        #expect(en.format(key, 3) == "3 items have issues and will fail to export.")
        // 机械替换后的常见形态：参数本身是 String（"3"）。
        #expect(en.format(key, "3") == "3 items have issues and will fail to export.")
        #expect(en.format(key, "3") == en.format(key, 3))

        #expect(en.format("共 %d 项", 7) == "共 7 项")
        #expect(en.format("共 %d 项", "7") == "共 7 项")
        #expect(en.format("共 %d 项", "7") == en.format("共 %d 项", 7))
    }

    @Test("format：整数配 %@ 归一成数值文本；宽度/百分号等常规写法不被改写")
    func integerArgumentsForObjectPlaceholdersAreNormalized() {
        let en = L10n(language: .en)
        #expect(en.format("%@", 7) == "7")
        #expect(en.format("%@", 7) == String(format: "%lld", 7))
        #expect(en.format("%05lld", 3) == "00003")
        #expect(en.format("%lld%%", 42) == "42%")
        #expect(en.format("已索引 %lld%%", 85) == "Indexed 85%")
    }

    @Test("format：不引入千分位（与 String(format:) 逐字一致，codemod 中性）")
    func formatDoesNotIntroduceGrouping() {
        let en = L10n(language: .en)
        #expect(en.format("已索引 %lld 张照片", 12847) == "Indexed 12847 photos")
        #expect(L10n(language: .zhCN).format("已索引 %lld 张照片", 12847) == "已索引 12847 张照片")
        #expect(en.format("%lld", 12847) == String(format: "%lld", 12847))
    }

    @Test("format：NaN/无穷/超范围浮点配整数转换符不崩（退化成文本）")
    func formatNeverTrapsOnUnrepresentableFloats() {
        let en = L10n(language: .en)
        #expect(en.format("%lld", Double.nan) == "nan")
        #expect(en.format("%lld", Double.infinity) == "inf")
        #expect(en.format("%lld", 1e30) == "1e+30")
        #expect(en.format("%.1f", Double.nan) == "nan")
        #expect(en.format("%d", 3.0) == "3")
        #expect(en.format("%d", 3.9) == "3")
    }

    @Test("format：缺参补空串、多参忽略，不因参数个数不匹配崩溃")
    func formatToleratesArgumentCountMismatch() {
        let en = L10n(language: .en)
        #expect(en.format("%@ / %@", "a") == "a / ")
        #expect(en.format("%@", "a", "b") == "a")
    }

    // MARK: - format：裸 % 与无参

    @Test("裸 %：无参不进入 String(format:)，占位符与百分号原样保留")
    func noArgumentsNeverEnterStringFormat() {
        let l10n = L10n(language: .en)
        #expect(l10n("进度 %") == "进度 %")
        #expect(l10n("进度 100%") == "进度 100%")
        #expect(l10n("已保存 %@") == "%@ saved")
        #expect(l10n.format("已保存 %@") == "%@ saved")
        #expect(l10n.format("进度 100%") == "进度 100%")
    }

    @Test("裸 %：有参时按字面量转义，%% 折叠成 %，真占位符照常插值")
    func barePercentIsEscapedWhenFormatting() {
        let l10n = L10n(language: .en)
        #expect(l10n.format("增长 5%", 1) == "增长 5%")
        #expect(l10n.format("%", 1) == "%")
        #expect(l10n.format("100% 完成：%@", "导出") == "100% 完成：导出")
        #expect(l10n.format("已完成 100%%", 1) == "已完成 100%%")
        #expect(l10n.format("置信度 %lld%%", 85) == "置信度 85%")
        // '*' 宽度无法静态配对 → 原样返回模板（不崩）。
        #expect(l10n.format("%*lld", 5) == "%*lld")
    }

    // MARK: - plural（R5-P1-2）

    @Test("plural：count==1 用 #one 单数，n>1 用复数；zh 回退原文")
    func pluralSelectsSingularAndPlural() {
        let en = L10n(language: .en)
        let zh = L10n(language: .zhCN)

        #expect(en.plural("%lld 张照片", count: 1) == "1 photo")
        #expect(en.plural("%lld 张照片", count: 2) == "2 photos")
        #expect(zh.plural("%lld 张照片", count: 1) == "1 张照片")
        #expect(zh.plural("%lld 张照片", count: 2) == "2 张照片")

        #expect(en.plural("%lld 个人脸样本", count: 1) == "1 face sample")
        #expect(en.plural("写回队列：%d 项", count: 1) == "Writeback Queue: 1 Item")
        #expect(en.plural("已完成任务（%lld）", count: 1) == "Completed job (1)")
        #expect(en.plural("失败任务 %lld", count: 1) == "Failed Task: 1")
        #expect(en.plural("%lld 个工作区", count: 1) == "1 workspace")

        // 额外参数在 count 之前：%@ · %lld 张照片。
        #expect(en.plural("%@ · %lld 张照片", count: 1, "Burst") == "Burst · 1 photo")
        #expect(en.plural("%@ · %lld 张照片", count: 3, "Burst") == "Burst · 3 photos")
        #expect(zh.plural("%@ · %lld 张照片", count: 1, "连拍") == "连拍 · 1 张照片")

        // 未登记 #one 的模板回退 base（行为与 format 一致，不出现 #one）。
        #expect(en.plural("共 %lld 项", count: 1) == "共 1 项")
        #expect(en.plural("%lld", count: 1) == "1")
    }

    @Test("LocalizedText.plural：延迟文案同样按 count 选模板（切语言不冻结）")
    func localizedTextPluralResolvesAtRenderTime() {
        let text = LocalizedText.plural("%lld 张照片", count: 1)
        #expect(text.pluralCount == 1)
        #expect(text.resolve(with: L10n(language: .en)) == "1 photo")
        #expect(text.resolve(with: L10n(language: .zhCN)) == "1 张照片")

        let many = LocalizedText.plural("%@ · %lld 张照片", count: 4, params: ["Scene"])
        #expect(many.resolve(with: L10n(language: .en)) == "Scene · 4 photos")
    }

    // MARK: - 动态 key

    @Test("动态 key：String 变量与字面量同源，未知 key 原样透传")
    func dynamicKeysResolveLikeLiterals() {
        let en = L10n(language: .en)
        let key = ["工作区", "不存在"].joined()
        #expect(key == "工作区不存在")
        #expect(en(key) == "Workspace not found")
        #expect(en.resolvedTemplate(key, params: []) == "Workspace not found")

        let unknown = "NOT_A_KEY_" + "42"
        #expect(en(unknown) == unknown)
        #expect(LocalizedText(dynamicKey: unknown).resolve(with: en) == unknown)
    }

    // MARK: - LocalizedText

    @Test("LocalizedText：动态 key 初始化与 resolve(with:) 等价；Hashable 语义不变")
    func localizedTextDynamicKeyAndResolve() {
        let en = L10n(language: .en)
        let key = ["已取消", "“%@”，未执行任何更改"].joined()
        let text = LocalizedText(dynamicKey: key, params: ["导出"])

        #expect(text.resolve(with: en) == "Cancelled “导出”; nothing was changed")
        // 旧入口是同一实现（4b-2 不触碰已在用的调用点）。
        #expect(text.resolved(with: en) == text.resolve(with: en))

        #expect(text == LocalizedText(key, params: ["导出"]))
        #expect(text.hashValue == LocalizedText(key, params: ["导出"]).hashValue)
        #expect(Set([text, LocalizedText(dynamicKey: key, params: ["导出"])]).count == 1)
        #expect(text != LocalizedText(dynamicKey: key, params: ["导入"]))
        #expect(LocalizedText("").isEmpty)
    }

    @Test("resolve：{{param}} 优先于 %@，无参保留占位符（旧语义不变）")
    func resolveKeepsTemplateSemantics() {
        let en = L10n(language: .en)
        // {{}} 形态：错误码表模板的写法（插值按出现顺序）。
        #expect(en.resolve(LocalizedText("冲突：{{expected}} → {{current}}", params: ["3", "5"]))
            == "冲突：3 → 5")
        // %@ 形态：params 是 String，%lld 也按 %@ 插入。
        #expect(en.resolve(LocalizedText("已写入 %lld 项", params: ["3"])) == "已写入 3 项")
        // 无参：保留占位符（与 4a 的行为一致）。
        #expect(en.resolve(LocalizedText("已保存 %@")) == "%@ saved")
        // 错误码模板 + params 走 errorText，不经 resolve。
        #expect(en.errorText(CommandError(code: "CULLING_REVISION_CONFLICT", params: ["3", "5"]))
            == "Culling revision conflict: expected 3, current 5")
    }

    // MARK: - 错误码语义（保持 4b-1 不变）

    @Test("errorText：码 / CODE::p / CODE: 散文 / 未知码 四种形态语义不变")
    func errorTextSemanticsUnchanged() {
        let en = L10n(language: .en)
        #expect(en.errorText("SESSION_NOT_FOUND") == "Workspace not found")
        #expect(en.errorText("CULLING_REVISION_CONFLICT::3::5")
            == "Culling revision conflict: expected 3, current 5")
        #expect(en.errorText("CULLING_REVISION_CONFLICT: 7")
            == "Culling revision conflict: expected 7, current ")
        #expect(en.errorText("NOT_A_REAL_CODE") == en(L10n.unknownErrorKey))
        #expect(en(L10n.unknownErrorKey) == "Something went wrong. Please try again later.")
        #expect(en.errorText(CommandError(code: "SESSION_NOT_FOUND")) == "Workspace not found")
    }

    // MARK: - 并发

    @Test("缓存并发：多任务同时读两种语言，结果稳定且命中计数自洽")
    func concurrentLookupsAreConsistent() async {
        let cache = L10nStringCache()
        let zh = L10n(language: .zhCN, cache: cache)
        let en = L10n(language: .en, cache: cache)
        let iterations = 50
        let tasks = 64

        let allConsistent = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<tasks {
                group.addTask {
                    let l10n = index.isMultiple(of: 2) ? zh : en
                    let expected = l10n.language == .en ? "Workspace not found" : "工作区不存在"
                    for _ in 0..<iterations {
                        if l10n("工作区不存在") != expected { return false }
                    }
                    return true
                }
            }
            var consistent = true
            for await result in group {
                consistent = consistent && result
            }
            return consistent
        }

        #expect(allConsistent)
        #expect(cache.stats.misses == 2)
        #expect(cache.stats.hits == tasks * iterations - 2)
    }
}

// desktop/native/gather-app/Sources/GatherUI/SemanticSearch/SemanticLabelCatalog.swift
// Wave5 batch7（E4 / 40-metadata-search D3 补充）：Vision 英文场景标签 ↔ 中文显示名。
//
// 为什么需要：语义索引里的标签是 Vision 的英文原串（beach、wedding…），中文用户
// 既读不懂、也不能直接检索（50-ai-similarity §2 E4 / §3-F）。本表只负责 **UI 层**：
// - 展示：英文标签 → 常见中文名（未命中回落英文原串，新标签不会丢）；
// - 检索：中文输入（含常见别名）→ 对应的英文标签，再交给既有 labels 检索。
//
// 纪律（可逆性）：落盘/检索参数始终是英文原串，关键词路径仍是 AI|场景|beach；
// 中文只活在显示层，不写 XMP、不改既有照片。表内数量控制在 30–60，宁缺毋滥；
// 新增标签只在 UI 缺失时回落英文，不需要改索引/数据库。
import Foundation

enum SemanticLabelCatalog {
    /// 英文规范化标签 → 中文显示名（唯一：反向映射才确定）。
    private static let displayNames: [String: String] = [
        "wedding": "婚礼",
        "bride": "新娘",
        "groom": "新郎",
        "ceremony": "仪式",
        "reception": "宴会",
        "beach": "海滩",
        "ocean": "海洋",
        "sea": "大海",
        "lake": "湖泊",
        "river": "河流",
        "waterfall": "瀑布",
        "mountain": "山",
        "hill": "山丘",
        "forest": "森林",
        "tree": "树",
        "flower": "花",
        "garden": "花园",
        "field": "田野",
        "grass": "草地",
        "sunset": "日落",
        "sunrise": "日出",
        "night": "夜晚",
        "sky": "天空",
        "cloud": "云",
        "snow": "雪",
        "rain": "雨",
        "food": "食物",
        "meal": "餐食",
        "cake": "蛋糕",
        "wine": "葡萄酒",
        "coffee": "咖啡",
        "car": "汽车",
        "bicycle": "自行车",
        "boat": "船",
        "airplane": "飞机",
        "building": "建筑",
        "house": "房屋",
        "church": "教堂",
        "bridge": "桥",
        "dog": "狗",
        "cat": "猫",
        "bird": "鸟",
        "horse": "马",
        "street": "街道",
        "city": "城市",
        "stage": "舞台",
        "dance": "舞蹈",
        "music": "音乐",
        "concert": "音乐会",
        "camera": "相机",
        "jewelry": "珠宝",
        "indoor": "室内",
        "outdoor": "室外",
        "sports": "运动",
        "child": "儿童",
        "baby": "婴儿",
        "people": "人群",
    ]

    /// 常见中文别名（可选增强）：只映射到主标签，不做多层级。
    private static let aliases: [String: String] = [
        "沙滩": "beach",
        "海边": "beach",
        "海滨": "beach",
        "结婚": "wedding",
        "婚礼现场": "wedding",
        "小狗": "dog",
        "猫咪": "cat",
        "小汽车": "car",
        "山峰": "mountain",
        "湖": "lake",
        "海": "sea",
    ]

    /// 反查表：中文显示名/别名 → 英文标签（排序稳定，便于测试与展示）。
    private static let reverseLookup: [String: [String]] = {
        var map: [String: [String]] = [:]
        for (english, display) in displayNames {
            map[display, default: []].append(english)
        }
        for (alias, english) in aliases {
            map[alias, default: []].append(english)
        }
        return map.mapValues { Array(Set($0)).sorted() }
    }()

    /// 支持的标签数量（测试守 30…60：太少不够用，太多没人维护）。
    static var supportedLabelCount: Int { displayNames.count }

    /// 已收录的英文标签（排序稳定；测试用于校验中文显示名唯一）。
    static var supportedEnglishLabels: [String] { displayNames.keys.sorted() }

    /// 与 core SemanticKeywordService.normalizeLabel 同口径：小写、下划线换空格、压空白、去首尾。
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 英文标签 → 中文显示名；未命中回落**原始英文串**（不是规范化后的串，保留 Vision 原形）。
    static func displayName(for label: String) -> String {
        let key = normalize(label)
        guard !key.isEmpty else { return label }
        return displayNames[key] ?? label
    }

    /// 是否包含中文（CJK 统一表意文字），用于区分"中文输入需要映射"。
    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 查询词是否已收录（英文标签或中文显示名/别名）。
    static func isKnown(_ term: String) -> Bool {
        let key = normalize(term)
        guard !key.isEmpty else { return false }
        return displayNames[key] != nil || reverseLookup[key] != nil
    }

    /// 单个查询词 → 英文标签数组（英文原样返回规范化形态；中文按显示名/别名/子串匹配）。
    static func englishLabels(for term: String) -> [String] {
        let key = normalize(term)
        guard !key.isEmpty else { return [] }
        if displayNames[key] != nil { return [key] }
        if let mapped = reverseLookup[key] { return mapped }
        guard containsChinese(key) else { return [key] }
        // 中文未精确命中时做一次保守的子串匹配（如"海边婚礼"→ 海边/婚礼），
        // 仍无命中就原样交给检索（结果为空，由 UI 提示换英文/常见中文名）。
        let candidates = reverseLookup.keys
            .filter { $0.contains(key) || key.contains($0) }
            .sorted()
        if candidates.isEmpty { return [key] }
        return Array(Set(candidates.flatMap { reverseLookup[$0] ?? [] })).sorted()
    }

    /// 多个查询词（逗号/空白分隔后的数组）→ 英文标签；保持输入顺序、去重。
    static func englishLabels(for terms: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for term in terms {
            for english in englishLabels(for: term) {
                let key = english.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(english)
            }
        }
        return result
    }

    /// 结果行/写回预览的展示串：中文名数组（未命中的英文标签原样出现）。
    static func displayList(_ labels: [String]) -> [String] {
        labels.map(displayName(for:))
    }

    /// keyword_path 的最后一段（AI|场景|beach → beach）；不是多段路径时返回 nil。
    static func labelSegment(of path: String) -> String? {
        let segments = path.split(separator: "|", omittingEmptySubsequences: false)
        guard segments.count >= 2, let last = segments.last, !last.isEmpty else { return nil }
        return String(last)
    }
}

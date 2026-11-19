// desktop/native/gather-app/Sources/GatherHost/C1/CaptureOneBridgeParser.swift
// M11（Wave5 / task-9）：从 CaptureOneBridge.swift 纯搬移的脚本输出解析（纯函数）。
// 这些解析器只做文本 → DTO 的纯映射，不 spawn、不读库，测试直接驱动。
//
// 纯移动：搬运块与 HEAD 逐字节一致（同 target internal 可见，无可见性改动）。
import Foundation
import GatherProtocol
import GatherUI

extension CaptureOneBridge {
    /// 写前回读报告解析：行数必须等于请求路径数、每行必须是非负整数；否则 nil
    ///（形状不认识 = 脚本契约变了，调用方带原文抛 C1_SCRIPT_FAILED，绝不按"未知"盲写）。
    static func parseVariantCounts(_ output: String, expected: Int) -> [Int]? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count == expected else { return nil }
        var counts: [Int] = []
        counts.reserveCapacity(lines.count)
        for line in lines {
            guard let count = Int(line), count >= 0 else { return nil }
            counts.append(count)
        }
        return counts
    }

    /// R1 写前回读的分区（纯函数：C1BridgeWave3Tests 直接驱动）。
    ///
    /// counts 与 items 同序（parseVariantCounts 保证行数相等）；越界按"当前集合里没有"
    /// 处理（保守：宁可 notFound 也不写错 variant）。
    static func partitionVariantTargets(
        items: [C1VariantWritebackItem],
        counts: [Int]
    ) -> C1VariantTargetPartition {
        var result = C1VariantTargetPartition(writable: [], multiVariant: [], notFound: [])
        for (index, item) in items.enumerated() {
            let count = index < counts.count ? counts[index] : 0
            if count == 0 {
                result.notFound.append(item)
            } else if count == 1 {
                result.writable.append(item)
            } else {
                result.multiVariant.append(item.photoPath)
            }
        }
        return result
    }

    /// select 报告 → 命中/未命中（纯函数：与 flags 同序；非 "1" 一律按未命中，沿用旧口径）。
    static func splitSelectionReport(
        flags: [String],
        requested: [String],
        selected: inout [String],
        missing: inout [String]
    ) {
        for (index, flag) in flags.enumerated() where index < requested.count {
            if flag == "1" {
                selected.append(requested[index])
            } else {
                missing.append(requested[index])
            }
        }
    }

    /// C7：把脚本的 `error:<msg>` 报告解析成可抛的错误消息（nil = 不是错误报告）。
    ///
    /// 为什么必须先判：这是 selectVariantsScript 在 `on error` 分支显式写出的，
    /// 语义是"脚本执行失败"（无当前文档、字段不存在、旧版字典不支持…），形状与
    /// `"1"/"0"` 报告完全不同。但原实现只按行数判断：单路径时 1 行 = 1 个请求，
    /// 错误串被当成"没匹配到"→ 返回 notFound；多路径时行数不等 → scriptUnsupported
    /// → 兜底 `open -a`（可能整批导入 C1）。两种都必须当脚本失败直接抛。
    ///
    /// 只认**整段输出的开头**（先 trim 空白），不用 contains：路径或消息中间出现
    /// "error:" 不能触发误判；消息体里含换行也一并保留。
    static func reportedScriptError(in output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(scriptErrorPrefix) else { return nil }
        let message = String(trimmed.dropFirst(scriptErrorPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "script reported an error" : message
    }

    /// reload 脚本输出 → 已重载的 variant 数；nil = 报告形状不认识（契约不匹配）。
    ///
    /// 为什么要区分 nil 与 0：0 是"C1 里没有选中项"的明确语义（→ .noSelection），
    /// 而无法解析的输出说明脚本被旧/新版 C1 改写了——那是脚本契约失败，必须带
    /// 原文上浮，不能用"没选中"掩盖。
    static func reloadedVariantCount(from output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 解析 G3 只读脚本输出（纯函数：测试直接驱动，不执行脚本）。
    ///
    /// 畸形行（前缀不认识 / 缺字段 / 数字非法 / W 行前面没有 P 记录）跳过并计入
    /// malformedLines：G3 的失败语义是「没有判断数据可映射」，而不是「整批失败」。
    static func parseVariantJudgements(_ output: String) -> C1VariantJudgementParseResult {
        var judgements: [C1VariantJudgement] = []
        var malformed: [String] = []
        var currentPath: String?
        var currentRating = 0
        var currentTag = 0
        var currentPick = false
        var currentKeywords: [String] = []

        func flush() {
            guard let path = currentPath, !path.isEmpty else { return }
            // rating 只有 0…5 合法；越界按上下界钳制（不整行丢弃，评级仍是可用信号）。
            judgements.append(C1VariantJudgement(
                photoPath: path,
                rating: max(0, min(5, currentRating)),
                colorTag: currentTag,
                pick: currentPick,
                keywords: currentKeywords))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            switch line.first {
            case "P":
                flush()
                currentPath = nil
                currentKeywords = []
                let fields = line.dropFirst()
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 4,
                      fields[1].hasPrefix("R"),
                      fields[2].hasPrefix("T"),
                      fields[3].hasPrefix("K"),
                      let rating = Int(fields[1].dropFirst()),
                      let tag = Int(fields[2].dropFirst()) else {
                    malformed.append(line)
                    continue
                }
                let pickRaw = String(fields[3].dropFirst())
                guard pickRaw == "0" || pickRaw == "1" else {
                    malformed.append(line)
                    continue
                }
                currentPath = Self.unescapeVariantField(fields[0])
                currentRating = rating
                currentTag = tag
                currentPick = pickRaw == "1"
            case "W":
                guard currentPath != nil else {
                    malformed.append(line)
                    continue
                }
                currentKeywords.append(
                    Self.unescapeVariantField(String(line.dropFirst())))
            default:
                malformed.append(line)
            }
        }
        flush()
        return C1VariantJudgementParseResult(
            judgements: judgements, malformedLines: malformed)
    }

    /// 还原脚本 escapeField 的转义：\\ → \、\n → 换行、\r → 回车、\t → TAB。
    /// 未知转义原样保留（不吞数据；是否需要报错由调用方按诊断决定）。
    static func unescapeVariantField(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }
            switch escaped {
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    /// 写回报告解析：每行 "1"/"0"，行数必须等于请求条目数；否则 nil（契约不匹配）。
    static func parseVariantWritebackReport(_ output: String, expected: Int) -> [String]? {
        let flags = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard flags.count == expected, flags.allSatisfy({ $0 == "1" || $0 == "0" }) else {
            return nil
        }
        return flags
    }

    /// 红标报告解析：行数 = 请求数、每行只能是 "0"/"1"/"2"；否则 nil（契约漂移）。
    static func parseRejectedColorTagReport(_ output: String, expected: Int) -> [String]? {
        let flags = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard flags.count == expected,
              flags.allSatisfy({ $0 == "0" || $0 == "1" || $0 == "2" }) else {
            return nil
        }
        return flags
    }

    /// R6 写前回读的分区（纯函数：C1BridgeWave3Tests 直接驱动）。
    ///
    /// 与变体级写回的 R1 同一规则：0 → notFound（当前集合没有）、1 → 可写（唯一目标）、
    /// 多 variant → 整条跳过并计数（不猜目标）。
    static func partitionRejectedColorTagPaths(
        paths: [String],
        counts: [Int]
    ) -> C1RejectedColorTagPartition {
        var result = C1RejectedColorTagPartition(writable: [], multiVariant: [], notFound: [])
        for (index, path) in paths.enumerated() {
            let count = index < counts.count ? counts[index] : 0
            if count == 0 {
                result.notFound.append(path)
            } else if count == 1 {
                result.writable.append(path)
            } else {
                result.multiVariant.append(path)
            }
        }
        return result
    }
}

/// G3 只读脚本的解析结果（internal：C1BridgeWave2Tests 直接驱动纯函数）。
struct C1VariantJudgementParseResult: Equatable {
    let judgements: [C1VariantJudgement]
    /// 无法解析的行原文：只进日志/诊断，导入侧不因畸形行失败。
    let malformedLines: [String]
}

/// R1 写前回读的分区结果（internal：C1BridgeWave3Tests 直接驱动纯函数）。
///
/// writable = 当前集合里恰好 1 个 variant（唯一目标，维持原写回）；
/// multiVariant = 多个 variant（不猜目标，整条跳过）；
/// notFound = 当前集合里没有（可按父目录 browse 补救一次）。
struct C1VariantTargetPartition: Equatable {
    var writable: [C1VariantWritebackItem]
    var multiVariant: [String]
    var notFound: [C1VariantWritebackItem]
}

/// Wave5 batch6 / R6 红标写回的分区结果（internal：C1BridgeWave3Tests 直接驱动）。
///
/// 与 C1VariantTargetPartition 同一口径：可写 = 当前集合里恰好 1 个 variant（唯一目标）；
/// multiVariant = 不猜目标、整条跳过；notFound = 当前集合里没有（可按父目录 browse 补救）。
struct C1RejectedColorTagPartition: Equatable {
    var writable: [String]
    var multiVariant: [String]
    var notFound: [String]
}

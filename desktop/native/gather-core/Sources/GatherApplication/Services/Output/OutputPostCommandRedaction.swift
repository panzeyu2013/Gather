// desktop/native/gather-core/Sources/GatherApplication/Services/Output/OutputPostCommandRedaction.swift
// Wave4b：导出后命令钩子结果的**落盘脱敏**。
//
// 背景：OutputPostCommandOutcome 的 command（用户命令模板）与 outputTail（命令输出
// 尾部）会被写进交付目录里的 manifest；用户很可能在命令里放 token/密码（curl -H
// "Authorization: Bearer …"、--token …），命令输出也可能回显这些值。manifest 是
// 本地审计文件、也可能被人工分享，所以写盘前统一做保守脱敏：
// - 保留命令结构/参数名，只把“看起来是凭据”的值替换成 ***；
// - 不删除 command/outputTail 本身（审计仍可用）；
// - 幂等：对已脱敏文本再跑一次不会继续变化。
import Foundation
import GatherProtocol

public enum OutputPostCommandRedaction {
    /// 对 outcome 的命令与输出尾部脱敏（其余字段原样）。
    public static func redacted(_ outcome: OutputPostCommandOutcome) -> OutputPostCommandOutcome {
        var copy = outcome
        copy.command = redactSecrets(in: outcome.command)
        if let tail = outcome.outputTail {
            copy.outputTail = redactSecrets(in: tail)
        }
        return copy
    }

    /// 文本脱敏（command 与 outputTail 共用）。
    public static func redactSecrets(in text: String) -> String {
        var result = text
        for rule in rules {
            do {
                let regex = try NSRegularExpression(pattern: rule.pattern)
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, options: [], range: range, withTemplate: rule.template)
            } catch {
                // 单个规则编译失败不影响其余规则；保守起见不抛错（写盘路径不能失败）。
                continue
            }
        }
        return result
    }

    private struct Rule {
        var pattern: String
        var template: String
    }

    /// 顺序有意义：先处理带前缀的值（Bearer/敏感 flag），再兜底裸 key 格式。
    private static let rules: [Rule] = [
        // Authorization: Bearer <token>
        Rule(
            pattern: "(?i)(bearer\\s+)([A-Za-z0-9._~+/=-]{8,})",
            template: "$1***"),
        // --token/--password/--secret/--api-key/--access-key/--session-token <value>
        Rule(
            pattern: "(?i)((?:--?|/)(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|session[_-]?token)(?:=|\\s+))([^\\s\"']+)",
            template: "$1***"),
        // x-amz-security-token: <value>（AWS 临时凭据）
        Rule(
            pattern: "(?i)(x-amz-security-token\\s*[:=]\\s*)(\\S+)",
            template: "$1***"),
        // 裸 key=value 形式（命令输出常见：token=... / password=...）
        Rule(
            pattern: "(?i)((?:^|[\\s;])(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|session[_-]?token)\\s*=\\s*)([^\\s\"']+)",
            template: "$1***"),
        // Authorization: <value>（非 Bearer 形式）
        Rule(
            pattern: "(?i)(authorization\\s*[:=]\\s*)([^\\s\"']{8,})",
            template: "$1***"),
        // aws_secret_access_key=<value>
        Rule(
            pattern: "(?i)(aws_secret_access_key\\s*[:=]\\s*)([^\\s\"']{8,})",
            template: "$1***"),
        // AWS access key id（固定形态）
        Rule(
            pattern: "AKIA[0-9A-Z]{16}",
            template: "***"),
    ]
}

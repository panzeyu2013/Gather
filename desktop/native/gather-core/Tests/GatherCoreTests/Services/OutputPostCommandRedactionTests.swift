// desktop/native/gather-core/Tests/GatherCoreTests/Services/OutputPostCommandRedactionTests.swift
// Wave4b / task-43：导出后命令钩子结果落盘前的脱敏（manifest 不保存命令令牌）。
//
// 覆盖：Bearer/token 参数/AWS access key/aws_secret_access_key/x-amz-security-token
// 被替换；普通文本与命令结构保留；脱敏幂等；outcome 其余字段不变。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("导出后命令钩子脱敏（Wave4b）")
struct OutputPostCommandRedactionTests {
    @Test("command：Bearer / --token / x-amz-security-token 值被替换")
    func redactsCommandSecrets() {
        let command = "/usr/bin/curl -H \"Authorization: Bearer TOPSECRET-ABC123\" "
            + "--token abc123 --secret=super-secret-value https://example.com/x"
        let redacted = OutputPostCommandRedaction.redactSecrets(in: command)
        #expect(!redacted.contains("TOPSECRET-ABC123"))
        #expect(!redacted.contains("abc123"))
        #expect(!redacted.contains("super-secret-value"))
        #expect(redacted.contains("--token ***"))
        #expect(redacted.contains("https://example.com/x"))
        // 幂等：再跑一次不继续变化。
        #expect(OutputPostCommandRedaction.redactSecrets(in: redacted) == redacted)
    }

    @Test("outputTail：AWS access key / secret / 头值被替换，普通输出保留")
    func redactsOutputTailSecrets() {
        let tail = "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
            + "aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
            + "x-amz-security-token: SESSION-TOKEN-VALUE\n"
            + "uploaded 12 files"
        let redacted = OutputPostCommandRedaction.redactSecrets(in: tail)
        #expect(!redacted.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(!redacted.contains("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
        #expect(!redacted.contains("SESSION-TOKEN-VALUE"))
        #expect(redacted.contains("uploaded 12 files"))
    }

    @Test("普通文本不变；outcome 的命令/输出被脱敏、其余字段原样")
    func redactsOutcomeOnly() {
        #expect(OutputPostCommandRedaction.redactSecrets(in: "echo hello world")
                == "echo hello world")
        let outcome = OutputPostCommandOutcome(
            command: "/bin/echo --token abc123",
            exitCode: 0,
            timedOut: false,
            durationMilliseconds: 42,
            error: nil,
            outputTail: "token=abc123")
        let redacted = OutputPostCommandRedaction.redacted(outcome)
        #expect(!redacted.command.contains("abc123"))
        #expect(!(redacted.outputTail ?? "").contains("abc123"))
        #expect(redacted.exitCode == 0)
        #expect(redacted.timedOut == false)
        #expect(redacted.durationMilliseconds == 42)
        #expect(redacted.error == nil)
        #expect(redacted != outcome)
    }
}

// desktop/native/gather-core/Sources/GatherCoreHelper/main.swift
// gather-core-helper 入口（1.3）：stdout JSON 行协议循环。
// 只做 stdin/stdout 胶水；核心路由逻辑在 GatherCore.HelperProtocol。

import Foundation
import GatherCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// 调用方关闭管道时避免默认 SIGPIPE 杀进程，让写入自然失败、循环继续。
signal(SIGPIPE, SIG_IGN)

// 日志一律走 stderr，stdout 只承载 JSON 响应行，互不污染。
func log(_ message: String) {
    FileHandle.standardError.write(Data("[gather-core-helper] \(message)\n".utf8))
}

log("started, waiting for requests on stdin")

while let line = readLine() {
    guard let response = HelperProtocol.handleLine(line) else { continue }
    FileHandle.standardOutput.write(response)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

log("stdin closed, exiting")

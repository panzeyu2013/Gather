// swift-tools-version: 5.9
// Gather Swift 核心库（P1 起）。无外部依赖，仅系统框架（Foundation）。
import PackageDescription
import Foundation

// 审计 P2-构建：CLT 搜索路径仅在本机只装 Command Line Tools（无完整 Xcode）
// 时才有必要——Swift Testing 框架位于 CLT 的 Library/Developer/Frameworks。
// 探测 CLT 框架存在且 Xcode 缺失时添加，避免环境耦合 hack。
#if os(macOS)
private let cltFrameworksPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
private let needsCLTSearchPaths =
    FileManager.default.fileExists(atPath: "\(cltFrameworksPath)/SwiftTesting.framework")
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

let testSwiftSettings: [SwiftSetting] = needsCLTSearchPaths ? [
    .unsafeFlags(["-F", cltFrameworksPath]),
] : []
let testLinkerSettings: [LinkerSetting] = needsCLTSearchPaths ? [
    .unsafeFlags([
        "-Xlinker", "-F", "-Xlinker", cltFrameworksPath,
        "-Xlinker", "-rpath", "-Xlinker", "\(cltFrameworksPath)",
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ]),
] : []
#else
let testSwiftSettings: [SwiftSetting] = []
let testLinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "gather-core",
    platforms: [
        // 2.2 人脸推理依赖 VNGenerateFaceEmbeddingsRequest（macOS 14+）。
        .macOS(.v14),
    ],
    products: [
        .library(name: "GatherCore", targets: ["GatherCore"]),
        // helper 线协议可执行（1.3）：stdout JSON 行协议，供外部工具调用。
        .executable(name: "gather-core-helper", targets: ["GatherCoreHelper"]),
        // Similarity 基准（2.3 验收 2 万/5 万）：产出 JSON 行指标（对齐 scripts/*.mjs 风格）。
        .executable(name: "gather-core-benchmarks", targets: ["GatherCoreBenchmarks"]),
    ],
    targets: [
        .target(
            name: "GatherCore",
            dependencies: ["CSQLite"]
        ),
        // 系统 SQLite3 的 C 模块 shim（module.modulemap），Linux/macOS 双平台。
        .target(name: "CSQLite"),
        .executableTarget(
            name: "GatherCoreHelper",
            dependencies: ["GatherCore"]
        ),
        .executableTarget(
            name: "GatherCoreBenchmarks",
            dependencies: ["GatherCore"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "GatherCoreTests",
            dependencies: ["GatherCore"],
            exclude: ["Reconciliation/Fixtures", "Reconciliation/README.md"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)

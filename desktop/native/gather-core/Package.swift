// swift-tools-version: 5.9
// Gather Swift 核心库（P1 起）。无外部依赖，仅系统框架（Foundation）。
import PackageDescription

// 本机仅装 Command Line Tools（无完整 Xcode）时，Swift Testing 框架位于 CLT 的
// Library/Developer/Frameworks，需显式加入搜索路径与运行期 rpath（仅 macOS）。
// Linux 上这些路径不存在，跳过；装有 Xcode / 官方 swift.org toolchain 的机器
// 亦无需这些路径。
#if os(macOS)
let testSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
    ]),
]
let testLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-F", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ]),
]
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

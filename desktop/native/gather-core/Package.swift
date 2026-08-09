// swift-tools-version: 5.9
// Gather Swift 核心库（P1 起）。无外部依赖，仅系统框架（Foundation）。
import PackageDescription

let package = Package(
    name: "gather-core",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "GatherCore", targets: ["GatherCore"]),
    ],
    targets: [
        .target(name: "GatherCore"),
        .testTarget(
            name: "GatherCoreTests",
            dependencies: ["GatherCore"],
            swiftSettings: [
                // 本机仅装 Command Line Tools（无完整 Xcode），Swift Testing 框架位于
                // CLT 的 Library/Developer/Frameworks，需显式加入搜索路径与运行期 rpath。
                // 装有 Xcode 的机器上这些路径不存在，编译器/链接器会静默忽略，可整体删除。
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-rpath", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-rpath", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ]),
            ]
        ),
    ]
)

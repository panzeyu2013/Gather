// swift-tools-version: 6.0
// Gather 原生宿主 app。
// SwiftUI 页面与 GatherCore 同进程运行；CommandRouter 复用
// gather-core 的 Protocol 与 HelperProtocol 信封约定。
import PackageDescription

// Swift 6 语言模式：与 gather-core 一致（tools 6.0 + 显式 language mode），
// 使并发诊断在 app 与 core 之间保持同一严格度。
let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "gather-app",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "gather-app", targets: ["GatherApp"]),
    ],
    dependencies: [
        .package(path: "../gather-core"),
    ],
    targets: [
        .executableTarget(
            name: "GatherApp",
            dependencies: [
                .product(name: "GatherCore", package: "gather-core"),
            ],
            path: ".",
            exclude: ["Tests", "Resources/Info.plist"],
            sources: [
                "Sources/GatherApp",
                "Settings",
                "FaceKeywording",
                "Duplicates",
                "Culling",
                "Export",
                "ControlCenter",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swift6Settings
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: ["GatherApp"],
            swiftSettings: swift6Settings
        ),
    ]
)

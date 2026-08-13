// swift-tools-version: 5.9
// Gather 原生宿主 app。
// SwiftUI 页面与 GatherCore 同进程运行；CommandRouter 复用
// gather-core 的 Protocol 与 HelperProtocol 信封约定。
import PackageDescription

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
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: ["GatherApp"]
        ),
    ]
)

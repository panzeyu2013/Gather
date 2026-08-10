// swift-tools-version: 5.9
// Gather 原生宿主 app（Phase 3.0 起）。
// SwiftUI 宿主 + WKWebView 托管残余 React 页（Strangler Fig 换壳），
// 桥契约复用 gather-core 的 Protocol（1.1）与 HelperProtocol 信封约定。
import PackageDescription

let package = Package(
    name: "gather-app",
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
            exclude: ["Resources/renderer-dist"]
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: ["GatherApp"]
        ),
    ]
)

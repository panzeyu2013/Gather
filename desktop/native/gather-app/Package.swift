// swift-tools-version: 6.0
// Gather 原生宿主 app。
// SwiftUI 页面与 GatherCore 同进程运行；CommandRouter 复用
// gather-core 的 Protocol 与 HelperProtocol 信封约定。
import PackageDescription
import Foundation

// Swift 6 语言模式：与 gather-core 一致（tools 6.0 + 显式 language mode），
// 使并发诊断在 app 与 core 之间保持同一严格度。
let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

/// 部署目标：app 仍可在 macOS 14 上运行。
let macOSDeploymentTarget = "14.0"

/// 真实 SDK 版本，写进 Mach-O 的 `LC_BUILD_VERSION.sdk`。
///
/// **为什么需要显式传**：SwiftPM 用 `-target arm64-apple-macosx14.0` 驱动编译，
/// Swift driver 于是把 `-platform_version macos 14.0 14.0` 交给 ld —— 二进制里
/// 记下的「SDK 版本」其实是**部署目标**，不是真实 SDK。
///
/// 从 macOS 26 起 AppKit 用这个字段做 linked-on-or-after 判定：
/// 记成 `sdk 14.0` 的 app 会被**强制渲染旧外观**（矩形按钮、不透明侧栏、
/// 旧窗口圆角、Toolbar 不进玻璃），Liquid Glass 一个都拿不到 ——
/// 哪怕链接的是 MacOSX27.0.sdk、运行在 macOS 27 上。
///
/// 这里读出真实 SDK 版本并显式补上，等同于 Xcode 工程自动生成的
/// `-platform_version macos <部署目标> <SDK 版本>`。
let macOSSDKVersion: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return macOSDeploymentTarget }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let value = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // 取不到就退回部署目标（等价于今天的行为，不会更糟）。
    return value.isEmpty ? macOSDeploymentTarget : value
}()

/// 让 AppKit 认得出「这个 app 是用支持 Liquid Glass 的 SDK 构建的」。
/// 开发时可覆盖：`GATHER_SDK_VERSION=27.0 swift build`。
let designSDKVersion = ProcessInfo.processInfo.environment["GATHER_SDK_VERSION"] ?? macOSSDKVersion

/// 每个参数都要 `-Xlinker` 前缀：SwiftPM 经 swiftc 链接，
/// `-platform_version` 是 ld 的参数，swiftc 自己不认（会报
/// `unknown argument: '-platform_version'`）。
let liquidGlassLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Xlinker", "-platform_version",
        "-Xlinker", "macos",
        "-Xlinker", macOSDeploymentTarget,
        "-Xlinker", designSDKVersion,
    ]),
]

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
            swiftSettings: swift6Settings,
            linkerSettings: liquidGlassLinkerSettings
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: ["GatherApp"],
            swiftSettings: swift6Settings
        ),
    ]
)

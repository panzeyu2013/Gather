// swift-tools-version: 6.0
// Gather 原生宿主 app。
//
// Cut 3 / 3b-2+3 拆分、3b-6 收口：从单 target 拆成 GatherUI（页面/视图模型，
// 只依赖 GatherProtocol）+ GatherHost（组合根/Live API/启动装配，依赖四层 core）+
// GatherApp（只剩 @main 与 Scene 的可执行）。过渡伞 GatherCore 已删除，app 包
// 只依赖四个分层 product；依赖方向严格单向：
//
//   GatherApp → GatherHost → GatherUI → GatherProtocol
//                    ↘ GatherPersistence / GatherAnalysis / GatherDomain → GatherProtocol
//
// GatherUI **不得** import GatherPersistence / GatherDomain / GatherAnalysis /
// GatherHost：跨域能力一律经 GatherProtocol 的 API 协议或 GatherUI 内的端口
// 协议注入（编译期由 build.sh / CI 的 --explicit-target-dependency-import-check
// error 守住）。Info.plist 在 GatherUI/Support（由 build.sh 拷入 app bundle），
// 本地化表在 GatherUI/Resources（gather-app_GatherUI.bundle）。
import PackageDescription
import Foundation

// Swift 6 语言模式：与 gather-core 一致（tools 6.0 + 显式 language mode），
// 使并发诊断在 app 与 core 之间保持同一严格度。
let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

/// 部署目标：app 仍可在 macOS 14 上运行。
let macOSDeploymentTarget = "14.0"

/// 真实 SDK 版本，写进 Mach-O 的 LC_BUILD_VERSION.sdk。
///
/// **为什么需要显式传**：SwiftPM 用 -target arm64-apple-macosx14.0 驱动编译，
/// Swift driver 于是把 -platform_version macos 14.0 14.0 交给 ld —— 二进制里
/// 记下的「SDK 版本」其实是**部署目标**，不是真实 SDK。
///
/// 从 macOS 26 起 AppKit 用这个字段做 linked-on-or-after 判定：
/// 记成 sdk 14.0 的 app 会被**强制渲染旧外观**（矩形按钮、不透明侧栏、
/// 旧窗口圆角、Toolbar 不进玻璃），Liquid Glass 一个都拿不到 ——
/// 哪怕链接的是 MacOSX27.0.sdk、运行在 macOS 27 上。
///
/// 这里读出真实 SDK 版本并显式补上，等同于 Xcode 工程自动生成的
/// -platform_version macos <部署目标> <SDK 版本>。
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
/// 开发时可覆盖：GATHER_SDK_VERSION=27.0 swift build。
let designSDKVersion = ProcessInfo.processInfo.environment["GATHER_SDK_VERSION"] ?? macOSSDKVersion

/// 每个参数都要 -Xlinker 前缀：SwiftPM 经 swiftc 链接，
/// -platform_version 是 ld 的参数，swiftc 自己不认（会报
/// unknown argument: '-platform_version'）。
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
        // 页面层：SwiftUI 视图 + 视图模型 + 本地化资源。
        // 只依赖 GatherProtocol；资源 bundle 名为 gather-app_GatherUI.bundle。
        .target(
            name: "GatherUI",
            dependencies: [
                .product(name: "GatherProtocol", package: "gather-core"),
            ],
            path: "Sources/GatherUI",
            exclude: ["Support/Info.plist"],
            resources: [
                // en.lproj / zh-Hans.lproj（Localizable.strings）。
                .process("Resources"),
            ],
            swiftSettings: swift6Settings
        ),
        // 宿主编排层：AppBootstrap / AppComposition / Live API / RootView / C1 桥。
        // 可 import 全部四层 core，并向上只暴露给 GatherApp（同包内 package）。
        .target(
            name: "GatherHost",
            dependencies: [
                "GatherUI",
                .product(name: "GatherProtocol", package: "gather-core"),
                .product(name: "GatherPersistence", package: "gather-core"),
                .product(name: "GatherAnalysis", package: "gather-core"),
                .product(name: "GatherDomain", package: "gather-core"),
            ],
            path: "Sources/GatherHost",
            swiftSettings: swift6Settings
        ),
        // 可执行：@main + Scene/WindowGroup/Settings/Commands。
        // Liquid Glass 的 linker flags 只对最终可执行生效。
        .executableTarget(
            name: "GatherApp",
            dependencies: ["GatherHost", "GatherUI"],
            path: "Sources/GatherApp",
            swiftSettings: swift6Settings,
            linkerSettings: liquidGlassLinkerSettings
        ),
        .testTarget(
            name: "GatherAppTests",
            dependencies: [
                "GatherUI", "GatherHost",
                .product(name: "GatherProtocol", package: "gather-core"),
                .product(name: "GatherPersistence", package: "gather-core"),
                .product(name: "GatherAnalysis", package: "gather-core"),
                .product(name: "GatherDomain", package: "gather-core"),
            ],
            swiftSettings: swift6Settings
        ),
    ]
)

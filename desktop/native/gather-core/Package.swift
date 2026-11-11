// swift-tools-version: 6.2
// Gather Swift 核心库（Cut 3 / 3a，3b-6 删除过渡伞）。分层 target + 元数据写盘 target
// + schema 工具/基准可执行 + 测试基建。
// 语言模式固定为 Swift 6：并发安全检查为硬错误（不再依赖 Swift 5 模式的警告）。
import PackageDescription
import Foundation

/// Swift 6 语言模式：全仓目标统一（含 benchmarks / 测试）。
let swift6Settings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

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
        // 只支持 macOS 26+（2026-10-29）：与 CI runner、Liquid Glass 的 SDK 判定同口径。
        .macOS(.v26),
    ],
    products: [
        // Cut 3：4 个分层库（依赖方向 Protocol ← Persistence / Analysis ← Application）。
        // WP2a：交付引擎单列 GatherDelivery（Protocol + Persistence ← Delivery ← Application）。
        .library(name: "GatherProtocol", targets: ["GatherProtocol"]),
        .library(name: "GatherPersistence", targets: ["GatherPersistence"]),
        .library(name: "GatherDelivery", targets: ["GatherDelivery"]),
        .library(name: "GatherAnalysis", targets: ["GatherAnalysis"]),
        .library(name: "GatherApplication", targets: ["GatherApplication"]),
        // #1：XMP/JPEG/IPTC 写盘实现（从 gather-app 的 GatherHost 抽出）。
        .library(name: "GatherMetadataIO", targets: ["GatherMetadataIO"]),
        // WP7：core 测试共享夹具作为 library product 暴露，供 gather-app 的
        // GatherAppTests 复用（只进测试链接，不改变 core 运行时；app 不链接它）。
        .library(name: "GatherTestSupport", targets: ["GatherTestSupport"]),
        // Cut 3 / 3a-5（D-015）：schema 工具可执行（dump / verify）。
        .executable(name: "gather-schema", targets: ["GatherSchema"]),
        // P0 / T0：真实集质量门 CLI。
        .executable(name: "gather-triage-eval", targets: ["GatherTriageEval"]),
        // Similarity 基准（2.3 验收 2 万/5 万）：产出 JSON 行指标（对齐 scripts/*.mjs 风格）。
        .executable(name: "gather-core-benchmarks", targets: ["GatherCoreBenchmarks"]),
        .executable(name: "gather-face-benchmarks", targets: ["GatherFaceBenchmarks"]),
    ],
    targets: [
        // 0 依赖：DTO / API 协议 / GatherError / PhotoFileTypes / Logging。
        .target(
            name: "GatherProtocol",
            swiftSettings: swift6Settings
        ),
        // Cut 3 / 3a-5（D-015）：schema 工具。DDL 的真相源在 GatherPersistence
        // （SchemaV1.swift），本 target 只做 dump / verify，不导出库。
        .executableTarget(
            name: "GatherSchema",
            dependencies: ["GatherPersistence"],
            path: "Sources/GatherSchema",
            swiftSettings: swift6Settings
        ),
        // P0 / T0：真实集质量门 CLI（只读打开库 + 纯函数评估；不写建议/决策/XMP）。
        .executableTarget(
            name: "GatherTriageEval",
            dependencies: ["GatherProtocol", "GatherPersistence", "GatherApplication", "GatherAnalysis"],
            path: "Sources/GatherTriageEval",
            swiftSettings: swift6Settings
        ),
        // 数据库层：唯一 import CSQLite 的模块（DDL 的真相源）。
        .target(
            name: "GatherPersistence",
            dependencies: ["GatherProtocol", "CSQLite"],
            swiftSettings: swift6Settings
        ),
        // WP2a 交付引擎：DeliveryCoordinator / WritebackService / MetadataMutationService /
        // XMPFileLock。只依赖 Protocol + Persistence；不得 import Application/Analysis/UI/Host。
        .target(
            name: "GatherDelivery",
            dependencies: ["GatherProtocol", "GatherPersistence"],
            swiftSettings: swift6Settings
        ),
        // 分析层：Face / Image / Concurrent / Similarity；FaceModels 资源随 target。
        .target(
            name: "GatherAnalysis",
            dependencies: ["GatherProtocol"],
            resources: [.copy("Resources/FaceModels")],
            swiftSettings: swift6Settings
        ),
        // 应用层：Services/**（组合 Delivery + Persistence + Analysis）。
        // WP3a：GatherDomain → GatherApplication（纯重命名，依赖边不变）。
        // WP2a：Application 依赖 Delivery（Culling/FaceKw/Similarity/Metadata 的交付编排）。
        .target(
            name: "GatherApplication",
            dependencies: ["GatherProtocol", "GatherPersistence", "GatherDelivery", "GatherAnalysis"],
            swiftSettings: swift6Settings
        ),
        // #1：元数据写盘（sidecar XMP / 内嵌 JPEG XMP+IPTC / 写目标路由）。
        //
        // 为什么从宿主搬下来：写盘真相住在 app target 时，「delivered == 磁盘上真的
        // 写了」这条不变量只能在 app 测试里验证；搬下来后 core 侧的交付集成测试可以
        // 直接驱动真实 adapter。
        //
        // 依赖已按 #1 C4/C5 收窄完成：只留 Protocol + Persistence + Analysis。
        // 曾经的 Application 依赖（内嵌解析/合并工具）已上移 GatherProtocol，
        // Delivery 依赖（备份白名单）已上移 XMPBackupNaming。
        .target(
            name: "GatherMetadataIO",
            // #1 C4/C5：只依赖 Protocol + Persistence + Analysis（ImageIO 读取实现在
            // Analysis）。不再依赖 Application / Delivery —— 它是被宿主装配的叶子适配器。
            dependencies: [
                "GatherProtocol", "GatherPersistence", "GatherAnalysis",
            ],
            swiftSettings: swift6Settings
        ),
        // 系统 SQLite3 的 C 模块 shim（module.modulemap），Linux/macOS 双平台。
        .target(name: "CSQLite"),
        // Cut 3 / 3a-4：core 测试共享 fixture（原 RepoTestSupport.swift + Support/AsyncGate.swift）。
        // 普通 library target + public API（不用 @testable，见 module-split-map-v2 §5.2）。
        // B04：ServiceConstructionTestSupport（344 行，core/app 逐字重复）合并到此，
        // 故额外依赖 Delivery / Analysis / Application；只进测试链接。
        .target(
            name: "GatherTestSupport",
            dependencies: [
                "GatherProtocol", "GatherPersistence", "GatherDelivery", "GatherAnalysis",
                "GatherApplication",
            ],
            path: "Tests/GatherTestSupport",
            swiftSettings: swift6Settings
        ),
        // 基准直接依赖 Protocol + Analysis（3a-5 起不再经过渡伞）。
        .executableTarget(
            name: "GatherCoreBenchmarks",
            dependencies: ["GatherProtocol", "GatherAnalysis"],
            exclude: ["README.md"],
            swiftSettings: swift6Settings
        ),
        .executableTarget(
            name: "GatherFaceBenchmarks",
            dependencies: ["GatherProtocol", "GatherAnalysis"],
            swiftSettings: swift6Settings
        ),
        .testTarget(
            name: "GatherCoreTests",
            dependencies: [
                "GatherProtocol", "GatherPersistence", "GatherDelivery", "GatherAnalysis",
                "GatherApplication",
                // #1 C2：元数据写盘（XMP/JPEG/IPTC）的测试从 app 迁回 core。
                "GatherMetadataIO",
                "GatherTestSupport",
                "CSQLite",
            ],
            exclude: ["Reconciliation/Fixtures", "Reconciliation/README.md"],
            swiftSettings: testSwiftSettings + swift6Settings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
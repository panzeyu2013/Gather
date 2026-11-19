// desktop/native/gather-app/Sources/GatherHost/C1/CaptureOneFacade.swift
// M1（Wave4 / task-6）：从 AppBootstrap.swift 拆出的 C1 UI 门面 + Session 目录导入适配，
// 以及摄取成功后的自动初审调度装饰器（TriageSchedulingSessionAPI）。
//
// 纯移动：三个类型的成员逐行未改；装配仍在 AppBootstrap.makeScene / wire。
import Foundation
import GatherProtocol
import GatherUI
// MARK: - Wave3：C1 门面 + Session 目录导入（G4/G5/G6）

/// UI 侧 C1 门面：协调器（reload/选中/预检）+ 具体桥（变体级写回）。
///
/// 为什么需要：`RootShellDependencies.captureOne` 既要让 UI 的
/// `as? C1RoundTripReloading / C1RoundTripExtending` 动态派发成立（手动/自动 reload
/// 共用串行队列、在 C1 中显示），又要暴露只有具体桥才有的变体级写回能力。组合根用
/// 一个门面同时委托两者，避免让 coordinator 反向依赖写回实现。
@MainActor
final class CaptureOneBridgeFacade: CaptureOneBridging, C1RoundTripReloading, C1RoundTripExtending {
    private let coordinator: C1RoundTripCoordinator
    private let bridge: CaptureOneBridge
    /// 协议要求是同步 nonisolated 属性；在 MainActor 门面上按 init 时快照实现，
    /// 避免"@MainActor 类型满足非隔离协议要求"触发 ConformanceIsolation。
    private nonisolated let c1InstalledSnapshot: Bool

    init(coordinator: C1RoundTripCoordinator, bridge: CaptureOneBridge) {
        self.coordinator = coordinator
        self.bridge = bridge
        self.c1InstalledSnapshot = bridge.c1Installed
    }

    nonisolated var c1Installed: Bool { c1InstalledSnapshot }

    // MARK: CaptureOneBridging（reloadMetadata 同时满足 C1RoundTripReloading 的同签名要求）

    func selectedPhotoPaths() async throws -> [String] {
        try await coordinator.selectedPhotoPaths()
    }

    func reloadMetadata(sessionId: String) async throws {
        try await coordinator.reloadMetadata(sessionId: sessionId)
    }

    func checkHealth() async -> Result<String, CaptureOneBridgeError> {
        await coordinator.checkHealth()
    }

    func preflight() async -> C1PreflightStatus {
        await coordinator.preflight()
    }

    nonisolated static func documentProbeScript(appName: String) -> String {
        C1RoundTripCoordinator.documentProbeScript(appName: appName)
    }

    func writeVariantJudgements(
        sessionId: String?,
        items: [C1VariantWritebackItem]
    ) async throws -> C1VariantWritebackReport {
        try await bridge.writeVariantJudgements(sessionId: sessionId, items: items)
    }

    /// P2（Wave4b）：转发具体桥的本机安装判定（Hot Folder 提示 gate）。

    // MARK: C1RoundTripReloading

    func noteDeliveryStateChanged(sessionId: String) {
        coordinator.noteDeliveryStateChanged(sessionId: sessionId)
    }

    func currentAutoReloadFailure() -> C1AutoReloadFailure? {
        coordinator.currentAutoReloadFailure()
    }

    func clearAutoReloadFailure() {
        coordinator.clearAutoReloadFailure()
    }

    // MARK: C1RoundTripExtending

    func selectVariants(paths: [String]) async throws -> C1SelectionOutcome {
        try await coordinator.selectVariants(paths: paths)
    }

    func adjustmentHints(paths: [String]) -> [C1AdjustmentHint] {
        coordinator.adjustmentHints(paths: paths)
    }
}

/// C1 Session 根目录导入的扫描根重定向（Wave3 / G6，A5 起与新建工作区共用同一 helper）。
///
/// C1 Session 根 = Capture（原始）+ Selects（挑中/移动后的文件）+ Trash（淘汰）。
/// 把根当普通目录递归会让 Trash 淘汰件"复活"成普通资产，并在 Capture/Selects 之间
/// 产生重复。这里识别到 session 结构后**只把 Capture 交给后续导入**（会话 source_path
/// = Capture → 监听/摄取也在 Capture 内；Trash 不扫；Selects 因不扫描而不重复）。
/// 识别/重定向规则在 `C1SessionDirectoryResolver.importPlan`（协议层，Host 与
/// GatherUI 的新建工作区面板共用）；本类型只做 ImportFolderSelection 适配。
/// 已知边界：Selects 中与 Capture 不同名的文件（C1 "Move to Selects" 移动过）本次
/// 不会导入——完整覆盖需要索引器支持按目录排除/去重（不在本波范围，见汇报）。
enum C1SessionDirectoryImport {
    static func redirect(_ selection: ImportFolderSelection) -> ImportFolderSelection {
        guard case .directory(let url) = selection else { return selection }
        guard let plan = C1SessionDirectoryResolver.importPlan(root: url.path) else {
            return selection
        }
        GatherLogger.log(
            "c1.session import scanRoot=\(plan.scanRoot)"
                + " originalRoot=\(plan.originalRoot)"
                + " selects=\(plan.layout.selects != nil)"
                + " trash=\(plan.layout.trash != nil)",
            level: .info)
        return .directory(URL(fileURLWithPath: plan.scanRoot))
    }
}

// MARK: - 摄取成功后的 AI 初审调度（Wave5 batch3 / task-19）

/// 摄取成功后的自动初审调度装饰器（导入入口的第六个/第七个）。
///
/// 为什么在 SessionAPI 层装饰：摄取面板（GatherUI）只依赖 SessionAPI，不能 import
/// GatherHost；而自动初审的调度器需要 JobService/DB/Settings。宿主把 UI 依赖里的
/// session 包一层，只有 ingest 成功后触发回调：
/// - **只在 success 且 registered > 0 时调度**：全被跳过（同一张卡重导）不做无用功；
/// - 失败/取消照原样抛出（摄取结果不被调度污染），调度发生在返回之后（不增加延迟）；
/// - 其它方法一律透传，不影响任何既有调用方。
/// 与其它导入入口同语义：只调度、不等待；真正的 pipeline 仍在后台任务里。
struct TriageSchedulingSessionAPI: SessionAPI {
    let base: any SessionAPI
    /// 摄取成功后的副作用（宿主注入 AITriageAutoScheduler.schedule；测试注入记录器）。
    let onIngestSucceeded: @Sendable (String) -> Void

    func list() async throws -> [SessionData] { try await base.list() }

    func get(_ sessionId: String) async throws -> SessionData {
        try await base.get(sessionId)
    }

    func create(_ input: SessionCreateInput) async throws -> SessionCreateResult {
        try await base.create(input)
    }

    func update(_ input: SessionUpdateParams) async throws -> SessionData {
        try await base.update(input)
    }

    func delete(_ input: Confirmed<SessionDeleteInput>) async throws {
        try await base.delete(input)
    }

    func addPhotos(_ input: SessionAddPhotosInput) async throws -> AddPhotoResult {
        try await base.addPhotos(input)
    }

    func ingest(_ input: Confirmed<SessionIngestInput>) async throws -> SessionIngestResult {
        let result = try await base.ingest(input)
        if result.registered > 0 {
            onIngestSucceeded(input.value.sessionId)
        }
        return result
    }

    func previewIngest(_ input: SessionIngestInput) async throws -> SessionIngestPreview {
        try await base.previewIngest(input)
    }

    func setSourceRoot(
        _ input: Confirmed<SessionSetSourceRootInput>
    ) async throws -> SessionData {
        try await base.setSourceRoot(input)
    }

    func status(_ sessionId: String) async throws -> WorkspaceStatus {
        try await base.status(sessionId)
    }
}

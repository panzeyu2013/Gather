// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsViewModel.swift
// Cut 4 / 4c-2d：从 SettingsView.swift 第 100-995 行拆出（VM 状态/依赖/init 主体）。
// 拆分口径：状态与 init 留本文件；数据加载/语言/重置 -> +Loading，分组字段与滑杆 ->
// +Fields，C1 四层预检 -> +C1Health，写回队列 -> +Sync，模型下载 -> +Download，
// 静态配置表（分组/滑杆/label）-> +Catalog。
//
// 跨文件 extension 只能访问 internal 成员：原 private 依赖与可写状态改为 internal
// （public internal(set) 保留只读对外语义），行为与访问路径不变。
//
// Phase 3.6：设置与模型状态（TS 源：pages/Settings/index.tsx + C1HealthPanel.tsx）。
// 设置读写全部走 SettingsAPI；语言本地状态只经注入的 LanguageStore 写（4a-3a）。
import SwiftUI
import GatherProtocol

@MainActor
@Observable
public final class SettingsViewModel {
    /// Cut 1 / B8.2a/B8.4：会话 / 设置 / 挑片三个域全部是类型化 API，
    /// 不再有字符串命令分支。
    let sessionAPI: any SessionAPI
    let settingsAPI: any SettingsAPI
    let cullingAPI: any CullingAPI
    /// C1 预检只用 checkHealth/preflight（不写 reload ack）；reload ack 的写
    /// 入口在 CaptureOneBridge 的其它注入点（B8.2e 统一为 recordReloadAck 闭包）。
    /// Cut 3 / 3b-3（E-17）：只持 Protocol 的能力面，实现由宿主显式注入。
    let captureOne: any CaptureOneBridging
    /// Cut 4 / 4a-3a：语言的唯一写入入口（本类不直接写旧全局语言，
    /// 持久化仍由 SettingsAPI 负责；4b-2g 起文案一律经传入的 L10n）。
    let languageStore: LanguageStore
    public internal(set) var values: [String: String] = [:]
    /// 分组设置行的编辑缓冲（未保存）。
    public var edits: [String: String] = [:]
    /// 滑杆拖动中的临时值（提交时才落库）。
    public var sliderValues: [String: Double] = [:]
    public internal(set) var modelStatus: MLStatusData?
    public internal(set) var errorMessage: CommandError?
    public internal(set) var notice: LocalizedText?
    public var language = "zh-CN"
    public var backend = "auto"

    // MARK: Capture One 健康面板

    public internal(set) var c1Health: C1HealthSnapshot?
    public internal(set) var c1HealthError = false
    public internal(set) var c1Checking = false

    // MARK: Capture One 写回队列（对齐 C1HealthPanel：culling.sync_status + 12s 轮询）

    public internal(set) var syncStatus: MetadataSyncSummary?
    /// 轮询目标会话：session.list 中 updatedAt 最新者（旧版
    /// sessionStore.currentSessionId 的会话级替代——设置页无当前会话上下文，
    /// 按旧版工作区页面的会话列表取最近会话）；nil = 无工作区。
    public internal(set) var syncSessionId: String?
    /// culling.sync_status 响应中的 reloadAckedAt（旧版 c1:sync-state 载荷字段，
    /// 对齐 C1HealthPanel 的最近同步时间；原生响应暂无该字段时为 nil）。
    public internal(set) var syncReloadAckedAt: String?
    public internal(set) var syncStateError = false
    /// refreshSyncState 的代次（B8.2a）：12s 轮询与 domainChanged 写路径事件可能
    /// 重叠，只允许最新一轮写状态（含 syncStateError），避免旧响应覆盖新快照。
    var syncStateGeneration = 0

    /// 最近同步时间（C-1 性能审计）：优先 reloadAckedAt（对齐 C1HealthPanel.tsx:147-155，
    /// 语义为 Capture One 最后一次 reload 确认时间），否则回退队列项 updatedAt 的最大值。
    /// 计算一次并缓存：旧实现是计算属性且直接写在 body 里，每次 body 都要对该会话
    /// **全部** outbox 行逐项 ISO 解析（无 LIMIT），叠加 12s 轮询 ⇒ 开着设置窗就是
    /// 每 12 秒一次秒级主线程停顿。写入方在 +Sync 的 recomputeLastSyncDate。
    public internal(set) var lastSyncDate: Date?

    // MARK: 模型下载（对齐旧版 installBanner + models.download_default）

    /// 安装流水线阶段（对齐旧版主进程 downloadDefaultModels 的 phase 语义：
    /// 下载 → 解压；进度条文案按此切换「已下载 xx%（文件名）/正在解压…」）。
    public enum ModelInstallStep: Equatable {
        case downloading
        case extracting
    }

    public enum ModelDownloadPhase: Equatable {
        case idle
        case downloading(filename: String, percent: Double, step: ModelInstallStep)
        case done
        case error
    }

    public internal(set) var downloadPhase: ModelDownloadPhase = .idle

    /// 生产装配（RootView / 宿主 Settings 场景）：三个域与 C1 桥均显式注入。
    /// Cut 3 / 3b-3（E-17）：删掉默认自建 CaptureOneBridge() 的分支——未注入
    /// 即编译错误，避免 reload ack 被静默丢弃。
    public init(
        session: any SessionAPI,
        settings: any SettingsAPI,
        culling: any CullingAPI,
        captureOne: any CaptureOneBridging,
        languageStore: LanguageStore
    ) {
        self.sessionAPI = session
        self.settingsAPI = settings
        self.cullingAPI = culling
        self.captureOne = captureOne
        self.languageStore = languageStore
    }
}

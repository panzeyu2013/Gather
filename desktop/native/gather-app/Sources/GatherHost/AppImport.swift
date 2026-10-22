// desktop/native/gather-app/Sources/GatherHost/AppImport.swift
// Cut 3 / 3b-1：原生导入入口（从 GatherApp.swift 抽出）。
//
// 覆盖三条共用同一实现的入口：菜单/Finder/deep-link（`importFiles`）、
// C1 菜单导入（source = "capture-one"）与工作台导入。失败展示仍走
// importCompleted 通知的 failedCount/examples（RootView toast），日志走 GatherLogger。
//
// R1 P1-3：metadata.scan 的 dedupeKey/checkpoint 规则已上移到 GatherProtocol
//（JobCreateParams.metadataScan）；本文件只传 sessionId + requestedPaths。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherUI

enum AppImport {
    /// 文件打开、菜单导入和 deep-link 共用同一条原生导入路径。
    ///
    /// **导入范围 === 用户显式选择集合**，目录导入与文件导入是两条明确语义：
    ///   · 目录导入：选择集合恰好是一个目录 → source_path = 该目录（唯一允许
    ///     递归的范围），扫描集合 = 该目录全树（job 不带 requestedPaths）；
    ///     照片由索引 job 发现，此处不预写照片行。
    ///   · 文件导入：其余情况（含「文件 + 目录」混合选择）→ source_path 留空，
    ///     扫描集合 = 用户选择的路径集合，由 job checkpoint 的 requestedPaths
    ///     携带；目录条目由索引器在其自身范围内展开。
    /// 历史缺陷：以所选文件的公共父目录充当 source_path，再入队不带路径的
    /// metadata.scan → 选 3 张照片等于递归扫描整个目录树（可上溯到 home）。
    /// 公共父目录现在**只用于取名**，绝不落库为 source_path。
    ///
    /// source/sourceLabel：C1 菜单导入传 "capture-one"/"Capture One 文件"
    /// （对齐旧版 c1:plugin-import 的来源标记与失败提示文案）；其余为
    /// "local"/"文件"。Cut 4 / 4b-3：两条文案都由调用方的 l10n 解析
    /// （en 界面分别是 capture-one / "Capture One Files"/"File"），本类型
    /// 不再读进程级 appLanguage。
    ///
    /// 成功建库后统一 post importCompleted（菜单/C1/deep-link 都走到这里），
    /// userInfo 键名见 GatherAppDelegate 的 GatherAppImportUserInfoKey。
    /// internal（非 private）：GatherAppDelegateTests 需要直调以断言通知内容。
    /// @MainActor：与拆分前 GatherApp.importFiles 的隔离一致（App 成员推断）。
    ///
    /// Cut 4 / 4b-3：`l10n` 由调用方（宿主装配的闭包）在**动作发生时**从
    /// LanguageStore 取当前语言传入——本类型不读进程全局，默认建库名（"C1 导入
    /// M/D H:mm" / "导入照片"）因此跟随界面语言。
    @MainActor
    static func importFiles(
        _ files: [String],
        composition: AppComposition,
        source: String = "local",
        sourceLabel: String = "",
        l10n: L10n
    ) {
        let normalized = normalizeImportFilepaths(files)
        guard !normalized.isEmpty else { return }
        do {
            let session: SessionData
            var failedFiles: [String] = []
            var added = 0
            var requestedPaths: [String]?
            if normalized.count == 1, isDirectory(normalized[0]) {
                // 目录作用域：name 传空 → 由目录 basename 命名。
                session = try composition.sessionService.createFromDirectory(
                    name: "", sourcePath: normalized[0], source: source
                )
                requestedPaths = nil
            } else {
                // 目录条目不写照片行（避免把目录当成一张「解码失败的照片」上报），
                // 交给索引器在 requestedPaths 范围内展开。
                let filepaths = normalized.filter { !isDirectory($0) }
                let parent = commonParentDirectory(filepaths: normalized)
                let name = parent.isEmpty
                    ? URL(fileURLWithPath: normalized[0]).deletingPathExtension().lastPathComponent
                    : URL(fileURLWithPath: parent).lastPathComponent
                // source_path 留空（= 显式文件集合作用域）：公共父目录只用于取名。
                // 若把 sanitizeSessionSourcePath 通过的父目录落库，监听器与
                // 「全量兜底」扫描（requestedPaths == nil）会绕开本 job 的
                // requestedPaths 重新递归该目录，重新引入「导入范围失控」。
                // 需要目录作用域的用户请走目录导入（拖入/打开文件夹）。
                session = try composition.sessionService.createSession(
                    name: name.isEmpty ? Self.defaultImportName(source: source, l10n: l10n) : name,
                    source: source
                )
                if !filepaths.isEmpty {
                    let result = try composition.sessionService.addPhotos(
                        sessionId: session.id,
                        filepaths: filepaths,
                        source: "import"
                    )
                    added = result.added
                    failedFiles = result.failedFiles
                }
                requestedPaths = normalized
            }
            _ = try composition.jobService.create(
                JobCreateParams.metadataScan(
                    sessionId: session.id, requestedPaths: requestedPaths))
            if !failedFiles.isEmpty {
                GatherLogger.log("import skipped \(failedFiles.count) files", level: .warn)
            }
            let examples = failedFiles
                .prefix(3)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .joined(separator: "、")
            NotificationCenter.default.post(
                name: GatherAppNotification.importCompleted,
                object: nil,
                userInfo: [
                    GatherAppImportUserInfoKey.sessionId: session.id,
                    GatherAppImportUserInfoKey.failedCount: failedFiles.count,
                    GatherAppImportUserInfoKey.addedCount: added,
                    GatherAppImportUserInfoKey.sourceLabel: sourceLabel,
                    GatherAppImportUserInfoKey.examples: examples,
                ]
            )
        } catch {
            GatherLogger.log("native import failed: \(error)", level: .error)
        }
    }

    /// Phase 4.3 一次性迁移：Vision feature print rev2 为 768 维，不能与
    /// 旧 512 维向量混用。首次启动原生宿主时切换 native
    /// embedding_dim，并为已有工作区排入 face.analyze；JobService 的
    /// dedupe/checkpoint 保证重启可续。真实照片集的 ARI/NMI 仍需发布前离线
    /// 验收，不在启动阶段伪造通过。
    @MainActor
    static func prepareNativeEmbeddingRerun(
        composition: AppComposition,
        settings: any SettingsAPI,
        databasePath: String
    ) async {
        let marker = "vision-feature-print-rev2-768-v1"
        // Scope the marker to the database. A global UserDefaults marker would
        // incorrectly skip the migration when a second library is opened.
        let markerKey = "gather.nativeEmbeddingVersion.\(databasePath)"
        guard UserDefaults.standard.string(forKey: markerKey) != marker else { return }
        do {
            // Cut 1 / B8.2d：settings.set 走 SettingsAPI（字符串命令不再出现在
            // 宿主；校验/错误语义与旧命令面分支一致：未知 key → INVALID_PARAM）。
            try await settings.set(SettingsSetInput(key: "embedding_dim", value: "768"))
            for session in try composition.sessionService.listSessions() where session.photoCount > 0 {
                _ = try composition.jobService.create(JobCreateParams(
                    type: .faceAnalyze,
                    scopeType: "session",
                    scopeId: session.id,
                    dedupeKey: "face.analyze:native-embedding:\(session.id)",
                    checkpoint: [
                        "detectorPath": .string("vision"),
                        "encoderPath": .string("vision-feature-print-rev2"),
                    ]
                ))
            }
            UserDefaults.standard.set(marker, forKey: markerKey)
        } catch {
            GatherLogger.log("native embedding migration deferred: \(error)", level: .warn)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// 对齐旧版 app.c1ImportName：C1 导入无公共父目录时使用
    /// 「C1 导入 M/D H:mm」（分钟补零）；其他来源回退「导入照片」。
    /// internal（非 private）：GatherAppDelegateTests 断言语言注入后的命名。
    static func defaultImportName(source: String, l10n: L10n) -> String {
        guard source == "capture-one" else { return l10n("导入照片") }
        let now = Date()
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return l10n.format(
            "C1 导入 %@",
            "\(month)/\(day) \(hour):\(String(format: "%02d", minute))"
        )
    }
}

// desktop/native/gather-app/Sources/GatherUI/Settings/ModelInstaller.swift
// Cut 4 / 4c-2d：默认模型包下载/解压/原子落位（旧版 model-downloader.ts 的 Swift 移植，
// 原 SettingsView.swift 1056-1232 行）。纯搬移：fileMap、整包回滚与 InstallError 文案不变。
import Foundation

// MARK: - 模型下载器（旧版 model-downloader.ts 的 Swift 移植）

/// 下载默认模型包（zip）→ 解压 → 按 fileMap 改名到模型目录。
/// 原生路由无 models.download_default 命令（face.models_status 恒
/// modelsPresent=true/downloading=false，Vision provider 不需要模型资产），
/// 故在设置页内用 Foundation 能力自给：settings.model_download_url 缺省
/// 用旧版 MODEL_CONFIG.download.packageUrl。
enum ModelInstaller {
    /// TS model-config.ts：MODEL_CONFIG.download.packageUrl。
    static let packageURL = "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
    /// TS fileMap：压缩包内文件名 → 模型目录目标名。
    static let fileMap: [String: String] = [
        "det_10g.onnx": "face_detector.onnx",
        "w600k_r50.onnx": "face_encoder.onnx",
    ]

    enum InstallError: LocalizedError {
        case badStatus
        case extractFailed
        case toolFailed(String)
        /// 问题 9：包缺必需文件 / 文件为空 —— 必须明确报错，不能静默继续。
        case missingFile(String)
        case emptyFile(String)

        /// 本地化文案（Cut 4 / 4b-2g）：错误只带 key + 参数，渲染期由调用方
        /// 传入的 L10n 解析；枚举本身不读进程全局语言。
        var text: LocalizedText {
            switch self {
            case .badStatus: LocalizedText("模型下载返回了非 2xx 状态码")
            case .extractFailed: LocalizedText("模型解压失败，请确保系统已安装 unzip 或 tar")
            case .toolFailed(let tool): LocalizedText("解压工具执行失败：%@", params: [tool])
            case .missingFile(let name): LocalizedText("模型包缺少必需文件：%@", params: [name])
            case .emptyFile(let name): LocalizedText("模型包中的文件为空：%@", params: [name])
            }
        }

        /// NSError 桥接只取 key 原文（稳定诊断）；上屏文案走 `text` + L10n。
        var errorDescription: String? { text.key }
    }

    static func install(
        url: URL,
        modelsDir: String,
        onProgress: @escaping @MainActor @Sendable (SettingsViewModel.ModelInstallStep, String, Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let http = response as? HTTPURLResponse
        if let http {
            guard (200..<300).contains(http.statusCode) else { throw InstallError.badStatus }
        } else if !url.isFileURL {
            // 非 HTTP 且非本地文件（问题 9 验收：允许 file:// 本地包，便于离线安装与测试）。
            throw InstallError.badStatus
        }
        let total = (http?.expectedContentLength).flatMap { $0 > 0 ? Double($0) : nil } ?? 0
        let tmpZip = fileManager.temporaryDirectory.appendingPathComponent("gather-models-\(UUID().uuidString).zip")
        let extractDir = fileManager.temporaryDirectory.appendingPathComponent("gather-models-extract-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: tmpZip)
            try? fileManager.removeItem(at: extractDir)
        }
        fileManager.createFile(atPath: tmpZip.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpZip)
        var downloaded: Double = 0
        do {
            // URLSession.AsyncBytes 逐字节产出：攒满一个块再写盘。
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    downloaded += Double(buffer.count)
                    await onProgress(.downloading, "buffalo_l.zip", total > 0 ? min(100, downloaded / total * 100) : 0)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                downloaded += Double(buffer.count)
                await onProgress(.downloading, "buffalo_l.zip", total > 0 ? min(100, downloaded / total * 100) : 0)
            }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()

        // 下载完成进入解压阶段（tar/unzip 无逐字节进度，保持 100% 与阶段文案）。
        await onProgress(.extracting, "buffalo_l.zip", 100)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        do {
            try Self.runTool("/usr/bin/tar", arguments: ["-xf", tmpZip.path, "-C", extractDir.path])
        } catch {
            do {
                try Self.runTool("/usr/bin/unzip", arguments: ["-o", tmpZip.path, "-d", extractDir.path])
            } catch {
                throw InstallError.extractFailed
            }
        }
        // 问题 9（第三轮审查）：旧实现「缺任一必需文件就 continue」，会把不完整
        // 的包当成功安装；且先删目标再 move，第二步失败会留下半套模型。
        // 这里：① 全部必需文件先校验存在且非空；② 先把全部文件搬到同目录暂存；
        // ③ 全部就绪后再逐个原子替换（replaceItemAt），任一步失败保留旧模型。
        var staged: [(staged: URL, dest: URL)] = []
        do {
            for (source, dest) in fileMap {
                let sourceURL = extractDir.appendingPathComponent(source)
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw InstallError.missingFile(source)
                }
                let size = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw InstallError.emptyFile(source) }
                staged.append((sourceURL, URL(fileURLWithPath: modelsDir).appendingPathComponent(dest)))
            }
            try fileManager.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
            let stagingDir = extractDir.appendingPathComponent(".gather-staging", isDirectory: true)
            try? fileManager.removeItem(at: stagingDir)
            try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            var moved: [(staged: URL, dest: URL)] = []
            for item in staged {
                let target = stagingDir.appendingPathComponent(item.dest.lastPathComponent)
                try? fileManager.removeItem(at: target)
                try fileManager.moveItem(at: item.staged, to: target)
                moved.append((target, item.dest))
            }
            // D7（深审）：单文件原子性 ≠ 整套原子性。逐个替换时第二个失败会留下
            // 「第一个新、第二个旧」的混合版本。改为：先把旧文件移出到同目录备份，
            // 全部就绪后依次放入；任一步失败即用备份**整体回滚**。
            var applied: [(dest: URL, backup: URL?)] = []
            do {
                for item in moved {
                    var backup: URL?
                    if fileManager.fileExists(atPath: item.dest.path) {
                        let backupURL = stagingDir.appendingPathComponent("prev-" + item.dest.lastPathComponent)
                        try? fileManager.removeItem(at: backupURL)
                        try fileManager.moveItem(at: item.dest, to: backupURL)
                        backup = backupURL
                    }
                    do {
                        try fileManager.moveItem(at: item.staged, to: item.dest)
                    } catch {
                        if let backup { try? fileManager.moveItem(at: backup, to: item.dest) }
                        throw error
                    }
                    applied.append((item.dest, backup))
                }
            } catch {
                // 整体回滚：已替换的恢复旧文件，本次新建的删除，保证「全旧或全新」。
                for entry in applied.reversed() {
                    if let backup = entry.backup {
                        try? fileManager.removeItem(at: entry.dest)
                        try? fileManager.moveItem(at: backup, to: entry.dest)
                    } else {
                        try? fileManager.removeItem(at: entry.dest)
                    }
                }
                try? fileManager.removeItem(at: extractDir.appendingPathComponent(".gather-staging"))
                throw error
            }
        } catch {
            // 失败：清理暂存，旧模型保持原样。
            try? fileManager.removeItem(at: extractDir.appendingPathComponent(".gather-staging"))
            throw error
        }
    }

    private static func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.toolFailed(path)
        }
    }
}

// Phase 3.6：设置与模型状态 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/Settings/index.tsx + C1HealthPanel。
import SwiftUI
import AppKit
import GatherCore

@MainActor
@Observable
public final class SettingsViewModel {
    private let client: NativeCommandClient
    private(set) public var values: [String: String] = [:]
    private(set) public var modelStatus: MLStatusData?
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    private(set) public var captureOneStatus = "未检查"
    public var selectedKey = "embedding_dim"
    public var editedValue = ""
    public var language = "zh-CN"
    public var backend = "auto"
    private let captureOne: CaptureOneBridge

    public init(router: CommandRouter) {
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
    }

    public func load() {
        do {
            values = try client.execute("settings.get_all").decoded(as: [String: String].self)
            modelStatus = try client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["onnx_provider"] ?? "auto"
            editedValue = values[selectedKey] ?? ""
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func select(_ key: String) {
        selectedKey = key
        editedValue = values[key] ?? ""
    }

    public func save() {
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string(selectedKey),
                "value": .string(editedValue),
            ])
            values[selectedKey] = editedValue
            notice = "已保存 \(selectedKey)"
            errorMessage = nil
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func setLanguage(_ value: String) {
        do {
            _ = try client.execute("settings.set_language", params: ["language": .string(value)])
            language = value
            values["ui_language"] = value
            notice = value == "en" ? "Language saved" : "语言已保存"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func setBackend(_ value: String) {
        do {
            _ = try client.execute("settings.set", params: [
                "key": .string("onnx_provider"),
                "value": .string(value),
            ])
            backend = value
            values["onnx_provider"] = value
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
            notice = "推理后端已保存"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func openModelDirectory() {
        guard let path = modelStatus?.modelResourcesDir, !path.isEmpty else {
            errorMessage = "模型目录不可用"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func checkCaptureOne() async {
        let result = await captureOne.checkHealth()
        switch result {
        case .success(let name): captureOneStatus = "已连接：\(name)"
        case .failure(let error): captureOneStatus = error.description
        }
    }

    public func reset() {
        do {
            values = try client.execute("settings.reset").decoded(as: [String: String].self)
            language = values["ui_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-CN"
            backend = values["onnx_provider"] ?? "auto"
            editedValue = values[selectedKey] ?? ""
            notice = "设置已恢复默认值"
            modelStatus = try? client.execute("settings.get_ml_status").decoded(as: MLStatusData.self)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }
}

public struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var confirmReset = false

    public init(router: CommandRouter) {
        _viewModel = State(initialValue: SettingsViewModel(router: router))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modelCard
                    settingsCard
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { viewModel.load() }
        .task { await viewModel.checkCaptureOne() }
        .confirmationDialog("恢复所有设置默认值？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { viewModel.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("模型路径、后端、缓存和写回参数都会恢复默认值。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置").font(.system(size: 24, weight: .bold))
                Text("原生宿主配置、推理后端和模型状态").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
            Button("检查 Capture One", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.checkCaptureOne() }
            }
            Button("恢复默认", systemImage: "arrow.counterclockwise") { confirmReset = true }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型与推理").font(.title3.weight(.semibold))
            if let model = viewModel.modelStatus {
                LabeledContent("平台", value: model.platform)
                LabeledContent("后端", value: model.autoBackendLabel)
                LabeledContent("Provider", value: model.provider)
                LabeledContent("Embedding", value: "\(model.modelInfo.embeddingDim) 维")
                LabeledContent("检测模型", value: model.detectorModel.exists ? "可用" : "未找到")
                LabeledContent("编码模型", value: model.encoderModel.exists ? "可用" : "未找到")
                Picker("语言", selection: Binding(
                    get: { viewModel.language },
                    set: { viewModel.setLanguage($0) }
                )) {
                    Text("简体中文").tag("zh-CN")
                    Text("English").tag("en")
                }
                Picker("推理后端", selection: Binding(
                    get: { viewModel.backend },
                    set: { viewModel.setBackend($0) }
                )) {
                    Text("自动").tag("auto")
                    ForEach(model.availableBackends, id: \.value) { backend in
                        Text(backend.label).tag(backend.value)
                    }
                }
                HStack {
                    Text("模型目录").foregroundStyle(.secondary)
                    Text(model.modelResourcesDir).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button("打开") { viewModel.openModelDirectory() }
                }
                Text("Capture One：\(viewModel.captureOneStatus)")
                    .font(.caption)
                    .foregroundStyle(viewModel.captureOneStatus.hasPrefix("已连接") ? .green : .secondary)
            } else {
                Text("正在读取模型状态…").foregroundStyle(.secondary)
            }
        }
        .nativeCard()
    }

    private var settingsCard: some View {
        HStack(alignment: .top, spacing: 20) {
            List(viewModel.values.keys.sorted(), id: \.self, selection: Binding(
                get: { viewModel.selectedKey },
                set: { if let value = $0 { viewModel.select(value) } }
            )) { key in
                Text(key).font(.caption.monospaced())
            }
            .frame(minWidth: 300, minHeight: 360)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.selectedKey).font(.headline)
                TextField("值", text: $viewModel.editedValue)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存", action: viewModel.save)
                    Spacer()
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .nativeCard()
    }
}

extension View {
    func nativeCard() -> some View {
        padding(18)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

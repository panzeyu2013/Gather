// Phase 3.5：人脸分析、簇绑定、成员修订和安全写回流程。
// TS 源：desktop/src/renderer/pages/FaceKeywording/* + face-kw.ipc.ts。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class FaceKeywordingViewModel {
    private let client: NativeCommandClient
    private let captureOne: CaptureOneBridge
    public let sessionId: String
    private(set) public var clusters: [FaceClusterData] = []
    private(set) public var analysisResult: FaceAnalysisResult?
    private(set) public var preview: FaceKwWritebackPreview?
    private(set) public var writebackResult: FaceKwWritebackResult?
    private(set) public var isLoading = false
    private(set) public var isAnalyzing = false
    private(set) public var isWritingBack = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    public var roleName = ""
    public var keywords = ""
    public var eps = 0.6
    public var minSamples = 2
    public var mergeTarget = ""
    public private(set) var selectedClusterId: Int?

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
    }

    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            clusters = try client.execute("fkw.clusters", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [FaceClusterData].self)
            if let selectedClusterId,
               let cluster = clusters.first(where: { $0.id == selectedClusterId }) {
                select(cluster)
            }
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func select(_ cluster: FaceClusterData) {
        selectedClusterId = cluster.id
        roleName = cluster.binding?.roleName ?? ""
        keywords = cluster.binding?.keywords.joined(separator: ", ") ?? ""
    }

    public func analyze() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let data = try await client.executeAsync("fkw.analyze", params: [
                "sessionId": .string(sessionId),
                "eps": .number(eps),
                "minSamples": .number(Double(minSamples)),
            ])
            analysisResult = try data.decoded(as: FaceAnalysisResult.self)
            notice = "人脸分析完成"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func cancel() {
        do {
            _ = try client.execute("fkw.cancel_analysis", params: ["sessionId": .string(sessionId)])
            notice = "已请求取消人脸分析"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func recluster() async {
        do {
            _ = try await client.executeAsync("fkw.recluster", params: [
                "sessionId": .string(sessionId),
                "eps": .number(eps),
                "minSamples": .number(Double(minSamples)),
            ])
            notice = "已重新聚类"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func bind(_ cluster: FaceClusterData) {
        let role = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = parseKeywords()
        guard !role.isEmpty else {
            errorMessage = "FKW_ROLE_NAME_EMPTY"
            return
        }
        do {
            _ = try client.execute("fkw.bind", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "roleName": .string(role),
                "keywords": .array(words.map(JSONValue.string)),
            ])
            notice = "已绑定簇 #\(cluster.id)"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func unbind(_ cluster: FaceClusterData) async {
        do {
            _ = try await client.executeAsync("fkw.unbind", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "confirmed": .bool(true),
            ])
            notice = "已解除簇 #\(cluster.id) 的绑定"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func removeMember(_ member: ClusterMember, from cluster: FaceClusterData) {
        do {
            _ = try client.execute("fkw.remove_member", params: [
                "sessionId": .string(sessionId),
                "clusterId": .number(Double(cluster.id)),
                "memberId": .number(Double(member.memberId)),
            ])
            notice = "已从簇 #\(cluster.id) 移除成员"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func merge(_ cluster: FaceClusterData) {
        guard let target = Int(mergeTarget), target > 0, target != cluster.id else {
            errorMessage = "请输入有效的目标簇编号"
            return
        }
        do {
            _ = try client.execute("fkw.merge", params: [
                "sessionId": .string(sessionId),
                "source": .number(Double(cluster.id)),
                "target": .number(Double(target)),
            ])
            notice = "已将簇 #\(cluster.id) 合并到簇 #\(target)"
            mergeTarget = ""
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func previewWriteback() async {
        do {
            let options = FaceKwWritebackOptions(
                createAlbums: false,
                addPrefix: false,
                markUngrouped: false,
                writeIPTC: false
            )
            let data = try await client.executeAsync("fkw.preview", params: [
                "sessionId": .string(sessionId),
                "options": try JSONValue(from: options),
            ])
            preview = try data.decoded(as: FaceKwWritebackPreview.self)
            writebackResult = nil
            notice = "写回预览已生成"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func writeback() async {
        guard let preview, !preview.items.isEmpty else {
            errorMessage = "请先生成写回预览"
            return
        }
        isWritingBack = true
        defer { isWritingBack = false }
        do {
            let data = try await client.executeAsync("fkw.writeback", params: [
                "sessionId": .string(sessionId),
                "items": .array(try preview.items.map { try JSONValue(from: $0) }),
                "confirmed": .bool(true),
            ])
            writebackResult = try data.decoded(as: FaceKwWritebackResult.self)
            notice = "已写回 \(writebackResult?.written ?? 0) 项；请先让 Capture One 重新加载元数据"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func retryFailed() async {
        guard let items = writebackResult?.failedItems, !items.isEmpty else {
            errorMessage = "没有可重试的失败项"
            return
        }
        do {
            let data = try await client.executeAsync("fkw.writeback", params: [
                "sessionId": .string(sessionId),
                "items": .array(try items.map { try JSONValue(from: $0) }),
                "confirmed": .bool(true),
            ])
            writebackResult = try data.decoded(as: FaceKwWritebackResult.self)
            notice = "已重试失败写回项"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            notice = "Capture One 已重新加载元数据，现在可以确认同步"
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func confirmSync() async {
        do {
            _ = try await client.executeAsync("fkw.confirm_sync", params: ["sessionId": .string(sessionId)])
            notice = "已确认人脸关键字同步"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func cleanup() async {
        do {
            _ = try await client.executeAsync("fkw.cleanup", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            notice = "已清理人脸写回备份"
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    private func parseKeywords() -> [String] {
        keywords.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

public struct FaceKeywordingView: View {
    @State private var viewModel: FaceKeywordingViewModel
    private let onBack: () -> Void
    @State private var unbindTarget: FaceClusterData?
    @State private var removeTarget: (cluster: FaceClusterData, member: ClusterMember)?
    @State private var confirmUnbind = false
    @State private var confirmRemove = false
    @State private var confirmWriteback = false
    @State private var confirmCleanup = false

    public init(sessionId: String, router: CommandRouter, onBack: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: FaceKeywordingViewModel(sessionId: sessionId, router: router))
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    analysisControls
                    bindingControls
                    writebackCard
                    if let result = viewModel.analysisResult {
                        Text("状态：\(result.status)，检测失败 \(result.detectionFailures)，编码失败 \(result.encodingFailures)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if viewModel.clusters.isEmpty {
                        ContentUnavailableView("暂无人脸簇", systemImage: "person.crop.circle.badge.questionmark", description: Text("先运行人脸分析"))
                    } else {
                        ForEach(viewModel.clusters, id: \.id) { cluster in
                            clusterCard(cluster)
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { viewModel.load() }
        .confirmationDialog("确认解除绑定？", isPresented: $confirmUnbind, titleVisibility: .visible) {
            Button("解除绑定", role: .destructive) {
                if let cluster = unbindTarget { Task { await viewModel.unbind(cluster) } }
                unbindTarget = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除 Gather 为该簇维护的角色关键字，照片文件不会删除。")
        }
        .confirmationDialog("确认移除人脸成员？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let target = removeTarget { viewModel.removeMember(target.member, from: target.cluster) }
                removeTarget = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只从当前人脸簇移除成员，不删除照片。")
        }
        .confirmationDialog("确认写回人脸关键字？", isPresented: $confirmWriteback, titleVisibility: .visible) {
            Button("确认写回") { Task { await viewModel.writeback() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("写回前请检查预览；写入后必须重新加载 Capture One，再确认同步。")
        }
        .confirmationDialog("确认清理人脸写回备份？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await viewModel.cleanup() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只应在 Capture One 已重载并确认同步后执行。")
        }
    }

    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text("人脸与关键字").font(.system(size: 24, weight: .bold))
                Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var analysisControls: some View {
        HStack(spacing: 12) {
            Stepper("eps \(viewModel.eps, specifier: "%.2f")", value: $viewModel.eps, in: 0.1...2, step: 0.05)
                .frame(width: 170)
            Stepper("最小簇 \(viewModel.minSamples)", value: $viewModel.minSamples, in: 2...20)
                .frame(width: 150)
            Button(viewModel.isAnalyzing ? "分析中…" : "运行人脸分析", systemImage: "play.fill") {
                Task { await viewModel.analyze() }
            }
            .disabled(viewModel.isAnalyzing)
            Button("取消", systemImage: "stop.fill", action: viewModel.cancel)
            Button("重新聚类", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.recluster() }
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var bindingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("簇绑定").font(.headline)
            HStack {
                TextField("角色名称（先选择一个簇）", text: $viewModel.roleName)
                    .textFieldStyle(.roundedBorder)
                TextField("关键字，用逗号分隔", text: $viewModel.keywords)
                    .textFieldStyle(.roundedBorder)
                TextField("合并到簇编号", text: $viewModel.mergeTarget)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            Text("点击簇卡片后编辑角色和关键字；绑定、合并、移除成员都会立即刷新簇状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var writebackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关键字写回").font(.headline)
                Spacer()
                Button("生成预览", systemImage: "eye") { Task { await viewModel.previewWriteback() } }
                Button("确认写回", systemImage: "square.and.arrow.down") { confirmWriteback = true }
                    .disabled(viewModel.preview?.items.isEmpty != false || viewModel.isWritingBack)
            }
            if let preview = viewModel.preview {
                Text("将影响 \(preview.affectedPhotos) 张照片，共 \(preview.totalCount) 个写回项")
                    .font(.callout)
                ForEach(preview.items.prefix(8), id: \.photoId) { item in
                    Text("\(URL(fileURLWithPath: item.photoPath).lastPathComponent)：\(item.keywords.joined(separator: ", "))")
                        .font(.caption).lineLimit(1)
                }
                if preview.items.count > 8 {
                    Text("还有 \(preview.items.count - 8) 项…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("先生成预览，确认影响范围后再写回。").font(.caption).foregroundStyle(.secondary)
            }
            if let result = viewModel.writebackResult {
                Text("结果：总计 \(result.totalAffected) · 成功 \(result.written) · 失败 \(result.failed) · 跳过 \(result.skipped)")
                HStack {
                    Button("重试失败项") { Task { await viewModel.retryFailed() } }
                        .disabled(result.failedItems.isEmpty)
                    Button("Capture One 重新加载") { Task { await viewModel.reloadCaptureOne() } }
                    Button("确认已同步") { Task { await viewModel.confirmSync() } }
                    Button("清理备份", role: .destructive) { confirmCleanup = true }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func clusterCard(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    viewModel.select(cluster)
                } label: {
                    Text("簇 #\(cluster.id) · \(cluster.size) 张")
                        .font(.headline)
                        .foregroundStyle(viewModel.selectedClusterId == cluster.id ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                Text(cluster.status).font(.caption).foregroundStyle(.secondary)
                if let binding = cluster.binding {
                    Text("已绑定：\(binding.roleName)").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("绑定") { viewModel.bind(cluster) }
                if cluster.binding != nil {
                    Button("解除") { unbindTarget = cluster; confirmUnbind = true }
                }
                Button("合并") { viewModel.merge(cluster) }
            }
            if !cluster.members.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(cluster.members, id: \.memberId) { member in
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack(alignment: .topTrailing) {
                                    PhotoThumbnailView(path: member.photoPath, size: 160, placeholderSize: CGSize(width: 120, height: 90))
                                    Button {
                                        removeTarget = (cluster, member)
                                        confirmRemove = true
                                    } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(.white, .red)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                }
                                Text(member.filename).font(.caption).lineLimit(1).frame(width: 120, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .nativeCard()
    }
}

// Phase 3.6：重复检测与处置 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Duplicates.tsx。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class DuplicatesViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var groups: [DuplicateGroup] = []
    private(set) public var scanResult: DuplicateScanResult?
    private(set) public var isScanning = false
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    public var threshold = 4
    public var showExact = true

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public func load() {
        do {
            groups = try client.execute("dup.groups", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [DuplicateGroup].self)
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            scanResult = try await client.executeAsync("dup.scan", params: [
                "sessionId": .string(sessionId),
                "visualThreshold": .number(Double(threshold)),
            ]).decoded(as: DuplicateScanResult.self)
            notice = "重复扫描完成"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func resolveGroup(_ group: DuplicateGroup, resolution: DupResolution) {
        do {
            _ = try client.execute("dup.resolve", params: [
                "groupId": .number(Double(group.id)),
                "resolution": .string(resolution.rawValue),
                "confirmed": .bool(true),
            ])
            notice = "已处理重复组 #\(group.id)"
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func toggle(_ member: DuplicateGroupMember) {
        do {
            _ = try client.execute("dup.resolve_member", params: [
                "memberId": .number(Double(member.id)),
                "isKept": .bool(!member.isKept),
                "confirmed": .bool(true),
            ])
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public var visibleGroups: [DuplicateGroup] {
        groups.filter { showExact ? $0.groupType == .exact : $0.groupType == .visual }
    }
}

public struct DuplicatesView: View {
    @State private var viewModel: DuplicatesViewModel
    private let onBack: () -> Void

    public init(sessionId: String, router: CommandRouter, onBack: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: DuplicatesViewModel(sessionId: sessionId, router: router))
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scanControls
                    if let result = viewModel.scanResult {
                        Text("精确组 \(result.exactGroups.count) · 视觉组 \(result.visualGroups.count) · 重复照片 \(result.totalDuplicates)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if viewModel.visibleGroups.isEmpty {
                        ContentUnavailableView("暂无重复组", systemImage: "square.on.square", description: Text("运行扫描或切换分组类型"))
                    } else {
                        ForEach(viewModel.visibleGroups, id: \.id) { group in groupCard(group) }
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { viewModel.load() }
    }

    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text("重复照片").font(.system(size: 24, weight: .bold))
                Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Picker("类型", selection: $viewModel.showExact) {
                Text("精确重复").tag(true)
                Text("视觉重复").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Stepper("阈值 \(viewModel.threshold)", value: $viewModel.threshold, in: 1...16)
                .frame(width: 130)
            Button(viewModel.isScanning ? "扫描中…" : "扫描重复", systemImage: "magnifyingglass") {
                Task { await viewModel.scan() }
            }
            .disabled(viewModel.isScanning)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.groupType.rawValue) 组 #\(group.id) · \(group.memberCount) 个成员")
                    .font(.headline)
                if let resolution = group.resolution { Text(resolution).font(.caption).foregroundStyle(.green) }
                Spacer()
                Menu("处理") {
                    Button("保留最佳") { viewModel.resolveGroup(group, resolution: .keepOne) }
                    Button("全部保留") { viewModel.resolveGroup(group, resolution: .keepAll) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(group.members, id: \.id) { member in
                    VStack(alignment: .leading, spacing: 5) {
                        PhotoThumbnailView(path: member.filepath, size: 220, placeholderSize: CGSize(width: 150, height: 110))
                        Text(member.filename).font(.caption).lineLimit(1)
                        Button(member.isKept ? "已保留" : "已排除") { viewModel.toggle(member) }
                            .buttonStyle(.bordered)
                            .tint(member.isKept ? .green : .orange)
                    }
                }
            }
        }
        .nativeCard()
    }
}

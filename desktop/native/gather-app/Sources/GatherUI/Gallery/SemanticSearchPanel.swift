// desktop/native/gather-app/Sources/GatherUI/Gallery/SemanticSearchPanel.swift
// P1 下一波 §3.11.3：语义"相似照片"入口的轻量结果面板。
//
// 只做一件事：以当前照片的 FeaturePrint 向量做相似检索，列出命中并允许跳回网格。
// 索引未建立/不可用时显示 unavailableReason（不假装空结果）。

import SwiftUI
import GatherProtocol

struct SemanticSearchPanel: View {
    let seedPhotoId: String
    let sessionId: String
    let api: any PhotoAPI
    let nameFor: (String) -> String
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    @State private var outcome: SemanticSearchOutcomeSnapshot?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            HStack {
                Text(l10n("相似照片"))
                    .font(GatherFont.cardTitle)
                Spacer()
                Button(l10n("完成")) { dismiss() }
                    .buttonStyle(.bordered)
            }
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let errorText {
                Text(errorText)
                    .foregroundStyle(GatherTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let outcome {
                if outcome.hits.isEmpty {
                    Text(outcome.unavailableReason ?? l10n("没有足够相似的已分析照片"))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                            ForEach(outcome.hits, id: \.photoId) { hit in
                                Button {
                                    onSelect(hit.photoId)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: GatherMetrics.Space.xxs) {
                                            Text(nameFor(hit.photoId))
                                                .lineLimit(1)
                                            if !hit.matchedLabels.isEmpty {
                                                Text(hit.matchedLabels.joined(separator: " · "))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if let similarity = hit.similarity {
                                            Text(String(format: "%.0f%%", similarity * 100))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, GatherMetrics.Space.xs)
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 360)
                }
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(width: 420)
        .task {
            do {
                outcome = try await api.semanticSearch(
                    SemanticSearchQuery(sessionId: sessionId, photoId: seedPhotoId))
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

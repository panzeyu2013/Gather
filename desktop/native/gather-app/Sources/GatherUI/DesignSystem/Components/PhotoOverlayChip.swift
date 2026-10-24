// 照片上的信息角标：深色胶囊 + 白字，保证在任何照片底图上可读。
// 统一离线 / RAW+JPEG / 评分 / 状态等照片角标，避免每页各画一套。
import SwiftUI

struct PhotoOverlayChip: View {
    let text: String
    var systemImage: String? = nil
    var iconColor: Color = .white

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(GatherFont.label)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.68)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

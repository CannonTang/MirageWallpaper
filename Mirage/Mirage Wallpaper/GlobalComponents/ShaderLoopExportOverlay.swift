//
//  Mirage Wallpaper
//

import SwiftUI

struct ShaderLoopExportOverlay: View {
    @ObservedObject private var model = ShaderLoopExportProgressModel.shared
    @ObservedObject private var localization = MirageLocalization.shared

    var body: some View {
        if let job = model.job {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成锁屏循环视频")
                        .font(.headline)
                }
                Text(job.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text(job.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
            .padding(24)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(.easeInOut(duration: 0.22), value: model.job)
            .environment(\.locale, localization.locale)
        }
    }
}

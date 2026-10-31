// DataWheel — 右下角任务通知卡片
import SwiftUI

struct ToastsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 9) {
            if state.jobs.count > 1 {
                Button {
                    state.closeAllJobs()
                } label: {
                    Text("全部关闭 (\(state.jobs.count))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: 0x8A8F9E))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xE6E9EE), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            ForEach(state.jobs) { job in
                JobCard(job: job) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        state.jobs.removeAll { $0.id == job.id }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(18)
        .allowsHitTesting(true)
    }
}

struct JobCard: View {
    let job: JobItem
    let onClose: () -> Void
    @State private var shown = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(job.file)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(detailColor)
                    .lineLimit(3)
                if let warn = job.warning {
                    Text("⚠ " + warn)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: 0xB45309))
                }
                if job.status == .done, let out = job.output {
                    HStack(spacing: 7) {
                        Button("打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: out))
                        }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)])
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: 0x3B82F6))
                }
            }
            Spacer(minLength: 4)
            FormatBadge(target: job.target)
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: 0x9AA3B0))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.14), radius: 12, y: 4)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: 0xE6E9EE), lineWidth: 1))
        )
        .offset(y: shown ? 0 : 14)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shown = true } }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .working:
            ProgressView()
                .controlSize(.small)
                .frame(width: 17, height: 17)
        case .done:
            Circle().fill(Color(hex: 0x16A34A))
                .frame(width: 17, height: 17)
                .overlay(Text("✓").font(.system(size: 10, weight: .bold)).foregroundColor(.white))
        case .failed:
            Circle().fill(Color(hex: 0xDC2626))
                .frame(width: 17, height: 17)
                .overlay(Text("✕").font(.system(size: 10, weight: .bold)).foregroundColor(.white))
        }
    }

    private var detailColor: Color {
        switch job.status {
        case .working: return Color(hex: 0x5A6472)
        case .done: return Color(hex: 0x9AA3B0)
        case .failed: return Color(hex: 0xDC2626)
        }
    }
}

// DataWheel — Python 环境状态横幅：缺失检测 + 一键安装
import SwiftUI

struct EnvBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.envState {
        case .checking:
            EmptyView()
        case .ok:
            EmptyView()
        case .missing(let pkgs):
            banner(icon: "exclamationmark.triangle.fill",
                   iconColor: Color(hex: 0xF59E0B),
                   text: "Python 组件缺失：\(pkgs.joined(separator: "、"))",
                   detail: "转换前将自动安装，或立即安装",
                   buttonTitle: "一键安装") { state.installEnv() }
        case .installing(let line):
            banner(icon: nil,
                   iconColor: brandColor,
                   text: line,
                   detail: "正在通过 pip 安装，首次安装需要 1～3 分钟…",
                   buttonTitle: nil, action: nil)
        case .installFailed(let msg):
            banner(icon: "xmark.octagon.fill",
                   iconColor: Color(hex: 0xDC2626),
                   text: "安装失败",
                   detail: msg,
                   buttonTitle: "重试") { state.installEnv() }
        }
    }

    @ViewBuilder
    private func banner(icon: String?, iconColor: Color, text: String,
                        detail: String, buttonTitle: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x2A3040))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: 0x8A8F9E))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(brandColor)
            }
            Button {
                state.envState = .ok   // 暂不处理，收起横幅
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: 0x9AA3B0))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 3)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: 0xE6E9EE), lineWidth: 1))
        )
        .frame(maxWidth: 520)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

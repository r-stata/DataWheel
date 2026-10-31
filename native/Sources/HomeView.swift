// DataWheel — 主界面：侧边栏 + 拖放卡片 + 最近转换（参考 Filee 布局）
import SwiftUI
import UniformTypeIdentifiers

/// 主题强调色（Filee 式紫罗兰）
let brandColor = Color(hex: 0x6C5CE7)
let brandSoft = Color(hex: 0xF4F2FD)
let brandBorder = Color(hex: 0xDEDAF5)

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 210)
            Rectangle()
                .fill(Color(hex: 0xECECF2))
                .frame(width: 1)
            MainView()
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(Color(hex: 0xF6F6FA))
        .background(DropTargetNSView())   // AppKit 原生拖放目标：拖入弹出浮动转盘
        .overlay(alignment: .top) {
            EnvBanner().padding(.top, 8)   // Python 环境缺失提示 + 一键安装
        }
        .overlay(ToastsView().zIndex(20)) // 右下角任务通知卡片
        .sheet(isPresented: $state.showSettings) { SettingsView().environmentObject(state) }
        .background(MainWindowTagger())   // 给 NSWindow 打标识，供菜单栏入口复用窗口
    }
}

// MARK: - 主窗口标识

/// 把宿主 NSWindow 标记为 "dw-main"：菜单栏「打开 DataWheel」据此复用已有窗口，
/// 避免 openWindow 在应用未激活时重复创建窗口（弹双窗口 bug）
struct MainWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.identifier = NSUserInterfaceItemIdentifier("dw-main")
            v.window?.isReleasedWhenClosed = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 返回已存在的主窗口（如果有）
@MainActor
func findMainWindow() -> NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue == "dw-main" }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                MenuWheelGlyph()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DataWheel")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: 0x1F2430))
                    Text("Drag, drop, converted.")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: 0x9AA3B0))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            SidebarItem(icon: "house.fill", title: "首页", active: true) {}
            SidebarItem(icon: "gearshape.fill", title: "设置", active: false) {
                state.showSettings = true
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text("Version 2.0 · 本地转换\n数据不上传\n开发：")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: 0xA6AEBC))
                // 微信公众号 RStata 可点击跳转主页
                Link("微信公众号 RStata", destination: URL(string: "https://tidyfriday.cn/")!)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: 0x7C6FD0))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color(hex: 0xFBFBFD))
    }
}

struct SidebarItem: View {
    let icon: String
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(active ? brandColor : Color(hex: 0x5A6472))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                    .foregroundColor(Color(hex: 0x2A3040))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Color(hex: 0xEEEBFB) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

// MARK: - 主区域

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("首页")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Color(hex: 0x1F2430))
                .padding(.top, 24)

            dropzone

            recentsHeader
            recents
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    // Filee 式拖放卡片
    private var dropzone: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(brandColor)
                    .frame(width: 54, height: 54)
                Image(systemName: "arrow.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 2)

            Text("拖放文件到这里")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color(hex: 0x1F2430))

            Text("把数据文件拖入窗口任意位置，转盘会在光标处弹出 — 松开到目标格式即完成转换")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: 0x8A8F9E))
                .multilineTextAlignment(.center)

            Text("支持 xlsx / xls · csv / tsv · dta · rds · parquet · feather · json / jsonl")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: 0xA6AEBC))

            Button("或点按选择文件") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = dataTypes
                if panel.runModal() == .OK, !panel.urls.isEmpty {
                    DonutPanel.shared.showClick(paths: panel.urls.map { $0.path })
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(brandColor)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(brandSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(brandBorder, lineWidth: 1.5)
                )
        )
    }

    let dataTypes: [UTType] = [
        .commaSeparatedText, .json, .data, .spreadsheet,
    ] + ["tsv", "dta", "rds", "rdata", "parquet", "pq", "feather", "arrow", "jsonl", "ndjson", "xls", "xlsx"]
        .compactMap { UTType(filenameExtension: $0) }

    private var recentsHeader: some View {
        HStack {
            Text("最近转换")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Color(hex: 0x1F2430))
            Spacer()
            if !state.recents.isEmpty {
                Button("清空") { state.clearRecents() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12.5))
                    .foregroundColor(brandColor)
            }
        }
    }

    private var recents: some View {
        Group {
            if state.recents.isEmpty {
                Text("转换过的文件会显示在这里")
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: 0xA6AEBC))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.recents.prefix(12)) { r in
                            RecentRow(item: r)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RecentRow: View {
    let item: RecentItem

    var body: some View {
        HStack(spacing: 10) {
            // 文件类型缩略圆标
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill((DataFormat.by(id: item.target)?.color ?? brandColor).opacity(0.14))
                    .frame(width: 30, height: 30)
                Text(item.target.uppercased().prefix(4))
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundColor(DataFormat.by(id: item.target)?.color ?? brandColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName(item.input))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(hex: 0x2A3040))
                Text(fileName(item.output))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0x8A8F9E))
            }
            Spacer(minLength: 8)
            Text("\(item.rows) 行 × \(item.cols) 列")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: 0xA6AEBC))
            Text(item.time, style: .time)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: 0xA6AEBC))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.output)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(brandColor)
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color(hex: 0xECECF2), lineWidth: 1))
        )
    }

    private func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }
}

struct FormatBadge: View {
    let target: String

    var body: some View {
        Text(target.uppercased())
            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(DataFormat.by(id: target)?.color ?? brandColor))
    }
}

/// 侧边栏小转盘图标（紫色系）
struct MenuWheelGlyph: View {
    var body: some View {
        ZStack {
            ForEach(Array(DataFormat.all.prefix(6).enumerated()), id: \.offset) { idx, _ in
                let a0 = Angle.degrees(-90 + Double(idx) * 60)
                Circle()
                    .trim(from: 0, to: 0.11)
                    .stroke(idx % 2 == 0 ? brandColor : brandColor.opacity(0.55),
                            style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(a0)
            }
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
        }
        .modifier(SlowSpin())
    }
}

struct SlowSpin: ViewModifier {
    @State private var spinning = false
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

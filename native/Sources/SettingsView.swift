// DataWheel — 设置面板
import SwiftUI
import ServiceManagement
import ApplicationServices

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var pythonPath: String = Settings.load().pythonPath ?? ""
    @State private var outputMode: String = Settings.load().outputMode
    @State private var customOutDir: String = Settings.load().customOutDir ?? ""
    @State private var hotkeyFlags: Set<String> = {
        let s = Settings.load()
        if let f = s.hotkeyFlags, !f.isEmpty { return Set(f) }
        return [s.hotkeyModifier]   // 兼容旧单选设置
    }()
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var dtaLabel: String = Settings.load().dtaLabel ?? ""
    @State private var axTrusted = HotkeyMonitor.isTrusted
    @State private var tapAuthorized = HotkeyMonitor.shared.authorized
    @State private var permTick = 0   // 定时刷新权限状态（从系统设置授权返回后自动更新）

    private let permTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.system(size: 16, weight: .bold))

            // 权限检测：快捷键拖拽所需的系统权限一站式检查
            permCard

            Divider()

            // 快捷键拖拽
            VStack(alignment: .leading, spacing: 6) {
                Text("快捷键拖拽转盘")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                // 修饰键组合：可多选，同时按住才触发
                HStack(spacing: 8) {
                    ForEach([("command", "⌘ Command"),
                             ("control", "⌃ Control"),
                             ("option", "⌥ Option"),
                             ("shift", "⇧ Shift"),
                             ("capslock", "⇪ Caps")], id: \.0) { key, label in
                        let on = hotkeyFlags.contains(key)
                        Button {
                            if on {
                                guard hotkeyFlags.count > 1 else { return }   // 至少保留一个修饰键
                                hotkeyFlags.remove(key)
                            } else {
                                hotkeyFlags.insert(key)
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(on ? brandColor.opacity(0.15) : Color(hex: 0xF0F0F4)))
                                .overlay(Capsule().strokeBorder(on ? brandColor : Color(hex: 0xD8DCE4), lineWidth: 1))
                                .foregroundColor(on ? brandColor : Color(hex: 0x5A6472))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("点选一个或多个修饰键组成组合键，按住组合键拖动文件即可弹出转盘。⇪ Caps 为开关状态：开启大写锁定后拖动即可。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0xA6AEBC))
                // 以 tap 是否真正创建成功为准（AXIsProcessTrusted 在部分环境下误报 false）
                if !tapAuthorized {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: 0xF59E0B))
                        Text("需要「辅助功能」权限才能监听全局拖拽")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: 0x5A6472))
                        Button("打开系统设置") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(brandColor)
                        Button("已授权，重新检测") {
                            HotkeyMonitor.shared.restart()
                            axTrusted = HotkeyMonitor.isTrusted
                            tapAuthorized = HotkeyMonitor.shared.authorized
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(brandColor)
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: 0x16A34A))
                        Text("快捷键拖拽已启用")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: 0x5A6472))
                    }
                }
            }

            Divider()

            // 后台常驻
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $launchAtLogin) {
                    Text("登录时自动启动（后台常驻）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(hex: 0x5A6472))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }
                Text("开启后 DataWheel 随登录在后台运行（菜单栏常驻），任何时候按住快捷键拖文件即可呼出转盘，无需打开主窗口。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0xA6AEBC))
            }

            Divider()

            // Python 环境检测卡片
            envCard

            VStack(alignment: .leading, spacing: 6) {
                Text("Python 解释器")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                TextField("留空自动探测（需已安装 pandas / pyreadstat / pyarrow / pyreadr）", text: $pythonPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("留空时自动探测：应用内置 venv → 项目 venv → Homebrew。转换前会自动检测缺失组件并提示安装。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0xA6AEBC))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("输出位置")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                Picker("", selection: $outputMode) {
                    Text("源文件所在目录").tag("source")
                    Text("每次询问").tag("ask")
                    Text("固定目录").tag("custom")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if outputMode == "custom" {
                    HStack {
                        TextField("目录路径", text: $customOutDir)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("浏览…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                customOutDir = url.path
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("dta 数据标签")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                TextField("数据处理：微信公众号 RStata", text: $dtaLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("转换为 Stata .dta 文件时写入的数据集标签（file label），留空使用默认值。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0xA6AEBC))
            }

            Divider()

            // 关于
            VStack(alignment: .leading, spacing: 4) {
                Text("DataWheel 数据转盘 v2.0")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x2A3040))
                Text("参考 KnifeLemon/Filee 转盘交互 · 本地转换，数据不上传")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: 0x8A8F9E))
                HStack(spacing: 0) {
                    Text("开发：")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(brandColor)
                    // 点击跳转主页
                    Link("微信公众号 RStata", destination: URL(string: "https://tidyfriday.cn/")!)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(brandColor)
                }
            }

            HStack {
                Spacer()
                Button("取消") { state.showSettings = false }
                Button("保存") {
                    let s = Settings()
                    s.pythonPath = pythonPath.trimmingCharacters(in: .whitespaces)
                    s.outputMode = outputMode
                    s.customOutDir = customOutDir.trimmingCharacters(in: .whitespaces)
                    s.hotkeyFlags = hotkeyFlags.sorted()
                    s.launchAtLogin = launchAtLogin
                    let lbl = dtaLabel.trimmingCharacters(in: .whitespaces)
                    s.dtaLabel = lbl.isEmpty ? nil : lbl
                    s.save()
                    HotkeyMonitor.shared.restart()   // 快捷键变更立即生效
                    state.checkEnv()                 // 解释器可能已变更，重新检测组件
                    state.showSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(permTimer) { _ in permTick += 1 }   // 每 2 秒刷新权限状态
    }

    // MARK: 权限检测卡片（快捷键拖拽所需系统权限一站式检查）

    @ViewBuilder
    private var permCard: some View {
        let listen = HotkeyMonitor.listenEventAccess
        let ax = HotkeyMonitor.isTrusted
        let alive = HotkeyMonitor.shared.isEventFlowAlive()
        let variant = HotkeyMonitor.shared.tapVariant
        let _ = permTick   // 触发重渲染（定时刷新权限状态）
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("权限检测")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                Spacer()
                Button("重新检测") {
                    HotkeyMonitor.shared.restart()
                    permTick += 1
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(brandColor)
            }

            // 事件流自检：端到端真值（tap 真正收到系统事件才算通过）
            HStack(spacing: 8) {
                Image(systemName: alive ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 13))
                    .foregroundColor(alive ? Color(hex: 0x16A34A) : Color(hex: 0x8A8F9E))
                VStack(alignment: .leading, spacing: 1) {
                    Text("监听自检")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: 0x2A3040))
                    Text(alive ? "事件流正常，转盘可正常呼出" : "移动鼠标自动验证（几秒后更新）")
                        .font(.system(size: 10.5))
                        .foregroundColor(alive ? Color(hex: 0x16A34A) : Color(hex: 0x8A8F9E))
                }
                Spacer(minLength: 0)
            }

            permRow(title: "输入监控",
                    desc: "HID 最佳监听模式必需；后台/隐藏监听全靠它",
                    ok: listen,
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                    requestListen: true)

            permRow(title: "辅助功能",
                    desc: "Session 回退监听模式需要",
                    ok: ax,
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    requestListen: false)

            // 当前监听模式
            HStack(spacing: 6) {
                Image(systemName: variant == "HID+default" ? "checkmark.seal.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(variant == "HID+default" ? Color(hex: 0x16A34A) : Color(hex: 0xF59E0B))
                Text("当前监听模式：\(variant ?? "未运行")")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(hex: 0x5A6472))
                if variant == "HID+default" {
                    Text("（最佳）").font(.system(size: 11)).foregroundColor(Color(hex: 0x16A34A))
                } else if variant != nil {
                    Text("（降级：授予输入监控后自动升级）")
                        .font(.system(size: 11)).foregroundColor(Color(hex: 0xB45309))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xECECF2), lineWidth: 1))
    }

    private func permRow(title: String, desc: String, ok: Bool,
                         url: String, requestListen: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(ok ? Color(hex: 0x16A34A) : Color(hex: 0xF59E0B))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x2A3040))
                Text(ok ? "已授权" : desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(ok ? Color(hex: 0x16A34A) : Color(hex: 0x8A8F9E))
            }
            Spacer(minLength: 8)
            if !ok {
                if requestListen {
                    Button("申请授权") {
                        CGRequestListenEventAccess()   // 弹出系统授权提示
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("授权提示") {
                        HotkeyMonitor.promptAX()       // 系统自动把应用加进辅助功能列表
                        NSWorkspace.shared.open(URL(string: url)!)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("打开系统设置") {
                    NSWorkspace.shared.open(URL(string: url)!)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(brandColor)
            }
        }
    }

    // MARK: Python 环境检测卡片

    private let packageOrder = ["pandas", "pyarrow", "pyreadstat", "pyreadr", "openpyxl", "xlsxwriter", "xlrd"]

    @ViewBuilder
    private var envCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Python 环境检测")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: 0x5A6472))
                Spacer()
                Button("重新检测") { state.checkEnv() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(brandColor)
                    .disabled(state.envState == .checking || isInstalling)
            }

            switch state.envState {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检测组件…").font(.system(size: 11.5)).foregroundColor(Color(hex: 0x8A8F9E))
                }
            case .ok:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0x16A34A))
                    Text("组件齐全，可以直接转换")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(hex: 0x16A34A))
                }
            case .missing(let pkgs):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xF59E0B))
                    Text("缺失 \(pkgs.count) 个组件：\(pkgs.joined(separator: "、"))")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(hex: 0xB45309))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("一键安装") { state.installEnv() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(brandColor)
                }
            case .installing(let line):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(line).font(.system(size: 11.5)).foregroundColor(Color(hex: 0x5A6472)).lineLimit(2)
                }
            case .installFailed(let msg):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xDC2626))
                    Text(msg).font(.system(size: 11.5)).foregroundColor(Color(hex: 0xDC2626)).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("重试") { state.installEnv() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(brandColor)
                }
            }

            // 解释器路径与版本
            if !state.envPython.isEmpty {
                Text("\(state.envPython) · Python \(state.envVersion)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(hex: 0x8A8F9E))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // 逐组件状态
            let names = packageOrder.filter { state.envPackages[$0] != nil }
                + state.envPackages.keys.filter { !packageOrder.contains($0) }.sorted()
            if !names.isEmpty {
                FlowishWrap(names: names, installed: { state.envPackages[$0] == true })
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xECECF2), lineWidth: 1))
    }

    private var isInstalling: Bool {
        if case .installing = state.envState { return true }
        return false
    }
}

/// 组件状态胶囊流式排布（简化版：每行 4 个）
struct FlowishWrap: View {
    let names: [String]
    let installed: (String) -> Bool

    var body: some View {
        let rows = stride(from: 0, to: names.count, by: 4).map { Array(names[$0..<min($0 + 4, names.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { name in
                        HStack(spacing: 3) {
                            Image(systemName: installed(name) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(installed(name) ? Color(hex: 0x16A34A) : Color(hex: 0xDC2626))
                            Text(name)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(installed(name) ? Color(hex: 0x2A3040) : Color(hex: 0xDC2626))
                        }
                    }
                }
            }
        }
    }
}

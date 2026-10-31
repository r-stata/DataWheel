// DataWheel — App 入口：窗口 + 菜单栏常驻 + 服务菜单
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 服务提供者：右键文件 -> 服务 -> 用 DataWheel 转换
        // （启动时设置 servicesProvider 即自动注册；安装后需 pbs -update 刷新系统服务缓存）
        NSApp.servicesProvider = self

        // 全局快捷键拖拽（按住修饰键拖文件 → 光标处弹出转盘）
        HotkeyMonitor.shared.start()

        // 调试/演示辅助：defaults write com.rstata.datawheel dwOpenSettingsOnLaunch -bool YES 后启动即打开设置页
        // 延迟 1.5s：SwiftUI 的 sheet 绑定在视图挂载前就为 true 时不会自动呈现
        if UserDefaults.standard.bool(forKey: "dwOpenSettingsOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AppState.shared.showSettings = true
            }
        }
    }

    /// Finder / 其他应用通过服务菜单发送文件
    @objc func convertService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // 兼容两种类型：NSFilenamesPboardType（NSSendTypes）与 file URL（NSSendFileTypes）
        var paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
        if paths.isEmpty {
            let urls = pboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            paths = urls.map { $0.path }
        }
        guard !paths.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            DonutPanel.shared.showClick(paths: paths, at: NSEvent.mouseLocation)
        }
    }

    /// Dock 拖放 / 打开方式
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map { $0.path }
        guard !paths.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            DonutPanel.shared.showClick(paths: paths, at: NSEvent.mouseLocation)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 关闭窗口仍保留菜单栏图标
    }

    /// Dock 图标点击 / reopen 事件：已有主窗口（含被关闭但未释放的）就复用，
    /// 不让 SwiftUI 再建一个——防止双窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = findMainWindow() {
            w.makeKeyAndOrderFront(nil)
            return false   // 已处理，不需要系统再创建
        }
        return true        // 无主窗口：交给 SwiftUI 正常创建
    }
}

@main
struct DataWheelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var menubarState = AppState.shared

    var body: some Scene {
        WindowGroup("DataWheel", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // 菜单栏常驻图标（桌面顶部快速启动）
        MenuBarExtra {
            MenuBarMenu(state: menubarState)
        } label: {
            if let img = Self.menubarImage() {
                Image(nsImage: img)
            } else {
                Image(systemName: "circle.circle")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    /// 加载模板态菜单栏图标（Resources/menubar.png）
    static func menubarImage() -> NSImage? {
        let url: URL? = Bundle.main.url(forResource: "menubar", withExtension: "png")
            ?? Bundle.main.url(forResource: "menubar", withExtension: "png", subdirectory: "Resources")
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}

struct MenuBarMenu: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 DataWheel") {
            // 已有主窗口就复用（置前激活），否则才创建——防止弹出两个窗口
            if let w = findMainWindow() {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                DispatchQueue.main.async {   // 异步创建，规避未激活状态下 openWindow 双建窗口
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .keyboardShortcut("o")

        Divider()

        Menu {
            if state.recents.isEmpty {
                Text("暂无记录")
            } else {
                ForEach(state.recents.prefix(5)) { r in
                    Button(fileName(r.output)) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.output)])
                    }
                }
            }
        } label: {
            Text("最近转换")
        }

        Divider()

        Button("清空最近记录") { state.clearRecents() }

        Divider()

        Button("关于 DataWheel") {
            NSApp.orderFrontStandardAboutPanel(options: [:])
        }

        Button("退出 DataWheel") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }

    private func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }
}

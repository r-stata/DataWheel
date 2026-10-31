// DataWheel — 全局状态：任务、最近转换、设置
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class Settings: Codable {
    var pythonPath: String?
    var outputMode: String = "source"   // source | ask | custom
    var customOutDir: String?
    var hotkeyModifier: String = "option"   // option | control（旧字段，向后兼容）
    var hotkeyFlags: [String]?              // 组合键：command/control/option/shift/capslock 任意组合，nil 时回退 hotkeyModifier
    var launchAtLogin: Bool = false         // 登录时自动启动（后台常驻）
    var dtaLabel: String?                   // dta 数据标签（nil 用引擎默认"数据处理：微信公众号 RStata"）

    static func url() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataWheel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    static func load() -> Settings {
        if let d = try? Data(contentsOf: url()), let s = try? JSONDecoder().decode(Settings.self, from: d) {
            return s
        }
        return Settings()
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            try? d.write(to: Self.url(), options: .atomic)
        }
    }
}

struct RecentItem: Codable, Identifiable {
    var id = UUID()
    var time: Date
    var input: String
    var output: String
    var target: String
    var rows: Int
    var cols: Int
    var elapsed: Double
}

final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: 任务与记录
    @Published var jobs: [JobItem] = []
    @Published var recents: [RecentItem] = []
    @Published var showSettings = false

    // MARK: Python 环境检测
    enum EnvState: Equatable {
        case checking
        case ok
        case missing([String])          // 缺失的包名
        case installing(String)         // 进度行
        case installFailed(String)
    }
    @Published var envState: EnvState = .checking
    @Published var envPython: String = ""       // 检测到的解释器路径
    @Published var envVersion: String = ""      // Python 版本
    @Published var envPackages: [String: Bool] = [:]   // 各组件安装状态
    private var pendingConvert: (() -> Void)?

    init() {
        loadRecents()
        checkEnv()
    }

    /// 启动时与安装完成后检测依赖
    func checkEnv() {
        envState = .checking
        Engine.checkEnv { [weak self] res in
            switch res {
            case .success(let report):
                self?.envPython = report.python
                self?.envVersion = report.version
                self?.envPackages = report.packages
                self?.envState = report.missing.isEmpty ? .ok : .missing(report.missing)
            case .failure:
                // 检查失败不阻塞使用（转换时会给出具体错误）
                self?.envState = .ok
            }
            // 安装完成后若有排队的转换，继续执行
            if case .ok = self?.envState, let go = self?.pendingConvert {
                self?.pendingConvert = nil
                go()
            }
        }
    }

    /// 一键安装缺失组件
    func installEnv() {
        guard case .missing(let pkgs) = envState else { return }
        envState = .installing("准备安装 \(pkgs.joined(separator: "、"))…")
        Engine.installEnv(onLine: { [weak self] line in
            guard let self, line.hasPrefix(">>") else { return }   // 只显示引擎进度行
            self.envState = .installing(line)
        }, onDone: { [weak self] res in
            switch res {
            case .success:
                self?.envState = .installing("安装完成，正在验证…")
                self?.checkEnv()
            case .failure(let err):
                self?.envState = .installFailed(err.message)
                self?.pendingConvert = nil
            }
        })
    }

    // MARK: 转换

    func convert(paths: [String], target: String) {
        // 依赖缺失：先自动安装，完成后继续本次转换
        if case .missing = envState {
            pendingConvert = { [weak self] in self?.convert(paths: paths, target: target) }
            installEnv()
            return
        }
        let settings = Settings.load()
        for p in paths {
            var item = JobItem(file: (p as NSString).lastPathComponent, target: target)
            jobs.insert(item, at: 0)
            if jobs.count > 5 { jobs = Array(jobs.prefix(5)) }   // 通知卡片最多保留 5 条
            let jobID = item.id
            let update: (JobItem) -> Void = { [weak self] newItem in
                guard let self else { return }
                if let idx = self.jobs.firstIndex(where: { $0.id == jobID }) {
                    self.jobs[idx] = newItem
                }
            }

            // 输出目录
            var outDir: String?
            switch settings.outputMode {
            case "custom": outDir = settings.customOutDir
            case "ask":
                // 简化：询问一次目录（在主线程）
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.message = "选择输出目录"
                if panel.runModal() == .OK, let url = panel.url { outDir = url.path }
            default: break // source：引擎默认源文件目录
            }

            update(JobItem(id: jobID, file: item.file, target: target, status: .working, detail: "读取中…"))
            DonutPanel.shared.jobStarted()

            Engine.convert(file: p, target: target, outDir: outDir, dtaLabel: settings.dtaLabel, onStage: { stage in
                update(JobItem(id: jobID, file: item.file, target: target, status: .working,
                               detail: stage == "reading" ? "读取中…" : "写出中…"))
            }, onDone: { [weak self] res in
                switch res {
                case .success(let r):
                    var it = JobItem(id: jobID, file: item.file, target: target, status: .done,
                                     detail: "\(r.rows) 行 × \(r.cols) 列 · \(String(format: "%.1f", r.elapsed))s",
                                     output: r.output, warning: r.warning)
                    it.output = r.output
                    it.warning = r.warning
                    update(it)
                    self?.addRecent(RecentItem(time: Date(), input: p, output: r.output, target: target,
                                               rows: r.rows, cols: r.cols, elapsed: r.elapsed))
                    DonutPanel.shared.jobFinished(detail: "已保存 ✓")
                case .failure(let err):
                    update(JobItem(id: jobID, file: item.file, target: target, status: .failed,
                                   detail: err.message))
                    DonutPanel.shared.jobFinished(detail: "转换失败")
                }
            })
        }
    }

    /// 关闭全部通知卡片
    func closeAllJobs() {
        withAnimation(.easeOut(duration: 0.2)) { jobs = [] }
    }

    // MARK: 最近转换

    static var recentsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataWheel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }

    func loadRecents() {
        if let d = try? Data(contentsOf: Self.recentsURL),
           let items = try? JSONDecoder().decode([RecentItem].self, from: d) {
            recents = items
        }
    }

    func addRecent(_ item: RecentItem) {
        recents.insert(item, at: 0)
        recents = Array(recents.prefix(30))
        if let d = try? JSONEncoder().encode(recents) {
            try? d.write(to: Self.recentsURL, options: .atomic)
        }
    }

    func clearRecents() {
        recents = []
        try? Data().write(to: Self.recentsURL)
    }
}


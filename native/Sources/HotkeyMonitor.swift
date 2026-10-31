// DataWheel — 全局快捷键拖拽监视
// 按住修饰键（默认 ⌥ Option，可在设置改为 ⌃ Control）拖动文件 → 转盘在光标处弹出，
// 拖到目标扇区上松开即转换，无需打开应用窗口。
// 依赖：listen-only CGEventTap 需要系统「辅助功能」权限。
import AppKit
import ApplicationServices

final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var authorized = true
    private(set) var tapVariant: String?        // 当前 tap 层级（HID+default 最稳）
    private var promptedListen = false          // 每次启动只弹一次「输入监控」授权请求

    /// 当前生效的组合键（从设置读取，多个修饰键同时按住才触发）
    var requiredFlags: CGEventFlags {
        let s = Settings.load()
        let mods = (s.hotkeyFlags?.isEmpty == false) ? s.hotkeyFlags! : [s.hotkeyModifier]
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case "control":  f.insert(.maskControl)
            case "command":  f.insert(.maskCommand)
            case "shift":    f.insert(.maskShift)
            case "capslock": f.insert(.maskAlphaShift)
            default:         f.insert(.maskAlternate)
            }
        }
        return f.isEmpty ? .maskAlternate : f
    }

    private var donutShown = false
    private var eventCount = 0
    private var healthTimer: Timer?
    private var lastReinstallAt = Date.distantPast

    private init() {}

    // MARK: 生命周期

    func start() {
        // 保活定时器：① tap 被系统停用时自动重新启用；② 辅助功能权限后补授予时自动重试创建。
        // 后台常驻场景下（应用不在前台）也要保证快捷键拖拽始终可用。
        startHealthCheck()
        guard tap == nil else { return }
        // mouseMoved 用于事件流自检（权限是否真正生效的唯一可靠判据）；普通鼠标移动只记时间戳
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        Self.log("start: AXTrusted=\(Self.isTrusted) ListenEvent=\(Self.listenEventAccess)")
        // 关键：必须用 HID 层，不能用 Session 层。macOS 15 起 Session 层 tap 有焦点过滤——
        // 应用不在前台/被隐藏时收不到事件；HID 层在窗口服务器之前接收，无此限制。
        // 首选 HID+defaultTap（不受 Secure Input 禁用，Karabiner/BTT 方案），依次回退。
        // Swift 覆盖层未暴露 .cgHIDEventTap case，用 rawValue（kCGHIDEventTap = 0）。
        let hid = CGEventTapLocation(rawValue: 0)!
        let session = CGEventTapLocation(rawValue: 1)!
        let attempts: [(String, CGEventTapLocation, CGEventTapOptions)] = [
            ("HID+default", hid, .defaultTap),
            ("HID+listenOnly", hid, .listenOnly),
            ("Session+listenOnly", session, .listenOnly),
        ]
        var port: CFMachPort?
        var used = ""
        for (label, loc, opt) in attempts {
            port = CGEvent.tapCreate(tap: loc,
                                     place: .headInsertEventTap,
                                     options: opt,
                                     eventsOfInterest: eventMask,
                                     callback: Self.tapCallback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
            if port != nil { used = label; break }
            Self.log("start: tapCreate FAILED (\(label))")
        }
        guard let port else {
            authorized = false   // 权限不足：全部层级创建失败
            Self.log("start: 所有 tap 层级均创建失败（检查辅助功能/输入监控权限）")
            return
        }
        Self.log("start: tap created & enabled (\(used))")
        authorized = true
        tapVariant = used
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // 未拿到「输入监控」权限时请求一次授权（HID+defaultTap 需要；缺它时系统会
        // 持续禁用 listen-only tap，导致快捷键拖拽时灵时不灵）
        if used != "HID+default", !Self.listenEventAccess, !promptedListen {
            promptedListen = true
            Self.log("start: 请求「输入监控」权限")
            CGRequestListenEventAccess()
        }
    }

    /// 「输入监控」权限预检（HID 层 tap 可能需要；macOS 10.15+）
    static var listenEventAccess: Bool { CGPreflightListenEventAccess() }

    /// 调试日志（排查快捷键链路）
    static func log(_ s: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DataWheel/hotkey.log")
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(s)\n"
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        }
        tap = nil
        runLoopSource = nil
    }

    /// 完整重建 tap（stop + start）。tapEnable 重开无效时的唯一可靠恢复手段。
    /// 注意不能直接调 start()——其 guard tap == nil 会早退成空操作。
    func reinstall() {
        lastReinstallAt = Date()
        stop()
        start()
    }

    /// tap 保活：每 1.5 秒巡检（.common 模式，拖拽等模态期间也不停摆）。
    /// 系统会以 kCGEventTapDisabledByUserInput/Timeout 静默停用 tap（隐藏应用、锁屏、
    /// 缺「输入监控」权限时 listen-only tap 更是会被持续禁用）；tapEnable 重开无效时重建。
    private func startHealthCheck() {
        guard healthTimer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let tap = self.tap else {
                if Self.isTrusted { self.start() }   // 权限后补授予：自动重试创建
                return
            }
            // 权限升级：「输入监控」已授予但 tap 还不是 HID+default → 重建升级
            if self.tapVariant != "HID+default", Self.listenEventAccess {
                Self.log("health: 「输入监控」已授权，升级为 HID+defaultTap")
                self.reinstall()
                return
            }
            guard !CGEvent.tapIsEnabled(tap: tap) else { return }
            // 被停用：先尝试直接重开
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                Self.log("health: tap 已恢复")
            } else if Date().timeIntervalSince(self.lastReinstallAt) > 3 {
                Self.log("health: tapEnable 未生效，重建 tap")
                self.reinstall()
            }
        }
        healthTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func restart() {
        stop()
        start()
    }

    /// 系统辅助功能权限状态
    static var isTrusted: Bool { AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary) }

    // MARK: 事件流自检

    private let activityLock = NSLock()
    private var _lastEventAt = Date.distantPast

    /// 收到任意事件时记录时间戳（事件线程调用，不进主队列）
    func noteActivity() {
        activityLock.lock()
        _lastEventAt = Date()
        activityLock.unlock()
    }

    /// 事件流是否存活：tap 在监听且最近收到过系统事件（移动鼠标即可触发）
    func isEventFlowAlive(within: TimeInterval = 20) -> Bool {
        activityLock.lock()
        let t = _lastEventAt
        activityLock.unlock()
        return tap != nil && Date().timeIntervalSince(t) < within
    }

    /// 弹出辅助功能授权提示（系统会自动把应用加进列表，用户只需打开开关）
    @discardableResult
    static func promptAX() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    // MARK: 事件回调

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let monitor = userInfo.map({ Unmanaged<HotkeyMonitor>.fromOpaque($0).takeUnretainedValue() }) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .mouseMoved {
            monitor.noteActivity()   // 高频事件在事件线程直接记时间戳
            return Unmanaged.passUnretained(event)
        }
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // 回调在事件线程，转发主线程处理
        DispatchQueue.main.async { self.process(type: type, event: event) }
    }

    private func process(type: CGEventType, event: CGEvent) {
        // 调试：记录前 5 个事件，确认 tap 是否收到事件
        if eventCount < 5 {
            eventCount += 1
            Self.log("event #\(eventCount): \(type.rawValue) flags=\(event.flags.rawValue)")
        }
        let need = requiredFlags
        let modHeld = event.flags.isSuperset(of: need)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统禁用了 tap（回调超时、隐藏应用、Secure Input 等）：立即重新启用，
            // 0.3s 后复核，仍未恢复则重建（tapEnable 对失效 tap 可能无效）
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
                    Self.log("tap 重新启用无效，重建")
                    self.reinstall()
                }
                Self.log("tap disabled (\(type.rawValue)), re-enabled")
            }
            return

        case .leftMouseDragged:
            guard !donutShown else {
                // 转盘已弹出：跟随悬停状态（面板自身拖放目标会接管扇区高亮）
                return
            }
            guard modHeld else { return }
            // 按住修饰键拖动：在光标处弹出转盘（位置在光标处，光标位于中心盘）
            donutShown = true
            Self.log("dragged+mod: showHotkey at \(NSEvent.mouseLocation)")
            DonutPanel.shared.showHotkey(at: NSEvent.mouseLocation)

        case .leftMouseUp:
            guard donutShown else { return }
            // 拖放若落在转盘扇区上，performDragOperation 已触发转换（转盘转入"转换中"态）
            // 否则稍候隐藏（给落在面板上的 drop 一点时间窗口）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.donutShown else { return }
                if DonutModel.shared.busyCount == 0 {
                    DonutPanel.shared.hide()
                }
                self.donutShown = false
            }

        case .flagsChanged:
            guard donutShown, !modHeld else { return }
            // 修饰键提前松开：取消
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.donutShown else { return }
                if DonutModel.shared.busyCount == 0 {
                    DonutPanel.shared.hide()
                }
                self.donutShown = false
            }

        default:
            break
        }
    }
}

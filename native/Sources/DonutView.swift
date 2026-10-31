// DataWheel — 转盘：Filee 式白色圆盘楔形扇区 + 独立浮动 NSPanel
// 三种形态：drag（窗口内拖放，面板不接收鼠标）/ hotkey（全局快捷键拖放，面板直接接收拖放）/ click（点击扇区）
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DonutMode { case drag, click }

// MARK: - 转盘状态（独立于主窗口状态）

final class DonutModel: ObservableObject {
    static let shared = DonutModel()
    @Published var mode: DonutMode = .drag
    @Published var hotIndex = -1
    @Published var fileCount = 0
    @Published var busyCount = 0
    @Published var lastDetail: String?
    var pendingPaths: [String] = []
}

// MARK: - 浮动转盘面板

final class DonutPanel: NSPanel {
    static let shared = DonutPanel()
    static let side: CGFloat = DonutGeometry.size + 32

    private var clickOutsideMonitor: Any?
    private var lastDragPoint: CGPoint = .zero
    private var dragAnchor: CGPoint = .zero   // 拖入点：转盘锚定在此
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// 每次显示重建 root view，让入场动画每次都播放
    private func installContent(acceptsDrops: Bool) {
        let hosting = NSHostingView(rootView: DonutContent(model: DonutModel.shared))
        if acceptsDrops {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
            let drop = PanelDropTarget(frame: container.bounds)
            // 关键：NSHostingView 默认零 frame，作为子视图加入后若父视图不 resize 就永远不布局，
            // 内容以零 bounds 为中心绘制 → 整个转盘只有 1/4 落在面板内
            hosting.frame = container.bounds
            drop.autoresizingMask = [.width, .height]
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(drop)
            container.addSubview(hosting)
            contentView = container
        } else {
            contentView = hosting   // 直接作为 contentView 时 AppKit 会自动撑满
        }
    }

    /// 应用处于隐藏（⌘H）状态时先恢复窗口显示（不激活应用、不抢焦点）；
    /// 后台常驻场景下按快捷键拖文件也能正常弹出转盘
    private func unhideAppIfNeeded() {
        guard NSApp.isHidden else { return }
        NSApp.unhide(nil)
        // unhide 有过渡动画，期间窗口置前可能被吞：稍候补一次 orderFrontRegardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isVisible else { return }
            self.orderFrontRegardless()
        }
    }

    /// 窗口内拖放：锚定在拖入点（约束在应用窗口内），面板不接收鼠标
    func showDrag(count: Int, at screenPoint: CGPoint, limit: CGRect? = nil) {
        unhideAppIfNeeded()
        let m = DonutModel.shared
        m.mode = .drag
        m.fileCount = max(count, 1)
        m.pendingPaths = []
        m.hotIndex = -1
        m.lastDetail = nil
        ignoresMouseEvents = true
        removeMonitor()
        setContentSize(NSSize(width: Self.side, height: Self.side))
        installContent(acceptsDrops: false)
        lastDragPoint = .zero
        dragAnchor = screenPoint
        place(center: screenPoint, limit: limit)
        orderFrontRegardless()
    }

    /// 全局快捷键拖放：转盘在光标处弹出，面板直接接收 Finder 拖放
    func showHotkey(at screenPoint: CGPoint) {
        unhideAppIfNeeded()
        let m = DonutModel.shared
        m.mode = .drag
        m.fileCount = 1
        m.pendingPaths = []
        m.hotIndex = -1
        m.lastDetail = nil
        ignoresMouseEvents = false
        removeMonitor()
        setContentSize(NSSize(width: Self.side, height: Self.side))
        installContent(acceptsDrops: true)
        lastDragPoint = .zero
        dragAnchor = screenPoint
        place(center: screenPoint)
        orderFrontRegardless()
    }

    /// 点击模式（服务菜单 / 选择文件 / Dock 拖放）：点击扇区转换
    func showClick(paths: [String], at screenPoint: CGPoint? = nil) {
        unhideAppIfNeeded()
        let m = DonutModel.shared
        m.mode = .click
        m.pendingPaths = paths
        m.fileCount = max(paths.count, 1)
        m.hotIndex = -1
        m.lastDetail = nil
        ignoresMouseEvents = false
        setContentSize(NSSize(width: Self.side, height: Self.side))
        installContent(acceptsDrops: false)
        let pt = screenPoint ?? {
            let f = NSScreen.main?.visibleFrame ?? .zero
            return CGPoint(x: f.midX, y: f.midY)
        }()
        place(center: pt)
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 点击面板外部关闭
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    /// 窗口内拖放中更新位置与悬停扇区：锚定拖入点 + 轻微漂移
    func moveDrag(to screenPoint: CGPoint, limit: CGRect? = nil) {
        guard isVisible else { return }
        let moved = abs(screenPoint.x - lastDragPoint.x) + abs(screenPoint.y - lastDragPoint.y)
        guard moved >= 2 else { return }
        lastDragPoint = screenPoint
        let nx = max(-14, min(14, (screenPoint.x - dragAnchor.x) * 0.08))
        let ny = max(-14, min(14, (screenPoint.y - dragAnchor.y) * 0.08))
        let center = place(center: CGPoint(x: dragAnchor.x + nx, y: dragAnchor.y + ny), limit: limit)
        let offset = CGPoint(x: screenPoint.x - center.x, y: center.y - screenPoint.y)
        DonutModel.shared.hotIndex = DonutGeometry.sectorIndex(offset: offset)
    }

    // MARK: 转换进度反馈（中心盘显示）

    func jobStarted() {
        DonutModel.shared.busyCount += 1
        cancelHide()
    }

    func jobFinished(detail: String) {
        let m = DonutModel.shared
        m.busyCount = max(0, m.busyCount - 1)
        m.lastDetail = detail
        if m.busyCount == 0, isVisible {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        removeMonitor()
        cancelHide()
        DonutModel.shared.hotIndex = -1
        DonutModel.shared.busyCount = 0
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func removeMonitor() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
    }

    /// 定位面板（中心对齐目标点），收进屏幕可见区与可选约束区（应用窗口）内
    @discardableResult
    private func place(center pt: CGPoint, limit: CGRect? = nil) -> CGPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(pt, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        var f = screen.visibleFrame
        if let limit { f = f.intersection(limit) }
        let half = Self.side / 2
        let x = min(max(pt.x - half, f.minX + 4), f.maxX - Self.side - 4)
        let y = min(max(pt.y - half, f.minY + 4), f.maxY - Self.side - 4)
        setFrameOrigin(CGPoint(x: x, y: y))
        return CGPoint(x: x + half, y: y + half)
    }
}

// MARK: - 面板自身的拖放目标（快捷键拖放模式）

final class PanelDropTarget: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func updateHot(_ sender: NSDraggingInfo) {
        let loc = convert(sender.draggingLocation, from: nil)
        // NSView y 向上 → 翻转为 SwiftUI y 向下偏移
        let o = CGPoint(x: loc.x - bounds.midX, y: bounds.midY - loc.y)
        DonutModel.shared.hotIndex = DonutGeometry.sectorIndex(offset: o)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHot(sender); return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHot(sender); return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DonutModel.shared.hotIndex = -1
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let hot = DonutModel.shared.hotIndex
        let paths = fileURLs(sender).map { $0.path }.filter { !$0.isEmpty }
        guard hot >= 0, hot < DataFormat.all.count, !paths.isEmpty else {
            DonutPanel.shared.hide()
            return true
        }
        DonutModel.shared.hotIndex = -1
        AppState.shared.convert(paths: paths, target: DataFormat.all[hot].id)
        return true
    }
}

// MARK: - AppKit 原生拖放目标（主窗口内拖入 → 转盘）

struct DropTargetNSView: NSViewRepresentable {
    func makeNSView(context: Context) -> FileDropTarget { FileDropTarget() }
    func updateNSView(_ view: FileDropTarget, context: Context) {}
}

final class FileDropTarget: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func screenPoint(_ sender: NSDraggingInfo) -> CGPoint {
        let loc = convert(sender.draggingLocation, from: nil)
        return window?.convertToScreen(NSRect(origin: loc, size: .zero)).origin
            ?? NSEvent.mouseLocation
    }

    /// 应用窗口内容区（屏幕坐标）：约束转盘完全在窗口内
    private func windowLimit() -> CGRect? {
        guard let w = window else { return nil }
        return w.convertToScreen(w.contentLayoutRect)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        DonutPanel.shared.showDrag(count: max(fileURLs(sender).count, 1),
                                   at: screenPoint(sender), limit: windowLimit())
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard DonutPanel.shared.isVisible else { return hasFiles(sender) ? .copy : [] }
        DonutPanel.shared.moveDrag(to: screenPoint(sender), limit: windowLimit())
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DonutPanel.shared.hide()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let hot = DonutModel.shared.hotIndex
        let paths = fileURLs(sender).map { $0.path }.filter { !$0.isEmpty }
        guard hot >= 0, hot < DataFormat.all.count, !paths.isEmpty else {
            DonutPanel.shared.hide()
            return true
        }
        DonutModel.shared.hotIndex = -1
        AppState.shared.convert(paths: paths, target: DataFormat.all[hot].id)
        return true
    }
}

// MARK: - 转盘内容（面板内 SwiftUI）

struct DonutContent: View {
    @ObservedObject var model: DonutModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            donutCore
            if model.mode == .click { sectorButtons }
        }
        .frame(width: DonutPanel.side, height: DonutPanel.side)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { appeared = true }
        }
        .onTapGesture {
            if model.mode == .click { DonutPanel.shared.hide() }
        }
    }

    /// Filee 式：白色实心圆盘 + 细线楔形扇区 + 中心小圆
    private var donutCore: some View {
        ZStack {
            // 白色圆盘底盘 + 柔阴影 + 细边框
            Circle()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.16), radius: 16, y: 5)
                .overlay(Circle().stroke(Color(hex: 0xE4E4EA), lineWidth: 1.5))

            // 楔形扇区：默认透明，悬停时填充格式淡色
            ForEach(Array(DataFormat.all.enumerated()), id: \.offset) { idx, fmt in
                let hot = model.hotIndex == idx
                DonutGeometry.sectorPath(index: idx)
                    .fill(hot ? fmt.color.opacity(0.15) : Color.clear)
                    .animation(.easeOut(duration: 0.12), value: hot)
            }

            // 楔形分隔线
            ForEach(Array(DataFormat.all.enumerated()), id: \.offset) { idx, _ in
                DonutGeometry.sectorPath(index: idx)
                    .stroke(Color(hex: 0xE4E4EA), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            // 格式名标签
            ForEach(Array(DataFormat.all.enumerated()), id: \.offset) { idx, fmt in
                let hot = model.hotIndex == idx
                let rad = DonutGeometry.midAngle(index: idx) * .pi / 180
                let labelR = (DonutGeometry.hubRadius + DonutGeometry.radius) / 2
                Text(fmt.label)
                    .font(.system(size: fmt.label.count > 5 ? 11 : 13, weight: .bold))
                    .foregroundColor(hot ? fmt.color : Color(hex: 0x2A3040))
                    .position(x: DonutGeometry.center.x + cos(rad) * labelR,
                              y: DonutGeometry.center.y + sin(rad) * labelR)
                    .animation(.easeOut(duration: 0.12), value: hot)
            }

            // 中心小圆
            hub
                .frame(width: DonutGeometry.hubRadius * 2, height: DonutGeometry.hubRadius * 2)
        }
        .frame(width: DonutGeometry.size, height: DonutGeometry.size)
        .scaleEffect(appeared ? 1 : 0.55)
        .opacity(appeared ? 1 : 0)
        .onContinuousHover { phase in
            guard model.mode == .click else { return }
            switch phase {
            case .active(let loc):
                let o = CGPoint(x: loc.x - DonutGeometry.size / 2, y: loc.y - DonutGeometry.size / 2)
                model.hotIndex = DonutGeometry.sectorIndex(offset: o)
            case .ended:
                model.hotIndex = -1
            }
        }
    }

    private var hub: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color(hex: 0xE4E4EA), lineWidth: 1.5))

            if model.busyCount > 0 {
                VStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("转换中…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(hex: 0x5A6472))
                }
            } else if model.hotIndex >= 0 {
                let fmt = DataFormat.all[model.hotIndex]
                VStack(spacing: 3) {
                    Text(fmt.label)
                        .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                        .foregroundColor(fmt.color)
                    Text(fmt.desc)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: 0x8A8F9E))
                    Text(model.mode == .drag ? "松开转换" : "点击转换")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(brandColor)
                }
                .padding(.horizontal, 10)
            } else if let detail = model.lastDetail {
                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: 0x16A34A))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: 0x8A8F9E))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 10)
            } else {
                VStack(spacing: 1) {
                    Text("\(model.fileCount)")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundColor(Color(hex: 0x1F2430))
                    Text("个文件")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: 0x8A8F9E))
                }
            }
        }
    }

    /// 点击模式：透明楔形命中按钮
    private var sectorButtons: some View {
        ZStack {
            ForEach(Array(DataFormat.all.enumerated()), id: \.offset) { idx, fmt in
                Button {
                    guard model.mode == .click, !model.pendingPaths.isEmpty else { return }
                    let paths = model.pendingPaths
                    DonutPanel.shared.hide()
                    AppState.shared.convert(paths: paths, target: fmt.id)
                } label: {
                    let hit = DonutGeometry.sectorPath(index: idx)
                    hit
                        .fill(Color.white.opacity(0.001))
                        .contentShape(hit)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: DonutGeometry.size, height: DonutGeometry.size)
    }
}

// MARK: - 转盘几何（Filee 式楔形）

enum DonutGeometry {
    static let size: CGFloat = 320
    static let center = CGPoint(x: 160, y: 160)
    static let radius: CGFloat = 152      // 圆盘半径
    static let hubRadius: CGFloat = 60    // 中心小圆半径
    static let gapDeg: CGFloat = 2        // 楔块角间隙

    /// 实心楔形扇区（圆心 → 外弧 → 闭合）
    static func sectorPath(index: Int) -> Path {
        let n = CGFloat(DataFormat.all.count)
        let span = 360 / n
        let a0 = -90 + CGFloat(index) * span + gapDeg / 2
        let a1 = a0 + span - gapDeg
        var p = Path()
        p.move(to: center)
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        p.closeSubpath()
        return p
    }

    static func midAngle(index: Int) -> CGFloat {
        let n = CGFloat(DataFormat.all.count)
        let span = 360 / n
        return -90 + CGFloat(index) * span + span / 2
    }

    /// 光标命中判定：入参为相对转盘中心的偏移（SwiftUI 坐标系，y 向下）
    static func sectorIndex(offset o: CGPoint) -> Int {
        let r = sqrt(o.x * o.x + o.y * o.y)
        guard r >= hubRadius + 2, r <= radius - 2 else { return -1 }
        var deg = atan2(o.y, o.x) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let n = DataFormat.all.count
        let idx = Int(deg / (360 / CGFloat(n)))
        return (idx >= 0 && idx < n) ? idx : -1
    }
}

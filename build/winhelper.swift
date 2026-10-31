// DataWheel 截图辅助：列出窗口/显示器 / 移动鼠标
// 用法: swift winhelper.swift list | displays | warp x y
import CoreGraphics
import Foundation

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "warp" && args.count >= 4 {
    let p = CGPoint(x: Double(args[2]) ?? 800, y: Double(args[3]) ?? 500)
    CGWarpMouseCursorPosition(p)
    usleep(200000)
    // 轻微移动让系统确认位置
    if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                          mouseCursorPosition: CGPoint(x: p.x + 1, y: p.y + 1), mouseButton: .left) {
        move.post(tap: .cghidEventTap)
    }
    exit(0)
}

if args.count >= 2 && args[1] == "displays" {
    var count: UInt32 = 0
    CGGetActiveDisplayList(8, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(8, &ids, &count)
    for d in ids.prefix(Int(count)) {
        let b = CGDisplayBounds(d)
        print("display=\(d) x=\(Int(b.origin.x)) y=\(Int(b.origin.y)) w=\(Int(b.width)) h=\(Int(b.height)) pw=\(CGDisplayPixelsWide(d))")
    }
    exit(0)
}

// 默认: 列出窗口
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.hasPrefix("DataWheel") else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: NSNumber] ?? [:]
    let name = w[kCGWindowName as String] as? String ?? ""
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    print("id=\(id) layer=\(layer) alpha=\(alpha) x=\(b["X"]?.intValue ?? 0) y=\(b["Y"]?.intValue ?? 0) w=\(b["Width"]?.intValue ?? 0) h=\(b["Height"]?.intValue ?? 0) name=\(name)")
}

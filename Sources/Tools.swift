import AppKit

// Build-time and check-time helpers. None of this runs in normal use.

enum IconMaker {
    /// Draws the app logo at 1024 px: a screen with the app list along its left edge.
    static func write(to path: String) {
        let n = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow(); drop.shadowColor = NSColor.black.withAlphaComponent(0.30); drop.shadowBlurRadius = 28; drop.shadowOffset = NSSize(width: 0, height: -12); drop.set()
        NSColor(hex: "#0B1E4A").setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(hex: "#4C93F0"), NSColor(hex: "#1B55C0"), NSColor(hex: "#0B1E4A")])?.draw(in: body, angle: -70)
        NSGradient(starting: NSColor(hex: "#1FB5A9", alpha: 0.55), ending: NSColor(hex: "#1FB5A9", alpha: 0))?
            .draw(in: body, relativeCenterPosition: NSPoint(x: 0.7, y: 0.6))
        // the app that fills the screen
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: 420, y: 180, width: 440, height: 664), xRadius: 56, yRadius: 56).fill()
        // the list on the left edge
        let panel = NSRect(x: 164, y: 180, width: 220, height: 664)
        NSColor.white.withAlphaComponent(0.30).setFill()
        let pp = NSBezierPath(roundedRect: panel, xRadius: 64, yRadius: 64); pp.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke(); pp.lineWidth = 6; pp.stroke()
        for i in 0..<4 {
            let r = NSRect(x: panel.minX + 34, y: panel.maxY - 150 - CGFloat(i) * 148, width: 152, height: 112)
            (i == 0 ? NSColor.white : NSColor.white.withAlphaComponent(0.42)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Renders the list or the settings sheet to a PNG so the layout can be checked without touching the screen.
/// The real frosting needs a live screen, so a stand-in backdrop is painted behind.
enum Snapshot {
    final class Backdrop: NSView {
        var theme = Theme.current
        var radius: CGFloat = 0
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let t = theme
            // pretend screen content: half a white page, half a dark window
            NSColor(hex: "#F4F5F7").setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
            NSColor(hex: "#12161F").setFill(); NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2).fill()
            let glass = bounds.insetBy(dx: 16, dy: 16)
            let path = NSBezierPath(roundedRect: glass, xRadius: radius, yRadius: radius)
            // stand-in for blur + material: what the frosted layer averages to
            (t.isDark ? NSColor.rgba(52, 54, 60, 0.82) : NSColor.rgba(214, 216, 222, 0.82)).setFill(); path.fill()
            t.tint.setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            NSGradient(starting: t.sheen, ending: t.sheen.withAlphaComponent(0))?.draw(in: NSRect(x: glass.minX, y: glass.minY, width: glass.width, height: glass.height * 0.38), angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            t.rim.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }

    private static func write(_ v: NSView, to path: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func panel(to path: String, picking: Bool, trusted: Bool) {
        let t = Theme.current
        AppModel.shared.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))   // let the window list load
        AppModel.shared.picking = picking
        let list = ListView()
        list.theme = t
        list.forceTrusted = trusted
        list.reload()
        let w = Prefs.shared.list == "icons" ? Theme.widthIcons : Theme.widthNames
        let h = t.fullHeight ? 640 : list.preferredHeight()
        let back = Backdrop(frame: NSRect(x: 0, y: 0, width: w + 32, height: h + 32))
        back.theme = t; back.radius = t.radius
        list.frame = NSRect(x: 16, y: 16, width: w, height: h)
        back.addSubview(list)
        write(back, to: path)
    }

    static func settings(to path: String) {
        let t = Theme.current
        let v = SettingsView()
        v.theme = t
        let h = v.contentHeight()
        let back = Backdrop(frame: NSRect(x: 0, y: 0, width: SettingsWindow.width + 32, height: h + 32))
        back.theme = t; back.radius = t.sheetRadius
        v.frame = NSRect(x: 16, y: 16, width: SettingsWindow.width, height: h)
        back.addSubview(v)
        write(back, to: path)
    }
}

/// `EdgeSwitch --cli <command>`: small checks run from Terminal.
enum CLI {
    private static func find(_ name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame }
    }
    private static func wait(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    static func run(_ a: [String]) -> Int32 {
        switch a.first ?? "" {
        case "status":
            print("trusted=\(WindowControl.trusted) \(SystemTweaks.status())")
            for s in NSScreen.screens { print("screen frame=\(s.frame) visible=\(s.visibleFrame)") }
            let on = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let owners = Dictionary(grouping: on.compactMap { $0[kCGWindowOwnerName as String] as? String }, by: { $0 }).mapValues(\.count)
            print("on-screen windows by owner: \(owners.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let ws = WindowControl.windows(of: app.processIdentifier)
                let d = ws.map { w -> String in
                    let f = WindowControl.frame(of: w) ?? .zero
                    return "[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(WindowControl.isStandard(w) ? "" : " non-standard")\(WindowControl.isMinimized(w) ? " minimized" : "")]"
                }.joined(separator: " ")
                print("\(app.processIdentifier) \(app.localizedName ?? "?")\(app.isHidden ? " (hidden)" : "") \(d)")
                for w in WindowControl.windowList(of: app.processIdentifier) {
                    print("    window \(w.id)\(w.isMain ? " (front)" : "")\(w.minimized ? " (minimized)" : ""): \(AppModel.shortTitle(w.title, app: app.localizedName ?? ""))  <- \(w.title)")
                }
            }
        case "fill":
            guard a.count > 1, let app = find(a[1]) else { print("app not found"); return 1 }
            WindowControl.place(pid: app.processIdentifier, slot: .full, areas: WindowControl.areas())
        case "split":
            guard a.count > 2, let l = find(a[1]), let r = find(a[2]) else { print("app not found"); return 1 }
            WindowControl.place(pid: l.processIdentifier, slot: .left, areas: WindowControl.areas(), on: WindowControl.areas().first)
            WindowControl.place(pid: r.processIdentifier, slot: .right, areas: WindowControl.areas(), on: WindowControl.areas().first)
        case "warp":   // move the cursor; coordinates from the top-left of the main display
            guard a.count > 2, let x = Double(a[1]), let y = Double(a[2]) else { return 2 }
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        case "click", "rightclick":
            guard a.count > 2, let x = Double(a[1]), let y = Double(a[2]) else { return 2 }
            let p = CGPoint(x: x, y: y), right = a[0] == "rightclick"
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            wait(0.15)
            CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
            wait(0.05)
            CGEvent(mouseEventSource: src, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
            wait(0.1)
        case "own":    // this app's windows that are on screen now
            let on = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            for w in on where (w[kCGWindowOwnerName as String] as? String) == "Edge Switch" {
                let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                print("window x=\(Int(b["X"] ?? 0)) y=\(Int(b["Y"] ?? 0)) w=\(Int(b["Width"] ?? 0)) h=\(Int(b["Height"] ?? 0)) layer=\(w[kCGWindowLayer as String] ?? 0) alpha=\(w[kCGWindowAlpha as String] ?? 0)")
            }
            print("front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        case "closewin":   // close the windows of an app whose title matches exactly
            guard a.count > 2, let app = find(a[1]) else { print("app not found"); return 1 }
            for w in WindowControl.windowList(of: app.processIdentifier) where w.title == a[2] { WindowControl.close(window: w.element) }
        case "hide":
            guard a.count > 1, let app = find(a[1]) else { print("app not found"); return 1 }
            app.hide(); wait(0.3)
        case "tweaks":
            SystemTweaks.apply()
            wait(2)
            print(SystemTweaks.status())
            for s in NSScreen.screens { print("screen frame=\(s.frame) visible=\(s.visibleFrame)") }
        default:
            print("commands: status | fill <app> | split <left> <right> | tweaks | warp x y | click x y | rightclick x y | own | closewin <app> <title> | hide <app>")
            return 2
        }
        return 0
    }
}

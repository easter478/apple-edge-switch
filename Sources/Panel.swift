import AppKit

// The list of open apps that slides out of the left screen edge.

final class EdgePanel: NSPanel {
    /// Only the Home Assistant view takes the keyboard (for its search); the app list never does.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

final class PanelController {
    static let shared = PanelController()

    private let panel: EdgePanel
    private let glass = GlassView()
    let list = ListView()
    private(set) var isOpen = false
    private var armed = true
    private var closeWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var screen: NSScreen?
    private var sliding = false

    private init() {
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: Theme.widthNames, height: 400),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView(frame: panel.contentLayoutRect)
        glass.frame = root.bounds; glass.autoresizingMask = [.width, .height]
        list.frame = root.bounds; list.autoresizingMask = [.width, .height]
        root.addSubview(glass); root.addSubview(list)
        panel.contentView = root
        list.controller = self
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) { monitors.append(l) }
        // Slow safety net in case macOS stops delivering mouse events to the monitors.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.mouseMoved() }
        for n in [Notification.Name.modelChanged, .prefsChanged, .homeChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(modelChanged), name: n, object: nil)
        }
    }

    // MARK: mouse

    private func screen(at p: NSPoint) -> NSScreen? { NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if !isOpen {
            guard let s = screen(at: p) else { return }
            if p.x > s.frame.minX + 3 { armed = true; return }
            // Only a real outer edge counts, not the seam between two displays.
            let outer = !NSScreen.screens.contains { $0 != s && NSMouseInRect(NSPoint(x: s.frame.minX - 4, y: p.y), $0.frame, false) }
            if p.x <= s.frame.minX + 1 { dlog("edge: armed=\(armed) outer=\(outer) buttons=\(NSEvent.pressedMouseButtons)") }
            if armed, outer, p.x <= s.frame.minX + 1, NSEvent.pressedMouseButtons == 0 { open(on: s) }
            return
        }
        let f = panel.frame
        let away = p.x > f.maxX + 56 || p.y > f.maxY + 90 || p.y < f.minY - 90
        if away {
            if closeWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.close() }
                closeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
            }
        } else {
            closeWork?.cancel(); closeWork = nil
        }
        list.pointerMoved(toScreen: p)
    }

    // MARK: open / close

    private func targetFrame(on s: NSScreen, theme t: Theme) -> NSRect {
        let w = Prefs.shared.list == "icons" && list.mode == .apps ? Theme.widthIcons : Theme.widthNames
        let maxH = s.frame.height - 2 * t.inset
        let h = t.fullHeight ? maxH : min(maxH, list.preferredHeight())
        return NSRect(x: s.frame.minX + t.inset, y: s.frame.midY - h / 2, width: w, height: h)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func open(on s: NSScreen) {
        guard !isOpen else { return }
        dlog("open")
        isOpen = true; armed = false; screen = s
        closeWork?.cancel(); closeWork = nil
        AppModel.shared.refresh()
        AppModel.shared.loadWindows()
        let t = Theme.current
        glass.apply(t)
        list.theme = t
        list.reload()
        let end = targetFrame(on: s, theme: t)
        if reduceMotion {
            panel.setFrame(end, display: true); panel.alphaValue = 1; panel.orderFrontRegardless()
        } else {
            panel.setFrame(end.offsetBy(dx: -(end.width + t.inset + 6), dy: 0), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            sliding = true
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = Theme.slideIn
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                // Window rows may have loaded while the list was sliding in: fit the list to them now.
                self?.sliding = false
                self?.modelChanged()
            })
        }
        panel.invalidateShadow()
    }

    func close() {
        guard isOpen else { return }
        dlog("close")
        isOpen = false
        sliding = false
        closeWork?.cancel(); closeWork = nil
        AppModel.shared.picking = false
        HomeAssistant.shared.stopWatching()
        panel.allowKey = false
        list.clearPointer()
        let done = { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
            self.list.mode = .apps      // the list always opens on the apps
        }
        if reduceMotion { done(); return }
        let t = Theme.current
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Theme.slideOut
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(f.offsetBy(dx: -(f.width + t.inset + 6), dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: done)
    }

    /// Switches the list between the apps and the Home Assistant controls.
    func show(_ mode: ListView.Mode) {
        list.mode = mode
        if mode == .home {
            HomeAssistant.shared.startWatching()
            panel.allowKey = true
            panel.makeKey()
            panel.makeFirstResponder(list)
        } else {
            HomeAssistant.shared.stopWatching()
        }
        modelChanged()
    }

    @objc private func modelChanged() {
        guard isOpen, let s = screen else { return }
        let t = Theme.current
        glass.apply(t)
        list.theme = t
        list.reload()
        guard !sliding else { return }
        let f = targetFrame(on: s, theme: t)
        if f != panel.frame { panel.setFrame(f, display: true); panel.invalidateShadow() }
    }

    var currentScreen: NSScreen? { screen }
}

final class ListView: NSView {
    enum Mode { case apps, home }

    enum Hit: Equatable {
        case none, row(Int), minimize(Int), close(Int), pin(Int), window(Int, Int), closeWindow(Int, Int)
        case gear, tool(String), cancel, notice, pinned(Int), unpin(Int)
        case back, entity(String), homeAction
    }

    weak var controller: PanelController?
    var theme = Theme.current
    var mode: Mode = .apps { didSet { if mode != oldValue { query = ""; scroll = 0; hover = .none; needsDisplay = true } } }

    private var entries: [AppEntry] = []
    private var wins: [[WindowInfo]] = []      // window rows under each app (empty in the icons-only list)
    private var counts: [Int] = []             // how many windows each app has
    /// What is drawn under each app, in order: a profile name, or a window (index into `wins`).
    private enum Sub { case header(String), window(Int) }
    private var subs: [[Sub]] = []
    private var pages: [[String]] = []         // the label of each window row
    private var pinned: [PinnedApp] = []
    private var pinnedIcons: [NSImage] = []
    private var hover: Hit = .none
    private var pressed: Hit = .none
    private var query = ""                     // Home Assistant search text
    private var scroll: CGFloat = 0            // Home Assistant list scroll offset
    private var model: AppModel { AppModel.shared }
    private var home: HomeAssistant { HomeAssistant.shared }
    private var iconsOnly: Bool { Prefs.shared.list == "icons" && mode == .apps }
    var forceTrusted: Bool?    // set only when rendering a picture for checks
    private var trusted: Bool { forceTrusted ?? WindowControl.trusted }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        entries = model.apps
        counts = entries.map { model.windows[$0.pid]?.count ?? 0 }
        wins = entries.map { iconsOnly ? [] : model.listedWindows(of: $0.pid) }
        subs = []; pages = []
        for (i, e) in entries.enumerated() {
            let parsed = wins[i].map { AppModel.parseTitle($0.title, app: e.name) }
            // Browsers that name the profile in the window title get their windows grouped under each profile.
            var order: [String] = []
            for p in parsed { if let n = p.profile, !order.contains(n) { order.append(n) } }
            if order.isEmpty {
                subs.append(wins[i].indices.map { .window($0) })
            } else {
                var list: [Sub] = []
                for name in order {
                    list.append(.header(name))
                    list += parsed.indices.filter { parsed[$0].profile == name }.map { .window($0) }
                }
                let loose = parsed.indices.filter { parsed[$0].profile == nil }
                if !loose.isEmpty { list.append(.header("Other windows")); list += loose.map { .window($0) } }
                subs.append(list)
            }
            pages.append(parsed.map(\.page))
        }
        let newPinned = Prefs.shared.pinned
        if newPinned != pinned {
            pinned = newPinned
            pinnedIcons = pinned.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        needsDisplay = true
    }
    func clearPointer() { hover = .none; pressed = .none; needsDisplay = true }

    // MARK: footer tools

    /// The buttons beside Settings: id, symbol, and the words shown while the pointer is on it.
    private var tools: [(id: String, symbol: String, hint: String)] {
        var t: [(String, String, String)] = []
        if Prefs.shared.showHome { t.append(("home", "house.fill", "Home Assistant")) }
        if Prefs.shared.showShots {
            t.append(("shot", "camera", "Screenshot: whole screen"))
            t.append(("area", "rectangle.dashed", "Screenshot: drag an area"))
        }
        return t
    }
    private var footerHeight: CGFloat { iconsOnly ? Theme.footer + CGFloat(tools.count) * 38 : Theme.footer }
    private var pinnedHeight: CGFloat {
        guard mode == .apps, !pinned.isEmpty else { return 0 }
        return iconsOnly ? CGFloat(pinned.count) * 44 : Theme.pinnedRow
    }

    // MARK: layout

    private struct Item { let rect: NSRect; let app: Int; let win: Int?; var header: String? = nil }

    private struct Metrics {
        var header: NSRect?
        var cancel: NSRect?
        var notice: NSRect?
        var items: [Item] = []
        var pinDivider: CGFloat?
        var pins: [NSRect] = []
        var divider: CGFloat = 0
        var gear: NSRect = .zero
        var tools: [(String, NSRect)] = []
        var content: NSRect = .zero        // where rows go (apps, or the Home Assistant list)
    }

    private var headerHeight: CGFloat { model.picking ? (iconsOnly ? 30 : 32) + 6 : 0 }
    private var noticeHeight: CGFloat { trusted ? 0 : (iconsOnly ? 52 : 62) + 6 }

    /// Height the list wants. Call after `reload()`.
    func preferredHeight() -> CGFloat {
        if mode == .home { return Theme.homeHeight }
        let n = CGFloat(max(entries.count, 1))
        var m: CGFloat = 0, h: CGFloat = 0
        for list in subs { for s in list { if case .header = s { h += 1 } else { m += 1 } } }
        let pins = pinnedHeight > 0 ? pinnedHeight + 17 : 0
        return Theme.pad + headerHeight + noticeHeight + n * Theme.rowHeight + m * Theme.windowRowHeight + h * Theme.groupHeaderHeight
            + (n + m + h - 1) * Theme.rowGap + 17 + pins + footerHeight + Theme.pad
    }

    private func metrics() -> Metrics {
        var m = Metrics()
        let pad = Theme.pad, w = bounds.width - 2 * pad

        // bottom up: Settings and tools, then the pinned apps
        let footerTop = bounds.height - pad - footerHeight
        m.divider = footerTop - 8.5
        if iconsOnly {
            m.gear = NSRect(x: pad, y: footerTop, width: w, height: Theme.footer)
            for (k, t) in tools.enumerated() {
                m.tools.append((t.id, NSRect(x: pad, y: footerTop + Theme.footer + CGFloat(k) * 38, width: w, height: 36)))
            }
        } else {
            let n = CGFloat(tools.count), bw: CGFloat = 34
            let toolsWidth = n * bw + max(0, n - 1) * 4
            m.gear = NSRect(x: pad, y: footerTop, width: w - (n > 0 ? toolsWidth + 8 : 0), height: Theme.footer)
            for (k, t) in tools.enumerated() {
                m.tools.append((t.id, NSRect(x: pad + w - toolsWidth + CGFloat(k) * (bw + 4), y: footerTop + (Theme.footer - 32) / 2, width: bw, height: 32)))
            }
        }
        var bottom = m.divider - 8
        if pinnedHeight > 0 {
            let top = m.divider - 8 - pinnedHeight
            if iconsOnly {
                for k in pinned.indices { m.pins.append(NSRect(x: pad, y: top + CGFloat(k) * 44, width: w, height: 44)) }
            } else {
                for k in pinned.indices { m.pins.append(NSRect(x: pad + 5 + CGFloat(k) * 46, y: top, width: 46, height: pinnedHeight)) }
            }
            m.pinDivider = top - 8.5
            bottom = top - 17
        }

        // top down
        var y = pad
        if mode == .home {
            m.content = NSRect(x: pad, y: y, width: w, height: max(0, bottom - y))
            return m
        }
        if model.picking {
            let h: CGFloat = iconsOnly ? 30 : 32
            m.header = NSRect(x: pad, y: y, width: w, height: h)
            m.cancel = iconsOnly ? NSRect(x: pad, y: y, width: w, height: h) : NSRect(x: pad + w - 66, y: y + 3, width: 66, height: 26)
            y += h + 6
        }
        if !trusted {
            let h: CGFloat = iconsOnly ? 52 : 62
            m.notice = NSRect(x: pad, y: y, width: w, height: h)
            y += h + 6
        }
        m.content = NSRect(x: pad, y: y, width: w, height: max(0, bottom - y))

        let n = entries.count
        guard n > 0 else { return m }
        var k = 0, g = 0
        for list in subs { for s in list { if case .header = s { g += 1 } else { k += 1 } } }
        var appH = Theme.rowHeight, winH = Theme.windowRowHeight, headH = Theme.groupHeaderHeight
        let gaps = CGFloat(n + k + g - 1) * Theme.rowGap
        let avail = bottom - y - gaps
        let wanted = CGFloat(n) * appH + CGFloat(k) * winH + CGFloat(g) * headH
        if wanted > avail, wanted > 0 {     // many apps and windows: rows get shorter rather than fall off the list
            let f = max(0, avail) / wanted
            appH = max(30, floor(appH * f)); winH = max(20, floor(winH * f)); headH = max(14, floor(headH * f))
        }
        let ix = pad + Theme.windowIndent, iw = w - Theme.windowIndent
        for i in 0..<n {
            m.items.append(Item(rect: NSRect(x: pad, y: y, width: w, height: appH), app: i, win: nil))
            y += appH + Theme.rowGap
            for s in subs[i] {
                switch s {
                case .header(let name):
                    m.items.append(Item(rect: NSRect(x: ix, y: y, width: iw, height: headH), app: i, win: nil, header: name))
                    y += headH + Theme.rowGap
                case .window(let j):
                    m.items.append(Item(rect: NSRect(x: ix, y: y, width: iw, height: winH), app: i, win: j))
                    y += winH + Theme.rowGap
                }
            }
        }
        return m
    }

    // Buttons on an app row, from the right: minimize, close, pin.
    private func canClose(_ i: Int) -> Bool { !iconsOnly && !model.picking }
    private func canMinimize(_ i: Int) -> Bool { canClose(i) && !entries[i].hidden }
    private func canPin(_ i: Int) -> Bool { canClose(i) && model.canPin(entries[i]) }
    private func buttonRect(_ slot: Int, in row: NSRect) -> NSRect {
        let b = Theme.buttonSize
        return NSRect(x: row.maxX - 8 - b - CGFloat(slot) * (b + 4), y: row.midY - b / 2, width: b, height: b)
    }
    private func minimizeRect(in row: NSRect) -> NSRect { buttonRect(0, in: row) }
    private func closeRect(in row: NSRect, app i: Int) -> NSRect { buttonRect(canMinimize(i) ? 1 : 0, in: row) }
    private func pinRect(in row: NSRect, app i: Int) -> NSRect { buttonRect(canMinimize(i) ? 2 : 1, in: row) }
    private func buttonsWidth(_ i: Int) -> CGFloat {
        let n = (canMinimize(i) ? 1 : 0) + (canClose(i) ? 1 : 0) + (canPin(i) ? 1 : 0)
        return n == 0 ? 10 : CGFloat(n) * (Theme.buttonSize + 4) + 12
    }
    private func windowCloseRect(in row: NSRect) -> NSRect {
        let b = min(24, row.height - 2)
        return NSRect(x: row.maxX - b - 4, y: row.midY - b / 2, width: b, height: b)
    }
    private func pinIconRect(_ r: NSRect) -> NSRect {
        NSRect(x: r.midX - Theme.icon / 2, y: r.midY - Theme.icon / 2 - (iconsOnly ? 0 : 3), width: Theme.icon, height: Theme.icon)
    }
    private func unpinRect(_ r: NSRect) -> NSRect {
        let i = pinIconRect(r)
        return NSRect(x: i.maxX - 9, y: i.minY - 7, width: 16, height: 16)
    }

    private func hit(at p: NSPoint) -> Hit {
        let m = metrics()
        for (id, r) in m.tools where r.contains(p) { return .tool(id) }
        if m.gear.contains(p) { return .gear }
        if mode == .home { return homeHit(at: p, in: m.content) }
        if let c = m.cancel, c.contains(p) { return .cancel }
        if let n = m.notice, n.contains(p) { return .notice }
        for (k, r) in m.pins.enumerated() where r.contains(p) {
            return unpinRect(r).insetBy(dx: -2, dy: -2).contains(p) ? .unpin(k) : .pinned(k)
        }
        for it in m.items where it.rect.insetBy(dx: 0, dy: -Theme.rowGap / 2).contains(p) {
            if it.header != nil { return .none }
            if let j = it.win {
                if !model.picking, windowCloseRect(in: it.rect).contains(p) { return .closeWindow(it.app, j) }
                return .window(it.app, j)
            }
            if canMinimize(it.app), minimizeRect(in: it.rect).contains(p) { return .minimize(it.app) }
            if canClose(it.app), closeRect(in: it.rect, app: it.app).contains(p) { return .close(it.app) }
            if canPin(it.app), pinRect(in: it.rect, app: it.app).contains(p) { return .pin(it.app) }
            return .row(it.app)
        }
        return .none
    }

    // MARK: drawing helpers

    private func fill(_ r: NSRect, _ radius: CGFloat, _ c: NSColor) {
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private func text(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .left) {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        ps.alignment = align
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor, centeredIn r: NSRect) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func button(_ r: NSRect, _ name: String, hovered: Bool) {
        fill(r, 8, hovered ? theme.hover : theme.field)
        symbol(name, size: name == "xmark" ? 10.5 : 12, color: theme.text, centeredIn: r)
    }

    private func pill(_ r: NSRect, _ label: String, hovered: Bool) {
        fill(r, r.height / 2, hovered ? theme.hover : theme.field)
        text(label, .systemFont(ofSize: 12.5, weight: .medium), theme.text, in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 16), align: .center)
    }

    private func drawOnFill(_ r: NSRect, radius: CGFloat) {
        let t = theme
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if let end = t.rowOnEnd {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = t.accent.withAlphaComponent(t.isDark ? 0.45 : 0.30)
            glow.shadowBlurRadius = 14; glow.shadowOffset = NSSize(width: 0, height: -4)
            glow.set()
            t.rowOn.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: t.rowOn.withAlphaComponent(0), ending: end)?.draw(in: path, angle: 0)
        } else {
            t.rowOn.setFill(); path.fill()
        }
    }

    private func drawSwitch(_ r: NSRect, on: Bool) {
        let t = theme
        fill(r, r.height / 2, on ? t.accent : t.hover)
        if !on {
            t.hair.setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            p.lineWidth = 1; p.stroke()
        }
        let d = r.height - 4
        let knob = NSRect(x: on ? r.maxX - d - 2 : r.minX + 2, y: r.minY + 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -1); sh.set()
        fill(knob, d / 2, .white)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: drawing the apps

    private func drawApp(_ i: Int, in r: NSRect) {
        let t = theme, e = entries[i]
        let state = model.state(of: e.pid)
        let hovered: Bool = { switch hover { case .row(i), .minimize(i), .close(i), .pin(i): return true; default: return false } }()
        let radius = min(t.rowRadius, r.height / 2)
        if !state.isEmpty {
            drawOnFill(r, radius: radius)
            if t.showsBar { fill(NSRect(x: r.minX, y: r.minY + r.height * 0.28, width: 3, height: r.height * 0.44), 1.5, t.accent) }
        } else if hovered {
            fill(r, radius, t.hover)
        }

        let isz = min(Theme.icon, r.height - 8)
        let iconRect = iconsOnly
            ? NSRect(x: r.midX - isz / 2, y: r.midY - isz / 2, width: isz, height: isz)
            : NSRect(x: r.minX + 10, y: r.midY - isz / 2, width: isz, height: isz)
        e.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: e.hidden ? 0.45 : 1, respectFlipped: true, hints: nil)

        if iconsOnly {
            // How many windows the app has; clicking the app again steps through them.
            if counts[i] >= 2 {
                let b = NSRect(x: iconRect.maxX - 11, y: iconRect.maxY - 11, width: 16, height: 16)
                fill(b, 8, t.text)
                text("\(min(counts[i], 9))", .systemFont(ofSize: 10.5, weight: .bold), t.inverseText,
                     in: NSRect(x: b.minX, y: b.midY - 6.5, width: b.width, height: 13), align: .center)
            }
            return
        }

        let tx = iconRect.maxX + 12
        let tw = r.maxX - tx - (hovered ? buttonsWidth(i) : 10)
        let sub = model.subtitle(for: e)
        let nameColor = e.hidden ? t.text.withAlphaComponent(0.72) : t.text
        if sub.isEmpty || r.height < 44 {
            text(e.name, Theme.nameFont(), nameColor, in: NSRect(x: tx, y: r.midY - 9, width: tw, height: 18))
        } else {
            text(e.name, Theme.nameFont(), nameColor, in: NSRect(x: tx, y: r.midY - 17, width: tw, height: 18))
            // On the coloured row for the app in use the second line needs the full text colour to stay readable.
            text(sub, Theme.subFont(), state.isEmpty ? t.textMuted : t.text, in: NSRect(x: tx, y: r.midY + 1, width: tw, height: 16))
        }
        if hovered && canClose(i) {
            if canPin(i) { button(pinRect(in: r, app: i), model.isPinned(e) ? "pin.fill" : "pin", hovered: hover == .pin(i)) }
            button(closeRect(in: r, app: i), "xmark", hovered: hover == .close(i))
            if canMinimize(i) { button(minimizeRect(in: r), "minus", hovered: hover == .minimize(i)) }
        }
    }

    private func drawWindow(_ i: Int, _ j: Int, in r: NSRect) {
        let t = theme, e = entries[i], w = wins[i][j]
        let state = model.state(of: w, pid: e.pid)
        let hovered = hover == .window(i, j) || hover == .closeWindow(i, j)
        let radius = min(t.rowRadius, r.height / 2)
        if !state.isEmpty { drawOnFill(r, radius: radius) } else if hovered { fill(r, radius, t.hover) }

        let showClose = hovered && !model.picking
        let side = state == "left" ? "Left" : state == "right" ? "Right" : ""
        let reserve: CGFloat = showClose ? 34 : side.isEmpty ? 10 : 46
        let color = (!state.isEmpty || hovered) && !w.minimized ? t.text : t.textMuted
        let label = pages[i][j] + (w.minimized ? " (in the Dock)" : "")
        text(label, .systemFont(ofSize: 12.5, weight: state.isEmpty ? .regular : .medium), color,
             in: NSRect(x: r.minX + 10, y: r.midY - 8, width: r.width - 10 - reserve, height: 16))
        if showClose {
            button(windowCloseRect(in: r), "xmark", hovered: hover == .closeWindow(i, j))
        } else if !side.isEmpty {
            text(side, .systemFont(ofSize: 11.5), t.text, in: NSRect(x: r.maxX - 44, y: r.midY - 7.5, width: 36, height: 15), align: .right)
        }
    }

    private func drawPinned(_ k: Int, in r: NSRect) {
        let t = theme, p = pinned[k]
        let hovered = hover == .pinned(k) || hover == .unpin(k)
        let running = model.pid(of: p) != nil
        if hovered { fill(r.insetBy(dx: 2, dy: 1), min(t.rowRadius, 12), t.hover) }
        let icon = pinIconRect(r)
        pinnedIcons[k].draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if running && !iconsOnly { fill(NSRect(x: icon.midX - 2, y: icon.maxY + 3, width: 4, height: 4), 2, t.accent) }
        if hovered {
            let b = unpinRect(r)
            fill(b, 8, t.text)
            symbol("xmark", size: 7.5, color: t.inverseText, centeredIn: b)
        }
    }

    private func drawFooter(_ m: Metrics) {
        let t = theme
        fill(NSRect(x: Theme.pad, y: m.divider, width: bounds.width - 2 * Theme.pad, height: 1), 0, t.hair)
        let g = m.gear
        var hint: String?
        if case .tool(let id) = hover { hint = tools.first { $0.id == id }?.hint }
        if hover == .gear { fill(g, min(t.rowRadius, g.height / 2), t.hover) }
        let gc = hover == .gear || hint != nil ? t.text : t.textMuted
        if iconsOnly {
            symbol("gearshape", size: 17, color: gc, centeredIn: g)
        } else if let hint {
            // While the pointer is on a tool button, its name takes the place of "Settings".
            text(hint, .systemFont(ofSize: 12.5), t.text, in: NSRect(x: g.minX + 10, y: g.midY - 8, width: g.width - 12, height: 16))
        } else {
            symbol("gearshape", size: 17, color: gc, centeredIn: NSRect(x: g.minX + 10, y: g.minY, width: Theme.icon, height: g.height))
            text("Settings", .systemFont(ofSize: 13.5), gc, in: NSRect(x: g.minX + 10 + Theme.icon + 12, y: g.midY - 9, width: g.width - 60, height: 18))
        }
        for (id, r) in m.tools {
            let active = id == "home" && mode == .home
            let radius = min(t.rowRadius, 10)
            if active { drawOnFill(r, radius: radius) } else { fill(r, radius, hover == .tool(id) ? t.hover : t.field) }
            if id == "home" && !iconsOnly {
                text("HA", .systemFont(ofSize: 12.5, weight: .bold), t.text, in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 16), align: .center)
            } else {
                symbol(tools.first { $0.id == id }?.symbol ?? "circle", size: 14, color: t.text, centeredIn: r)
            }
        }
    }

    // MARK: Home Assistant view

    private enum HomeItem { case section(String), entity(HAEntity) }

    private var homeItems: [HomeItem] {
        let q = query.lowercased()
        let list = home.entities.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        var out: [HomeItem] = []
        for (domain, title) in [("light", "Lights"), ("switch", "Switches")] {
            let part = list.filter { $0.domain == domain }
            if !part.isEmpty { out.append(.section(title)); out += part.map { .entity($0) } }
        }
        return out
    }

    private struct HomeLayout {
        var back: NSRect, search: NSRect, list: NSRect
        var rows: [(NSRect, HomeItem)] = []
        var action: NSRect?            // the button of a message (Open Settings / Try again)
        var height: CGFloat = 0
    }

    private func homeLayout(in c: NSRect) -> HomeLayout {
        var l = HomeLayout(back: NSRect(x: c.minX, y: c.minY + 2, width: 70, height: 28),
                           search: NSRect(x: c.minX, y: c.minY + 40, width: c.width, height: 32),
                           list: NSRect(x: c.minX, y: c.minY + 82, width: c.width, height: max(0, c.height - 82)))
        var y = l.list.minY - scroll
        for it in homeItems {
            let h: CGFloat = { if case .section = it { return 24 } else { return Theme.homeRow } }()
            l.rows.append((NSRect(x: c.minX, y: y, width: c.width, height: h), it))
            y += h + 2
        }
        l.height = y + scroll - l.list.minY
        if l.rows.isEmpty { l.action = NSRect(x: c.midX - 62, y: l.list.minY + 96, width: 124, height: 30) }
        return l
    }

    private func homeMessage() -> (text: String, button: String?) {
        switch home.status {
        case .notSetUp: return ("Add your Home Assistant address and access token in Settings.", "Open Settings")
        case .loading: return ("Loading your lights and switches.", nil)
        case .failed(let m): return (m, "Try again")
        case .ok: return (query.isEmpty ? "Home Assistant has no lights or switches." : "Nothing matches \"\(query)\".", nil)
        }
    }

    private func homeHit(at p: NSPoint, in c: NSRect) -> Hit {
        let l = homeLayout(in: c)
        if l.back.contains(p) { return .back }
        if l.rows.isEmpty { return homeMessage().button != nil && (l.action?.contains(p) ?? false) ? .homeAction : .none }
        guard l.list.contains(p) else { return .none }
        for (r, it) in l.rows where r.contains(p) { if case .entity(let e) = it { return .entity(e.id) } }
        return .none
    }

    private func drawHome(in c: NSRect) {
        let t = theme, l = homeLayout(in: c)
        // header: back to the apps, and the title
        fill(l.back, l.back.height / 2, hover == .back ? t.hover : t.field)
        symbol("chevron.left", size: 11, color: t.text, centeredIn: NSRect(x: l.back.minX + 6, y: l.back.minY, width: 18, height: l.back.height))
        text("Apps", .systemFont(ofSize: 12.5, weight: .medium), t.text, in: NSRect(x: l.back.minX + 24, y: l.back.midY - 8, width: 40, height: 16))
        text("Home Assistant", .systemFont(ofSize: 13, weight: .semibold), t.text,
             in: NSRect(x: l.back.maxX + 8, y: l.back.midY - 8, width: c.maxX - l.back.maxX - 12, height: 17), align: .right)

        // search
        fill(l.search, min(t.rowRadius, 12), t.field)
        t.hair.setStroke()
        let sp = NSBezierPath(roundedRect: l.search.insetBy(dx: 0.5, dy: 0.5), xRadius: min(t.rowRadius, 12), yRadius: min(t.rowRadius, 12))
        sp.lineWidth = 1; sp.stroke()
        symbol("magnifyingglass", size: 12, color: t.textMuted, centeredIn: NSRect(x: l.search.minX + 4, y: l.search.minY, width: 26, height: l.search.height))
        text(query.isEmpty ? "Type to search" : query, .systemFont(ofSize: 13), query.isEmpty ? t.textMuted : t.text,
             in: NSRect(x: l.search.minX + 30, y: l.search.midY - 8.5, width: l.search.width - 38, height: 17))

        if l.rows.isEmpty {
            let msg = homeMessage()
            let ps = NSMutableParagraphStyle(); ps.alignment = .center; ps.lineBreakMode = .byWordWrapping
            (msg.text as NSString).draw(with: NSRect(x: c.minX + 10, y: l.list.minY + 20, width: c.width - 20, height: 70),
                                        options: [.usesLineFragmentOrigin],
                                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: t.text, .paragraphStyle: ps])
            if let b = msg.button, let r = l.action { pill(r, b, hovered: hover == .homeAction) }
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: l.list).addClip()
        for (r, it) in l.rows where r.maxY >= l.list.minY && r.minY <= l.list.maxY {
            switch it {
            case .section(let title):
                text(title, .systemFont(ofSize: 11.5, weight: .semibold), t.textMuted, in: NSRect(x: r.minX + 10, y: r.maxY - 17, width: r.width - 20, height: 15))
            case .entity(let e):
                if hover == .entity(e.id) { fill(r, min(t.rowRadius, r.height / 2), t.hover) }
                text(e.name, .systemFont(ofSize: 13.5), e.available ? t.text : t.textMuted,
                     in: NSRect(x: r.minX + 10, y: r.midY - 9, width: r.width - 74, height: 18))
                if e.available {
                    drawSwitch(NSRect(x: r.maxX - 50, y: r.midY - 12, width: 40, height: 24), on: e.isOn)
                } else {
                    text("Offline", .systemFont(ofSize: 11.5), t.textMuted, in: NSRect(x: r.maxX - 60, y: r.midY - 7.5, width: 50, height: 15), align: .right)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: draw

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        let m = metrics()

        if mode == .home {
            drawHome(in: m.content)
            drawFooter(m)
            return
        }

        if let h = m.header, let c = m.cancel {
            if !iconsOnly {
                text("Split \(model.name(model.current)) with", .systemFont(ofSize: 13, weight: .semibold), t.text,
                     in: NSRect(x: h.minX + 8, y: h.midY - 8, width: h.width - 84, height: 18))
            }
            fill(c, c.height / 2, hover == .cancel ? t.hover : t.field)
            text("Cancel", .systemFont(ofSize: iconsOnly ? 11.5 : 12.5), t.text,
                 in: NSRect(x: c.minX, y: c.midY - 8, width: c.width, height: 16), align: .center)
        }

        if let n = m.notice {
            fill(n, t.rowRadius, hover == .notice ? t.hover : t.field)
            t.hair.setStroke()
            let b = NSBezierPath(roundedRect: n.insetBy(dx: 0.5, dy: 0.5), xRadius: t.rowRadius, yRadius: t.rowRadius)
            b.lineWidth = 1; b.stroke()
            if iconsOnly {
                symbol("exclamationmark.triangle.fill", size: 18, color: t.text, centeredIn: n)
            } else {
                text("Allow window control", .systemFont(ofSize: 13, weight: .semibold), t.text,
                     in: NSRect(x: n.minX + 12, y: n.minY + 9, width: n.width - 24, height: 17))
                text("Click, then switch on Edge Switch under Accessibility.", .systemFont(ofSize: 12), t.textMuted,
                     in: NSRect(x: n.minX + 12, y: n.minY + 27, width: n.width - 24, height: 30))
            }
        }

        for it in m.items {
            if let name = it.header {
                text(name, .systemFont(ofSize: 11.5, weight: .semibold), t.textMuted,
                     in: NSRect(x: it.rect.minX + 10, y: it.rect.maxY - 15, width: it.rect.width - 14, height: 15))
            } else if let j = it.win {
                drawWindow(it.app, j, in: it.rect)
            } else {
                drawApp(it.app, in: it.rect)
            }
        }

        if let d = m.pinDivider {
            fill(NSRect(x: Theme.pad, y: d, width: bounds.width - 2 * Theme.pad, height: 1), 0, t.hair)
            for (k, r) in m.pins.enumerated() { drawPinned(k, in: r) }
        }
        drawFooter(m)
    }

    // MARK: pointer and keys

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func setHover(_ h: Hit) { if h != hover { hover = h; needsDisplay = true } }

    func pointerMoved(toScreen p: NSPoint) {
        guard let w = window else { return }
        setHover(hit(at: convert(w.convertPoint(fromScreen: p), from: nil)))
    }

    override func mouseMoved(with e: NSEvent) { setHover(hit(at: convert(e.locationInWindow, from: nil))) }
    override func mouseDragged(with e: NSEvent) { setHover(hit(at: convert(e.locationInWindow, from: nil))) }
    override func mouseExited(with e: NSEvent) { setHover(.none) }
    override func mouseDown(with e: NSEvent) { pressed = hit(at: convert(e.locationInWindow, from: nil)) }

    override func scrollWheel(with e: NSEvent) {
        guard mode == .home else { return }
        let l = homeLayout(in: metrics().content)
        let maxScroll = max(0, l.height - l.list.height)
        scroll = min(maxScroll, max(0, scroll - e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8)))
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        guard mode == .home else { return }
        switch e.keyCode {
        case 53:    // Esc: clear the search, then go back to the apps
            if query.isEmpty { controller?.show(.apps) } else { query = ""; scroll = 0 }
        case 51:    // delete
            if !query.isEmpty { query.removeLast(); scroll = 0 }
        default:
            guard !e.modifierFlags.contains(.command), let c = e.characters, !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) else { return }
            query += c; scroll = 0
        }
        needsDisplay = true
    }

    private func window(_ i: Int, _ j: Int) -> WindowInfo? {
        wins.indices.contains(i) && wins[i].indices.contains(j) ? wins[i][j] : nil
    }

    override func mouseUp(with e: NSEvent) {
        let h = hit(at: convert(e.locationInWindow, from: nil))
        defer { pressed = .none }
        guard h == pressed else { return }
        let screen = controller?.currentScreen
        switch h {
        case .row(let i):
            guard entries.indices.contains(i) else { return }
            let pid = entries[i].pid
            if model.picking {
                guard model.splitWith(pid, window: nil, on: screen) else { return }
            } else if iconsOnly, pid == model.current, model.split == nil, counts[i] >= 2 {
                model.showNextWindow(of: pid)
            } else {
                model.show(pid)
            }
            controller?.close()
        case .window(let i, let j):
            guard let w = window(i, j) else { return }
            let pid = entries[i].pid
            if model.picking {
                guard model.splitWith(pid, window: w, on: screen) else { return }
            } else {
                model.show(pid, window: w)
            }
            controller?.close()
        case .minimize(let i):
            guard entries.indices.contains(i) else { return }
            model.minimize(entries[i].pid)
        case .close(let i):
            guard entries.indices.contains(i) else { return }
            model.quit(entries[i].pid)
        case .pin(let i):
            guard entries.indices.contains(i) else { return }
            if !model.togglePin(entries[i]) { NSSound.beep() }
        case .closeWindow(let i, let j):
            guard let w = window(i, j) else { return }
            model.close(window: w, of: entries[i].pid)
        case .pinned(let k):
            guard pinned.indices.contains(k) else { return }
            model.open(pinned[k])
            controller?.close()
        case .unpin(let k):
            guard pinned.indices.contains(k) else { return }
            model.unpin(pinned[k])
        case .gear:
            controller?.close()
            SettingsWindow.shared.show()
        case .tool("home"):
            controller?.show(mode == .home ? .apps : .home)
        case .tool(let id):
            // Let the list slide away first so it is not in the picture.
            controller?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.slideOut + 0.12) { Screenshots.take(selection: id == "area") }
        case .back:
            controller?.show(.apps)
        case .entity(let id):
            if let e = home.entities.first(where: { $0.id == id }) { home.toggle(e) }
        case .homeAction:
            if home.status == .notSetUp { controller?.close(); SettingsWindow.shared.show() } else { home.refresh() }
        case .cancel:
            model.picking = false
        case .notice:
            WindowControl.askForAccess()
            WindowControl.openAccessSettings()
            controller?.close()
        case .none:
            break
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard mode == .apps else { return }
        var pid: pid_t?
        var win: WindowInfo?
        switch hit(at: convert(e.locationInWindow, from: nil)) {
        case .row(let i), .minimize(let i), .close(let i), .pin(let i):
            if entries.indices.contains(i) { pid = entries[i].pid }
        case .window(let i, let j), .closeWindow(let i, let j):
            if let w = window(i, j) { pid = entries[i].pid; win = w }
        case .pinned, .unpin, .tool, .gear:
            return      // the pinned apps and the buttons at the bottom do nothing on a right-click
        default: break
        }
        if model.rightClick(on: pid, window: win, screen: controller?.currentScreen) { controller?.close() }
    }
}

import AppKit

// The list of open apps that slides out of the left screen edge.

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
        NotificationCenter.default.addObserver(self, selector: #selector(modelChanged), name: .modelChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(modelChanged), name: .prefsChanged, object: nil)
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
        let w = Prefs.shared.list == "icons" ? Theme.widthIcons : Theme.widthNames
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
        list.clearPointer()
        if reduceMotion { panel.orderOut(nil); return }
        let t = Theme.current
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = Theme.slideOut
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(f.offsetBy(dx: -(f.width + t.inset + 6), dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        })
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
    enum Hit: Equatable {
        case none, row(Int), minimize(Int), close(Int), window(Int, Int), closeWindow(Int, Int), gear, cancel, notice
    }

    weak var controller: PanelController?
    var theme = Theme.current
    private var entries: [AppEntry] = []
    private var wins: [[WindowInfo]] = []      // window rows under each app (empty in the icons-only list)
    private var counts: [Int] = []             // how many windows each app has
    /// What is drawn under each app, in order: a profile name, or a window (index into `wins`).
    private enum Sub { case header(String), window(Int) }
    private var subs: [[Sub]] = []
    private var pages: [[String]] = []         // the label of each window row
    private var hover: Hit = .none
    private var pressed: Hit = .none
    private var model: AppModel { AppModel.shared }
    private var iconsOnly: Bool { Prefs.shared.list == "icons" }
    var forceTrusted: Bool?    // set only when rendering a picture for checks
    private var trusted: Bool { forceTrusted ?? WindowControl.trusted }

    override var isFlipped: Bool { true }
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
                pages.append(parsed.map(\.page))
            } else {
                var list: [Sub] = []
                for name in order {
                    list.append(.header(name))
                    list += parsed.indices.filter { parsed[$0].profile == name }.map { .window($0) }
                }
                let loose = parsed.indices.filter { parsed[$0].profile == nil }
                if !loose.isEmpty { list.append(.header("Other windows")); list += loose.map { .window($0) } }
                subs.append(list)
                pages.append(parsed.map(\.page))
            }
        }
        needsDisplay = true
    }
    func clearPointer() { hover = .none; pressed = .none; needsDisplay = true }

    // MARK: layout

    private struct Item { let rect: NSRect; let app: Int; let win: Int?; var header: String? = nil }

    private struct Metrics {
        var header: NSRect?
        var cancel: NSRect?
        var notice: NSRect?
        var items: [Item] = []
        var divider: CGFloat = 0
        var gear: NSRect = .zero
    }

    private var headerHeight: CGFloat { model.picking ? (iconsOnly ? 30 : 32) + 6 : 0 }
    private var noticeHeight: CGFloat { trusted ? 0 : (iconsOnly ? 52 : 62) + 6 }

    /// Height the list wants. Call after `reload()`.
    func preferredHeight() -> CGFloat {
        let n = CGFloat(max(entries.count, 1))
        var m: CGFloat = 0, h: CGFloat = 0
        for list in subs { for s in list { if case .header = s { h += 1 } else { m += 1 } } }
        return Theme.pad + headerHeight + noticeHeight + n * Theme.rowHeight + m * Theme.windowRowHeight + h * Theme.groupHeaderHeight
            + (n + m + h - 1) * Theme.rowGap + 17 + Theme.footer + Theme.pad
    }

    private func metrics() -> Metrics {
        var m = Metrics()
        let pad = Theme.pad, w = bounds.width - 2 * pad
        var y = pad
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
        let footerTop = bounds.height - pad - Theme.footer
        m.divider = footerTop - 8.5
        m.gear = NSRect(x: pad, y: footerTop, width: w, height: Theme.footer)

        let n = entries.count
        guard n > 0 else { return m }
        var k = 0, g = 0
        for list in subs { for s in list { if case .header = s { g += 1 } else { k += 1 } } }
        var appH = Theme.rowHeight, winH = Theme.windowRowHeight, headH = Theme.groupHeaderHeight
        let gaps = CGFloat(n + k + g - 1) * Theme.rowGap
        let avail = m.divider - 8 - y - gaps
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

    private func canClose(_ i: Int) -> Bool { !iconsOnly && !model.picking }
    private func canMinimize(_ i: Int) -> Bool { canClose(i) && !entries[i].hidden }
    private func minimizeRect(in row: NSRect) -> NSRect {
        let b = Theme.buttonSize
        return NSRect(x: row.maxX - b - 8, y: row.midY - b / 2, width: b, height: b)
    }
    /// The close button sits to the left of minimize, or in its place when the app is already minimized.
    private func closeRect(in row: NSRect, app i: Int) -> NSRect {
        let m = minimizeRect(in: row)
        return canMinimize(i) ? m.offsetBy(dx: -(Theme.buttonSize + 4), dy: 0) : m
    }
    private func windowCloseRect(in row: NSRect) -> NSRect {
        let b = min(24, row.height - 2)
        return NSRect(x: row.maxX - b - 4, y: row.midY - b / 2, width: b, height: b)
    }

    private func hit(at p: NSPoint) -> Hit {
        let m = metrics()
        if let c = m.cancel, c.contains(p) { return .cancel }
        if let n = m.notice, n.contains(p) { return .notice }
        if m.gear.contains(p) { return .gear }
        for it in m.items where it.rect.insetBy(dx: 0, dy: -Theme.rowGap / 2).contains(p) {
            if it.header != nil { return .none }
            if let j = it.win {
                if !model.picking, windowCloseRect(in: it.rect).contains(p) { return .closeWindow(it.app, j) }
                return .window(it.app, j)
            }
            if canMinimize(it.app), minimizeRect(in: it.rect).contains(p) { return .minimize(it.app) }
            if canClose(it.app), closeRect(in: it.rect, app: it.app).contains(p) { return .close(it.app) }
            return .row(it.app)
        }
        return .none
    }

    // MARK: drawing

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

    private func drawApp(_ i: Int, in r: NSRect) {
        let t = theme, e = entries[i]
        let state = model.state(of: e.pid)
        let hovered = hover == .row(i) || hover == .minimize(i) || hover == .close(i)
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
        let reserve: CGFloat = !hovered ? 10 : canMinimize(i) ? 2 * Theme.buttonSize + 20 : canClose(i) ? Theme.buttonSize + 16 : 10
        let tw = r.maxX - tx - reserve
        let sub = model.subtitle(for: e)
        let nameColor = e.hidden ? t.text.withAlphaComponent(0.72) : t.text
        if sub.isEmpty || r.height < 44 {
            text(e.name, Theme.nameFont(), nameColor, in: NSRect(x: tx, y: r.midY - 9, width: tw, height: 18))
        } else {
            text(e.name, Theme.nameFont(), nameColor, in: NSRect(x: tx, y: r.midY - 17, width: tw, height: 18))
            text(sub, Theme.subFont(), t.textMuted, in: NSRect(x: tx, y: r.midY + 1, width: tw, height: 16))
        }
        if hovered && canClose(i) {
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
            text(side, .systemFont(ofSize: 11.5), t.textMuted, in: NSRect(x: r.maxX - 44, y: r.midY - 7.5, width: 36, height: 15), align: .right)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        let m = metrics()

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

        fill(NSRect(x: Theme.pad, y: m.divider, width: bounds.width - 2 * Theme.pad, height: 1), 0, t.hair)
        let g = m.gear
        if hover == .gear { fill(g, min(t.rowRadius, g.height / 2), t.hover) }
        let gc = hover == .gear ? t.text : t.textMuted
        if iconsOnly {
            symbol("gearshape", size: 17, color: gc, centeredIn: g)
        } else {
            symbol("gearshape", size: 17, color: gc, centeredIn: NSRect(x: g.minX + 10, y: g.minY, width: Theme.icon, height: g.height))
            text("Settings", .systemFont(ofSize: 13.5), gc, in: NSRect(x: g.minX + 10 + Theme.icon + 12, y: g.midY - 9, width: g.width - 70, height: 18))
        }
    }

    // MARK: pointer

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
        case .closeWindow(let i, let j):
            guard let w = window(i, j) else { return }
            model.close(window: w, of: entries[i].pid)
        case .gear:
            controller?.close()
            SettingsWindow.shared.show()
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
        var pid: pid_t?
        var win: WindowInfo?
        switch hit(at: convert(e.locationInWindow, from: nil)) {
        case .row(let i), .minimize(let i), .close(let i):
            if entries.indices.contains(i) { pid = entries[i].pid }
        case .window(let i, let j), .closeWindow(let i, let j):
            if let w = window(i, j) { pid = entries[i].pid; win = w }
        default: break
        }
        if model.rightClick(on: pid, window: win, screen: controller?.currentScreen) { controller?.close() }
    }
}

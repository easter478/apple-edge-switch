import AppKit
import ServiceManagement

// The settings sheet. Same frosted surface and tokens as the app list.

final class SheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { SettingsWindow.shared.hide() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { SettingsWindow.shared.hide() } else { super.keyDown(with: e) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        // There is no Edit menu (the app has no menu bar), so the text fields get their shortcuts here.
        switch e.charactersIgnoringModifiers {
        case "w": SettingsWindow.shared.hide(); return true
        case "q": NSApp.terminate(nil); return true
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        default: return super.performKeyEquivalent(with: e)
        }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    static let width: CGFloat = 560

    private let window: SheetWindow
    private let glass = GlassView()
    private let scroll = NSScrollView()
    let view = SettingsView()

    private init() {
        window = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindow.width, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let root = NSView(frame: window.contentLayoutRect)
        glass.frame = root.bounds; glass.autoresizingMask = [.width, .height]
        scroll.frame = root.bounds; scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = view
        root.addSubview(glass); root.addSubview(scroll)
        window.contentView = root
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .modelChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .homeChanged, object: nil)
    }

    var isVisible: Bool { window.isVisible }

    @objc func refresh() {
        guard window.isVisible else { return }
        apply()
    }

    private func apply() {
        let t = Theme.current
        glass.apply(t, radius: t.sheetRadius)
        view.theme = t
        scroll.appearance = t.appearance
        let h = view.contentHeight()
        view.frame = NSRect(x: 0, y: 0, width: SettingsWindow.width, height: h)
        view.positionFields()
        view.needsDisplay = true
        let s = NSScreen.main ?? NSScreen.screens[0]
        let wh = min(h, s.visibleFrame.height - 60)
        var f = window.frame
        if f.height != wh || !window.isVisible {
            f = NSRect(x: s.visibleFrame.midX - SettingsWindow.width / 2, y: s.visibleFrame.midY - wh / 2, width: SettingsWindow.width, height: wh)
            window.setFrame(f, display: true)
        }
        window.invalidateShadow()
    }

    func show() {
        view.loadFields()
        if HomeAssistant.shared.isSetUp { HomeAssistant.shared.refresh() }
        apply()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func hide() {
        window.orderOut(nil)
        if let c = AppModel.shared.current { NSRunningApplication(processIdentifier: c)?.activate(options: []) }
    }
}

final class SettingsView: NSView {
    enum Act: Equatable {
        case done, mode(String), theme(String), look(String), accent(String), list(String), toggle(String), access, quit
        case unpin(String), homeSave
    }

    private let addressField = NSTextField()
    private let tokenField = NSSecureTextField()
    private var fieldRects: [String: NSRect] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [addressField, tokenField] {
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: 13)
            f.cell?.usesSingleLineMode = true
            f.cell?.lineBreakMode = .byTruncatingTail
            f.target = self
            f.action = #selector(saveHome)
            addSubview(f)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Fills the address from the saved settings. The token field always starts empty: a saved token is never shown.
    func loadFields() {
        addressField.stringValue = Prefs.shared.haURL
        tokenField.stringValue = ""
    }

    /// Puts the two text fields where the last layout pass drew their boxes.
    func positionFields() {
        _ = walk(draw: false)
        let t = theme
        for (key, f) in [("address", addressField), ("token", tokenField)] {
            guard let r = fieldRects[key] else { continue }
            f.frame = NSRect(x: r.minX + 10, y: r.midY - 9, width: r.width - 20, height: 18)
            f.textColor = t.text
            f.appearance = t.appearance
            let hint = key == "address" ? "http://homeassistant.local:8123"
                : (Secrets.hasToken ? "Saved in your Keychain. Paste to replace." : "Paste a long-lived access token")
            f.placeholderAttributedString = NSAttributedString(string: hint, attributes: [.foregroundColor: t.textMuted, .font: NSFont.systemFont(ofSize: 13)])
        }
    }

    @objc private func saveHome() {
        var address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        if !address.isEmpty, !address.lowercased().hasPrefix("http://"), !address.lowercased().hasPrefix("https://") { address = "http://" + address }
        addressField.stringValue = address
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            saveFailed = !Secrets.saveToken(token)
            tokenField.stringValue = ""
        }
        Prefs.shared.haURL = address
        HomeAssistant.shared.credentialsChanged()
        HomeAssistant.shared.refresh()
        window?.makeFirstResponder(self)
        positionFields()
        needsDisplay = true
    }
    private var saveFailed = false

    var theme = Theme.current
    private var hover: Act?
    private var pressed: Act?
    private var loginError = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func contentHeight() -> CGFloat { walk(draw: false).height }

    // MARK: paint helpers

    private func fill(_ r: NSRect, _ radius: CGFloat, _ c: NSColor) {
        c.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
    private func stroke(_ r: NSRect, _ radius: CGFloat, _ c: NSColor, _ w: CGFloat = 1) {
        c.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: w / 2, dy: w / 2), xRadius: max(0, radius - w / 2), yRadius: max(0, radius - w / 2))
        p.lineWidth = w; p.stroke()
    }
    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, in r: NSRect, align: NSTextAlignment = .left) {
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail; ps.alignment = align
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: ps])
    }
    private func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    // MARK: state

    private var loginOn: Bool { SMAppService.mainApp.status == .enabled }

    private func isOn(_ key: String) -> Bool {
        let p = Prefs.shared
        switch key {
        case "hideDock": return p.hideDock
        case "hideMenuBar": return p.hideMenuBar
        case "stageManagerOff": return p.stageManagerOff
        case "login": return loginOn
        case "showHome": return p.showHome
        case "showShots": return p.showShots
        default: return false
        }
    }

    private func perform(_ a: Act) {
        let p = Prefs.shared
        switch a {
        case .done: SettingsWindow.shared.hide()
        case .mode(let v): p.mode = v
        case .theme(let v): p.theme = v
        case .look(let v): p.look = v
        case .accent(let v): p.accent = v
        case .list(let v): p.list = v
        case .toggle("hideDock"): p.hideDock.toggle()
        case .toggle("hideMenuBar"): p.hideMenuBar.toggle()
        case .toggle("stageManagerOff"): p.stageManagerOff.toggle()
        case .toggle("showHome"): p.showHome.toggle()
        case .toggle("showShots"): p.showShots.toggle()
        case .unpin(let id): p.pinned = p.pinned.filter { $0.id != id }
        case .homeSave: saveHome()
        case .toggle("login"):
            do {
                if loginOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
                loginError = false
            } catch { loginError = true }
            SettingsWindow.shared.refresh()
        case .toggle: break
        case .access: WindowControl.askForAccess(); WindowControl.openAccessSettings()
        case .quit: NSApp.terminate(nil)
        }
        needsDisplay = true
    }

    // MARK: one pass that both lays out and draws

    private struct Result { var items: [(NSRect, Act)] = []; var height: CGFloat = 0 }

    private func walk(draw: Bool) -> Result {
        var res = Result()
        let t = theme, p = Prefs.shared
        let m: CGFloat = 24, w = SettingsWindow.width - 2 * m
        let rr = t.rowRadius
        var y: CGFloat = 22

        func hot(_ r: NSRect, _ a: Act) { res.items.append((r, a)) }
        func card(_ r: NSRect, selected: Bool, act: Act?) {
            guard draw else { return }
            if selected {
                fill(r, rr, t.accent.withAlphaComponent(0.16)); stroke(r, rr, t.accent, 1.5)
            } else {
                fill(r, rr, act != nil && hover == act ? t.hover : t.field); stroke(r, rr, t.hair)
            }
        }
        func pill(_ r: NSRect, _ label: String, act: Act) {
            hot(r, act)
            guard draw else { return }
            fill(r, r.height / 2, hover == act ? t.hover : t.field); stroke(r, r.height / 2, t.hair)
            text(label, size: 13, weight: .semibold, color: t.text, in: NSRect(x: r.minX, y: r.midY - 8.5, width: r.width, height: 17), align: .center)
        }
        func section(_ title: String) {
            y += 16
            if draw { text(title, size: 13, weight: .semibold, color: t.textMuted, in: NSRect(x: m, y: y, width: w, height: 17)) }
            y += 25
        }
        func segmented(_ options: [(String, String)], current: String, rightEdge: CGFloat, midY: CGFloat, make: (String) -> Act) {
            let widths = options.map { width($0.1, size: 13, weight: .semibold) + 28 }
            let total = widths.reduce(0, +) + 6
            let outer = NSRect(x: rightEdge - total, y: midY - 17, width: total, height: 34)
            if draw { fill(outer, 17, t.field); stroke(outer, 17, t.hair) }
            var x = outer.minX + 3
            for (i, o) in options.enumerated() {
                let r = NSRect(x: x, y: outer.minY + 3, width: widths[i], height: 28)
                let act = make(o.0)
                hot(r, act)
                if draw {
                    let on = o.0 == current
                    if on { fill(r, 14, t.accent.withAlphaComponent(0.40)) } else if hover == act { fill(r, 14, t.hover) }
                    text(o.1, size: 13, weight: on ? .semibold : .regular, color: t.text, in: NSRect(x: r.minX, y: r.midY - 8.5, width: r.width, height: 17), align: .center)
                }
                x += widths[i]
            }
        }
        func line(_ title: String, _ detail: String? = nil, height h: CGFloat) -> NSRect {
            let r = NSRect(x: m, y: y, width: w, height: h)
            card(r, selected: false, act: nil)
            if draw {
                if let d = detail {
                    text(title, size: 14, color: t.text, in: NSRect(x: r.minX + 14, y: r.midY - 18, width: w - 90, height: 18))
                    text(d, size: 12.5, color: t.textMuted, in: NSRect(x: r.minX + 14, y: r.midY + 1, width: w - 90, height: 16))
                } else {
                    text(title, size: 14, color: t.text, in: NSRect(x: r.minX + 14, y: r.midY - 9, width: w - 90, height: 18))
                }
            }
            y += h + 8
            return r
        }

        // header
        if draw {
            NSApp.applicationIconImage.draw(in: NSRect(x: m - 2, y: y - 2, width: 40, height: 40), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            text("Edge Switch", size: 19, weight: .semibold, color: t.text, in: NSRect(x: m + 48, y: y + 6, width: 300, height: 24))
        }
        pill(NSRect(x: m + w - 76, y: y + 2, width: 76, height: 32), "Done", act: .done)
        y += 40

        // split
        section("Right-click at the left edge")
        let modes: [(String, String, String)] = [
            ("row", "Right-click an app in the list", "That app goes on the right half, beside the app you are using."),
            ("pick", "Right-click, then pick", "Right-click anywhere on the list, then choose the second app."),
            ("last", "Split with the last app", "The app you used just before goes on the right half. Right-click again to undo."),
        ]
        for (id, title, detail) in modes {
            let r = NSRect(x: m, y: y, width: w, height: 58)
            let on = p.mode == id
            hot(r, .mode(id))
            card(r, selected: on, act: .mode(id))
            if draw {
                let dot = NSRect(x: r.minX + 14, y: r.minY + 13, width: 16, height: 16)
                if on {
                    fill(dot, 8, t.accent); fill(dot.insetBy(dx: 5, dy: 5), 3, .white)
                } else {
                    stroke(dot, 8, t.textMuted, 1.5)
                }
                text(title, size: 14, weight: .semibold, color: t.text, in: NSRect(x: r.minX + 42, y: r.minY + 11, width: w - 56, height: 18))
                text(detail, size: 12.5, color: t.textMuted, in: NSRect(x: r.minX + 42, y: r.minY + 30, width: w - 56, height: 16))
            }
            y += 58 + 8
        }
        y -= 8

        // look
        section("Look")
        let cw = (w - 20) / 3
        let kinds = ThemeKind.allCases
        for (i, k) in kinds.enumerated() {
            let r = NSRect(x: m + CGFloat(i % 3) * (cw + 10), y: y + CGFloat(i / 3) * 124, width: cw, height: 116)
            let on = p.theme == k.rawValue
            hot(r, .theme(k.rawValue))
            card(r, selected: on, act: .theme(k.rawValue))
            if draw {
                let pv = NSRect(x: r.minX + 8, y: r.minY + 8, width: cw - 16, height: 56)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: pv, xRadius: 8, yRadius: 8).addClip()
                let colors: [NSColor]
                switch k {
                case .tahoe: colors = [NSColor(hex: "#3B7BD9"), NSColor(hex: "#0B1E4A")]
                case .slate: colors = [NSColor(hex: "#56606E"), NSColor(hex: "#14181D")]
                case .aurora: colors = [NSColor(hex: "#7C3AED"), NSColor(hex: "#12C9A0"), NSColor(hex: "#E0458C")]
                case .midnight: colors = [NSColor(hex: "#24408F"), NSColor(hex: "#060B1F")]
                case .vision: colors = [NSColor(hex: "#D5DDEC"), NSColor(hex: "#8794B0")]
                case .neon: colors = [NSColor(hex: "#161A22"), NSColor(hex: "#05070A")]
                }
                NSGradient(colors: colors)?.draw(in: pv, angle: -40)
                let glassFill = NSColor.white.withAlphaComponent(k == .slate ? 0.34 : 0.55)
                switch k {
                case .tahoe: fill(NSRect(x: pv.minX + 4, y: pv.minY + 4, width: pv.width * 0.26, height: pv.height - 8), 6, glassFill)
                case .slate: fill(NSRect(x: pv.minX, y: pv.minY, width: pv.width * 0.26, height: pv.height), 0, glassFill)
                case .aurora: fill(NSRect(x: pv.minX + 5, y: pv.minY + 12, width: pv.width * 0.24, height: pv.height - 24), 9, glassFill)
                case .midnight: fill(NSRect(x: pv.minX + 4, y: pv.minY + 4, width: pv.width * 0.26, height: pv.height - 8), 8, NSColor(hex: "#9DB6FF", alpha: 0.45))
                case .vision: fill(NSRect(x: pv.minX + 6, y: pv.minY + 10, width: pv.width * 0.25, height: pv.height - 20), 11, NSColor.white.withAlphaComponent(0.8))
                case .neon:
                    let pr = NSRect(x: pv.minX + 4, y: pv.minY + 4, width: pv.width * 0.26, height: pv.height - 8)
                    fill(pr, 5, NSColor.white.withAlphaComponent(0.10)); stroke(pr, 5, t.accent, 1.5)
                }
                NSGraphicsContext.restoreGraphicsState()
                text(k.title, size: 13.5, weight: .semibold, color: t.text, in: NSRect(x: r.minX + 10, y: r.minY + 72, width: cw - 20, height: 17))
                text(k.blurb, size: 12.5, color: t.textMuted, in: NSRect(x: r.minX + 10, y: r.minY + 91, width: cw - 20, height: 16))
            }
        }
        y += CGFloat((kinds.count + 2) / 3) * 124

        var r = line("Appearance", height: 48)
        segmented([("dark", "Dark"), ("light", "Light")], current: p.look, rightEdge: r.maxX - 8, midY: r.midY) { .look($0) }

        r = line("Accent color", height: 48)
        var sx = r.maxX - 14 - CGFloat(Accent.all.count) * 34 + 8
        for a in Accent.all {
            let c = NSRect(x: sx, y: r.midY - 13, width: 26, height: 26)
            hot(c.insetBy(dx: -4, dy: -4), .accent(a.hex))
            if draw {
                fill(c, 13, NSColor(hex: a.hex))
                if p.accent.caseInsensitiveCompare(a.hex) == .orderedSame { stroke(c.insetBy(dx: -4, dy: -4), 17, t.text, 2) }
                else if hover == .accent(a.hex) { stroke(c.insetBy(dx: -4, dy: -4), 17, t.textMuted, 1) }
            }
            sx += 34
        }

        r = line("App list", height: 48)
        segmented([("names", "Icons and names"), ("icons", "Icons only")], current: p.list, rightEdge: r.maxX - 8, midY: r.midY) { .list($0) }
        y -= 8

        // screen
        section("Screen")
        let toggles: [(String, String, String)] = [
            ("hideDock", "Hide the Dock", "Apps use the full height of the screen."),
            ("hideMenuBar", "Hide the menu bar", "It comes back when the cursor touches the top edge."),
            ("stageManagerOff", "Turn off Stage Manager", "No strip of app thumbnails at the side of the screen."),
            ("login", "Start at login", loginError ? "macOS did not allow this. Add Edge Switch under Login Items in System Settings."
                                                   : "Edge Switch opens when you sign in to this Mac."),
        ]
        func toggleLine(_ key: String, _ title: String, _ detail: String) {
            let lr = line(title, detail, height: 56)
            let sw = NSRect(x: lr.maxX - 14 - 46, y: lr.midY - 14, width: 46, height: 28)
            hot(lr, .toggle(key))
            guard draw else { return }
            let on = isOn(key)
            fill(sw, 14, on ? t.accent : t.hover)
            if !on { stroke(sw, 14, t.hair) }
            let knob = NSRect(x: on ? sw.maxX - 25 : sw.minX + 3, y: sw.minY + 3, width: 22, height: 22)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1); sh.set()
            fill(knob, 11, .white)
            NSGraphicsContext.restoreGraphicsState()
        }
        for (key, title, detail) in toggles { toggleLine(key, title, detail) }
        y -= 8

        // buttons beside Settings in the list
        section("Buttons beside Settings")
        toggleLine("showHome", "Home Assistant button", "Opens your lights and switches inside the list.")
        toggleLine("showShots", "Screenshot buttons", "Whole screen, or an area you drag. Saved and copied.")
        y -= 8

        // pinned apps
        section("Pinned apps")
        let pins = p.pinned
        if pins.isEmpty {
            _ = line("None yet", "Point at an app in the list and click the pin. Up to \(Prefs.maxPinned) apps.", height: 56)
        } else {
            for pin in pins {
                let lr = line(pin.name, height: 48)
                pill(NSRect(x: lr.maxX - 14 - 84, y: lr.midY - 15, width: 84, height: 30), "Remove", act: .unpin(pin.id))
            }
        }
        y -= 8

        // Home Assistant
        section("Home Assistant")
        for (key, title) in [("address", "Address"), ("token", "Access token")] {
            let lr = line(title, height: 48)
            let fr = NSRect(x: lr.minX + 128, y: lr.midY - 15, width: lr.width - 128 - 10, height: 30)
            fieldRects[key] = fr
            if draw { fill(fr, min(rr, 10), t.field); stroke(fr, min(rr, 10), t.hair) }
        }
        var haTitle = "Not connected", haDetail = "Make a long-lived access token in Home Assistant: your profile, then Security."
        if saveFailed { haDetail = "The token could not be saved in your Keychain." }
        else {
            switch HomeAssistant.shared.status {
            case .ok: haTitle = "Connected"; haDetail = "\(HomeAssistant.shared.entities.count) lights and switches found. The token is kept in your Keychain."
            case .loading: haTitle = "Checking"; haDetail = "Asking Home Assistant for your lights and switches."
            case .failed(let msg): haDetail = msg
            case .notSetUp: break
            }
        }
        let hr = NSRect(x: m, y: y, width: w, height: 72)
        card(hr, selected: false, act: nil)
        if draw {
            text(haTitle, size: 14, color: t.text, in: NSRect(x: hr.minX + 14, y: hr.minY + 10, width: w - 170, height: 18))
            let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byWordWrapping
            (haDetail as NSString).draw(with: NSRect(x: hr.minX + 14, y: hr.minY + 30, width: w - 170, height: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: t.textMuted, .paragraphStyle: ps])
        }
        pill(NSRect(x: hr.maxX - 14 - 126, y: hr.midY - 16, width: 126, height: 32), "Save and test", act: .homeSave)
        y += 72

        // window control + quit
        section("Window control")
        let trusted = WindowControl.trusted
        let fr = line(trusted ? "Allowed" : "Not allowed yet",
                      trusted ? "Edge Switch can resize and switch your apps." : "Switch on Edge Switch under Accessibility.", height: 56)
        if !trusted { pill(NSRect(x: fr.maxX - 14 - 150, y: fr.midY - 16, width: 150, height: 32), "Open Accessibility", act: .access) }
        y += 6
        pill(NSRect(x: m + w - 150, y: y, width: 150, height: 32), "Quit Edge Switch", act: .quit)
        y += 32 + 22

        res.height = y
        return res
    }

    override func draw(_ dirtyRect: NSRect) { _ = walk(draw: true) }

    // MARK: pointer

    private func act(at p: NSPoint) -> Act? { walk(draw: false).items.last { $0.0.contains(p) }?.1 }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    private func setHover(_ a: Act?) { if a != hover { hover = a; needsDisplay = true } }
    override func mouseMoved(with e: NSEvent) { setHover(act(at: convert(e.locationInWindow, from: nil))) }
    override func mouseExited(with e: NSEvent) { setHover(nil) }
    override func mouseDown(with e: NSEvent) { pressed = act(at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) {
        let a = act(at: convert(e.locationInWindow, from: nil))
        defer { pressed = nil }
        if let a, a == pressed { perform(a) }
    }
}

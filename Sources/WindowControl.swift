import AppKit
import ApplicationServices

// Window number of an Accessibility window. Private but long-standing call, used here only to keep the
// windows of an app in a stable order (oldest first) and to tell two windows apart.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One window of an app, as shown in the list.
struct WindowInfo {
    let element: AXUIElement
    let id: CGWindowID
    let title: String
    let minimized: Bool
    let isMain: Bool
}

// Moves and resizes other apps' windows through the macOS Accessibility API.
// All calls that talk to other apps run on `queue`, never on the main thread.
enum WindowControl {
    static let queue = DispatchQueue(label: "local.easter.edgeswitch.ax", qos: .userInitiated)

    enum Slot { case full, left, right }

    /// A screen in Accessibility coordinates (origin at the top-left of the primary display).
    struct Area { let frame: CGRect; let visible: CGRect }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: screens

    static func area(for s: NSScreen) -> Area {
        let h = NSScreen.screens.first?.frame.height ?? s.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return Area(frame: flip(s.frame), visible: flip(s.visibleFrame))
    }
    static func areas() -> [Area] { NSScreen.screens.map(area(for:)) }

    static func rect(_ slot: Slot, in v: CGRect) -> CGRect {
        let half = floor(v.width / 2)
        switch slot {
        case .full: return v
        case .left: return CGRect(x: v.minX, y: v.minY, width: half - 1, height: v.height)
        case .right: return CGRect(x: v.minX + half + 1, y: v.minY, width: v.width - half - 1, height: v.height)
        }
    }

    // MARK: reading

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        return app
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        (copy(appElement(pid), kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    static func isStandard(_ w: AXUIElement) -> Bool {
        (copy(w, kAXSubroleAttribute as String) as? String) == (kAXStandardWindowSubrole as String)
    }
    static func isMinimized(_ w: AXUIElement) -> Bool { (copy(w, kAXMinimizedAttribute as String) as? Bool) ?? false }
    static func isFullScreen(_ w: AXUIElement) -> Bool { (copy(w, "AXFullScreen") as? Bool) ?? false }

    static func frame(of w: AXUIElement) -> CGRect? {
        guard let p = copy(w, kAXPositionAttribute as String), let s = copy(w, kAXSizeAttribute as String),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func title(of pid: pid_t) -> String? {
        let app = appElement(pid)
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let w = copy(app, attr), CFGetTypeID(w) == AXUIElementGetTypeID(),
               let t = copy(w as! AXUIElement, kAXTitleAttribute as String) as? String, !t.isEmpty { return t }
        }
        return nil
    }

    static func windowID(_ w: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w, &id) == .success ? id : 0
    }

    static func mainWindow(of pid: pid_t) -> AXUIElement? {
        let app = appElement(pid)
        for attr in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
            if let w = copy(app, attr), CFGetTypeID(w) == AXUIElementGetTypeID() { return (w as! AXUIElement) }
        }
        return nil
    }

    /// The normal windows of an app (on the current desktop), oldest first.
    static func windowList(of pid: pid_t) -> [WindowInfo] {
        let mainID = mainWindow(of: pid).map(windowID) ?? 0
        let list = windows(of: pid).filter(isStandard).enumerated().map { (i, w) -> (Int, WindowInfo) in
            let id = windowID(w)
            let info = WindowInfo(element: w, id: id, title: (copy(w, kAXTitleAttribute as String) as? String) ?? "",
                                  minimized: isMinimized(w), isMain: id != 0 && id == mainID)
            return (i, info)
        }
        // Without window numbers, keep the order the app reports.
        return list.sorted { $0.1.id != 0 && $1.1.id != 0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }.map(\.1)
    }

    /// Brings one particular window to the front. Call on `queue`.
    static func focus(window w: AXUIElement, pid: pid_t) {
        guard trusted else { return }
        if isMinimized(w) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    /// Closes one window, as its red button would. Call on `queue`.
    static func close(window w: AXUIElement) {
        guard trusted else { return }
        if let b = copy(w, kAXCloseButtonAttribute as String), CFGetTypeID(b) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
    }

    // MARK: writing

    private static func setPosition(_ w: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }
    private static func setSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }
    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// Puts one window in `r`. A window that cannot grow that far is centred in `r` at the size it reached.
    /// Returns false when the window cannot be resized at all (it is then left alone).
    @discardableResult
    static func setFrame(_ w: AXUIElement, _ r: CGRect) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        if let cur = frame(of: w), near(cur, r) { return true }
        setPosition(w, r.origin)
        setSize(w, r.size)
        setPosition(w, r.origin)
        if let got = frame(of: w), !near(got, r) {
            setSize(w, r.size)   // some apps need a second pass after the move
            if let again = frame(of: w), again.width < r.width - 4 || again.height < r.height - 4 {
                setPosition(w, CGPoint(x: max(r.minX, r.midX - again.width / 2), y: max(r.minY, r.midY - again.height / 2)))
            }
        }
        return true
    }

    private static func withApp(_ pid: pid_t, _ body: () -> Void) {
        let app = appElement(pid)
        // Chrome and Electron apps animate resizes when this is on, which leaves windows half way.
        let enhanced = (copy(app, "AXEnhancedUserInterface") as? Bool) ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        body()
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    private static func placeOne(_ w: AXUIElement, slot: Slot, areas: [Area], forced: Area?) {
        guard !isMinimized(w) else { return }
        if isFullScreen(w) {
            // A window in macOS full screen already covers the display; leave it alone.
            // For a 50/50 split it has to come out of full screen first.
            if slot == .full { return }
            AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 1.1)
        }
        var area = forced ?? areas[0]
        if forced == nil, let f = frame(of: w) {
            let c = CGPoint(x: f.midX, y: f.midY)
            if let a = areas.first(where: { $0.frame.contains(c) }) { area = a }
        }
        setFrame(w, rect(slot, in: area.visible))
    }

    /// Lays out every normal window of an app. `on` forces a screen; otherwise each window stays on its own screen.
    /// Call on `queue`.
    static func place(pid: pid_t, slot: Slot, areas: [Area], on forced: Area? = nil) {
        guard trusted, !areas.isEmpty else { return }
        withApp(pid) {
            for w in windows(of: pid) where isStandard(w) { placeOne(w, slot: slot, areas: areas, forced: forced) }
        }
    }

    /// Lays out chosen windows only (two windows of one app side by side). Call on `queue`.
    static func place(pid: pid_t, windows list: [(AXUIElement, Slot)], areas: [Area], on forced: Area? = nil) {
        guard trusted, !areas.isEmpty else { return }
        withApp(pid) {
            for (w, slot) in list { placeOne(w, slot: slot, areas: areas, forced: forced) }
        }
    }

    /// Brings an app and its main window to the front. Call on `queue`.
    static func raise(pid: pid_t) {
        guard trusted else { return }
        let app = appElement(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w = copy(app, kAXMainWindowAttribute as String), CFGetTypeID(w) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(w as! AXUIElement, kAXRaiseAction as CFString)
        }
    }

    /// 0 = the app has no windows, 1 = all its windows are in the Dock (one is brought back), 2 = it has a window on screen.
    static func ensureWindow(pid: pid_t) -> Int {
        guard trusted else { return 2 }
        let ws = windows(of: pid).filter(isStandard)
        if ws.isEmpty { return 0 }
        if ws.allSatisfy(isMinimized), let first = ws.first {
            AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            return 1
        }
        return 2
    }
}

// Tells the app when another app opens a window or changes its front window.
final class WindowWatcher {
    private var observers: [pid_t: AXObserver] = [:]
    var onEvent: ((pid_t) -> Void)?
    static var current: WindowWatcher?

    private static let callback: AXObserverCallback = { _, element, _, _ in
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        DispatchQueue.main.async { WindowWatcher.current?.onEvent?(pid) }
    }

    func watch(_ pid: pid_t) {
        guard WindowControl.trusted, observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, WindowWatcher.callback, &obs) == .success, let o = obs else { return }
        let app = WindowControl.appElement(pid)
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(o, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observers[pid] = o
    }

    func unwatch(_ pid: pid_t) {
        guard let o = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }
}

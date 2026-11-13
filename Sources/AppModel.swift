import AppKit

struct AppEntry {
    let pid: pid_t
    let name: String
    let icon: NSImage
    let hidden: Bool
    let bundleID: String?
}

/// One side of a 50/50 split: an app, and optionally one particular window of it.
struct Target {
    let pid: pid_t
    var window: AXUIElement?
    var windowID: CGWindowID = 0
}

// Which apps and windows are open, which one is in use, and whether two share the screen.
final class AppModel {
    static let shared = AppModel()

    private(set) var apps: [AppEntry] = []
    private(set) var current: pid_t?                      // the app in use; never Edge Switch itself
    private(set) var split: (left: Target, right: Target)?
    private(set) var windows: [pid_t: [WindowInfo]] = [:] // normal windows of each app, oldest first
    private var mru: [pid_t] = []                         // most recently used first
    var picking = false { didSet { if picking != oldValue { changed() } } }

    private let watcher = WindowWatcher()
    private var pending: [pid_t: DispatchWorkItem] = [:]
    private var windowReload: DispatchWorkItem?
    private var trustTimer: Timer?
    private var splitOn: NSScreen?
    private let me = ProcessInfo.processInfo.processIdentifier

    private func changed() { NotificationCenter.default.post(name: .modelChanged, object: nil) }

    // MARK: start

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivate(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didHideOrShow(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didHideOrShow(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        WindowWatcher.current = watcher
        watcher.onEvent = { [weak self] pid in self?.windowEvent(pid) }

        refresh()
        if let f = NSWorkspace.shared.frontmostApplication, isManaged(f) { current = f.processIdentifier }
        mru = (current.map { [$0] } ?? []) + apps.map(\.pid).filter { $0 != current }

        if WindowControl.trusted { becameTrusted() } else {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if WindowControl.trusted { t.invalidate(); self?.becameTrusted() }
            }
        }
    }

    private func becameTrusted() {
        apps.forEach { watcher.watch($0.pid) }
        if let c = current { layout(c) }
        loadWindows()
        changed()
    }

    // MARK: app list

    func isManaged(_ a: NSRunningApplication) -> Bool {
        a.activationPolicy == .regular && a.processIdentifier != me && !a.isTerminated
            && !(a.bundleIdentifier.map { Prefs.shared.excluded.contains($0) } ?? false)
    }

    private func running(_ pid: pid_t) -> NSRunningApplication? {
        guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return nil }
        return a
    }

    func refresh() {
        let list = NSWorkspace.shared.runningApplications.filter(isManaged)
            // Launch order, like the Windows taskbar. Finder has no launch date and goes first.
            .sorted { ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier) }
        apps = list.map {
            AppEntry(pid: $0.processIdentifier, name: $0.localizedName ?? "App",
                     icon: $0.icon ?? NSWorkspace.shared.icon(for: .application), hidden: $0.isHidden, bundleID: $0.bundleIdentifier)
        }
        changed()
    }

    func name(_ pid: pid_t?) -> String { apps.first { $0.pid == pid }?.name ?? "this app" }

    /// The windows listed under an app. Only apps with two or more windows get window rows.
    func listedWindows(of pid: pid_t) -> [WindowInfo] {
        let w = windows[pid] ?? []
        return w.count >= 2 ? w : []
    }

    /// "on", "left", "right", "both" or "" for the row of an app.
    func state(of pid: pid_t) -> String {
        if let s = split {
            if s.left.pid == pid && s.right.pid == pid { return "both" }
            return s.left.pid == pid ? "left" : s.right.pid == pid ? "right" : ""
        }
        return current == pid ? "on" : ""
    }

    /// "on", "left", "right" or "" for the row of one window.
    func state(of w: WindowInfo, pid: pid_t) -> String {
        if let s = split {
            if s.left.pid == pid, s.left.windowID != 0, s.left.windowID == w.id { return "left" }
            if s.right.pid == pid, s.right.windowID != 0, s.right.windowID == w.id { return "right" }
            return ""
        }
        return current == pid && w.isMain ? "on" : ""
    }

    func subtitle(for e: AppEntry) -> String {
        if picking { return e.pid == current ? "Stays on the left" : "Put beside \(name(current))" }
        if e.hidden { return "Minimized" }
        switch state(of: e.pid) {
        case "left": return "Left half"
        case "right": return "Right half"
        case "both": return "Both halves"
        default:
            let w = windows[e.pid] ?? []
            if w.count >= 2 { return "\(w.count) windows" }
            let t = w.first.map { AppModel.shortTitle($0.title, app: e.name) } ?? ""
            return t == e.name ? "" : t      // a window titled like its app adds nothing
        }
    }

    /// "Page - Google Chrome - Work" becomes "Work: Page"; "Page - Safari" becomes "Page".
    static func shortTitle(_ title: String, app: String) -> String {
        for sep in [" - ", " – ", " — "] {
            if let r = title.range(of: sep + app + sep, options: .backwards) {
                let page = String(title[..<r.lowerBound]), profile = String(title[r.upperBound...])
                return profile.isEmpty ? page : "\(profile): \(page)"
            }
            if title.hasSuffix(sep + app) { return String(title.dropLast((sep + app).count)) }
        }
        return title.isEmpty ? "Untitled window" : title
    }

    /// Reads every app's windows, off the main thread.
    func loadWindows() {
        guard WindowControl.trusted else { return }
        let pids = apps.map(\.pid)
        WindowControl.queue.async {
            var all: [pid_t: [WindowInfo]] = [:]
            for p in pids { all[p] = WindowControl.windowList(of: p) }
            DispatchQueue.main.async { self.windows = all; self.changed() }
        }
    }

    private func loadWindowsSoon(_ delay: TimeInterval = 0.45) {
        windowReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.loadWindows() }
        windowReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: workspace events

    @objc private func didActivate(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, isManaged(a) else { return }
        let pid = a.processIdentifier
        current = pid
        mru.removeAll { $0 == pid }; mru.insert(pid, at: 0)
        if let s = split {
            if s.left.pid != pid && s.right.pid != pid { split = nil } else { current = s.left.pid }
        }
        watcher.watch(pid)
        layout(pid)
        // Windows that appear a moment after the app comes forward (launch, reopen) are caught here.
        for delay in [0.35, 1.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.layout(pid) } }
        refresh()
    }

    @objc private func didLaunch(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = a.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let app = self.running(pid), self.isManaged(app) else { return }
            self.watcher.watch(pid); self.layout(pid); self.refresh()
        }
        refresh()
    }

    @objc private func didTerminate(_ n: Notification) {
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = a.processIdentifier
        watcher.unwatch(pid)
        mru.removeAll { $0 == pid }
        windows[pid] = nil
        leaveSplit(ifInvolves: pid)
        if current == pid { current = nil }
        refresh()
    }

    @objc private func didHideOrShow(_ n: Notification) {
        if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.isHidden {
            leaveSplit(ifInvolves: a.processIdentifier)
        }
        refresh()
    }

    @objc private func screensChanged() {
        // The usable screen area changed (Dock or menu bar hidden, display plugged in): lay out again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if let s = self.split { self.layout(s.left.pid); self.layout(s.right.pid) } else if let c = self.current { self.layout(c) }
        }
    }

    private func leaveSplit(ifInvolves pid: pid_t) {
        guard let s = split, s.left.pid == pid || s.right.pid == pid else { return }
        let other = s.left.pid == pid ? s.right.pid : s.left.pid
        split = nil
        guard other != pid else { return }
        current = other
        layout(other)
    }

    private func windowEvent(_ pid: pid_t) {
        pending[pid]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.pending[pid] = nil; self?.layout(pid) }
        pending[pid] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
        if PanelController.shared.isOpen { loadWindowsSoon() }
    }

    // MARK: layout

    func layout(_ pid: pid_t) {
        guard WindowControl.trusted, pid != me, let app = running(pid), isManaged(app) else { return }
        let areas = WindowControl.areas()
        let splitArea = (splitOn ?? NSScreen.main).map(WindowControl.area(for:))

        // Two windows of the same app side by side: only those two are moved.
        if let s = split, s.left.pid == pid, s.right.pid == pid, let lw = s.left.window, let rw = s.right.window {
            WindowControl.queue.async {
                WindowControl.place(pid: pid, windows: [(lw, .left), (rw, .right)], areas: areas, on: splitArea)
            }
            return
        }
        var slot = WindowControl.Slot.full
        if let s = split { slot = s.left.pid == pid ? .left : s.right.pid == pid ? .right : .full }
        if slot == .full && !Prefs.shared.fillOnOpen { return }
        let forced = slot == .full ? nil : splitArea
        WindowControl.queue.async { WindowControl.place(pid: pid, slot: slot, areas: areas, on: forced) }
    }

    // MARK: actions

    private func bringForward(_ pid: pid_t, window: AXUIElement? = nil, verify: Bool) {
        guard let app = running(pid) else { return }
        if app.isHidden { app.unhide() }
        app.activate(options: window == nil ? [.activateAllWindows] : [])
        WindowControl.queue.async {
            if let w = window { WindowControl.focus(window: w, pid: pid) } else { WindowControl.raise(pid: pid) }
            let state = window == nil ? WindowControl.ensureWindow(pid: pid) : 2
            guard verify else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                // No window at all, or macOS did not bring it forward: ask the app to open, as a Dock click would.
                if (state == 0 || front != pid), let url = app.bundleURL {
                    let c = NSWorkspace.OpenConfiguration()
                    c.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: c, completionHandler: nil)
                }
            }
        }
    }

    /// One app fills the screen. With `window`, that window of the app comes to the front.
    func show(_ pid: pid_t, window: WindowInfo? = nil) {
        split = nil
        picking = false
        layout(pid)
        bringForward(pid, window: window?.element, verify: true)
        if window != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.layout(pid) } }
        changed()
    }

    /// The next window of an app comes to the front (used by the icons-only list).
    func showNextWindow(of pid: pid_t) {
        let w = windows[pid] ?? []
        guard w.count >= 2 else { show(pid); return }
        let i = w.firstIndex { $0.isMain } ?? -1
        show(pid, window: w[(i + 1) % w.count])
        loadWindowsSoon()
    }

    /// `left` and `right` share the screen 50/50; `left` keeps the keyboard.
    func splitScreen(left: Target, right: Target, on screen: NSScreen?) {
        guard running(left.pid) != nil, running(right.pid) != nil else { return }
        if left.pid == right.pid {
            guard left.window != nil, right.window != nil, left.windowID != right.windowID else { return }
        }
        split = (left, right)
        splitOn = screen
        picking = false
        current = left.pid
        running(left.pid)?.unhide(); running(right.pid)?.unhide()
        layout(right.pid); if left.pid != right.pid { layout(left.pid) }
        bringForward(right.pid, window: right.window, verify: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.bringForward(left.pid, window: left.window, verify: true)
            for d in [0.3, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    self?.layout(right.pid); if left.pid != right.pid { self?.layout(left.pid) }
                }
            }
        }
        changed()
    }

    /// Puts an app (or one window) on the right half, beside what is in use now. Returns false when that makes no sense.
    @discardableResult
    func splitWith(_ pid: pid_t, window: WindowInfo?, on screen: NSScreen?) -> Bool {
        guard let cur = current, running(cur) != nil else { return false }
        if pid == cur {
            // Same app: its front window stays on the left, the chosen window goes on the right.
            guard let w = window, let main = (windows[cur] ?? []).first(where: { $0.isMain }), main.id != w.id, main.id != 0, w.id != 0 else { return false }
            splitScreen(left: Target(pid: cur, window: main.element, windowID: main.id),
                        right: Target(pid: cur, window: w.element, windowID: w.id), on: screen)
        } else {
            splitScreen(left: Target(pid: cur), right: Target(pid: pid, window: window?.element, windowID: window?.id ?? 0), on: screen)
        }
        return true
    }

    /// Windows-style minimize: the whole app leaves the screen and stays in the list.
    func minimize(_ pid: pid_t) {
        leaveSplit(ifInvolves: pid)
        running(pid)?.hide()
        if current == pid { current = mru.first { $0 != pid && !(running($0)?.isHidden ?? true) } }
        refresh()
    }

    /// Quits an app, as Cmd-Q would. The app itself asks about unsaved work.
    func quit(_ pid: pid_t) {
        leaveSplit(ifInvolves: pid)
        running(pid)?.terminate()
    }

    /// Closes one window of an app.
    func close(window w: WindowInfo, of pid: pid_t) {
        if let s = split, (s.left.pid == pid && s.left.windowID == w.id) || (s.right.pid == pid && s.right.windowID == w.id) {
            leaveSplit(ifInvolves: pid)
            if split != nil { split = nil }
        }
        WindowControl.queue.async { WindowControl.close(window: w.element) }
        loadWindowsSoon(0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.layout(pid) }
    }

    /// A right-click in the list. Returns true when the list should close.
    func rightClick(on pid: pid_t?, window: WindowInfo?, screen: NSScreen?) -> Bool {
        guard let cur = current, running(cur) != nil else {
            if let pid { show(pid, window: window); return true }
            return false
        }
        switch Prefs.shared.mode {
        case "row":
            guard let pid else { return false }
            return splitWith(pid, window: window, on: screen)
        case "pick":
            picking = true
            return false
        default:
            if split != nil { show(cur); return true }
            guard let other = mru.first(where: { $0 != cur && self.running($0) != nil && !(self.running($0)?.isHidden ?? true) }) else { return false }
            splitScreen(left: Target(pid: cur), right: Target(pid: other), on: screen)
            return true
        }
    }
}

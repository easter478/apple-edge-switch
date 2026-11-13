import AppKit

// The three macOS settings this app changes for the user: Dock auto-hide, menu bar auto-hide, Stage Manager.
// The value found before the first change is remembered, and put back when the option is switched off.
enum SystemTweaks {
    // MARK: Dock

    static var dockHidden: Bool {
        get { (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false }
        set {
            CFPreferencesSetAppValue("autohide" as CFString, newValue as CFBoolean, "com.apple.dock" as CFString)
            CFPreferencesAppSynchronize("com.apple.dock" as CFString)
            // The Dock reads this setting only when it starts, so restart it (takes about a second).
            run("/usr/bin/killall", ["Dock"])
        }
    }

    // MARK: menu bar

    private static func global(_ key: String) -> Bool? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }
    private static func setGlobal(_ key: String, _ value: Bool?) {
        CFPreferencesSetValue(key as CFString, value.map { $0 as CFBoolean }, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static var menuBarHidden: Bool {
        get { global("_HIHideMenuBar") ?? false }
        set {
            setGlobal("_HIHideMenuBar", newValue)
            setGlobal("AppleMenuBarVisibleInFullscreen", !newValue)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    // MARK: Stage Manager

    static var stageManagerOn: Bool {
        get { (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false }
        set {
            CFPreferencesSetAppValue("GloballyEnabled" as CFString, newValue as CFBoolean, "com.apple.WindowManager" as CFString)
            CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        }
    }

    // MARK: apply

    private static func sync(option on: Bool, key: String, wanted: Bool, read: () -> Bool, write: (Bool) -> Void) {
        let d = UserDefaults.standard
        if on {
            Prefs.shared.rememberOriginal(key, read())
            if read() != wanted { write(wanted) }
        } else if let o = Prefs.shared.original(key) as? Bool {
            if read() != o { write(o) }
            d.removeObject(forKey: "orig." + key)
        }
    }

    /// Makes the Mac match the three switches in Settings.
    static func apply() {
        let p = Prefs.shared
        sync(option: p.hideDock, key: "dock", wanted: true, read: { dockHidden }, write: { dockHidden = $0 })
        sync(option: p.hideMenuBar, key: "menubar", wanted: true, read: { menuBarHidden }, write: { menuBarHidden = $0 })
        sync(option: p.stageManagerOff, key: "stage", wanted: false, read: { stageManagerOn }, write: { stageManagerOn = $0 })
    }

    static func status() -> String {
        "dockHidden=\(dockHidden) menuBarHidden=\(menuBarHidden) stageManagerOn=\(stageManagerOn)"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: path)
        t.arguments = args
        do { try t.run(); t.waitUntilExit(); return t.terminationStatus } catch { return -1 }
    }
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // Only one copy runs at a time.
        if let id = Bundle.main.bundleIdentifier {
            for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) where a != NSRunningApplication.current { a.terminate() }
        }
        SystemTweaks.apply()
        AppModel.shared.start()
        PanelController.shared.start()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { note in
            if let k = note.object as? String, ["hideDock", "hideMenuBar", "stageManagerOff"].contains(k) { SystemTweaks.apply() }
        }
        if !WindowControl.trusted { WindowControl.askForAccess() }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            SettingsWindow.shared.show()
        }
    }

    // Opening the app again while it runs shows Settings (there is no Dock or menu bar icon).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--make-icon"), args.count > i + 1 {
    IconMaker.write(to: args[i + 1]); exit(0)
}
if let i = args.firstIndex(of: "--cli") {
    exit(CLI.run(Array(args[(i + 1)...])))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 {
    // --snapshot panel|panel-pick|panel-locked|settings <file.png> [theme look list]
    // "demo" anywhere after the file name: sample apps, windows, pins and Home Assistant data.
    let demo = args.contains("demo")
    let extra = Array(args[(i + 3)...]).filter { $0 != "demo" }
    let d = UserDefaults.standard
    // Snapshots must not change saved settings: use a throwaway layer.
    var layer: [String: Any] = [:]
    if extra.count > 0 { layer["theme"] = extra[0] }
    if extra.count > 1 { layer["look"] = extra[1] }
    if extra.count > 2 { layer["list"] = extra[2] }
    if extra.count > 3 { layer["accent"] = extra[3] }
    if demo {
        layer["haURL"] = "http://homeassistant.local:8123"
        layer["showHome"] = true; layer["showShots"] = true
        layer["pinned"] = [
            ["id": "com.apple.Safari", "path": "/Applications/Safari.app", "name": "Safari"],
            ["id": "com.apple.mail", "path": "/System/Applications/Mail.app", "name": "Mail"],
            ["id": "com.apple.Notes", "path": "/System/Applications/Notes.app", "name": "Notes"],
            ["id": "com.apple.iCal", "path": "/System/Applications/Calendar.app", "name": "Calendar"],
        ]
    }
    d.setVolatileDomain(layer, forName: UserDefaults.argumentDomain)
    switch args[i + 1] {
    case "settings": Snapshot.settings(to: args[i + 2])
    case "panel-pick": Snapshot.panel(to: args[i + 2], picking: true, trusted: true)
    case "panel-locked": Snapshot.panel(to: args[i + 2], picking: false, trusted: false)
    case "panel-home": Snapshot.panel(to: args[i + 2], picking: false, trusted: true, home: true)
    default: Snapshot.panel(to: args[i + 2], picking: false, trusted: true)
    }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()

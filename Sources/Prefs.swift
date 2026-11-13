import AppKit

extension Notification.Name {
    static let homeChanged = Notification.Name("EdgeSwitchHomeChanged")
    static let prefsChanged = Notification.Name("EdgeSwitchPrefsChanged")
    static let modelChanged = Notification.Name("EdgeSwitchModelChanged")
}

struct PinnedApp: Equatable {
    let id: String      // bundle id
    let path: String    // where the app is
    let name: String
    init(id: String, path: String, name: String) { self.id = id; self.path = path; self.name = name }
    init?(_ d: [String: String]) {
        guard let id = d["id"], let path = d["path"], let name = d["name"] else { return nil }
        self.init(id: id, path: path, name: name)
    }
    var dictionary: [String: String] { ["id": id, "path": path, "name": name] }
}

// Settings, saved in the app's own preferences (domain local.easter.edgeswitch).
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "mode": "row", "theme": "tahoe", "look": "dark", "accent": "#0A84FF", "list": "names",
            "hideDock": true, "hideMenuBar": true, "stageManagerOff": true, "fillOnOpen": true,
            "showHome": true, "showShots": true,
        ])
    }

    private func str(_ k: String) -> String { d.string(forKey: k) ?? "" }
    private func set(_ v: Any, _ k: String) {
        d.set(v, forKey: k)
        NotificationCenter.default.post(name: .prefsChanged, object: k)
    }

    /// "row" = right-click an app in the list; "pick" = right-click then pick; "last" = split with the last app
    var mode: String { get { str("mode") } set { set(newValue, "mode") } }
    var theme: String { get { str("theme") } set { set(newValue, "theme") } }
    var look: String { get { str("look") } set { set(newValue, "look") } }
    var accent: String { get { str("accent") } set { set(newValue, "accent") } }
    /// "names" or "icons"
    var list: String { get { str("list") } set { set(newValue, "list") } }
    var hideDock: Bool { get { d.bool(forKey: "hideDock") } set { set(newValue, "hideDock") } }
    var hideMenuBar: Bool { get { d.bool(forKey: "hideMenuBar") } set { set(newValue, "hideMenuBar") } }
    var stageManagerOff: Bool { get { d.bool(forKey: "stageManagerOff") } set { set(newValue, "stageManagerOff") } }
    var fillOnOpen: Bool { get { d.bool(forKey: "fillOnOpen") } set { set(newValue, "fillOnOpen") } }
    /// Whether the Home Assistant button and the two screenshot buttons appear beside Settings in the list.
    var showHome: Bool { get { d.bool(forKey: "showHome") } set { set(newValue, "showHome") } }
    var showShots: Bool { get { d.bool(forKey: "showShots") } set { set(newValue, "showShots") } }

    /// Home Assistant address, such as http://homeassistant.local:8123. The access token is in the Keychain, never here.
    var haURL: String { get { str("haURL") } set { set(newValue, "haURL") } }

    /// Apps kept at the bottom of the list whether or not they are running (at most `maxPinned`).
    static let maxPinned = 5
    var pinned: [PinnedApp] {
        get { (d.array(forKey: "pinned") as? [[String: String]] ?? []).compactMap(PinnedApp.init) }
        set { set(newValue.map(\.dictionary), "pinned") }
    }

    /// Apps that are never resized (bundle ids). No screen for this yet; edit with `defaults write`.
    var excluded: [String] { d.stringArray(forKey: "excluded") ?? [] }

    // What the Mac was set to before this app changed it, so switching an option off puts it back.
    func original(_ k: String) -> Any? { d.object(forKey: "orig." + k) }
    func rememberOriginal(_ k: String, _ v: Any) { if d.object(forKey: "orig." + k) == nil { d.set(v, forKey: "orig." + k) } }
}

/// Debug lines on stderr, only when the app is started with EDGESWITCH_DEBUG=1.
let debugLogging = ProcessInfo.processInfo.environment["EDGESWITCH_DEBUG"] != nil
func dlog(_ s: @autoclosure () -> String) {
    if debugLogging { FileHandle.standardError.write((String(format: "%.2f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + s() + "\n").data(using: .utf8)!) }
}

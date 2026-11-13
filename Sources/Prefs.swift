import AppKit

extension Notification.Name {
    static let prefsChanged = Notification.Name("EdgeSwitchPrefsChanged")
    static let modelChanged = Notification.Name("EdgeSwitchModelChanged")
}

// Settings, saved in the app's own preferences (domain local.easter.edgeswitch).
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "mode": "row", "theme": "tahoe", "look": "dark", "accent": "#0A84FF", "list": "names",
            "hideDock": true, "hideMenuBar": true, "stageManagerOff": true, "fillOnOpen": true,
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
    /// Apps that are never resized (bundle ids). No screen for this yet; edit with `defaults write`.
    var excluded: [String] { d.stringArray(forKey: "excluded") ?? [] }

    // What the Mac was set to before this app changed it, so switching an option off puts it back.
    func original(_ k: String) -> Any? { d.object(forKey: "orig." + k) }
    func rememberOriginal(_ k: String, _ v: Any) { if d.object(forKey: "orig." + k) == nil { d.set(v, forKey: "orig." + k) } }
}

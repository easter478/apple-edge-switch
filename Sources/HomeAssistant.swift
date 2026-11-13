import AppKit
import Security

// The Home Assistant access token lives in the macOS Keychain. It is never written to preferences, files or logs.
enum Secrets {
    private static let service = "local.easter.edgeswitch"
    private static let account = "home-assistant-token"
    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }

    static func saveToken(_ token: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func loadToken() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static var hasToken: Bool {
        var q = base
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true     // attributes only: does not read the secret
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() { SecItemDelete(base as CFDictionary) }
}

struct HAEntity: Equatable {
    let id: String          // light.kitchen
    let name: String
    var state: String       // on, off, unavailable
    var domain: String { String(id.prefix { $0 != "." }) }
    var isOn: Bool { state == "on" }
    var available: Bool { state == "on" || state == "off" }
}

// Lights and switches from Home Assistant, over its REST API.
final class HomeAssistant {
    static let shared = HomeAssistant()

    enum Status: Equatable { case notSetUp, loading, ok, failed(String) }

    private(set) var entities: [HAEntity] = []
    private(set) var status: Status = .notSetUp
    private var token: String?
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()
    // Test hooks: a stand-in server can be given on the command line environment. Never used in normal running.
    private let env = ProcessInfo.processInfo.environment

    private var base: URL? {
        let raw = env["EDGESWITCH_HA_URL"] ?? Prefs.shared.haURL
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(string: s.hasSuffix("/") ? String(s.dropLast()) : s)
    }

    var isSetUp: Bool { base != nil && (env["EDGESWITCH_HA_TOKEN"] != nil || Secrets.hasToken) }

    private func changed() { NotificationCenter.default.post(name: .homeChanged, object: nil) }

    /// Forget the cached token (after the user saves a new one).
    func credentialsChanged() { token = nil; entities = []; status = isSetUp ? .loading : .notSetUp; changed() }

    private func request(_ path: String, body: [String: Any]? = nil) -> URLRequest? {
        guard let base, let url = URL(string: base.absoluteString + path) else { return nil }
        if token == nil { token = env["EDGESWITCH_HA_TOKEN"] ?? Secrets.loadToken() }
        guard let token else { return nil }
        var r = URLRequest(url: url)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func message(for error: Error?, code: Int?) -> String {
        if code == 401 || code == 403 { return "Home Assistant refused the access token. Paste a new one in Settings." }
        if let code, code >= 400 { return "Home Assistant answered with error \(code)." }
        let host = base?.host ?? "that address"
        return "Can't reach Home Assistant at \(host). Check the address in Settings and that this Mac is on the same network."
    }

    func refresh() {
        guard isSetUp, let req = request("/api/states") else { status = .notSetUp; changed(); return }
        if entities.isEmpty { status = .loading; changed() }
        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode
            var list: [HAEntity]?
            if code == 200, let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                list = arr.compactMap { o in
                    guard let id = o["entity_id"] as? String, id.hasPrefix("light.") || id.hasPrefix("switch."),
                          let state = o["state"] as? String else { return nil }
                    let name = (o["attributes"] as? [String: Any])?["friendly_name"] as? String
                    return HAEntity(id: id, name: name ?? id, state: state)
                }.sorted { ($0.domain, $0.name.lowercased()) < ($1.domain, $1.name.lowercased()) }
            }
            DispatchQueue.main.async {
                if let list { self.entities = list; self.status = .ok } else { self.status = .failed(self.message(for: err, code: code)) }
                self.changed()
            }
        }.resume()
    }

    func toggle(_ e: HAEntity) {
        guard e.available, let req = request("/api/services/\(e.domain)/toggle", body: ["entity_id": e.id]) else { return }
        // Show the new state at once; the next refresh confirms it.
        if let i = entities.firstIndex(where: { $0.id == e.id }) { entities[i].state = e.isOn ? "off" : "on"; changed() }
        session.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async {
                guard let self else { return }
                if code != 200 { self.status = .failed(self.message(for: err, code: code)); self.changed() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
            }
        }.resume()
    }

    /// Keep the list fresh while the controls are on screen.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopWatching() { timer?.invalidate(); timer = nil }
}

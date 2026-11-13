import AppKit

// Screenshots through macOS's own screencapture tool: the whole screen, or an area the user drags out.
// The picture is saved in Pictures/Screenshots (or wherever macOS has been told to save screenshots) and also
// copied to the clipboard. The Desktop is not used by default: macOS asks for a separate permission to write there.
enum Screenshots {
    static func folder() -> URL {
        if let custom = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            let path = (custom as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: path) }
        }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func take(selection: Bool) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder().appendingPathComponent("Screenshot \(f.string(from: Date())).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = selection ? ["-i", "-s", url.path] : [url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                // Esc during a selection leaves no file; then there is nothing to copy.
                guard let img = NSImage(contentsOf: url) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        }
        try? p.run()
    }
}

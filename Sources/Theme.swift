import AppKit

// One central theme. Views read tokens from here and never hard-code colours or sizes.
// Source of truth for the values: THEME.md (Tahoe Glass) and mockups/edge-switch.html.

enum ThemeKind: String, CaseIterable {
    case tahoe, slate, aurora
    var title: String {
        switch self {
        case .tahoe: return "Tahoe Glass"
        case .slate: return "Slate Rail"
        case .aurora: return "Aurora Capsule"
        }
    }
    var blurb: String {
        switch self {
        case .tahoe: return "Floating frosted panel"
        case .slate: return "Flat rail on the edge"
        case .aurora: return "Small glowing capsule"
        }
    }
}

enum Look: String { case dark, light }

struct Accent {
    let name: String
    let hex: String
    static let all: [Accent] = [
        Accent(name: "Blue", hex: "#0A84FF"),
        Accent(name: "Purple", hex: "#8E5CF6"),
        Accent(name: "Pink", hex: "#F2478B"),
        Accent(name: "Orange", hex: "#F08A24"),
        Accent(name: "Green", hex: "#2FB65A"),
        Accent(name: "Graphite", hex: "#8A8F98"),
    ]
}

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

struct Theme {
    let kind: ThemeKind
    let look: Look
    let accent: NSColor

    // colour tokens
    let text: NSColor
    let textMuted: NSColor
    let tint: NSColor          // laid over the system frosting
    let rim: NSColor
    let sheen: NSColor         // top of the sheen gradient, fades to clear
    let hair: NSColor
    let field: NSColor
    let hover: NSColor
    let rowOn: NSColor
    let rowOnEnd: NSColor?     // set = gradient fill (Aurora)
    let showsBar: Bool         // accent bar on the row in use (Slate)
    let shadow: NSColor

    // shape tokens
    let inset: CGFloat
    let radius: CGFloat
    let rowRadius: CGFloat
    let sheetRadius: CGFloat
    let fullHeight: Bool
    let edgeAttached: Bool

    // fixed sizes
    static let widthNames: CGFloat = 256
    static let widthIcons: CGFloat = 72
    static let pad: CGFloat = 10
    static let rowHeight: CGFloat = 52
    static let rowGap: CGFloat = 3
    static let windowRowHeight: CGFloat = 30   // a single window listed under its app
    static let windowIndent: CGFloat = 46
    static let groupHeaderHeight: CGFloat = 20 // a profile name above that profile's windows
    static let buttonSize: CGFloat = 28        // close and minimize buttons on a row
    static let icon: CGFloat = 36
    static let footer: CGFloat = 44
    static let slideIn: TimeInterval = 0.21
    static let slideOut: TimeInterval = 0.14

    var isDark: Bool { look == .dark }
    /// Text drawn on a fill made of the text colour (the window-count badge).
    var inverseText: NSColor { isDark ? NSColor(hex: "#14161A") : NSColor(hex: "#F5F6F8") }
    var material: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .vibrantDark : .vibrantLight) }

    static func nameFont(_ size: CGFloat = 14) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    static func subFont(_ size: CGFloat = 12) -> NSFont { .systemFont(ofSize: size, weight: .regular) }

    static func make(kind: ThemeKind, look: Look, accentHex: String) -> Theme {
        let accent = NSColor(hex: accentHex)
        let dark = look == .dark
        let text = dark ? NSColor(hex: "#F5F6F8") : NSColor(hex: "#14161A")
        let muted = text.withAlphaComponent(dark ? 0.76 : 0.72)
        let hair = dark ? NSColor.rgba(255, 255, 255, 0.14) : NSColor.rgba(0, 0, 0, 0.11)
        let field = dark ? NSColor.rgba(255, 255, 255, 0.07) : NSColor.rgba(0, 0, 0, 0.05)
        let hover = dark ? NSColor.rgba(255, 255, 255, 0.10) : NSColor.rgba(0, 0, 0, 0.07)

        switch kind {
        case .tahoe:
            return Theme(kind: kind, look: look, accent: accent, text: text, textMuted: muted,
                         tint: dark ? .rgba(24, 26, 32, 0.46) : .rgba(246, 247, 250, 0.46),
                         rim: dark ? .rgba(255, 255, 255, 0.20) : .rgba(255, 255, 255, 0.75),
                         sheen: dark ? .rgba(255, 255, 255, 0.13) : .rgba(255, 255, 255, 0.55),
                         hair: hair, field: field, hover: hover,
                         rowOn: accent.withAlphaComponent(dark ? 0.36 : 0.26), rowOnEnd: nil, showsBar: false,
                         shadow: dark ? .rgba(0, 0, 0, 0.42) : .rgba(20, 30, 60, 0.26),
                         inset: 10, radius: 22, rowRadius: 14, sheetRadius: 24, fullHeight: true, edgeAttached: false)
        case .slate:
            return Theme(kind: kind, look: look, accent: accent, text: text, textMuted: muted,
                         tint: dark ? .rgba(30, 33, 38, 0.66) : .rgba(238, 240, 243, 0.66),
                         rim: dark ? .rgba(255, 255, 255, 0.10) : .rgba(0, 0, 0, 0.10),
                         sheen: .clear,
                         hair: hair, field: field, hover: hover,
                         rowOn: dark ? .rgba(255, 255, 255, 0.10) : .rgba(0, 0, 0, 0.08), rowOnEnd: nil, showsBar: true,
                         shadow: dark ? .rgba(0, 0, 0, 0.35) : .rgba(30, 40, 60, 0.20),
                         inset: 0, radius: 0, rowRadius: 6, sheetRadius: 10, fullHeight: true, edgeAttached: true)
        case .aurora:
            let mint = NSColor.rgba(47, 227, 196, 1)
            let end = (accent.blended(withFraction: 0.6, of: mint) ?? accent).withAlphaComponent(dark ? 0.34 : 0.24)
            return Theme(kind: kind, look: look, accent: accent, text: text, textMuted: muted,
                         tint: dark ? .rgba(22, 17, 40, 0.44) : .rgba(250, 246, 255, 0.46),
                         rim: dark ? .rgba(255, 255, 255, 0.24) : .rgba(255, 255, 255, 0.80),
                         sheen: accent.withAlphaComponent(dark ? 0.30 : 0.22),
                         hair: hair, field: field, hover: hover,
                         rowOn: accent.withAlphaComponent(dark ? 0.62 : 0.34), rowOnEnd: end, showsBar: false,
                         shadow: dark ? .rgba(0, 0, 0, 0.42) : .rgba(20, 30, 60, 0.26),
                         inset: 14, radius: 30, rowRadius: 20, sheetRadius: 28, fullHeight: false, edgeAttached: false)
        }
    }

    static var current: Theme {
        let p = Prefs.shared
        return make(kind: ThemeKind(rawValue: p.theme) ?? .tahoe, look: Look(rawValue: p.look) ?? .dark, accentHex: p.accent)
    }
}

// Shared frosted surface: system blur + theme tint + rim + sheen. Used by every window in the app.
final class GlassView: NSView {
    private let effect = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let sheenLayer = CAGradientLayer()
    private let rimLayer = CAShapeLayer()
    private var radius: CGFloat = 0
    private var attached = false
    var snapshotBackdrop: NSColor?   // used only when rendering a picture for checks

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        layer?.addSublayer(tintLayer)
        layer?.addSublayer(sheenLayer)
        rimLayer.fillColor = nil
        rimLayer.lineWidth = 1
        layer?.addSublayer(rimLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ t: Theme, radius: CGFloat? = nil) {
        self.radius = radius ?? t.radius
        attached = t.edgeAttached && radius == nil
        effect.material = t.material
        effect.appearance = t.appearance
        appearance = t.appearance
        tintLayer.backgroundColor = t.tint.cgColor
        sheenLayer.colors = [t.sheen.cgColor, t.sheen.withAlphaComponent(0).cgColor]
        sheenLayer.locations = [0, 0.38]
        if t.kind == .aurora {
            sheenLayer.startPoint = CGPoint(x: 0, y: 1); sheenLayer.endPoint = CGPoint(x: 1, y: 0.2)
        } else {
            sheenLayer.startPoint = CGPoint(x: 0.5, y: 1); sheenLayer.endPoint = CGPoint(x: 0.5, y: 0)
        }
        rimLayer.strokeColor = t.rim.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        sheenLayer.frame = bounds
        rimLayer.frame = bounds
        let r = radius
        if attached {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: bounds.maxX - 0.5, y: 0)); p.addLine(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
            rimLayer.path = p
        } else {
            rimLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, r - 0.5), cornerHeight: max(0, r - 0.5), transform: nil)
        }
        effect.maskImage = r > 0 ? GlassView.mask(radius: r) : nil
        let m = CAShapeLayer()
        m.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        tintLayer.mask = m
        let m2 = CAShapeLayer(); m2.path = m.path
        sheenLayer.mask = m2
        CATransaction.commit()
    }

    static func mask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

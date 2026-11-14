import AppKit
import Carbon.HIToolbox

/// Which side of the main window the drawer slides in from.
enum Edge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// An edge this version doesn't know (top drawers were tried and removed) becomes the bottom one,
    /// rather than failing to load every drawer.
    init(from decoder: Decoder) throws {
        self = Edge(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bottom
    }
}

/// One main app + the drawer app that slides over (or beside) it.
struct Pair: Codable, Identifiable, Equatable {
    var id = UUID()
    var mainID: String
    var drawerID: String
    var edge: Edge = .bottom
    var size: Double = 0.5          // share of the main window's height (bottom) or width (left/right)
    var shrinkMain: Bool = false    // tile next to the main window instead of overlaying it
    var shortcut: Shortcut?         // nil = use the edge's shortcut
    var previousSize: Double?       // size before the last edge drag (double-clicking the edge goes back)
    var redClosesWindow: Bool?      // the red button closes the window as usual, instead of sliding the drawer away

    var effectiveShortcut: Shortcut { shortcut ?? Config.shared.shortcut(for: edge) }

    /// Covers the whole main window, like swapping the app out.
    var isFull: Bool { size >= 0.999 }
    /// Sits beside the main window, which shrinks to make room. A full-size drawer always floats.
    var tiles: Bool { shrinkMain && !isFull }
}

/// A window's close, minimize and zoom buttons.
enum TrafficLight: CaseIterable {
    case close, minimize, zoom
    var attribute: String {
        switch self {
        case .close: kAXCloseButtonAttribute
        case .minimize: kAXMinimizeButtonAttribute
        case .zoom: kAXZoomButtonAttribute
        }
    }

    /// Where `window`'s traffic lights are right now (screen coordinates, a little padding). Any thread.
    static func find(in window: AXUIElement) -> [(kind: TrafficLight, rect: CGRect)] {
        AXUIElementSetMessagingTimeout(window, 0.1)
        return allCases.compactMap { kind in
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kind.attribute as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXUIElementGetTypeID(), let f = axFrame(v as! AXUIElement), f.width > 0 else { return nil }
            return (kind, f.insetBy(dx: -2, dy: -2))
        }
    }
}

/// Apps that take turns in one spot: the main app's window. The left and right edge shortcuts (and fn + swipe)
/// cycle through them.
struct Carousel: Codable, Identifiable, Equatable {
    var id = UUID()
    var mainID: String
    var appIDs: [String] = []       // in order, after the main app

    var members: [String] { [mainID] + appIDs }
}

struct Shortcut: Codable, Hashable {
    var keyCode: Int
    var flags: UInt64               // CGEventFlags subset: control/option/shift/command/fn

    /// fn⌃ + key: , (left), D (bottom), . (right).
    static func fnControl(_ key: Int) -> Shortcut {
        Shortcut(keyCode: key, flags: CGEventFlags([.maskControl, .maskSecondaryFn]).rawValue)
    }
    static func `default`(for edge: Edge) -> Shortcut {
        switch edge {
        case .left: return fnControl(kVK_ANSI_Comma)
        case .bottom: return fnControl(kVK_ANSI_D)
        case .right: return fnControl(kVK_ANSI_Period)
        }
    }
    static let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]

    var cgFlags: CGEventFlags { CGEventFlags(rawValue: flags) }

    /// Individual key caps, e.g. ["fn", "⌃", "D"].
    var keys: [String] {
        let f = cgFlags
        var k: [String] = []
        if f.contains(.maskSecondaryFn) { k.append("fn") }
        if f.contains(.maskControl) { k.append("⌃") }
        if f.contains(.maskAlternate) { k.append("⌥") }
        if f.contains(.maskShift) { k.append("⇧") }
        if f.contains(.maskCommand) { k.append("⌘") }
        return k + [keyName(keyCode)]
    }

    /// As text, e.g. "fn ⌃D".
    var display: String {
        let k = keys
        return k.first == "fn" ? "fn " + k.dropFirst().joined() : k.joined()
    }
}

/// Character a key code produces on the current keyboard layout (e.g. 17 → "T").
func keyName(_ code: Int) -> String {
    let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                  kVK_Delete: "⌫", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                  kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
    if let s = special[code] { return s }
    guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> String in
        let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        return len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }
}

/// All settings, persisted in UserDefaults (domain local.drawer).
final class Config: ObservableObject {
    static let shared = Config()
    private let d = UserDefaults.standard

    @Published var pairs: [Pair] { didSet { store(pairs, "pairs") } }
    @Published var edgeShortcuts: [String: Shortcut] { didSet { store(edgeShortcuts, "edgeShortcuts") } }
    @Published var carousels: [Carousel] { didSet { store(carousels, "carousels") } }
    @Published var inset: Double { didSet { d.set(inset, forKey: "inset") } }   // overlay gap to main window edges
    @Published var peek: Bool { didSet { d.set(peek, forKey: "peek") } }        // hold shortcut to peek
    @Published var hoverTarget: Bool { didSet { d.set(hoverTarget, forKey: "hoverTarget") } }   // carousel shortcuts and swipes act on the carousel under the pointer
    @Published var openInDrawer: Bool { didSet { d.set(openInDrawer, forKey: "openInDrawer") } }   // switching to a drawer app opens its drawer

    private init() {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String) -> T? {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        pairs = load("pairs") ?? []
        edgeShortcuts = load("edgeShortcuts") ?? [:]
        carousels = load("carousels") ?? []
        inset = d.object(forKey: "inset") as? Double ?? 8
        peek = d.object(forKey: "peek") as? Bool ?? true
        hoverTarget = d.object(forKey: "hoverTarget") as? Bool ?? true
        openInDrawer = d.object(forKey: "openInDrawer") as? Bool ?? true
    }

    private func store<T: Encodable>(_ v: T, _ key: String) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }

    /// Drawers configured for `main` that `shortcut` opens.
    func pairs(forMain main: String?, shortcut: Shortcut) -> [Pair] {
        pairs.filter { $0.mainID == main && $0.effectiveShortcut == shortcut }
    }

    /// The shortcut each edge's drawers open with unless they override it.
    func shortcut(for edge: Edge) -> Shortcut { edgeShortcuts[edge.rawValue] ?? .default(for: edge) }

    func setShortcut(_ s: Shortcut, for edge: Edge) {
        edgeShortcuts[edge.rawValue] = s == .default(for: edge) ? nil : s
    }

    /// The carousel `app` belongs to, if any.
    func carousel(containing app: String?) -> Carousel? {
        guard let app else { return nil }
        return carousels.first { $0.members.contains(app) && $0.members.count > 1 }
    }

    /// Every distinct shortcut in use.
    var allShortcuts: [Shortcut] {
        var all = Set(pairs.map(\.effectiveShortcut))
        if carousels.contains(where: { $0.members.count > 1 }) {
            all.insert(shortcut(for: .left)); all.insert(shortcut(for: .right))
        }
        return Array(all)
    }
}

/// Gap macOS puts between tiled windows (System Settings → Desktop & Dock → "Tiled windows have margins").
var tileGap: CGFloat {
    (UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTiledWindowMargins") as? Bool ?? true) ? 8 : 0
}

/// The app whose window is under the pointer (topmost ordinary window there), if any. Window bounds and
/// owners need no Screen Recording permission. Safe off the main thread.
func appUnderPointer() -> String? {
    guard let loc = CGEvent(source: nil)?.location,   // global top-left coords, like window bounds
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    for w in list {   // front to back
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b), r.contains(loc) else { continue }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
    return nil
}

/// Of `pids`, the one owning the frontmost ordinary on-screen window, if any.
func frontmostWindowOwner(among pids: Set<pid_t>) -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) { return pid }
    }
    return nil
}

func running(_ id: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first
}

func appName(_ id: String) -> String {
    if let a = running(id), let n = a.localizedName { return n }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return id
}

func appIcon(_ id: String, size: CGFloat = 16) -> NSImage? {
    let icon = running(id)?.icon
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    guard let copy = icon?.copy() as? NSImage else { return nil }
    copy.size = NSSize(width: size, height: size)
    return copy
}

/// Apps in /Applications, /System/Applications and ~/Applications, for picking apps that aren't running.
func installedApps() -> [(id: String, name: String)] {
    let fm = FileManager.default
    let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    var seen = Set<String>()
    return dirs.flatMap { dir in
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.compactMap { name -> (String, String)? in
            guard let id = Bundle(path: "\(dir)/\(name)")?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return (id, String(name.dropLast(4)))
        }
    }
}

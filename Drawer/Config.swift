import AppKit
import Carbon.HIToolbox

/// Which side of the main window the drawer slides in from.
enum Edge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
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

    var effectiveShortcut: Shortcut { shortcut ?? Config.shared.shortcut(for: edge) }

    /// Covers the whole main window, like swapping the app out.
    var isFull: Bool { size >= 0.999 }
    /// Sits beside the main window, which shrinks to make room. A full-size drawer always floats.
    var tiles: Bool { shrinkMain && !isFull }
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

    var display: String {
        let f = cgFlags
        var s = ""
        if f.contains(.maskSecondaryFn) { s += "fn " }
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + keyName(keyCode)
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
    @Published var inset: Double { didSet { d.set(inset, forKey: "inset") } }   // overlay gap to main window edges
    @Published var peek: Bool { didSet { d.set(peek, forKey: "peek") } }        // hold shortcut to peek

    private init() {
        let d = UserDefaults.standard
        func load<T: Decodable>(_ key: String) -> T? {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        // Migrate the single-pair settings from earlier versions.
        pairs = load("pairs") ?? [Pair(mainID: d.string(forKey: "mainBundleID") ?? "com.t3tools.t3code",
                                       drawerID: d.string(forKey: "drawerBundleID") ?? "com.superlogical.rex",
                                       size: d.object(forKey: "heightFraction") as? Double ?? 0.5,
                                       shrinkMain: d.bool(forKey: "shrinkMain"))]
        var edges: [String: Shortcut] = load("edgeShortcuts") ?? [:]
        if edges.isEmpty, let old: Shortcut = load("shortcut"), old != .default(for: .bottom) {
            edges[Edge.bottom.rawValue] = old   // keep a custom single shortcut from earlier versions on the bottom slot
        }
        edgeShortcuts = edges
        inset = d.object(forKey: "inset") as? Double ?? 8
        peek = d.object(forKey: "peek") as? Bool ?? true
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

    /// Every distinct shortcut in use.
    var allShortcuts: [Shortcut] { Array(Set(pairs.map(\.effectiveShortcut))) }
}

/// Gap macOS puts between tiled windows (System Settings → Desktop & Dock → "Tiled windows have margins").
var tileGap: CGFloat {
    (UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTiledWindowMargins") as? Bool ?? true) ? 8 : 0
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

/// Apps in /Applications (and ~/Applications), for picking apps that aren't running.
func installedApps() -> [(id: String, name: String)] {
    let fm = FileManager.default
    let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    var seen = Set<String>()
    return dirs.flatMap { dir in
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }.compactMap { name -> (String, String)? in
            guard let id = Bundle(path: "\(dir)/\(name)")?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return (id, String(name.dropLast(4)))
        }
    }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
}

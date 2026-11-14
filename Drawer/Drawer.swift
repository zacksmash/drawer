import AppKit
import ApplicationServices

// MARK: Accessibility helpers (AX coords: top-left origin on the primary screen)

func axWindow(_ app: NSRunningApplication) -> AXUIElement? {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 0.25)   // a busy app shouldn't stall the animation
    for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v { return (v as! AXUIElement) }
    }
    var list: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &list) == .success,
       let wins = list as? [AXUIElement], let first = wins.first { return first }
    return nil
}

func axFrame(_ w: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func setPos(_ w: AXUIElement, _ pt: CGPoint) {
    var pt = CGPoint(x: pt.x.rounded(), y: pt.y.rounded())
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pt)!)
}

func setSize(_ w: AXUIElement, _ sz: CGSize) {
    var sz = CGSize(width: sz.width.rounded(), height: sz.height.rounded())
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
}

func setFrame(_ w: AXUIElement, _ r: CGRect) { setPos(w, r.origin); setSize(w, r.size) }

/// Fallback when AX can't see the window (e.g. it's on another Space): ask the window server.
/// CG window bounds use the same top-left global coords as AX.
func largestWindow(of app: NSRunningApplication) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
               && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { ($0[kCGWindowBounds as String] as! CFDictionary?).flatMap { CGRect(dictionaryRepresentation: $0) } }
        .filter { $0.width > 200 && $0.height > 200 }
        .max { $0.width * $0.height < $1.width * $1.height }
}

/// Bring an app and its window to the front. `NSRunningApplication.activate()` from a background
/// app is often ignored on macOS 14+, so set the app frontmost through Accessibility instead.
/// When Drawer last brought an app forward itself, so it can tell those activations from the user's.
var lastOwnActivation: CFTimeInterval = 0

func bringToFront(_ app: NSRunningApplication, _ window: AXUIElement?) {
    lastOwnActivation = CACurrentMediaTime()
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    app.activate()
}

/// A normal document/app window (not a panel, popover or helper window).
func isStandardWindow(_ w: AXUIElement) -> Bool {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &v) == .success
        && (v as? String) == kAXStandardWindowSubrole as String
}

func isMinimized(_ w: AXUIElement) -> Bool {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &v) == .success && (v as? Bool) == true
}

func setMinimized(_ w: AXUIElement, _ on: Bool) {
    AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
}

/// Whether any of the app's normal windows is on the current desktop (Space).
func onCurrentSpace(_ app: NSRunningApplication) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                           && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

// MARK: Layout

/// Frames for a main window and every drawer open around it (AX coords).
struct StageLayout {
    var main: CGRect
    var drawers: [UUID: CGRect]
}

/// Lay out `pairs` (the open drawers of one main app) around the main window's full frame `area`.
/// Tiled ("make room") side drawers take full-height strips and a tiled bottom drawer spans the width
/// left between them; the main window gets what remains. Floating drawers sit inside the main window.
/// Smallest size each drawer app will let its window be (e.g. Rex won't go under 526pt tall), learned by
/// asking for a size and reading back what the app kept. Layouts never go below it, so the drawer stays
/// anchored to its edge instead of hanging off the main window.
var minSizes: [String: CGSize] = [:]

/// Ask `w` for `asked` a few times over ~0.1s; if the app keeps refusing to go that small, record its
/// minimum size. Asking more than once rules out an app that's just slow to resize. Returns true if it learned something.
func probeMinSize(_ app: String, window w: AXUIElement, asked: CGSize) -> Bool {
    for _ in 0..<3 {
        guard let got = axFrame(w)?.size else { return false }
        if got.width <= asked.width + 1 && got.height <= asked.height + 1 { return false }
        Thread.sleep(forTimeInterval: 0.03)
        setSize(w, asked)
    }
    return learnMinSize(app, window: w, asked: asked)
}

/// Record `app`'s minimum size if `w` refused to shrink to `asked`. Returns true if it learned something new.
@discardableResult
func learnMinSize(_ app: String, window w: AXUIElement, asked: CGSize) -> Bool {
    guard let got = axFrame(w)?.size else { return false }
    let old = minSizes[app] ?? .zero
    var new = old
    if got.width > asked.width + 1 { new.width = max(old.width, got.width) }
    if got.height > asked.height + 1 { new.height = max(old.height, got.height) }
    guard new != old else { return false }
    minSizes[app] = new
    return true
}

func stageLayout(area: CGRect, pairs: [Pair]) -> StageLayout {
    let gap = tileGap, inset = Config.shared.inset
    var main = area
    var drawers: [UUID: CGRect] = [:]
    let tiled = pairs.filter(\.shrinkMain), floating = pairs.filter { !$0.shrinkMain }

    // Tiled: sides first (full height), then bottom between them.
    func minSize(_ p: Pair) -> CGSize { minSizes[p.drawerID] ?? .zero }
    for p in tiled where p.edge != .bottom {
        let w = max(((area.width - gap) * p.size).rounded(), min(minSize(p).width, main.width - gap - 200))
        if p.edge == .left {
            drawers[p.id] = CGRect(x: main.minX, y: area.minY, width: w, height: area.height)
            main = CGRect(x: main.minX + w + gap, y: main.minY, width: main.width - w - gap, height: main.height)
        } else {
            drawers[p.id] = CGRect(x: main.maxX - w, y: area.minY, width: w, height: area.height)
            main.size.width -= w + gap
        }
    }
    for p in tiled where p.edge == .bottom {
        let h = max(((area.height - gap) * p.size).rounded(), min(minSize(p).height, main.height - gap - 200))
        drawers[p.id] = CGRect(x: main.minX, y: main.maxY - h, width: main.width, height: h)
        main.size.height -= h + gap
    }
    main.size.width = max(200, main.width)
    main.size.height = max(200, main.height)

    // Floating: inside what's left of the main window, inset from its edges.
    for p in floating {
        let r = main.insetBy(dx: inset, dy: inset)
        switch p.edge {
        case .bottom:
            let h = min(max(((main.height - inset) * p.size).rounded(), minSize(p).height), r.height)
            drawers[p.id] = CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        case .left:
            let w = min(max(((main.width - inset) * p.size).rounded(), minSize(p).width), r.width)
            drawers[p.id] = CGRect(x: r.minX, y: r.minY, width: w, height: r.height)
        case .right:
            let w = min(max(((main.width - inset) * p.size).rounded(), minSize(p).width), r.width)
            drawers[p.id] = CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
        }
    }
    return StageLayout(main: main, drawers: drawers)
}

/// `open` moved just past the screen edge the drawer slides in from.
func closedFrame(_ open: CGRect, edge: Edge) -> CGRect {
    let primaryH = NSScreen.screens[0].frame.height
    let center = CGPoint(x: open.midX, y: primaryH - open.midY)
    let sf = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens[0]).frame
    let screen = CGRect(x: sf.minX, y: primaryH - sf.maxY, width: sf.width, height: sf.height)
    switch edge {
    case .bottom: return open.offsetBy(dx: 0, dy: screen.maxY - open.minY)
    case .left: return open.offsetBy(dx: screen.minX - open.maxX, dy: 0)
    case .right: return open.offsetBy(dx: screen.maxX - open.minX, dy: 0)
    }
}

/// While a drawer on `edge` moves (now at `d`), the side of `old→new` facing it follows the drawer's
/// leading edge, so neighbours never show a gap or overlap it. `lead` lets them sit slightly under it.
func track(old: CGRect, new: CGRect, edge: Edge, drawer d: CGRect, lead: CGFloat) -> CGRect {
    let gap = tileGap
    var r = new
    switch edge {
    case .bottom:
        let lo = min(old.maxY, new.maxY), hi = max(old.maxY, new.maxY)
        let bottom = min(max(d.minY - gap + lead, lo), hi)
        r.size.height = bottom - r.minY
    case .left:
        let lo = min(old.minX, new.minX), hi = max(old.minX, new.minX)
        let left = min(max(d.maxX + gap - lead, lo), hi)
        r.size.width = new.maxX - left; r.origin.x = left
    case .right:
        let lo = min(old.maxX, new.maxX), hi = max(old.maxX, new.maxX)
        let right = min(max(d.minX - gap + lead, lo), hi)
        r.size.width = right - r.minX
    }
    return r
}

let easeOutCubic: (Double) -> Double = { 1 - pow(1 - $0, 3) }   // arrive: fast start, soft landing
let easeInCubic: (Double) -> Double = { $0 * $0 * $0 }           // leave: gentle start, exits at speed

/// Applies window frames on a background queue, always jumping to the most recent request,
/// so a main app that's slow to resize lags slightly instead of stalling the drawer's animation.
final class AsyncResizer {
    private let queue = DispatchQueue(label: "drawer.resize", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: (AXUIElement, CGRect, Bool)?   // window, frame, move only (keep its size)
    private var busy = false

    func request(_ window: AXUIElement, _ frame: CGRect) { enqueue((window, frame, false)) }

    /// Just move it. Much cheaper for the app than a resize, which makes it lay out again (and jitter).
    func move(_ window: AXUIElement, _ origin: CGPoint) { enqueue((window, CGRect(origin: origin, size: .zero), true)) }

    private func enqueue(_ job: (AXUIElement, CGRect, Bool)) {
        lock.lock()
        latest = job
        guard !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = latest else { busy = false; lock.unlock(); return }
            latest = nil
            lock.unlock()
            if job.2 { setPos(job.0, job.1.origin) } else { setFrame(job.0, job.1) }
        }
    }
}

/// Runs one animation at a time, stepped by the display's refresh (vsync) rather than a timer,
/// so every frame lands on a screen refresh.
final class Animator: NSObject {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var curve: (Double) -> Double = { $0 }
    private var step: (Double) -> Void = { _ in }
    private var done: () -> Void = {}

    func run(duration: Double, curve: @escaping (Double) -> Double,
             step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        stop()
        (self.duration, self.curve, self.step, self.done) = (duration, curve, step, done)
        start = CACurrentMediaTime()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)   // keep ticking while menus are open
        link = l
    }

    var isRunning: Bool { link != nil }

    func stop() {
        link?.invalidate(); link = nil
        (step, done) = ({ _ in }, {})   // drop closures so sessions they capture can be freed
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard link != nil else { return }
        let p = min(1, (CACurrentMediaTime() - start) / duration)
        step(curve(p))
        guard link != nil else { return }   // step may have stopped us
        if p >= 1 { let finish = done; stop(); finish() }
    }
}

// MARK: Drawer controller

/// Main window frames saved while tiled drawers are open, so they survive Drawer being killed.
enum OpenState {
    private static let key = "openStateByMain"
    private static var dict: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func save(_ mainID: String, mainFrame f: CGRect) {
        dict[mainID] = [f.minX, f.minY, f.width, f.height].map(Double.init)
    }
    static func clear(_ mainID: String) { dict[mainID] = nil }
    static func all() -> [(String, CGRect)] {
        dict.compactMap { k, v in v.count == 4 ? (k, CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil }
    }
}

/// One open drawer window.
final class DrawerSession {
    let pair: Pair
    let window: AXUIElement
    var parked: CGPoint = .zero      // where macOS actually let the drawer sit off-screen (it pins windows at the edge)
    var docked = false               // fully open; edge drags are blocked and dragging it pops it out
    let resizer = AsyncResizer()
    private var observer: AXObserver?
    var onPopOut: (() -> Void)?
    var expected: CGRect = .zero     // frame we last put it at

    init(pair: Pair, window: AXUIElement) { (self.pair, self.window) = (pair, window) }

    /// Watch for the user dragging the open drawer away (title bar drag) → treat it as popped out.
    func watchMoves(app: NSRunningApplication) {
        guard observer == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            Unmanaged<DrawerSession>.fromOpaque(refcon!).takeUnretainedValue().moved()
        }, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, window, kAXMovedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    func stopWatching() {
        if let observer {
            AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
    }

    private func moved() {
        // Only the user dragging the drawer itself pops it out: its app is in front and the mouse is down.
        // When we move it (following the main window) it can lag behind; that must never count.
        guard docked, NSEvent.pressedMouseButtons & 1 != 0,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == pair.drawerID,
              let now = axFrame(window) else { return }
        if abs(now.minX - expected.minX) + abs(now.minY - expected.minY) > 24 { onPopOut?() }
    }
}

/// Calls back as soon as an app creates a window or shows one again (Accessibility notifications, so no
/// polling delay).
final class WindowCreationWatcher {
    private var observer: AXObserver?
    private let app: AXUIElement
    private let onCreate: (AXUIElement) -> Void

    init?(pid: pid_t, onCreate: @escaping (AXUIElement) -> Void) {
        self.app = AXUIElementCreateApplication(pid)
        self.onCreate = onCreate
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, refcon in
            Unmanaged<WindowCreationWatcher>.fromOpaque(refcon!).takeUnretainedValue().onCreate(element)
        }, &obs) == .success, let obs else { return nil }
        guard AXObserverAddNotification(obs, app, kAXWindowCreatedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return nil }
        // A hidden window shown again isn't "created", but it becomes the main/focused window.
        for n in Self.reshown { AXObserverAddNotification(obs, app, n as CFString, Unmanaged.passUnretained(self).toOpaque()) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    private static let reshown = [kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification]

    deinit {
        guard let observer else { return }
        AXObserverRemoveNotification(observer, app, kAXWindowCreatedNotification as CFString)
        for n in Self.reshown { AXObserverRemoveNotification(observer, app, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

/// A drawer window the user dragged out. Tracks where it is until it closes, so its app can be told to
/// reopen it in the drawer spot instead (see Drawer.forgetMovedSpot).
final class PoppedWindow {
    let pair: Pair
    let window: AXUIElement
    private(set) var lastFrame: CGRect
    var onClosed: ((PoppedWindow) -> Void)?
    private var observer: AXObserver?
    private static let notes = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]

    init(pair: Pair, window: AXUIElement, pid: pid_t, frame: CGRect) {
        (self.pair, self.window, self.lastFrame) = (pair, window, frame)
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, _, note, refcon in
            Unmanaged<PoppedWindow>.fromOpaque(refcon!).takeUnretainedValue().changed(note as String)
        }, &obs) == .success, let obs else { return }
        for n in Self.notes { AXObserverAddNotification(obs, window, n as CFString, Unmanaged.passUnretained(self).toOpaque()) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    private func changed(_ note: String) {
        if note == kAXUIElementDestroyedNotification as String { onClosed?(self); return }
        if let f = axFrame(window) { lastFrame = f }
    }

    deinit {
        guard let observer else { return }
        for n in Self.notes { AXObserverRemoveNotification(observer, window, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

/// Many Mac apps remember where each window was ("NSWindow Frame <name>" in their preferences) and reopen it
/// there. Point the entries that match `from` at `to` instead. Apps that save frames another way are untouched.
func rewriteSavedFrames(app: String, from: CGRect, to: CGRect) {
    let primaryH = NSScreen.screens[0].frame.height
    let cocoa = { (r: CGRect) in [r.minX, primaryH - r.maxY, r.width, r.height].map(Double.init) }
    let old = cocoa(from), new = cocoa(to)
    let domain = app as CFString
    guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else { return }
    var changed = false
    for key in keys where key.hasPrefix("NSWindow Frame ") {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain) as? String else { continue }
        var tokens = value.split(separator: " ").map(String.init)
        let nums = tokens.prefix(4).compactMap(Double.init)
        guard nums.count == 4, zip(nums, old).allSatisfy({ abs($0 - $1) < 3 }) else { continue }
        for i in 0..<4 { tokens[i] = String(Int(new[i].rounded())) }
        CFPreferencesSetAppValue(key as CFString, (tokens.joined(separator: " ") + " ") as CFString, domain)
        changed = true
    }
    if changed { CFPreferencesAppSynchronize(domain) }
}

/// A main window and the drawers currently open around it.
final class Stage {
    let mainID: String
    var mainWindow: AXUIElement?
    var area: CGRect                 // the main window's full frame (as if no tiled drawers were open)
    var sessions: [DrawerSession] = []
    let animator = Animator()
    let mainResizer = AsyncResizer()
    var expectedMain: CGRect?        // main frame we last set; anything else means the user moved/re-tiled it
    var quietUntil: CFTimeInterval = 0
    var pressWatch: Timer?           // watching a mouse press on the main window for a drag
    var clickPending = false         // the main app was brought forward by that press
    var relayoutTimer: Timer?
    private var observer: AXObserver?
    var onMainChanged: (() -> Void)?

    init(mainID: String, mainWindow: AXUIElement?, area: CGRect) {
        (self.mainID, self.mainWindow, self.area) = (mainID, mainWindow, area)
    }

    var tiled: Bool { sessions.contains { $0.pair.shrinkMain } }
    func layout(_ pairs: [Pair]? = nil) -> StageLayout { stageLayout(area: area, pairs: pairs ?? sessions.map(\.pair)) }

    func watchMain(app: NSRunningApplication) {
        guard observer == nil, let mainWindow else { return }
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            Unmanaged<Stage>.fromOpaque(refcon!).takeUnretainedValue().onMainChanged?()
        }, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, mainWindow, kAXMovedNotification as CFString, me)
        AXObserverAddNotification(obs, mainWindow, kAXResizedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    func stopWatching() {
        if let observer, let mainWindow {
            AXObserverRemoveNotification(observer, mainWindow, kAXMovedNotification as CFString)
            AXObserverRemoveNotification(observer, mainWindow, kAXResizedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        relayoutTimer?.invalidate()
    }

    func setMain(_ r: CGRect) {
        guard let mainWindow else { return }
        expectedMain = r
        mainResizer.request(mainWindow, r)
    }
}

final class Drawer {
    /// Open drawers, grouped by main app.
    private var stages: [String: Stage] = [:]
    /// Drawers waiting for their app's window, by pair. Dropping one also drops its window-creation watcher.
    private var pending: [UUID: Timer] = [:] {
        didSet { for id in creationWatchers.keys where pending[id] == nil { creationWatchers[id] = nil } }
    }
    private var creationWatchers: [UUID: WindowCreationWatcher] = [:]
    /// The window each drawer app last showed in a drawer. Many apps (Rex, Electron apps) only hide a window
    /// when it's closed and show the same one again on reopen, so it can be parked before it reappears.
    private var lastWindows: [String: AXUIElement] = [:]
    /// Drawer windows the user dragged out, by drawer app, until they close or dock again.
    private var popped: [String: PoppedWindow] = [:]

    var lockedFrames: [CGRect] { stages.values.flatMap { $0.sessions.filter(\.docked).map(\.expected) } }
    var mainFrames: [(id: String, frame: CGRect)] {
        stages.values.compactMap { st in st.expectedMain.map { (st.mainID, $0) } }
    }

    /// The mouse went down on a main window that has drawers. If the window starts moving (a title-bar drag),
    /// drop its drawers on the spot. Checked every frame from the mouse rather than from move notifications,
    /// which apps can deliver late or only once the drag ends.
    func mainPressed(_ mainID: String) {
        guard let st = stages[mainID], st.pressWatch == nil, let mw = st.mainWindow, let start = axFrame(mw) else { return }
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self, weak st] t in
            guard let self, let st, self.stages[st.mainID] === st, let now = axFrame(mw) else { t.invalidate(); st?.pressWatch = nil; return }
            // Any change counts: macOS also gives a tiled ("Left Half" etc.) window its old size back the
            // moment you drag it, so a drag can show up as a resize.
            if abs(now.minX - start.minX) + abs(now.minY - start.minY) > 2
                || abs(now.width - start.width) + abs(now.height - start.height) > 2 {
                t.invalidate(); st.pressWatch = nil
                self.dropAll(st)
                return
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {   // released without moving: just a click
                t.invalidate(); st.pressWatch = nil
                if st.clickPending { st.clickPending = false; self.closeFloating(st) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        st.pressWatch = t
    }

    /// Clicking the main app dismisses its floating drawers (it would cover them anyway).
    private func closeFloating(_ st: Stage) {
        for s in st.sessions where s.docked && !s.pair.shrinkMain { close(s.pair.id, raise: false) }
    }
    var openAppIDs: Set<String> { Set(stages.values.flatMap { st in st.sessions.map(\.pair.drawerID) + [st.mainID] }) }

    private func session(_ id: UUID) -> (Stage, DrawerSession)? {
        for st in stages.values { if let s = st.sessions.first(where: { $0.pair.id == id }) { return (st, s) } }
        return nil
    }

    /// Handle `shortcut` pressed with `front` frontmost. Returns the drawer it opened (for hold-to-peek).
    @discardableResult
    func toggle(_ shortcut: Shortcut) -> UUID? {
        guard AXIsProcessTrusted() else { promptAccessibility(); return nil }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // In an open drawer's app, act on behalf of its main app.
        let main = stages.values.first { st in st.sessions.contains { $0.pair.drawerID == front } }?.mainID ?? front
        guard let pair = Config.shared.pairs(forMain: main, shortcut: shortcut).first else { return nil }
        if session(pair.id) != nil || pending[pair.id] != nil { close(pair.id); return nil }
        // One app can only be in one drawer at a time: take it from wherever else it's open.
        for st in stages.values { for s in st.sessions where s.pair.drawerID == pair.drawerID { detach(st, s, hide: true) } }
        show(pair)
        return pair.id
    }

    init() {
        // Clicking (or switching to) the main app dismisses its floating drawers, which it would cover anyway.
        // Tiled drawers sit beside the main window, so they stay.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, CACurrentMediaTime() - lastOwnActivation > 0.5,
                  let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  let st = self.stages[id] else { return }
            if st.pressWatch != nil || NSEvent.pressedMouseButtons & 1 != 0 {
                st.clickPending = true   // a click or the start of a drag: mainPressed decides on release
                self.mainPressed(id)     // (no-op if the event tap already started watching)
            } else {
                self.closeFloating(st)
            }
        }
        // Quitting an app with a dragged-out drawer window closes that window too.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                  let p = self.popped[id] else { return }
            self.forgetMovedSpot(p)
        }
    }

    /// A dragged-out drawer window closed: make its app reopen it in the drawer spot, not where it was moved to.
    private func forgetMovedSpot(_ p: PoppedWindow) {
        popped[p.pair.drawerID] = nil
        rewriteSavedFrames(app: p.pair.drawerID, from: p.lastFrame, to: openFrame(p.pair))
    }

    // MARK: Opening

    /// Launch the drawer app if needed, wait for its window, then slide it in.
    func show(_ pair: Pair) {
        pending[pair.id]?.invalidate()
        popped[pair.drawerID] = nil   // docking it again; no need to remember the moved spot
        let started = CACurrentMediaTime()
        var reopened = false, parked = false
        var windowSeenAt: CFTimeInterval?
        var spaceMove: (window: AXUIElement, at: CFTimeInterval, restored: Bool)?

        if running(pair.drawerID) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pair.drawerID) else { return }
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = false
            conf.hides = true   // its first window must not flash where it was last time
            NSWorkspace.shared.openApplication(at: url, configuration: conf)
        }

        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - started
            if elapsed > 10 { t.invalidate(); self.pending[pair.id] = nil; return }   // app never produced a window
            guard let app = running(pair.drawerID) else { return }
            // Catch the window the instant the app creates it (launch or reopen) and park it off-screen,
            // so it can't show up where it last was, even for a frame.
            if self.creationWatchers[pair.id] == nil {
                self.creationWatchers[pair.id] = WindowCreationWatcher(pid: app.processIdentifier) { [weak self] w in
                    guard let self, !parked, self.pending[pair.id] != nil, isStandardWindow(w) else { return }
                    self.park(pair, w)
                    parked = true
                }
            }
            guard app.isFinishedLaunching else { return }
            // A window wherever it last was (popped out, moved, or reopened) would flash there before jumping
            // to the drawer spot. So the app stays hidden until its window is parked off-screen, then unhides.
            if !parked {
                guard let w = axWindow(app) else {
                    // Running but no window (common after closing it, and for Transmit/TablePlus):
                    // a "reopen" asks for its default window, hidden so it can't flash.
                    if !app.isHidden { app.hide() }
                    if !reopened, elapsed > 0.3, let url = app.bundleURL {
                        reopened = true
                        // If it re-shows the window it hid on close, that one is already off-screen.
                        if let last = self.lastWindows[pair.drawerID] { self.park(pair, last) }
                        let conf = NSWorkspace.OpenConfiguration()
                        conf.activates = false
                        conf.hides = true
                        NSWorkspace.shared.openApplication(at: url, configuration: conf)
                    }
                    return
                }
                if !app.isHidden { app.hide(); return }
                self.park(pair, w)
                parked = true
                app.unhide()
                return
            }
            if app.isHidden { app.unhide(); return }
            // Moving the window here from another desktop (see below): wait for it to land.
            if let m = spaceMove {
                let now = CACurrentMediaTime()
                if !m.restored {
                    // Minimised (it happened on its own desktop, out of sight): park it off-screen and restore it here.
                    guard isMinimized(m.window) || now - m.at > 1 else { return }
                    self.park(pair, m.window)
                    setMinimized(m.window, false)
                    spaceMove = (m.window, now, true)
                    return
                }
                if !onCurrentSpace(app) {
                    if now - m.at > 2 { t.invalidate(); self.pending[pair.id] = nil; self.warnOtherSpace(pair.drawerID) }
                    return
                }
                t.invalidate()
                self.pending[pair.id] = nil
                self.park(pair, m.window)
                self.present(pair, app: app, window: m.window)
                return
            }
            guard let w = axWindow(app) else { return }
            // The window is on another desktop. There's no public API to move it, but a window restored from
            // the Dock lands on the current desktop: minimise it (out of sight over there), then restore it here.
            if !onCurrentSpace(app) {
                // A just-unhidden window can take a moment to show up as on-screen: give it a beat first.
                if windowSeenAt == nil { windowSeenAt = CACurrentMediaTime() }
                if CACurrentMediaTime() - windowSeenAt! < 0.3 { return }
                spaceMove = (w, CACurrentMediaTime(), false)
                setMinimized(w, true)
                return
            }
            t.invalidate()
            self.pending[pair.id] = nil
            self.present(pair, app: app, window: w)
        }
        RunLoop.main.add(t, forMode: .common)
        pending[pair.id] = t
        t.fire()   // first check right away
    }

    /// Stage for `mainID`, created from the main window's current frame if none is open.
    private func stage(for mainID: String) -> Stage {
        if let st = stages[mainID] { return st }
        let main = running(mainID).flatMap { $0.isHidden ? nil : $0 }
        let mw = main.flatMap(axWindow)
        let area = mw.flatMap(axFrame) ?? main.flatMap(largestWindow) ?? Self.screenArea()
        let st = Stage(mainID: mainID, mainWindow: mw, area: area)
        st.expectedMain = area
        st.onMainChanged = { [weak self, weak st] in if let st { self?.mainChanged(st) } }
        if let main { st.watchMain(app: main) }
        stages[mainID] = st
        return st
    }

    /// Where the drawer would open now, parked just off-screen.
    private func park(_ pair: Pair, _ w: AXUIElement) {
        setFrame(w, closedFrame(openFrame(pair), edge: pair.edge))
    }

    /// Where `pair`'s drawer would sit if it opened now.
    private func openFrame(_ pair: Pair) -> CGRect {
        let st = stages[pair.mainID]
        let area = st?.area ?? running(pair.mainID).flatMap(axWindow).flatMap(axFrame) ?? Self.screenArea()
        let pairs = (st?.sessions.filter { $0.pair.id != pair.id }.map(\.pair) ?? []) + [pair]
        return stageLayout(area: area, pairs: pairs).drawers[pair.id] ?? area
    }

    private func present(_ pair: Pair, app: NSRunningApplication, window w: AXUIElement) {
        let st = stage(for: pair.mainID)
        let before = st.layout()
        lastWindows[pair.drawerID] = w
        let s = DrawerSession(pair: pair, window: w)
        st.sessions.append(s)
        guard let guess = st.layout().drawers[pair.id] else { return }
        setFrame(w, closedFrame(guess, edge: pair.edge))
        // If the app won't go that small (Rex has a minimum height), find out now, before sliding,
        // so it doesn't stop short and then jump once the size is noticed.
        if probeMinSize(pair.drawerID, window: w, asked: guess.size) {
            setFrame(w, closedFrame(st.layout().drawers[pair.id] ?? guess, edge: pair.edge))
        }
        let after = st.layout()
        guard let open = after.drawers[pair.id] else { return }
        let start = CGRect(origin: axFrame(w)?.origin ?? closedFrame(open, edge: pair.edge).origin, size: open.size)
        s.parked = start.origin
        s.expected = open
        if st.tiled { OpenState.save(st.mainID, mainFrame: st.area) }
        bringToFront(app, w)   // drawer in front, so its neighbours can resize behind it

        // The new drawer moves on the main thread every screen refresh; the main window and the other drawers
        // are resized on background queues (latest frame wins), so slow apps can't stall the slide.
        let others = st.sessions.filter { $0 !== s }
        st.quietUntil = .infinity
        st.animator.run(duration: 0.28, curve: easeOutCubic, step: { e in
            let d = lerp(start, open, e)
            setPos(w, d.origin)
            let lead = 40 * (1 - e)   // tapers to zero so the last frame is exact (no snap)
            if pair.shrinkMain {
                st.setMain(track(old: before.main, new: after.main, edge: pair.edge, drawer: d, lead: lead))
                for o in others { if let a = before.drawers[o.pair.id], let b = after.drawers[o.pair.id], a != b {
                    o.expected = b
                    o.resizer.request(o.window, track(old: a, new: b, edge: pair.edge, drawer: d, lead: lead))
                } }
            }
        }) { [weak self, st, s] in
            st.setMain(after.main)
            for o in others { if let b = after.drawers[o.pair.id] { o.expected = b; o.resizer.request(o.window, b) } }
            bringToFront(app, w)   // in case another app grabbed focus mid-slide
            s.docked = true
            s.onPopOut = { [weak self, weak st, weak s] in if let st, let s { self?.popOut(st, s) } }
            s.watchMoves(app: app)
            st.quietUntil = CACurrentMediaTime() + 0.4   // let our last resizes land before watching for user moves
            // Once settled, check the app kept the size we asked for. If it won't go that small (Rex has a
            // minimum height), remember that and re-fit so the drawer stays anchored to its edge.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak st, weak s] in
                guard let st, let s, s.docked, let f = axFrame(w),
                      f.width > s.expected.width + 1 || f.height > s.expected.height + 1 else { return }
                setSize(w, s.expected.size)   // ask once more, in case the app was just slow
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak st, weak s] in
                    guard let self, let st, let s, s.docked, st.sessions.contains(where: { $0 === s }) else { return }
                    if learnMinSize(pair.drawerID, window: w, asked: s.expected.size) { self.applyLayout(st) }
                }
            }
        }
    }

    // MARK: Closing

    /// Slide the drawer back off its screen edge while its neighbours grow back into the space.
    func close(_ id: UUID, raise: Bool = true) {
        if let t = pending.removeValue(forKey: id) { t.invalidate(); return }
        guard let (st, s) = session(id) else { return }
        let before = st.layout()
        st.sessions.removeAll { $0 === s }
        let after = st.layout()
        s.docked = false
        s.stopWatching()
        let app = running(s.pair.drawerID)
        guard let f = axFrame(s.window) else { app?.hide(); finishStage(st, after); return }
        let parked = CGRect(origin: s.parked, size: f.size)
        let others = st.sessions
        let wasFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if raise, let app { bringToFront(app, s.window) }   // must be in front, or neighbours would cover it as they grow
        st.quietUntil = .infinity
        st.animator.run(duration: 0.24, curve: easeInCubic, step: { e in
            let d = lerp(f, parked, e)
            setPos(s.window, d.origin)
            let lead = 40 * e   // grows from zero so the first frame doesn't jump
            if s.pair.shrinkMain {
                st.setMain(track(old: before.main, new: after.main, edge: s.pair.edge, drawer: d, lead: lead))
                for o in others { if let a = before.drawers[o.pair.id], let b = after.drawers[o.pair.id], a != b {
                    o.expected = b
                    o.resizer.request(o.window, track(old: a, new: b, edge: s.pair.edge, drawer: d, lead: lead))
                } }
            }
        }) { [weak self] in
            app?.hide()
            self?.finishStage(st, after)
            Drawer.restoreFocus(st, wasFront: wasFront, closing: s.pair.drawerID)
        }
    }

    /// After a drawer closes, put the main window and the drawers still open back in a sensible order.
    /// Floating drawers sit on top of the main window, so they must end up above it again.
    private static func restoreFocus(_ st: Stage, wasFront: String?, closing: String) {
        if let main = running(st.mainID) { bringToFront(main, st.mainWindow) }
        if wasFront == st.mainID { return }   // the user was working in the main app: leave them there
        // The user was in a drawer: raise the floating ones over the main window, ending on the one they were in.
        let floating = st.sessions.filter { !$0.pair.shrinkMain }
        let ordered = floating.filter { $0.pair.drawerID != wasFront } + floating.filter { $0.pair.drawerID == wasFront }
        for o in ordered { if let a = running(o.pair.drawerID) { bringToFront(a, o.window) } }
        if let o = st.sessions.first(where: { $0.pair.drawerID == wasFront && $0.pair.shrinkMain }),
           let a = running(o.pair.drawerID) { bringToFront(a, o.window) }
    }

    /// Settle a stage on `layout`, and forget it if no drawers are left.
    private func finishStage(_ st: Stage, _ layout: StageLayout) {
        st.setMain(st.sessions.isEmpty ? st.area : layout.main)
        for o in st.sessions { if let b = layout.drawers[o.pair.id] { o.expected = b; o.resizer.request(o.window, b) } }
        st.quietUntil = CACurrentMediaTime() + 0.4
        if st.sessions.isEmpty {
            st.stopWatching()
            stages[st.mainID] = nil
            OpenState.clear(st.mainID)
        } else if !st.tiled {
            OpenState.clear(st.mainID)
        }
    }

    /// Take a drawer out of its stage right away (no animation), optionally hiding its app.
    private func detach(_ st: Stage, _ s: DrawerSession, hide: Bool) {
        st.animator.stop()
        st.sessions.removeAll { $0 === s }
        s.docked = false
        s.stopWatching()
        if hide { running(s.pair.drawerID)?.hide() }
        finishStage(st, st.layout())
    }

    /// The user dragged a drawer away: let it be a normal window and give the space back.
    /// Pressing its shortcut in the main app docks it again.
    private func popOut(_ st: Stage, _ s: DrawerSession) {
        guard st.sessions.contains(where: { $0 === s }) else { return }
        detach(st, s, hide: false)
        guard let app = running(s.pair.drawerID) else { return }
        let p = PoppedWindow(pair: s.pair, window: s.window, pid: app.processIdentifier, frame: axFrame(s.window) ?? s.expected)
        p.onClosed = { [weak self] p in self?.forgetMovedSpot(p) }
        popped[s.pair.drawerID] = p
    }

    /// Put everything back immediately (used when Drawer quits).
    func restoreNow() {
        for st in stages.values {
            st.animator.stop()
            for s in st.sessions { s.stopWatching(); running(s.pair.drawerID)?.hide() }
            if let mw = st.mainWindow { setFrame(mw, st.area) }
            st.stopWatching()
            OpenState.clear(st.mainID)
        }
        stages = [:]
    }

    /// If Drawer was killed or crashed with tiled drawers open, the main window was left shrunk.
    /// Put it back to the size it had before, so the next open doesn't shrink it a second time.
    func recoverAfterCrash() {
        for (mainID, frame) in OpenState.all() {
            OpenState.clear(mainID)
            guard let main = running(mainID), let mw = axWindow(main) else { continue }
            setFrame(mw, frame)
        }
    }

    // MARK: Following the main window

    /// The main window moved or resized while drawers are open.
    /// Moved (same size) → shift the drawers along live. Resized/re-tiled → re-lay out once it settles.
    private func mainChanged(_ st: Stage) {
        guard stages[st.mainID] === st, !st.animator.isRunning, CACurrentMediaTime() > st.quietUntil,
              let mw = st.mainWindow, let now = axFrame(mw), let expected = st.expectedMain else { return }
        let near = { (a: CGFloat, b: CGFloat) in abs(a - b) < 2 }
        if near(now.minX, expected.minX), near(now.minY, expected.minY),
           near(now.width, expected.width), near(now.height, expected.height) { return }   // our own change

        if NSEvent.pressedMouseButtons & 1 != 0 || (near(now.width, expected.width) && near(now.height, expected.height)) {
            // Dragged (macOS may also un-tile it to its old size as the drag starts) or moved: drop its drawers.
            dropAll(st)
        } else {
            st.relayoutTimer?.invalidate()
            let t = Timer(timeInterval: 0.15, repeats: false) { [weak self, weak st] _ in if let st { self?.relayout(st) } }
            RunLoop.main.add(t, forMode: .common)
            st.relayoutTimer = t
        }
    }

    /// Hide every drawer of `st` at once (no animation) and give the main window back its full,
    /// un-drawered size, where it is now. Set again once the mouse is released, since macOS may
    /// still be sizing it while it's being dragged.
    private func dropAll(_ st: Stage) {
        st.animator.stop()
        st.relayoutTimer?.invalidate()
        st.pressWatch?.invalidate(); st.pressWatch = nil
        for s in st.sessions {
            s.docked = false
            s.stopWatching()
            running(s.pair.drawerID)?.hide()
        }
        st.sessions = []
        st.stopWatching()
        stages[st.mainID] = nil
        OpenState.clear(st.mainID)
        guard let mw = st.mainWindow else { return }
        let size = st.area.size
        setSize(mw, size)
        let t = Timer(timeInterval: 0.03, repeats: true) { t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            if let f = axFrame(mw), f.size != size { setSize(mw, size) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// The main window got a new size (e.g. re-tiled): treat it as the new full area and fit the drawers to it.
    private func relayout(_ st: Stage) {
        guard stages[st.mainID] === st, let mw = st.mainWindow, let area = axFrame(mw) else { return }
        st.area = area
        applyLayout(st)
    }

    /// Move the main window and every open drawer to the stage's current layout.
    private func applyLayout(_ st: Stage) {
        let l = st.layout()
        st.quietUntil = CACurrentMediaTime() + 0.6
        st.setMain(l.main)
        if st.tiled { OpenState.save(st.mainID, mainFrame: st.area) }
        for s in st.sessions {
            guard let target = l.drawers[s.pair.id], let from = axFrame(s.window) else { continue }
            s.expected = target
            setSize(s.window, target.size)
            s.parked = s.pair.edge == .bottom ? CGPoint(x: target.minX, y: s.parked.y) : CGPoint(x: s.parked.x, y: target.minY)
            let start = CGRect(origin: from.origin, size: target.size)
            s.resizer.request(s.window, start)
            let anim = Animator()
            anim.run(duration: 0.2, curve: easeOutCubic, step: { e in setPos(s.window, lerp(start, target, e).origin) },
                     done: { _ = anim })
        }
    }

    // MARK: Misc

    private var warned = Set<String>()
    private func warnOtherSpace(_ id: String) {
        guard warned.insert(id).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "\(appName(id))'s window is on another desktop"
        alert.informativeText = """
            Drawer couldn't bring it to this desktop. To have \(appName(id)) show up on whichever desktop \
            you're on, right-click its Dock icon → Options → Assign To: All Desktops.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func screenArea() -> CGRect {
        let primaryH = NSScreen.screens[0].frame.height
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGRect(x: v.minX, y: primaryH - v.maxY, width: v.width, height: v.height)
    }

    func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}

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
func bringToFront(_ app: NSRunningApplication, _ window: AXUIElement?) {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    app.activate()
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

struct Layout {
    var open: CGRect          // drawer frame when shown
    var closed: CGRect        // drawer frame parked just off the screen edge
    var mainShrunk: CGRect?   // main window frame while the drawer is shown (shrink mode)
}

/// Where everything goes for `pair`, given the main window frame `area`.
/// `drawerSize` is the size the drawer app actually accepted (apps may enforce min/max sizes);
/// pass nil to get the ideal size.
func layout(_ pair: Pair, area: CGRect, drawerSize: CGSize? = nil) -> Layout {
    let cfg = Config.shared
    let primaryH = NSScreen.screens[0].frame.height
    let center = CGPoint(x: area.midX, y: primaryH - area.midY)
    let sf = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens[0]).frame
    let screen = CGRect(x: sf.minX, y: primaryH - sf.maxY, width: sf.width, height: sf.height)  // AX coords

    let edge = pair.shrinkMain ? 0 : cfg.inset           // gap to the main window's outer edges
    let between = pair.shrinkMain ? tileGap : cfg.inset   // gap between the drawer and the rest of the main window
    var open: CGRect, closed: CGRect, shrunk: CGRect?

    switch pair.edge {
    case .bottom:
        let s = drawerSize ?? CGSize(width: area.width - 2 * edge, height: ((area.height - between) * pair.size).rounded())
        open = CGRect(x: area.midX - s.width / 2, y: area.maxY - edge - s.height, width: s.width, height: s.height)
        closed = open.offsetBy(dx: 0, dy: screen.maxY - open.minY)
        shrunk = CGRect(x: area.minX, y: area.minY, width: area.width,
                        height: max(200, open.minY - tileGap - area.minY))
    case .left:
        let s = drawerSize ?? CGSize(width: ((area.width - between) * pair.size).rounded(), height: area.height - 2 * edge)
        open = CGRect(x: area.minX + edge, y: area.midY - s.height / 2, width: s.width, height: s.height)
        closed = open.offsetBy(dx: screen.minX - open.maxX, dy: 0)
        let x = open.maxX + tileGap
        shrunk = CGRect(x: x, y: area.minY, width: max(200, area.maxX - x), height: area.height)
    case .right:
        let s = drawerSize ?? CGSize(width: ((area.width - between) * pair.size).rounded(), height: area.height - 2 * edge)
        open = CGRect(x: area.maxX - edge - s.width, y: area.midY - s.height / 2, width: s.width, height: s.height)
        closed = open.offsetBy(dx: screen.maxX - open.minX, dy: 0)
        shrunk = CGRect(x: area.minX, y: area.minY, width: max(200, open.minX - tileGap - area.minX), height: area.height)
    }
    return Layout(open: open, closed: closed, mainShrunk: pair.shrinkMain ? shrunk : nil)
}

let easeOutCubic: (Double) -> Double = { 1 - pow(1 - $0, 3) }   // arrive: fast start, soft landing
let easeInCubic: (Double) -> Double = { $0 * $0 * $0 }           // leave: gentle start, exits at speed

/// Applies window frames on a background queue, always jumping to the most recent request,
/// so a main app that's slow to resize lags slightly instead of stalling the drawer's animation.
final class AsyncResizer {
    private let queue = DispatchQueue(label: "drawer.resize", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: (AXUIElement, CGRect)?
    private var busy = false

    func request(_ window: AXUIElement, _ frame: CGRect) {
        lock.lock()
        latest = (window, frame)
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
            setFrame(job.0, job.1)
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

/// Main window frames saved while a tiled drawer is open, so they survive Drawer being killed.
enum OpenState {
    private static let key = "openState"
    private static var dict: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func save(_ id: UUID, mainFrame f: CGRect) {
        dict[id.uuidString] = [f.minX, f.minY, f.width, f.height].map(Double.init)
    }
    static func clear(_ id: UUID) { dict[id.uuidString] = nil }
    static func all() -> [(UUID, CGRect)] {
        dict.compactMap { k, v in
            guard let id = UUID(uuidString: k), v.count == 4 else { return nil }
            return (id, CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        }
    }
}

/// One drawer's live state: from the moment it starts opening until it has closed (or popped out).
final class DrawerSession {
    let pair: Pair
    var window: AXUIElement?
    var mainWindow: AXUIElement?
    var mainFrame: CGRect = .zero     // main window frame before opening, restored on close
    var parked: CGPoint = .zero       // where macOS actually let the drawer sit off-screen (it pins windows at the edge)
    /// Frame of the fully open drawer; while set, resize drags on its edges are blocked (see Hotkey).
    var lockedFrame: CGRect?
    let animator = Animator()
    let resizer = AsyncResizer()
    var pending: Timer?
    private var observer: AXObserver?
    var onPopOut: (() -> Void)?

    init(pair: Pair) { self.pair = pair }

    /// Watch for the user dragging the open drawer away (title bar drag) → treat it as popped out.
    func watchMoves(app: NSRunningApplication, window: AXUIElement) {
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
            if let window { AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
    }

    private func moved() {
        guard let locked = lockedFrame, let window, let now = axFrame(window) else { return }
        if abs(now.minX - locked.minX) + abs(now.minY - locked.minY) > 24 { onPopOut?() }
    }
}

final class Drawer {
    /// Open (or opening) drawers, by pair id. Several can be open at once, one per main app.
    private var sessions: [UUID: DrawerSession] = [:]

    var lockedFrames: [CGRect] { sessions.values.compactMap(\.lockedFrame) }
    var openAppIDs: Set<String> { Set(sessions.values.flatMap { [$0.pair.mainID, $0.pair.drawerID] }) }

    private func session(for front: String?) -> DrawerSession? {
        sessions.values.first { front == $0.pair.mainID || front == $0.pair.drawerID }
    }

    /// Whether the shortcut means something with `front` frontmost.
    func handles(front: String?) -> Bool {
        session(for: front) != nil || Config.shared.pair(forMain: front) != nil
    }

    /// Toggle the drawer for the frontmost app. Returns the pair id if this opened one (for hold-to-peek).
    @discardableResult
    func toggle() -> UUID? {
        guard AXIsProcessTrusted() else { promptAccessibility(); return nil }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let s = session(for: front) {
            close(s.pair.id)
            return nil
        }
        guard let pair = Config.shared.pair(forMain: front) else { return nil }
        // The same drawer app can only be in one place: take it from another main app's drawer first.
        for s in sessions.values where s.pair.drawerID == pair.drawerID { restore(s) }
        show(pair)
        return pair.id
    }

    /// Open the drawer for `pair`: launch the drawer app if needed, wait for its window, then slide it in.
    func show(_ pair: Pair) {
        let s = DrawerSession(pair: pair)
        sessions[pair.id] = s
        let started = CACurrentMediaTime()
        var reopened = false
        var hidOnce = false
        var windowSeenAt: CFTimeInterval?

        if running(pair.drawerID) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pair.drawerID) else {
                sessions[pair.id] = nil; return
            }
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: conf)
        }

        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self, weak s] t in
            guard let self, let s else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - started
            if elapsed > 10 { t.invalidate(); self.sessions[pair.id] = nil; return }   // app never produced a window
            guard let app = running(pair.drawerID), app.isFinishedLaunching else { return }
            // A visible drawer window (popped out, or reopened where it last was) would jump to the
            // drawer spot. Hide it first; it's then parked off-screen while hidden and slides in cleanly.
            if !app.isHidden, !hidOnce {
                hidOnce = true
                if axWindow(app) != nil { app.hide(); return }
            }
            if app.isHidden {
                // Park the window off-screen while still hidden, so unhiding doesn't flash it anywhere.
                if let w = axWindow(app) { self.park(pair, w) }
                hidOnce = true   // we're showing it ourselves; don't hide it again next tick
                app.unhide()
                return
            }
            guard let w = axWindow(app) else {
                // Running but no window (common for Transmit/TablePlus): a "reopen" asks for its default window.
                if !reopened, elapsed > 0.6, let url = app.bundleURL {
                    reopened = true
                    let conf = NSWorkspace.OpenConfiguration()
                    conf.activates = false
                    NSWorkspace.shared.openApplication(at: url, configuration: conf)
                }
                return
            }
            // The window exists but isn't on this desktop: macOS gives no public way to move it here.
            if !onCurrentSpace(app) {
                if windowSeenAt == nil { windowSeenAt = CACurrentMediaTime() }
                if CACurrentMediaTime() - windowSeenAt! > 0.5 {
                    t.invalidate(); self.sessions[pair.id] = nil; self.warnOtherSpace(pair.drawerID)
                }
                return
            }
            t.invalidate()
            self.present(s, app: app, window: w)
        }
        RunLoop.main.add(t, forMode: .common)
        s.pending = t
        t.fire()   // first check right away, not one interval later
    }

    /// Main window frame that keeps its edge just behind the drawer's leading edge while the drawer moves.
    /// `lead` lets the main window extend a little under the drawer, so freshly drawn content is
    /// revealed only once it's rendered (no blank flashes in the gap).
    private func trackingMainFrame(_ pair: Pair, area: CGRect, drawer d: CGRect, lead: CGFloat) -> CGRect {
        switch pair.edge {
        case .bottom:
            let bottom = min(area.maxY, d.minY - tileGap + lead)
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: max(200, bottom - area.minY))
        case .left:
            let left = max(area.minX, d.maxX + tileGap - lead)
            return CGRect(x: left, y: area.minY, width: max(200, area.maxX - left), height: area.height)
        case .right:
            let right = min(area.maxX, d.minX - tileGap + lead)
            return CGRect(x: area.minX, y: area.minY, width: max(200, right - area.minX), height: area.height)
        }
    }

    private func mainArea(_ pair: Pair) -> (CGRect, AXUIElement?) {
        let main = running(pair.mainID).flatMap { $0.isHidden ? nil : $0 }
        let mainWindow = main.flatMap(axWindow)
        return (mainWindow.flatMap(axFrame) ?? main.flatMap(largestWindow) ?? Self.screenArea(), mainWindow)
    }

    private func park(_ pair: Pair, _ w: AXUIElement) {
        var l = layout(pair, area: mainArea(pair).0)
        setFrame(w, l.closed)
        if let actual = axFrame(w)?.size, actual != l.closed.size {
            l = layout(pair, area: mainArea(pair).0, drawerSize: actual)
            setPos(w, l.closed.origin)
        }
    }

    private func present(_ s: DrawerSession, app: NSRunningApplication, window w: AXUIElement) {
        let pair = s.pair
        let (area, mainWindow) = mainArea(pair)

        var l = layout(pair, area: area)
        setFrame(w, l.closed)
        if let actual = axFrame(w)?.size, actual != l.closed.size {
            l = layout(pair, area: area, drawerSize: actual)
            setPos(w, l.closed.origin)
        }
        let start = CGRect(origin: axFrame(w)?.origin ?? l.closed.origin, size: l.open.size)
        (s.window, s.mainWindow, s.mainFrame, s.parked) = (w, mainWindow, area, start.origin)
        if pair.shrinkMain { OpenState.save(pair.id, mainFrame: area) }
        bringToFront(app, w)   // drawer in front, so the main window can shrink behind it
        let shrink = pair.shrinkMain ? mainWindow : nil

        // The drawer moves on the main thread every screen refresh; the main window is resized on a
        // background queue (latest frame wins), so a slow-to-redraw main app can't stall the slide.
        s.animator.run(duration: 0.28, curve: easeOutCubic, step: { e in
            let d = lerp(start, l.open, e)
            setPos(w, d.origin)
            // Overlap tapers to zero so the last frame is exactly the final size (no snap at the end).
            if let mw = shrink { s.resizer.request(mw, self.trackingMainFrame(pair, area: area, drawer: d, lead: 40 * (1 - e))) }
        }) { [weak self] in
            if let mw = shrink, let target = l.mainShrunk { s.resizer.request(mw, target) }
            bringToFront(app, w)   // in case the main app grabbed focus mid-slide
            s.lockedFrame = axFrame(w) ?? l.open
            s.onPopOut = { self?.popOut(s) }
            s.watchMoves(app: app, window: w)
        }
    }

    /// Slide the drawer back off its screen edge while the main window grows back behind it.
    func close(_ id: UUID) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        OpenState.clear(id)
        s.pending?.invalidate()
        s.stopWatching()
        s.lockedFrame = nil
        let app = running(s.pair.drawerID)
        guard let w = s.window, let f = axFrame(w) else { s.animator.stop(); app?.hide(); return }
        let parked = CGRect(origin: s.parked, size: f.size)
        let grow = s.pair.shrinkMain ? s.mainWindow : nil

        // The drawer must be the front window, or the main window would cover it as it grows back.
        if let app { bringToFront(app, w) }

        s.animator.run(duration: 0.24, curve: easeInCubic, step: { e in
            let d = lerp(f, parked, e)
            setPos(w, d.origin)
            // Overlap grows from zero so the first frame doesn't jump.
            if let mw = grow { s.resizer.request(mw, self.trackingMainFrame(s.pair, area: s.mainFrame, drawer: d, lead: 40 * e)) }
        }) {
            if let mw = grow { s.resizer.request(mw, s.mainFrame) }
            app?.hide()
            if let main = running(s.pair.mainID) { bringToFront(main, s.mainWindow) }
        }
    }

    /// The user dragged the drawer away: let it be a normal window and give the main window its space back.
    /// Pressing the shortcut in the main app docks it again.
    private func popOut(_ s: DrawerSession) {
        guard sessions[s.pair.id] === s else { return }
        sessions[s.pair.id] = nil
        OpenState.clear(s.pair.id)
        s.stopWatching()
        s.lockedFrame = nil
        if s.pair.shrinkMain, let mw = s.mainWindow { s.resizer.request(mw, s.mainFrame) }
    }

    /// Put things back immediately, without animating.
    private func restore(_ s: DrawerSession) {
        sessions[s.pair.id] = nil
        OpenState.clear(s.pair.id)
        s.pending?.invalidate()
        s.animator.stop()
        s.stopWatching()
        s.lockedFrame = nil
        running(s.pair.drawerID)?.hide()
        if s.pair.shrinkMain, let mw = s.mainWindow { setFrame(mw, s.mainFrame) }
    }

    /// Used when Drawer quits.
    func restoreNow() { sessions.values.forEach(restore) }

    /// If Drawer was killed or crashed with a tiled drawer open, the main window was left shrunk.
    /// Put it back to the size it had before, so the next open doesn't shrink it a second time.
    func recoverAfterCrash() {
        for (id, frame) in OpenState.all() {
            OpenState.clear(id)
            guard let pair = Config.shared.pairs.first(where: { $0.id == id }),
                  let main = running(pair.mainID), let mw = axWindow(main) else { continue }
            setFrame(mw, frame)
        }
    }

    private var warned = Set<String>()
    private func warnOtherSpace(_ id: String) {
        guard warned.insert(id).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "\(appName(id))'s window is on another desktop"
        alert.informativeText = """
            macOS doesn't let Drawer move windows between desktops. To have \(appName(id)) show up on whichever \
            desktop you're on, right-click its Dock icon → Options → Assign To: All Desktops.
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

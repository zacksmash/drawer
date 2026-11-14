import AppKit

/// Keyboard/mouse event tap for the shortcut and for blocking drawer resizes. A tap (rather than a Carbon
/// hotkey) can require the Globe/fn key and lets keystrokes pass through when no configured app is in front.
///
/// Tap = toggle. Hold (with "hold to peek" on) = show while held, hide on release.
///
/// The tap runs on its own thread and never waits on the main thread: while a tap callback runs, macOS
/// holds back ALL keyboard and mouse input. Anything slow (Accessibility calls into a busy app) happens on
/// the main thread asynchronously, and the callback only reads a small snapshot of state.
final class Hotkey {
    /// What the tap needs to decide, refreshed from the main thread.
    private struct Snapshot {
        var front: String?
        var handledFronts: Set<String> = []   // main apps with a drawer + apps of open drawers
        var lockedFrames: [CGRect] = []
        var resizeHandles: [(id: UUID, rect: CGRect)] = []
        var mainFrames: [(id: String, frame: CGRect)] = []   // main windows that have drawers open
        var shortcuts: [Shortcut] = []
        var hoverTarget = true
        var carouselFronts: Set<String> = []   // apps in a carousel (fn + swipe cycles them)
        var peek = true
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var tap: CFMachPort?

    // Tap-thread state.
    private var pressedAt: CFTimeInterval?   // set while we're swallowing a press of a shortcut key
    private var pressedKey: Int64 = -1
    private var blockingDrag = false
    private var resizing: UUID?              // drawer whose inner edge is being dragged
    private var resizeIsDoubleClick = false
    private let peekThreshold = 0.35
    private var swipeX: Double = 0           // fn + horizontal scroll travel in the current gesture
    private var swipeFired = false           // this gesture already cycled
    private var swipeLast: CFTimeInterval = 0
    private var swipeTarget: String?         // app the current fn-swipe gesture is for

    // Main-thread state.
    private var openedByPress: UUID?         // drawer this press opened, closed on release if it was a peek
    private var cycledByPress = false        // this press cycled a carousel, undone on release if it was a peek

    func install() {
        startRefreshing()
        let thread = Thread { [weak self] in self?.runTap() }
        thread.name = "Drawer event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Snapshot (main thread)

    private func startRefreshing() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
    }

    func refresh() {
        var s = Snapshot()
        s.front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        s.handledFronts = Set(Config.shared.pairs.map(\.mainID)).union(drawer.openAppIDs).union(carousels.memberIDs)
        s.lockedFrames = drawer.lockedFrames
        s.resizeHandles = drawer.resizeHandles
        s.mainFrames = drawer.mainFrames
        s.shortcuts = Config.shared.allShortcuts
        s.carouselFronts = carousels.memberIDs
        s.hoverTarget = Config.shared.hoverTarget
        s.peek = Config.shared.peek
        lock.lock(); snap = s; lock.unlock()
    }

    private func current() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    // MARK: Tap (own thread)

    /// Creates the tap once Accessibility is allowed, and tears it down the moment it's revoked: an active
    /// tap whose permission is pulled makes macOS reject every event passing through it (a frozen Mac)
    /// until it's gone. AXIsProcessTrusted() can't tell — it keeps answering "yes" for the rest of the
    /// process's life — so a fresh helper process asks instead (see liveTrusted).
    private func runTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        while true {
            while !liveTrusted() { Thread.sleep(forTimeInterval: 1) }
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: mask, callback: { _, type, event, ctx in
                let me = Unmanaged<Hotkey>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { Thread.sleep(forTimeInterval: 2); continue }
            tap = t
            let loop = CFRunLoopGetCurrent()!
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(loop, src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            // Watchdog off the tap thread (spawning the helper must never hold up input).
            let stop = NSLock(); var stopped = false
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            watchdog.schedule(deadline: .now() + 1, repeating: 1)
            watchdog.setEventHandler {
                guard !liveTrusted() else { return }
                stop.lock(); defer { stop.unlock() }
                guard !stopped else { return }
                stopped = true
                CGEvent.tapEnable(tap: t, enable: false)   // input flows again right away
                CFRunLoopStop(loop)
            }
            watchdog.resume()
            while true {   // CFRunLoopRun can also return on its own; only leave when the watchdog says so
                CFRunLoopRun()
                stop.lock(); let done = stopped; stop.unlock()
                if done { break }
            }
            watchdog.cancel()
            CFRunLoopRemoveSource(loop, src, .commonModes)
            CFMachPortInvalidate(t)
            tap = nil
            pressedAt = nil
            blockingDrag = false
        }
    }

    /// Returns true to swallow the event. Must stay fast and never block.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turned the tap off (slow callback, or permission pulled). Turning it back on is safe:
            // if the permission is gone, the watchdog removes the tap within a second.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let s = current()

        switch type {
        case .scrollWheel: return swipe(event, s)
        case .leftMouseDown:
            let p = event.location   // global top-left coords, same as Accessibility
            // The inner edge (facing the main window) resizes the drawer. Drawer does the resizing itself,
            // so the drawer and the main window move together and the app never fights it.
            if let h = s.resizeHandles.first(where: { $0.rect.contains(p) }) {
                resizing = h.id
                resizeIsDoubleClick = event.getIntegerValueField(.mouseEventClickState) >= 2
                let double = resizeIsDoubleClick
                DispatchQueue.main.async {   // double-click: back to the size before the last drag
                    if double { drawer.restorePreviousSize(h.id) } else { drawer.beginResize(h.id) }
                    self.refresh()
                }
                return true
            }
            // Swallow drags that start on an open drawer's other edges, so its app never starts a resize.
            blockingDrag = s.lockedFrames.contains { f in
                f.insetBy(dx: -8, dy: -8).contains(p) && !f.insetBy(dx: 5, dy: 5).contains(p)
            }
            // A press on a main window with drawers might start dragging it: let Drawer watch for that.
            if !blockingDrag, !s.lockedFrames.contains(where: { $0.contains(p) }),   // not on a drawer itself
               let hit = s.mainFrames.first(where: { $0.frame.contains(p) }) {
                DispatchQueue.main.async { drawer.mainPressed(hit.id) }
            }
            return blockingDrag
        case .leftMouseDragged:
            if let id = resizing {
                guard !resizeIsDoubleClick else { return true }
                let p = event.location
                DispatchQueue.main.async { drawer.resizeDrawer(id, to: p); self.refresh() }
                return true
            }
            return blockingDrag
        case .leftMouseUp:
            if let id = resizing {
                resizing = nil
                guard !resizeIsDoubleClick else { return true }
                DispatchQueue.main.async { drawer.finishResize(id); self.refresh() }
                return true
            }
            defer { blockingDrag = false }
            return blockingDrag
        default:
            break
        }

        let key = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            guard let start = pressedAt, key == pressedKey else { return false }
            pressedAt = nil
            let peeked = s.peek && CACurrentMediaTime() - start > peekThreshold   // held → it was a peek
            DispatchQueue.main.async {
                if peeked, let id = self.openedByPress { drawer.close(id) }
                if self.cycledByPress { carousels.keyReleased(peek: peeked) }
                self.openedByPress = nil
                self.cycledByPress = false
            }
            return true
        }

        if pressedAt != nil, key == pressedKey { return true }   // auto-repeat while held
        let flags = event.flags.intersection(Shortcut.modifierMask)
        guard let shortcut = s.shortcuts.first(where: { Int64($0.keyCode) == key && $0.cgFlags == flags }) else { return false }
        // Carousels follow the pointer (setting on); drawers always go with the app in front.
        let hovered = target(s).flatMap { s.carouselFronts.contains($0) ? $0 : nil }
        let front = s.front
        guard hovered != nil || front.map(s.handledFronts.contains) == true else { return false }
        pressedAt = CACurrentMediaTime()
        pressedKey = key
        DispatchQueue.main.async {
            if let c = [hovered, front].compactMap({ $0 }).first(where: { carousels.handles(front: $0, shortcut: shortcut) }) {
                carousels.cycle(front: c, shortcut: shortcut, held: true)   // ‹ / › in a carousel app
                self.openedByPress = nil
                self.cycledByPress = true
            } else {
                self.openedByPress = drawer.toggle(shortcut, target: front)
                self.cycledByPress = false
            }
            self.refresh()
        }
        return true
    }

    // MARK: fn + swipe (carousels)

    /// The carousel app a shortcut or swipe is for: the one under the pointer (setting on), else the one in front.
    private func target(_ s: Snapshot) -> String? {
        s.hoverTarget ? (appUnderPointer() ?? s.front) : s.front
    }

    /// Only the fn key held (no ⌃⌥⇧⌘).
    private func fnOnly(_ event: CGEvent) -> Bool {
        event.flags.intersection(Shortcut.modifierMask) == .maskSecondaryFn
    }

    private func cycle(_ front: String, forward: Bool) {
        DispatchQueue.main.async {
            carousels.cycle(front: front, forward: forward)
            self.refresh()
        }
    }

    /// fn + a sideways scroll (two fingers on a trackpad, one on a Magic Mouse) cycles once per gesture.
    /// Fingers moving left bring in the next app from the right.
    private func swipe(_ event: CGEvent, _ s: Snapshot) -> Bool {
        let now = CACurrentMediaTime()
        guard let e = NSEvent(cgEvent: event) else { return false }
        // A new gesture: fingers just touched, or (mice without phases) a pause in the scrolling.
        if e.phase.contains(.began) || (e.phase.isEmpty && e.momentumPhase.isEmpty && now - swipeLast > 0.3) {
            swipeX = 0; swipeFired = false; swipeTarget = nil
        }
        swipeLast = now
        guard fnOnly(event) else { return false }
        if swipeTarget == nil { swipeTarget = target(s) ?? "" }   // once per gesture
        guard let front = swipeTarget, s.carouselFronts.contains(front) else { return false }
        if swipeFired { return true }   // swallow the rest of this gesture, momentum included
        guard e.momentumPhase.isEmpty else { return false }   // coasting after a swipe that didn't cycle
        let dx = Double(e.scrollingDeltaX) * (e.hasPreciseScrollingDeltas ? 1 : 10)
        let dy = Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 10)
        guard abs(dx) > abs(dy) * 0.5 else { return false }
        swipeX += e.isDirectionInvertedFromDevice ? dx : -dx   // > 0: fingers moving right
        if abs(swipeX) > 18 {
            swipeFired = true
            cycle(front, forward: swipeX < 0)
        }
        return true
    }

}

/// Whether Drawer is allowed Accessibility *right now*. Runs Drawer's own binary with --trust-check:
/// a new process gets a fresh answer, while this one's AXIsProcessTrusted() stays stuck on "yes".
func liveTrusted() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--trust-check"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return AXIsProcessTrusted() }
    let deadline = Date().addingTimeInterval(2)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning { p.terminate(); return true }   // no answer: assume nothing changed
    return p.terminationStatus == 0
}

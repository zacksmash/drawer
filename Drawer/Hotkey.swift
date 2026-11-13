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
        var shortcuts: [Shortcut] = [.default]
        var peek = true
    }

    private let lock = NSLock()
    private var snap = Snapshot()
    private var tap: CFMachPort?

    // Tap-thread state.
    private var pressedAt: CFTimeInterval?   // set while we're swallowing a press of a shortcut key
    private var pressedKey: Int64 = -1
    private var blockingDrag = false
    private let peekThreshold = 0.35

    // Main-thread state.
    private var openedByPress: UUID?         // drawer this press opened, closed on release if it was a peek

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
        s.handledFronts = Set(Config.shared.pairs.map(\.mainID)).union(drawer.openAppIDs)
        s.lockedFrames = drawer.lockedFrames
        s.shortcuts = Config.shared.allShortcuts
        s.peek = Config.shared.peek
        lock.lock(); snap = s; lock.unlock()
    }

    private func current() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    // MARK: Tap (own thread)

    private func runTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        while tap == nil {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, ctx in
                let me = Unmanaged<Hotkey>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if tap == nil { Thread.sleep(forTimeInterval: 2) }   // no Accessibility permission yet
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        CFRunLoopRun()
    }

    /// Returns true to swallow the event. Must stay fast and never block.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let s = current()

        switch type {
        case .leftMouseDown:
            // Swallow drags that start on an open drawer's edges, so its app never starts a resize.
            let p = event.location   // global top-left coords, same as Accessibility
            blockingDrag = s.lockedFrames.contains { f in
                f.insetBy(dx: -8, dy: -8).contains(p) && !f.insetBy(dx: 5, dy: 5).contains(p)
            }
            return blockingDrag
        case .leftMouseDragged:
            return blockingDrag
        case .leftMouseUp:
            defer { blockingDrag = false }
            return blockingDrag
        default:
            break
        }

        let key = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            guard let start = pressedAt, key == pressedKey else { return false }
            pressedAt = nil
            if s.peek, CACurrentMediaTime() - start > peekThreshold {
                DispatchQueue.main.async {   // held → it was a peek
                    if let id = self.openedByPress { drawer.close(id) }
                    self.openedByPress = nil
                }
            }
            return true
        }

        if pressedAt != nil, key == pressedKey { return true }   // auto-repeat while held
        let flags = event.flags.intersection(Shortcut.modifierMask)
        guard let shortcut = s.shortcuts.first(where: { Int64($0.keyCode) == key && $0.cgFlags == flags }),
              let front = s.front, s.handledFronts.contains(front) else { return false }
        pressedAt = CACurrentMediaTime()
        pressedKey = key
        DispatchQueue.main.async {
            self.openedByPress = drawer.toggle(shortcut)
            self.refresh()
        }
        return true
    }
}

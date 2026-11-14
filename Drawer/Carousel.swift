import AppKit

/// Carousels: apps that take turns in the main app's spot. fn⌃. slides the next one in from the right,
/// fn⌃, the previous one from the left, wrapping around. The spot is wherever the app showing now is
/// (so moving or resizing it carries the whole carousel along); the one being replaced hides once covered.
final class CarouselController {
    private var busy: Set<UUID> = []
    private let animator = Animator()

    /// Whether `shortcut` cycles a carousel while `front` is in front.
    func handles(front: String?, shortcut: Shortcut) -> Bool {
        guard Config.shared.carousel(containing: front) != nil else { return false }
        return shortcut == Config.shared.shortcut(for: .left) || shortcut == Config.shared.shortcut(for: .right)
    }

    var memberIDs: Set<String> { Set(Config.shared.carousels.filter { $0.members.count > 1 }.flatMap(\.members)) }

    func cycle(front: String?, shortcut: Shortcut) {
        cycle(front: front, forward: shortcut == Config.shared.shortcut(for: .right))
    }

    /// Forward = the next app, coming in from the right.
    func cycle(front: String?, forward: Bool) {
        guard AXIsProcessTrusted() else { drawer.promptAccessibility(); return }
        guard let front, let c = Config.shared.carousel(containing: front), !busy.contains(c.id),
              let cur = c.members.firstIndex(of: front) else { return }
        let members = c.members
        let next = (cur + (forward ? 1 : -1) + members.count) % members.count
        let curApp = running(front)
        // The spot: the current app's window as it is now. If it's the main app with drawers open,
        // drop those and use its full frame.
        guard let frame = drawer.releaseMain(front) ?? curApp.flatMap(axWindow).flatMap(axFrame) else { return }
        busy.insert(c.id)
        bringIn(members[next], frame: frame, from: forward ? .right : .left) { [weak self] ok in
            self?.busy.remove(c.id)
            if ok { curApp?.hide() }
        }
    }

    /// Where the incoming window starts: one tile gap out on that side, so it barely moves outside the spot.
    /// (8pt even with tile margins off, so there's still a slide.)
    private func entryFrame(_ frame: CGRect, from edge: Edge) -> CGRect {
        let gap = max(tileGap, 8)
        switch edge {
        case .left: return frame.offsetBy(dx: -gap, dy: 0)
        case .right: return frame.offsetBy(dx: gap, dy: 0)
        case .bottom: return frame.offsetBy(dx: 0, dy: gap)
        }
    }

    /// Launch or unhide `id`, park its window just off-screen on `edge` at `frame`'s size, then slide it in.
    private func bringIn(_ id: String, frame: CGRect, from edge: Edge, done: @escaping (Bool) -> Void) {
        let started = CACurrentMediaTime()
        var parked = false, reopened = false
        let closed = entryFrame(frame, from: edge)
        if running(id) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { done(false); return }
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = false
            conf.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: conf)
        }
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] t in
            let elapsed = CACurrentMediaTime() - started
            guard let self, elapsed < 10 else { t.invalidate(); done(false); return }
            guard let app = running(id), app.isFinishedLaunching else { return }
            if !parked {
                guard let w = axWindow(app) else {
                    // No window: ask for one (hidden, so it can't flash where it last was).
                    if !app.isHidden { app.hide() }
                    if !reopened, elapsed > 0.3, let url = app.bundleURL {
                        reopened = true
                        let conf = NSWorkspace.OpenConfiguration()
                        conf.activates = false
                        conf.hides = true
                        NSWorkspace.shared.openApplication(at: url, configuration: conf)
                    }
                    return
                }
                if !app.isHidden { app.hide(); return }
                setFrame(w, closed)
                parked = true
                app.unhide()
                return
            }
            if app.isHidden { app.unhide(); return }
            guard let w = axWindow(app) else { return }
            t.invalidate()
            setSize(w, frame.size)
            let start = CGRect(origin: axFrame(w)?.origin ?? closed.origin, size: frame.size)
            bringToFront(app, w)
            self.animator.run(duration: 0.4, curve: easeOutBack, step: { e in
                setPos(w, lerp(start, frame, e).origin)
            }) {
                setFrame(w, frame)
                bringToFront(app, w)
                done(true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
    }
}

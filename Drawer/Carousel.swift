import AppKit

/// Carousels: apps that take turns in the main app's spot. fn⌃. slides the next one in from the right,
/// fn⌃, the previous one from the left, wrapping around. The spot is wherever the app showing now is
/// (so moving or resizing it carries the whole carousel along); the one being replaced hides once covered.
final class CarouselController {
    private var busy: Set<UUID> = []
    private let animator = Animator()
    /// The last swap, so a peek (shortcut held) can undo it on release.
    private var last: (carousel: UUID, from: String, to: String, forward: Bool)?
    private var returnWanted = false
    /// While the shortcut that cycled is still held, the app it replaced stays under the new one (so a
    /// peek can back out over it); it's hidden once the key comes up as a tap.
    private var keyHeld = false
    private var underneath: NSRunningApplication?

    /// Whether `shortcut` cycles a carousel while `front` is in front.
    func handles(front: String?, shortcut: Shortcut) -> Bool {
        guard Config.shared.carousel(containing: front) != nil else { return false }
        return shortcut == Config.shared.shortcut(for: .left) || shortcut == Config.shared.shortcut(for: .right)
    }

    var memberIDs: Set<String> { Set(Config.shared.carousels.filter { $0.members.count > 1 }.flatMap(\.members)) }

    /// `held`: from a key press, which may turn into a peek.
    func cycle(front: String?, shortcut: Shortcut, held: Bool = false) {
        cycle(front: front, forward: shortcut == Config.shared.shortcut(for: .right), held: held)
    }

    /// Forward = the next app, coming in from the right.
    func cycle(front: String?, forward: Bool, held: Bool = false) {
        guard AXIsProcessTrusted() else { drawer.promptAccessibility(); return }
        guard let front, let c = Config.shared.carousel(containing: front), !busy.contains(c.id),
              let cur = c.members.firstIndex(of: front) else { return }
        let members = c.members
        let next = (cur + (forward ? 1 : -1) + members.count) % members.count
        let curApp = running(front)
        // The spot: the current app's window as it is now. If it's the main app with drawers open,
        // drop those and use its full frame.
        guard let frame = drawer.releaseMain(front) ?? curApp.flatMap(axWindow).flatMap(axFrame) else { return }
        last = (c.id, front, members[next], forward)
        returnWanted = false
        underneath?.hide(); underneath = nil
        keyHeld = held
        swap(c.id, from: curApp, to: members[next], frame: frame, edge: forward ? .right : .left)
    }

    /// The cycling shortcut came up: a peek goes back; a tap keeps the new app and hides the old one.
    func keyReleased(peek: Bool) {
        keyHeld = false
        if peek { endPeek() } else { underneath?.hide(); underneath = nil }
    }

    /// The user switched to `app` itself (Dock, ⌘-Tab…). If it's in a carousel and another member is
    /// showing, put it right in that member's spot and hide that one. Returns whether it did.
    func adopt(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, let c = Config.shared.carousel(containing: id), !busy.contains(c.id) else { return false }
        let others = c.members.filter { $0 != id }.compactMap(running).filter { !$0.isHidden }
        guard let shown = frontmostWindowOwner(among: Set(others.map(\.processIdentifier))),
              let other = others.first(where: { $0.processIdentifier == shown }) else { return false }
        guard let frame = other.bundleIdentifier.flatMap({ drawer.releaseMain($0) }) ?? axWindow(other).flatMap(axFrame)
        else { return false }
        busy.insert(c.id)
        // Its window may not exist yet (just launched): wait briefly for it.
        let started = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] t in
            guard CACurrentMediaTime() - started < 5 else { t.invalidate(); self?.busy.remove(c.id); return }
            guard app.isFinishedLaunching, let w = axWindow(app) else { return }
            t.invalidate()
            setFrame(w, frame)
            other.hide()
            self?.busy.remove(c.id)
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
        return true
    }

    /// The shortcut was held and let go: go back to the app that was showing before it was pressed.
    func endPeek() {
        guard let l = last else { return }
        if busy.contains(l.carousel) { returnWanted = true; return }   // once the slide in finishes
        last = nil
        let cur = running(l.to)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == l.to,
              let frame = cur.flatMap(axWindow).flatMap(axFrame) else { return }
        // Play the same animation backwards: the peeked app backs out the way it came.
        swap(l.carousel, from: cur, to: l.from, frame: frame, edge: l.forward ? .right : .left, reversed: true)
    }

    /// Slide `to` in over `from` at `frame`, then hide `from`. `edge`: the side the incoming app enters
    /// from — or, `reversed`, the side `from` backs out to.
    private func swap(_ cid: UUID, from: NSRunningApplication?, to: String, frame: CGRect, edge: Edge,
                      reversed: Bool = false) {
        busy.insert(cid)
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            // Still held: leave the old app underneath for a peek to back out over.
            if ok, !reversed, self.keyHeld || self.returnWanted { self.underneath = from }
            else if ok { from?.hide() }
            self.busy.remove(cid)
            if self.returnWanted { self.returnWanted = false; self.endPeek() }
        }
        if reversed { backOut(from, to: to, frame: frame, toward: edge, done: finish) }
        else { bringIn(to, frame: frame, from: edge, done: finish) }
    }

    /// Backwards: `to` goes back in the spot underneath, and `app`'s window backs out toward `edge`
    /// and disappears, revealing it.
    private func backOut(_ app: NSRunningApplication?, to: String, frame: CGRect, toward edge: Edge,
                         done: @escaping (Bool) -> Void) {
        guard let app, let w = axWindow(app), let back = running(to), let bw = axWindow(back) else {
            bringIn(to, frame: frame, from: edge, animated: false, done: done); return
        }
        if underneath?.processIdentifier == back.processIdentifier, !back.isHidden {
            underneath = nil   // still right there under the peeked window
        } else {
            setFrame(bw, frame)   // while still hidden
            back.unhide()
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)   // keep the peeked window on top of it
        }
        let end = entryFrame(frame, from: edge)
        animator.run(duration: 0.2, curve: glide, step: { e in
            setPos(w, lerp(frame, end, e).origin)
        }) {
            bringToFront(back, bw)
            app.hide()
            setFrame(w, frame)   // back in place for next time
            done(true)
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

    /// Launch or unhide `id`, park its window just outside the spot on `edge`, then slide it in.
    /// Not `animated`: put it straight in the spot and in front.
    private func bringIn(_ id: String, frame: CGRect, from edge: Edge,
                         animated: Bool = true, done: @escaping (Bool) -> Void) {
        let started = CACurrentMediaTime()
        var parked = false, reopened = false
        let closed = animated ? entryFrame(frame, from: edge) : frame
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
                // Activating it unhides it already in front; a plain unhide can show it behind the current
                // app for a frame before it's raised (a flicker).
                bringToFront(app, w)
                return
            }
            if app.isHidden { app.unhide(); return }
            guard let w = axWindow(app) else { return }
            t.invalidate()
            guard animated else {
                setFrame(w, frame)
                bringToFront(app, w)
                done(true)
                return
            }
            setSize(w, frame.size)
            let start = CGRect(origin: axFrame(w)?.origin ?? closed.origin, size: frame.size)
            bringToFront(app, w)
            self.animator.run(duration: 0.3, curve: glide, step: { e in
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

import AppKit

/// Carousels: apps that take turns in the main app's spot. The right-edge shortcut (fn⌃. by default) switches to
/// the next one, the left-edge one (fn⌃,) to the previous one, wrapping around, and the switcher shows which; or
/// click one in the switcher. Switches are instant. The spot is wherever the app showing now is (so moving or
/// resizing it carries the whole carousel along); the one being replaced hides once covered.
final class CarouselController {
    private var busy: Set<UUID> = [] { didSet { switcher.refresh() } }   // the switcher stays out of the way while a swap runs
    var isBusy: Bool { !busy.isEmpty }
    /// Where each app was when the carousel hid it: its window and the desktops it was on. A hidden app's
    /// window stays on that desktop, and activating it would switch there, so it's fetched over first.
    private var putAway: [String: (window: AXUIElement, desktops: Set<UInt64>)] = [:]
    /// The last switch by shortcut, so a peek (shortcut held) can undo it on release.
    private var last: (carousel: UUID, from: String, to: String)?
    private var returnWanted = false   // the peek was let go before its switch finished: undo it once it has

    /// Whether `shortcut` cycles a carousel while `front` is in front.
    func handles(front: String?, shortcut: Shortcut) -> Bool {
        guard Config.shared.carousel(containing: front) != nil else { return false }
        return shortcut == Config.shared.shortcut(for: .left) || shortcut == Config.shared.shortcut(for: .right)
    }

    var memberIDs: Set<String> { Set(Config.shared.carousels.filter { $0.members.count > 1 }.flatMap(\.members)) }

    func cycle(front: String?, shortcut: Shortcut) {
        cycle(front: front, forward: shortcut == Config.shared.shortcut(for: .right))
    }

    /// Forward = the next app. The switcher opens with it highlighted as it comes in.
    func cycle(front: String?, forward: Bool) {
        guard let front, let c = Config.shared.carousel(containing: front),
              let cur = c.members.firstIndex(of: front), !busy.contains(c.id) else { return }
        let next = c.members[(cur + (forward ? 1 : -1) + c.members.count) % c.members.count]
        switcher.showSwitch(to: next)
        go(c, from: front, to: next, peek: true)
    }

    /// Switch straight to `target` (clicked in the switcher).
    func jump(front: String, to target: String) {
        guard let c = Config.shared.carousel(containing: front), c.members.contains(target), target != front else { return }
        go(c, from: front, to: target, peek: false)
    }

    /// `peek`: remember it, so letting go of a held shortcut can undo it.
    private func go(_ c: Carousel, from front: String, to next: String, peek: Bool) {
        guard AXIsProcessTrusted() else { drawer.promptAccessibility(); return }
        guard !busy.contains(c.id) else { return }
        let curApp = running(front)
        // The spot: the current app's window as it is now. If it's the main app with drawers open,
        // drop those and use its full frame.
        guard let frame = drawer.releaseMain(front) ?? curApp.flatMap(axWindow).flatMap(axFrame) else { return }
        returnWanted = false
        last = peek ? (c.id, front, next) : nil
        swapInPlace(c.id, from: curApp, to: next, frame: frame)
    }

    /// Put `to` in the spot in front of `from`, then hide `from`: an instant switch. Two windows stacked on the
    /// spot would show a doubled, darker shadow until the old one hides (which waits for the new app to be in
    /// front), so the old one moves off every screen the moment the new one is up, and back once it's hidden.
    private func swapInPlace(_ cid: UUID, from: NSRunningApplication?, to: String, frame: CGRect) {
        busy.insert(cid)
        bringIn(to, frame: frame) { [weak self] ok in
            guard let self else { return }
            guard ok, let from else { self.finished(cid); return }
            let ow = axWindow(from)
            if let ow { setPos(ow, CGPoint(x: (screenFrames().map(\.maxX).max() ?? 0) + 200, y: frame.minY)) }
            // Hide it only once the new app is in front, so macOS doesn't bring some other app forward.
            self.hideOnceBehind(from) {
                if let ow { setFrame(ow, frame) }   // hidden, back in the spot for next time
                self.finished(cid)
            }
        }
    }

    private func finished(_ cid: UUID) {
        busy.remove(cid)
        if returnWanted { returnWanted = false; endPeek() }
    }

    /// Hide `app`, noting where its window is first (see putAway).
    private func hide(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier else { return }
        if !app.isHidden, let w = axWindow(app) {
            let d = desktops(of: w)
            if !d.isEmpty { putAway[id] = (w, d) }
        }
        app.hide()
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
            self?.hide(other)
            self?.busy.remove(c.id)
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
        return true
    }

    /// The shortcut was held and let go: go back to the app that was showing before it was pressed.
    func endPeek() {
        guard let l = last else { return }
        if busy.contains(l.carousel) { returnWanted = true; return }   // not in yet: go back once it is
        last = nil
        let cur = running(l.to)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == l.to,
              let frame = cur.flatMap(axWindow).flatMap(axFrame) else { return }
        switcher.showSwitch(to: l.from)
        busy.insert(l.carousel)
        backOut(cur, to: l.from, frame: frame) { [weak self] ok in
            if ok { self?.hide(cur) }
            self?.busy.remove(l.carousel)
        }
    }

    /// Peek let go: put `to` back in front at `frame` (bringing it in afresh if a window is missing).
    private func backOut(_ app: NSRunningApplication?, to: String, frame: CGRect, done: @escaping (Bool) -> Void) {
        guard let app, let w = axWindow(app), let back = running(to), axWindow(back) != nil else {
            bringIn(to, frame: frame, done: done); return
        }
        retreat(w, app: app, home: frame, revealing: back) { done(true) }
    }

    /// Peek let go: hide the peeked app on the spot (no animation), leaving `back` in front.
    private func retreat(_ w: AXUIElement, app: NSRunningApplication, home: CGRect,
                         revealing back: NSRunningApplication?, done: @escaping () -> Void) {
        if let back, let bw = axWindow(back) {
            // Hidden as the peeked app came in: put it in place while still hidden, then activate it, which
            // unhides it already in front (a plain unhide shows it behind the peeked app for a frame).
            if back.isHidden { setFrame(bw, home) }
            bringToFront(back, bw)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if back.isHidden { back.unhide() } }   // just in case
        }
        hideOnceBehind(app) { setFrame(w, home) }   // in place for next time
        done()
    }

    /// Hide `app` once it's no longer in front. Hiding the app in front makes macOS bring forward some
    /// other app first, which flashes on screen.
    private func hideOnceBehind(_ app: NSRunningApplication, then: @escaping () -> Void = {}) {
        let started = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.008, repeats: true) { [unowned self] t in
            guard !app.isActive || CACurrentMediaTime() - started > 0.5 else { return }
            t.invalidate()
            self.hide(app)
            then()
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
    }

    /// Launch or unhide `id` and put its window in the spot (`frame`) and in front, instantly: placed while still
    /// hidden, so it can't show where it last was, even for a frame.
    private func bringIn(_ id: String, frame: CGRect, done: @escaping (Bool) -> Void) {
        let started = CACurrentMediaTime()
        var parked = false, reopened = false, activated = false
        var parkedAt: CFTimeInterval = 0
        if running(id) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { done(false); return }
            openHidden(url)
        }
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] t in
            let elapsed = CACurrentMediaTime() - started
            guard let self, elapsed < 10 else { t.invalidate(); done(false); return }
            guard let app = running(id), app.isFinishedLaunching else { return }
            if !parked {
                // Hidden on a desktop that isn't showing now (the user moved on since): bringing it forward would
                // switch to that desktop, so fetch its window over first, then start again from here.
                if let away = self.putAway[id], app.isHidden, away.desktops.isDisjoint(with: visibleDesktops()),
                   axFrame(away.window) != nil {
                    t.invalidate()
                    self.putAway[id] = nil
                    _ = bringOver(app, away.window, fallback: nil, place: { setFrame(away.window, frame) }) { [weak self] ok in
                        guard ok else { drawer.warnOtherSpace(id); done(false); return }
                        self?.bringIn(id, frame: frame, done: done)
                    }
                    return
                }
                guard let w = axWindow(app) else {
                    // No window: ask for one (hidden, so it can't flash where it last was).
                    if !app.isHidden { app.hide() }
                    if !reopened, elapsed > 0.3, let url = app.bundleURL {
                        reopened = true
                        openHidden(url)
                    }
                    return
                }
                if !app.isHidden { app.hide(); return }
                if isMinimized(w) { setMinimized(w, false); return }   // from the Dock, unseen: no genie
                setFrame(w, frame)
                parked = true
                parkedAt = CACurrentMediaTime()
                return
            }
            // Bring it forward once its window has taken the spot, only once (activating again re-raises it: a
            // hitch), and finish once it's in front. Activating unhides it already in front; a plain unhide can
            // show it behind the current app for a frame first.
            guard let w = axWindow(app) else { return }
            let waited = CACurrentMediaTime() - parkedAt
            if !activated {
                guard axFrame(w).map({ near($0, frame, within: 2) }) == true || waited > 0.1 else { return }
                bringToFront(app, w)
                activated = true
                return
            }
            guard (app.isActive && !app.isHidden) || waited > 0.4 else { return }
            t.invalidate()
            if app.isHidden { app.unhide() }
            done(true)
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
    }
}

import AppKit
import ScreenCaptureKit

/// Carousels: apps that take turns in the main app's spot. fn⌃. slides the next one in from the right,
/// fn⌃, the previous one from the left, wrapping around. The spot is wherever the app showing now is
/// (so moving or resizing it carries the whole carousel along); the one being replaced hides once covered.
final class CarouselController {
    private var busy: Set<UUID> = []
    private let animator = Animator()
    /// The last swap, so a peek (shortcut held) can undo it on release.
    private var last: (carousel: UUID, from: String, to: String, forward: Bool)?
    private var returnWanted = false

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
        last = (c.id, front, members[next], forward)
        returnWanted = false
        swap(c.id, from: curApp, to: members[next], frame: frame, edge: forward ? .right : .left)
    }

    /// The shortcut was held and let go: go back to the app that was showing before it was pressed.
    func endPeek() {
        guard let l = last else { return }
        if busy.contains(l.carousel) { returnWanted = true; return }   // once the slide in finishes
        last = nil
        let cur = running(l.to)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == l.to,
              let frame = cur.flatMap(axWindow).flatMap(axFrame) else { return }
        swap(l.carousel, from: cur, to: l.from, frame: frame, edge: l.forward ? .left : .right)
    }

    /// Slide `to` in over `from` at `frame`, crossfading `from` out when allowed, then hide `from`.
    private func swap(_ cid: UUID, from: NSRunningApplication?, to: String, frame: CGRect, edge: Edge) {
        busy.insert(cid)
        snapshot(from, frame: frame) { [weak self] image in
            guard let self else { return }
            let overlay = image.map { FadeOverlay(image: $0, frame: frame) }
            self.bringIn(to, frame: frame, from: edge, overlay: overlay) { ok in
                if ok { from?.hide() }
                overlay?.close()
                self.busy.remove(cid)
                if self.returnWanted { self.returnWanted = false; self.endPeek() }
            }
        }
    }

    /// A picture of `app`'s window, to fade out over the incoming one. Only with the fade turned on and
    /// Screen Recording allowed; otherwise nil straight away.
    private func snapshot(_ app: NSRunningApplication?, frame: CGRect, done: @escaping (CGImage?) -> Void) {
        guard Config.shared.carouselFade, CGPreflightScreenCaptureAccess(), let pid = app?.processIdentifier else {
            done(nil); return
        }
        let finish: (CGImage?) -> Void = { img in DispatchQueue.main.async { done(img) } }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            func off(_ r: CGRect) -> CGFloat { abs(r.minX - frame.minX) + abs(r.minY - frame.minY) + abs(r.width - frame.width) }
            guard let w = content?.windows
                .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
                .min(by: { off($0.frame) < off($1.frame) }), off(w.frame) < 40 else { finish(nil); return }
            let cfg = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.frame.width >= frame.width }?.backingScaleFactor ?? 2
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                             configuration: cfg) { img, _ in finish(img) }
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
    private func bringIn(_ id: String, frame: CGRect, from edge: Edge, overlay: FadeOverlay? = nil,
                         done: @escaping (Bool) -> Void) {
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
            let began = CACurrentMediaTime()
            self.animator.run(duration: 0.4, curve: easeOutBack, step: { e in
                setPos(w, lerp(start, frame, e).origin)
                overlay?.alpha = 1 - min((CACurrentMediaTime() - began) / 0.25, 1)
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

/// A borderless picture of the outgoing window sitting over it, faded out to crossfade into the next app.
/// (Other apps' windows can't be made see-through directly.)
final class FadeOverlay {
    private let window: NSWindow

    init(image: CGImage, frame: CGRect) {   // frame in Accessibility (top-left) coordinates
        let primaryH = NSScreen.screens[0].frame.height
        let r = NSRect(x: frame.minX, y: primaryH - frame.maxY, width: frame.width, height: frame.height)
        window = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSImageView(frame: NSRect(origin: .zero, size: r.size))
        view.image = NSImage(cgImage: image, size: r.size)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
    }

    var alpha: Double {
        get { window.alphaValue }
        set { window.alphaValue = newValue }
    }

    func close() { window.orderOut(nil) }
}

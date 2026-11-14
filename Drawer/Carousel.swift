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

    /// Bring `to` in over `from` at `frame` in the chosen style, then hide `from`. `edge`: the side the
    /// incoming app enters from — or, `reversed`, the side `from` backs out to (the animation runs backwards).
    private func swap(_ cid: UUID, from: NSRunningApplication?, to: String, frame: CGRect, edge: Edge,
                      reversed: Bool = false) {
        busy.insert(cid)
        var style = Config.shared.carouselStyle
        if style.needsCapture, !CGPreflightScreenCaptureAccess() { style = .slide }
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            if ok { from?.hide() }
            self.busy.remove(cid)
            if self.returnWanted { self.returnWanted = false; self.endPeek() }
        }
        let plain = { [self] in
            if reversed { backOut(from, to: to, frame: frame, toward: edge, done: finish) }
            else { bringIn(to, frame: frame, from: edge, done: finish) }
        }
        guard style.needsCapture, let pid = from?.processIdentifier else { plain(); return }
        capture(pid: pid, frame: frame) { [weak self] current in
            guard let self else { return }
            guard let current else { plain(); return }
            let overlay = Transition(frame: frame, current: current)
            if style == .slideFade, !reversed {
                self.bringIn(to, frame: frame, from: edge, overlay: overlay) { ok in overlay.close(); finish(ok) }
                return
            }
            // Played out in pictures over the spot: put the real window in place underneath first,
            // then animate the pictures and lift them off.
            self.bringIn(to, frame: frame, from: edge, animated: false) { ok in
                guard ok else { overlay.close(); finish(false); return }
                from?.hide()
                let play: (CGImage?) -> Void = { other in
                    overlay.play(style, edge: edge, other: other, reversed: reversed) { overlay.close(); finish(true) }
                }
                guard style.needsIncoming || reversed, let otherPid = running(to)?.processIdentifier else { play(nil); return }
                // Give a just-shown window a moment to draw before picturing it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.capture(pid: otherPid, frame: frame, done: play)
                }
            }
        }
    }

    /// Plain Slide, backwards: `app`'s window backs out a little toward `edge`, then `to` takes the spot.
    private func backOut(_ app: NSRunningApplication?, to: String, frame: CGRect, toward edge: Edge,
                         done: @escaping (Bool) -> Void) {
        guard let w = app.flatMap(axWindow) else { bringIn(to, frame: frame, from: edge, animated: false, done: done); return }
        let end = entryFrame(frame, from: edge)
        animator.run(duration: 0.15, curve: glide, step: { e in
            setPos(w, lerp(frame, end, e).origin)
        }) { [weak self] in
            self?.bringIn(to, frame: frame, from: edge, animated: false) { ok in
                app?.hide()
                setFrame(w, frame)   // back in place for next time, while hidden
                done(ok)
            }
        }
    }

    /// A picture of `pid`'s window at `frame` (Screen Recording), or nil.
    private func capture(pid: pid_t, frame: CGRect, done: @escaping (CGImage?) -> Void) {
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

    /// Launch or unhide `id`, park its window just outside the spot on `edge`, then slide it in
    /// (fading `overlay` out meanwhile). Not `animated`: put it straight in the spot and in front.
    private func bringIn(_ id: String, frame: CGRect, from edge: Edge, overlay: Transition? = nil,
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
                app.unhide()
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
            let began = CACurrentMediaTime()
            self.animator.run(duration: 0.3, curve: glide, step: { e in
                setPos(w, lerp(start, frame, e).origin)
                overlay?.fadeOut(min((CACurrentMediaTime() - began) / 0.25, 1))
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

/// Pictures of the outgoing (and incoming) windows in a borderless window over the spot, animated
/// with Core Animation and clipped to the spot. Other apps' windows can only be moved, so anything
/// else (fading, scaling, flipping, staying inside the spot) is played out on pictures of them.
final class Transition {
    private let window: NSWindow
    private let root = CALayer()
    private let current = CALayer()   // the window showing when it started
    private let currentImage: CGImage
    private let animator = Animator()

    init(frame: CGRect, current image: CGImage) {   // frame in Accessibility (top-left) coordinates
        currentImage = image
        let primaryH = NSScreen.screens[0].frame.height
        let r = NSRect(x: frame.minX, y: primaryH - frame.maxY, width: frame.width, height: frame.height)
        window = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: r.size))
        view.wantsLayer = true
        window.contentView = view
        root.frame = view.bounds
        root.masksToBounds = true
        // Clip to the window's own rounded corners, so pictures sliding in never show a square corner.
        root.cornerRadius = Transition.cornerRadius(of: image, scale: window.backingScaleFactor)
        root.cornerCurve = .continuous
        view.layer?.addSublayer(root)
        configure(current, image)
        root.addSublayer(current)
        window.orderFrontRegardless()
    }

    /// The window's corner radius, read off its picture: along the top row, the corner is see-through up
    /// to where the curve meets the edge.
    private static func cornerRadius(of image: CGImage, scale: CGFloat) -> CGFloat {
        let w = min(image.width, 160), rows = 2
        var px = [UInt8](repeating: 0, count: w * rows * 4)
        guard let ctx = CGContext(data: &px, width: w, height: rows, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 10 }
        // Draw so the image's top rows land in this small context (CG's origin is bottom-left).
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(rows - image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        var x = 0   // memory row 0 is the image's very top row
        while x < w, px[x * 4 + 3] < 128 { x += 1 }
        guard x > 0, x < w else { return 10 }
        // The top row (half a pixel down) meets the curve at x ≈ r − √r; solve for r, erring a touch larger.
        let r = Double(x) + Double(x).squareRoot() + 1
        return CGFloat(r) / scale
    }

    private func configure(_ l: CALayer, _ image: CGImage) {
        l.frame = root.bounds
        l.contents = image
        l.contentsGravity = .resize
        l.contentsScale = window.backingScaleFactor
    }

    /// For Slide and fade: the picture of the outgoing window fades as the real next one slides in.
    func fadeOut(_ p: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        current.opacity = Float(1 - p)
        CATransaction.commit()
    }

    /// Play `style` with the incoming app entering from `edge`. `other` is a picture of the other window
    /// (the incoming one; or, `reversed`, the one coming back). `reversed` runs the animation backwards,
    /// so the current app backs out to `edge`. The real window that ends up showing already sits underneath,
    /// so wherever the pictures leave a gap it shows through.
    func play(_ style: CarouselStyle, edge: Edge, other image: CGImage?, reversed: Bool, done: @escaping () -> Void) {
        // Roles as in the forward animation: `outgoing` is covered or leaves, `incoming` arrives.
        let otherLayer = CALayer()
        if let image { configure(otherLayer, image) }
        let outgoing: CALayer, incoming: CALayer?
        let outImage: CGImage
        if reversed {
            guard let image else { return play(.crossfade, edge: edge, other: nil, reversed: false, done: done) }
            (outgoing, incoming, outImage) = (otherLayer, current, image)
        } else {
            if image == nil, style.needsIncoming { return play(.crossfade, edge: edge, other: nil, reversed: false, done: done) }
            (outgoing, incoming, outImage) = (current, image == nil ? nil : otherLayer, currentImage)
        }
        // Stacking: fades put the outgoing one on top; slides put the incoming one on top.
        let fades: [CarouselStyle] = [.zoom, .crossfade, .slideFade, .slide]
        let bottom = incoming.map { fades.contains(style) ? $0 : outgoing }, top = fades.contains(style) ? outgoing : incoming
        for l in [bottom, top].compactMap({ $0 }) { l.removeFromSuperlayer(); root.addSublayer(l) }
        if let incoming, !fades.contains(style) {
            incoming.shadowColor = NSColor.black.cgColor
            incoming.shadowOpacity = style == .push ? 0 : style == .parallax ? 0.5 : 0.3
            incoming.shadowRadius = style == .parallax ? 28 : 14
            incoming.shadowOffset = .zero
            incoming.shadowPath = CGPath(roundedRect: root.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        }
        // Darkening that follows the outgoing window's shape (its rounded corners stay clear).
        let dim = CALayer()
        dim.frame = root.bounds
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        let mask = CALayer()
        configure(mask, outImage)
        dim.mask = mask
        outgoing.addSublayer(dim)
        // Styles that shrink or turn the pictures need a backdrop, or the real window shows around them.
        if [.push, .parallax, .flip].contains(style) {
            root.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        }
        if style == .flip {
            var p = CATransform3DIdentity
            p.m34 = -1 / 1200
            root.sublayerTransform = p
        }

        let w = root.bounds.width
        let dir: CGFloat = edge == .left ? -1 : 1   // the side the incoming app comes from
        let nudge = max(tileGap, 8)
        func set(_ l: CALayer?, x: CGFloat = 0, scale s: CGFloat = 1, rotate: CGFloat = 0, opacity: Double = 1) {
            guard let l else { return }
            var t = CATransform3DMakeTranslation(x, 0, 0)
            t = CATransform3DScale(t, s, s, 1)
            if rotate != 0 { t = CATransform3DRotate(t, rotate, 0, 1, 0) }
            l.transform = t
            l.opacity = Float(opacity)
        }
        let (duration, curve): (Double, (Double) -> Double) = switch style {
        case .carousel: (0.4, glide)
        case .push: (0.5, cubicBezier(0.65, 0, 0.35, 1))
        case .parallax: (0.45, glide)
        case .zoom: (0.32, easeOutCubic)
        case .slide, .slideFade: (0.25, glide)
        case .crossfade: (0.25, { $0 })
        case .flip: (0.5, cubicBezier(0.45, 0, 0.55, 1))
        }
        let step: (Double) -> Void = { p in
            let e = reversed ? 1 - p : p   // progress of the forward animation
            CATransaction.begin(); CATransaction.setDisableActions(true)
            switch style {
            case .carousel:
                set(incoming, x: dir * w * (1 - e))
                outgoing.isHidden = e >= 1
            case .push:
                // Two cards side by side: both shrink a little mid-way, travel together with a gap, settle.
                let s = 1 - 0.1 * sin(.pi * e)
                let span = w + 24
                set(incoming, x: dir * span * (1 - e), scale: s)
                set(outgoing, x: -dir * span * e, scale: s)
            case .parallax:
                // The current app sinks back (slower, smaller, darker) under the one sliding over it.
                set(incoming, x: dir * w * (1 - e))
                set(outgoing, x: -dir * w * 0.25 * e, scale: 1 - 0.08 * e)
                dim.opacity = Float(0.5 * e)
            case .zoom:
                set(outgoing, scale: 1 - 0.15 * e, opacity: 1 - e)
            case .crossfade:
                set(outgoing, opacity: 1 - e)
            case .slide, .slideFade:
                set(incoming, x: dir * nudge * (1 - e))
                set(outgoing, opacity: 1 - e)
            case .flip:
                let half = CGFloat.pi / 2
                outgoing.isHidden = e >= 0.5
                incoming?.isHidden = e < 0.5
                if e < 0.5 { set(outgoing, rotate: -dir * half * e * 2) }
                else { set(incoming, rotate: dir * half * (1 - (e - 0.5) * 2)) }
            }
            CATransaction.commit()
        }
        step(0)
        animator.run(duration: duration, curve: curve, step: step, done: done)
    }

    func close() { window.orderOut(nil) }
}

import AppKit
import Combine
import SwiftUI

/// Drawer peeks (Drawers → Peek at the edges): point near the middle of the main window's left, bottom or right
/// edge and a small arc peeks out with a chevron; click it and that edge's drawer opens. While a drawer is open, the
/// same peek closes it (on the drawer's inner edge for an overlay drawer, which covers the main window's). Each
/// tucks away a moment after the pointer leaves.
final class DrawerPeeks {
    /// What a peek on one edge does now.
    private struct Spot {
        let pair: Pair
        let closes: Bool   // on an open drawer, closing it; otherwise on the main window, opening it
        let frame: NSRect  // the peek itself (Cocoa coords)
        let large: NSRect  // the peek grown, once the pointer touches it
        let panel: NSRect  // room for both, and the bounce
        let zone: NSRect   // the pointer here brings it up
    }

    private final class Peek {
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        let model = PeekModel()
        let pointer = PointerView()
        var spot: Spot?
        var shown = false
        var large = false
        var hideLater: DispatchWorkItem?
        var orderOutLater: DispatchWorkItem?

        init() {
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let host = ClickThroughHostingView(rootView: DrawerPeekView(model: model))
            host.autoresizingMask = [.width, .height]
            pointer.addSubview(host)
            panel.contentView = pointer
        }
    }

    private var peeks: [Edge: Peek] = [:]
    /// The main app under the pointer or in front (or the main app of the open drawer there): its drawers by edge
    /// and its window.
    private var target: (mainID: String, pairs: [Edge: Pair], window: NSRect)?
    private var lastHover: CGWindowID?   // the window under the pointer last time: another one means look again
    private var watched: (window: AXUIElement, app: AXUIElement, observer: AXObserver)?
    private var lastCheck: CFTimeInterval = 0
    private var pointerMonitor: Any?
    private var scheduled = false
    private var lastLook: CFTimeInterval = 0
    private var configChange: AnyCancellable?

    private static let length: CGFloat = 60, depth: CGFloat = 18   // the arc, along and out from the edge
    private static let reach: CGFloat = 60, span: CGFloat = 220     // the zone that brings it up
    private static let linger = 1.0                                  // seconds it stays once the pointer leaves

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        configChange = Config.shared.objectWillChange.sink { [weak self] _ in self?.refresh() }
    }

    /// Match the app in front now (on the next run loop pass, once per burst of changes).
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.update()
        }
    }

    private func update() {
        let cfg = Config.shared
        guard cfg.drawerPeeks, AXIsProcessTrusted(), case let (main, w)? = pick(),
              let mainID = main.bundleIdentifier, let f = axFrame(w)
        else { clear(); return }
        var pairs: [Edge: Pair] = [:]
        for p in cfg.pairs where p.mainID == mainID && pairs[p.edge] == nil { pairs[p.edge] = p }   // the first on each edge
        if cfg.switcher == .bottom, cfg.carousel(containing: mainID) != nil { pairs[.bottom] = nil }   // the switcher's edge
        target = (mainID, pairs, cocoa(f))
        watch(main, w)
        trackPointer(true)
        pointerMoved()
    }

    /// The main app to peek at: the one whose window (or one of whose open drawers) is under the pointer, focused or
    /// not; else the one in front.
    private func pick() -> (NSRunningApplication, AXUIElement)? {
        func main(for id: String?) -> (NSRunningApplication, AXUIElement)? {
            guard let id = drawer.mainApp(for: id), let m = running(id), !m.isHidden, let w = visibleWindow(m) else { return nil }
            return (m, w)
        }
        if let h = Hovered.window, let id = NSRunningApplication(processIdentifier: h.pid)?.bundleIdentifier,
           let m = main(for: id), m.0.bundleIdentifier != id || windowNumber(m.1) == h.wid { return m }
        return main(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Nothing under the pointer or in front with drawers to peek at.
    private func clear() {
        target = nil
        for pk in peeks.values { hide(pk) }
        unwatch()
        trackPointer(Config.shared.drawerPeeks && AXIsProcessTrusted())   // moves also look again (see pointerMoved)
    }

    private func cocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: NSScreen.screens[0].frame.height - r.maxY, width: r.width, height: r.height)
    }

    /// Where the peek on `edge` goes now, and what it does. Worked out afresh each time (drawers open, close and
    /// resize): just arithmetic on frames Drawer already knows.
    private func spot(_ edge: Edge) -> Spot? {
        guard let target, let pair = target.pairs[edge] else { return nil }
        let closes = drawer.isOpen(pair.id)
        var win = target.window
        if closes {
            guard let d = drawer.dockedFrame(pair.id).map(cocoa) else { return nil }   // sliding in or out: nothing to peek at
            // An overlay covers the main window's edge: sit on the drawer's inner edge instead (the side facing
            // the main window), poking out over the main window like the others. Worked out as a stand-in window
            // whose edge on the drawer's side is that inner edge.
            if !pair.tiles {
                let far = target.window.width + target.window.height
                switch edge {
                case .bottom: win = NSRect(x: d.minX, y: d.maxY, width: d.width, height: far)
                case .left: win = NSRect(x: d.maxX, y: d.minY, width: far, height: d.height)
                case .right: win = NSRect(x: d.minX - far, y: d.minY, width: far, height: d.height)
                }
            }
        }
        let L = Self.length, D = Self.depth, R = Self.reach, S = Self.span
        let big = Self.largeSize(edge), inset = Self.inset, m = Self.margin
        // Laid out from where the peek sits: the middle of `win`'s edge on the drawer's side.
        let frame: NSRect, large: NSRect, panel: NSRect, zone: NSRect
        switch edge {
        case .bottom:
            let x = win.midX, base = win.minY, pw = max(L, big.width) + 2 * m
            frame = NSRect(x: x - L / 2, y: base, width: L, height: D)
            large = NSRect(x: x - big.width / 2, y: base + inset, width: big.width, height: big.height)
            panel = NSRect(x: x - pw / 2, y: base, width: pw, height: inset + big.height + m)
            zone = NSRect(x: x - S / 2, y: base, width: S, height: R)
        case .left:
            let y = win.midY, base = win.minX, ph = max(L, big.height) + 2 * m
            frame = NSRect(x: base, y: y - L / 2, width: D, height: L)
            large = NSRect(x: base + inset, y: y - big.height / 2, width: big.width, height: big.height)
            panel = NSRect(x: base, y: y - ph / 2, width: inset + big.width + m, height: ph)
            zone = NSRect(x: base, y: y - S / 2, width: R, height: S)
        case .right:
            let y = win.midY, base = win.maxX, ph = max(L, big.height) + 2 * m, pw = inset + big.width + m
            frame = NSRect(x: base - D, y: y - L / 2, width: D, height: L)
            large = NSRect(x: base - inset - big.width, y: y - big.height / 2, width: big.width, height: big.height)
            panel = NSRect(x: base - pw, y: y - ph / 2, width: pw, height: ph)
            zone = NSRect(x: base - R, y: y - S / 2, width: R, height: S)
        }
        return Spot(pair: pair, closes: closes, frame: frame.integral, large: large.integral, panel: panel.integral,
                    zone: zone.intersection(win))
    }

    static let inset: CGFloat = 3, margin: CGFloat = 10   // the grown peek's gap from the edge; room for its bounce
    /// The grown peek: the drawer app's icon tile with the chevron beside it, on the side it points.
    static func largeSize(_ edge: Edge) -> CGSize { edge == .bottom ? CGSize(width: 32, height: 50) : CGSize(width: 50, height: 32) }

    // MARK: Pointer

    private func trackPointer(_ on: Bool) {
        if on, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.pointerMoved() }
        } else if !on, let m = pointerMonitor {
            NSEvent.removeMonitor(m)
            pointerMonitor = nil
        }
    }

    /// Moves come from everywhere else (a global monitor) and from over a peek itself (its tracking area).
    private func pointerMoved() {
        let hover = Hovered.window
        if hover?.wid != lastHover { lastHover = hover?.wid; refresh() }   // onto another window: maybe another main app
        guard let target else {
            // Nothing set up: if a main app with drawers is in front anyway, it was missed. Look again, now and then.
            let now = CACurrentMediaTime()
            if now - lastLook > 0.3, drawer.mainApp(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil {
                lastLook = now
                refresh()
            }
            return
        }
        // Now and then, check it's still on the right window and spot (an app can switch windows without
        // anything else telling Drawer).
        let now = CACurrentMediaTime()
        if now - lastCheck > 1 { lastCheck = now; refresh() }
        let p = NSEvent.mouseLocation
        // Only over its own windows: not where another window covers that edge.
        let over = hover.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }
            .flatMap { drawer.mainApp(for: $0) } == target.mainID
        for edge in [Edge.left, .bottom, .right] {
            let pk = peek(edge)
            guard let s = spot(edge) else { pk.spot = nil; hide(pk); continue }
            let changed = pk.spot.map { $0.pair.id != s.pair.id || $0.closes != s.closes } ?? true
            if changed, pk.shown { hide(pk) }   // e.g. its drawer just opened: tuck the old one away first
            pk.spot = s
            if pk.panel.frame != s.panel, !pk.shown || !changed { pk.panel.setFrame(s.panel, display: true) }
            let points = s.closes ? edge.outward : edge.inward
            if pk.model.points != points { pk.model.points = points }   // only on change: each set redraws it
            if pk.model.icon != s.pair.drawerID { pk.model.icon = s.pair.drawerID }
            if pk.model.closes != s.closes { pk.model.closes = s.closes }
            let onPeek = s.frame.contains(p), onLarge = pk.large && s.large.insetBy(dx: -8, dy: -8).contains(p)
            if pk.shown, pk.large != (onPeek || onLarge) { pk.large = onPeek || onLarge; pk.model.large = pk.large; publishHits() }
            if (over && s.zone.contains(p)) || onPeek || onLarge {
                if !changed || !pk.panel.isVisible { show(pk) }
            } else if pk.shown {
                hideSoon(pk)
            }
        }
    }

    /// Where clicks are the peeks' (global top-left coords), so Drawer's own click handling leaves them alone.
    private func publishHits() {
        let primaryH = NSScreen.screens[0].frame.height
        let rects = peeks.values.compactMap { pk -> CGRect? in
            guard pk.shown, let s = pk.spot else { return nil }
            let r = pk.large ? s.large : s.frame
            return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
        }
        PanelHits.set("peeks", rects)
    }

    private func peek(_ edge: Edge) -> Peek {
        if let pk = peeks[edge] { return pk }
        let pk = Peek()
        pk.model.edge = edge
        pk.pointer.onMove = { [weak self] in self?.pointerMoved() }
        pk.model.click = { [weak self, weak pk] in if let self, let pk { self.clicked(pk) } }
        peeks[edge] = pk
        return pk
    }

    private func clicked(_ pk: Peek) {
        guard let s = pk.spot else { return }
        hide(pk)
        if s.closes { drawer.close(s.pair.id) } else { drawer.open(s.pair) }
    }

    private func show(_ pk: Peek) {
        pk.hideLater?.cancel(); pk.hideLater = nil
        guard !pk.shown else { return }
        pk.shown = true
        pk.orderOutLater?.cancel(); pk.orderOutLater = nil
        if let s = pk.spot, pk.panel.frame != s.panel { pk.panel.setFrame(s.panel, display: true) }
        defer { publishHits() }
        if pk.panel.isVisible {
            pk.model.visible = true
        } else {
            pk.model.visible = false   // start tucked in so it springs out
            pk.panel.orderFrontRegardless()
            DispatchQueue.main.async { pk.model.visible = pk.shown }
        }
    }

    private func hideSoon(_ pk: Peek) {
        guard pk.hideLater == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.hide(pk) }
        pk.hideLater = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: item)
    }

    private func hide(_ pk: Peek) {
        pk.hideLater?.cancel(); pk.hideLater = nil
        guard pk.shown else { return }
        pk.shown = false
        pk.large = false
        pk.model.visible = false
        pk.model.large = false
        publishHits()
        let item = DispatchWorkItem { if !pk.shown { pk.panel.orderOut(nil) } }   // once it has tucked away
        pk.orderOutLater = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    // MARK: Following the main window

    private func watch(_ app: NSRunningApplication, _ w: AXUIElement) {
        if let watched, CFEqual(watched.window, w) { return }
        unwatch()
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, _, refcon in
            Unmanaged<DrawerPeeks>.fromOpaque(refcon!).takeUnretainedValue().refresh()
        }, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque(), el = AXUIElementCreateApplication(app.processIdentifier)
        for n in Self.notes { AXObserverAddNotification(obs, w, n as CFString, me) }
        for n in Self.appNotes { AXObserverAddNotification(obs, el, n as CFString, me) }   // switched to another of its windows
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        watched = (w, el, obs)
    }

    private static let notes = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                                kAXWindowMiniaturizedNotification]
    private static let appNotes = [kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification,
                                   kAXWindowCreatedNotification]

    private func unwatch() {
        guard let (w, el, obs) = watched else { return }
        for n in Self.notes { AXObserverRemoveNotification(obs, w, n as CFString) }
        for n in Self.appNotes { AXObserverRemoveNotification(obs, el, n as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        watched = nil
    }
}

private extension Edge {
    /// Which way a drawer on this edge moves to open (in from the edge) and to close (back out through it).
    var inward: Edge.Direction { switch self { case .left: .right; case .right: .left; case .bottom: .up } }
    var outward: Edge.Direction { switch self { case .left: .left; case .right: .right; case .bottom: .down } }
}

extension Edge {
    enum Direction { case left, right, up, down }
}

final class PeekModel: ObservableObject {
    @Published var edge: Edge = .bottom
    @Published var points: Edge.Direction = .up
    @Published var icon = ""
    @Published var closes = false   // on an open drawer: an × instead of the chevron
    @Published var visible = false
    @Published var large = false   // grown: the pointer is on it
    var click: () -> Void = {}
}

/// A drawer's peek: a low arc on the edge with a chevron the way the drawer will go (an × to close it), springing out of the edge;
/// with the pointer on it, it grows into the drawer app's icon and that chevron, like the carousel switcher.
struct DrawerPeekView: View {
    @ObservedObject var model: PeekModel

    private static let bounce = Animation.spring(response: 0.34, dampingFraction: 0.55)
    static let tile: CGFloat = 32

    var body: some View {
        let edge = model.edge
        let side: EdgeArc.Side = switch edge { case .left: .left; case .right: .right; case .bottom: .bottom }
        let arc = EdgeArc(side: side)
        let align: Alignment = switch edge { case .left: .leading; case .right: .trailing; case .bottom: .bottom }
        let anchor: UnitPoint = switch edge { case .left: .leading; case .right: .trailing; case .bottom: .bottom }
        // Toward the edge it rises from: into the thick of the arc, and where it sinks to when tucked away.
        let toward: CGSize = switch edge {
        case .left: CGSize(width: -1, height: 0)
        case .right: CGSize(width: 1, height: 0)
        case .bottom: CGSize(width: 0, height: 1)
        }
        let small = model.visible && !model.large, big = model.visible && model.large
        let peek = edge == .bottom ? CGSize(width: 60, height: 18) : CGSize(width: 18, height: 60)
        let large = DrawerPeeks.largeSize(edge)
        let padEdge: SwiftUI.Edge.Set = switch edge { case .left: .leading; case .right: .trailing; case .bottom: .bottom }
        ZStack(alignment: align) {
            Button(action: model.click) {
                chevron(size: 9)
                    .foregroundStyle(.primary)   // full contrast on the arc
                    .offset(x: toward.width * 2, y: toward.height * 2)
                    .frame(width: peek.width, height: peek.height)
                    .background(.thickMaterial, in: arc)
                    .overlay(arc.stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .contentShape(arc)
            }
            .buttonStyle(.plain)
            .offset(x: small ? 0 : toward.width * 22, y: small ? 0 : toward.height * 22)
            .opacity(small ? 1 : 0)
            .allowsHitTesting(small)
            Button(action: model.click) {
                // The drawer app's icon in its own tile, and the chevron (or the ×) outside it, on the side away
                // from the edge. White with a dark halo, so it reads over anything.
                let tile = AppIcon(id: model.icon, size: 22)
                    .frame(width: Self.tile, height: Self.tile)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                let arrow = chevron(size: 12)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                Group {
                    switch edge {
                    case .bottom: VStack(spacing: 3) { arrow; tile }
                    case .left: HStack(spacing: 3) { tile; arrow }
                    case .right: HStack(spacing: 3) { arrow; tile }
                    }
                }
                .frame(width: large.width, height: large.height, alignment: align)
                .contentShape(Rectangle())
            }
            .buttonStyle(PeekPress())
            .scaleEffect(big ? 1 : 0.3, anchor: anchor)
            .opacity(big ? 1 : 0)
            .allowsHitTesting(big)
            .padding(padEdge, DrawerPeeks.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
        .animation(Self.bounce, value: model.visible)
        .animation(Self.bounce, value: model.large)
    }

    private func chevron(size: CGFloat) -> some View {
        if model.closes { return Image(systemName: "xmark").font(.system(size: size - 1, weight: .heavy)) }
        let name = switch model.points {
        case .left: "chevron.left"; case .right: "chevron.right"; case .up: "chevron.up"; case .down: "chevron.down"
        }
        return Image(systemName: name).font(.system(size: size, weight: .heavy))
    }
}

/// Dips when pressed and springs back.
private struct PeekPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// A dome rising from one side of its rect.
struct EdgeArc: Shape {
    enum Side { case top, bottom, left, right }
    let side: Side

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch side {
        case .top, .bottom:
            let base = side == .top ? r.minY : r.maxY, crest = side == .top ? r.maxY : r.minY
            p.move(to: CGPoint(x: r.minX, y: base))
            p.addCurve(to: CGPoint(x: r.maxX, y: base),
                       control1: CGPoint(x: r.minX + r.width * 0.18, y: crest),
                       control2: CGPoint(x: r.maxX - r.width * 0.18, y: crest))
        case .left, .right:
            let base = side == .left ? r.minX : r.maxX, crest = side == .left ? r.maxX : r.minX
            p.move(to: CGPoint(x: base, y: r.minY))
            p.addCurve(to: CGPoint(x: base, y: r.maxY),
                       control1: CGPoint(x: crest, y: r.minY + r.height * 0.18),
                       control2: CGPoint(x: crest, y: r.maxY - r.height * 0.18))
        }
        p.closeSubpath()
        return p
    }
}

/// Where clicks belong to Drawer's own floating windows (peeks, the carousel switcher) right now, in global
/// top-left coordinates. Read by the event tap off the main thread, so it can leave those clicks alone without
/// also ignoring the see-through parts around them.
enum PanelHits {
    private static let lock = NSLock()
    private static var rects: [String: [CGRect]] = [:]

    static func set(_ owner: String, _ r: [CGRect]) { lock.lock(); rects[owner] = r; lock.unlock() }

    static func contains(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rects.values.contains { $0.contains { $0.contains(p) } }
    }
}

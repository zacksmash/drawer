import AppKit
import Combine
import SwiftUI

/// What the switcher is showing.
enum SwitcherState { case none, peek, full }

/// A row of a carousel's app icons over the app showing now (Carousels → Switcher), like a little dock. Click one
/// to switch straight to it. Shows on its shortcut, always, or (Pointer near its edge) as a small peek when the
/// pointer nears that edge of the window, springing open once the pointer reaches the peek and back to the peek
/// when it leaves. On the carousel app under the pointer (focused or not), else the one in front; it stays open
/// through a switch.
final class CarouselSwitcher {
    private let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
    private let model = SwitcherModel()
    private let container = PointerView()
    private lazy var host = ClickThroughHostingView(rootView: SwitcherView(model: model))
    private var scheduled = false
    private var size: CGSize = .zero
    /// The window it sits on, watched so it follows as that moves or resizes, and its app, watched for switching
    /// to another of its windows.
    private var watched: (window: AXUIElement, app: AXUIElement, observer: AXObserver)?
    private var configChange: AnyCancellable?
    /// Where the open switcher and the peek sit on the app in front now (Cocoa coordinates); nil: nowhere for it.
    private var frame: NSRect?
    private var peekFrame: NSRect = .zero
    /// The pointer here brings up the peek: the middle of the window's edge, around where the switcher sits.
    private var zone: NSRect = .zero
    private var shownPid: pid_t?       // the app it's on
    private var lastHover: CGWindowID? // the window under the pointer last time: another one means look again
    private var shownOn: UUID?         // the carousel it's on, so switching to another app forgets `revealed`
    private var revealed = false       // by its shortcut, until pressed again or the app changes
    private var closeAfterSwap = false // opened by its shortcut and used: close once the switch is done
    private var flashing = false       // a carousel shortcut or swipe is switching: open, showing which app
    private var flashEnd: DispatchWorkItem?
    private var lastCheck: CFTimeInterval = 0
    private var hover: SwitcherState = .none   // what the pointer has brought up (Pointer near its edge)
    private var peekTimeout: DispatchWorkItem?   // the pointer left the zone: the peek tucks away unless it comes back
    private var orderOutLater: DispatchWorkItem?
    private var pointerMonitor: Any?
    private var retries = 0            // the app in front is a carousel app, but its window isn't showing yet
    private var lastRetry: CFTimeInterval = 0

    private static let cell: CGFloat = 32, spacing: CGFloat = 2, pad: CGFloat = 4
    static let margin: CGFloat = 12     // room around the open switcher for its bounce and shadow
    static let inset: (bottom: CGFloat, top: CGFloat) = (10, 6)   // the open switcher's gap from the window's edge
    private static let peekLinger = 1.0   // seconds a peek stays once the pointer leaves its zone

    init() {
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // over the carousel apps, even as they switch
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // the views draw their own, which follows them as they spring
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.onMove = { [weak self] in self?.pointerMoved() }
        panel.contentView = container
        model.pick = { [weak self] target in self?.pick(target) }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.retries = 0; self?.refresh() }
        }
        configChange = Config.shared.objectWillChange.sink { [weak self] _ in self?.refresh() }
    }

    /// Show, move or hide it to match what's in front now (on the next run loop pass, once per burst of changes).
    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.update()
        }
    }

    /// Its shortcut: open it, or close it if it's open. Returns whether it's open now.
    func toggle() -> Bool {
        update()
        reveal(shown != .full)
        return revealed
    }

    func reveal(_ on: Bool) {
        revealed = on && frame != nil
        if !on { setHover(.none) }   // closing it on purpose: don't leave it up because the pointer's near
        apply()
    }

    /// A carousel shortcut or swipe is switching to `target`: open with it highlighted, and close a moment after the
    /// switch (unless the pointer keeps it open).
    func showSwitch(to target: String) {
        update()
        guard frame != nil else { return }
        flashEnd?.cancel(); flashEnd = nil
        flashing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.current = target }
        apply()
    }

    private func pick(_ target: String) {
        guard let current = model.current.isEmpty ? nil : model.current else { return }
        if revealed && Config.shared.switcherShow != .always && hover != .full { closeAfterSwap = true }
        carousels.jump(front: current, to: target)
    }

    private var shown: SwitcherState {
        guard frame != nil else { return .none }
        if flashing { return .full }
        switch Config.shared.switcherShow {
        case .always: return .full
        case .shortcut: return revealed ? .full : .none
        case .hover: return revealed ? .full : hover
        }
    }

    private func update() {
        let cfg = Config.shared
        // Mid-switch: stay just as it is (open, on the same spot) until the new app is in.
        if carousels.isBusy, panel.isVisible { return }
        guard cfg.switcher != .off, !carousels.isBusy, case let (app, w)? = pick(),
              let id = app.bundleIdentifier, let c = cfg.carousel(containing: id), let f = axFrame(w)
        else {
            off()
            // A carousel app just switched to (Dock, ⌘-Tab, unhidden) can take a moment to put its window on
            // screen: look again shortly rather than wait for the next change.
            if !carousels.isBusy, retries < 8, cfg.switcher != .off, cfg.carousel(containing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
            }
            return
        }
        retries = 0
        shownPid = app.processIdentifier
        if shownOn != c.id { shownOn = c.id; revealed = false; setHover(.none) }
        if closeAfterSwap { closeAfterSwap = false; revealed = false }
        let n = CGFloat(c.members.count)
        size = CGSize(width: n * Self.cell + (n - 1) * Self.spacing + 2 * Self.pad, height: Self.cell + 2 * Self.pad)
        if model.members != c.members { model.members = c.members }
        if model.current != id { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { model.current = id } }
        watch(app, w)
        place(on: f)
        if flashing, flashEnd == nil {   // the switch is done: close in a moment
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.flashEnd = nil
                self.flashing = false
                self.apply()
            }
            flashEnd = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
        }
    }

    /// The carousel app to show it on: the one whose window is under the pointer, focused or not; else the one in front.
    private func pick() -> (NSRunningApplication, AXUIElement)? {
        func carouselWindow(_ app: NSRunningApplication?) -> AXUIElement? {
            guard let app, !app.isHidden, Config.shared.carousel(containing: app.bundleIdentifier) != nil else { return nil }
            return visibleWindow(app)
        }
        if let h = Hovered.window, let app = NSRunningApplication(processIdentifier: h.pid),
           let w = carouselWindow(app), windowNumber(w) == h.wid { return (app, w) }
        let front = NSWorkspace.shared.frontmostApplication
        return carouselWindow(front).map { (front!, $0) }
    }

    /// Nothing to show it on.
    private func off() {
        frame = nil
        flashing = false
        flashEnd?.cancel(); flashEnd = nil
        shownOn = nil
        shownPid = nil
        revealed = false
        closeAfterSwap = false
        setHover(.none)
        unwatch()
        let cfg = Config.shared
        trackPointer(cfg.switcher != .off && cfg.switcherShow != .shortcut)   // pointer moves also look again (see pointerMoved)
        apply()
    }

    /// Centred on the window's top or bottom edge, just inside it; the peek right on that edge. The panel spans
    /// both, plus room for the bounce.
    private func place(on f: CGRect) {
        guard f.width > size.width + 40, f.height > size.height * 4 else { frame = nil; apply(); return }
        let cfg = Config.shared
        let top = cfg.switcher == .top
        let primaryH = NSScreen.screens[0].frame.height
        let window = NSRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)   // Cocoa coords
        let peek = PeekView.size(for: model.members.count)
        let inset = top ? Self.inset.top : Self.inset.bottom
        frame = NSRect(x: (window.midX - size.width / 2).rounded(),
                       y: (top ? window.maxY - inset - size.height : window.minY + inset).rounded(),
                       width: size.width, height: size.height)
        peekFrame = NSRect(x: (window.midX - peek.width / 2).rounded(), y: top ? window.maxY - peek.height : window.minY,
                           width: peek.width, height: peek.height)
        let reach: CGFloat = 60   // how far in from the edge the pointer brings up the peek
        zone = NSRect(x: window.midX - size.width / 2 - 80, y: top ? window.maxY - reach : window.minY,
                      width: size.width + 160, height: reach).intersection(window)
        let w = max(size.width, peek.width) + 2 * Self.margin, h = inset + size.height + Self.margin
        let panelFrame = NSRect(x: (window.midX - w / 2).rounded(), y: top ? window.maxY - h : window.minY, width: w, height: h)
        if panel.frame != panelFrame { panel.setFrame(panelFrame, display: true) }
        model.top = top
        trackPointer(cfg.switcherShow != .shortcut)   // also follows the pointer onto other carousel windows
        if cfg.switcherShow == .hover { pointerMoved() }
        apply()
    }

    /// Spring to what should show: in from nothing, between peek and open, or away (then off the screen).
    private func apply() {
        let s = shown
        orderOutLater?.cancel(); orderOutLater = nil
        // Where its clicks are, for Drawer's own click handling to leave alone (global top-left coords).
        let primaryH = NSScreen.screens[0].frame.height
        let hit = s == .full ? frame : s == .peek ? peekFrame : nil
        PanelHits.set("switcher", hit.map { [CGRect(x: $0.minX, y: primaryH - $0.maxY, width: $0.width, height: $0.height)] } ?? [])
        if s == .none {
            guard panel.isVisible else { return }
            model.state = .none
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.shown == .none else { return }
                self.panel.orderOut(nil)
            }
            orderOutLater = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)   // once it has sunk away
            return
        }
        if !panel.isVisible {
            model.state = .none   // start from nothing so it springs in
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in self?.model.state = s }
        } else {
            panel.orderFrontRegardless()
            if model.state != s { model.state = s }
        }
    }

    // MARK: Pointer near its edge

    private func trackPointer(_ on: Bool) {
        if on, pointerMonitor == nil {
            pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.pointerMoved() }
        } else if !on, let m = pointerMonitor {
            NSEvent.removeMonitor(m)
            pointerMonitor = nil
            setHover(.none)
        }
    }

    private func setHover(_ s: SwitcherState) {
        peekTimeout?.cancel(); peekTimeout = nil
        hover = s
    }

    /// A peek stays while the pointer is in the zone that brought it up; once it leaves, it tucks away after a
    /// moment unless the pointer comes back.
    private func lingerPeek(close: Bool) {
        if close { peekTimeout?.cancel(); peekTimeout = nil; return }
        guard peekTimeout == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hover == .peek else { return }
            self.setHover(.none)
            self.apply()
        }
        peekTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekLinger, execute: item)
    }

    /// Moves come from two places: everywhere else (a global monitor), and over the panel itself (its tracking
    /// area), since Drawer gets no global moves over its own window.
    private func pointerMoved() {
        let under = Hovered.window
        if under?.wid != lastHover, !carousels.isBusy { lastHover = under?.wid; refresh() }   // maybe another carousel app
        guard let frame else {
            // Nothing showing: if a carousel app is in front anyway, it was missed. Look again, now and then.
            let now = CACurrentMediaTime()
            if now - lastRetry > 0.3, !carousels.isBusy,
               Config.shared.carousel(containing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != nil {
                lastRetry = now
                refresh()
            }
            return
        }
        // Now and then, check it's still on the right window and spot (an app can switch windows without
        // anything else telling Drawer).
        let now = CACurrentMediaTime()
        if now - lastCheck > 1 { lastCheck = now; refresh() }
        guard Config.shared.switcherShow == .hover else { return }
        let p = NSEvent.mouseLocation
        let near = zone.contains(p) && under?.pid == shownPid   // not where another window covers that edge
        let onPeek = peekFrame.contains(p)   // it opens only once the pointer touches it
        let onOpen = frame.union(peekFrame).insetBy(dx: -8, dy: -8).contains(p)
        let was = hover
        switch hover {
        case .none: if near { setHover(.peek) }
        case .peek: if onPeek { setHover(.full) }
        case .full: if !onOpen, !carousels.isBusy { setHover(.peek) }   // straight back to the peek
        }
        if hover == .peek { lingerPeek(close: near || onPeek) }   // the same area that brought it up keeps it
        if hover != was { apply() }
    }

    // MARK: Following the window

    private func watch(_ app: NSRunningApplication, _ w: AXUIElement) {
        if let watched, CFEqual(watched.window, w) { return }
        unwatch()
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, note, refcon in
            Unmanaged<CarouselSwitcher>.fromOpaque(refcon!).takeUnretainedValue().windowChanged(note as String)
        }, &obs) == .success, let obs else { return }
        let me = Unmanaged.passUnretained(self).toOpaque(), el = AXUIElementCreateApplication(app.processIdentifier)
        for n in Self.notes { AXObserverAddNotification(obs, w, n as CFString, me) }
        for n in Self.appNotes { AXObserverAddNotification(obs, el, n as CFString, me) }
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

    private func windowChanged(_ note: String) {
        guard !carousels.isBusy else { return }   // mid-switch the old app moves out of the way: stay put
        guard let w = watched?.window, note == kAXMovedNotification as String || note == kAXResizedNotification as String,
              let f = axFrame(w) else { refresh(); return }
        place(on: f)   // straight away, so it keeps up with a drag
    }
}

/// Never takes focus: clicking an icon leaves the app in front where it is until the next one comes in.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Drawer is never the active app, so the first click on an icon has to count.
final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reports pointer moves over the switcher's panel, even though Drawer is never the active app.
final class PointerView: NSView {
    var onMove: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onMove?() }
    override func mouseMoved(with event: NSEvent) { onMove?() }
    override func mouseExited(with event: NSEvent) { onMove?() }
}

final class SwitcherModel: ObservableObject {
    @Published var members: [String] = []
    @Published var current = ""
    @Published var state: SwitcherState = .none
    @Published var top = false
    var pick: (String) -> Void = { _ in }
}

/// The peek and the open switcher, in one panel: the peek rises from the window's edge, the switcher springs
/// open out of it.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    private static let bounce = Animation.spring(response: 0.34, dampingFraction: 0.55)

    var body: some View {
        let top = model.top, edge: Alignment = top ? .top : .bottom
        let peek = PeekView.size(for: model.members.count)
        ZStack(alignment: edge) {
            PeekView(members: model.members, current: model.current, top: top)
                .frame(width: peek.width, height: peek.height)
                .offset(y: model.state == .peek ? 0 : (top ? -peek.height - 4 : peek.height + 4))   // sunk into the edge
                .opacity(model.state == .peek ? 1 : 0)
            Dock(members: model.members, current: model.current, pick: model.pick)
                .scaleEffect(model.state == .full ? 1 : 0.3, anchor: top ? .top : .bottom)
                .offset(y: model.state == .full ? 0 : (top ? -8 : 8))
                .opacity(model.state == .full ? 1 : 0)
                .allowsHitTesting(model.state == .full)
                .padding(top ? .top : .bottom, top ? CarouselSwitcher.inset.top : CarouselSwitcher.inset.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
        .animation(Self.bounce, value: model.state)
    }
}

/// The open switcher: the carousel's apps in a row, the one showing highlighted.
private struct Dock: View {
    let members: [String]
    let current: String
    let pick: (String) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(members, id: \.self) { id in
                Button { pick(id) } label: {
                    AppIcon(id: id, size: 22)
                        .opacity(id == current ? 1 : 0.75)
                        .frame(width: 32, height: 32)
                        .background {
                            if id == current {
                                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.15))
                                    .matchedGeometryEffect(id: "current", in: highlight)   // glides to the new app
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressBounce())
                .help(appName(id))
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// Icons dip when pressed and spring back.
private struct PressBounce: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

/// The peek: a low arc on the window's edge with a dot per app, the one showing filled in.
private struct PeekView: View {
    let members: [String]
    let current: String
    let top: Bool

    static func size(for n: Int) -> CGSize { CGSize(width: max(56, CGFloat(n) * 10 + 32), height: 16) }

    var body: some View {
        let arc = EdgeArc(side: top ? .top : .bottom)
        HStack(spacing: 5) {
            ForEach(members, id: \.self) { id in
                Circle().fill(Color.primary.opacity(id == current ? 0.8 : 0.3)).frame(width: 5, height: 5)
            }
        }
        .offset(y: top ? -2 : 2)   // sit low in the arc, toward the edge it rises from
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: arc)
        .overlay(arc.stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 3, y: top ? 1 : -1)
    }
}

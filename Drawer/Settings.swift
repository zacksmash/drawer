import AppKit
import ServiceManagement
import SwiftUI

// MARK: Window — classic macOS settings window with toolbar tabs

final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(tab("Drawers", "rectangle.bottomhalf.filled", DrawersTab()))
            tabs.addTabViewItem(tab("Carousels", "square.stack.3d.forward.dottedline", CarouselsTab()))
            tabs.addTabViewItem(tab("General", "gearshape", GeneralTab()))
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)   // so the window can take focus
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func tab(_ label: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view.environmentObject(Config.shared))
        host.sizingOptions = .preferredContentSize   // window resizes to fit each tab
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    func windowWillClose(_ n: Notification) { NSApp.setActivationPolicy(.accessory) }
}

// MARK: Drawers tab

struct DrawersTab: View {
    @EnvironmentObject var cfg: Config
    @State private var editing: Pair?
    @State private var isNew = false

    /// Main apps in the order they first appear.
    private var mains: [String] {
        var seen = Set<String>()
        return cfg.pairs.map(\.mainID).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            if cfg.pairs.isEmpty {
                Section { Text("No drawers yet.").foregroundStyle(.secondary) }
            }
            ForEach(mains, id: \.self) { main in
                Section {
                    ForEach(cfg.pairs.filter { $0.mainID == main }) { pair in
                        Button { isNew = false; editing = pair } label: {
                            DrawerRow(pair: pair, conflict: conflict(pair))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit…") { isNew = false; editing = pair }
                            Button("Remove", role: .destructive) { cfg.pairs.removeAll { $0.id == pair.id } }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        AppIcon(id: main, size: 18)
                        Text(appName(main))
                        Spacer()
                        if let edge = freeEdge(for: main) {
                            Button { isNew = true; editing = Pair(mainID: main, drawerID: "", edge: edge) } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("Add another drawer to \(appName(main))")
                        }
                    }
                }
            }
            Section {
            } footer: {
                HStack(alignment: .top) {
                    Text("Each drawer opens with its shortcut while its main app is in front.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Drawer…") { isNew = true; editing = Pair(mainID: "", drawerID: "") }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: min(620, 110 + CGFloat(mains.count) * 50 + CGFloat(max(cfg.pairs.count, 1)) * 58))
        .sheet(item: $editing) { pair in
            DrawerEditor(draft: pair, isNew: isNew) { result in
                switch result {
                case .save(let p):
                    if let i = cfg.pairs.firstIndex(where: { $0.id == p.id }) { cfg.pairs[i] = p } else { cfg.pairs.append(p) }
                case .remove(let p): cfg.pairs.removeAll { $0.id == p.id }
                case .cancel: break
                }
                editing = nil
            }
        }
    }

    private func freeEdge(for main: String) -> Edge? {
        let used = Set(cfg.pairs.filter { $0.mainID == main }.map(\.edge))
        return Edge.allCases.first { !used.contains($0) }
    }

    /// Why this drawer clashes with another one on the same main app, if it does.
    private func conflict(_ p: Pair) -> String? {
        let siblings = cfg.pairs.filter { $0.mainID == p.mainID && $0.id != p.id }
        if siblings.contains(where: { $0.edge == p.edge }) { return "Another drawer uses this edge" }
        if let i = cfg.pairs.firstIndex(where: { $0.id == p.id }),
           cfg.pairs[..<i].contains(where: { $0.mainID == p.mainID && $0.effectiveShortcut == p.effectiveShortcut }) {
            return "Same shortcut as another drawer — it won't open"
        }
        return nil
    }
}

// MARK: Carousels tab

struct CarouselsTab: View {
    @EnvironmentObject var cfg: Config
    @State private var canCapture = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            if cfg.carousels.isEmpty {
                Section { Text("No carousels yet.").foregroundStyle(.secondary) }
            }
            ForEach($cfg.carousels) { $c in
                Section {
                    AppPickerRow(title: "Main app", id: $c.mainID)
                    ForEach(Array(c.appIDs.enumerated()), id: \.offset) { i, id in
                        HStack(spacing: 8) {
                            Text("\(i + 2)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 16)
                            AppIcon(id: id, size: 18)
                            Text(appName(id))
                            Spacer()
                            Button { c.appIDs.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                                .disabled(i == 0)
                            Button { c.appIDs.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(i == c.appIDs.count - 1)
                            Button { c.appIDs.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .help("Take \(appName(id)) out of the carousel")
                        }
                        .buttonStyle(.borderless)
                    }
                    Menu("Add App") {
                        ForEach(AppCatalog.apps(including: "").filter { !c.members.contains($0.id) }, id: \.id) { a in
                            Button { c.appIDs.append(a.id) } label: {
                                Label { Text(a.name) } icon: { AppIcon(id: a.id, size: 16) }
                            }
                        }
                    }
                    .disabled(c.mainID.isEmpty)
                } header: {
                    HStack(spacing: 8) {
                        AppIcon(id: c.mainID, size: 18)
                        Text(c.mainID.isEmpty ? "New carousel" : appName(c.mainID))
                        Spacer()
                        Button(role: .destructive) { cfg.carousels.removeAll { $0.id == c.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this carousel")
                    }
                } footer: {
                    if let clash = clash(c) {
                        Label(clash, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { cfg.carouselFade }, set: { on in
                    cfg.carouselFade = on
                    if on, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
                    canCapture = CGPreflightScreenCaptureAccess()
                })) {
                    Text("Fade out the app being replaced")
                    Text(cfg.carouselFade && !canCapture
                         ? "Needs Screen Recording for Drawer (to picture the window as it fades). Allow it, then quit and reopen Drawer."
                         : "Uses Screen Recording to picture the outgoing window as it fades.")
                }
                if cfg.carouselFade && !canCapture {
                    Button("Open Screen Recording Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            .onAppear { canCapture = CGPreflightScreenCaptureAccess() }
            Section {
            } footer: {
                HStack(alignment: .top) {
                    Text("Apps in a carousel take turns in the same spot. While one is in front, \(cfg.shortcut(for: .right).display) slides in the next and \(cfg.shortcut(for: .left).display) the previous, wrapping around. Move or resize whichever is showing and the rest follow.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Carousel…") { cfg.carousels.append(Carousel(mainID: "")) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: min(720, 210 + CGFloat(cfg.carousels.reduce(0) { $0 + $1.appIDs.count + 2 }) * 44 + CGFloat(cfg.carousels.count) * 50))
    }

    /// Why part of this carousel won't work as expected, if so.
    private func clash(_ c: Carousel) -> String? {
        if let other = cfg.carousels.first(where: { $0.id != c.id && !Set($0.members).isDisjoint(with: c.members) && $0.members.count > 1 }),
           let shared = c.members.first(where: other.members.contains) {
            return "\(appName(shared)) is in another carousel too — only the first one cycles."
        }
        let sides = Set([cfg.shortcut(for: .left), cfg.shortcut(for: .right)])
        if let p = cfg.pairs.first(where: { c.members.contains($0.mainID) && sides.contains($0.effectiveShortcut) }) {
            return "\(appName(p.mainID))'s \(p.edge.rawValue) drawer shares a cycling shortcut, so it won't open."
        }
        return nil
    }
}

struct DrawerRow: View {
    let pair: Pair
    var conflict: String?

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(id: pair.drawerID, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(appName(pair.drawerID))
                if let conflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text(pair.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 3) { ForEach(pair.effectiveShortcut.keys, id: \.self) { KeyCap(text: $0) } }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

extension Pair {
    static let sizes: [(value: Double, label: String)] = [(1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (1.0, "Full")]
    /// The preset this size is, or nil if it was dragged to a custom size.
    var preset: Double? { Self.sizes.first { abs($0.value - size) < 0.005 }?.value }
    var sizeLabel: String { Self.sizes.first { $0.value == preset }?.label ?? "Custom" }
    var summary: String {
        isFull ? "\(edge.label) · Full" : "\(edge.label) · \(sizeLabel) · \(tiles ? "Tiled" : "Floating")"
    }
}

// MARK: Drawer editor sheet

struct DrawerEditor: View {
    enum Result { case save(Pair), remove(Pair), cancel }

    @State var draft: Pair
    let isNew: Bool
    let onFinish: (Result) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LayoutPreview(pair: draft).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                Section {
                    AppPickerRow(title: "Main app", id: $draft.mainID)
                    AppPickerRow(title: "Drawer app", id: $draft.drawerID)
                } footer: {
                    Text("When the main app is in front, the shortcut slides the drawer app in.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Slides in from") {
                        EdgePicker(edge: $draft.edge, taken: takenEdges)
                    }
                    Picker("Size", selection: Binding(
                        get: { draft.preset ?? -1 },
                        set: { if $0 > 0 { draft.size = $0 } })) {
                        ForEach(Pair.sizes, id: \.value) { Text($0.label).tag($0.value) }
                        if draft.preset == nil { Text("Custom").tag(-1.0) }
                    }
                    Toggle(isOn: $draft.shrinkMain) {
                        Text("Make room for the drawer")
                        Text(draft.isFull ? "A full-size drawer covers the main window, so there's no room to make."
                                          : "Resizes the main window so the two sit side by side like tiled windows. When off, the drawer floats over it.")
                    }
                    .disabled(draft.isFull)
                } footer: {
                    if draft.preset == nil {
                        Text("Custom size, set by dragging the drawer's inner edge. Pick a size to go back to a preset.")
                            .foregroundStyle(.secondary)
                    } else if !draft.isFull {
                        Text("Drag an open drawer's inner edge to give it a custom size.").foregroundStyle(.secondary)
                    }
                    if takenEdges.count == Edge.allCases.count {
                        Label("\(appName(draft.mainID)) already has a drawer on every edge.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle(isOn: Binding(
                        get: { draft.shortcut == nil },
                        set: { draft.shortcut = $0 ? nil : Config.shared.shortcut(for: draft.edge) })) {
                        HStack(spacing: 6) {
                            Text("Use the \(draft.edge.label.lowercased()) edge shortcut")
                            HStack(spacing: 3) {
                                ForEach(Config.shared.shortcut(for: draft.edge).keys, id: \.self) { KeyCap(text: $0) }
                            }
                        }
                    }
                    if let sc = draft.shortcut {
                        LabeledContent("Shortcut") {
                            ShortcutRecorder(shortcut: Binding(get: { sc }, set: { draft.shortcut = $0 }))
                        }
                    }
                } footer: {
                    Text("Each edge has its own shortcut, set in General.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .pickerStyle(.segmented)

            Divider()
            HStack {
                if !isNew {
                    Button("Remove Drawer", role: .destructive) { onFinish(.remove(draft)) }
                }
                Spacer()
                Button("Cancel") { onFinish(.cancel) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") { onFinish(.save(draft)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.mainID.isEmpty || draft.drawerID.isEmpty || draft.mainID == draft.drawerID
                              || takenEdges.contains(draft.edge))
            }
            .padding(16)
        }
        .frame(width: 480, height: 720)
        .onChange(of: draft.mainID) { _, _ in
            // Moved to a main app where this edge is taken: pick a free one.
            if takenEdges.contains(draft.edge), let free = Edge.allCases.first(where: { !takenEdges.contains($0) }) {
                draft.edge = free
            }
        }
    }

    /// Edges other drawers on the same main app already use.
    private var takenEdges: Set<Edge> {
        Set(Config.shared.pairs.filter { $0.mainID == draft.mainID && $0.id != draft.id }.map(\.edge))
    }
}

/// Segmented edge control with taken edges greyed out (SwiftUI's segmented Picker can't disable one segment).
struct EdgePicker: NSViewRepresentable {
    @Binding var edge: Edge
    let taken: Set<Edge>

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: Edge.allCases.map(\.label), trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (i, e) in Edge.allCases.enumerated() {
            c.setEnabled(!taken.contains(e), forSegment: i)
            c.setToolTip(taken.contains(e) ? "Another drawer on this app uses the \(e.label.lowercased()) edge" : nil, forSegment: i)
        }
        c.selectedSegment = Edge.allCases.firstIndex(of: edge) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: EdgePicker
        init(parent: EdgePicker) { self.parent = parent }
        @objc func changed(_ c: NSSegmentedControl) {
            guard Edge.allCases.indices.contains(c.selectedSegment) else { return }
            parent.edge = Edge.allCases[c.selectedSegment]
        }
    }
}

/// Little schematic of the main window and where the drawer lands.
struct LayoutPreview: View {
    let pair: Pair

    var body: some View {
        let w: CGFloat = 220, h: CGFloat = 132, gap: CGFloat = 5
        let main = mainRect(w, h, gap), drawer = drawerRect(w, h, gap)
        ZStack(alignment: .topLeading) {
            // Mini "desktop".
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.95), Color(red: 0.62, green: 0.52, blue: 0.88)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: w + 20, height: h + 20)
            ZStack(alignment: .topLeading) {
                window(main, fill: Color(nsColor: .windowBackgroundColor))
                AppIcon(id: pair.mainID, size: 26).position(x: visibleMain(main, drawer).midX, y: visibleMain(main, drawer).midY)
                    .opacity(pair.isFull ? 0 : 1)   // fully covered
                window(drawer, fill: Color.accentColor.opacity(0.35))
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                AppIcon(id: pair.drawerID, size: 26).position(x: drawer.midX, y: drawer.midY)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .offset(x: 10, y: 10)
        }
        .animation(.spring(duration: 0.35), value: pair)
    }

    private func window(_ r: CGRect, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
    }

    /// Part of the main window not covered by the drawer (where its icon goes).
    private func visibleMain(_ m: CGRect, _ d: CGRect) -> CGRect {
        guard !pair.tiles else { return m }
        switch pair.edge {
        case .bottom: return CGRect(x: m.minX, y: m.minY, width: m.width, height: d.minY - m.minY)
        case .left: return CGRect(x: d.maxX, y: m.minY, width: m.maxX - d.maxX, height: m.height)
        case .right: return CGRect(x: m.minX, y: m.minY, width: d.minX - m.minX, height: m.height)
        }
    }

    private func drawerRect(_ w: CGFloat, _ h: CGFloat, _ gap: CGFloat) -> CGRect {
        if pair.isFull { return CGRect(x: 0, y: 0, width: w, height: h) }
        let inset: CGFloat = pair.tiles ? 0 : 6
        switch pair.edge {
        case .bottom:
            let dh = (h - gap) * pair.size
            return CGRect(x: inset, y: h - dh - inset, width: w - 2 * inset, height: dh)
        case .left:
            let dw = (w - gap) * pair.size
            return CGRect(x: inset, y: inset, width: dw, height: h - 2 * inset)
        case .right:
            let dw = (w - gap) * pair.size
            return CGRect(x: w - dw - inset, y: inset, width: dw, height: h - 2 * inset)
        }
    }

    private func mainRect(_ w: CGFloat, _ h: CGFloat, _ gap: CGFloat) -> CGRect {
        guard pair.tiles else { return CGRect(x: 0, y: 0, width: w, height: h) }
        let d = drawerRect(w, h, gap)
        switch pair.edge {
        case .bottom: return CGRect(x: 0, y: 0, width: w, height: d.minY - gap)
        case .left: return CGRect(x: d.maxX + gap, y: 0, width: w - d.maxX - gap, height: h)
        case .right: return CGRect(x: 0, y: 0, width: d.minX - gap, height: h)
        }
    }
}

/// Picker listing installed and running apps, with icons.
struct AppPickerRow: View {
    let title: String
    @Binding var id: String

    var body: some View {
        Picker(title, selection: $id) {
            if id.isEmpty { Text("Choose…").tag("") }
            ForEach(AppCatalog.apps(including: id), id: \.id) { a in
                Label { Text(a.name) } icon: { AppIcon(id: a.id, size: 16) }.tag(a.id)
            }
        }
        .pickerStyle(.menu)
    }
}

enum AppCatalog {
    private static var cached: [(id: String, name: String)]?

    /// Installed apps plus any running regular apps that live elsewhere, sorted by name.
    static func apps(including extra: String) -> [(id: String, name: String)] {
        if cached == nil {
            var list = installedApps()
            var ids = Set(list.map(\.id))
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
                if let id = a.bundleIdentifier, ids.insert(id).inserted { list.append((id, a.localizedName ?? id)) }
            }
            cached = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        var list = cached!
        if !extra.isEmpty, !list.contains(where: { $0.id == extra }) { list.insert((extra, appName(extra)), at: 0) }
        return list
    }
}

struct AppIcon: View {
    let id: String
    let size: CGFloat

    var body: some View {
        if let img = appIcon(id, size: size) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary).frame(width: size, height: size)
        }
    }
}

// MARK: General tab

struct GeneralTab: View {
    @EnvironmentObject var cfg: Config
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Keyboard") {
                ForEach([Edge.left, .bottom, .right]) { e in
                    LabeledContent("\(e.label) drawers") {
                        ShortcutRecorder(shortcut: Binding(get: { cfg.shortcut(for: e) }, set: { cfg.setShortcut($0, for: e) }),
                                         resetTo: .default(for: e))
                    }
                }
                Toggle(isOn: $cfg.peek) {
                    Text("Hold to peek")
                    Text("Hold the shortcut to show the drawer or the next carousel app, and release to go back.")
                }
            }

            Section {
                Picker("Gap around floating drawers", selection: $cfg.inset) {
                    Text("None").tag(0.0); Text("Small").tag(8.0); Text("Large").tag(16.0)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Tiled drawers use the macOS window margins.").foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                        catch { loginError = error.localizedDescription }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
                LabeledContent {
                    if axTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).labelStyle(.titleAndIcon)
                    } else {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Needed to move windows and listen for the shortcut.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled   // pick up changes made in System Settings
            axTrusted = AXIsProcessTrusted()
        }
    }
}

/// Shows the shortcut as key caps; click, then press the new shortcut (needs ⌃, ⌥ or ⌘; fn optional). Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    var resetTo: Shortcut? = nil
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if let resetTo, shortcut != resetTo, !recording {
                Button { shortcut = resetTo } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(resetTo.display)")
            }
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 3) {
                    if recording {
                        Text("Type shortcut…").foregroundStyle(Color.accentColor)
                    } else {
                        ForEach(shortcut.keys, id: \.self) { KeyCap(text: $0) }
                    }
                }
                .frame(minWidth: 110, minHeight: 24)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to record a new shortcut")

        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            let m = e.modifierFlags
            var f: CGEventFlags = []
            if m.contains(.control) { f.insert(.maskControl) }
            if m.contains(.option) { f.insert(.maskAlternate) }
            if m.contains(.shift) { f.insert(.maskShift) }
            if m.contains(.command) { f.insert(.maskCommand) }
            if m.contains(.function) { f.insert(.maskSecondaryFn) }
            guard !f.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else { NSSound.beep(); return nil }
            shortcut = Shortcut(keyCode: Int(e.keyCode), flags: f.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }
}

extension Shortcut {
    /// Individual key caps, e.g. ["fn", "⌃", "D"].
    var keys: [String] {
        let f = cgFlags
        var k: [String] = []
        if f.contains(.maskSecondaryFn) { k.append("fn") }
        if f.contains(.maskControl) { k.append("⌃") }
        if f.contains(.maskAlternate) { k.append("⌥") }
        if f.contains(.maskShift) { k.append("⇧") }
        if f.contains(.maskCommand) { k.append("⌘") }
        return k + [keyName(keyCode)]
    }
}

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

    var body: some View {
        Form {
            Section {
                if cfg.pairs.isEmpty {
                    Text("No drawers yet.").foregroundStyle(.secondary)
                }
                ForEach(cfg.pairs) { pair in
                    Button { isNew = false; editing = pair } label: { DrawerRow(pair: pair) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit…") { isNew = false; editing = pair }
                            Button("Remove", role: .destructive) { cfg.pairs.removeAll { $0.id == pair.id } }
                        }
                }
            } header: {
                Text("Drawers")
            } footer: {
                HStack(alignment: .top) {
                    footnote
                    Spacer()
                    Button("Add Drawer…") {
                        isNew = true
                        editing = Pair(mainID: "", drawerID: "")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: min(560, 170 + CGFloat(max(cfg.pairs.count, 1)) * 58))
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

    @ViewBuilder private var footnote: some View {
        let mains = cfg.pairs.map(\.mainID)
        if Set(mains).count != mains.count {
            Label("Two drawers use the same main app. Only the first one will open.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text("Press \(cfg.shortcut.display) in a main app to open its drawer.")
                .foregroundStyle(.secondary)
        }
    }
}

struct DrawerRow: View {
    let pair: Pair

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(id: pair.mainID, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName(pair.mainID))  →  \(appName(pair.drawerID))")
                Text(pair.summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            AppIcon(id: pair.drawerID, size: 24)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

extension Pair {
    static let sizes: [(value: Double, label: String)] = [(1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔")]
    var sizeLabel: String { Self.sizes.min { abs($0.value - size) < abs($1.value - size) }!.label }
    var summary: String { "\(edge.label) · \(sizeLabel) · \(shrinkMain ? "Tiled" : "Floating")" }
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
                    Picker("Slides in from", selection: $draft.edge) {
                        ForEach(Edge.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Size", selection: Binding(
                        get: { Pair.sizes.min { abs($0.value - draft.size) < abs($1.value - draft.size) }!.value },
                        set: { draft.size = $0 })) {
                        ForEach(Pair.sizes, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    Toggle(isOn: $draft.shrinkMain) {
                        Text("Make room for the drawer")
                        Text("Resizes the main window so the two sit side by side like tiled windows. When off, the drawer floats over it.")
                    }
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
                    .disabled(draft.mainID.isEmpty || draft.drawerID.isEmpty || draft.mainID == draft.drawerID)
            }
            .padding(16)
        }
        .frame(width: 480, height: 570)
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
        guard !pair.shrinkMain else { return m }
        switch pair.edge {
        case .bottom: return CGRect(x: m.minX, y: m.minY, width: m.width, height: d.minY - m.minY)
        case .left: return CGRect(x: d.maxX, y: m.minY, width: m.maxX - d.maxX, height: m.height)
        case .right: return CGRect(x: m.minX, y: m.minY, width: d.minX - m.minX, height: m.height)
        }
    }

    private func drawerRect(_ w: CGFloat, _ h: CGFloat, _ gap: CGFloat) -> CGRect {
        let inset: CGFloat = pair.shrinkMain ? 0 : 6
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
        guard pair.shrinkMain else { return CGRect(x: 0, y: 0, width: w, height: h) }
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
                LabeledContent("Shortcut") { ShortcutRecorder(shortcut: $cfg.shortcut) }
                Toggle(isOn: $cfg.peek) {
                    Text("Hold to peek")
                    Text("Hold the shortcut to show the drawer, and release to hide it.")
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
        .frame(width: 520, height: 430)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled   // pick up changes made in System Settings
            axTrusted = AXIsProcessTrusted()
        }
    }
}

/// Shows the shortcut as key caps; click, then press the new shortcut (needs ⌃, ⌥ or ⌘; fn optional). Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
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

            if shortcut != .default && !recording {
                Button { shortcut = .default } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Reset to \(Shortcut.default.display)")
            }
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

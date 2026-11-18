// Draws the guide's screenshots: Drawer's real peek and switcher views over mock windows. Built and run by render.sh
// (with the app's sources, minus its main.swift).
import AppKit
import SwiftUI

let drawer = Drawer()
let hotkey = Hotkey()
let carousels = CarouselController()
let switcher = CarouselSwitcher()
let peeks = DrawerPeeks()
let settings = SettingsWindow()

let W: CGFloat = 460, H: CGFloat = 290

func peekModel(_ edge: Edge, closes: Bool, large: Bool, icon: String) -> PeekModel {
    let m = PeekModel()
    m.edge = edge; m.closes = closes; m.large = large; m.visible = true; m.icon = icon
    m.points = closes ? (edge == .bottom ? .down : edge == .left ? .left : .right) : (edge == .bottom ? .up : edge == .left ? .right : .left)
    return m
}

/// A plain app window: traffic lights and a few lines of "content".
struct MockWindow: View {
    let dark: Bool
    var faded = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(dark ? Color(white: 0.17) : Color(white: 0.96))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill(faded ? Color.gray.opacity(0.4) : $0).frame(width: 11, height: 11) }
                }
                ForEach([220.0, 170, 260, 140, 200], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 5).fill(dark ? Color(white: 0.3) : Color(white: 0.85)).frame(width: w, height: 10)
                }
            }.padding(16)
        }
    }
}

/// A terminal-ish drawer window.
struct MockDrawer: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1))
                .shadow(color: .black.opacity(0.4), radius: 10, y: -2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach([("$", 160.0), ("", 220), ("", 120), ("$", 90)], id: \.1) { p, w in
                    HStack(spacing: 6) {
                        Text(p.isEmpty ? " " : p).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.32)).frame(width: w, height: 8)
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 26)
        }
    }
}

struct Pointer: View {
    var body: some View {
        Image(systemName: "cursorarrow").font(.system(size: 22, weight: .regular)).foregroundStyle(.black)
            .shadow(color: .white, radius: 0.6).shadow(color: .white, radius: 0.6).shadow(color: .white, radius: 0.6)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: 6, y: 9)   // so .position() places its tip
    }
}

struct Panel<Content: View>: View {
    let step: Int
    let title: String
    let dark: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("\(step)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.22)))
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            ZStack { content() }.frame(width: W, height: H)
        }
        .padding(24)
    }
}

func strip(dark: Bool, @ViewBuilder _ panels: () -> some View) -> some View {
    HStack(spacing: -24) { panels() }
        .padding(.horizontal, 12)
        .background(LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.75), Color(red: 0.55, green: 0.35, blue: 0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
}

// MARK: Drawer peeks

func peekStrip(dark: Bool) -> some View {
    let dh: CGFloat = 112   // the open drawer's height
    return strip(dark: dark) {
        Panel(step: 1, title: "Point near an edge", dark: dark) {
            MockWindow(dark: dark)
            DrawerPeekView(model: peekModel(.bottom, closes: false, large: false, icon: "com.apple.Terminal"))
                .frame(width: 80, height: 63).position(x: W / 2, y: H - 63 / 2)
            Pointer().position(x: W / 2 + 30, y: H - 30)
        }
        Panel(step: 2, title: "Click the peek to open", dark: dark) {
            MockWindow(dark: dark)
            DrawerPeekView(model: peekModel(.bottom, closes: false, large: true, icon: "com.apple.Terminal"))
                .frame(width: 80, height: 63).position(x: W / 2, y: H - 63 / 2)
            Pointer().position(x: W / 2 + 12, y: H - 8)
        }
        Panel(step: 3, title: "Click × to close it", dark: dark) {
            MockWindow(dark: dark)
            MockDrawer().frame(width: W, height: dh).position(x: W / 2, y: H - dh / 2)
            DrawerPeekView(model: peekModel(.bottom, closes: true, large: true, icon: "com.apple.Terminal"))
                .frame(width: 80, height: 63).position(x: W / 2, y: H - dh - 63 / 2)
            Pointer().position(x: W / 2 + 12, y: H - dh - 8)
        }
    }
}

// MARK: Carousel switcher

func switcherModel(_ state: SwitcherState, current: String) -> SwitcherModel {
    let m = SwitcherModel()
    m.members = ["com.apple.Terminal", "com.apple.Safari", "com.apple.Notes"]
    m.current = current; m.state = state; m.top = false
    return m
}

let switcherPanel = CGSize(width: max(3 * 32 + 2 * 2 + 8, 62) + 2 * CarouselSwitcher.margin,
                           height: CarouselSwitcher.inset.bottom + 40 + CarouselSwitcher.margin)

func switcherStrip(dark: Bool) -> some View {
    let sp = switcherPanel
    return strip(dark: dark) {
        Panel(step: 1, title: "Point near the bottom", dark: dark) {
            MockWindow(dark: dark)
            SwitcherView(model: switcherModel(.peek, current: "com.apple.Safari"))
                .frame(width: sp.width, height: sp.height).position(x: W / 2, y: H - sp.height / 2)
            Pointer().position(x: W / 2 + 34, y: H - 30)
        }
        Panel(step: 2, title: "Touch the peek, pick an app", dark: dark) {
            MockWindow(dark: dark)
            SwitcherView(model: switcherModel(.full, current: "com.apple.Safari"))
                .frame(width: sp.width, height: sp.height).position(x: W / 2, y: H - sp.height / 2)
            Pointer().position(x: W / 2 + 34 + 11, y: H - 30 + 11)
        }
        Panel(step: 3, title: "Works on windows behind, too", dark: dark) {
            // The carousel's window, behind another app's.
            ZStack {
                MockWindow(dark: dark)
                SwitcherView(model: switcherModel(.full, current: "com.apple.Notes"))
                    .frame(width: sp.width, height: sp.height).position(x: 160, y: 220 - sp.height / 2)
            }
            .frame(width: 320, height: 220).position(x: 160, y: H - 110)
            MockWindow(dark: !dark).frame(width: 250, height: 190).position(x: W - 125, y: 95)
            Pointer().position(x: 160 - 34 + 11, y: H - 30 + 11)
        }
    }
}

@MainActor func save(_ v: some View, _ path: String, dark: Bool) {
    let host = NSHostingView(rootView: v.environment(\.colorScheme, dark ? .dark : .light))
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.appearance = win.appearance
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("fail"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}

let out = CommandLine.arguments[1]   // the docs folder
MainActor.assumeIsolated {
    _ = NSApplication.shared
    for dark in [false, true] {
        let s = dark ? "dark" : "light"
        save(peekStrip(dark: dark), out + "/peeks-\(s).png", dark: dark)
        save(switcherStrip(dark: dark), out + "/switcher-\(s).png", dark: dark)
    }
}

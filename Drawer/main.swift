// Drawer — slides a "drawer" app's window over (or beside) a "main" app's window on a global shortcut.
// Each main app gets its own drawer (e.g. T3 Code → Rex, VS Code → Notes); the shortcut acts on
// whichever main app is in front. Carousels cycle several apps through one spot (fn⌃, / fn⌃.).
// Configure from the menu bar icon → Settings…

import AppKit

// Helper mode for Hotkey's watchdog: report whether Accessibility is allowed right now, then exit.
if CommandLine.arguments.contains("--trust-check") { exit(AXIsProcessTrusted() ? 0 : 1) }

let drawer = Drawer()
let hotkey = Hotkey()
let carousels = CarouselController()
let settings = SettingsWindow()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.bottomhalf.filled", accessibilityDescription: "Drawer")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if !AXIsProcessTrusted() { drawer.promptAccessibility() }
        // Never let a busy app stall Drawer for long: cap every Accessibility call (default is ~6s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        if AXIsProcessTrusted() { drawer.recoverAfterCrash() }
        hotkey.install()
    }

    func applicationWillTerminate(_ n: Notification) { drawer.restoreNow() }

    // Reopening the app (e.g. double-clicking it in Applications) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settings.show(); return false
    }

    // Rebuilt each time it opens so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Config.shared
        for p in cfg.pairs {
            let i = menu.addItem(withTitle: "\(appName(p.mainID))  →  \(appName(p.drawerID))  ·  \(p.edge.label)  ·  \(p.effectiveShortcut.display)",
                                 action: nil, keyEquivalent: "")
            i.image = appIcon(p.drawerID)
            i.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Drawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func openSettings() { settings.show() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

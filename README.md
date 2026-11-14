<p align="center">
  <img src="docs/banner.svg" alt="Drawer: slide any app out of the edge of the one you're working in" width="100%">
</p>

<p align="center">
  <img src="docs/icon.png" width="96" alt="Drawer icon"><br>
  <b>A tiny macOS menu bar app that turns your apps into drawers.</b><br>
  Keep a terminal, database client, file browser or chat tucked behind any window, one keystroke away.
</p>

<p align="center">
  <a href="https://github.com/sponsors/zacksmash"><img src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="Sponsor on GitHub"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-native-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift">
</p>

---

## What it does

Pick a **main app** (your editor, browser, whatever you live in) and give it **drawers**: other apps that slide out from its left, bottom or right edge on a shortcut, sized to its window. Press the shortcut again and they slide away. Or put several apps in a **carousel** and flick between them in the same spot.

<p align="center">
  <img src="docs/modes.svg" alt="Overlay, Make room and Carousel modes" width="100%">
</p>

- **Overlay**: the drawer slides over the main window, like a pull-down terminal.
- **Make room**: the drawer tiles beside it and the main window shrinks to fit, then grows back when it closes.
- **Carousel**: apps take turns in one spot. Next and previous slide the next app in over the current one.

## Install

> [!WARNING]
> **Drawer isn't signed with a paid Apple Developer account**, so it isn't notarized by Apple. That's a $99/year membership, and Drawer is a free side project.
>
> - **Building from source** (below) is the easiest way: an app you build yourself isn't flagged by Gatekeeper.
> - **If you download a pre-built copy** from [Releases](https://github.com/zacksmash/drawer/releases/latest), macOS will refuse to open it the first time. Go to **System Settings → Privacy & Security** and click **Open Anyway**, or clear the download flag once:
>   ```bash
>   xattr -dr com.apple.quarantine /Applications/Drawer.app
>   ```
>
> If Drawer earns a spot in your day and you'd like it to open without any of this, [**sponsoring me on GitHub**](https://github.com/sponsors/zacksmash) goes straight toward the developer account that makes notarized releases possible. 💛

### Build from source

You need macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/zacksmash/drawer.git
cd drawer
./Drawer/build.sh --install     # builds, quits any running Drawer, copies it to /Applications
open /Applications/Drawer.app
```

On first launch Drawer asks for **Accessibility** permission (System Settings → Privacy & Security → Accessibility). It needs this to move and resize other apps' windows and to see its shortcuts. Nothing else is required: no Screen Recording, no network.

> [!TIP]
> `build.sh` signs with your own **Apple Development** certificate if you have one (a free Apple ID in Xcode is enough). That keeps the Accessibility permission across rebuilds. Without one it signs ad hoc, and macOS will ask you to re-allow Drawer after each rebuild. Quit Drawer before removing it from the Accessibility list.

## Usage

Drawer lives in the menu bar. Open **Settings…** from its menu.

### Drawers

1. **Drawers** tab → **Add Drawer…**
2. Choose the **main app** and the **drawer app**, the **edge** (left, bottom or right) and a **size** (⅓, ½, ⅔ or Full).
3. Turn on **Make room** to tile beside the main window instead of overlaying it.

Then, with the main app in front:

| Shortcut | Drawer |
| --- | --- |
| <kbd>fn</kbd> <kbd>⌃</kbd> <kbd>,</kbd> | Left |
| <kbd>fn</kbd> <kbd>⌃</kbd> <kbd>D</kbd> | Bottom |
| <kbd>fn</kbd> <kbd>⌃</kbd> <kbd>.</kbd> | Right |

Change them under **General → Keyboard**, or give a single drawer its own shortcut.

- **Hold to peek**: hold the shortcut to show the drawer, let go to hide it.
- **Resize**: drag the drawer's inner edge (the one facing the main window). The new size is saved. **Double-click** that edge to go back to the previous size.
- **Traffic lights** on an open drawer do drawer things. <kbd>⌥</kbd>-click for the usual behaviour.
  - 🔴 slides the drawer away. The app keeps its window and state.
  - 🟡 lets it out as a normal window, with a little *pop*. The shortcut docks it again.
  - 🟢 switches between its size and Full.
- **Drag a drawer out** by its title bar to use it as a normal window. Close it and it goes back to its drawer spot next time.
- **Click the main app** to dismiss overlay drawers. **Move the main window** and its drawers hide instantly.
- **Switching to a drawer app** from the Dock or <kbd>⌘</kbd><kbd>Tab</kbd> opens it in its drawer.

### Carousels

1. **Carousels** tab → **Add Carousel…**
2. Choose a **main app**, then **Add App** for each app in the rotation. Reorder them with the arrows.

While any app in the carousel is in front, or under the pointer:

| Input | Does |
| --- | --- |
| <kbd>fn</kbd> <kbd>⌃</kbd> <kbd>.</kbd> | Next app, slides in from the right |
| <kbd>fn</kbd> <kbd>⌃</kbd> <kbd>,</kbd> | Previous app, slides in from the left |
| <kbd>fn</kbd> + two-finger swipe | Next or previous (one finger on a Magic Mouse) |
| Hold the shortcut | Peek at the next app, let go to come back |

Move or resize whichever app is showing and the rest follow. The carousel's spot is wherever the current app's window is.

> [!NOTE]
> In a carousel app, <kbd>fn</kbd><kbd>⌃</kbd><kbd>,</kbd> and <kbd>fn</kbd><kbd>⌃</kbd><kbd>.</kbd> cycle the carousel, so left and right drawers on that app won't open. Bottom drawers still work. Settings shows a warning when this applies.

## Good to know

- Drawer only moves and resizes windows through the Accessibility API. It never injects into or modifies other apps.
- Apps with a minimum window size (some won't go below a certain height) are fitted as closely as they allow.
- A window on another desktop (Space) is brought over to the current one before it slides in.
- Built and tested on macOS 27. It needs macOS 14 or later.

## Support

Drawer is free and built in spare time. If it saves you a few hundred <kbd>⌘</kbd><kbd>Tab</kbd>s a day:

<p align="center">
  <a href="https://github.com/sponsors/zacksmash"><b>❤️ Sponsor @zacksmash on GitHub</b></a>
</p>

Sponsorships help cover an Apple Developer account, so future releases can be signed and notarized and open with a double-click. Bug reports and ideas are welcome in [Issues](https://github.com/zacksmash/drawer/issues).

## License

[MIT](LICENSE) © Zack Warren
